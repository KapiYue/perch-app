import Foundation

/// `blobs/` 目录管理：内容本体与缩略图的落盘位置。
enum BlobStore {

    /// `~/Library/Application Support/Perch/blobs/`
    static var rootDirectory: URL {
        DiskStore.applicationSupportDirectory
            .appendingPathComponent("blobs", isDirectory: true)
    }

    /// 单个条目的目录：`blobs/<uuid>/`
    static func directory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// 缩略图统一叫 thumb.jpg，本体保留原扩展名。
    static let thumbnailFilename = "thumb.jpg"

    /// 相对路径 → 绝对路径。
    ///
    /// index.json 里只存 `<uuid>/name.png` 这样的相对路径：
    /// 存绝对路径的话，用户换了home目录名或者迁移到新机器，整份索引就全指向空气了。
    static func absoluteURL(forRelativePath path: String) -> URL {
        rootDirectory.appendingPathComponent(path, isDirectory: false)
    }

    /// 删掉某条目的整个目录（本体 + 缩略图）。
    ///
    /// 目录本来就不存在（纯文本条目）不是错误，静默忽略。
    static func removeDirectory(for id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// 把内容写进 `blobs/<id>/<filename>`，返回相对路径。
    @discardableResult
    static func write(_ data: Data, filename: String, for id: UUID) throws -> String {
        let directory = directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return "\(id.uuidString)/\(filename)"
    }

    static func exists(atRelativePath path: String) -> Bool {
        FileManager.default.fileExists(atPath: absoluteURL(forRelativePath: path).path)
    }

    // MARK: - 对账

    /// 刚落地的目录不参与孤儿判定的宽限期。
    ///
    /// 🚨 这个宽限期是必须的：`copyIntoBlobs` / `ingestImage` 都是**先建目录再写文件**，
    /// 建完到条目进索引之间有一小段窗口。启动扫描恰好撞进这个窗口，
    /// 就会把用户正拖进来的东西当成孤儿删掉。
    private static let orphanGracePeriod: TimeInterval = 5 * 60

    /// 扫掉「索引里没人指向」的目录，返回删掉的个数。
    ///
    /// 为什么需要它：写盘失败会留下一个空壳目录，而索引里从来没有它 ——
    /// 按条目清理的那条路径**永远扫不到**，只能靠这里对一次账。
    /// （2026-08-22 实测在 `blobs/` 里发现过这种空目录。）
    ///
    /// 只在启动时跑一次。放在后台线程，别在主线程枚举目录。
    @discardableResult
    nonisolated static func removeOrphanDirectories(keeping liveIDs: Set<UUID>) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let cutoff = Date().addingTimeInterval(-orphanGracePeriod)
        var removed = 0

        for entry in entries {
            // 认不出 UUID 的东西一律不碰 —— 那不是我们建的，删了就是越权。
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            guard !liveIDs.contains(id) else { continue }

            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate, modified < cutoff else { continue }

            if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
        }

        return removed
    }
}
