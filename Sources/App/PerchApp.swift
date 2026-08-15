import SwiftUI

/// 应用入口。
///
/// LSUIElement = true 的应用没有主窗口，所以这里只声明 `Settings` 场景：
/// 它提供 ⌘, 打开的设置窗口，并且**不会**在启动时自动开窗。
/// 若换成 `WindowGroup`，启动瞬间就会弹出一个空窗口，与菜单栏常驻形态冲突。
@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
