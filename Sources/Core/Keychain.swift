// 已保存账号的令牌只存在 macOS 钥匙串里；accounts.json 不保存令牌。
// 直接调用 Security.framework，密钥不会出现在任何进程参数中。
import Foundation
import Security

struct Keychain {
    let service: String

    static let undoAccount = "undo"
    static func accountKey(_ id: String) -> String { "acct:\(id)" }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func set(_ data: Data, account: String, label: String) throws {
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
        ]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            add[kSecAttrDescription as String] = "Codex auth.json (codex-switch)"
            // 仅本机、解锁时可用；不随 iCloud 钥匙串同步，也不随备份迁移到其他设备。
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(add as CFDictionary, nil)
        }
        try check(status, "写入钥匙串")
    }

    func get(account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "读取钥匙串")
        return result as? Data
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status, "删除钥匙串条目")
    }

    /// 列出本服务下所有条目名（不读取内容，不会触发授权弹窗）。
    func allAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, "列出钥匙串条目")
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw ToolError("\(action)失败：\(message)")
    }
}
