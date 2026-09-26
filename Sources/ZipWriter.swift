import Foundation
import zlib

struct ZipError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 最小 zip 写入：文件名带 UTF-8 标记（Windows 解压中文名不乱码），支持 ZIP64（超过 4GB 的 PSB）。
/// macOS 自带的 ditto / zip 都不设 UTF-8 标记，所以自己写。
final class ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let method: UInt16
        let crc: UInt32
        let csize: UInt64
        let usize: UInt64
        let offset: UInt64
        let zip64: Bool
    }

    /// 超过这个值的大小 / 偏移量要用 ZIP64 字段记录；只有测试会调小它
    static var limit: UInt64 = 0xFFFF_FFFF

    private let out: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        out = try FileHandle(forWritingTo: url)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        dosDate = UInt16((((c.year ?? 1980) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    func add(data: Data, name: String) throws {
        try add(name: name, compress: true, size: UInt64(data.count)) { emit in try emit(data) }
    }

    func add(file: URL, name: String, compress: Bool, progress: ((UInt64) -> Void)? = nil) throws {
        let size = fileSize(file.path)
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        try add(name: name, compress: compress, size: size) { emit in
            var done: UInt64 = 0
            while let chunk = try fh.read(upToCount: 4 << 20), !chunk.isEmpty {
                try emit(chunk)
                done += UInt64(chunk.count)
                progress?(done)
            }
        }
    }

    private func write(_ d: Data) throws {
        try out.write(contentsOf: d)
        offset += UInt64(d.count)
    }

    private func add(name: String, compress: Bool, size: UInt64,
                     body: ((Data) throws -> Void) throws -> Void) throws {
        let nameBytes = Array(name.utf8)
        let zip64 = size >= Self.limit
        // 大文件只存储不压缩，压缩后大小也就不会越过 4GB 边界
        let method: UInt16 = (compress && size < (1 << 30)) ? 8 : 0
        let headerOffset = offset

        var h = Data()
        h.le32(0x0403_4B50)
        h.le16(zip64 ? 45 : 20)
        h.le16(0x0800) // UTF-8 文件名
        h.le16(method)
        h.le16(dosTime)
        h.le16(dosDate)
        h.le32(0) // CRC，写完回填
        h.le32(zip64 ? 0xFFFF_FFFF : 0)
        h.le32(zip64 ? 0xFFFF_FFFF : 0)
        h.le16(UInt16(nameBytes.count))
        h.le16(zip64 ? 20 : 0)
        h.append(contentsOf: nameBytes)
        if zip64 {
            h.le16(0x0001)
            h.le16(16)
            h.le64(0)
            h.le64(0)
        }
        try write(h)

        var crc: uLong = 0
        var csize: UInt64 = 0
        var usize: UInt64 = 0

        var z = z_stream()
        if method == 8 {
            guard deflateInit2_(&z, 6, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw ZipError(message: "压缩初始化失败")
            }
        }
        defer { if method == 8 { deflateEnd(&z) } }
        var buffer = [UInt8](repeating: 0, count: 1 << 18)

        func deflateChunk(_ input: Data, finish: Bool) throws {
            try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                z.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                z.avail_in = uInt(src.count)
                while true {
                    var ret: Int32 = Z_OK
                    let produced = buffer.withUnsafeMutableBufferPointer { ob -> Int in
                        z.next_out = ob.baseAddress
                        z.avail_out = uInt(ob.count)
                        ret = deflate(&z, finish ? Z_FINISH : Z_NO_FLUSH)
                        return ob.count - Int(z.avail_out)
                    }
                    if produced > 0 {
                        try write(Data(buffer[0..<produced]))
                        csize += UInt64(produced)
                    }
                    if ret == Z_STREAM_ERROR { throw ZipError(message: "压缩失败") }
                    if finish ? ret == Z_STREAM_END : z.avail_out != 0 { break }
                }
            }
        }

        try body { chunk in
            usize += UInt64(chunk.count)
            crc = chunk.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            if method == 8 {
                try deflateChunk(chunk, finish: false)
            } else {
                try write(chunk)
                csize += UInt64(chunk.count)
            }
        }
        if method == 8 { try deflateChunk(Data(), finish: true) }

        // 回填 CRC 和大小
        let end = offset
        try out.seek(toOffset: headerOffset + 14)
        var patch = Data()
        patch.le32(UInt32(crc))
        if zip64 {
            try out.write(contentsOf: patch)
            try out.seek(toOffset: headerOffset + 30 + UInt64(nameBytes.count) + 4)
            var ext = Data()
            ext.le64(usize)
            ext.le64(csize)
            try out.write(contentsOf: ext)
        } else {
            guard usize < Self.limit else { throw ZipError(message: "文件在打包过程中被修改") }
            patch.le32(UInt32(csize))
            patch.le32(UInt32(usize))
            try out.write(contentsOf: patch)
        }
        try out.seek(toOffset: end)

        entries.append(Entry(name: nameBytes, method: method, crc: UInt32(crc),
                             csize: csize, usize: usize, offset: headerOffset, zip64: zip64))
    }

    func finish() throws {
        let cdStart = offset
        for e in entries {
            let bigU = e.zip64 || e.usize >= Self.limit, bigC = e.zip64 || e.csize >= Self.limit
            let bigO = e.offset >= Self.limit
            var extra = Data()
            if bigU || bigC || bigO {
                var f = Data()
                if bigU { f.le64(e.usize) }
                if bigC { f.le64(e.csize) }
                if bigO { f.le64(e.offset) }
                extra.le16(0x0001)
                extra.le16(UInt16(f.count))
                extra.append(f)
            }
            var c = Data()
            c.le32(0x0201_4B50)
            c.le16(0x0300 | 45) // Unix，4.5
            c.le16(extra.isEmpty ? 20 : 45)
            c.le16(0x0800)
            c.le16(e.method)
            c.le16(dosTime)
            c.le16(dosDate)
            c.le32(e.crc)
            c.le32(bigC ? 0xFFFF_FFFF : UInt32(e.csize))
            c.le32(bigU ? 0xFFFF_FFFF : UInt32(e.usize))
            c.le16(UInt16(e.name.count))
            c.le16(UInt16(extra.count))
            c.le16(0) // 注释
            c.le16(0) // 磁盘号
            c.le16(0) // 内部属性
            c.le32(UInt32(0o100644) << 16)
            c.le32(bigO ? 0xFFFF_FFFF : UInt32(e.offset))
            c.append(contentsOf: e.name)
            c.append(extra)
            try write(c)
        }
        let cdSize = offset - cdStart
        let n = UInt64(entries.count)

        if n >= 0xFFFF || cdStart >= Self.limit || cdSize >= Self.limit {
            let z64 = offset
            var r = Data()
            r.le32(0x0606_4B50)
            r.le64(44)
            r.le16(0x0300 | 45)
            r.le16(45)
            r.le32(0)
            r.le32(0)
            r.le64(n)
            r.le64(n)
            r.le64(cdSize)
            r.le64(cdStart)
            r.le32(0x0706_4B50)
            r.le32(0)
            r.le64(z64)
            r.le32(1)
            try write(r)
        }

        var e = Data()
        e.le32(0x0605_4B50)
        e.le16(0)
        e.le16(0)
        e.le16(UInt16(min(n, 0xFFFF)))
        e.le16(UInt16(min(n, 0xFFFF)))
        e.le32(cdSize >= Self.limit ? 0xFFFF_FFFF : UInt32(cdSize))
        e.le32(cdStart >= Self.limit ? 0xFFFF_FFFF : UInt32(cdStart))
        e.le16(0)
        try write(e)
        try out.close()
    }

    func abandon() {
        try? out.close()
    }
}
