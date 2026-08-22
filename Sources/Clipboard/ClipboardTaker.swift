import AppKit
import SwiftUI

/// 「取回剪贴板」这条路径的唯一入口。
///
/// 四条取出方式里有两条走这里（单击整行、⌘1–⌘9），另外两条是拖出（`DragOutCoordinator`）
/// 和双击固定（`PerchStore.togglePin`）。
///
/// 取出之后的三件事必须一起发生，所以合并在这一个地方：
/// ① 写回剪贴板；② 行内反馈亮 1.1 秒；③ 反馈放完把面板收起（「复制完就走」）。
@MainActor
final class ClipboardTaker: ObservableObject {

    static let shared = ClipboardTaker()

    /// 行内反馈的时长。收起面板的延时用的是同一个数 ——
    /// 面板比反馈先走的话，等于没有反馈。
    static let feedbackDuration: TimeInterval = 1.1

    /// 刚被取回的那一条。视图据此把整行描绿并挂上「✓ 已复制」。
    ///
    /// 🚨 **不做全局 toast。** 此刻用户的视线就在那一行上，
    /// 让他去看屏幕底部是错的（主文档 2.4 的明确决定）。
    @Published private(set) var recentlyTakenID: UUID?

    private var feedbackReset: DispatchWorkItem?

    private init() {}

    /// 取回一条：写回剪贴板 + 行内反馈 + 延时收起面板。
    func take(_ item: PerchItem) {
        writeToPasteboard(item)

        // 我们自己写的这一次不能被监听当成新内容抓回来。
        ClipboardWatcher.shared.acknowledgeSelfWrite()

        withAnimation(.easeOut(duration: 0.12)) { recentlyTakenID = item.id }

        feedbackReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            guard let self, self.recentlyTakenID == item.id else { return }
            withAnimation(.easeOut(duration: 0.18)) { self.recentlyTakenID = nil }
        }
        feedbackReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.feedbackDuration, execute: reset)

        // 反馈放完连同面板一起收走。双击在这 1.1 秒内到达的话会取消掉（见 `cancelTake`）。
        PanelController.shared.scheduleCollapseAfterTake()
    }

    /// 双击 = 切换固定。第一下已经复制过了，这里把「收起」和反馈撤掉，
    /// 否则面板会在用户刚固定完的瞬间溜走。
    func cancelTake() {
        feedbackReset?.cancel()
        feedbackReset = nil
        withAnimation(.easeOut(duration: 0.12)) { recentlyTakenID = nil }
        PanelController.shared.cancelCollapseAfterTake()
    }

    // MARK: - 写回剪贴板

    private func writeToPasteboard(_ item: PerchItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text, .link, .code:
            // 代码也是纯文本 —— 取回时不做任何格式化、不加围栏，原样还回去。
            pasteboard.setString(item.preview, forType: .string)

        case .image, .file:
            guard let blobPath = item.blobPath else { return }
            let url = BlobStore.absoluteURL(forRelativePath: blobPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return }

            // 一个 pasteboard item 同时挂两种类型：
            // 图片数据（⌘V 到备忘录 / 聊天窗口直接出图）和文件 URL（⌘V 到访达出文件）。
            // 分两次 write 的话后一次会把前一次挤掉，只能挂在同一个 item 上。
            let entry = NSPasteboardItem()
            entry.setString(url.absoluteString, forType: .fileURL)
            if item.kind == .image, let data = try? Data(contentsOf: url) {
                entry.setData(data, forType: .png)
            }
            pasteboard.writeObjects([entry])
        }
    }
}
