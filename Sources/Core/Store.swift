// 路径与账号索引。索引只含元数据（邮箱、计划、时间），不含任何令牌。
import Foundation

struct Paths {
    let dataDir: URL
    let codexDir: URL
    var indexFile: URL { dataDir.appendingPathComponent("accounts.json") }
    var lockFile: URL { dataDir.appendingPathComponent(".lock") }
    var authFile: URL { codexDir.appendingPathComponent("auth.json") }
    var configFile: URL { codexDir.appendingPathComponent("config.toml") }

    static func resolve() -> Paths {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = env["CODEX_SWITCH_HOME"].flatMap(nonEmptyPath)
            ?? home.appendingPathComponent("Library/Application Support/codex-switch")
        // 与 Codex 本身一致：CODEX_HOME 优先，否则 ~/.codex。
        let codexDir = env["CODEX_HOME"].flatMap(nonEmptyPath) ?? home.appendingPathComponent(".codex")
        return Paths(dataDir: dataDir, codexDir: codexDir)
    }

    private static func nonEmptyPath(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }
}

struct AccountMeta: Codable {
    var id: String
    var label: String
    var email: String?
    var principal: String
    var accountId: String
    var plan: String?
    var addedAt: Date
    var updatedAt: Date
    var lastSwitchedAt: Date?
    /// 最近一次查询到的额度（只有百分比和重置时间，不含令牌）。
    var usage: UsageSnapshot? = nil
    var usageError: String? = nil

    var key: String { "\(principal)|\(accountId)" }
    var shortAccountId: String { String(accountId.prefix(8)) }
}

struct AccountIndex: Codable {
    var version = 1
    var accounts: [AccountMeta] = []

    static func load(_ paths: Paths) throws -> AccountIndex {
        guard SecureFS.exists(paths.indexFile) else { return AccountIndex() }
        let data = try SecureFS.readPrivateFile(paths.indexFile, maxBytes: 4 << 20)
        do {
            return try decoder.decode(AccountIndex.self, from: data)
        } catch {
            throw ToolError("账号索引损坏（\(paths.indexFile.path)），可运行 doctor --fix 从钥匙串重建")
        }
    }

    func save(_ paths: Paths) throws {
        try SecureFS.ensurePrivateDirectory(paths.dataDir)
        try SecureFS.writePrivateFileAtomically(try Self.encoder.encode(self), to: paths.indexFile)
    }

    /// 选择器：列表序号、内部 id 前缀（≥4 位）、标签或邮箱（不区分大小写）。
    func resolve(_ selector: String) throws -> Int {
        if let n = Int(selector) {
            guard n >= 1 && n <= accounts.count else { throw ToolError("没有第 \(n) 个账号，用 list 查看") }
            return n - 1
        }
        let lowered = selector.lowercased()
        let byName = accounts.indices.filter {
            accounts[$0].label.lowercased() == lowered || accounts[$0].email?.lowercased() == lowered
        }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw ToolError("“\(selector)” 匹配到多个账号，请用序号") }
        if lowered.count >= 4 {
            let byId = accounts.indices.filter { accounts[$0].id.hasPrefix(lowered) }
            if byId.count == 1 { return byId[0] }
        }
        throw ToolError("找不到账号 “\(selector)”，用 list 查看")
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
