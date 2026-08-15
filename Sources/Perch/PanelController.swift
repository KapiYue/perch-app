import AppKit
import Combine
import SwiftUI

/// 面板的展开/收起状态。视图层观察它做动画。
///
/// 高度由 `PanelController` 在展开前算好写进来，而不是让视图自己用
/// GeometryReader 量 —— 窗口尺寸本来就要先定下来（否则内容会被裁掉），
/// 那个数顺手传给视图即可，省掉一次「量完再布局」的往返。
@MainActor
final class PanelState: ObservableObject {
    @Published var isExpanded = false
    @Published var contentHeight: CGFloat = 180
}

/// 热区 + 面板的唯一调度者。
///
/// **收起的判据只有一条：鼠标没有悬停在热区或面板上。**
/// 只有两个「暂缓收起」的理由，任一成立就不收：
/// - `isHovering`：鼠标真的在上面；
/// - `isDragActive`：正在拖东西进来或拖出去，中途收起会让落点消失。
///
/// ⚠️ **没有「点击粘住」这回事**（2026-08-15 确认的口径）。
/// 点击只是「立刻展开 / 立刻收起」，展开后照样离开就收。
/// 早先版本里点击展开会粘住，结果拖出去之后面板一直挂在屏幕上挡路。
@MainActor
final class PanelController {

    static let shared = PanelController()

    private let state = PanelState()
    private lazy var panel = PerchPanel(state: state)

    /// **每块屏幕一个黑条。** 只建一个的话，另一块屏上完全没有入口 ——
    /// 鼠标移到那块屏的顶部什么都不会发生。
    private var hotZones: [HotZoneWindow] = []

    /// 条目数徽标的订阅。只挂一份，变更时刷新所有黑条。
    private var storeObserver: AnyCancellable?

    private var isHovering = false
    private var isDragActive = false

    private var pendingCollapse: DispatchWorkItem?

    /// 「取回一条 → 1.1 秒后收起」的那一次。和悬停收起是两码事，分开存。
    private var takeCollapse: DispatchWorkItem?

    /// 鼠标移开后多久收起。
    private static let hoverCollapseDelay: TimeInterval = 0.4

    /// 收起动画放完再把窗口 orderOut。提前 orderOut 会让动画看起来是「闪没」。
    private static let collapseAnimationDuration: TimeInterval = 0.32

    private init() {}

    /// 启动时挂上黑条。黑条常驻，面板按需显示。
    func install() {
        rebuildHotZones()

        // 上架/移除内容时刷新黑条上的条目数徽标。
        // objectWillChange 是**变更前**发的，同一轮读到的还是旧值，所以推到下一轮再读。
        storeObserver = PerchStore.shared.objectWillChange.sink { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PanelController.shared.refreshHotZoneBadges() }
            }
        }

        // 接屏、断屏、改分辨率、开合盖都会发这个通知。
        // 不重建的话：新接的屏没有热区，拔掉的屏留下一个指向已失效 NSScreen 的窗口。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { PanelController.shared.rebuildHotZones() }
        }
    }

    private func rebuildHotZones() {
        hotZones.forEach { $0.orderOut(nil) }
        hotZones = NSScreen.screens.map { screen in
            let zone = HotZoneWindow(screen: screen)
            zone.controller = self
            zone.orderFrontRegardless()
            return zone
        }

        // 接屏/断屏时面板可能正开着。新建的黑条默认是收起态，
        // 不同步的话会出现「面板挂在那儿、上面的黑条却是窄的」。
        if panel.isVisible {
            hotZone(for: panel.screen)?.setMorphExpanded(true)
            hotZones.forEach { $0.order(.above, relativeTo: panel.windowNumber) }
        }
    }

    private func hotZone(for screen: NSScreen?) -> HotZoneWindow? {
        guard let screen else { return nil }
        // NSScreen 实例在重建后会换对象，按 frame 认屏更稳。
        return hotZones.first { $0.screen0.frame == screen.frame }
    }

    func refreshHotZoneBadges() {
        hotZones.forEach { $0.refreshItemCount() }
    }

    // MARK: - 对外入口

    /// 菜单栏和热区单击都走这里：立刻展开 / 立刻收起，不粘住。
    func toggle(on screen: NSScreen? = nil) {
        if panel.isVisible {
            isHovering = false
            collapse()
        } else {
            expand(on: screen)
        }
    }

    /// 鼠标进入热区或面板。
    func mouseEntered(on screen: NSScreen? = nil) {
        isHovering = true
        cancelPendingCollapse()
        if !panel.isVisible {
            expand(on: screen)
        }
    }

    /// 鼠标离开热区或面板。
    func mouseExited() {
        isHovering = false
        scheduleCollapseIfIdle()
    }

    /// 拖着东西悬停到黑条：展开，并在拖拽期间保持展开。
    /// 拖完了就按「有没有悬停」重新判定，不留任何粘性。
    func dragEnteredHotZone(on screen: NSScreen? = nil) {
        isDragActive = true
        cancelPendingCollapse()
        hotZone(for: screen)?.setDragHighlighted(true)
        if !panel.isVisible {
            expand(on: screen)
        }
    }

    /// 拖入面板范围。
    func dragEnteredPanel() {
        isDragActive = true
        cancelPendingCollapse()
        hotZone(for: panel.screen)?.setDragHighlighted(true)
    }

    /// 拖入动作结束（放下了，或者拖走了）。
    func dragEnded() {
        isDragActive = false
        clearDragHighlight()
        scheduleCollapseIfIdle()
    }

    /// **从面板里往外拖，拖完了。**
    ///
    /// 这时鼠标已经在别的 App 上（用户就是要把东西送过去），面板留着纯属挡路。
    func dragOutEnded() {
        isDragActive = false
        clearDragHighlight()
        // 🚨 拖拽期间系统**不发** mouseExited —— 鼠标早就离开面板了，
        // 但 `isHovering` 还停在 true 上。这里必须拿真实鼠标位置兜底重算，
        // 否则「拖出之后面板收起」永远不会发生。
        isHovering = panelOrHotZoneContainsMouse()
        scheduleCollapseIfIdle()
    }

    // MARK: - 取回之后收起

    /// 取回一条之后：行内反馈放完，连同面板一起收走（「复制完就走」）。
    ///
    /// 🚨 这里必须**无视 `isHovering`** —— 鼠标此刻正压在刚点的那一行上，
    /// 按悬停规则算的话永远不会收。这是唯一一处越过那条判据的地方。
    func scheduleCollapseAfterTake() {
        cancelCollapseAfterTake()
        guard panel.isVisible else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 拖拽中不收：东西还在半空，落点不能消失。
            guard !self.isDragActive else { return }
            self.isHovering = false
            self.collapse()
        }
        takeCollapse = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ClipboardTaker.feedbackDuration,
            execute: work
        )
    }

    /// 双击（切换固定）落在那 1.1 秒里时撤销收起。
    func cancelCollapseAfterTake() {
        takeCollapse?.cancel()
        takeCollapse = nil
    }

    // MARK: - 展开与收起

    private func expand(on screen: NSScreen?) {
        cancelPendingCollapse()

        let target = screen ?? ScreenGeometry.activeScreen()

        // 顺序很重要：先按内容定好窗口尺寸和位置，再显示，最后才做动画。
        // 反过来的话第一帧会以旧尺寸、旧位置闪一下。
        state.contentHeight = panel.fitToContentAndPosition(on: target)
        panel.orderFrontRegardless()

        // 面板和黑条同为 .statusBar 层级，同层级里靠 order 决定谁在上。
        // 黑条必须压在面板上面：一是收起入口不能被盖掉，
        // 二是面板顶部那多压的 1pt 要靠黑条盖住（见 PerchPanel.fitToContentAndPosition）。
        hotZones.forEach { $0.order(.above, relativeTo: panel.windowNumber) }

        // 黑条横向形变到 640pt，和面板连成一体。
        hotZone(for: target)?.setMorphExpanded(true)

        // ⌘1–⌘9 只在面板展开期间归栖架，收起时立刻还给别的 App（见 HotKeyCenter）。
        HotKeyCenter.shared.registerNumberKeys()

        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            state.isExpanded = true
        }
    }

    private func collapse() {
        cancelPendingCollapse()
        cancelCollapseAfterTake()

        hotZones.forEach { $0.setMorphExpanded(false) }
        clearDragHighlight()
        HotKeyCenter.shared.unregisterNumberKeys()

        withAnimation(.spring(response: Self.collapseAnimationDuration, dampingFraction: 0.9)) {
            state.isExpanded = false
        }

        // 动画放完再撤窗口。期间窗口还在，但内容已经滑出可视区。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseAnimationDuration) { [weak self] in
            guard let self, !self.state.isExpanded else { return }
            self.panel.orderOut(nil)
        }
    }

    /// 两个「暂缓收起」的理由都不成立时，延时收起。
    private func scheduleCollapseIfIdle() {
        cancelPendingCollapse()
        guard panel.isVisible else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isHovering, !self.isDragActive else { return }
            self.collapse()
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverCollapseDelay, execute: work)
    }

    private func clearDragHighlight() {
        hotZones.forEach { $0.setDragHighlighted(false) }
    }

    private func cancelPendingCollapse() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    /// 拖拽期间收不到 mouseExited，只能自己拿鼠标位置和窗口 frame 比。
    private func panelOrHotZoneContainsMouse() -> Bool {
        let mouse = NSEvent.mouseLocation
        if panel.isVisible && panel.frame.contains(mouse) { return true }
        return hotZones.contains { $0.frame.contains(mouse) }
    }
}
