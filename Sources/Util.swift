import Foundation

/// 正则第一处匹配的各分组（未参与匹配的分组为 nil）
func regexGroups(_ pattern: String, _ s: String) -> [String?]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        Range(m.range(at: i), in: s).map { String(s[$0]) }
    }
}

func regexAll(_ pattern: String, _ s: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
        Range($0.range, in: s).map { String(s[$0]) }
    }
}

func humanSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

func fileSize(_ path: String) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
}

extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
