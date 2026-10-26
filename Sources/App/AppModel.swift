// 图形界面的状态与操作。所有读写都放到串行后台队列，并与命令行共用文件锁。
import AppKit
import SwiftUI

enum RestartPreference: String, CaseIterable, Identifiable {
    case ask, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: return "每次询问"
        case .always: return "自动重启"
        case .never: return "不重启"
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, remaining, shortName
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon: return "仅图标"
        case .remaining: return "图标 + 5h 剩余"
        case .shortName: return "图标 + 账号简称"
        }
    }
}

enum UsageInterval: Int, CaseIterable, Identifiable {
    case off = 0, five = 5, fifteen = 15, thirty = 30
    var id: Int { rawValue }
    var title: String { self == .off ? "不自动刷新" : "每 \(rawValue) 分钟" }
}

struct Toast: Equatable {
    let message: String
    let isError: Bool
}

@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published private(set) var accounts: [AccountMeta] = []
    @Published private(set) var currentKey: String?
    /// 当前 auth.json 里的登录尚未加入账号库时不为 nil。
    @Published private(set) var unsavedCurrent: AuthIdentity?
    @Published private(set) var currentError: String?
    @Published private(set) var loadError: String?
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var hasUndo = false
    @Published private(set) var busy: String?
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var loginOutput = ""
    @Published private(set) var loginRunning = false
    @Published private(set) var refreshingUsage = false
    @Published var toast: Toast?
    @Published var page: Page = .accounts

    @AppStorage("restartPreference") var restartPreference: RestartPreference = .ask
    @AppStorage("menuBarStyle") var menuBarStyle: MenuBarStyle = .icon
    @AppStorage("usageInterval") var usageInterval: UsageInterval = .fifteen

    enum Page: Hashable { case accounts, security, settings }

    private let queue = DispatchQueue(label: "codex-switch.worker")
    private var timer: Timer?
    private var login: CodexLogin?
    /// 额度查询走单独的队列：网络请求可能较慢，不能挡住切换等操作。
    private let usageQueue = DispatchQueue(label: "codex-switch.usage")
    private var usageTimer: Timer?
    private var lastUsageRefresh: Date?

    override init() {
        super.init()
        reload()
        // 只读本地文件（索引与 auth.json），不访问钥匙串、不联网，开销很小。
        timer = Timer.scheduledTimer(
            timeInterval: 10, target: self, selector: #selector(periodicReload),
            userInfo: nil, repeats: true)
        // 截图模式用的是伪造令牌，绝不能发出真实请求。
        guard ProcessInfo.processInfo.environment["CODEX_SWITCH_SNAPSHOT"] == nil else { return }
        usageTimer = Timer.scheduledTimer(
            timeInterval: 60, target: self, selector: #selector(periodicUsageRefresh),
            userInfo: nil, repeats: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refreshUsageIfDue() }
    }

    @objc private func periodicReload(_ timer: Timer) { reload() }

    @objc private func periodicUsageRefresh(_ timer: Timer) { refreshUsageIfDue() }

    /// 5 小时窗口剩余百分比（没有 5 小时窗口时用每周窗口），给菜单栏显示。
    var currentRemaining: String? {
        guard let usage = currentAccount?.usage, let window = usage.fiveHour ?? usage.oneWeek else { return nil }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    var lastUsageFetch: Date? { accounts.compactMap { $0.usage?.fetchedAt }.max() }

    var currentAccount: AccountMeta? { accounts.first { $0.key == currentKey } }

    /// 菜单栏用的简称：邮箱只取 @ 前部分，最多 8 个字符。
    var currentShortName: String? {
        guard let label = currentAccount?.label else { return nil }
        let name = label.split(separator: "@").first.map(String.init) ?? label
        return name.count > 8 ? String(name.prefix(7)) + "…" : name
    }

    // MARK: - 读取

    func reload() {
        queue.async {
            let result = Result { () -> (AccountIndex, AuthSnapshot?, String?, Bool) in
                let manager = try makeManager()
                var current: AuthSnapshot?
                var currentError: String?
                do { current = try manager.currentSnapshot() } catch { currentError = "\(error)" }
                let hasUndo = (try? manager.keychain.allAccounts().contains(Keychain.undoAccount)) ?? false
                return (manager.index, current, currentError, hasUndo)
            }
            DispatchQueue.main.async {
                switch result {
                case let .success((index, current, currentError, hasUndo)):
                    self.accounts = index.accounts
                    self.currentKey = current?.identity.key
                    self.unsavedCurrent = current.flatMap { snap in
                        index.accounts.contains { $0.key == snap.identity.key } ? nil : snap.identity
                    }
                    self.currentError = currentError
                    self.hasUndo = hasUndo
                    self.loadError = nil
                case let .failure(error):
                    self.loadError = "\(error)"
                }
                self.lastLoaded = Date()
            }
        }
    }

    // MARK: - 操作

    /// 在后台队列持锁执行一次账号库操作，结束后刷新并提示结果。
    private func perform(_ title: String, _ body: @escaping @Sendable (inout Manager) throws -> String) {
        guard busy == nil else { return }
        busy = title
        queue.async {
            var lines: [String] = []
            let result = Result { () -> String in
                let lock = try acquireLock()
                defer { withExtendedLifetime(lock) {} }
                var manager = try makeManager()
                manager.log = { lines.append($0) }
                return try body(&manager)
            }
            let warnings = lines.filter { $0.hasPrefix("! ") }.map { String($0.dropFirst(2)) }
            DispatchQueue.main.async {
                self.busy = nil
                switch result {
                case let .success(message):
                    self.show(([message] + warnings).joined(separator: "\n"), isError: false)
                case let .failure(error):
                    self.show("\(error)", isError: true)
                }
                self.reload()
            }
        }
    }

    func switchTo(_ meta: AccountMeta) {
        guard meta.key != currentKey else { return }
        guard let restart = decideRestart() else { return }
        perform("正在切换到 \(meta.label)…") { manager in
            guard let position = manager.index.accounts.firstIndex(where: { $0.id == meta.id }) else {
                throw ToolError("账号已不存在")
            }
            try manager.switchTo(position, restartApp: restart)
            return "已切换到 \(meta.label)"
        }
    }

    func undo() {
        guard let restart = decideRestart() else { return }
        perform("正在撤销上次切换…") { manager in
            try manager.undo(restartApp: restart)
            return "已恢复到上次切换前的登录"
        }
    }

    func saveCurrent() {
        perform("正在保存当前登录…") { manager in
            guard let snap = try manager.currentSnapshot() else { throw ToolError("当前未登录") }
            let (i, result) = try manager.upsert(snap, label: nil)
            try manager.index.save(manager.paths)
            let label = manager.index.accounts[i].label
            switch result {
            case .created: return "已保存 \(label)"
            case .updated: return "已更新 \(label) 的令牌"
            case .unchanged: return "\(label) 已是最新"
            case .skippedOlder: return "\(label) 在库中的令牌更新，已跳过"
            }
        }
    }

    func importFile(_ url: URL, deleteSource: Bool) {
        perform("正在导入…") { manager in
            let snap = try parseAuth(try SecureFS.readPrivateFile(url))
            let (i, result) = try manager.upsert(snap, label: nil)
            try manager.index.save(manager.paths)
            if deleteSource { SecureFS.scrubAndRemove(url) }
            let label = manager.index.accounts[i].label
            let suffix = deleteSource ? "，源文件已删除" : "；源文件仍是明文令牌，建议删除"
            return (result == .created ? "已导入 \(label)" : "已更新 \(label)") + suffix
        }
    }

    func rename(_ meta: AccountMeta, to label: String) {
        let name = label.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != meta.label else { return }
        perform("正在重命名…") { manager in
            guard let i = manager.index.accounts.firstIndex(where: { $0.id == meta.id }) else {
                throw ToolError("账号已不存在")
            }
            manager.index.accounts[i].label = name
            try manager.index.save(manager.paths)
            return "已重命名为 \(name)"
        }
    }

    func remove(_ meta: AccountMeta) {
        perform("正在删除…") { manager in
            guard let i = manager.index.accounts.firstIndex(where: { $0.id == meta.id }) else {
                throw ToolError("账号已不存在")
            }
            try manager.remove(i)
            return "已删除 \(meta.label)"
        }
    }

    func runDoctor(fix: Bool) {
        guard busy == nil else { return }
        busy = fix ? "正在修复…" : "正在检查…"
        queue.async {
            var notes: [String] = []
            let result = Result { () -> [Finding] in
                let lock = try acquireLock()
                defer { withExtendedLifetime(lock) {} }
                var doctor = Doctor(manager: try openManagerForDoctor(fix: fix) { notes.append($0) }, fix: fix)
                try doctor.run()
                return doctor.findings
            }
            let completedNotes = notes
            DispatchQueue.main.async {
                self.busy = nil
                switch result {
                case let .success(findings):
                    self.findings = findings
                    if fix { self.show((["修复完成"] + completedNotes).joined(separator: "\n"), isError: false) }
                case let .failure(error):
                    self.show("\(error)", isError: true)
                }
                self.reload()
            }
        }
    }

    // MARK: - 额度

    private func refreshUsageIfDue() {
        guard usageInterval != .off else { return }
        let due = lastUsageRefresh.map { Date().timeIntervalSince($0) >= Double(usageInterval.rawValue * 60) } ?? true
        if due { refreshUsage(manual: false) }
    }

    /// 逐个查询所有账号的额度；每查完一个就刷新界面。
    func refreshUsage(manual: Bool) {
        guard !refreshingUsage, !accounts.isEmpty else { return }
        refreshingUsage = true
        let targets = accounts.map { ($0.id, $0.label) }
        usageQueue.async {
            var failures: [String] = []
            for (id, label) in targets {
                do { try fetchAndStoreUsage(accountID: id) } catch { failures.append("\(label)：\(error)") }
                DispatchQueue.main.async { self.reload() }
            }
            let completedFailures = failures
            DispatchQueue.main.async {
                self.refreshingUsage = false
                self.lastUsageRefresh = Date()
                if manual {
                    self.show(completedFailures.isEmpty ? "额度已更新" : "额度查询失败\n" + completedFailures.joined(separator: "\n"),
                              isError: !completedFailures.isEmpty)
                }
            }
        }
    }

    // MARK: - 登录新账号

    func startLogin(label: String?) {
        guard !loginRunning else { return }
        let session: CodexLogin
        do { session = try CodexLogin() } catch { return show("\(error)", isError: true) }
        login = session
        loginRunning = true
        loginOutput = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> String in
                let snap = try session.run { text in
                    DispatchQueue.main.async { self.loginOutput += text }
                }
                return try self.queue.sync {
                    let lock = try acquireLock()
                    defer { withExtendedLifetime(lock) {} }
                    var manager = try makeManager()
                    let (i, result) = try manager.saveLogin(snap, label: label)
                    let meta = manager.index.accounts[i]
                    return "\(result == .created ? "已添加" : "已更新") \(meta.label)\(describePlan(meta.plan))"
                }
            }
            DispatchQueue.main.async {
                self.login = nil
                self.loginRunning = false
                switch result {
                case let .success(message): self.show(message, isError: false)
                case let .failure(error): self.show("\(error)", isError: true)
                }
                self.reload()
            }
        }
    }

    func cancelLogin() { login?.cancel() }

    /// codex 输出里的登录链接，浏览器没有自动打开时让用户手动点。
    var loginURL: URL? {
        guard let range = loginOutput.range(of: #"https://auth\.openai\.com/\S+"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(loginOutput[range]))
    }

    // MARK: - 辅助

    /// 应用运行中时按设置决定是否重启；返回 nil 表示用户取消。
    private func decideRestart() -> Bool? {
        guard !DesktopApp.running().isEmpty else { return false }
        switch restartPreference {
        case .always: return true
        case .never: return false
        case .ask:
            let alert = NSAlert()
            alert.messageText = "ChatGPT 正在运行"
            alert.informativeText = "应用会继续使用旧账号，并可能在退出时把旧令牌写回。建议重启应用让切换生效。"
            alert.addButton(withTitle: "重启并切换")
            alert.addButton(withTitle: "仅切换")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: return true
            case .alertSecondButtonReturn: return false
            default: return nil
            }
        }
    }

    private func show(_ message: String, isError: Bool) {
        let toast = Toast(message: message, isError: isError)
        self.toast = toast
        // 主窗口没开时（只用菜单栏），错误改用弹窗提示，否则用户看不到。
        if isError && !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.contains("main") == true }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "操作失败"
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 8 : 4)) {
            if self.toast == toast { self.toast = nil }
        }
    }
}
