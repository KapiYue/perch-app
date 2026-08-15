import SwiftUI
import UniformTypeIdentifiers

/// 文件区：网格。
///
/// M4 补齐每格结构（42pt 图标区 + 文件名两行 + 大小·剩余时长）、
/// 多选、批量操作条（拖出 / 打包 ZIP / 固定 / 移除）与右键菜单。
struct FileGridView: View {

    @ObservedObject private var store = PerchStore.shared

    /// 每格约 86pt，自适应列数。
    static let cellWidth: CGFloat = 86
    static let maxHeight: CGFloat = 180

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.cellWidth), spacing: 7)]
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
                LazyVGrid(columns: columns, spacing: 7) {
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
            .frame(maxHeight: Self.maxHeight)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
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
            Text(item.preview)
                .font(.system(size: 9.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: Self.cellWidth)
        .padding(.vertical, 6)
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
