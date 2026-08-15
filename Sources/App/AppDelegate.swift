import AppKit

/// 应用生命周期。
///
/// 标 `@MainActor`：AppKit 的委托回调全部在主线程，Swift 6 严格并发下
/// 不加这个标注，持有 `MenuBarController`（本身是 MainActor 隔离的）会编译不过。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 冷启动到菜单栏图标出现要求 < 300ms，这里只做最轻的事。
        // 磁盘读取、剪贴板轮询等留到后续里程碑，并且要异步做。
        menuBarController = MenuBarController()
        // 黑条常驻，面板按需显示。
        PanelController.shared.install()
        // 剪贴板监听 —— 本产品的立身之本，启动就跑。
        // 只是挂一个 0.5 秒的 Timer，冷启动预算里可以忽略；真正读内容要 changeCount 变了才发生。
        ClipboardWatcher.shared.start()
        // ⌃⌘V 唤出面板。常驻注册，⌘1–⌘9 则只在面板展开期间（见 HotKeyCenter）。
        HotKeyCenter.shared.registerToggleKey()
    }

    /// macOS 14 起不实现这个方法会在控制台刷警告。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// 菜单栏应用没有窗口，关掉最后一个窗口时不能退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
