import Foundation

/// 文字图层的排版数据（EngineData）是一段类 PostScript 文本：
/// << /Key value >>、[ ... ]、(字符串)、/名字、数字、true/false。
/// 字符串按字节转义 ( ) \ ，内容通常是带 FE FF 头的 UTF-16BE。
indirect enum EValue {
    case dict([String: EValue])
    case list([EValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case name(String)

    subscript(key: String) -> EValue? {
        if case .dict(let d) = self { return d[key] }
        return nil
    }

    var items: [EValue] {
        if case .list(let l) = self { return l }
        return []
    }

    var int: Int? {
        if case .number(let n) = self, n.rounded() == n, abs(n) < 1e9 { return Int(n) }
        return nil
    }

    var text: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

struct EngineError: Error {}

struct EngineParser {
    private let b: UnsafeBufferPointer<UInt8>
    private(set) var i: Int
    private let end: Int

    init(_ b: UnsafeBufferPointer<UInt8>, from: Int, end: Int) {
        self.b = b
        self.i = from
        self.end = min(end, b.count)
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x00
    }

    private static func isDelimiter(_ c: UInt8) -> Bool {
        isSpace(c) || c == 0x2F || c == 0x5B || c == 0x5D || c == 0x3C || c == 0x3E || c == 0x28 || c == 0x29
    }

    private mutating func skipSpace() {
        while i < end && Self.isSpace(b[i]) { i += 1 }
    }

    private mutating func word() -> String {
        let s = i
        while i < end && !Self.isDelimiter(b[i]) { i += 1 }
        return String(decoding: UnsafeBufferPointer(rebasing: b[s..<i]), as: UTF8.self)
    }

    mutating func value(depth: Int = 0) throws -> EValue {
        guard depth < 64 else { throw EngineError() }
        skipSpace()
        guard i < end else { throw EngineError() }
        switch b[i] {
        case 0x3C: // <<
            guard i + 1 < end, b[i + 1] == 0x3C else { throw EngineError() }
            i += 2
            var d: [String: EValue] = [:]
            while true {
                skipSpace()
                guard i < end else { throw EngineError() }
                if b[i] == 0x3E { i += 2; return .dict(d) }
                guard b[i] == 0x2F else { throw EngineError() }
                i += 1
                let key = word()
                d[key] = try value(depth: depth + 1)
            }
        case 0x5B: // [
            i += 1
            var out: [EValue] = []
            while true {
                skipSpace()
                guard i < end else { throw EngineError() }
                if b[i] == 0x5D { i += 1; return .list(out) }
                out.append(try value(depth: depth + 1))
            }
        case 0x28: // (
            return .string(try string())
        case 0x2F: // /
            i += 1
            return .name(word())
        default:
            let t = word()
            guard !t.isEmpty else { throw EngineError() }
            if t == "true" { return .bool(true) }
            if t == "false" { return .bool(false) }
            if let n = Double(t) { return .number(n) }
            return .name(t)
        }
    }

    private mutating func string() throws -> String {
        i += 1
        var raw: [UInt8] = []
        while true {
            guard i < end else { throw EngineError() }
            let c = b[i]
            if c == 0x5C {
                guard i + 1 < end else { throw EngineError() }
                raw.append(b[i + 1])
                i += 2
            } else if c == 0x29 {
                i += 1
                break
            } else {
                raw.append(c)
                i += 1
            }
        }
        if raw.count >= 2, raw[0] == 0xFE, raw[1] == 0xFF {
            var units: [UInt16] = []
            units.reserveCapacity(raw.count / 2)
            var j = 2
            while j + 1 < raw.count {
                units.append(UInt16(raw[j]) << 8 | UInt16(raw[j + 1]))
                j += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
        return String(bytes: raw, encoding: .isoLatin1) ?? ""
    }
}

let ignoredFonts: Set<String> = ["AdobeInvisFont"]

/// 返回文字实际用到的字体 PostScript 名和文字内容。
/// FontSet 里还会带着 MyriadPro、AdobeInvisFont 这类没真正用上的默认项，
/// 所以按样式段 RunArray 引用的字体序号来算。
func fontsInEngine(_ ed: EValue) -> (fonts: [String], text: String) {
    let rd = ed["ResourceDict"]
    let names: [String?] = (rd?["FontSet"]?.items ?? []).map { $0["Name"]?.text }

    var fallback: Int?
    let sheets = rd?["StyleSheetSet"]?.items ?? []
    let normal = rd?["TheNormalStyleSheet"]?.int ?? 0
    if normal >= 0, normal < sheets.count {
        fallback = sheets[normal]["StyleSheetData"]?["Font"]?.int
    }

    let engine = ed["EngineDict"]
    let runs = engine?["StyleRun"]?["RunArray"]?.items ?? []
    var idxs = runs.compactMap { $0["StyleSheet"]?["StyleSheetData"]?["Font"]?.int ?? fallback }
    if idxs.isEmpty, let f = fallback { idxs = [f] }

    var used = idxs.compactMap { $0 >= 0 && $0 < names.count ? names[$0] : nil }
    if used.isEmpty { used = names.compactMap { $0 } }

    var seen = Set<String>()
    var out: [String] = []
    for n in used where !n.isEmpty && !ignoredFonts.contains(n) && seen.insert(n).inserted {
        out.append(n)
    }
    return (out, engine?["Editor"]?["Text"]?.text ?? "")
}
