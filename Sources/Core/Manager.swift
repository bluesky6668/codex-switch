// 账号库的核心操作：保存、切换、撤销、删除。
import Foundation

enum UpsertResult { case created, updated, unchanged, skippedOlder }

struct Manager {
    let paths: Paths
    let keychain: Keychain
    var index: AccountIndex
    /// 进度与提示输出；命令行打印到终端，图形界面收集后显示。
    var log: (String) -> Void = { print($0) }

    init(paths: Paths, keychain: Keychain) throws {
        self.paths = paths
        self.keychain = keychain
        try SecureFS.ensurePrivateDirectory(paths.dataDir)
        index = try AccountIndex.load(paths)
    }

    // MARK: - 当前登录

    /// 当前 auth.json 的快照；文件不存在返回 nil，无法解析时抛错。
    func currentSnapshot() throws -> AuthSnapshot? {
        guard SecureFS.exists(paths.authFile) else { return nil }
        return try parseAuth(try SecureFS.readPrivateFile(paths.authFile))
    }

    func indexOf(_ identity: AuthIdentity) -> Int? {
        index.accounts.firstIndex { $0.key == identity.key }
    }

    // MARK: - 保存

    /// 把一份登录态存入账号库：已有账号只在令牌更新时覆盖，新账号自动创建。
    /// 先写钥匙串再改索引，任何一步失败都不会出现“索引有、令牌无”的新条目。
    mutating func upsert(_ snap: AuthSnapshot, label: String?, force: Bool = false) throws -> (Int, UpsertResult) {
        let now = Date()
        if let i = indexOf(snap.identity) {
            var meta = index.accounts[i]
            if let label, !label.isEmpty { meta.label = label }
            let stored = try keychain.get(account: Keychain.accountKey(meta.id)).flatMap { try? parseAuth($0) }
            var result = UpsertResult.unchanged
            if let stored, !force, !isNewerSnapshot(snap, than: stored) {
                if stored.refreshToken != snap.refreshToken { result = .skippedOlder }
            } else {
                try keychain.set(snap.raw, account: Keychain.accountKey(meta.id), label: "codex-switch: \(meta.label)")
                meta.updatedAt = now
                result = .updated
            }
            if let email = snap.identity.email { meta.email = email }
            if let plan = snap.identity.plan { meta.plan = plan }
            index.accounts[i] = meta
            return (i, result)
        }

        let id = UUID().uuidString.lowercased()
        let name = (label?.isEmpty == false ? label : nil)
            ?? snap.identity.email ?? "Codex \(snap.identity.accountId.prefix(8))"
        try keychain.set(snap.raw, account: Keychain.accountKey(id), label: "codex-switch: \(name)")
        index.accounts.append(AccountMeta(
            id: id, label: name, email: snap.identity.email, principal: snap.identity.principal,
            accountId: snap.identity.accountId, plan: snap.identity.plan,
            addedAt: now, updatedAt: now, lastSwitchedAt: nil))
        return (index.accounts.count - 1, .created)
    }

    // MARK: - 切换

    mutating func switchTo(_ position: Int, restartApp: Bool) throws {
        let target = index.accounts[position]
        guard let targetRaw = try keychain.get(account: Keychain.accountKey(target.id)) else {
            throw ToolError("钥匙串中找不到 #\(position + 1) 的令牌，请重新登录该账号后执行 import")
        }
        let targetSnap = try parseAuth(targetRaw)
        // 钥匙串内容必须与索引记录的身份一致，防止条目被篡改或错配后写错账号。
        guard targetSnap.identity.key == target.key else {
            throw ToolError("#\(position + 1) 的钥匙串内容与索引身份不一致，已拒绝切换；请运行 doctor")
        }
        if let current = try? currentSnapshot(), current.identity.key == target.key {
            log("已经是 #\(position + 1) \(target.label)，无需切换")
            return
        }

        try checkCodexDirWritable()
        let relaunch = try prepareDesktopApp(restartApp)
        defer { relaunch.forEach(DesktopApp.launch) }

        try captureCurrentLogin()
        try SecureFS.writePrivateFileAtomically(targetRaw, to: paths.authFile)
        guard let written = try currentSnapshot(), written.identity.key == target.key else {
            throw ToolError("写入后校验失败：auth.json 与目标账号不一致，可用 undo 恢复")
        }

        index.accounts[position].lastSwitchedAt = Date()
        try index.save(paths)
        log("✓ 已切换到 #\(position + 1) \(target.label)\(describePlan(target.plan))")
        reportAfterSwitch(restarted: !relaunch.isEmpty)
    }

    /// 把 auth.json 恢复为上一次切换前的状态；再次执行会切回来。
    mutating func undo(restartApp: Bool) throws {
        guard let snapshot = try keychain.get(account: Keychain.undoAccount) else {
            throw ToolError("没有可撤销的切换记录")
        }
        guard (try? JSONSerialization.jsonObject(with: snapshot)) is [String: Any] else {
            throw ToolError("撤销快照已损坏，拒绝写入")
        }
        try checkCodexDirWritable()
        let relaunch = try prepareDesktopApp(restartApp)
        defer { relaunch.forEach(DesktopApp.launch) }

        let previous = try captureCurrentLogin(saveUndo: false)
        try SecureFS.writePrivateFileAtomically(snapshot, to: paths.authFile)
        if let previous {
            try keychain.set(previous, account: Keychain.undoAccount, label: "codex-switch: 切换前快照")
        } else {
            try keychain.delete(account: Keychain.undoAccount)
        }
        try index.save(paths)
        let restored = (try? currentSnapshot())?.identity
        log("✓ 已恢复到切换前的登录：\(restored?.email ?? restored?.accountId ?? "（非 ChatGPT 登录）")")
        reportAfterSwitch(restarted: !relaunch.isEmpty)
    }

    /// 切走前先把当前 auth.json 存回账号库（Codex 可能已轮换了 refresh_token），
    /// 并把原始内容存为撤销快照。返回当前 auth.json 原始内容。
    @discardableResult
    private mutating func captureCurrentLogin(saveUndo: Bool = true) throws -> Data? {
        guard SecureFS.exists(paths.authFile) else { return nil }
        let raw = try SecureFS.readPrivateFile(paths.authFile)
        if let snap = try? parseAuth(raw) {
            let (i, result) = try upsert(snap, label: nil)
            switch result {
            case .created: log("· 当前登录 \(index.accounts[i].label) 尚未保存，已自动加入账号库（#\(i + 1)）")
            case .updated: log("· 已把 #\(i + 1) 刷新后的令牌存回钥匙串")
            case .unchanged, .skippedOlder: break
            }
        } else {
            warn("当前 auth.json 不是可管理的 ChatGPT 登录，仅保存为撤销快照")
        }
        if saveUndo {
            try keychain.set(raw, account: Keychain.undoAccount, label: "codex-switch: 切换前快照")
        }
        return raw
    }

    private func checkCodexDirWritable() throws {
        try SecureFS.ensureDirectoryExists(paths.codexDir)
        guard let (mine, mode) = SecureFS.ownerAndMode(paths.codexDir), mine else {
            throw ToolError("\(paths.codexDir.path) 不属于当前用户，拒绝写入令牌")
        }
        if mode & 0o002 != 0 {
            throw ToolError("\(paths.codexDir.path) 对所有用户可写，拒绝写入令牌；运行 doctor --fix 修复")
        }
        if mode & 0o020 != 0 {
            warn("\(paths.codexDir.path) 对同组用户可写（\(octal(mode))），建议运行 doctor --fix")
        }
    }

    /// 应用运行时会在内存里持有旧令牌，并可能在退出时把它写回 auth.json，
    /// 所以必须先退出应用再切换。返回需要重新打开的 bundle id。
    private func prepareDesktopApp(_ restart: Bool) throws -> [String] {
        let apps = DesktopApp.running()
        guard !apps.isEmpty else { return [] }
        guard restart else {
            warn("未重启应用：它会继续使用旧账号，且可能在退出时把旧令牌写回 auth.json")
            return []
        }
        let ids = Array(Set(apps.compactMap(\.bundleIdentifier)))
        log("· 正在退出应用…")
        guard DesktopApp.quit() else {
            throw ToolError("应用未在 20 秒内退出（可能有未保存的对话框），已取消，auth.json 未改动")
        }
        return ids
    }

    private func reportAfterSwitch(restarted: Bool) {
        if restarted { log("· 正在重新打开应用") }
        if DesktopApp.running().isEmpty || restarted {
            let stray = DesktopApp.strayCLIProcessCount()
            if stray > 0 { warn("有 \(stray) 个 codex CLI 进程仍在运行，重启它们后才会使用新账号") }
        }
    }

    private func warn(_ message: String) { log("! \(message)") }

    // MARK: - 维护

    mutating func remove(_ position: Int) throws {
        let meta = index.accounts[position]
        try keychain.delete(account: Keychain.accountKey(meta.id))
        index.accounts.remove(at: position)
        try index.save(paths)
    }
}

func describePlan(_ plan: String?) -> String {
    plan.map { "（\($0)）" } ?? ""
}

func octal(_ mode: mode_t) -> String { "0" + String(mode, radix: 8) }

/// 命令行与图形界面共用的入口：按环境变量定位数据目录与钥匙串服务。
func makeManager() throws -> Manager {
    let service = ProcessInfo.processInfo.environment["CODEX_SWITCH_KEYCHAIN_SERVICE"] ?? "com.local.codex-switch"
    return try Manager(paths: Paths.resolve(), keychain: Keychain(service: service))
}

/// 锁放在数据目录里，Manager 初始化前需要先确保目录存在。
func acquireLock() throws -> ProcessLock {
    let paths = Paths.resolve()
    try SecureFS.ensurePrivateDirectory(paths.dataDir)
    return try ProcessLock(at: paths.lockFile)
}
