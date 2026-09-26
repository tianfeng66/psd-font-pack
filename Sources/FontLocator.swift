import Foundation
import CoreText

enum FontKind {
    case local        // 普通字体，要打包
    case system       // Mac 系统自带
    case macDownload  // Mac 系统可下载字体（字体册里点下载的那种）
    case adobeFonts   // Adobe Fonts 云字体
    case adobeBundled // Photoshop 等 Adobe 软件自带
}

struct FoundFont {
    let path: String
    let display: String
    let kind: FontKind
}

let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont"]

/// 按 PostScript 名找字体文件。优先问 CoreText（和 Photoshop 看到的一致），
/// 找不到再扫 PS 私有字体目录和「字体册」里被停用的字体。
final class FontLocator {
    private var index: [String: String]?
    private var variableIndex: [String: (path: String, display: String)]?

    func locate(_ ps: String) -> FoundFont? {
        if let f = locateExact(ps) { return f }
        // 可变字体在 PS 里拖了粗细 / 光学尺寸滑块后，名字是按坐标现造的，没有哪个文件叫这个名字，
        // 要找它所属的那个可变字体文件
        let prefixes = Self.variablePrefixes(ps)
        guard !prefixes.isEmpty else { return nil }
        if variableIndex == nil { variableIndex = buildVariableIndex() }
        for p in prefixes {
            if let v = variableIndex?[p.lowercased()] {
                return FoundFont(path: v.path, display: "\(v.display)（可变字体，自定义粗细）", kind: Self.classify(v.path))
            }
        }
        return nil
    }

    /// 可变字体实例名 → 可能的字体前缀。依据 Adobe 技术说明 5902：
    /// 任意坐标写成 `前缀_700wght_5.5wdth`，太长时写成 `前缀-哈希...`；
    /// Adobe 软件实际还会写成 `前缀_wght2BC`（轴名 + 十六进制坐标）。
    static func variablePrefixes(_ ps: String) -> [String] {
        var out: [String] = []
        if ps.hasSuffix("..."), let g = regexGroups(#"^(.+)-[A-Za-z0-9]+\.\.\.$"#, ps), let p = g[1] {
            out.append(p)
        }
        let axis = #"_(?:-?[0-9]*\.?[0-9]+[A-Za-z][A-Za-z0-9]{2,3}|[A-Za-z][A-Za-z0-9]{3}-?[0-9A-Fa-f]+)"#
        if let g = regexGroups("^(.+?)(?:\(axis))+$", ps), let p = g[1] {
            out.append(p)
        }
        // Adobe 也会在命名实例名后面接坐标（`Minion-Roman_wght2BC`），再退一步按 `-` 前的家族前缀找
        for p in out {
            if let dash = p.firstIndex(of: "-"), dash != p.startIndex { out.append(String(p[..<dash])) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    private func buildVariableIndex() -> [String: (path: String, display: String)] {
        var idx: [String: (path: String, display: String)] = [:]
        func add(_ d: CTFontDescriptor) {
            guard let url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL else { return }
            let font = CTFontCreateWithFontDescriptor(d, 12, nil)
            guard let axes = CTFontCopyVariationAxes(font) as? [Any], !axes.isEmpty else { return }
            let family = (CTFontCopyName(font, kCTFontFamilyNameKey) as String?) ?? ""
            let ps = CTFontCopyPostScriptName(font) as String
            var keys = [ps, family.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }]
            keys += [16, 25].compactMap { Self.nameRecord(font, id: $0) }.map { id in id.filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }
            if let dash = ps.firstIndex(of: "-"), dash != ps.startIndex { keys.append(String(ps[..<dash])) }
            for k in keys where !k.isEmpty && idx[k.lowercased()] == nil {
                idx[k.lowercased()] = (url.path, family)
            }
        }
        let available = CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionCreateFromAvailableFonts(nil)) as? [CTFontDescriptor] ?? []
        available.forEach(add)
        for dir in Self.searchDirs() {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where fontExtensions.contains(url.pathExtension.lowercased()) {
                (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []).forEach(add)
            }
        }
        return idx
    }

    /// 读 name 表里指定 ID 的英文名（16 = 排版家族名，25 = 可变字体 PostScript 名前缀）
    private static func nameRecord(_ font: CTFont, id: UInt16) -> String? {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) as Data? else { return nil }
        let b = [UInt8](table)
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
        let count = u16(2), strings = u16(4)
        for i in 0..<count {
            let r = 6 + i * 12
            guard r + 12 <= b.count, u16(r + 6) == Int(id) else { continue }
            let platform = u16(r), lang = u16(r + 4), len = u16(r + 8), off = strings + u16(r + 10)
            guard off + len <= b.count else { continue }
            let raw = Data(b[off..<off + len])
            if platform == 3 && lang == 0x409 { return String(data: raw, encoding: .utf16BigEndian) }
            if platform == 1 && lang == 0 { return String(data: raw, encoding: .macOSRoman) }
        }
        return nil
    }

    private func locateExact(_ ps: String) -> FoundFont? {
        let font = CTFontCreateWithName(ps as CFString, 12, nil)
        // 找不到时 CoreText 会返回替代字体，所以要核对名字
        if (CTFontCopyPostScriptName(font) as String).caseInsensitiveCompare(ps) == .orderedSame,
           let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? NSURL,
           let path = url.path,
           FileManager.default.fileExists(atPath: path) {
            return FoundFont(path: path, display: CTFontCopyDisplayName(font) as String, kind: Self.classify(path))
        }
        if index == nil { index = buildIndex() }
        if let path = index?[ps.lowercased()] {
            return FoundFont(path: path, display: "", kind: Self.classify(path))
        }
        return nil
    }

    /// 字体文件里包含的所有 PostScript 名（.ttc 会有多个）
    static func postScriptNames(in url: URL) -> [String] {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return descs.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
    }

    static func classify(_ path: String) -> FontKind {
        if path.hasPrefix("/System/Library/AssetsV2") || path.contains("/MobileAsset") { return .macDownload }
        if path.hasPrefix("/System/") { return .system }
        if path.contains("/CoreSync/plugins/livetype") { return .adobeFonts }
        if path.contains("/Adobe/Fonts") || path.hasPrefix("/Applications/Adobe ") { return .adobeBundled }
        return .local
    }

    private func buildIndex() -> [String: String] {
        var idx: [String: String] = [:]
        for dir in Self.searchDirs() {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where fontExtensions.contains(url.pathExtension.lowercased()) {
                for n in Self.postScriptNames(in: url) where idx[n.lowercased()] == nil {
                    idx[n.lowercased()] = url.path
                }
            }
        }
        return idx
    }

    private static func searchDirs() -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/Library/Fonts",
            "/Library/Fonts",
            "/Library/Application Support/Adobe/Fonts",
            "\(home)/Library/Application Support/Adobe/Fonts",
        ]
        // Adobe 软件自带字体的位置随版本变化（PS 2026 在 Required/PDFL/Resource/Fonts），
        // 所以在各软件的 Required 目录下找所有叫 Fonts 的文件夹
        for app in (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [] where app.hasPrefix("Adobe ") {
            let root = "/Applications/\(app)"
            var requiredDirs = ["\(root)/Required"]
            for inner in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where inner.hasSuffix(".app") {
                requiredDirs.append("\(root)/\(inner)/Contents/Required")
            }
            for r in requiredDirs { dirs += fontFolders(under: r, depth: 4) }
        }
        return dirs.filter { fm.fileExists(atPath: $0) }
    }

    private static func fontFolders(under dir: String, depth: Int) -> [String] {
        guard depth > 0 else { return [] }
        let fm = FileManager.default
        var out: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let path = "\(dir)/\(name)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  !name.hasSuffix(".plugin"), !name.hasSuffix(".framework"), !name.hasSuffix(".bundle") else { continue }
            if name == "Fonts" { out.append(path) } else { out += fontFolders(under: path, depth: depth - 1) }
        }
        return out
    }
}
