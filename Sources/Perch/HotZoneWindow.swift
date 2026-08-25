import AppKit
import QuartzCore

/// 屏幕顶部的黑条窗口。**每块屏幕一个，常驻显示。**
///
/// 入口的定义是「屏幕中上方的一块黑条」，**不是「物理刘海」** ——
/// 有刘海的机器直接用刘海那块地方（见 `ScreenGeometry.barSize`），
/// 没刘海的机器（外接屏 / iMac / Mac mini）渲染一条同尺寸的虚拟黑条，
/// 两种情况下面板的外观必须完全一致。
///
/// 展开时黑条**横向形变到与面板同宽（640pt）并与面板连成一体**（灵动岛那一下）。
/// 这一下是「高级感」的主要来源，不是模糊和圆角 —— 改动前先看 `perch-demo-v3.html`。
///
/// ⚠️ **宽度必须真改窗口 frame，不能用视图缩放。**
/// 缩放只改渲染，窗口还是 186pt 宽，展开后点黑条两侧会直接点到底下的 App 上。
/// 反过来「窗口一直 640pt 宽、只画中间一段」也不行：borderless 窗口的命中区域按
/// frame 算不按透明度算，收起时会吃掉菜单栏中段 640pt 的点击。
@MainActor
final class HotZoneWindow: NSPanel {

    /// 展开后与面板同宽，两个窗口拼成一体。
    static var expandedWidth: CGFloat { PerchPanel.width }

    /// 收起态的圆角（demo v3：`border-radius:0 0 13px 13px`）。展开时收敛到 0，
    /// 因为下面接着面板，面板自己有 18pt 的下圆角。
    private static let collapsedCornerRadius: CGFloat = 13

    /// demo v3：`transition:width .2s cubic-bezier(.32,.72,0,1)`。
    private static let morphDuration: CFTimeInterval = 0.2

    static let accentColor: NSColor =
        NSColor(named: "AccentColor") ?? NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 1)

    weak var controller: PanelController?

    /// 本热区所属的屏幕。展开时面板要落在**同一块**屏上，
    /// 不能永远落在主屏 —— 那样在外接屏上悬停会看到面板在另一块屏弹出来。
    let screen0: NSScreen

    /// 收起态尺寸。有刘海按刘海算，没刘海用虚拟黑条，所以每块屏可能不一样。
    let barSize: NSSize

    private let barView: HotZoneView

    private(set) var isMorphExpanded = false

    private var morphLink: CADisplayLink?
    private var morphFrom: CGFloat = 0
    private var morphTo: CGFloat = 0
    private var morphStartedAt: CFTimeInterval = 0

    init(screen: NSScreen) {
        screen0 = screen
        barSize = ScreenGeometry.barSize(for: screen)
        barView = HotZoneView(frame: NSRect(origin: .zero, size: barSize))

        super.init(
            contentRect: NSRect(origin: .zero, size: barSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false

        barView.owner = self
        barView.cornerRadius = Self.collapsedCornerRadius
        // 有刘海的机器上黑条就是刘海本身，中间被摄像头模组挡着，
        // 画了也看不见 —— 名字和徽标只在虚拟黑条上画。
        barView.showsLabel = !ScreenGeometry.hasNotch(screen)
        contentView = barView

        refreshItemCount()
        applyWidth(barSize.width)
    }

    override var canBecomeKey: Bool { false }

    // MARK: - 形变

    /// 展开 / 收起黑条。由 `PanelController` 和面板同步调度。
    func setMorphExpanded(_ expanded: Bool) {
        guard expanded != isMorphExpanded else { return }
        isMorphExpanded = expanded

        let target = expanded ? Self.expandedWidth : barSize.width

        // 系统开了「减弱动态效果」就直接到位，不做形变。
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopMorph()
            applyWidth(target)
            return
        }

        morphFrom = frame.width
        morphTo = target
        morphStartedAt = CACurrentMediaTime()
        startMorphLink()
    }

    /// 拖拽悬停时黑条发光，表示「可以放手了」。
    func setDragHighlighted(_ highlighted: Bool) {
        barView.isDragHighlighted = highlighted
    }

    private func startMorphLink() {
        if morphLink == nil {
            // 用 CADisplayLink 而不是 `animator().setFrame` ——
            // 窗口 animator 的缓动曲线改不了，形变的手感全在那条曲线上。
            let link = barView.displayLink(target: self, selector: #selector(morphTick))
            link.add(to: .main, forMode: .common)
            morphLink = link
        }
        morphLink?.isPaused = false
    }

    private func stopMorph() {
        morphLink?.isPaused = true
    }

    @objc private func morphTick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - morphStartedAt
        let t = min(max(elapsed / Self.morphDuration, 0), 1)
        applyWidth(morphFrom + (morphTo - morphFrom) * MorphCurve.value(at: t))

        if t >= 1 {
            // 只暂停不销毁：形变来回跑，反复建 display link 不划算。
            link.isPaused = true
        }
    }

    /// 按当前宽度重设窗口 frame（贴屏幕**物理**顶部居中）并同步圆角。
    ///
    /// 这里用 `frame` 而不是 `visibleFrame` 是对的 —— 黑条就是要盖在菜单栏那一条上。
    /// 危险的是面板（见 `PerchPanel.fitToContentAndPosition`），不是黑条。
    private func applyWidth(_ width: CGFloat) {
        let area = screen0.frame
        setFrame(
            NSRect(
                x: area.midX - width / 2,
                y: area.maxY - barSize.height,
                width: width,
                height: barSize.height
            ),
            display: true
        )

        let span = Self.expandedWidth - barSize.width
        let progress = span > 0 ? min(max((width - barSize.width) / span, 0), 1) : 0
        barView.cornerRadius = Self.collapsedCornerRadius * (1 - progress)
    }

    // MARK: - 条目数徽标

    /// 条目数由 `PanelController` 统一推过来（订阅只挂一份，见 `PanelController.install`）。
    func refreshItemCount() {
        let store = PerchStore.shared
        barView.itemCount = store.clipboardItems.count + store.fileItems.count
    }

    // MARK: - 回调转发

    fileprivate func mouseEntered() { controller?.hotZoneMouseEntered(on: screen0) }
    fileprivate func mouseExited() { controller?.mouseExited() }
    fileprivate func clicked() { controller?.toggle(on: screen0) }
    fileprivate func dragEntered() { controller?.dragEnteredHotZone(on: screen0) }
    fileprivate func dragExited() { controller?.dragEnded() }
}

/// 黑条的内容视图：渲染 + 悬停、单击、以及「拖着文件悬停」。
private final class HotZoneView: NSView {

    weak var owner: HotZoneWindow?

    var cornerRadius: CGFloat = 13 {
        didSet { if cornerRadius != oldValue { needsDisplay = true } }
    }

    var itemCount = 0 {
        didSet { if itemCount != oldValue { needsDisplay = true } }
    }

    var isDragHighlighted = false {
        didSet { if isDragHighlighted != oldValue { needsDisplay = true } }
    }

    /// 有刘海的屏幕上黑条被摄像头模组挡着，名字和徽标画了也看不见。
    var showsLabel = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 只是为了让拖拽悬停能触发 draggingEntered，黑条本身不收放下（见下）。
        registerForDraggedTypes(DropTargetView.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 渲染

    override func draw(_ dirtyRect: NSRect) {
        let shape = Self.bottomRoundedPath(in: bounds, radius: cornerRadius)
        NSColor.black.setFill()
        shape.fill()

        if isDragHighlighted {
            // demo v3 那圈外发光在这里做不到：窗口会把超出 frame 的内容裁掉，
            // 要发光得让窗口比黑条大一圈。留给 M5，先用内描边表达同一个意思。
            let inner = Self.bottomRoundedPath(
                in: bounds.insetBy(dx: 1, dy: 1),
                radius: max(cornerRadius - 1, 0)
            )
            inner.lineWidth = 2
            HotZoneWindow.accentColor.setStroke()
            inner.stroke()
        }

        guard showsLabel else { return }
        drawLabelAndBadge()
    }

    private func drawLabelAndBadge() {
        let title = NSAttributedString(
            string: String(localized: "hotzone.label"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .kern: 0.4,
            ]
        )
        let titleSize = title.size()

        var badge: NSAttributedString?
        var badgeWidth: CGFloat = 0
        if itemCount > 0 {
            let text = NSAttributedString(
                string: itemCount > 99 ? "99+" : "\(itemCount)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
            )
            badge = text
            badgeWidth = max(16, text.size().width + 10)
        }

        let gap: CGFloat = badge == nil ? 0 : 7
        var x = bounds.midX - (titleSize.width + gap + badgeWidth) / 2

        title.draw(at: NSPoint(x: x, y: bounds.midY - titleSize.height / 2))
        x += titleSize.width + gap

        if let badge {
            let pill = NSRect(x: x, y: bounds.midY - 8, width: badgeWidth, height: 16)
            HotZoneWindow.accentColor.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()

            let size = badge.size()
            badge.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
        }
    }

    /// 只有下面两个角是圆的 —— 黑条是从屏幕顶部**长出来**的。
    private static func bottomRoundedPath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        guard r > 0 else { return NSBezierPath(rect: rect) }

        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + r))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r, startAngle: 180, endAngle: 270
        )
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r, startAngle: 270, endAngle: 360
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }

    // MARK: - 事件

    /// 面板不抢焦点 ⇒ Perch 永远不是前台 App。
    /// 用 `.activeInKeyWindow` / `.activeInActiveApp` 的话这两个回调一次都不会来。
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

    override func mouseEntered(with event: NSEvent) { owner?.mouseEntered() }
    override func mouseExited(with event: NSEvent) { owner?.mouseExited() }

    /// 见 `DragSourceView.acceptsFirstMouse` 的说明：不返回 true 的话要点两次。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { owner?.clicked() }

    // MARK: - 拖拽悬停

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        owner?.dragEntered()
        // 黑条自己不收东西：它只有 30pt 高，在这么窄的条上松手很容易落空。
        // 展开面板后让用户往下挪一点，放到面板里去。
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        owner?.dragExited()
    }
}

/// demo v3 里黑条形变用的 `cubic-bezier(.32,.72,0,1)`。
///
/// 起步快、收尾几乎贴着终点滑进去 —— 「灵动岛那一下」的手感全在这条曲线上，
/// 换成系统默认的 easeInOut 会明显变钝。
private enum MorphCurve {

    private static let x1 = 0.32, y1 = 0.72
    private static let x2 = 0.0, y2 = 1.0

    static func value(at x: Double) -> Double {
        // 牛顿迭代反解出参数 t，再代回求 y。
        var t = x
        for _ in 0..<8 {
            let dx = axis(t, x1, x2) - x
            if abs(dx) < 1e-5 { break }
            let slope = derivative(t, x1, x2)
            if abs(slope) < 1e-6 { break }
            t -= dx / slope
        }
        return axis(t, y1, y2)
    }

    /// 起点 0、终点 1 的三次贝塞尔在某一轴上的取值。
    private static func axis(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let mt = 1 - t
        return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t
    }

    private static func derivative(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let mt = 1 - t
        return 3 * mt * mt * a + 6 * mt * t * (b - a) + 3 * t * t * (1 - b)
    }
}
