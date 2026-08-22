import Foundation

/// 剪贴板区的类型筛选。
///
/// **单选**，而且**不持久化** —— 面板收起就回到「全部」（见 `PanelController.collapse`）。
/// 上次筛在「代码」上、这次复制了一段文本却看不见，用户只会当成 bug。
enum ClipboardFilter: String, CaseIterable, Sendable {
    case all
    case text
    case link
    case image
    case code

    /// `.all` 没有对应的类型，返回 nil 表示不过滤。
    var kind: ItemKind? {
        switch self {
        case .all: nil
        case .text: .text
        case .link: .link
        case .image: .image
        case .code: .code
        }
    }

    /// pill 上的文案。
    var titleKey: String { "filter.\(rawValue)" }
}

/// 全应用唯一的数据源。
///
/// 所有会改到条目的路径都必须经过这里 —— 去重、数量上限、落盘是绑在一起的三件事，
/// 谁绕过去直接改数组，谁那条路径就不会存盘。
@MainActor
final class PerchStore: ObservableObject {

    static let shared = PerchStore()

    /// 剪贴板区，最多 200 条，超出淘汰最旧的（固定项不参与淘汰）。
    ///
    /// **恒按 `createdAt` 倒序**（新的在最前）。插入一律 `insert(at: 0)`，
    /// 去重命中则整条搬到最前，所以不需要每次重排。
    @Published private(set) var clipboardItems: [PerchItem] = []

    /// 文件区，不设条数上限，但要显示总占用。
    @Published private(set) var fileItems: [PerchItem] = []

    /// 剪贴板监听是否已暂停。面板头部的 ⏸ 按钮绑定这个状态，跨重启保留。
    @Published var isMonitoringPaused: Bool = Preferences.isMonitoringPaused {
        didSet { Preferences.isMonitoringPaused = isMonitoringPaused }
    }

    /// 保存时长。改了立刻对全表生效（起算点在条目上，见 `PerchItem.retentionAnchor`），
    /// 所以这里改完要马上扫一遍 —— 从 7 天调到 1 小时，用户期待的是「现在就少了」。
    @Published var retention: Janitor.Retention = Preferences.retention {
        didSet {
            guard retention != oldValue else { return }
            Preferences.retention = retention
            sweepExpired()
            scheduleSave()
        }
    }

    /// 剪贴板区当前的类型筛选。**只改显示，不动数据。**
    @Published var clipboardFilter: ClipboardFilter = .all

    /// 文件区的选中态。多选拖出要用。
    ///
    /// ⌘A / Esc 这两个键盘入口做不了：面板 `canBecomeKey = false`，收不到键盘事件。
    /// 要支持得挂全局 `NSEvent` 监听，那是 M4 连同批量操作条一起做的事。
    @Published var selectedFileIDs: Set<UUID> = []

    /// 磁盘写入的合并窗口。
    ///
    /// 连着拖 10 个文件进来会连着 10 次 `add`，每次都整份 JSON 落盘就是 10 次全量写。
    /// 合并成一次。窗口不能太长 —— 被 `pkill` 掉的话，这段时间内的改动就丢了。
    private static let saveDebounce: TimeInterval = 0.6

    private var pendingSave: DispatchWorkItem?

    /// 磁盘上的历史读完了没有。没读完之前不允许落盘，
    /// 否则「启动后 0.2 秒内复制了一条」会把那一条当成全部内容覆盖掉整份历史。
    private var isLoaded = false

    private init() {}

    // MARK: - 写入

    /// 上架一条内容，按类型自动分区。新的排在最前。
    ///
    /// 三件事绑在一起：**去重 → 插入 → 淘汰 → 落盘**。
    func add(_ item: PerchItem) {
        if item.kind.belongsToClipboardSection {
            if mergeDuplicate(item, into: &clipboardItems) {
                scheduleSave()
                return
            }
            clipboardItems.insert(item, at: 0)
            enforceClipboardLimit()
        } else {
            if mergeDuplicate(item, into: &fileItems) {
                scheduleSave()
                return
            }
            fileItems.insert(item, at: 0)
        }
        scheduleSave()
    }

    /// 去重：命中就把老的那条提到最前并重置计时，**不新增**。返回是否命中。
    ///
    /// 口径取自参考稿 `docs/design/prototype/src/App.tsx` 的 `handleAddClipboard`：
    /// 遍历**整个区域**找相同内容，而不是只跟最新的一条比。
    /// 只比最新一条的话，「复制 A → 复制 B → 又复制 A」会留下两条 A，
    /// 而这恰恰是最常见的来回粘贴场景 —— 那样「提到最前」也就无从谈起了，命中的永远已经在最前。
    ///
    /// 🚨 命中时要把**新条目**已经落盘的本体删掉。图片和文件在走到这里之前
    /// 就已经写进 `blobs/<新 id>/` 了，不删就是一个索引里没人指向的孤儿。
    private func mergeDuplicate(_ incoming: PerchItem, into items: inout [PerchItem]) -> Bool {
        guard let index = items.firstIndex(where: { $0.dedupKey == incoming.dedupKey }) else {
            return false
        }

        var hit = items.remove(at: index)
        let now = Date()
        hit.createdAt = now
        // 固定项不看这个字段，但照样刷新 —— 取消固定那一刻才不会拿到一个几天前的起算点。
        hit.retentionStartedAt = now
        items.insert(hit, at: 0)

        if incoming.id != hit.id {
            BlobStore.removeDirectory(for: incoming.id)
        }
        return true
    }

    /// 超过 200 条时淘汰。
    ///
    /// 口径同样取自参考稿：**先无条件保住全部固定项**，剩下的名额再按时间从新到旧填。
    /// 固定项多到超过 200 时上限会被撑破 —— 这是有意的，
    /// 「固定」的语义就是用户明说了要留着，不能被一条数量规则悄悄抹掉。
    private func enforceClipboardLimit() {
        guard clipboardItems.count > Janitor.clipboardLimit else { return }

        // 不用 `count(where:)`：那是 Swift 6 标准库的新 API，最低要 macOS 15，本项目是 14。
        let pinnedCount = clipboardItems.lazy.filter(\.isPinned).count
        let slots = max(0, Janitor.clipboardLimit - pinnedCount)

        var kept: [PerchItem] = []
        var evicted: [PerchItem] = []
        var used = 0

        // 数组本身已是新→旧，顺着扫一遍就够，不用排序。
        for item in clipboardItems {
            if item.isPinned {
                kept.append(item)
            } else if used < slots {
                kept.append(item)
                used += 1
            } else {
                evicted.append(item)
            }
        }

        clipboardItems = kept
        evicted.forEach { BlobStore.removeDirectory(for: $0.id) }
    }

    // MARK: - 过期清理

    /// 扫一遍，把到期的清掉。启动时一次 + 每 60 秒一次（见 `Janitor`）。
    ///
    /// 固定项永不过期；保存时长设成「永不」时整个跳过。
    func sweepExpired(now: Date = Date()) {
        guard retention.timeInterval != nil else { return }

        let expiredClipboard = clipboardItems.filter { $0.isExpired(at: now, under: retention) }
        let expiredFiles = fileItems.filter { $0.isExpired(at: now, under: retention) }
        guard !expiredClipboard.isEmpty || !expiredFiles.isEmpty else { return }

        let ids = Set((expiredClipboard + expiredFiles).map(\.id))
        clipboardItems.removeAll { ids.contains($0.id) }
        fileItems.removeAll { ids.contains($0.id) }
        selectedFileIDs.subtract(ids)

        // 本体跟着走。只从数组里拿掉的话，blobs/ 下就留下一堆再也没人指向的目录。
        ids.forEach { BlobStore.removeDirectory(for: $0) }
        scheduleSave()
    }

    /// 清理全部未固定的剪贴板条目。
    ///
    /// 这是「没有对应行可闪」的操作之一，调用方要弹 toast 说清楚清了多少条（产品决定 D-2）。
    /// 返回清掉的条数。
    @discardableResult
    func clearUnpinnedClipboard() -> Int {
        let doomed = clipboardItems.filter { !$0.isPinned }
        guard !doomed.isEmpty else { return 0 }

        clipboardItems.removeAll { !$0.isPinned }
        doomed.forEach { BlobStore.removeDirectory(for: $0.id) }
        scheduleSave()
        return doomed.count
    }

    /// 抹掉全部数据：两个区清空，索引和本体一起删。
    ///
    /// 这个入口和面板上常驻的 ⏸ 是「不做密码识别」那条产品决定的配套补偿，
    /// **不能藏起来，也不能只清列表不删磁盘** —— 用户点它就是要东西真的消失。
    func wipeAllData() {
        clipboardItems.removeAll()
        fileItems.removeAll()
        selectedFileIDs.removeAll()

        // 待写的那次落盘要撤掉，否则它会把刚删掉的 index.json 又写回来。
        pendingSave?.cancel()
        pendingSave = nil
        DiskStore.wipe()
    }

    // MARK: - 持久化

    /// 启动时调一次。读盘在后台，读完再回主线程合并。
    ///
    /// 冷启动预算 300ms 全花在菜单栏图标上，这里一步都不能卡主线程。
    func loadFromDisk() {
        guard !isLoaded else { return }

        Task.detached(priority: .userInitiated) {
            let index = DiskStore.load()

            // 本体已经不在了的条目直接丢掉（用户手动删过 blobs/、或者上次写盘写失败）。
            // 留着的话列表里会有一行点了没反应、拖出去是空的。
            let clipboard = index.clipboardItems.filter(Self.blobIsIntact)
            let files = index.fileItems.filter(Self.blobIsIntact)

            await MainActor.run {
                PerchStore.shared.adopt(clipboard: clipboard, files: files)
            }

            // 反方向的对账：磁盘上有、索引里没有的目录扫掉。
            // 必须等 adopt 之后再算 liveIDs —— 期间用户可能已经拖了东西进来。
            let liveIDs = await MainActor.run { PerchStore.shared.allItemIDs }
            let removed = BlobStore.removeOrphanDirectories(keeping: liveIDs)
            if removed > 0 {
                NSLog("[Perch] 启动对账：清掉 \(removed) 个孤儿目录")
            }
        }
    }

    /// 纯文本和链接没有本体，恒为完整。
    private nonisolated static func blobIsIntact(_ item: PerchItem) -> Bool {
        guard let path = item.blobPath else { return true }
        return BlobStore.exists(atRelativePath: path)
    }

    /// 把读到的历史并进来。
    ///
    /// 🚨 是**并**不是**赋值**：读盘那几十毫秒里用户完全可能已经复制了一条，
    /// 直接赋值会把它冲掉。读到的历史一律排在已有内容后面（它们本来就更旧）。
    private func adopt(clipboard: [PerchItem], files: [PerchItem]) {
        let existingClipboard = Set(clipboardItems.map(\.dedupKey))
        let existingFiles = Set(fileItems.map(\.dedupKey))

        clipboardItems += clipboard.filter { !existingClipboard.contains($0.dedupKey) }
        fileItems += files.filter { !existingFiles.contains($0.dedupKey) }

        isLoaded = true

        sweepExpired()
        enforceClipboardLimit()
        // 上面两步可能什么都没删（那时不会有落盘），但读盘本身也可能丢掉了本体缺失的条目，
        // 所以这里无条件写一次，让磁盘和内存对齐。
        scheduleSave()
    }

    var allItemIDs: Set<UUID> {
        Set(clipboardItems.map(\.id)).union(fileItems.map(\.id))
    }

    /// 合并窗口内的多次改动只落一次盘。
    private func scheduleSave() {
        guard isLoaded else { return }
        pendingSave?.cancel()

        let work = DispatchWorkItem { MainActor.assumeIsolated { PerchStore.shared.saveNow() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// 立刻落盘。退出前必须调一次，否则合并窗口里的改动会跟着进程一起没。
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isLoaded else { return }

        do {
            try DiskStore.save(
                PerchIndex(clipboardItems: clipboardItems, fileItems: fileItems)
            )
        } catch {
            NSLog("[Perch] 索引落盘失败：\(error)")
        }
    }

    // MARK: - 筛选

    /// 当前筛选下**看得见**的剪贴板条目。列表和 ⌘1–⌘9 都以它为准。
    var visibleClipboardItems: [PerchItem] {
        guard let kind = clipboardFilter.kind else { return clipboardItems }
        return clipboardItems.filter { $0.kind == kind }
    }

    /// 面板收起时调用。筛选状态不跨一次展开保留。
    func resetClipboardFilter() {
        clipboardFilter = .all
    }

    /// 取剪贴板区第 N 条（从 0 开始）。⌘1–⌘9 用。
    ///
    /// 🚨 **按全表算，不按筛选后的可见列表算。** 口径取自参考稿
    /// `docs/design/prototype/src/App.tsx`，那里的快捷键处理也是直接索引 `clipboardItems[index]`。
    ///
    /// 早先这里做成了「跟着筛选后的顺序走」，理由是「用户看到的第 1 行按 ⌘1 就该取到它」。
    /// 参考稿的解法更好：⌘N 永远指全表第 N 条，**而在筛选生效时干脆不画 ⌘N 徽标**
    /// （改画普通序号，见 `ClipboardListView.shortcutLabel`）。
    /// 这样「看得见的第 1 行」和「⌘1」不会同时出现，歧义在视觉层就消掉了，
    /// 不必让快捷键的语义随界面状态漂移 —— 后者会让「⌘3 是哪一条」变成一个要先看屏幕才能回答的问题。
    func clipboardItem(at index: Int) -> PerchItem? {
        clipboardItems.indices.contains(index) ? clipboardItems[index] : nil
    }

    // MARK: - 固定与移除

    /// 双击整行切换固定。固定的条目永不过期，也不参与数量上限的淘汰。
    func togglePin(_ id: UUID) {
        if let index = clipboardItems.firstIndex(where: { $0.id == id }) {
            clipboardItems[index].isPinned.toggle()
            restartRetentionIfUnpinned(&clipboardItems[index])
        } else if let index = fileItems.firstIndex(where: { $0.id == id }) {
            fileItems[index].isPinned.toggle()
            restartRetentionIfUnpinned(&fileItems[index])
        } else {
            return
        }
        scheduleSave()
    }

    /// 取消固定时，保存时长**从当下重新起算**。
    ///
    /// 不这么做的话：固定了三天的东西一取消固定，起算点还是三天前，
    /// 12 小时的时长早就过了 —— 下一次扫描（最多 60 秒后）它就没了。
    /// 用户刚做的动作是「取消固定」，不是「删掉」。
    ///
    /// 只动起算点，**不动 `createdAt`** —— 动了它这条会跳到列表最前，
    /// 而用户并没有重新复制过它。
    private func restartRetentionIfUnpinned(_ item: inout PerchItem) {
        guard !item.isPinned else { return }
        item.retentionStartedAt = Date()
    }

    /// 手动移除一条。
    ///
    /// 本体要同步删掉：只从数组里拿掉的话，`blobs/<uuid>/` 会永远留在磁盘上 ——
    /// 索引里再也没有人指向它，按条目清理那条路径也扫不到，就是纯粹的孤儿。
    func remove(_ id: UUID) {
        clipboardItems.removeAll { $0.id == id }
        fileItems.removeAll { $0.id == id }
        selectedFileIDs.remove(id)
        BlobStore.removeDirectory(for: id)
        scheduleSave()
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
    ///
    /// 🚨 **条目已经不在了的话，要把缩略图连同目录一起删掉。**
    /// 生成缩略图要几十毫秒，这期间条目完全可能已经被去重合并、被淘汰或被清理掉了 ——
    /// 而写缩略图那一步是 `blobs/<id>/thumb.jpg`，会把刚删掉的目录**又建回来**。
    /// 光在这里 return 的话，每重复复制一张图片就多一个孤儿目录，
    /// 而且要等到下次启动对账才收得掉。
    func setThumbnail(_ path: String, for id: UUID) {
        if let index = fileItems.firstIndex(where: { $0.id == id }) {
            fileItems[index].thumbPath = path
        } else if let index = clipboardItems.firstIndex(where: { $0.id == id }) {
            clipboardItems[index].thumbPath = path
        } else {
            BlobStore.removeDirectory(for: id)
            return
        }
        scheduleSave()
    }

    var totalByteSize: Int64 {
        (clipboardItems + fileItems).reduce(0) { $0 + $1.byteSize }
    }

    var isEmpty: Bool {
        clipboardItems.isEmpty && fileItems.isEmpty
    }
}
