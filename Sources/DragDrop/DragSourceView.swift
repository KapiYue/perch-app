import AppKit
import SwiftUI

/// 一次单击的上下文。
struct ClickContext {

    /// 按住了 ⌘ 或 Shift —— 文件区的多选累加。
    let extending: Bool

    /// 第几击。**2 = 双击**：剪贴板区切换固定，文件区用默认应用打开。
    ///
    /// 双击一定会先来一次 `clickCount == 1`，所以「单击」的副作用无法避免地
    /// 会在双击时也发生一次。剪贴板区正是靠这一点做的：第一下照常复制，
    /// 第二下把「复制完收起面板」撤销并改成切换固定（见 `ClipboardTaker.cancelTake`）。
    let clickCount: Int
}

/// 可以往外拖的区域。
///
/// 为什么不用 SwiftUI 的 `.onDrag`：它只能给出 `NSItemProvider`，
/// 而本项目的生死线是 `NSFilePromiseProvider`，两者不是一回事。
/// 所以这里下沉到 AppKit，用一层透明视图盖在 SwiftUI 内容上负责起拖。
final class DragSourceView: NSView {

    /// 这块区域拖出去的是什么。多选时会有多条，由上层解析好再传进来。
    var payload: DragPayload = .items([])

    /// 单击（没有超过起拖阈值）。
    var onClick: (@MainActor (ClickContext) -> Void)?

    /// 右键。给的是那次事件和这块起拖层本身，调用方拿它们弹菜单
    /// （`NSMenu.popUp` 要一个视图来定位）。
    ///
    /// 不用 `NSView.menu(for:)` 那条标准路径：菜单要按「点的是不是已选中的格子」
    /// 现算内容，而 `menu` 属性是提前设好的。见 `FileGridView.contextMenu`。
    var onRightClick: (@MainActor (NSEvent, NSView) -> Void)?

    /// 起拖阈值，单位 pt。低于它按单击处理 —— M2 的「单击复制」和
    /// 文件区的多选点击都靠这个和拖拽区分开。
    private static let dragThreshold: CGFloat = 3

    private var mouseDownEvent: NSEvent?

    /// 🚨 必须返回 true。
    ///
    /// 面板是 `.nonactivatingPanel` 且 `canBecomeKey = false`，所以 Perch **永远不是前台 App**
    /// —— 落在面板上的每一次点击，对系统来说都是「非活跃窗口的第一次点击」。
    /// 默认行为是把这一下吞掉只用来激活窗口，表现就是：第一下拖不动，得点两次。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 先只记下来。这里就起拖的话，单击会被误判成拖拽。
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }

        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold else { return }

        // 置空，避免同一次按下里重复起拖。
        mouseDownEvent = nil
        // 传 down 而不是当前 event：拖拽图像要从按下的位置长出来。
        DragOutCoordinator.shared.beginDrag(payload, from: self, event: down)
    }

    override func mouseUp(with event: NSEvent) {
        // mouseDownEvent 还在，说明这次按下自始至终没超过阈值 —— 是单击不是拖拽。
        if let down = mouseDownEvent {
            onClick?(
                ClickContext(
                    extending: !down.modifierFlags.intersection([.command, .shift]).isEmpty,
                    clickCount: down.clickCount
                )
            )
        }
        mouseDownEvent = nil
    }

    /// 右键菜单。
    ///
    /// 🚨 不能等到 `rightMouseUp` —— 菜单是 `popUp` 弹出来的，它会**接管事件循环**
    /// 直到用户选完，那之后我们根本收不到 up。按下就弹，和访达一致。
    override func rightMouseDown(with event: NSEvent) {
        guard let onRightClick else {
            super.rightMouseDown(with: event)
            return
        }
        onRightClick(event, self)
    }
}

// MARK: - NSDraggingSource

extension DragSourceView: NSDraggingSource {

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            // 只给 .copy。给 .move 的话，目标是同卷宗的访达窗口时会变成「移动」，
            // 把 blobs/ 里的本体搬走，架上的条目当场失效。
            return .copy
        case .withinApplication:
            return []
        @unknown default:
            return []
        }
    }

    /// 拖到废纸篓不应该是「删除条目」。M1 先明确不支持。
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    /// 拖出结束 —— 东西已经送到别的 App 了，面板留着挡路，收起来。
    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        DragOutCoordinator.shared.dragOutEnded()
    }
}

// MARK: - SwiftUI 桥接

/// 盖在内容上的透明起拖层。
private struct DragOutSurface: NSViewRepresentable {

    let payload: DragPayload
    let help: String?
    let onClick: (@MainActor (ClickContext) -> Void)?
    let onRightClick: (@MainActor (NSEvent, NSView) -> Void)?

    func makeNSView(context: Context) -> DragSourceView {
        DragSourceView()
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.payload = payload
        nsView.onClick = onClick
        nsView.onRightClick = onRightClick
        // 🚨 提示文字必须挂在**这一层**上，不能用 SwiftUI 的 `.help`。
        // 工具提示是按 NSView 注册的，而这层不透明的起拖层盖在内容之上 ——
        // 鼠标停住时命中的是它，底下 SwiftUI 注册的那条提示永远不会被查到。
        nsView.toolTip = help
    }
}

extension View {

    /// 让这块区域可以拖出去，并接收单击。
    ///
    /// 用 `overlay` 而不是 `background`：起拖层必须在 SwiftUI 内容**之上**才拿得到鼠标事件。
    ///
    /// ⚠️ 起拖层会把它盖住的那块区域的点击全部接管，所以**不要盖到按钮上** ——
    /// 剪贴板行里的 ☆ / ✕ 就在这一层之外，只有内容那半边挂了 `dragOut`。
    func dragOut(
        _ items: [PerchItem],
        help: String? = nil,
        onClick: (@MainActor (ClickContext) -> Void)? = nil,
        onRightClick: (@MainActor (NSEvent, NSView) -> Void)? = nil
    ) -> some View {
        overlay(
            DragOutSurface(
                payload: .items(items),
                help: help,
                onClick: onClick,
                onRightClick: onRightClick
            )
        )
    }

    /// 让这块区域拖出去时**打包成一个 zip**。批量操作条上的「打包 ZIP」用。
    ///
    /// 压缩发生在用户松手那一刻（`NSFilePromiseProvider`），拖到一半放弃就完全不会压。
    func dragOutZip(
        _ items: [PerchItem],
        help: String? = nil,
        onClick: (@MainActor (ClickContext) -> Void)? = nil
    ) -> some View {
        overlay(
            DragOutSurface(payload: .zip(items), help: help, onClick: onClick, onRightClick: nil)
        )
    }

    /// 只收单击的透明层。
    ///
    /// 面板里的按钮**不能用 SwiftUI 的 `Button`**：面板永远不是前台窗口，
    /// 每一次点击都是「非活跃窗口的第一次点击」，而 `acceptsFirstMouse`
    /// 在 SwiftUI 那边没有出口（同 `DragSourceView` 的说明）。
    func clickAction(help: String? = nil, _ action: @escaping @MainActor () -> Void) -> some View {
        overlay(ClickSurface(help: help, action: action))
    }
}

/// 只负责「点一下」的 AppKit 层，见 `View.clickAction`。
private struct ClickSurface: NSViewRepresentable {

    let help: String?
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> ClickSurfaceView {
        ClickSurfaceView()
    }

    func updateNSView(_ nsView: ClickSurfaceView, context: Context) {
        nsView.action = action
        // 同 `DragOutSurface`：提示挂在盖在最上面的这一层，`.help` 会被它挡住。
        nsView.toolTip = help
    }
}

final class ClickSurfaceView: NSView {

    var action: (@MainActor () -> Void)?

    /// 见 `DragSourceView.acceptsFirstMouse`：不返回 true 的话第一下会被系统吞掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 在 mouseUp 而不是 mouseDown 触发：按下去之后滑出按钮范围再松手应该算取消，
    /// 这和系统按钮的行为一致。
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        action?()
    }
}
