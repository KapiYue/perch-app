import Foundation

/// 面板「什么时候该收起」的全部判据。
///
/// 抽成不依赖 AppKit 的纯逻辑，只有一个理由：**这段判据出过一次静默失效的 bug，
/// 而它在真机上的表现是「面板就是不收」——没有报错、没有日志，只能靠人盯着屏幕发现。**
///
/// 2026-08-25 那次是：轮询每 0.25 秒调一次「延时 0.4 秒收起」，
/// 而排新任务前会先取消旧任务 —— 于是收起任务每次都在到点前被顶掉，
/// **自己把自己饿死了**。类型检查、编译、真机手测都发现不了这种东西，
/// 只有把它变成「给定状态 → 该不该收」的纯函数，才能用脚本一秒钟跑完几十种组合。
enum CollapsePolicy {

    /// 面板这一次是怎么被唤出来的。**它决定宽限期，不影响别的。**
    enum Summon: Sendable {
        /// 鼠标悬停到热区。用户的手就在鼠标上，移开就该收。
        case hover
        /// ⌃⌘V、单击黑条、菜单栏。用户可能压根没碰鼠标。
        case keyboard
    }

    /// 鼠标移开之后多久收起。悬停唤出的按这个来。
    static let hoverGrace: TimeInterval = 0.4

    /// 键盘唤出、且鼠标从头到尾没碰过面板时的宽限期。
    ///
    /// 🔴 **不能用 `hoverGrace`。** 键盘流程是 `⌃⌘V` → 看一眼 → `⌘1–⌘9` 取第 N 条，
    /// 全程本来就不该碰鼠标；按 0.4 秒收的话，面板会在用户还没看清列表时就没了，
    /// 这条路径直接废掉。
    ///
    /// 也不能像早先那样「鼠标没动过就永不收起」——那样快捷键唤出的面板会一直挂在屏幕上
    /// 挡着别人（2026-08-25 真机反馈：等了 5 秒也不消失）。给一个够看完列表的宽限期，
    /// 到点照样收。取完东西本来就会立刻收（见 `scheduleCollapseAfterTake`），
    /// 所以这个数只影响「唤出来又不取」那种情况。
    static let keyboardGrace: TimeInterval = 4.0

    /// 这一次该用多长的宽限期。
    ///
    /// 鼠标**碰过**面板之后一律按悬停算 —— 用户已经在用鼠标了，
    /// 再给他 4 秒就成了「移开鼠标面板还赖着」。
    static func grace(summon: Summon, hasEverHovered: Bool) -> TimeInterval {
        (summon == .hover || hasEverHovered) ? hoverGrace : keyboardGrace
    }

    /// 这一拍要不要收起。
    ///
    /// - Parameters:
    ///   - mouseInside: 鼠标在面板或热区上。
    ///   - isDragActive: 正在拖东西进来或拖出去 —— 中途收起会让落点消失。
    ///   - isMenuOpen: 右键菜单开着 —— 收起的话菜单会浮在半空。
    ///   - outsideFor: 鼠标已经**连续**在外面多久。回到面板上要清零。
    ///   - grace: 见 `grace(summon:hasEverHovered:)`。
    static func shouldCollapse(
        mouseInside: Bool,
        isDragActive: Bool,
        isMenuOpen: Bool,
        outsideFor: TimeInterval,
        grace: TimeInterval
    ) -> Bool {
        // 三个「暂缓收起」的理由，任一成立就不收。
        guard !mouseInside, !isDragActive, !isMenuOpen else { return false }
        return outsideFor >= grace
    }
}
