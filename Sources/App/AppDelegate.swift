// 管理主窗口与 Dock 图标的生命周期：关闭窗口后保留菜单栏，重新打开时恢复 Dock 图标。
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.title == "Codex Switch" else { return }
        // willClose 发出时窗口仍在 NSApp.windows 中，下一轮事件循环再判断。
        DispatchQueue.main.async {
            let mainWindowVisible = NSApp.windows.contains {
                $0.title == "Codex Switch" && $0.isVisible
            }
            if !mainWindowVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }
}
