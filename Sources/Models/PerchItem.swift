import Foundation

/// 条目类型。
///
/// 判定优先级（M2 的 ClipboardWatcher 依赖这个顺序）：
/// 图片 > 文件 URL > 链接 > 代码 > 纯文本。
///
/// 🚨 代码排在**链接之后**：`https://…` 在代码片段里也很常见，
/// 链接先判才不会把一行 URL 吃成代码。
enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case link
    case image
    case code
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

    /// 代码片段的语言（`swift` / `python` / `json` …），行内那个小标签显示它。
    ///
    /// **只有 `.code` 会有值**，其余类型恒为 nil。反过来也成立：
    /// 认不出语言的代码不会被判成 `.code`（见 `CodeDetector`），
    /// 所以 `kind == .code` 时这里一定非空。
    ///
    /// 旧的 `index.json` 里没有这个键 —— Optional 走 `decodeIfPresent`，
    /// 老数据照常读得出来，不需要迁移。
    var language: String?

    var byteSize: Int64

    /// 去重键：文本/链接 = 内容全文；图片/文件 = 文件名 + 字节数。
    /// 只和「当前区域最新的那一条」比较，不遍历全表、不做哈希。
    var dedupKey: String

    /// 同时也是「上次刷新时间」—— 去重命中时重置为现在，倒计时随之重算。
    ///
    /// 列表顺序按它排（新的在最前），所以**只有「该提到最前」的时候才动它**。
    var createdAt: Date

    /// 保存时长的**起算点**。倒计时从这里加上当前设置的时长。
    ///
    /// 为什么不直接存一个 `expiresAt`：那样改设置就只能影响新条目，
    /// 「保存时长改成 1 小时」却发现三小时前的东西还在，是说不通的。
    /// 存起算点则是设置一改、全表立刻按新时长重算。
    ///
    /// 和 `createdAt` 分成两个字段，是因为它们有一处会分叉：
    /// **取消固定时倒计时从当下重新起算，但条目不该因此跳到列表最前**（见 `PerchStore.togglePin`）。
    ///
    /// 老的 `index.json` 里没有这个键 —— Optional 走 `decodeIfPresent`，
    /// 读出来是 nil，`retentionAnchor` 会退回 `createdAt`。
    var retentionStartedAt: Date?

    /// 固定的条目永不过期，也不参与数量上限的淘汰。
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        kind: ItemKind,
        preview: String,
        blobPath: String? = nil,
        thumbPath: String? = nil,
        language: String? = nil,
        byteSize: Int64 = 0,
        dedupKey: String,
        createdAt: Date = Date(),
        retentionStartedAt: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.blobPath = blobPath
        self.thumbPath = thumbPath
        self.language = language
        self.byteSize = byteSize
        self.dedupKey = dedupKey
        self.createdAt = createdAt
        self.retentionStartedAt = retentionStartedAt
        self.isPinned = isPinned
    }
}

// MARK: - 过期

extension PerchItem {

    /// 倒计时的起算点。没记过就是上架那一刻。
    var retentionAnchor: Date { retentionStartedAt ?? createdAt }

    /// 什么时候会被清理。返回 nil = 永不过期（固定项，或保存时长设成「永不」）。
    ///
    /// 🚨 **保存时长是唯一的自动清理依据**，没有别的隐藏触发条件（占用超标、条数超标都不算 ——
    /// 条数超标走的是淘汰，见 `PerchStore.enforceClipboardLimit`，那是另一回事）。
    func expiryDate(under retention: Janitor.Retention) -> Date? {
        guard !isPinned, let interval = retention.timeInterval else { return nil }
        return retentionAnchor.addingTimeInterval(interval)
    }

    func isExpired(at now: Date, under retention: Janitor.Retention) -> Bool {
        guard let expiry = expiryDate(under: retention) else { return false }
        return expiry <= now
    }
}
