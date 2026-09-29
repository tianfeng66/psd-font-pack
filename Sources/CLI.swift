import Foundation

/// 命令行模式：PSD字体打包.app/Contents/MacOS/PSDFontPack --cli [选项] 文件或文件夹…
enum CLI {
    static let usage = """
    用法：PSDFontPack --cli [选项] <PSD/PSB 文件或文件夹>…
      --check            只检查，不下载、不打包
      --no-download      缺失字体不自动下载
      --no-system        不打包 Mac 系统字体（苹方等，默认打包）
      --no-psd           包里只放字体
      --library <目录>   缺失字体先从这个字体库文件夹里找（可写多次；默认用 App 里设置的字体库）
      --separate         多个 PSD 各打一个包（默认合并）
      -o <目录>          输出目录（默认和 PSD 放在一起）
    退出码：0 正常，2 有字体缺失，1 出错
    """

    static func run(_ args: [String]) -> Never {
        var check = false, download = true, separate = false
        var options = PackOptions(includeSystem: true)
        var outDir: URL?
        var inputs: [URL] = []
        var libraries: [String] = []
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--check": check = true
            case "--no-download": download = false
            case "--include-system": options.includeSystem = true
            case "--no-system": options.includeSystem = false
            case "--no-psd": options.includePSD = false
            case "--separate": separate = true
            case "--library": if let d = it.next() { libraries.append(URL(fileURLWithPath: (d as NSString).expandingTildeInPath).path) }
            case "-o": outDir = it.next().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            case "-h", "--help": print(usage); exit(0)
            default: inputs.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
            }
        }
        let psds = Pipeline.expand(inputs)
        guard !psds.isEmpty else {
            print(inputs.isEmpty ? usage : "没有找到 PSD/PSB 文件")
            exit(1)
        }

        Task {
            let library = FontLibrary(roots: libraries.isEmpty ? FontLibrary.folders : libraries)
            var a = Pipeline.analyze(psds, locator: FontLocator(), library: library)
            for (i, url) in psds.enumerated() {
                print("读取 \(url.lastPathComponent)：\(a.textLayerCounts[i]) 个文字图层")
            }
            for f in a.failures { print("✗ \(f.url.lastPathComponent)：\(f.message)") }

            if download && !check {
                let downloader = Downloader()
                for i in a.fonts.indices where a.fonts[i].section(includeSystem: options.includeSystem) == .missing {
                    print("下载 \(a.fonts[i].ps) …")
                    do {
                        let r = try await downloader.fetch(a.fonts[i].ps) { print("  \($0)") }
                        a.fonts[i].download = r
                        print("  ✓ \(r.source)")
                    } catch {
                        a.fonts[i].downloadError = Downloader.describe(error)
                        print("  ✗ \(Downloader.describe(error))")
                    }
                }
            }

            let groups: [[Int]] = separate ? psds.indices.map { [$0] } : [Array(psds.indices)]
            var code: Int32 = 0
            for g in groups {
                print("")
                print(Pipeline.report(a, psdIndices: g, options: options, arcnames: [:]))
                let only = Set(g)
                if a.fonts.contains(where: { f in
                    f.section(includeSystem: options.includeSystem) == .missing && f.usages.contains { only.contains($0.psd) }
                }) { code = 2 }
                guard !check else { continue }
                let first = psds[g[0]]
                let singleFolder = inputs.count == 1 && inputs[0].hasDirectoryPath ? inputs[0].lastPathComponent : nil
                let name = g.count == 1 ? first.deletingPathExtension().lastPathComponent
                    : singleFolder ?? "\(first.deletingPathExtension().lastPathComponent)等\(g.count)个文件"
                do {
                    let out = try Pipeline.package(a, psdIndices: g, name: name,
                                                   outDir: outDir ?? first.deletingLastPathComponent(), options: options)
                    print("✓ 打包完成：\(out.path)")
                } catch {
                    print("✗ 打包失败：\(error.localizedDescription)")
                    code = 1
                }
            }
            exit(code)
        }
        dispatchMain()
    }
}
