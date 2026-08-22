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
        menuBarController = MenuBarController()
        // 黑条常驻，面板按需显示。
        PanelController.shared.install()
        // 读回上次的历史。**读盘整段在后台**，回主线程的只有「把结果并进来」那一下 ——
        // 几百条历史加上一次目录对账，摆在主线程上就是几十到几百毫秒，直接把冷启动预算吃穿。
        PerchStore.shared.loadFromDisk()
        // 剪贴板监听 —— 本产品的立身之本，启动就跑。
        // 只是挂一个 0.5 秒的 Timer，冷启动预算里可以忽略；真正读内容要 changeCount 变了才发生。
        ClipboardWatcher.shared.start()
        // 过期清理：启动时一次 + 每 60 秒一次。
        Janitor.start()
        // ⌃⌘V 唤出面板。常驻注册，⌘1–⌘9 则只在面板展开期间（见 HotKeyCenter）。
        HotKeyCenter.shared.registerToggleKey()
    }

    /// 退出前把合并窗口里还没落盘的改动写下去。
    ///
    /// 不写的话，「复制一条 → 立刻 ⌘Q」会丢掉那一条：`scheduleSave` 有 0.6 秒的合并窗口，
    /// 进程先没了，那次写就不会发生。
    func applicationWillTerminate(_ notification: Notification) {
        PerchStore.shared.saveNow()
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
