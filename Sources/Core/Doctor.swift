// doctor：检查权限、钥匙串一致性与残留文件，fix 时就地修复。
import Foundation

struct Finding: Identifiable {
    enum Level { case ok, info, warning, error }
    let id = UUID()
    let level: Level
    let message: String
    /// 不修复时：该问题能否用 fix 自动修复。修复时：nil 表示未尝试，true/false 为修复结果。
    var fixable = false
    var fixed: Bool?

    var cliLine: String {
        let mark = ["✓", "·", "!", "✗"][[Level.ok, .info, .warning, .error].firstIndex(of: level)!]
        switch fixed {
        case true?: return "\(mark) \(message) → 已修复"
        case false?: return "\(mark) \(message) → 修复失败"
        case nil: return "\(mark) \(message)\(fixable ? "（可用 --fix 修复）" : "")"
        }
    }
}

struct Doctor {
    var manager: Manager
    let fix: Bool
    private(set) var findings: [Finding] = []

    var errorCount: Int { findings.filter { $0.level == .error && $0.fixed != true }.count }
    var fixableCount: Int { findings.filter { $0.fixable && $0.fixed == nil }.count }

    init(manager: Manager, fix: Bool) {
        self.manager = manager
        self.fix = fix
    }

    private mutating func add(_ level: Finding.Level, _ message: String) {
        findings.append(Finding(level: level, message: message))
    }

    /// 可修复的问题：fixed 为 nil 表示未修复（仅提示可修复），否则为修复结果。
    private mutating func repairable(_ level: Finding.Level, _ message: String, fixed: Bool?) {
        findings.append(Finding(level: level, message: message, fixable: fixed == nil, fixed: fixed))
    }

    mutating func run() throws {
        let paths = manager.paths
        checkPrivate(paths.dataDir, expected: 0o700, name: "数据目录 \(displayPath(paths.dataDir))")
        if SecureFS.exists(paths.indexFile) {
            checkPrivate(paths.indexFile, expected: 0o600, name: "账号索引")
        }
        checkCodexDir()
        checkAuthFile()
        checkCredentialStore()
        try checkKeychain()
        cleanLeftovers()
        add(.info, DesktopApp.running().isEmpty ? "ChatGPT/Codex 应用未运行" : "ChatGPT/Codex 应用正在运行（切换时会提示重启）")
    }

    private mutating func checkPrivate(_ url: URL, expected: mode_t, name: String) {
        guard let (mine, mode) = SecureFS.ownerAndMode(url) else { return }
        guard mine else { return add(.error, "\(name) 不属于当前用户") }
        if mode & 0o077 == 0 { return add(.ok, "\(name) 权限 \(octal(mode))") }
        let fixed = fix ? chmod(url.path, expected) == 0 : nil
        repairable(.warning, "\(name) 权限为 \(octal(mode))，应为 \(octal(expected))", fixed: fixed)
    }

    private mutating func checkCodexDir() {
        let dir = manager.paths.codexDir
        guard let (mine, mode) = SecureFS.ownerAndMode(dir) else { return add(.info, "\(displayPath(dir)) 不存在") }
        if !mine { return add(.error, "\(displayPath(dir)) 不属于当前用户") }
        if SecureFS.isSymlink(dir) { add(.info, "\(displayPath(dir)) 是符号链接（已跟随检查目标目录）") }
        // ~/.codex 里还有会话记录和日志，其他用户可读同样是隐私泄露。
        if mode & 0o077 == 0 { return add(.ok, "\(displayPath(dir)) 权限 \(octal(mode))") }
        let who = mode & 0o002 != 0 ? "所有用户可写入" : mode & 0o020 != 0 ? "同组用户可写入" : "其他用户可读取"
        let fixed = fix ? chmod(dir.path, 0o700) == 0 : nil
        repairable(.warning, "\(displayPath(dir)) 权限为 \(octal(mode))，\(who)（含令牌与会话记录）", fixed: fixed)
    }

    private mutating func checkAuthFile() {
        let url = manager.paths.authFile
        guard SecureFS.exists(url) else { return add(.info, "auth.json 不存在（当前未登录）") }
        if SecureFS.isSymlink(url) { return add(.error, "auth.json 是符号链接，codex-switch 拒绝处理") }
        checkPrivate(url, expected: 0o600, name: "auth.json")
        do {
            guard let snap = try manager.currentSnapshot() else { return }
            let who = "\(snap.identity.email ?? snap.identity.accountId)\(describePlan(snap.identity.plan))"
            if let i = manager.indexOf(snap.identity) {
                add(.ok, "当前登录 \(who)，对应账号库 #\(i + 1)")
            } else {
                add(.info, "当前登录 \(who) 尚未保存，可加入账号库")
            }
            if snap.hasStoredAPIKey { add(.info, "auth.json 同时含有 OPENAI_API_KEY（切换时原样保留各账号自己的值）") }
        } catch {
            add(.warning, "当前 auth.json 无法作为账号管理：\(error)")
        }
    }

    private mutating func checkCredentialStore() {
        guard let text = try? String(contentsOf: manager.paths.configFile, encoding: .utf8) else { return }
        let pattern = #"(?m)^\s*cli_auth_credentials_store\s*=\s*"(\w+)""#
        guard let match = text.range(of: pattern, options: .regularExpression) else {
            return add(.ok, "Codex 凭据存储为默认的 auth.json 文件")
        }
        let value = text[match].split(separator: "\"").dropFirst().first.map(String.init) ?? ""
        switch value {
        case "file": add(.ok, "Codex 凭据存储为 auth.json 文件")
        case "keyring": add(.error, "config.toml 设置了 cli_auth_credentials_store = \"keyring\"，Codex 不读 auth.json，切换无效")
        default: add(.warning, "config.toml 设置了 cli_auth_credentials_store = \"\(value)\"，可能不使用 auth.json")
        }
    }

    private mutating func checkKeychain() throws {
        let items = Set(try manager.keychain.allAccounts())
        var missing = 0
        for (i, meta) in manager.index.accounts.enumerated() where !items.contains(Keychain.accountKey(meta.id)) {
            missing += 1
            add(.error, "#\(i + 1) \(meta.label) 的令牌在钥匙串中缺失；重新登录该账号后再保存")
        }

        let known = Set(manager.index.accounts.map { Keychain.accountKey($0.id) })
        let orphans = items.filter { $0.hasPrefix("acct:") && !known.contains($0) }
        if orphans.isEmpty && missing == 0 {
            add(.ok, "钥匙串中 \(manager.index.accounts.count) 个账号的令牌齐全")
        }
        for orphan in orphans.sorted() {
            // 索引丢失或损坏时，从钥匙串把账号重新登记回来。
            let fixed = fix ? adopt(orphan) : nil
            repairable(.warning, "钥匙串中有未登记的账号条目 \(orphan)", fixed: fixed)
        }
        if fix && !orphans.isEmpty { try manager.index.save(manager.paths) }
        if items.contains(Keychain.undoAccount) { add(.info, "存在一份切换前快照，可撤销上次切换") }
    }

    private mutating func adopt(_ orphan: String) -> Bool {
        guard let raw = try? manager.keychain.get(account: orphan), let snap = try? parseAuth(raw) else { return false }
        let now = Date()
        manager.index.accounts.append(AccountMeta(
            id: String(orphan.dropFirst("acct:".count)),
            label: snap.identity.email ?? "Codex \(snap.identity.accountId.prefix(8))",
            email: snap.identity.email, principal: snap.identity.principal,
            accountId: snap.identity.accountId, plan: snap.identity.plan,
            addedAt: now, updatedAt: now, lastSwitchedAt: nil))
        return true
    }

    private mutating func cleanLeftovers() {
        let fm = FileManager.default
        var leftovers: [URL] = []
        for dir in [manager.paths.codexDir, manager.paths.dataDir] {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            leftovers += names
                .filter { ($0.contains(".codex-switch-") && $0.hasSuffix(".tmp")) || $0.hasPrefix("login-") }
                .map { dir.appendingPathComponent($0) }
        }
        guard !leftovers.isEmpty else { return }
        if fix { leftovers.forEach(scrubRecursively) }
        repairable(.warning, "发现 \(leftovers.count) 个可能含令牌的残留临时文件", fixed: fix ? true : nil)
    }
}

/// 覆写并删除目录或文件（用于清理 login 临时目录）。
func scrubRecursively(_ url: URL) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
    if isDir.boolValue && !SecureFS.isSymlink(url) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            scrubRecursively(url.appendingPathComponent(name))
        }
        rmdir(url.path)
    } else if SecureFS.isSymlink(url) {
        unlink(url.path)
    } else {
        SecureFS.scrubAndRemove(url)
    }
}

/// 打开账号库；索引损坏且允许修复时，把它移到一边后从钥匙串重建。
func openManagerForDoctor(fix: Bool, log: (String) -> Void) throws -> Manager {
    do {
        return try makeManager()
    } catch {
        let paths = Paths.resolve()
        guard fix, SecureFS.exists(paths.indexFile) else { throw error }
        let aside = paths.dataDir.appendingPathComponent("accounts.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        guard rename(paths.indexFile.path, aside.path) == 0 else { throw error }
        log("! 账号索引损坏，已移至 \(aside.lastPathComponent)，将从钥匙串重建")
        return try makeManager()
    }
}

/// 显示用路径：把家目录缩写为 ~。
func displayPath(_ url: URL) -> String {
    let home = NSHomeDirectory()
    return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
}
