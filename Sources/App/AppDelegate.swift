// 管理主窗口与 Dock 图标的生命周期：关闭窗口后保留菜单栏，重新打开时恢复 Dock 图标。
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowClosedObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowClosedObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowClosedObserver {
            NotificationCenter.default.removeObserver(windowClosedObserver)
        }
    }
}
