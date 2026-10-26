// 在独立的临时 CODEX_HOME 里运行官方 codex login，当前登录不受影响；
// 拿到的 auth.json 存入钥匙串后立即覆写删除。
import Foundation

/// 只在一个后台线程上运行；cancel 可从主线程调用（Process.terminate 线程安全）。
final class CodexLogin: @unchecked Sendable {
    let home: URL
    private let process = Process()

    init() throws {
        guard let codex = CodexLogin.findBinary() else {
            throw ToolError("找不到 codex 命令；可设置 CODEX_SWITCH_CODEX_BIN 指向它")
        }
        let paths = Paths.resolve()
        try SecureFS.ensurePrivateDirectory(paths.dataDir)
        home = paths.dataDir.appendingPathComponent("login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        process.executableURL = codex
        process.arguments = ["login", "-c", #"cli_auth_credentials_store="file""#]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home.path
        process.environment = env
    }

    deinit { scrubRecursively(home) }

    /// output 为 nil 时继承终端输出；否则逐段回调 codex 的输出（含登录链接）。
    func run(output: ((String) -> Void)? = nil) throws -> AuthSnapshot {
        if let output {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { output(String(decoding: data, as: UTF8.self)) }
            }
        }
        try process.run()
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal { throw ToolError("登录已取消") }
        guard process.terminationStatus == 0 else {
            throw ToolError("codex login 未成功（退出码 \(process.terminationStatus)）")
        }
        let authFile = home.appendingPathComponent("auth.json")
        guard SecureFS.exists(authFile) else {
            throw ToolError("codex login 没有生成 auth.json（可能被配置为钥匙串存储）")
        }
        return try parseAuth(try SecureFS.readPrivateFile(authFile))
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }

    static func findBinary() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["CODEX_SWITCH_CODEX_BIN"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        // 图形界面启动时 PATH 很短，额外查找常见安装位置。
        let pathDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        let candidates = pathDirs.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") } + [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

extension Manager {
    /// 保存新登录的账号并写入索引，返回 (序号, 结果)。
    mutating func saveLogin(_ snap: AuthSnapshot, label: String?) throws -> (Int, UpsertResult) {
        let result = try upsert(snap, label: label, force: true)
        try index.save(paths)
        return result
    }
}
