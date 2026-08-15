import AppKit
import SwiftUI

/// 主面板窗口。
///
/// 展开/收起由 `PanelController` 调度，本类只负责窗口本身的配置、尺寸和位置。
///
/// 下面这几个属性是这个产品能不能成立的关键，改动前先想清楚：
/// - `.nonactivatingPanel` + `canBecomeKey = false`：面板显示时不抢焦点，
///   前台 App 的输入光标不会消失。这是「一边打字一边取内容」的前提。
/// - `level = .statusBar`：盖在普通窗口之上。
/// - `.canJoinAllSpaces` + `.fullScreenAuxiliary`：切 Space、进全屏都还在。
@MainActor
final class PerchPanel: NSPanel {

    /// 面板宽度固定 640pt，与交互原型一致。
    static let width: CGFloat = 640

    private let hosting: NSHostingView<PerchRootView>

    init(state: PanelState) {
        hosting = NSHostingView(rootView: PerchRootView(state: state))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 180),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // 容器同时是拖入的落点和鼠标进出的跟踪区。
        //
        // ⚠️ 拖入必须挂在**祖先**视图上，不能和 SwiftUI 内容平级。
        // AppKit 找拖拽目标的方式是：命中最深的视图，然后沿 superview 往上找
        // 第一个注册过类型的。格子上盖着 DragSourceView（起拖层，没注册拖入类型），
        // 如果落点视图只是它的兄弟节点，往上根本找不到，拖进格子区域就会被拒绝。
        let container = DropTargetView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 180))
        container.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container
    }

    /// 面板永远不接受键盘焦点，否则前台 App 的输入光标会消失。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 按内容定尺寸、贴**指定屏幕**顶部居中，返回内容高度供动画使用。
    ///
    /// 屏幕由触发展开的那个热区指定 —— 在外接屏上悬停，面板就要在外接屏上弹出来。
    @discardableResult
    func fitToContentAndPosition(on screen: NSScreen?) -> CGFloat {
        guard let screen = screen ?? ScreenGeometry.activeScreen() else { return frame.height }

        // 上限取可见高度的一半，条目再多也不会顶出屏幕。
        let height = min(max(hosting.fittingSize.height, 120), screen.visibleFrame.height / 2)
        setContentSize(NSSize(width: Self.width, height: height))

        // 🚨 这里用的是 `frame`（物理顶部），不是 `visibleFrame`。
        //
        // M0 阶段这么写会锁死自己：面板 level 是 `.statusBar`，比菜单栏（`.mainMenu`）高一层，
        // 贴物理顶部就盖住菜单栏，而那时唯一的收起入口就是菜单栏图标 —— 一盖住只能 `pkill`。
        //
        // 现在可以贴物理顶部，是因为收起入口有三个且都在面板覆盖范围之外：
        // ① 黑条单击（黑条 order 在面板之上，见 PanelController.expand）；
        // ② 菜单栏图标（在屏幕最右侧，面板 640pt 居中够不到）；
        // ③ 菜单里的「打开面板」。
        // **改动面板宽度或位置前，先确认这三个入口还在。**
        //
        // 面板挂在黑条**下沿**，并往上多压 1pt：黑条和面板是两个 NSPanel，
        // 边界刚好对齐的话中间会露一条抗锯齿缝，形变到一半时特别明显。
        // 多压的这 1pt 被黑条盖住（黑条 order 在面板之上），看不见。
        let area = screen.frame
        let barHeight = ScreenGeometry.barSize(for: screen).height
        setFrameOrigin(
            NSPoint(
                x: area.midX - frame.width / 2,
                y: area.maxY - barHeight + 1 - frame.height
            )
        )

        return height
    }
}
