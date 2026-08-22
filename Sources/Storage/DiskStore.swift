import Foundation

/// 磁盘上的索引文件。
///
/// 只有元数据和**相对路径**，内容本体在 `blobs/` 下。
/// 🚨 绝对不要把图片 base64 进来 —— 几十张截图就能把这个文件撑到几百 MB，
/// 每次启动全量反序列化会明显卡顿。
struct PerchIndex: Codable, Sendable {

    /// 格式版本。以后要迁移时靠它分支，现在只写不读。
    var version: Int = 1
    var clipboardItems: [PerchItem] = []
    var fileItems: [PerchItem] = []
}

/// `index.json` 的读写，以及应用支持目录的位置。
enum DiskStore {

    /// 存储目录的覆盖开关，**只给离线测试用**（`script/test_persistence.sh`）。
    ///
    /// 为什么需要它：macOS 上 `NSHomeDirectory()` 走的是 `getpwuid`，**完全无视 `HOME` 环境变量**，
    /// 所以测试脚本没有别的办法把读写引到一个临时目录里去。
    /// 而那个脚本要验「抹掉全部数据」—— 那是真删磁盘，绝不能打到用户真实的目录上。
    ///
    /// 正常运行时这个变量不存在，走下面的标准路径。
    private static let overrideKey = "PERCH_SUPPORT_DIR"

    /// `~/Library/Application Support/Perch/`
    ///
    /// 沙盒关闭，所以这里拿到的是用户真实的家目录，
    /// 不是 `~/Library/Containers/...` 下的容器路径。
    static var applicationSupportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[overrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

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

    // MARK: - 编解码
    //
    // 日期用 ISO8601 而不是默认的 timeIntervalSinceReferenceDate：
    // 这个文件用户随时可以打开看，`766283472.9` 谁也读不出是什么时候。
    // 两边的策略必须成对，改一处就要改另一处。

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - 读写

    /// 读索引。文件不存在（首次运行）返回空索引，不是错误。
    ///
    /// 内容坏掉时**不抛**，返回空索引并把坏文件改名留在原地：
    /// 抛出去的话启动流程就得处理「用户的历史全没了」，而这里能做的也只有从空开始。
    /// 留一份 `.corrupt` 是为了事后还能捞。
    static func load() -> PerchIndex {
        guard let data = try? Data(contentsOf: indexURL) else { return PerchIndex() }

        do {
            return try decoder.decode(PerchIndex.self, from: data)
        } catch {
            NSLog("[Perch] index.json 解析失败，从空索引开始：\(error)")
            let backup = indexURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: indexURL, to: backup)
            return PerchIndex()
        }
    }

    static func save(_ index: PerchIndex) throws {
        try ensureDirectoryExists()
        try writeAtomically(encoder.encode(index), to: indexURL)
    }

    /// 抹掉全部数据：索引 + 全部本体。
    static func wipe() {
        try? FileManager.default.removeItem(at: indexURL)
        try? FileManager.default.removeItem(at: indexURL.appendingPathExtension("corrupt"))
        try? FileManager.default.removeItem(at: BlobStore.rootDirectory)
    }

    /// 原子写：先写 `.tmp` 再 rename。
    ///
    /// 直接往 index.json 上覆盖写，中途崩溃会留下一个截断的 JSON，
    /// 下次启动整份历史都读不出来。rename 在同一文件系统内是原子操作。
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // replaceItemAt 在目标不存在时会失败（首次运行就是这种情况），退回直接改名。
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
