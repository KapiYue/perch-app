import Foundation

/// `index.json` 的读写，以及应用支持目录的位置。
///
/// M3 实现完整的加载与保存。目录计算现在就定下来，
/// 因为 BlobStore 和 Janitor 都要用同一套路径。
enum DiskStore {

    /// `~/Library/Application Support/Perch/`
    ///
    /// 沙盒关闭，所以这里拿到的是用户真实的家目录，
    /// 不是 `~/Library/Containers/...` 下的容器路径。
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return base.appendingPathComponent("Perch", isDirectory: true)
    }

    /// 条目元数据。只存路径，不存内容本体。
    static var indexURL: URL {
        applicationSupportDirectory.appendingPathComponent("index.json", isDirectory: false)
    }

    /// 确保目录存在。
    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
    }

    /// 原子写：先写 `.tmp` 再 rename。
    ///
    /// 直接往 index.json 上覆盖写，中途崩溃会留下一个截断的 JSON，
    /// 下次启动整份历史都读不出来。rename 在同一文件系统内是原子操作。
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
