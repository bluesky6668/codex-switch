// 带安全检查的文件读写：拒绝符号链接与他人所有的文件，私有权限原子写入。
import Foundation

enum SecureFS {
    /// 读取普通文件。O_NOFOLLOW 拒绝符号链接，防止 auth.json 被替换成指向别处的链接。
    static func readPrivateFile(_ url: URL, maxBytes: Int = maxAuthFileBytes) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw ToolError("\(url.path) 是符号链接，出于安全考虑拒绝读取") }
            throw ToolError("无法读取 \(url.path)：\(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ToolError("无法读取 \(url.path) 的文件信息") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ToolError("\(url.path) 不是普通文件") }
        guard info.st_uid == getuid() else { throw ToolError("\(url.path) 不属于当前用户，拒绝读取") }
        guard info.st_size <= maxBytes else { throw ToolError("\(url.path) 过大，拒绝读取") }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw ToolError("读取 \(url.path) 失败") }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.count > maxBytes { throw ToolError("\(url.path) 过大，拒绝读取") }
        }
        buffer.resetBytes(in: 0..<buffer.count)
        return data
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// 同目录临时文件（创建瞬间即 0600）→ fsync → rename → fsync 目录。
    /// 任一步失败都不会留下半写的 auth.json。
    static func writePrivateFileAtomically(_ data: Data, to url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
            throw ToolError("\(url.path) 是符号链接，出于安全考虑拒绝覆盖")
        }

        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).codex-switch-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ToolError("无法创建临时文件：\(String(cString: strerror(errno)))") }

        var ok = false
        defer {
            if !ok { unlink(temp.path) }
        }
        let written = data.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        let synced = written && fchmod(fd, 0o600) == 0 && fsync(fd) == 0
        close(fd)
        guard synced else { throw ToolError("写入临时文件失败") }
        guard rename(temp.path, url.path) == 0 else {
            throw ToolError("替换 \(url.path) 失败：\(String(cString: strerror(errno)))")
        }
        ok = true

        let dirFd = open(dir.path, O_RDONLY | O_CLOEXEC)
        if dirFd >= 0 {
            fsync(dirFd)
            close(dirFd)
        }
    }

    /// 创建或收紧一个仅当前用户可访问的目录（0700）。
    static func ensurePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ToolError("\(url.path) 不是目录") }
        guard info.st_uid == getuid() else { throw ToolError("\(url.path) 不属于当前用户") }
        if info.st_mode & 0o077 != 0 { chmod(url.path, 0o700) }
    }

    /// 目录不存在时以 0700 创建；已存在则保持原样（权限问题交给 doctor 处理）。
    static func ensureDirectoryExists(_ url: URL) throws {
        if exists(url) { return }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// 返回 (owner 是否为当前用户, 权限位)，路径不存在时返回 nil。跟随符号链接。
    static func ownerAndMode(_ url: URL) -> (ownedByMe: Bool, mode: mode_t)? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return (info.st_uid == getuid(), info.st_mode & 0o7777)
    }

    static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// 尽力覆写后删除含明文令牌的临时文件。APFS 写时复制下无法保证物理擦除。
    static func scrubAndRemove(_ url: URL) {
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           let handle = FileHandle(forWritingAtPath: url.path) {
            handle.write(Data(count: size))
            try? handle.synchronize()
            try? handle.close()
        }
        unlink(url.path)
    }
}

/// 进程级排它锁，防止两个 codex-switch 同时改写 auth.json 和账号索引。
final class ProcessLock {
    private let fd: Int32

    init(at url: URL) throws {
        fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ToolError("无法创建锁文件 \(url.path)") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            FileHandle.standardError.write(Data("另一个 codex-switch 正在运行，等待其结束…\n".utf8))
            guard flock(fd, LOCK_EX) == 0 else { throw ToolError("获取锁失败") }
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
