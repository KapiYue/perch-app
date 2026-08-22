import SwiftUI
import UniformTypeIdentifiers

/// 文件区：网格。
///
/// M4 补齐每格结构（42pt 图标区 + 文件名两行 + 大小·剩余时长）、
/// 多选、批量操作条（拖出 / 打包 ZIP / 固定 / 移除）与右键菜单。
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
    static let maxHeight: CGFloat = 180

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.cellWidth), spacing: Self.spacing)]
    }

    private var columnCount: Int {
        let available = PerchPanel.width - 26   // 左右各 13pt 内边距
        return max(1, Int((available + Self.spacing) / (Self.cellWidth + Self.spacing)))
    }

    /// 网格按**实际行数**占高，不是一上来就把 180pt 占满。
    ///
    /// 🚨 ScrollView 是贪心的：只给 `maxHeight` 的话，架上只有一个文件时
    /// 它照样会摊开到 180pt，下面全是死空白 —— 而那块空白是从剪贴板区嘴里抢的。
    /// 实测过一次：一个文件的文件区占了 220pt，剪贴板 200 条只剩 5 行可见。
    private var gridHeight: CGFloat {
        let rows = max(1, Int(ceil(Double(store.fileItems.count) / Double(columnCount))))
        let height = CGFloat(rows) * Self.cellHeight + CGFloat(rows - 1) * Self.spacing
        return min(height, Self.maxHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("files.section")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if store.selectedFileIDs.count > 1 {
                    // 完整的批量操作条（拖出 / 打包 ZIP / 固定 / 移除）在 M4，
                    // 这里先把「选了几个」说清楚，否则多选拖出没有任何反馈。
                    Text("已选 \(store.selectedFileIDs.count) 个")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.spacing) {
                    ForEach(store.fileItems) { item in
                        cell(for: item)
                            // 本体已经在 blobs/ 里，拖出去走 .fileURL。
                            // 拖已选中的格子 → 整个选中集一起走。
                            .dragOut(store.dragPayload(startingFrom: item)) { click in
                                // 双击打开、右键菜单在 M4，这里只处理选中。
                                store.toggleSelection(item.id, extending: click.extending)
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

    /// M1-a 的临时格子，只要能看见、能拖走就够。完整结构（42pt 图标区 +
    /// 文件名两行 + 大小·剩余时长 + 多选态）在 M4 做，这里不要提前投入样式。
    private func cell(for item: PerchItem) -> some View {
        let isSelected = store.selectedFileIDs.contains(item.id)
        return VStack(spacing: 4) {
            Image(nsImage: icon(for: item))
                .resizable()
                // 缩略图不是正方形，不按比例缩会把长图压成扁的。
                .aspectRatio(contentMode: .fit)
                .frame(width: 38, height: 38)
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
        .frame(width: Self.cellWidth, height: Self.cellHeight)
        .background(
            isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
            in: .rect(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 1.5 : 0)
        }
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
