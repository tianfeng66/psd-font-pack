import SwiftUI
import AppKit

struct PackResult {
    let files: [URL]
    let missing: Int
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var analysis = Analysis()
    @Published private(set) var status: String?
    @Published var result: PackResult?
    @Published var alert: String?

    @Published var autoPack: Bool { didSet { save("autoPack", autoPack) } }
    @Published var autoDownload: Bool { didSet { save("autoDownload", autoDownload) } }
    @Published var installDownloaded: Bool { didSet { save("installDownloaded", installDownloaded) } }
    @Published var includeSystem: Bool { didSet { save("includeSystem", includeSystem); result = nil } }
    @Published var includePSD: Bool { didSet { save("includePSD", includePSD); result = nil } }
    @Published var separatePackages: Bool { didSet { save("separatePackages", separatePackages); result = nil } }
    @Published private(set) var libraryFolders: [String] = FontLibrary.folders

    private let locator = FontLocator()
    private let downloader = Downloader()
    private var folderName: String?
    private var generation = 0

    private init() {
        let d = UserDefaults.standard
        autoPack = d.object(forKey: "autoPack") as? Bool ?? true
        autoDownload = d.object(forKey: "autoDownload") as? Bool ?? true
        installDownloaded = d.bool(forKey: "installDownloaded")
        includeSystem = d.bool(forKey: "includeSystem")
        includePSD = d.object(forKey: "includePSD") as? Bool ?? true
        separatePackages = d.bool(forKey: "separatePackages")
    }

    private func save(_ key: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: key) }

    var isEmpty: Bool { analysis.psds.isEmpty }
    var isBusy: Bool { status != nil }

    func sections() -> [(Section, [FontEntry])] {
        Section.allCases.compactMap { s in
            let g = analysis.fonts.filter { $0.section(includeSystem: includeSystem) == s }
            return g.isEmpty ? nil : (s, g)
        }
    }

    func count(_ pred: (Section) -> Bool) -> Int {
        analysis.fonts.filter { pred($0.section(includeSystem: includeSystem)) }.count
    }

    // MARK: - 打开

    func chooseFiles(append: Bool = false) {
        let panel = NSOpenPanel()
        panel.message = "选择要打包字体的 PSD / PSB 文件或文件夹"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK { open(panel.urls, append: append) }
    }

    /// 拖入 / 拖到程序坞图标：自动打包模式下每次拖入都是一批新任务，打完就结束；
    /// 手动模式下追加到当前列表，攒齐了再点打包。
    func open(_ urls: [URL], append: Bool? = nil) {
        let psds = Pipeline.expand(urls)
        guard !psds.isEmpty else {
            alert = "没有找到 PSD / PSB 文件。"
            return
        }
        let keep = (append ?? !autoPack) && !isEmpty
        let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        folderName = (!keep && urls.count == 1 && dirs.count == 1) ? dirs[0].lastPathComponent : nil
        let base = keep ? analysis.psds : []
        var seen = Set(base.map(\.path))
        let all = base + psds.filter { seen.insert($0.path).inserted }
        Task { await run(all) }
    }

    func clear() {
        generation += 1
        analysis = Analysis()
        result = nil
        status = nil
        folderName = nil
    }

    func remove(_ url: URL) {
        let rest = analysis.psds.filter { $0 != url }
        if rest.isEmpty { clear() } else { Task { await run(rest, pack: false) } }
    }

    private func run(_ psds: [URL], pack: Bool = true) async {
        generation += 1
        let gen = generation
        result = nil
        status = "正在读取 \(psds.count) 个文件…"
        let locator = self.locator
        let folders = libraryFolders
        let a = await Task.detached { Pipeline.analyze(psds, locator: locator, library: FontLibrary(roots: folders)) }.value
        guard gen == generation else { return }
        analysis = a
        status = nil
        if installDownloaded {
            for f in a.fonts where f.found == nil { if let p = f.download?.path { _ = Pipeline.installToUserFonts(p) } }
        }
        if autoDownload { await downloadMissing() }
        guard gen == generation else { return }
        if pack && autoPack && !analysis.fonts.isEmpty { self.pack() }
    }

    // MARK: - 字体库

    func addLibraryFolder() {
        let panel = NSOpenPanel()
        panel.message = "选择存放字体的文件夹（会包含所有子文件夹）"
        panel.prompt = "设为字体库"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        setLibraryFolders(libraryFolders + panel.urls.map(\.path).filter { !libraryFolders.contains($0) })
    }

    func removeLibraryFolder(_ path: String) {
        setLibraryFolders(libraryFolders.filter { $0 != path })
    }

    private func setLibraryFolders(_ folders: [String]) {
        libraryFolders = folders
        FontLibrary.folders = folders
        if !isEmpty { Task { await run(analysis.psds) } }
    }

    // MARK: - 下载

    func downloadMissing() async {
        let gen = generation
        let targets = analysis.fonts.filter { $0.section(includeSystem: includeSystem) == .missing && !$0.downloading }.map(\.ps)
        for ps in targets {
            guard gen == generation else { return }
            await download(ps)
        }
    }

    func retry(_ ps: String) {
        Task {
            await download(ps)
            let ok = analysis.fonts.first { $0.ps == ps }?.download != nil
            if ok && autoPack && !isBusy { pack() }
        }
    }

    private func download(_ ps: String) async {
        let gen = generation
        guard let i = analysis.fonts.firstIndex(where: { $0.ps == ps }) else { return }
        analysis.fonts[i].downloading = true
        analysis.fonts[i].downloadError = nil
        status = "正在下载缺失字体 \(ps)…"
        let report: @Sendable (String) -> Void = { s in Task { @MainActor in AppModel.shared.status = s } }
        let outcome: Result<DownloadResult, Error>
        do { outcome = .success(try await downloader.fetch(ps, status: report)) } catch { outcome = .failure(error) }
        guard gen == generation, let j = analysis.fonts.firstIndex(where: { $0.ps == ps }) else { return }
        switch outcome {
        case .success(let r):
            analysis.fonts[j].download = r
            if installDownloaded { _ = Pipeline.installToUserFonts(r.path) }
            result = nil // 之前的包里没有这款字体，需要重新打包
        case .failure(let e):
            analysis.fonts[j].downloadError = Downloader.describe(e)
        }
        analysis.fonts[j].downloading = false
        status = nil
    }

    // MARK: - 打包

    func pack(chooseLocation: Bool = false) {
        if chooseLocation {
            guard let dir = askDirectory("选择压缩包的保存位置") else { return }
            pack(into: dir)
        } else {
            pack(into: nil)
        }
    }

    private func pack(into outDir: URL?) {
        let a = analysis
        let options = PackOptions(includeSystem: includeSystem, includePSD: includePSD)
        let stem = { (i: Int) in a.psds[i].deletingPathExtension().lastPathComponent }
        let groups: [(indices: [Int], name: String)]
        if a.psds.count > 1 && separatePackages {
            groups = a.psds.indices.map { ([$0], stem($0)) }
        } else if a.psds.count == 1 {
            groups = [([0], stem(0))]
        } else {
            groups = [(Array(a.psds.indices), folderName ?? "\(stem(0))等\(a.psds.count)个文件")]
        }
        let missing = count { $0 == .missing }
        let gen = generation

        status = "正在打包…"
        Task {
            let outcome = await Task.detached { () -> Result<[URL], Error> in
                do {
                    let files = try groups.map { g in
                        try Pipeline.package(a, psdIndices: g.indices, name: g.name,
                                             outDir: outDir ?? a.psds[g.indices[0]].deletingLastPathComponent(),
                                             options: options) { s in
                            Task { @MainActor in AppModel.shared.status = s }
                        }
                    }
                    return .success(files)
                } catch {
                    return .failure(error)
                }
            }.value
            guard gen == generation else { return }
            status = nil
            switch outcome {
            case .success(let files):
                result = PackResult(files: files, missing: missing)
                if missing == 0 {
                    reveal(files)
                } else {
                    // 有缺失字体时停在窗口里，让红色提示被看到
                    NSSound.beep()
                    NSApp.activate(ignoringOtherApps: true)
                }
            case .failure(let error):
                if outDir == nil, (error as? CocoaError)?.code == .fileWriteNoPermission {
                    // PSD 所在位置写不进去（只读盘、网络盘等），直接让用户选个地方
                    if let dir = askDirectory("PSD 所在的文件夹不能写入，请选择压缩包的保存位置") {
                        pack(into: dir)
                    }
                } else {
                    alert = "打包失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func askDirectory(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "保存到这里"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = analysis.psds.first?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
