import AppKit

/// 菜单栏图标与菜单。
///
/// 继承 `NSObject` 是必要的：菜单项要用 `#selector` 指向本类的方法，
/// 而 target-action 机制依赖 Objective-C 运行时。
@MainActor
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        statusItem.menu = makeMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // isTemplate = true 让图标跟随浅色/深色菜单栏自动反色。
        // 用普通图片会在深色菜单栏下变成一坨黑。
        let image = NSImage(
            systemSymbolName: "tray.and.arrow.down",
            accessibilityDescription: String(localized: "menubar.accessibility")
        )
        image?.isTemplate = true
        button.image = image
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(
            title: String(localized: "menu.open"),
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: String(localized: "menu.settings"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(localized: "menu.quit"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - 动作

    /// 面板会盖住菜单栏中段，但状态项在最右边、面板 640pt 居中够不到，
    /// 所以这个入口任何时候都点得到 —— 它是热区之外的第二条收起路径，别弄丢。
    @objc private func togglePanel() {
        PanelController.shared.toggle()
    }

    @objc private func openSettings() {
        Self.openSettings()
    }

    /// 面板头部的 ⚙ 也走这里，两个入口只能有一份实现。
    static func openSettings() {
        // LSUIElement 应用默认不是前台应用，不先 activate 的话设置窗口会开在别的窗口后面。
        NSApp.activate(ignoringOtherApps: true)
        // macOS 13 起 SwiftUI 的 Settings 场景由这个 selector 唤起
        // （更早的系统是 showPreferencesWindow:，本项目最低 macOS 14，无需兼容）。
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
