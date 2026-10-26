// 解析 Codex auth.json，识别账号身份并比较令牌新旧。
import Foundation

/// 单个 auth.json 文件的大小上限，防止误读巨型文件。
let maxAuthFileBytes = 1 << 20

struct AuthIdentity: Equatable {
    /// 小写邮箱；没有邮箱时退回 chatgpt_user_id / sub / account_id。
    let principal: String
    let accountId: String
    let email: String?
    let plan: String?

    /// 同一邮箱的个人空间和团队空间视为两个不同账号。
    var key: String { "\(principal)|\(accountId)" }
}

struct AuthSnapshot {
    /// 原始字节，切换时原样写回，保留 Codex 写入的全部字段。
    let raw: Data
    let identity: AuthIdentity
    let refreshToken: String
    let accessToken: String
    /// access token 的过期时间（JWT exp，秒）。
    let accessTokenExpiry: Int64?
    let lastRefresh: Int64?
    let hasStoredAPIKey: Bool
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func parseAuth(_ raw: Data) throws -> AuthSnapshot {
    guard raw.count <= maxAuthFileBytes else { throw ToolError("auth.json 超过 1 MiB，拒绝处理") }
    // 解析失败时不回显内容，避免令牌出现在终端或日志里。
    guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
        throw ToolError("auth.json 不是合法的 JSON 对象")
    }

    let mode = (root["auth_mode"] as? String)?.lowercased() ?? ""
    let tokens = (root["tokens"] as? [String: Any])
        ?? ((root["access_token"] != nil && root["id_token"] != nil) ? root : nil)
    guard let tokens else {
        if !mode.isEmpty && mode != "chatgpt" && mode != "chatgpt_auth_tokens" {
            throw ToolError("当前不是 ChatGPT 登录模式（auth_mode=\(mode)），无法作为账号管理")
        }
        throw ToolError("auth.json 未包含 ChatGPT 登录令牌；若 Codex 配置为钥匙串存储，请先改为文件存储（见 doctor）")
    }

    guard let accessToken = nonEmpty(tokens["access_token"]) else { throw ToolError("auth.json 缺少 access_token") }
    guard let idToken = nonEmpty(tokens["id_token"]) else { throw ToolError("auth.json 缺少 id_token") }
    guard let refreshToken = nonEmpty(tokens["refresh_token"]) else {
        throw ToolError("auth.json 缺少 refresh_token，切换后无法自动续期")
    }

    var accountId = nonEmpty(tokens["account_id"])
    var email: String?
    var plan: String?
    var principal: String?
    if let claims = decodeJWTPayload(idToken) {
        email = nonEmpty(claims["email"])
        let authClaim = claims["https://api.openai.com/auth"] as? [String: Any]
        if accountId == nil { accountId = nonEmpty(authClaim?["chatgpt_account_id"]) }
        plan = nonEmpty(authClaim?["chatgpt_plan_type"])
        principal = email.flatMap(normalizePrincipal)
            ?? nonEmpty(authClaim?["chatgpt_user_id"] ?? authClaim?["user_id"]).flatMap(normalizePrincipal)
            ?? nonEmpty(claims["sub"]).flatMap(normalizePrincipal)
    }
    guard let accountId else { throw ToolError("无法从 auth.json 识别 chatgpt_account_id") }

    return AuthSnapshot(
        raw: raw,
        identity: AuthIdentity(
            principal: principal ?? accountId, accountId: accountId, email: email, plan: plan),
        refreshToken: refreshToken,
        accessToken: accessToken,
        accessTokenExpiry: (decodeJWTPayload(accessToken)?["exp"] as? NSNumber)?.int64Value,
        lastRefresh: lastRefreshSeconds(root["last_refresh"]),
        hasStoredAPIKey: nonEmpty(root["OPENAI_API_KEY"]) != nil
    )
}

/// candidate 是否带着比 reference 更新的刷新令牌。
/// Codex 刷新时会轮换 refresh_token，旧的随即失效，所以切走前必须把新令牌存回库里。
func isNewerSnapshot(_ candidate: AuthSnapshot, than reference: AuthSnapshot) -> Bool {
    if candidate.refreshToken == reference.refreshToken { return false }
    switch (candidate.lastRefresh, reference.lastRefresh) {
    case let (c?, r?): return c >= r
    case (.some, nil): return true
    default: return false
    }
}

private func nonEmpty(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return nil }
    return text
}

private func normalizePrincipal(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    return trimmed.contains("@") ? trimmed.lowercased() : trimmed
}

func decodeJWTPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return nil }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func lastRefreshSeconds(_ value: Any?) -> Int64? {
    func normalize(_ ts: Int64) -> Int64 { abs(ts) >= 1_000_000_000_000 ? ts / 1000 : ts }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        return normalize(number.int64Value)
    }
    guard let text = nonEmpty(value) else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Codex 写入的小数秒可能超过 3 位，Foundation 不一定能解析，失败时去掉小数部分再试。
    let plain = ISO8601DateFormatter()
    let truncated = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    if let date = withFraction.date(from: text) ?? plain.date(from: text) ?? plain.date(from: truncated) {
        return Int64(date.timeIntervalSince1970)
    }
    return Int64(text).map(normalize)
}
