import Foundation

/// 用户自己攒的字体文件夹（字体库）。本机没装的字体先按 PostScript 名在这里找，找到就直接打包，
/// 找不到才联网下载。字体名读出来后缓存起来，下次只核对文件的修改时间和大小。
final class FontLibrary {
    static let defaultsKey = "libraryFolders"

    static var folders: [String] {
        get { UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private struct Entry: Codable {
        let mtime: Double
        let size: UInt64
        let names: [String]
    }

    private static let cacheURL = Downloader.cacheDir.appendingPathComponent("library-index.json")

    let roots: [String]
    private var index: [String: String]?

    init(roots: [String] = FontLibrary.folders) {
        self.roots = roots.filter { FileManager.default.fileExists(atPath: $0) }
    }

    var isEmpty: Bool { roots.isEmpty }

    func find(_ ps: String) -> DownloadResult? {
        guard !roots.isEmpty else { return nil }
        if index == nil { index = build() }
        guard let path = index?[ps.lowercased()] else { return nil }
        let root = roots.first { path.hasPrefix($0 + "/") }
        let shown = root.map { (($0 as NSString).lastPathComponent as NSString).appendingPathComponent(String(path.dropFirst($0.count + 1))) }
            ?? (path as NSString).abbreviatingWithTildeInPath
        return DownloadResult(path: path, source: "字体库 \(shown)", note: "")
    }

    private func build() -> [String: String] {
        let fm = FileManager.default
        var cache: [String: Entry] = [:]
        if let data = try? Data(contentsOf: Self.cacheURL) {
            cache = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
        var fresh: [String: Entry] = [:]
        var idx: [String: String] = [:]
        for root in roots {
            let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var files: [URL] = []
            while let url = e?.nextObject() as? URL {
                if fontExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
            }
            // 同名字体出现多次时，取路径排序靠前的那个，结果稳定
            files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            for url in files {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = UInt64(v?.fileSize ?? 0)
                let entry: Entry
                if let c = cache[url.path], c.mtime == mtime, c.size == size {
                    entry = c
                } else {
                    entry = Entry(mtime: mtime, size: size, names: FontLocator.postScriptNames(in: url))
                }
                fresh[url.path] = entry
                for n in entry.names where idx[n.lowercased()] == nil {
                    idx[n.lowercased()] = url.path
                }
            }
        }
        try? fm.createDirectory(at: Downloader.cacheDir, withIntermediateDirectories: true)
        // 其他字体库文件夹的缓存也留着，切换回来不用重读
        let merged = cache.filter { k, _ in !roots.contains { k.hasPrefix($0 + "/") } }.merging(fresh) { $1 }
        if let data = try? JSONEncoder().encode(merged) { try? data.write(to: Self.cacheURL, options: .atomic) }
        return idx
    }
}
