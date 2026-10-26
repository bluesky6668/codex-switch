// codex-switch：安全的 Codex 多账号切换工具（仅切换与额度查看，无反代、无号池）。
import Foundation

let usage = """
codex-switch \(toolVersion) — 安全地在多个 Codex（ChatGPT 登录）账号之间切换

用法：
  codex-switch list                     列出已保存的账号与上次查询的额度（* 为当前登录）
  codex-switch usage [账号]             联网查询额度（5 小时 / 每周剩余），不指定则查询全部
  codex-switch current                  显示当前登录的账号
  codex-switch import [--label 名称]    保存当前 ~/.codex/auth.json 的登录
         [--from 文件 [--delete-source]] 从指定 auth.json 导入（可导入后安全删除源文件）
         [--force]                       即使库里令牌更新也强制覆盖
  codex-switch login [--label 名称]     用官方 codex login 登录新账号（不影响当前登录）
  codex-switch switch <账号>            切换账号；<账号> 可以是序号、标签、邮箱或 id 前缀
         [--restart | --no-restart]      应用运行时是否自动重启（默认询问）
  codex-switch undo [--restart | --no-restart]
                                        撤销上一次切换（再次执行会切回来）
  codex-switch rename <账号> <新名称>
  codex-switch remove <账号> [--yes]    删除账号（同时删除钥匙串中的令牌）
  codex-switch doctor [--fix]           检查权限、钥匙串一致性与残留文件

令牌只保存在 macOS 钥匙串中；本工具不监听端口，只在查询额度时访问 chatgpt.com 与 auth.openai.com。
"""

struct Arguments {
    private var items: [String]

    init(_ raw: [String]) { items = raw }

    mutating func flag(_ names: String...) -> Bool {
        guard let i = items.firstIndex(where: names.contains) else { return false }
        items.remove(at: i)
        return true
    }

    mutating func option(_ name: String) throws -> String? {
        guard let i = items.firstIndex(of: name) else { return nil }
        guard i + 1 < items.count, !items[i + 1].hasPrefix("--") else { throw ToolError("\(name) 需要一个值") }
        let value = items[i + 1]
        items.removeSubrange(i...(i + 1))
        return value
    }

    func positionals(_ count: ClosedRange<Int>, _ hint: String) throws -> [String] {
        if let unknown = items.first(where: { $0.hasPrefix("-") }) { throw ToolError("未知选项 \(unknown)") }
        guard count.contains(items.count) else { throw ToolError("用法：codex-switch \(hint)") }
        return items
    }
}

func restartMode(_ args: inout Arguments) throws -> RestartMode {
    let yes = args.flag("--restart"), no = args.flag("--no-restart")
    if yes && no { throw ToolError("--restart 与 --no-restart 不能同时使用") }
    return yes ? .yes : no ? .no : .ask
}

enum RestartMode { case ask, yes, no }

/// 应用在运行时，按选项或交互询问决定是否重启。
func shouldRestartApp(_ mode: RestartMode) throws -> Bool {
    switch mode {
    case .yes: return true
    case .no: return false
    case .ask:
        guard !DesktopApp.running().isEmpty else { return false }
        guard isatty(STDIN_FILENO) != 0 else {
            throw ToolError("ChatGPT/Codex 应用正在运行；非交互模式请加 --restart 或 --no-restart")
        }
        return confirm("ChatGPT/Codex 应用正在运行，需要重启才能生效。现在重启？", defaultYes: true)
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("! \(message)\n".utf8))
}

func confirm(_ question: String, defaultYes: Bool) -> Bool {
    print("\(question) \(defaultYes ? "[Y/n]" : "[y/N]") ", terminator: "")
    fflush(stdout)
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    if answer.isEmpty { return defaultYes }
    return answer == "y" || answer == "yes"
}

// MARK: - 列表显示

func displayWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }
}

func pad(_ text: String, _ width: Int) -> String {
    text + String(repeating: " ", count: max(0, width - displayWidth(text)))
}

func formatDate(_ date: Date?) -> String {
    guard let date else { return "-" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

/// 例如 “78%（10-26 21:14 重置）”。
func formatWindow(_ window: UsageWindow?) -> String {
    guard let window else { return "-" }
    let percent = "\(Int(window.remainingPercent.rounded()))%"
    guard let reset = window.resetAt else { return percent }
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    return "\(percent)（\(formatter.string(from: reset)) 重置）"
}

func listAccounts(_ manager: Manager) {
    let current: AuthSnapshot?
    var currentError: String?
    do { current = try manager.currentSnapshot() } catch { current = nil; currentError = "\(error)" }

    if manager.index.accounts.isEmpty {
        print("账号库为空。先在 ChatGPT/Codex 中登录，然后运行：codex-switch import")
    } else {
        let rows = manager.index.accounts.enumerated().map { i, meta in
            [meta.key == current?.identity.key ? "*" : " ", "\(i + 1)", meta.label, meta.plan ?? "-",
             formatWindow(meta.usage?.fiveHour), formatWindow(meta.usage?.oneWeek), formatDate(meta.lastSwitchedAt)]
        }
        let header = ["", "#", "标签", "计划", "5h 剩余", "每周剩余", "上次切换"]
        let widths = header.indices.map { col in ([header] + rows).map { displayWidth($0[col]) }.max() ?? 0 }
        for row in [header] + rows {
            print(zip(row, widths).map { pad($0, $1) }.joined(separator: "  "))
        }
    }

    let fetched = manager.index.accounts.compactMap { $0.usage?.fetchedAt }.max()
    print(fetched.map { "\n额度更新于 \(formatDate($0))，运行 codex-switch usage 刷新" } ?? "\n运行 codex-switch usage 查询额度")
    for (i, meta) in manager.index.accounts.enumerated() {
        if let error = meta.usageError { print("! #\(i + 1) 额度查询失败：\(error)") }
    }

    if let current, manager.indexOf(current.identity) == nil {
        print("\n当前登录 \(current.identity.email ?? current.identity.accountId) 尚未保存，运行 codex-switch import 加入")
    } else if let currentError {
        print("\n当前 auth.json：\(currentError)")
    }
}

// MARK: - login

func loginNewAccount(label: String?) throws {
    let login = try CodexLogin()
    // Ctrl-C 只结束 codex login，本进程继续执行清理；处理函数在 exec 后会被子进程重置为默认。
    signal(SIGINT) { _ in }
    defer { signal(SIGINT, SIG_DFL) }
    let snap = try login.run()
    let lock = try acquireLock()
    defer { withExtendedLifetime(lock) {} }
    var manager = try makeManager()
    let (i, result) = try manager.saveLogin(snap, label: label)
    let meta = manager.index.accounts[i]
    print("✓ \(result == .created ? "已添加" : "已更新") #\(i + 1) \(meta.label)\(describePlan(meta.plan))")
    print("· 运行 codex-switch switch \(i + 1) 切换到该账号")
}

// MARK: - 入口

func run() throws {
    var rest = Array(CommandLine.arguments.dropFirst())
    guard !rest.isEmpty else { return print(usage) }
    let command = rest.removeFirst()
    var args = Arguments(rest)

    switch command {
    case "list", "ls":
        _ = try args.positionals(0...0, "list")
        listAccounts(try makeManager())

    case "usage", "quota":
        let selector = try args.positionals(0...1, "usage [账号]").first
        let accounts = try makeManager().index
        let targets = try selector.map { [accounts.accounts[try accounts.resolve($0)]] } ?? accounts.accounts
        guard !targets.isEmpty else { throw ToolError("账号库为空") }
        var failed = 0
        for meta in targets {
            do {
                let usage = try fetchAndStoreUsage(accountID: meta.id)
                print("✓ \(meta.label)：5h \(formatWindow(usage.fiveHour))，每周 \(formatWindow(usage.oneWeek))")
            } catch {
                failed += 1
                warn("\(meta.label)：\(error)")
            }
        }
        print("")
        listAccounts(try makeManager())
        if failed > 0 { exit(1) }

    case "__test-parse-usage":
        // 仅供 tests/run.sh 校验额度解析，只对测试用的钥匙串服务名生效。
        guard try makeManager().keychain.service.hasPrefix("codex-switch-test-") else { throw ToolError("未知命令 \(command)") }
        let path = try args.positionals(1...1, "__test-parse-usage <文件>")[0]
        let usage = try UsageAPI.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
        print("5h=\(usage.fiveHour.map { "\(Int($0.remainingPercent))" } ?? "nil") week=\(usage.oneWeek.map { "\(Int($0.remainingPercent))" } ?? "nil") plan=\(usage.plan ?? "nil")")

    case "current", "status":
        _ = try args.positionals(0...0, "current")
        let manager = try makeManager()
        guard let snap = try manager.currentSnapshot() else { return print("当前未登录（没有 auth.json）") }
        let who = "\(snap.identity.email ?? snap.identity.accountId)\(describePlan(snap.identity.plan))"
        if let i = manager.indexOf(snap.identity) {
            print("当前：#\(i + 1) \(manager.index.accounts[i].label) — \(who)")
        } else {
            print("当前：\(who)（尚未保存，运行 codex-switch import 加入）")
        }

    case "import", "add":
        let label = try args.option("--label")
        let from = try args.option("--from")
        let deleteSource = args.flag("--delete-source")
        let force = args.flag("--force")
        _ = try args.positionals(0...0, "import [--label 名称] [--from 文件]")
        if deleteSource && from == nil { throw ToolError("--delete-source 只能与 --from 一起使用") }
        let lock = try acquireLock()
        defer { withExtendedLifetime(lock) {} }
        var manager = try makeManager()
        let source = from.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? manager.paths.authFile
        guard SecureFS.exists(source) else { throw ToolError("找不到 \(source.path)") }
        let snap = try parseAuth(try SecureFS.readPrivateFile(source))
        let (i, result) = try manager.upsert(snap, label: label, force: force)
        try manager.index.save(manager.paths)
        let meta = manager.index.accounts[i]
        switch result {
        case .created: print("✓ 已添加 #\(i + 1) \(meta.label)\(describePlan(meta.plan))")
        case .updated: print("✓ 已更新 #\(i + 1) \(meta.label) 的令牌")
        case .unchanged: print("· #\(i + 1) \(meta.label) 已是最新，无需更新")
        case .skippedOlder: warn("#\(i + 1) \(meta.label) 在库中的令牌比导入的更新，已跳过（--force 强制覆盖）")
        }
        if let from {
            if deleteSource {
                SecureFS.scrubAndRemove(source)
                print("· 已覆写并删除源文件")
            } else {
                warn("源文件 \(from) 仍是明文令牌，建议删除或加 --delete-source")
            }
        }

    case "login":
        let label = try args.option("--label")
        _ = try args.positionals(0...0, "login [--label 名称]")
        try loginNewAccount(label: label)

    case "switch", "use":
        let mode = try restartMode(&args)
        let selector = try args.positionals(1...1, "switch <序号|标签|邮箱>")[0]
        let lock = try acquireLock()
        defer { withExtendedLifetime(lock) {} }
        var manager = try makeManager()
        let position = try manager.index.resolve(selector)
        try manager.switchTo(position, restartApp: try shouldRestartApp(mode))

    case "undo":
        let mode = try restartMode(&args)
        _ = try args.positionals(0...0, "undo")
        let lock = try acquireLock()
        defer { withExtendedLifetime(lock) {} }
        var manager = try makeManager()
        try manager.undo(restartApp: try shouldRestartApp(mode))

    case "rename":
        let values = try args.positionals(2...2, "rename <账号> <新名称>")
        let lock = try acquireLock()
        defer { withExtendedLifetime(lock) {} }
        var manager = try makeManager()
        let i = try manager.index.resolve(values[0])
        let name = values[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ToolError("新名称不能为空") }
        manager.index.accounts[i].label = name
        try manager.index.save(manager.paths)
        print("✓ #\(i + 1) 已重命名为 \(name)")

    case "remove", "rm", "delete":
        let yes = args.flag("--yes", "-y")
        let selector = try args.positionals(1...1, "remove <账号> [--yes]")[0]
        let lock = try acquireLock()
        defer { withExtendedLifetime(lock) {} }
        var manager = try makeManager()
        let i = try manager.index.resolve(selector)
        let meta = manager.index.accounts[i]
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else { throw ToolError("非交互模式请加 --yes 确认删除") }
            guard confirm("删除 #\(i + 1) \(meta.label)？钥匙串中的令牌会一并删除", defaultYes: false) else {
                return print("已取消")
            }
        }
        let isCurrent = (try? manager.currentSnapshot())?.identity.key == meta.key
        try manager.remove(i)
        print("✓ 已删除 \(meta.label)")
        if isCurrent { warn("auth.json 仍是该账号的登录态；如需退出登录请在 Codex 中登出") }

    case "doctor":
        let fix = args.flag("--fix")
        _ = try args.positionals(0...0, "doctor [--fix]")
        let lock = try acquireLock()
        defer { withExtendedLifetime(lock) {} }
        var doctor = Doctor(manager: try openManagerForDoctor(fix: fix) { print($0) }, fix: fix)
        try doctor.run()
        doctor.findings.forEach { print($0.cliLine) }
        print(doctor.errorCount == 0 ? "\n检查完成，未发现严重问题。" : "\n检查完成，发现 \(doctor.errorCount) 个严重问题。")
        if doctor.errorCount > 0 { exit(1) }

    case "__test-purge":
        // 仅供 tests/run.sh 清理测试条目，只对 codex-switch-test- 开头的服务名生效。
        let keychain = try makeManager().keychain
        guard keychain.service.hasPrefix("codex-switch-test-") else { throw ToolError("未知命令 \(command)") }
        try keychain.allAccounts().forEach { try keychain.delete(account: $0) }

    case "version", "-v", "--version":
        print("codex-switch \(toolVersion)")

    default:
        throw ToolError("未知命令 \(command)，运行 codex-switch help 查看用法")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
    exit(1)
}
