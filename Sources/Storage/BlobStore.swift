import Foundation

/// `blobs/` 目录管理：内容本体与缩略图的落盘位置。
///
/// M1-b 接入拖入文件的拷贝，M2 接入剪贴板图片的写入，M3 接入清理。
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
}
