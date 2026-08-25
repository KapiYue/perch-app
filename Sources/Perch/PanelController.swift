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

    /// 右键菜单正开着。
    ///
    /// 🚨 菜单弹出来的那一刻，鼠标就算还压在格子上，跟踪区也会发一次 `mouseExited`
    /// （事件被菜单接管了）—— 不挡住的话，用户刚点开右键菜单，面板就在菜单底下收走了，
    /// 菜单还浮在半空，选哪一项都作用在一个已经不见了的面板上。
    private var isMenuOpen = false

    private var pendingCollapse: DispatchWorkItem?

    /// 收起之后的一小段冷却期，期间悬停不触发展开。见 `hotZoneMouseEntered`。
    private var expandBlockedUntil = Date.distantPast

    /// 面板开着期间，每隔一会儿查一次鼠标在哪。
    ///
    /// 🚨 **为什么不能只靠跟踪区的 `mouseExited`**，三种情况它都给不出来：
    /// ① 收起动画期间窗口还在，鼠标扫过会发 `mouseEntered` 而不是 exited；
    /// ② **快捷键唤出时鼠标从来没进过面板**，也就永远不会有 exited —— 面板会一直挂着；
    /// ③ 拖拽期间系统压根不发这两个事件。
    ///
    /// 这是**查询**不是钩子：`NSEvent.mouseLocation` 是同步读一次当前坐标，
    /// 不需要任何授权，也不违反「不装全局鼠标钩子」那条产品决定。
    private var mousePollTimer: Timer?

    /// 这一次面板是怎么唤出来的，决定宽限期（见 `CollapsePolicy.grace`）。
    private var summon: CollapsePolicy.Summon = .hover

    /// 鼠标已经**连续**在面板外面多久。回到面板上清零。
    private var mouseOutsideFor: TimeInterval = 0

    /// 这一次展开期间，鼠标有没有真的落到过面板/热区上。
    /// 碰过之后就按悬停的宽限期算 —— 用户已经在用鼠标了。
    private var hasEverHovered = false

    /// 轮询间隔。面板开着才跑，开着的时间以秒计，这个频率的代价可以忽略。
    private static let mousePollInterval: TimeInterval = 0.25

    /// 「取回一条 → 1.1 秒后收起」的那一次。和悬停收起是两码事，分开存。
    private var takeCollapse: DispatchWorkItem?

    /// 鼠标移开后多久收起。判据统一放在 `CollapsePolicy`，这里只是取个别名。
    private static let hoverCollapseDelay: TimeInterval = CollapsePolicy.hoverGrace

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
                MainActor.assumeIsolated {
                    PanelController.shared.refreshHotZoneBadges()
                    // 选中态、文件条数一变，⌘A / Esc 的前提就变了（见 HotKeyCenter.syncFileKeys）。
                    PanelController.shared.syncFileHotKeys()
                }
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

        // 🔴 **用户切到别的 App，就把置顶让出来。**
        //
        // 面板是 `.statusBar` 层级，盖在所有普通窗口之上 —— 用户点开另一个 App
        // 却发现顶上压着一条 640pt 的面板，那就是纯粹挡路（2026-08-25 真机要求）。
        // 鼠标轮询也会收，但那要等宽限期；切 App 是个明确得多的信号，立刻收。
        //
        // ⚠️ 必须用 `NSWorkspace` 的通知中心，不是 `NotificationCenter.default` ——
        // 前者才发 App 激活事件。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                PanelController.shared.otherAppActivated(bundleID: bundleID)
            }
        }
    }

    /// 别的 App 抢到前台了。
    ///
    /// 两处例外：
    /// ① **激活的是我们自己**（AirDrop、导出失败弹窗、设置窗口都会主动 activate）——
    ///    那不是「用户切走了」，收面板是错的；
    /// ② **正在拖拽**：把文件拖到别的 App 上会让它激活，这时候收面板等于把落点撤掉。
    func otherAppActivated(bundleID: String?) {
        guard panel.isVisible else { return }
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        guard !isDragActive else { return }

        isHovering = false
        collapse()
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

    /// 按当前内容决定 ⌘A / Esc 要不要占着。面板没开就一个都不占。
    func syncFileHotKeys() {
        guard panel.isVisible else {
            HotKeyCenter.shared.unregisterFileKeys()
            return
        }
        let store = PerchStore.shared
        HotKeyCenter.shared.syncFileKeys(
            hasFiles: !store.fileItems.isEmpty,
            hasSelection: !store.selectedFileIDs.isEmpty
        )
    }

    // MARK: - 对外入口

    /// 菜单栏和热区单击都走这里：立刻展开 / 立刻收起，不粘住。
    func toggle(on screen: NSScreen? = nil) {
        if panel.isVisible {
            isHovering = false
            collapse()
        } else {
            // 菜单栏、⌃⌘V、单击黑条都走这里。前两个用户可能压根没碰鼠标，
            // 所以按键盘唤出算（宽限期更长）；单击黑条时鼠标本来就在热区上，
            // 轮询第一拍就会把 hasEverHovered 置真，自动退回悬停的宽限期。
            expand(on: screen, summon: .keyboard)
        }
    }

    /// 鼠标进入**热区（顶部黑条）**。这是悬停展开的**唯一**触发点。
    ///
    /// 「悬停自动展开」可以在设置里关掉。关掉之后：
    /// - 鼠标扫过黑条**不再**弹出面板（只剩单击 / ⌃⌘V / 菜单栏三个入口）；
    /// - 但面板已经开着时，悬停照样按住它不收 —— 否则鼠标停在面板上它也会自己溜走。
    func hotZoneMouseEntered(on screen: NSScreen? = nil) {
        isHovering = true
        cancelPendingCollapse()

        // 🚨 刚收起的那一小段时间里不许再展开。
        // 收起时黑条要从 640pt 形变回 190pt，这期间它的窗口仍然是宽的，
        // 鼠标横穿屏幕顶部就会落进那片还没缩回去的区域 —— 表现就是
        // 「面板刚收起，鼠标根本没到刘海上，它自己又弹出来一次」（2026-08-25 真机反馈）。
        guard Date() >= expandBlockedUntil else { return }

        if !panel.isVisible, Preferences.autoExpandOnHover {
            expand(on: screen, summon: .hover)
        }
    }

    /// 鼠标进入**面板**。
    ///
    /// 🔴 **只负责「按住不收」，绝不负责「展开」**（2026-08-25 定的口径）。
    /// 早先这里和热区共用一个入口，于是面板自己那 640pt 宽的表面也成了展开触发器：
    /// 收起动画那 0.32 秒里窗口还在，鼠标从上面扫过就把它又拉了回来。
    /// 用户的原话是「鼠标并没有移入顶部刘海区，依然会再次出现一次」——
    /// **展开的入口只有热区、单击、⌃⌘V、菜单栏这四个，面板不在其中。**
    func panelMouseEntered() {
        isHovering = true
        cancelPendingCollapse()
    }

    /// 鼠标离开热区或面板。
    func mouseExited() {
        isHovering = false
        scheduleCollapseIfIdle()
    }

    /// 拖着东西悬停到黑条：展开，并在拖拽期间保持展开。
    /// 拖完了就按「有没有悬停」重新判定，不留任何粘性。
    ///
    /// ⚠️ 这条**不看**「悬停自动展开」那个开关。手上拖着文件停在黑条上是明确的意图，
    /// 不是「鼠标恰好路过」；不展开的话这条主路径就直接断了。
    func dragEnteredHotZone(on screen: NSScreen? = nil) {
        isDragActive = true
        cancelPendingCollapse()
        hotZone(for: screen)?.setDragHighlighted(true)
        if !panel.isVisible {
            expand(on: screen, summon: .hover)
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

    // MARK: - 右键菜单

    /// 右键菜单弹出前调用。菜单开着期间面板绝对不能收。
    func contextMenuWillOpen() {
        isMenuOpen = true
        cancelPendingCollapse()
    }

    /// 菜单关掉了（选了一项，或者点别处取消）。
    ///
    /// 按真实鼠标位置重算 `isHovering`，理由和 `dragOutEnded` 一样：
    /// 菜单接管事件循环期间跟踪区发过 `mouseExited`，那个 false 是假的；
    /// 反过来鼠标可能真的已经移开了，也得认出来。
    func contextMenuDidClose() {
        isMenuOpen = false
        isHovering = panelOrHotZoneContainsMouse()
        scheduleCollapseIfIdle()
    }

    /// 面板里的动作把用户送去别的 App 了（打开文件、导出后跳访达、AirDrop）。
    ///
    /// 这时面板留着纯属挡路 —— 和 `dragOutEnded` 是同一个道理，
    /// 区别只是这里鼠标八成还压在面板上，所以要**无视 `isHovering`** 直接收。
    func collapseAfterHandoff() {
        isDragActive = false
        isMenuOpen = false
        isHovering = false
        collapse()
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
            // 拖拽中不收：东西还在半空，落点不能消失。右键菜单开着同理。
            guard !self.isDragActive, !self.isMenuOpen else { return }
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

    // MARK: - 内容变高变矮

    /// 面板正开着时重新按内容定尺寸。切换类型筛选后调用。
    ///
    /// 展开时的高度是**那一刻**用 `hosting.fittingSize` 量出来写死进窗口的，
    /// 之后内容自己变矮，窗口不会跟着变 —— VStack 会在多出来的空间里居中，
    /// 看上去就是「内容吊在一个空壳中间」。
    ///
    /// 🚨 必须推到下一轮 runloop：这一轮 SwiftUI 还没有按新的筛选重新布局，
    /// 现在量到的仍然是旧高度。
    func refitToContent() {
        // 收起动画还在跑的时候（窗口还没 orderOut）不要动尺寸，
        // 否则面板会在滑出去的半路上抽一下。
        guard panel.isVisible, state.isExpanded else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, self.state.isExpanded else { return }
            let height = self.panel.fitToContentAndPosition(on: self.panel.screen)
            withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                self.state.contentHeight = height
            }
        }
    }

    // MARK: - 展开与收起

    private func expand(on screen: NSScreen?, summon: CollapsePolicy.Summon) {
        cancelPendingCollapse()
        self.summon = summon

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
        syncFileHotKeys()

        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            state.isExpanded = true
        }

        startMousePolling()
    }

    // MARK: - 鼠标位置轮询

    private func startMousePolling() {
        stopMousePolling()
        mouseOutsideFor = 0
        hasEverHovered = panelOrHotZoneContainsMouse()

        let timer = Timer(timeInterval: Self.mousePollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { PanelController.shared.pollMouse() }
        }
        // 和 ClipboardWatcher / Janitor 同样的理由：默认模式在菜单弹开、
        // 拖拽期间整个停摆，而那恰恰是最需要它盯着的时候。
        RunLoop.main.add(timer, forMode: .common)
        mousePollTimer = timer
    }

    private func stopMousePolling() {
        mousePollTimer?.invalidate()
        mousePollTimer = nil
    }

    /// 每 0.25 秒一次：鼠标在面板或热区上就按住，连续在外面够久就收起。
    ///
    /// 🚨 **这里绝对不能去调 `scheduleCollapseIfIdle()`。**
    /// 那个方法头一行是 `cancelPendingCollapse()` —— 轮询每 0.25 秒调一次，
    /// 而收起任务的延时是 0.4 秒，于是它每次都在到点前被下一拍取消重排，
    /// **永远轮不到执行**。真机上的表现就是「鼠标离开了面板也不收」，
    /// 而且不报错、无日志（2026-08-25）。
    ///
    /// 判据本身现在由 `./script/test_panel_collapse.sh` 盯着（含「连续在外面的时长要累计」
    /// 那条契约）；而「不去碰那个共享的延时任务」这一点脚本够不着 —— 它在 AppKit 这一侧，
    /// 只能靠这段注释和下面那句「直接 collapse()」守住。**改这里之前先读完上面这段。**
    ///
    /// 现在轮询自己累计「连续在外面多久」，够了就**直接收**，不经过那个共享的延时任务。
    private func pollMouse() {
        guard panel.isVisible else {
            stopMousePolling()
            return
        }

        let inside = panelOrHotZoneContainsMouse()
        if inside {
            hasEverHovered = true
            mouseOutsideFor = 0
            isHovering = true
            cancelPendingCollapse()
            return
        }

        isHovering = false
        mouseOutsideFor += Self.mousePollInterval

        guard CollapsePolicy.shouldCollapse(
            mouseInside: false,
            isDragActive: isDragActive,
            isMenuOpen: isMenuOpen,
            outsideFor: mouseOutsideFor,
            grace: CollapsePolicy.grace(summon: summon, hasEverHovered: hasEverHovered)
        ) else { return }

        collapse()
    }

    private func collapse() {
        cancelPendingCollapse()
        cancelCollapseAfterTake()
        stopMousePolling()
        // 黑条形变回窄条要一小会儿，这期间它的窗口还是宽的。冷却掉，
        // 否则鼠标横穿屏幕顶部会立刻把面板又拉回来。
        expandBlockedUntil = Date().addingTimeInterval(Self.collapseAnimationDuration + 0.12)

        hotZones.forEach { $0.setMorphExpanded(false) }
        clearDragHighlight()
        isMenuOpen = false
        HotKeyCenter.shared.unregisterNumberKeys()
        HotKeyCenter.shared.unregisterFileKeys()

        withAnimation(.spring(response: Self.collapseAnimationDuration, dampingFraction: 0.9)) {
            state.isExpanded = false
        }

        // 动画放完再撤窗口。期间窗口还在，但内容已经滑出可视区。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseAnimationDuration) { [weak self] in
            guard let self, !self.state.isExpanded else { return }
            self.panel.orderOut(nil)

            // 类型筛选回到「全部」。放在这里而不是 collapse() 开头 ——
            // 收起动画还在跑的时候改筛选，列表会在滑出去的半路上跳一下。
            PerchStore.shared.resetClipboardFilter()
            // 文件区的选中态同理归零。留着的话下次展开会带着一批「上次选的」，
            // 而批量操作条会跟着冒出来 —— 用户这一轮什么都还没点。
            PerchStore.shared.clearSelection()
        }
    }

    /// 两个「暂缓收起」的理由都不成立时，延时收起。
    private func scheduleCollapseIfIdle() {
        cancelPendingCollapse()
        guard panel.isVisible else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isHovering, !self.isDragActive, !self.isMenuOpen else { return }
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
