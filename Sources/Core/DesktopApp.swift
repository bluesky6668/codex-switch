// 检测并正常退出 / 重新打开 ChatGPT（Codex）桌面应用。
// 只按 bundle id 操作，并且只请求正常退出（等同 ⌘Q），从不强杀进程。
import AppKit

enum DesktopApp {
    /// 新版 ChatGPT.app 与旧版 Codex.app 都使用此 bundle id。
    /// 测试时可设 CODEX_SWITCH_APP_BUNDLE_IDS=none 关闭应用联动。
    static var bundleIDs: [String] {
        let raw = ProcessInfo.processInfo.environment["CODEX_SWITCH_APP_BUNDLE_IDS"] ?? "com.openai.codex"
        if raw == "none" { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func running() -> [NSRunningApplication] {
        bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    /// 请求正常退出并等待，超时返回 false（例如应用弹出了“未保存”对话框）。
    static func quit(timeout: TimeInterval = 20) -> Bool {
        let apps = running()
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if apps.allSatisfy({ $0.isTerminated || kill($0.processIdentifier, 0) != 0 }) { return true }
            // 用 sleep 而非 RunLoop：图形界面在后台线程调用，那里没有运行循环。
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    static func launch(bundleID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleID]
        try? process.run()
        process.waitUntilExit()
    }

    /// 应用之外独立运行的 codex CLI 进程，它们在重启前会继续使用旧账号。
    static func strayCLIProcessCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").count
    }
}
