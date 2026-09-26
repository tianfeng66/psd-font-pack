import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--cli") {
            CLI.run(Array(args[(i + 1)...]))
        }
        PSDFontPackApp.main()
    }
}

struct PSDFontPackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("PSD 字体打包", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开 PSD…") { AppModel.shared.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 把 PSD 拖到程序坞图标上、或在访达里「打开方式」选本程序
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
