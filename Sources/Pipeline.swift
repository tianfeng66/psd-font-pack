import Foundation

enum Section: Int, CaseIterable, Identifiable {
    case packed, downloaded, adobeBundled, system, macDownload, adobeFonts, missing

    var id: Int { rawValue }

    var mark: String {
        switch self {
        case .packed, .downloaded, .adobeBundled: return "✓"
        case .missing: return "✗"
        default: return "○"
        }
    }

    var title: String {
        switch self {
        case .packed: return "已打包"
        case .downloaded: return "本机缺失，已从字体库或网上补充并打包"
        case .system: return "Mac 系统自带（未打包，对方用 Mac 就不需要）"
        case .macDownload: return "Mac 系统可下载字体（未打包，对方在「字体册」里搜索该字体点下载即可）"
        case .adobeFonts: return "Adobe Fonts 云字体（未打包，对方打开 PSD 时 Photoshop 会自动激活）"
        case .adobeBundled: return "Photoshop 等 Adobe 软件自带字体（已从本机的 Adobe 软件里找到并打包，防止对方的版本里没有）"
        case .missing: return "缺失！本机没有安装，也没能从字体库或网上补充"
        }
    }

    var willPack: Bool { self == .packed || self == .downloaded || self == .adobeBundled }
}

struct Usage {
    let psd: Int
    let label: String
}

struct FontEntry: Identifiable {
    let ps: String
    var id: String { ps }
    var usages: [Usage] = []
    var found: FoundFont?
    var download: DownloadResult?
    var downloadError: String?
    var downloading = false

    var filePath: String? { found?.path ?? download?.path }

    func section(includeSystem: Bool) -> Section {
        if let f = found {
            switch f.kind {
            case .local: return .packed
            case .system: return includeSystem ? .packed : .system
            case .macDownload: return includeSystem ? .packed : .macDownload
            case .adobeFonts: return .adobeFonts
            case .adobeBundled: return .adobeBundled
            }
        }
        return download != nil ? .downloaded : .missing
    }

    func usageLine(multi: Bool, psdNames: [String], only: Set<Int>? = nil, limit: Int = 3) -> String {
        let list = usages.filter { only?.contains($0.psd) ?? true }
            .map { (multi ? "\(psdNames[$0.psd]): " : "") + $0.label }
        let head = list.prefix(limit).joined(separator: "；")
        return list.count > limit ? head + "（等共 \(list.count) 处）" : head
    }
}

struct Analysis {
    var psds: [URL] = []
    var textLayerCounts: [Int] = []
    var fonts: [FontEntry] = []
    var externals: [(psd: Int, link: ExternalLink)] = []
    var failures: [(url: URL, message: String)] = []

    var psdNames: [String] { psds.map(\.lastPathComponent) }
}

struct PackOptions {
    var includeSystem = false
    var includePSD = true
}

enum Pipeline {
    static let psdExtensions: Set<String> = ["psd", "psb"]

    /// 文件夹展开成里面所有 PSD/PSB（跳过隐藏目录和本工具生成的包）
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var found: [URL] = []
                while let f = e?.nextObject() as? URL {
                    if f.lastPathComponent.hasSuffix("_字体打包") { e?.skipDescendants(); continue }
                    if psdExtensions.contains(f.pathExtension.lowercased()) { found.append(f) }
                }
                out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if psdExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func analyze(_ psds: [URL], locator: FontLocator, library: FontLibrary) -> Analysis {
        var a = Analysis(psds: psds)
        var byName: [String: Int] = [:]
        for (i, url) in psds.enumerated() {
            do {
                let (layers, externals) = try PSDReader.read(url)
                a.textLayerCounts.append(layers.count)
                a.externals += externals.map { (i, $0) }
                for l in layers {
                    var snippet = l.text.components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    if snippet.count > 18 { snippet = String(snippet.prefix(18)) + "…" }
                    let label = l.path + (snippet.isEmpty ? "" : "「\(snippet)」") + (l.hidden ? "（隐藏）" : "")
                    for f in l.fonts {
                        if byName[f] == nil {
                            byName[f] = a.fonts.count
                            a.fonts.append(FontEntry(ps: f))
                        }
                        a.fonts[byName[f]!].usages.append(Usage(psd: i, label: label))
                    }
                }
            } catch {
                a.textLayerCounts.append(0)
                a.failures.append((url, error.localizedDescription))
            }
        }
        a.fonts.sort { $0.ps.localizedCaseInsensitiveCompare($1.ps) == .orderedAscending }
        for i in a.fonts.indices {
            a.fonts[i].found = locator.locate(a.fonts[i].ps)
            if a.fonts[i].found == nil { a.fonts[i].download = library.find(a.fonts[i].ps) }
        }
        return a
    }

    // MARK: - 清单

    static func report(_ a: Analysis, psdIndices: [Int], options: PackOptions, arcnames: [String: String]) -> String {
        let only = Set(psdIndices)
        let fonts = a.fonts.filter { f in f.usages.contains { only.contains($0.psd) } }
        let multi = psdIndices.count > 1
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"

        var lines = ["PSD 字体清单", "生成时间：\(fmt.string(from: Date()))"]
        lines += psdIndices.map { "文件：\(a.psdNames[$0])" }

        let sections = fonts.map { $0.section(includeSystem: options.includeSystem) }
        let packed = sections.filter(\.willPack).count
        let missing = sections.filter { $0 == .missing }.count
        let skipped = fonts.count - packed - missing
        var summary = "共用到 \(fonts.count) 款字体：打包 \(packed) 款"
        if skipped > 0 { summary += "，无需打包 \(skipped) 款" }
        if missing > 0 { summary += "，缺失 \(missing) 款" }
        lines += ["", summary]

        for sec in Section.allCases {
            let group = fonts.filter { $0.section(includeSystem: options.includeSystem) == sec }
            guard !group.isEmpty else { continue }
            lines += ["", "【\(sec.title)】"]
            for f in group {
                let display = f.found?.display ?? ""
                lines.append("  \(sec.mark) \(f.ps)" + (display.isEmpty || display == f.ps ? "" : "（\(display)）"))
                if let arc = arcnames[f.ps] {
                    lines.append("      文件：\(arc)" + (f.download.map { "   来源：\($0.source)" } ?? ""))
                }
                if let note = f.download?.note, !note.isEmpty { lines.append("      ⚠ \(note)") }
                if sec == .packed, let k = f.found?.kind, k == .system || k == .macDownload {
                    lines.append("      说明：Mac 系统自带字体，已一并打包，对方用 Windows 也能正常显示")
                }
                lines.append("      用于：\(f.usageLine(multi: multi, psdNames: a.psdNames, only: only))")
                if sec == .missing {
                    if let err = f.downloadError { lines.append("      自动下载：\(err)") }
                    lines += searchHints(f.ps).map { "      \($0.label)：\($0.url.absoluteString)" }
                }
            }
        }

        let ext = a.externals.filter { only.contains($0.psd) }
        if !ext.isEmpty {
            lines += ["", "【注意：PSD 链接了外部文件，未包含在 PSD 里，需要一并发给对方】"]
            lines += ext.map { "  ⚠ \($0.link.file)   （图层：\(multi ? a.psdNames[$0.psd] + ": " : "")\($0.link.layer)）" }
        }
        if packed > 0 {
            lines += ["", "对方安装字体（一次装完）：打开 Fonts 文件夹，按 ⌘A / Ctrl+A 全选 → Mac 按 ⌘O 或双击，在弹出的窗口点「安装」；Windows 右键 →「为所有用户安装」。装好后重启 Photoshop 再打开 PSD。"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 打包

    /// 生成 <name>_字体打包.zip，返回路径。先写临时文件，成功后才替换。
    static func package(_ a: Analysis, psdIndices: [Int], name: String, outDir: URL, options: PackOptions,
                        progress: ((String) -> Void)? = nil) throws -> URL {
        let only = Set(psdIndices)
        let pack = a.fonts.filter { f in
            f.section(includeSystem: options.includeSystem).willPack && f.filePath != nil
                && f.usages.contains { only.contains($0.psd) }
        }

        var used = Set<String>()
        func unique(_ folder: String, _ file: String) -> String {
            let stem = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
            var candidate = file, n = 2
            while used.contains("\(folder)\(candidate)".lowercased()) {
                candidate = "\(stem)_\(n)" + (ext.isEmpty ? "" : ".\(ext)")
                n += 1
            }
            used.insert("\(folder)\(candidate)".lowercased())
            return "\(folder)\(candidate)"
        }

        var arcnames: [String: String] = [:]
        var fontFiles: [(src: String, arc: String)] = []
        var byPath: [String: String] = [:]
        for f in pack {
            guard let p = f.filePath else { continue }
            if let arc = byPath[p] {
                arcnames[f.ps] = arc // 同一个 .ttc 里的多款字体只放一次
                continue
            }
            let arc = unique("Fonts/", (p as NSString).lastPathComponent)
            byPath[p] = arc
            arcnames[f.ps] = arc
            fontFiles.append((p, arc))
        }

        let pkg = "\(name)_字体打包"
        let target = outDir.appendingPathComponent("\(pkg).zip")
        let tmp = outDir.appendingPathComponent(".\(pkg).zip.part")
        try? FileManager.default.removeItem(at: tmp)

        let zip = try ZipWriter(url: tmp)
        do {
            let text = report(a, psdIndices: psdIndices, options: options, arcnames: arcnames)
            try zip.add(data: Data(text.utf8), name: "\(pkg)/字体清单.txt")
            for (src, arc) in fontFiles {
                progress?("写入 \(arc)…")
                try zip.add(file: URL(fileURLWithPath: src), name: "\(pkg)/\(arc)", compress: true)
            }
            if options.includePSD {
                for i in psdIndices {
                    let url = a.psds[i]
                    let arc = unique("", url.lastPathComponent)
                    let total = fileSize(url.path)
                    var last = Date.distantPast
                    // PSD 内部已压缩，再压一遍收益很小，直接存储更快
                    try zip.add(file: url, name: "\(pkg)/\(arc)", compress: false) { done in
                        guard Date().timeIntervalSince(last) > 0.2 else { return }
                        last = Date()
                        let pct = total > 0 ? Int(done * 100 / total) : 0
                        progress?("写入 \(url.lastPathComponent)（\(pct)%）…")
                    }
                }
            }
            try zip.finish()
        } catch {
            zip.abandon()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }

    static func installToUserFonts(_ path: String) -> Bool {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Fonts", isDirectory: true)
        let dst = dir.appendingPathComponent((path as NSString).lastPathComponent)
        if FileManager.default.fileExists(atPath: dst.path) { return true }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? FileManager.default.copyItem(atPath: path, toPath: dst.path)) != nil
    }
}
