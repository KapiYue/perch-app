import SwiftUI
import UniformTypeIdentifiers

/// 文件区：网格 + 多选 + 批量操作条 + 右键菜单。
///
/// 每格结构：`[固定标记] [选中框] 42pt 图标 · 文件名（两行）· 大小 · 剩余时长`。
///
/// 三套入口做的是同一批事（见 `FileActions`），不要在这里另起一份实现：
/// 双击 = 打开 · 右键 = 全部动作 · 批量操作条 = 选中集上的常用动作。
struct FileGridView: View {

    @ObservedObject private var store = PerchStore.shared

    /// 和剪贴板行同一套：倒计时得自己走，否则面板开着的时候这行字会一直停在原地。
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// 每格约 96pt，自适应列数。
    /// 86pt 时「16 KB · 56 分钟后清理」这行会被截成「56 分钟后...」，倒计时看不全。
    static let cellWidth: CGFloat = 96
    /// 每格高度固定。两个理由：
    /// ① 文件名一行还是两行会让格子高低不齐，网格看着是毛的；
    /// ② 高度确定了才能按行数算出网格该占多高（见 `gridHeight`）。
    static let cellHeight: CGFloat = 104
    static let spacing: CGFloat = 7

    /// 网格最多占两行，再多就滚动。
    ///
    /// 这个数必须是**整数行**：`104 * 2 + 7`。早先是 180pt，那是「一行半多一点」——
    /// 第二行永远露出一截被切掉的格子，看着像渲染坏了。
    /// 两行 × 6 列 = 12 个文件不用滚，再多的场景本来就该滚。
    static let maxHeight: CGFloat = cellHeight * 2 + spacing

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.cellWidth), spacing: Self.spacing)]
    }

    private var columnCount: Int {
        let available = PerchPanel.width - 26   // 左右各 13pt 内边距
        return max(1, Int((available + Self.spacing) / (Self.cellWidth + Self.spacing)))
    }

    /// 网格按**实际行数**占高，不是一上来就把上限占满。
    ///
    /// 🚨 ScrollView 是贪心的：只给 `maxHeight` 的话，架上只有一个文件时
    /// 它照样会摊开到上限，下面全是死空白 —— 而那块空白是从剪贴板区嘴里抢的。
    /// 实测过一次：一个文件的文件区占了 220pt，剪贴板 200 条只剩 5 行可见。
    private var gridHeight: CGFloat {
        let rows = max(1, Int(ceil(Double(store.fileItems.count) / Double(columnCount))))
        let height = CGFloat(rows) * Self.cellHeight + CGFloat(rows - 1) * Self.spacing
        return min(height, Self.maxHeight)
    }

    private var isSelecting: Bool { !store.selectedFileIDs.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if isSelecting {
                batchBar
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.spacing) {
                    ForEach(store.fileItems) { item in
                        cell(for: item)
                            // 本体已经在 blobs/ 里，拖出去走 .fileURL。
                            // 拖已选中的格子 → 整个选中集一起走。
                            .dragOut(store.dragPayload(startingFrom: item)) { click in
                                handle(click, on: item)
                            } onRightClick: { event, view in
                                showMenu(for: item, event: event, in: view)
                            }
                    }
                }
            }
            .frame(height: gridHeight)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .onReceive(clock) { now = $0 }
    }

    // MARK: - 段标题

    private var header: some View {
        HStack(spacing: 7) {
            Text("files.section")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text("\(store.fileItems.count)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            if store.fileItems.count > 1 {
                selectAllToggle
            }
        }
    }

    /// 「□ 全选」。
    ///
    /// 常驻在段标题上而不是只放进批量操作条：操作条要选中了东西才出现，
    /// 而「全选」恰恰是**一个都还没选**的时候最需要的那个按钮。
    /// ⌘A 走的是同一个入口（见 `HotKeyCenter.syncFileKeys`）。
    private var selectAllToggle: some View {
        let isAll = store.selectedFileIDs.count >= store.fileItems.count && !store.fileItems.isEmpty
        return HStack(spacing: 4) {
            Image(systemName: isAll ? "checkmark.square.fill" : "square")
                .font(.system(size: 10))
                .foregroundStyle(isAll ? Color.accentColor : .secondary)
            Text("files.selectAll")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .clickAction(help: String(localized: "files.selectAll.help")) {
            if isAll {
                store.clearSelection()
            } else {
                store.selectAllFiles()
            }
        }
    }

    // MARK: - 批量操作条

    /// 选中东西之后才出现的那一条。
    ///
    /// 顺序按「越常用越靠左」排：导出 → 打包 → 固定 → 移除。
    /// 移除放在最右且是红的，和别的动作隔开 —— 它是这里唯一一个不可撤销的操作。
    private var batchBar: some View {
        let selected = store.selectedFileItems

        return HStack(spacing: 5) {
            Text(String(format: String(localized: "files.selected"), selected.count))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Spacer(minLength: 4)

            // 「导出」和「打包 ZIP」都是**又能点又能拖**的：
            // 点 = 存到「下载」（一个一定找得到的地方），拖 = 用户自己指定落点。
            // 只能拖的话，不知道要拖的用户点了会以为按钮坏了；
            // 只能点的话，「拖拽即导出」这条主路径在批量场景就断了。
            chip("files.action.export", symbol: "arrow.down.circle", tint: .accentColor)
                .dragOut(selected, help: String(localized: "files.action.export.help")) { click in
                    // 只认第一下。双击会连来两次 mouseUp，不挡的话「导出」会跑两遍，
                    // 「下载」里凭空多出一份 `xxx 2.pdf`。
                    guard click.clickCount == 1 else { return }
                    FileActions.exportToDownloads(selected)
                }

            chip("files.action.zip", symbol: "doc.zipper", tint: .accentColor)
                .dragOutZip(selected, help: String(localized: "files.action.zip.help")) { click in
                    guard click.clickCount == 1 else { return }
                    FileActions.exportZipToDownloads(selected)
                }

            chip(
                store.selectedFilesAllPinned ? "files.action.unpin" : "files.action.pin",
                symbol: store.selectedFilesAllPinned ? "star.slash" : "star",
                tint: .perchAmber
            )
            .clickAction { store.toggleSelectedFilesPin() }

            chip("files.action.remove", symbol: "xmark", tint: .red)
                .clickAction { store.removeSelectedFiles() }

            chip("files.action.deselect", symbol: "escape", tint: .secondary)
                .clickAction(help: String(localized: "files.action.deselect.help")) {
                    store.clearSelection()
                }
        }
    }

    private func chip(_ titleKey: LocalizedStringKey, symbol: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
            Text(titleKey)
                .font(.system(size: 10))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.16), in: .capsule)
        .contentShape(.capsule)
    }

    // MARK: - 格子

    private func cell(for item: PerchItem) -> some View {
        let isSelected = store.selectedFileIDs.contains(item.id)

        return VStack(spacing: 3) {
            Image(nsImage: icon(for: item))
                .resizable()
                // 缩略图不是正方形，不按比例缩会把长图压成扁的。
                .aspectRatio(contentMode: .fit)
                .frame(width: 42, height: 42)

            // 名字区高度固定成两行，一行的文件名下面留白，格子才会齐。
            Text(item.preview)
                .font(.system(size: 9.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 25, alignment: .top)

            // 🚨 「大小 · 剩余时长」不能省。
            // 文件区同样受保存时长管辖（官网 features 页写的就是「每格显示……大小与剩余时长」），
            // 不画倒计时的话文件就是**无声消失**：2026-08-22 真机上一个 index.html
            // 到点被清掉，用户完全没有得到过任何预告。剪贴板行一直有这句话，文件格子也必须有。
            Text(Formatters.meta(Formatters.size(item.byteSize), for: item, now: now))
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // 「3 天后清理」比「56 分钟后清理」短，长度随时间变；缩一点也不让它截断。
                .minimumScaleFactor(0.85)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .padding(.horizontal, 4)
        .frame(width: Self.cellWidth, height: Self.cellHeight)
        .background(
            isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
            in: .rect(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 1.5 : 0)
        }
        // 固定标记在左上角。文件格子上原来只有一句「已固定」混在元信息里，
        // 而那一行还要显示体积，一眼扫过去分不出哪些是固定的。
        .overlay(alignment: .topLeading) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.perchAmber)
                    .padding(5)
            }
        }
        // 选中框只在**已经选了东西**的时候出现。
        // 常驻的话空闲状态下六个格子右上角六个圈，噪音太大；
        // 一选中就全部出现，则是在说「现在是多选模式，接着点就是了」。
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .padding(4)
            }
        }
    }

    // MARK: - 点击

    private func handle(_ click: ClickContext, on item: PerchItem) {
        // 双击 = 用默认应用打开。
        // 第一下已经把它选上了（双击必然先来一次 clickCount == 1），
        // 这里不用再动选中态 —— 打开的就是刚选中的那一个。
        if click.clickCount >= 2 {
            FileActions.open([item])
        } else {
            store.toggleSelection(item.id, extending: click.extending)
        }
    }

    /// 右键。规则和访达一致：
    /// 点在**已选中**的格子上 → 菜单作用于整个选中集；
    /// 点在没选中的格子上 → 先把选中集换成它自己，再弹菜单。
    private func showMenu(for item: PerchItem, event: NSEvent, in view: NSView) {
        let targets: [PerchItem]
        if store.selectedFileIDs.contains(item.id) {
            targets = store.selectedFileItems
        } else {
            store.toggleSelection(item.id, extending: false)
            targets = [item]
        }
        FileActions.showContextMenu(for: targets, event: event, in: view)
    }

    /// 缩略图是异步生成的，还没到、或者这个类型压根没有缩略图时回退到系统图标。
    private func icon(for item: PerchItem) -> NSImage {
        if let thumbPath = item.thumbPath,
           let thumb = NSImage(contentsOf: BlobStore.absoluteURL(forRelativePath: thumbPath)) {
            return thumb
        }
        guard let blobPath = item.blobPath else { return NSWorkspace.shared.icon(for: .data) }
        return NSWorkspace.shared.icon(forFile: BlobStore.absoluteURL(forRelativePath: blobPath).path)
    }
}
