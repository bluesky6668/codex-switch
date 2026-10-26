// 额度查询（5 小时 / 每周窗口），并执行以下安全限制：
// - 只访问写死的 chatgpt.com 与 auth.openai.com，不读 config.toml 里的自定义地址，
//   也不信任令牌里的 iss，避免令牌被发往其他主机；
// - 拒绝重定向，不保存 Cookie 与缓存；
// - 当前登录账号的令牌只读不刷新：刷新会轮换 refresh_token，把 ChatGPT 应用登出。
import Foundation

struct UsageWindow: Codable, Equatable {
    var usedPercent: Double
    var windowSeconds: Int
    var resetAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct UsageSnapshot: Codable, Equatable {
    var fiveHour: UsageWindow?
    var oneWeek: UsageWindow?
    var plan: String?
    var fetchedAt: Date
}

struct UsageCredentials {
    let accessToken: String
    let accountId: String
    let isCurrent: Bool
    let refreshed: Bool
}

enum UsageAPI {
    struct Unauthorized: Error, CustomStringConvertible {
        let status: Int
        var description: String { "额度接口拒绝了令牌（HTTP \(status)）" }
    }

    static func fetch(_ credentials: UsageCredentials) throws -> UsageSnapshot {
        var lastError: Error = ToolError("额度接口不可用")
        // 仅使用 chatgpt.com 上的两个固定地址；前者 404 时再试后者。
        for path in ["/backend-api/wham/usage", "/api/codex/usage"] {
            var request = URLRequest(url: URL(string: "https://chatgpt.com\(path)")!)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (status, body) = try HTTP.send(request)
            switch status {
            case 200..<300: return try parse(body)
            case 401, 403: throw Unauthorized(status: status)
            case 404: lastError = ToolError("额度接口返回 404")
            default: throw ToolError("额度接口返回 HTTP \(status)")
            }
        }
        throw lastError
    }

    /// 解析接口返回：收集所有窗口，按时长挑出 5 小时与 7 天窗口。
    static func parse(_ body: Data) throws -> UsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw ToolError("额度接口返回的不是 JSON")
        }
        var windows: [UsageWindow] = []
        func collect(_ rateLimit: Any?) {
            guard let rateLimit = rateLimit as? [String: Any] else { return }
            for key in ["primary_window", "secondary_window"] {
                guard let raw = rateLimit[key] as? [String: Any],
                      let used = (raw["used_percent"] as? NSNumber)?.doubleValue,
                      let seconds = (raw["limit_window_seconds"] as? NSNumber)?.intValue else { continue }
                let reset = (raw["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(UsageWindow(usedPercent: used, windowSeconds: seconds, resetAt: reset))
            }
        }
        collect(root["rate_limit"])
        for extra in root["additional_rate_limits"] as? [[String: Any]] ?? [] { collect(extra["rate_limit"]) }

        // 只有一个窗口时，不把周窗口误当成 5 小时窗口显示。
        func nearest(_ target: Int, within range: ClosedRange<Int>) -> UsageWindow? {
            windows.filter { range.contains($0.windowSeconds) }
                .min { abs($0.windowSeconds - target) < abs($1.windowSeconds - target) }
        }
        return UsageSnapshot(
            fiveHour: nearest(5 * 3600, within: 0...(24 * 3600)),
            oneWeek: nearest(7 * 86400, within: (2 * 86400)...Int.max),
            plan: (root["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            fetchedAt: Date())
    }
}

/// 用 refresh_token 换新令牌，返回更新后的完整 auth.json。只用于未在使用中的已保存账号。
enum TokenRefresher {
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func refresh(_ raw: Data) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw ToolError("令牌数据缺少 refresh_token，无法续期")
        }
        // client_id 取自 id_token 的 aud（Codex 的应用 id 都以 app_ 开头），否则用 Codex 默认值。
        let aud = (tokens["id_token"] as? String).flatMap(decodeJWTPayload)?["aud"]
        let clientID = ((aud as? String) ?? (aud as? [String])?.first).flatMap { $0.hasPrefix("app_") ? $0 : nil }
            ?? codexClientID

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        // URLComponents 不转义 +，而它在表单里表示空格。
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)

        let (status, body) = try HTTP.send(request)
        guard (200..<300).contains(status) else {
            let hint = status == 400 || status == 401 ? "，登录可能已失效，请重新登录该账号" : ""
            throw ToolError("续期令牌失败（HTTP \(status)）\(hint)")
        }
        guard let fresh = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let access = fresh["access_token"] as? String, let id = fresh["id_token"] as? String else {
            throw ToolError("续期令牌的返回格式不正确")
        }
        tokens["access_token"] = access
        tokens["id_token"] = id
        if let rotated = fresh["refresh_token"] as? String, !rotated.isEmpty { tokens["refresh_token"] = rotated }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    }
}

/// 最小 HTTP 客户端：主机白名单、拒绝重定向、无 Cookie、无缓存。
enum HTTP {
    private static let allowedHosts: Set<String> = ["chatgpt.com", "auth.openai.com"]

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = ["User-Agent": "codex-switch/\(toolVersion)"]
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest) throws -> (Int, Data) {
        guard request.url?.scheme == "https", let host = request.url?.host, allowedHosts.contains(host) else {
            throw ToolError("拒绝访问未授权的地址")
        }
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), Error> = .failure(ToolError("网络请求未完成"))
        session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(ToolError("网络请求失败：\(error.localizedDescription)"))
            } else {
                result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}

// MARK: - 账号库中的额度

extension Manager {
    /// 取查询额度用的凭据（需持锁调用）。当前账号读 auth.json 且绝不刷新；
    /// 其他账号读钥匙串，access token 即将过期或 forceRefresh 时先续期并存回钥匙串。
    mutating func usageCredentials(id: String, forceRefresh: Bool) throws -> UsageCredentials {
        guard let i = index.accounts.firstIndex(where: { $0.id == id }) else { throw ToolError("账号已不存在") }
        let meta = index.accounts[i]
        if let current = try? currentSnapshot(), current.identity.key == meta.key {
            if forceRefresh { throw ToolError("当前账号的令牌已过期，ChatGPT/Codex 会自动续期，稍后再刷新") }
            return UsageCredentials(accessToken: current.accessToken, accountId: meta.accountId,
                                    isCurrent: true, refreshed: false)
        }
        guard let raw = try keychain.get(account: Keychain.accountKey(meta.id)) else {
            throw ToolError("钥匙串中找不到令牌")
        }
        var snap = try parseAuth(raw)
        guard snap.identity.key == meta.key else { throw ToolError("钥匙串内容与账号身份不一致") }

        let expiresSoon = snap.accessTokenExpiry.map { $0 < Int64(Date().timeIntervalSince1970) + 300 } ?? false
        guard forceRefresh || expiresSoon else {
            return UsageCredentials(accessToken: snap.accessToken, accountId: meta.accountId,
                                    isCurrent: false, refreshed: false)
        }
        let freshRaw = try TokenRefresher.refresh(raw)
        let fresh = try parseAuth(freshRaw)
        guard fresh.identity.key == meta.key else { throw ToolError("续期返回的令牌不属于该账号，已丢弃") }
        try keychain.set(freshRaw, account: Keychain.accountKey(meta.id), label: "codex-switch: \(meta.label)")
        index.accounts[i].updatedAt = Date()
        try index.save(paths)
        snap = fresh
        return UsageCredentials(accessToken: snap.accessToken, accountId: meta.accountId,
                                isCurrent: false, refreshed: true)
    }

    mutating func storeUsage(_ result: Result<UsageSnapshot, Error>, id: String) throws {
        guard let i = index.accounts.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case let .success(usage):
            index.accounts[i].usage = usage
            index.accounts[i].usageError = nil
            if let plan = usage.plan { index.accounts[i].plan = plan }
        case let .failure(error):
            // 保留上一次的额度数据，只记录错误。
            index.accounts[i].usageError = "\(error)"
        }
        try index.save(paths)
    }
}

func withLockedManager<T>(_ body: (inout Manager) throws -> T) throws -> T {
    let lock = try acquireLock()
    defer { withExtendedLifetime(lock) {} }
    var manager = try makeManager()
    return try body(&manager)
}

/// 查询一个账号的额度并写入账号库。网络请求不持锁，只在取凭据、续期、保存时短暂持锁，
/// 所以查询期间仍可正常切换账号。
@discardableResult
func fetchAndStoreUsage(accountID id: String) throws -> UsageSnapshot {
    var credentials = try withLockedManager { try $0.usageCredentials(id: id, forceRefresh: false) }
    var result: Result<UsageSnapshot, Error>
    do {
        result = .success(try UsageAPI.fetch(credentials))
    } catch let error as UsageAPI.Unauthorized where credentials.isCurrent {
        result = .failure(ToolError("当前账号的令牌暂时失效（HTTP \(error.status)），ChatGPT/Codex 运行时会自动续期"))
    } catch is UsageAPI.Unauthorized where !credentials.refreshed {
        do {
            credentials = try withLockedManager { try $0.usageCredentials(id: id, forceRefresh: true) }
            result = Result { try UsageAPI.fetch(credentials) }
        } catch {
            result = .failure(error)
        }
    } catch {
        result = .failure(error)
    }
    let final = result
    try withLockedManager { try $0.storeUsage(final, id: id) }
    return try final.get()
}
