import AppKit
import SwiftUI

/// 设置窗口。**自己持有一个 NSWindow，不走 SwiftUI 的 `Settings` 场景。**
///
/// 🚨 为什么不用 `Settings` 场景 —— 它在这个 App 里根本打不开：
/// `LSUIElement` 应用的激活策略是 `.accessory`，而 accessory 应用**没有主菜单栏**。
/// SwiftUI 的 `Settings` 场景是靠它注入到主菜单里的那一项来响应 `showSettingsWindow:` 的，
/// 主菜单不存在 ⇒ 响应链上没有接收者 ⇒ `NSApp.sendAction` 返回 false，
/// **不报错、不打日志、什么都不发生**。2026-08-22 真机上就是这个现象。
///
/// 换成自己持有窗口之后，从菜单栏和面板 ⚙ 过来的都是一次普通的方法调用，中间没有响应链。
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        // accessory 应用默认不是前台应用，不先 activate 的话窗口会开在别的窗口后面 ——
        // 表现和「点了没反应」几乎一样，用户根本不会去别的 App 后面找它。
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        // 🚨 先把内容布出来再建窗口。
        // 不这么做的话，下面 `center` 读到的 `window.frame.size` 还是初始的那个空尺寸，
        // 算出来的原点等于屏幕中点本身 —— 窗口会贴着屏幕正中往右下角挂着。
        // 实测过一次：鼠标在外接屏（midX = 2472），窗口落在 x = 2471。
        hosting.view.layoutSubtreeIfNeeded()

        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(hosting.view.fittingSize)
        window.title = String(localized: "settings.window.title")
        // 不给 .resizable：尺寸由 SwiftUI 那边定死，拉大只会在四周留白。
        window.styleMask = [.titled, .closable, .miniaturizable]
        // 🚨 默认是 true —— 关掉窗口就把它释放了，而我们这里还留着一个强引用，
        // 下次再点「设置」就是在用一个已经没了的对象，直接崩。
        window.isReleasedWhenClosed = false
        center(window)
        window.makeKeyAndOrderFront(nil)
        // accessory 应用不一定抢得到前台，`makeKeyAndOrderFront` 有可能把窗口
        // 排在别的 App 后面。黑条和面板也是出于同样的理由用 orderFrontRegardless。
        window.orderFrontRegardless()

        self.window = window
    }

    /// 居中到**当前这块屏**，不是 `NSWindow.center()` 的那块。
    ///
    /// 🚨 `center()` 用的是系统主屏。接了外接屏的时候实测会把窗口扔到另一块屏上
    /// （2026-08-22 探到过一次 `bounds = 2471,-172`），用户在这块屏上点了「设置」，
    /// 窗口却在另一块屏上打开 —— 现象和「点了没反应」几乎没区别。
    /// 面板早就是「落在触发它的那块屏」，设置窗口照同一条规矩。
    private func center(_ window: NSWindow) {
        // 一块屏都认不出来（罕见，但 activeScreen 的返回值是 Optional）就退回系统那套居中。
        guard let screen = ScreenGeometry.activeScreen() else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                // 略高于正中：视觉重心比几何中心稍微靠上一点更稳，和系统设置窗口一致。
                y: visible.midY - size.height / 2 + visible.height * 0.08
            )
        )
    }
}
