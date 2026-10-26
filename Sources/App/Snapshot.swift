// 开发用：设置 CODEX_SWITCH_SNAPSHOT=<目录> 启动时，把各页面离屏渲染成 PNG 后退出。
// 配合 CODEX_HOME / CODEX_SWITCH_HOME 指向测试数据，用于检查界面而不打开真实窗口。
import SwiftUI

enum Snapshot {
    @MainActor
    static func render(to directory: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = AppModel()
        spin(1.0)

        let pages: [(String, AppModel.Page)] = [("accounts", .accounts), ("security", .security), ("settings", .settings)]
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, page) in pages {
                model.page = page
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: MainWindow().environmentObject(model))
                host.frame = window.contentRect(forFrameRect: window.frame)
                window.contentView = host
                spin(page == .security ? 1.5 : 0.4)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        exit(0)
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
