import AppKit

/// 屏幕几何：刘海探测与多屏定位。
///
/// M5 补齐：Quick Look、深色/浅色等打磨项。
/// 接屏/断屏时重建窗口已在 `PanelController.install` 里监听。
enum ScreenGeometry {

    /// 没有刘海时渲染的虚拟黑条尺寸（demo v3 的 186×30）。
    static let virtualBarSize = NSSize(width: 186, height: 30)

    /// 鼠标当前所在的那块屏幕。
    ///
    /// 用 `NSEvent.mouseLocation` 而不是 `NSScreen.main`：后者返回的是
    /// 「含有键盘焦点窗口」的屏幕，对不抢焦点的面板来说是错的参照系。
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// 该屏幕是否有物理刘海。
    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// 该屏幕上黑条（收起态）的尺寸。
    ///
    /// - 有刘海：**取刘海自己的外接矩形**。比刘海小的话黑条整个藏进硬件里看不见，
    ///   更糟的是面板会顶到刘海下沿以上，中间那段被摄像头模组咬掉一口。
    /// - 无刘海：虚拟黑条 186×30，和 demo v3 一致。
    ///
    /// 刘海宽度没有公开 API，只能用左右两块「辅助区域」反推：
    /// `frame.width - 左.width - 右.width` 就是中间被挡住的那段。
    static func barSize(for screen: NSScreen) -> NSSize {
        guard hasNotch(screen),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else {
            return virtualBarSize
        }

        let notchWidth = screen.frame.width - left.width - right.width
        return NSSize(
            width: max(notchWidth, virtualBarSize.width),
            height: max(screen.safeAreaInsets.top, virtualBarSize.height)
        )
    }
}
