import AppKit

/// 面板的拖入落点，同时负责鼠标进出的跟踪。
///
/// 它是面板 contentView，也就是所有 SwiftUI 内容的祖先视图 ——
/// 这一点是必须的，原因见 `PerchPanel.init` 里的注释。
final class DropTargetView: NSView {

    /// 拖入时接受的类型。顺序不代表优先级，类型判定在 `DropIngestor` 里做。
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, .string, .png, .tiff, .html,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `.activeAlways` 是必须的：Perch 不抢焦点，永远不是活跃 App，
    /// 其它选项下这两个回调一次都不会触发。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        PanelController.shared.mouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
        PanelController.shared.mouseExited()
    }

    // MARK: - 拖入

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 拖拽过程中不能让面板自动收起，否则东西还没放下落点就没了。
        PanelController.shared.dragEnteredPanel()
        return DropIngestor.canIngest(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropIngestor.canIngest(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = DropIngestor.ingest(sender.draggingPasteboard)
        // 放下之后鼠标还在面板里，`isHovering` 会接管；这里只是解除「拖拽中」的暂缓。
        PanelController.shared.dragEnded()
        return accepted
    }

    /// 拖拽结束后重新开始计时收起 —— 不做的话面板会一直挂在那儿。
    override func draggingExited(_ sender: NSDraggingInfo?) {
        PanelController.shared.dragEnded()
    }
}
