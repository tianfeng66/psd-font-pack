import Foundation

struct TextLayer {
    let path: String
    let text: String
    let fonts: [String]
    let hidden: Bool
}

/// 链接型智能对象：文件不在 PSD 里，要另外发给对方
struct ExternalLink: Hashable {
    let layer: String
    let file: String
}

enum PSDError: LocalizedError {
    case notPSD
    case unsupportedVersion(Int)
    case truncated

    var errorDescription: String? {
        switch self {
        case .notPSD: return "不是 PSD/PSB 文件"
        case .unsupportedVersion(let v): return "不支持的 PSD 版本（\(v)）"
        case .truncated: return "文件不完整或已损坏"
        }
    }
}

/// PSB（版本 2）里这些区块的长度字段是 8 字节
private let bigKeys: Set<String> = [
    "LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk",
    "lnk2", "lnk3", "lnkE", "FXid", "FEid", "FELS", "PxSD", "pths",
    "extd", "extn", "cinf", "artd",
]

private struct LayerRec {
    var name: String
    var hidden: Bool
    var divider = 0
    var engine: Range<Int>?
    var linkBlocks: [Range<Int>] = []
    var path = ""
}

private struct LinkedFile {
    let kind: String
    let uuid: String
    let name: String
    var data: Range<Int>?
}

/// 只读解析 PSD/PSB：找出所有文字图层（含分组路径、隐藏状态）和嵌入式智能对象里的文字。
/// 文件整个内存映射，几个 GB 的 PSB 也不会占用对应的内存。
final class PSDReader {
    static let maxSmartObjectDepth = 8

    static func read(_ url: URL) throws -> (layers: [TextLayer], externals: [ExternalLink]) {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 26 else { throw PSDError.notPSD }
        return try data.withUnsafeBytes { raw in
            let r = PSDReader(raw.bindMemory(to: UInt8.self))
            do {
                try r.parseDocument(base: 0, limit: r.b.count, prefix: "", depth: 0)
            } catch let e as PSDError {
                if case .truncated = e {} else { throw e }
            } catch {}
            // 结构解析中途失败时，已拿到的保留，漏掉的靠全文扫描补上
            r.scanLeftovers()
            return (r.layers, r.externals)
        }
    }

    private let b: UnsafeBufferPointer<UInt8>
    private var layers: [TextLayer] = []
    private var externals: [ExternalLink] = []
    private var covered: [Range<Int>] = []

    private init(_ b: UnsafeBufferPointer<UInt8>) {
        self.b = b
    }

    // MARK: - 读数（全部做越界检查，损坏的文件只会抛错不会崩）

    private func u8(_ p: Int) throws -> Int {
        guard p >= 0, p < b.count else { throw PSDError.truncated }
        return Int(b[p])
    }

    private func be(_ p: Int, _ n: Int) throws -> UInt64 {
        guard p >= 0, p <= b.count - n else { throw PSDError.truncated }
        var v: UInt64 = 0
        for k in 0..<n { v = v << 8 | UInt64(b[p + k]) }
        return v
    }

    private func u16(_ p: Int) throws -> Int { Int(try be(p, 2)) }

    private func i16(_ p: Int) throws -> Int { Int(Int16(truncatingIfNeeded: try be(p, 2))) }

    /// 长度字段：超过文件大小的一律当作损坏，避免后面的加法溢出
    private func length(_ p: Int, _ n: Int) throws -> Int {
        let v = try be(p, n)
        guard v <= UInt64(b.count) else { throw PSDError.truncated }
        return Int(v)
    }

    private func matches(_ p: Int, _ s: String) -> Bool {
        let u = Array(s.utf8)
        guard p >= 0, p <= b.count - u.count else { return false }
        for k in 0..<u.count where b[p + k] != u[k] { return false }
        return true
    }

    private func latin1(_ p: Int, _ n: Int) -> String {
        guard p >= 0, n >= 0, p <= b.count - n else { return "" }
        return String(bytes: UnsafeBufferPointer(rebasing: b[p..<(p + n)]), encoding: .isoLatin1) ?? ""
    }

    private func macRoman(_ p: Int, _ n: Int) -> String {
        guard p >= 0, n >= 0, p <= b.count - n else { return "" }
        return String(bytes: UnsafeBufferPointer(rebasing: b[p..<(p + n)]), encoding: .macOSRoman) ?? ""
    }

    private func utf16(_ p: Int, _ chars: Int) -> String {
        guard chars >= 0, p >= 0, p <= b.count - chars * 2 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(chars)
        for k in 0..<chars { units.append(UInt16(b[p + 2 * k]) << 8 | UInt16(b[p + 2 * k + 1])) }
        return String(decoding: units, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private func find(_ needle: [UInt8], _ from: Int, _ to: Int) -> Int? {
        let lo = max(0, from), hi = min(to, b.count)
        guard !needle.isEmpty, hi - lo >= needle.count, let base = b.baseAddress else { return nil }
        return needle.withUnsafeBytes { nd -> Int? in
            guard let hit = memmem(base + lo, hi - lo, nd.baseAddress, needle.count) else { return nil }
            return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
        }
    }

    /// 附加信息区块：(key, 数据范围)。区块间的对齐填充靠找签名跳过。
    private func blocks(_ start: Int, _ end: Int, _ version: Int) -> [(key: String, range: Range<Int>)] {
        var out: [(key: String, range: Range<Int>)] = []
        let end = min(end, b.count)
        var pos = start
        while pos + 12 <= end {
            if !(matches(pos, "8BIM") || matches(pos, "8B64")) {
                guard let d = (1...3).first(where: { matches(pos + $0, "8BIM") || matches(pos + $0, "8B64") }) else { break }
                pos += d
                continue
            }
            let key = latin1(pos + 4, 4)
            let big = version == 2 && bigKeys.contains(key)
            guard let len = try? length(pos + 8, big ? 8 : 4) else { break }
            let ds = pos + (big ? 16 : 12)
            let de = ds + len
            if de > end { break }
            out.append((key, ds..<de))
            pos = de
        }
        return out
    }

    // MARK: - 结构

    private func layerRecords(_ start: Int, _ end: Int, _ version: Int) throws -> [LayerRec] {
        let count = abs(try i16(start))
        let channelSize = version == 1 ? 6 : 10
        var p = start + 2
        var recs: [LayerRec] = []
        for _ in 0..<count {
            p += 16
            p += 2 + (try u16(p)) * channelSize
            guard matches(p, "8BIM") else { throw PSDError.truncated }
            let flags = try u8(p + 10)
            let extraLen = try length(p + 12, 4)
            p += 16
            let extraEnd = p + extraLen
            var q = p
            q += 4 + (try length(q, 4)) // 蒙版
            q += 4 + (try length(q, 4)) // 混合范围
            let nlen = try u8(q)
            var rec = LayerRec(name: macRoman(q + 1, nlen), hidden: flags & 0x02 != 0)
            q += (1 + nlen + 3) / 4 * 4
            for (key, r) in blocks(q, extraEnd, version) {
                switch key {
                case "luni":
                    if let n = try? length(r.lowerBound, 4) { rec.name = utf16(r.lowerBound + 4, n) }
                case "lsct", "lsdk":
                    rec.divider = (try? u16(r.lowerBound + 2)) ?? 0
                case "TySh":
                    if let k = find(Array("EngineDatatdta".utf8), r.lowerBound, r.upperBound),
                       let n = try? length(k + 14, 4) {
                        rec.engine = (k + 18)..<min(k + 18 + n, r.upperBound)
                    }
                case "SoLd", "SoLE", "PlLd", "plLd":
                    rec.linkBlocks.append(r)
                default:
                    break
                }
            }
            recs.append(rec)
            p = extraEnd
        }

        // 图层按自下而上存储；倒序遍历，用分组起止标记还原「组 / 子图层」路径
        var stack: [String] = []
        for i in recs.indices.reversed() {
            switch recs[i].divider {
            case 1, 2:
                recs[i].path = (stack + [recs[i].name]).joined(separator: " / ")
                stack.append(recs[i].name)
            case 3:
                _ = stack.popLast()
            default:
                recs[i].path = (stack + [recs[i].name]).joined(separator: " / ")
            }
        }
        return recs
    }

    private func linkedFiles(_ r: Range<Int>) -> [LinkedFile] {
        var items: [LinkedFile] = []
        var p = r.lowerBound
        while p + 8 <= r.upperBound {
            guard let len = try? length(p, 8), len > 0 else { break }
            let ds = p + 8, de = ds + len
            guard de <= r.upperBound else { break }
            if let item = try? linkedFile(ds, de) { items.append(item) }
            p = ds + (len + 3) / 4 * 4
        }
        return items
    }

    private func linkedFile(_ ds: Int, _ de: Int) throws -> LinkedFile {
        let kind = latin1(ds, 4)
        var q = ds + 8
        let ulen = try u8(q)
        let uuid = latin1(q + 1, ulen)
        q += 1 + ulen
        let n = try length(q, 4)
        let name = utf16(q + 4, n)
        q += 4 + 2 * n + 8 // 文件名 + 文件类型 + 创建者
        let size = try length(q, 8)
        q += 8
        var item = LinkedFile(kind: kind, uuid: uuid, name: name)
        if kind == "liFD", let s = find(Array("8BPS".utf8), q, min(de, q + (1 << 20))) {
            item.data = s..<min(s + size, de)
        }
        return item
    }

    private func parseDocument(base: Int, limit: Int, prefix: String, depth: Int) throws {
        guard matches(base, "8BPS") else { throw PSDError.notPSD }
        let version = try u16(base + 4)
        guard version == 1 || version == 2 else { throw PSDError.unsupportedVersion(version) }
        let lw = version == 1 ? 4 : 8

        var p = base + 26
        p += 4 + (try length(p, 4)) // 颜色模式数据
        p += 4 + (try length(p, 4)) // 图像资源
        let lmLen = try length(p, lw)
        p += lw
        guard lmLen > 0 else { return }
        let lmEnd = min(p + lmLen, limit)

        let liLen = try length(p, lw)
        p += lw
        var recs = liLen > 0 ? try layerRecords(p, p + liLen, version) : []
        p += liLen + (liLen & 1)
        if p + 4 <= lmEnd { p += 4 + (try length(p, 4)) } // 全局蒙版

        var links: [LinkedFile] = []
        for (key, r) in blocks(p, lmEnd, version) {
            if (key == "Lr16" || key == "Lr32") && recs.isEmpty {
                // 16/32 位文档的图层信息放在这里
                for off in [0, lw] {
                    if let got = try? layerRecords(r.lowerBound + off, r.upperBound, version) {
                        recs = got
                        break
                    }
                }
            } else if ["lnk2", "lnk3", "lnkD", "lnkE"].contains(key) {
                links += linkedFiles(r)
            }
        }

        for rec in recs {
            guard let r = rec.engine else { continue }
            covered.append(r)
            var parser = EngineParser(b, from: r.lowerBound, end: r.upperBound)
            guard let ed = try? parser.value() else { continue }
            let (fonts, text) = fontsInEngine(ed)
            layers.append(TextLayer(path: prefix + (rec.path.isEmpty ? rec.name : rec.path),
                                    text: text, fonts: fonts, hidden: rec.hidden))
        }

        for lf in links {
            let ascii = Array(lf.uuid.utf8)
            let wide = lf.uuid.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            let owners = recs.filter { rec in
                !ascii.isEmpty && rec.linkBlocks.contains { r in
                    find(ascii, r.lowerBound, r.upperBound) != nil || find(wide, r.lowerBound, r.upperBound) != nil
                }
            }.map { $0.path.isEmpty ? $0.name : $0.path }

            if lf.kind != "liFD" {
                externals.append(ExternalLink(layer: prefix + (owners.first ?? "?"), file: lf.name))
                continue
            }
            guard let d = lf.data, depth < Self.maxSmartObjectDepth else { continue }
            var label = owners.first ?? "智能对象「\(lf.name)」"
            if owners.count > 1 { label += " 等\(owners.count)个图层" }
            try? parseDocument(base: d.lowerBound, limit: d.upperBound, prefix: prefix + label + " ▸ ", depth: depth + 1)
        }
    }

    /// 兜底：全文找漏掉的排版数据
    private func scanLeftovers() {
        let needle = Array("/EngineDict".utf8)
        var pos = 0
        while let k = find(needle, pos, b.count) {
            pos = k + needle.count
            var s = k - 2
            while s >= max(0, k - 32), !(b[s] == 0x3C && b[s + 1] == 0x3C) { s -= 1 }
            guard s >= max(0, k - 32), !covered.contains(where: { $0.contains(s) }) else { continue }
            var parser = EngineParser(b, from: s, end: b.count)
            guard let ed = try? parser.value() else { continue }
            covered.append(s..<parser.i)
            let (fonts, text) = fontsInEngine(ed)
            layers.append(TextLayer(path: "（未定位到图层的文字）", text: text, fonts: fonts, hidden: false))
        }
    }
}
