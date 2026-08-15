import Foundation

/// 全应用唯一的数据源。
///
/// M3 接入磁盘持久化与去重，M2 接入剪贴板写入。
/// 现在只提供两个分区的空集合，供视图层绑定。
@MainActor
final class PerchStore: ObservableObject {

    static let shared = PerchStore()

    /// 剪贴板区，最多 200 条，超出淘汰最旧的（固定项不参与淘汰）。
    @Published private(set) var clipboardItems: [PerchItem] = []

    /// 文件区，不设条数上限，但要显示总占用。
    @Published private(set) var fileItems: [PerchItem] = []

    /// 剪贴板监听是否已暂停。面板头部的 ⏸ 按钮绑定这个状态，跨重启保留。
    @Published var isMonitoringPaused: Bool = Preferences.isMonitoringPaused {
        didSet { Preferences.isMonitoringPaused = isMonitoringPaused }
    }

    /// 文件区的选中态。多选拖出要用。
    ///
    /// ⌘A / Esc 这两个键盘入口做不了：面板 `canBecomeKey = false`，收不到键盘事件。
    /// 要支持得挂全局 `NSEvent` 监听，那是 M4 连同批量操作条一起做的事。
    @Published var selectedFileIDs: Set<UUID> = []

    private init() {}

    // MARK: - 写入

    /// 上架一条内容，按类型自动分区。新的排在最前。
    ///
    /// M3 在这里接去重（只和当前区域最新一条比）、数量上限与持久化。
    func add(_ item: PerchItem) {
        if item.kind.belongsToClipboardSection {
            clipboardItems.insert(item, at: 0)
        } else {
            fileItems.insert(item, at: 0)
        }
    }

    /// 取剪贴板区第 N 条（从 0 开始）。⌘1–⌘9 用。
    func clipboardItem(at index: Int) -> PerchItem? {
        clipboardItems.indices.contains(index) ? clipboardItems[index] : nil
    }

    // MARK: - 固定与移除

    /// 双击整行切换固定。固定的条目永不过期，也不参与数量上限的淘汰（M3）。
    func togglePin(_ id: UUID) {
        if let index = clipboardItems.firstIndex(where: { $0.id == id }) {
            clipboardItems[index].isPinned.toggle()
        } else if let index = fileItems.firstIndex(where: { $0.id == id }) {
            fileItems[index].isPinned.toggle()
        }
    }

    /// 手动移除一条。
    ///
    /// 本体要同步删掉：只从数组里拿掉的话，`blobs/<uuid>/` 会永远留在磁盘上 ——
    /// 索引里再也没有人指向它，M3 的自动清理也扫不到，就是纯粹的孤儿。
    func remove(_ id: UUID) {
        clipboardItems.removeAll { $0.id == id }
        fileItems.removeAll { $0.id == id }
        selectedFileIDs.remove(id)
        BlobStore.removeDirectory(for: id)
    }

    // MARK: - 选中

    /// `extending` 为真（按住 ⌘ / Shift）时累加，否则只选这一个。
    func toggleSelection(_ id: UUID, extending: Bool) {
        if extending {
            if selectedFileIDs.contains(id) {
                selectedFileIDs.remove(id)
            } else {
                selectedFileIDs.insert(id)
            }
        } else {
            selectedFileIDs = [id]
        }
    }

    func clearSelection() {
        selectedFileIDs.removeAll()
    }

    /// 从某个格子起拖时，实际应该拖走哪些。
    ///
    /// 规则和访达一致：拖一个**已在选中集里**的格子 → 拖走整个选中集；
    /// 拖一个没选中的格子 → 只拖它自己（并且不改变选中态）。
    func dragPayload(startingFrom item: PerchItem) -> [PerchItem] {
        guard selectedFileIDs.count > 1, selectedFileIDs.contains(item.id) else { return [item] }
        return fileItems.filter { selectedFileIDs.contains($0.id) }
    }

    /// 缩略图是异步生成的，条目先上架、缩略图后到。
    func setThumbnail(_ path: String, for id: UUID) {
        if let index = fileItems.firstIndex(where: { $0.id == id }) {
            fileItems[index].thumbPath = path
        } else if let index = clipboardItems.firstIndex(where: { $0.id == id }) {
            clipboardItems[index].thumbPath = path
        }
    }

    var totalByteSize: Int64 {
        (clipboardItems + fileItems).reduce(0) { $0 + $1.byteSize }
    }

    var isEmpty: Bool {
        clipboardItems.isEmpty && fileItems.isEmpty
    }
}
