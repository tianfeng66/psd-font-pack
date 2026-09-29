import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct SectionGroup: Identifiable {
    let section: Section
    let fonts: [FontEntry]
    var id: Int { section.rawValue }
}

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var dropTargeted = false
    @State private var showOptions = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isEmpty {
                dropZone
            } else {
                header
                Divider()
                fontList
            }
            if model.status != nil || model.result != nil {
                Divider()
                statusBar
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 580)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            load(providers)
            return true
        }
        .overlay {
            if dropTargeted && !model.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .alert("提示", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("好") {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.open(urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        }
    }

    // MARK: - 空状态

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "textformat")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("把 PSD / PSB 文件或文件夹拖到这里")
                .font(.title2.weight(.medium))
            Text(model.autoPack
                 ? "松手后自动完成：找出用到的字体 → 下载本机缺的 → 和 PSD 一起打成压缩包。\n压缩包就放在 PSD 旁边，打好后自动在访达里选中，直接发给对方即可。"
                 : "自动找出文件里用到的所有字体，和 PSD 一起打成压缩包发给别人。\n本机缺的字体会标红提醒，并尝试从免费字体库自动下载。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("选择文件…") { model.chooseFiles() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
            Text("小技巧：在程序坞图标上右键 → 选项 → 在程序坞中保留，以后直接把 PSD 拖到程序坞图标上就行，不用先打开窗口。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(24)
        )
    }

    // MARK: - 顶部：文件和汇总

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.analysis.psds.enumerated()), id: \.element) { i, url in
                            fileChip(url, layers: i < model.analysis.textLayerCounts.count ? model.analysis.textLayerCounts[i] : 0)
                        }
                    }
                }
                Button("添加…") { model.chooseFiles(append: true) }
                    .help("往当前列表里追加文件，合在一起打包")
                Button("清空") { model.clear() }
            }

            if !model.analysis.fonts.isEmpty {
                HStack(spacing: 14) {
                    Text("共用到 \(model.analysis.fonts.count) 款字体").font(.headline)
                    badge("将打包 \(model.count { $0.willPack })", .green)
                    let skipped = model.count { !$0.willPack && $0 != .missing }
                    if skipped > 0 { badge("无需打包 \(skipped)", .secondary) }
                    let missing = model.count { $0 == .missing }
                    if missing > 0 { badge("缺失 \(missing)", .red) }
                }
            }

            ForEach(model.analysis.failures, id: \.url) { f in
                Label("\(f.url.lastPathComponent)：\(f.message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(12)
    }

    private func fileChip(_ url: URL, layers: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.richtext").foregroundStyle(.secondary)
            Text(url.lastPathComponent).lineLimit(1)
            Text("\(layers) 个文字图层").foregroundStyle(.secondary)
            Button { model.remove(url) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除")
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - 字体列表

    private var fontList: some View {
        let a = model.analysis
        let multi = a.psds.count > 1
        return List {
            if a.fonts.isEmpty && !model.isBusy {
                Text("这些文件里没有文字图层（或文字已经栅格化），不需要打包字体。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(model.sections().map { SectionGroup(section: $0.0, fonts: $0.1) }) { g in
                SwiftUI.Section {
                    ForEach(g.fonts) { f in
                        FontRow(entry: f, section: g.section,
                                usage: f.usageLine(multi: multi, psdNames: a.psdNames),
                                onRetry: { model.retry(f.ps) })
                    }
                } header: {
                    Text(g.section.title)
                }
            }
            if !a.externals.isEmpty {
                SwiftUI.Section {
                    ForEach(Array(a.externals.enumerated()), id: \.offset) { _, e in
                        Label("\(e.link.file)   （图层：\(multi ? a.psdNames[e.psd] + ": " : "")\(e.link.layer)）",
                              systemImage: "link")
                            .font(.callout)
                    }
                } header: {
                    Text("注意：PSD 链接了外部文件，文件不在 PSD 里，需要另外发给对方")
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let s = model.status {
                ProgressView().controlSize(.small)
                Text(s).foregroundStyle(.secondary).lineLimit(1)
            } else if let r = model.result {
                if r.missing > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("已打包，但缺 \(r.missing) 款字体（见下方红色 ✗），对方打开会提示缺字体。装好字体后再拖一次 PSD 即可")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(r.files.count == 1 ? "打包完成：\(r.files[0].lastPathComponent)" : "打包完成：\(r.files.count) 个压缩包")
                        .lineLimit(1)
                }
                Button("在访达中显示") { model.reveal(r.files) }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 底栏：选项和打包按钮

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { showOptions.toggle() } label: {
                Label("选项", systemImage: "gearshape")
            }
            .popover(isPresented: $showOptions, arrowEdge: .top) { options }

            Text(optionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("打包到…") { model.pack(chooseLocation: true) }
                .disabled(!canPack)
                .help("自己选压缩包的保存位置")
            Button(model.result == nil ? "打包" : "重新打包") { model.pack() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canPack)
                .help("压缩包保存在 PSD 所在的文件夹")
        }
        .padding(12)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("拖进来就自动打包", isOn: $model.autoPack)
            Text("关闭后需要手动点「打包」，可以先多拖几批文件攒在一起")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 20).padding(.top, -6)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("字体库文件夹")
                Text("本机缺的字体先从这些文件夹（含子文件夹）里找，找到直接打包，找不到再联网下载")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.libraryFolders, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Button { model.removeLibraryFolder(path) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("不再使用这个文件夹")
                    }
                    .font(.callout)
                }
                Button("添加文件夹…") { model.addLibraryFolder() }
                    .padding(.top, 2)
            }
            Divider()
            Toggle("自动下载缺失字体", isOn: $model.autoDownload)
            Toggle("从字体库 / 网上补充的字体顺便装到本机", isOn: $model.installDownloaded)
            Divider()
            Toggle("压缩包里包含 PSD", isOn: $model.includePSD)
            Toggle("多个 PSD 时每个单独打一个包", isOn: $model.separatePackages)
            Toggle("打包 Mac 系统字体（苹方等）", isOn: $model.includeSystem)
            Text("对方用 Windows 时必须打开，否则会缺苹方等字体。注意：苹果字体的授权仅限在苹果设备上使用")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 20).padding(.top, -6)
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .frame(width: 380)
    }

    /// 选项收起来后，在按钮旁边提示当前和默认不一样的设置，避免忘了自己改过
    private var optionSummary: String {
        var s: [String] = []
        if !model.autoPack { s.append("手动打包") }
        if !model.autoDownload { s.append("不自动下载") }
        if !model.libraryFolders.isEmpty { s.append("字体库 \(model.libraryFolders.count) 个") }
        if model.installDownloaded { s.append("补充的字体装到本机") }
        if !model.includePSD { s.append("不含 PSD") }
        if model.separatePackages { s.append("每个 PSD 单独打包") }
        if !model.includeSystem { s.append("不含系统字体") }
        return s.joined(separator: " · ")
    }

    private var canPack: Bool {
        !model.isEmpty && !model.isBusy && !model.analysis.fonts.isEmpty
    }
}

private struct FontRow: View {
    let entry: FontEntry
    let section: Section
    let usage: String
    let onRetry: () -> Void

    private var icon: (String, Color) {
        switch section {
        case .packed, .adobeBundled: return ("checkmark.circle.fill", .green)
        case .downloaded: return ("arrow.down.circle.fill", .green)
        case .missing: return ("xmark.octagon.fill", .red)
        default: return ("minus.circle", .secondary)
        }
    }

    private var detail: String? {
        switch section {
        case .downloaded: return entry.download.map { "来源：\($0.source)" }
        case .adobeFonts: return nil
        default: return entry.filePath.map { ($0 as NSString).abbreviatingWithTildeInPath }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.0)
                .foregroundStyle(icon.1)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.ps).font(.body.weight(.semibold)).textSelection(.enabled)
                    if let d = entry.found?.display, !d.isEmpty, d != entry.ps {
                        Text(d).foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let note = entry.download?.note, !note.isEmpty {
                    Text("⚠ \(note)").font(.caption).foregroundStyle(.orange)
                }
                Text("用于：\(usage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if section == .missing {
                    if let err = entry.downloadError {
                        Text("自动下载失败：\(err)").font(.caption).foregroundStyle(.red)
                    }
                    HStack(spacing: 14) {
                        ForEach(searchHints(entry.ps), id: \.label) { h in
                            Link(h.label, destination: h.url)
                        }
                        if !entry.downloading {
                            Button(entry.downloadError == nil ? "尝试下载" : "重试下载", action: onRetry)
                                .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 8)
            if entry.downloading {
                ProgressView().controlSize(.small)
            } else if let p = entry.filePath, section != .adobeFonts {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("在访达中显示字体文件")
            }
        }
        .padding(.vertical, 4)
    }
}
