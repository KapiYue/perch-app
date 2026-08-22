import AppKit

// AppKit 的入口，不用 SwiftUI 的 `App` 生命周期。
//
// 原来是 `@main struct PerchApp: App`，body 里只有一个 `Settings` 场景 ——
// 而那个场景在 accessory 应用里**永远打不开**（详见 `SettingsWindowController`）。
// 场景删掉之后 SwiftUI 的 `App` 就只剩一个空壳：这个 App 的窗口全是自己建的
// （黑条、面板、设置窗口），SwiftUI 只活在 `NSHostingView` 里面。
//
// 顶层语句只允许写在名为 main.swift 的文件里，这是编译器的硬性要求。
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
