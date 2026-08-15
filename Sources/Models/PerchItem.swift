import Foundation

/// 条目类型。
///
/// 判定优先级（M2 的 ClipboardWatcher 依赖这个顺序）：
/// 图片 > 文件 URL > 链接 > 纯文本。
enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case link
    case image
    case file

    /// 剪贴板区显示的类型，文件走独立的文件区。
    var belongsToClipboardSection: Bool { self != .file }
}

/// 架上的一条内容。
///
/// 硬性约定：图片和文件的**本体以文件形式存在 blobs/ 下**，这里只存相对路径。
/// 绝对不要把图片以 base64 / dataURL 塞进来 —— 几十张截图就会把 index.json
/// 撑到几百 MB，每次启动全量反序列化会明显卡顿。
struct PerchItem: Codable, Identifiable, Sendable, Hashable {

    let id: UUID
    let kind: ItemKind

    /// 列表里显示的文字。文本是内容摘要，文件是文件名。
    var preview: String

    /// 相对 `blobs/` 的路径。图片和文件必填，纯文本和链接为 nil。
    var blobPath: String?

    /// 缩略图相对路径。
    var thumbPath: String?

    var byteSize: Int64

    /// 去重键：文本/链接 = 内容全文；图片/文件 = 文件名 + 字节数。
    /// 只和「当前区域最新的那一条」比较，不遍历全表、不做哈希。
    var dedupKey: String

    /// 同时也是「上次刷新时间」—— 去重命中时重置为现在，倒计时随之重算。
    var createdAt: Date

    /// 固定的条目永不过期，也不参与数量上限的淘汰。
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        kind: ItemKind,
        preview: String,
        blobPath: String? = nil,
        thumbPath: String? = nil,
        byteSize: Int64 = 0,
        dedupKey: String,
        createdAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.blobPath = blobPath
        self.thumbPath = thumbPath
        self.byteSize = byteSize
        self.dedupKey = dedupKey
        self.createdAt = createdAt
        self.isPinned = isPinned
    }
}
