import Foundation

struct DownloadResult {
    let path: String
    let source: String
    let note: String
}

struct DownloadFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 缺失字体的自动下载：先查常用免费中文字体的官方地址，再查 Google Fonts。
/// 系统代理设置会自动生效；Google 官网连不上时改走 CSS 接口和国内镜像。
actor Downloader {
    static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PSD字体打包", isDirectory: true)

    private static let metaURL = "https://fonts.google.com/metadata/fonts"
    private static let listURL = "https://fonts.google.com/download/list?family="
    private static let cssHosts = ["https://fonts.googleapis.com", "https://fonts.loli.net"]
    private static let metaTTL: TimeInterval = 7 * 86400

    private let dir = Downloader.cacheDir.appendingPathComponent("downloads", isDirectory: true)
    private let session: URLSession
    private var families: [String]?
    private var metaTried = false

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 900
        // Google 的 CSS 接口只对非浏览器 UA 返回 TTF
        cfg.httpAdditionalHeaders = ["User-Agent": "curl/8.7.1"]
        session = URLSession(configuration: cfg)
    }

    func fetch(_ ps: String, status: @escaping @Sendable (String) -> Void) async throws -> DownloadResult {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for ext in ["otf", "ttf"] {
            let cached = dir.appendingPathComponent("\(ps).\(ext)")
            if FileManager.default.fileExists(atPath: cached.path), Self.fileContains(cached, ps) {
                return DownloadResult(path: cached.path, source: "之前下载过", note: "")
            }
        }

        var errors: [String] = []
        for (url, source) in builtinURLs(ps) {
            let dest = dir.appendingPathComponent("\(ps).\((url as NSString).pathExtension)")
            do {
                try await download(url, to: dest)
                return DownloadResult(path: dest.path, source: source, note: "")
            } catch {
                errors.append("\(source)：\(Self.describe(error))")
            }
        }

        let file: URL, source: String
        do {
            (file, source) = try await google(ps, status: status)
        } catch {
            errors.append(Self.describe(error))
            throw DownloadFailure(message: errors.joined(separator: "；"))
        }
        var note = ""
        if !Self.fileContains(file, ps) {
            let names = FontLocator.postScriptNames(in: file)
            note = "文件内名称为 \(names.first ?? "未知")，与 PSD 不完全一致，Photoshop 可能仍提示缺失"
        }
        return DownloadResult(path: file.path, source: source, note: note)
    }

    static func fileContains(_ url: URL, _ ps: String) -> Bool {
        FontLocator.postScriptNames(in: url).contains { $0.caseInsensitiveCompare(ps) == .orderedSame }
    }

    static func describe(_ error: Error) -> String {
        if let f = error as? DownloadFailure { return f.message }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return "连接超时"
            case .notConnectedToInternet: return "没有网络"
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .secureConnectionFailed,
                 .dnsLookupFailed:
                return "连不上服务器"
            default: return u.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - 网络

    private func get(_ url: String, timeout: TimeInterval = 30) async throws -> Data {
        guard let u = URL(string: url) else { throw DownloadFailure(message: "地址无效") }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DownloadFailure(message: "服务器返回 \(code)") }
        return data
    }

    private func download(_ url: String, to dest: URL) async throws {
        guard let u = URL(string: url) else { throw DownloadFailure(message: "地址无效") }
        let (tmp, resp) = try await session.download(for: URLRequest(url: u))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw DownloadFailure(message: code == 404 ? "没有这个文件" : "服务器返回 \(code)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    // MARK: - 内置免费字体源

    private func builtinURLs(_ ps: String) -> [(String, String)] {
        var out: [(String, String)] = []
        if let g = regexGroups(#"^SourceHan(Sans|Serif)(SC|TC|HC|K|CN|TW|HK|JP|KR)?-\w+$"#, ps), let kind = g[1] {
            let region = g[2]
            let base = "https://raw.githubusercontent.com/adobe-fonts/source-han-\(kind.lowercased())/release"
            let label = kind == "Sans" ? "思源黑体（Adobe 官方）" : "思源宋体（Adobe 官方）"
            let full: [String: String] = ["SC": "SimplifiedChinese", "TC": "TraditionalChinese",
                                          "HC": "TraditionalChineseHK", "K": "Korean"]
            if let region, let folder = full[region] {
                out.append(("\(base)/OTF/\(folder)/\(ps).otf", label))
            } else if region == nil {
                out.append(("\(base)/OTF/Japanese/\(ps).otf", label))
            }
            if let region, ["CN", "TW", "HK", "JP", "KR"].contains(region) {
                out.append(("\(base)/SubsetOTF/\(region)/\(ps).otf", label))
            }
        }
        if regexGroups(#"^LXGWWenKai(Mono)?(TC)?-\w+$"#, ps) != nil {
            out.append(("https://github.com/lxgw/LxgwWenKai/releases/latest/download/\(ps).ttf", "霞鹜文楷（GitHub）"))
        }
        return out
    }

    // MARK: - Google Fonts

    private func json(_ data: Data) throws -> [String: Any] {
        // 返回内容前面有 )]}' 防劫持前缀
        guard let i = data.firstIndex(of: UInt8(ascii: "{")),
              let obj = try JSONSerialization.jsonObject(with: data[i...]) as? [String: Any] else {
            throw DownloadFailure(message: "数据格式错误")
        }
        return obj
    }

    private func googleFamilies(status: @Sendable (String) -> Void) async -> [String]? {
        if let families { return families }
        if metaTried { return nil }
        metaTried = true

        let cache = Self.cacheDir.appendingPathComponent("google_families.json")
        var stale: [String]?
        if let d = try? Data(contentsOf: cache),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let fams = o["families"] as? [String], let t = o["time"] as? Double {
            if Date().timeIntervalSince1970 - t < Self.metaTTL {
                families = fams
                return fams
            }
            stale = fams
        }
        status("正在获取 Google Fonts 字体目录（首次较慢，之后缓存 7 天）…")
        do {
            let o = try json(try await get(Self.metaURL, timeout: 90))
            let fams = ((o["familyMetadataList"] as? [[String: Any]]) ?? []).compactMap { $0["family"] as? String }
            guard !fams.isEmpty else { throw DownloadFailure(message: "") }
            families = fams
            try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
            if let d = try? JSONSerialization.data(withJSONObject: ["time": Date().timeIntervalSince1970, "families": fams]) {
                try? d.write(to: cache)
            }
        } catch {
            families = stale
        }
        return families
    }

    private static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    private func guessFamily(_ ps: String, status: @Sendable (String) -> Void) async -> String? {
        let base = String(ps.split(separator: "-", maxSplits: 1).first ?? "").replacingOccurrences(of: "_", with: " ")
        let words = regexAll("[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+", base)
        guard !words.isEmpty else { return nil }
        if let fams = await googleFamilies(status: status) {
            var idx: [String: String] = [:]
            for f in fams { idx[Self.norm(f)] = f }
            // OpenSans_SemiCondensed → 依次试 OpenSansSemiCondensed、OpenSans
            for n in stride(from: words.count, to: 0, by: -1) {
                if let hit = idx[Self.norm(words[0..<n].joined())] { return hit }
            }
            return nil
        }
        return words.joined(separator: " ") // 拿不到目录时按驼峰拆词猜
    }

    private func google(_ ps: String, status: @escaping @Sendable (String) -> Void) async throws -> (URL, String) {
        guard let family = await guessFamily(ps, status: status) else {
            throw DownloadFailure(message: "免费字体库里没有这个字体")
        }
        let q = family.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? family
        if let data = try? await get(Self.listURL + q), let o = try? json(data),
           let refs = (o["manifest"] as? [String: Any])?["fileRefs"] as? [[String: Any]], !refs.isEmpty {
            let files = refs.compactMap { r -> (name: String, url: String)? in
                guard let n = r["filename"] as? String, let u = r["url"] as? String else { return nil }
                return (n, u)
            }
            var note = ""
            var pick = files.first {
                (($0.name as NSString).lastPathComponent as NSString).deletingPathExtension
                    .caseInsensitiveCompare(ps) == .orderedSame
            }
            if pick == nil {
                let italic = fontStyle(ps).italic
                pick = files.first { $0.name.contains("VariableFont") && $0.name.contains("Italic") == italic }
                note = "（可变字体，Photoshop 中请确认字重）"
            }
            guard let p = pick else { throw DownloadFailure(message: "Google Fonts「\(family)」里没有 \(ps) 这个字重") }
            let ext = (p.name as NSString).pathExtension
            let dest = dir.appendingPathComponent("\(ps).\(ext.isEmpty ? "ttf" : ext)")
            try await download(p.url, to: dest)
            return (dest, "Google Fonts「\(family)」\(note)")
        }

        let (weight, italic) = fontStyle(ps)
        let fq = family.replacingOccurrences(of: " ", with: "+")
        for host in Self.cssHosts {
            guard let d = try? await get("\(host)/css2?family=\(fq):ital,wght@\(italic ? 1 : 0),\(weight)", timeout: 20),
                  let css = String(data: d, encoding: .utf8),
                  let m = regexGroups(#"url\((https?://[^)]+\.(?:ttf|otf))\)"#, css), let u = m[1] else { continue }
            let dest = dir.appendingPathComponent("\(ps).\((u as NSString).pathExtension)")
            try await download(u, to: dest)
            return (dest, "Google Fonts「\(family)」（\(URL(string: host)?.host ?? host)）")
        }
        throw DownloadFailure(message: "连不上 Google Fonts（可开代理后重试）")
    }
}

private let weightWords: [(String, Int)] = [
    ("extralight", 200), ("ultralight", 200), ("semibold", 600), ("demibold", 600),
    ("extrabold", 800), ("ultrabold", 800), ("thin", 100), ("light", 300), ("medium", 500),
    ("bold", 700), ("heavy", 800), ("black", 900),
]

func fontStyle(_ ps: String) -> (weight: Int, italic: Bool) {
    let parts = ps.split(separator: "-", maxSplits: 1)
    let style = parts.count > 1 ? parts[1].lowercased() : ""
    let weight = weightWords.first { style.contains($0.0) }?.1 ?? 400
    return (weight, style.contains("italic") || style.contains("oblique"))
}

// MARK: - 缺失字体的获取提示

private let vendorHints: [(pattern: String, name: String, url: String)] = [
    ("^FZ", "方正字库（商用需购买授权）", "https://www.foundertype.com"),
    ("^HY", "汉仪字库（商用需购买授权）", "https://www.hanyi.com.cn"),
    ("^(MF|ZZGF)", "造字工房（商用需购买授权）", "https://www.makefont.com"),
    ("^Alibaba", "阿里巴巴普惠体（免费商用）", "https://www.alibabafonts.com"),
    ("^HarmonyOS", "HarmonyOS Sans（免费商用）", "https://developer.huawei.com/consumer/cn/design/resource/"),
    ("^MiSans", "MiSans（免费商用）", "https://hyperos.mi.com/font/"),
    ("^SmileySans", "得意黑（免费商用）", "https://github.com/atelier-anchor/smiley-sans/releases"),
]

struct Hint {
    let label: String
    let url: URL
}

func searchHints(_ name: String) -> [Hint] {
    let ps = FontLocator.variablePrefixes(name).first ?? name
    var out: [Hint] = vendorHints.compactMap { h in
        guard regexGroups(h.pattern, ps) != nil, let u = URL(string: h.url) else { return nil }
        return Hint(label: "可能是 \(h.name)", url: u)
    }
    let q = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
    if let u = URL(string: "https://www.baidu.com/s?wd=\(q(ps + " 字体"))") { out.append(Hint(label: "百度搜索", url: u)) }
    if let u = URL(string: "https://www.google.com/search?q=\(q(ps + " font"))") { out.append(Hint(label: "Google 搜索", url: u)) }
    return out
}
