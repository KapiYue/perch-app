#!/usr/bin/env bash
#
# 面板收起判据的离线自测。
#
# 为什么这一段值得有脚本：2026-08-25 这里出过一个**静默失效**的 bug ——
# 轮询每 0.25 秒调一次「延时 0.4 秒收起」，而排新任务前会先取消旧任务，
# 于是收起任务每次都在到点前被顶掉，自己把自己饿死了。
# 真机上的表现只有一句「鼠标离开了面板也不收」，不报错、不打日志，
# 编译和类型检查更是一点忙都帮不上。
#
# 把判据抽成纯函数之后，几十种组合一秒钟就能跑完。
#
# 编译的是 Sources/ 下的**本体**，不是拷贝。
#
#   用法：./script/test_panel_collapse.sh
#   退出码：0 全过；1 有不符（可以直接进 CI）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCE="Sources/Perch/CollapsePolicy.swift"
[ -f "$SOURCE" ] || { printf '\033[0;31m✗\033[0m 找不到 %s\n' "$SOURCE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var failed = 0
var total = 0

@MainActor
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    total += 1
    if condition {
        print("\u{001B}[0;32m ok \u{001B}[0m \(name)")
    } else {
        failed += 1
        let extra = detail()
        print("\u{001B}[0;31mFAIL\u{001B}[0m \(name)\(extra.isEmpty ? "" : " —— \(extra)")")
    }
}

let hover = CollapsePolicy.hoverGrace
let keyboard = CollapsePolicy.keyboardGrace

// ── 宽限期怎么选 ──
check("悬停唤出 → 短宽限", CollapsePolicy.grace(summon: .hover, hasEverHovered: false) == hover)
check("键盘唤出、鼠标没碰过 → 长宽限",
      CollapsePolicy.grace(summon: .keyboard, hasEverHovered: false) == keyboard)
check("键盘唤出、但鼠标碰过面板 → 退回短宽限（用户已经在用鼠标了）",
      CollapsePolicy.grace(summon: .keyboard, hasEverHovered: true) == hover)
check("长宽限确实比短的长得多（够看完列表再按 ⌘N）", keyboard >= hover * 5)

// ── 三个「暂缓收起」的理由 ──
func collapse(inside: Bool = false, drag: Bool = false, menu: Bool = false,
              outside: TimeInterval, grace: TimeInterval = CollapsePolicy.hoverGrace) -> Bool {
    CollapsePolicy.shouldCollapse(mouseInside: inside, isDragActive: drag,
                                  isMenuOpen: menu, outsideFor: outside, grace: grace)
}

check("鼠标在面板上 → 不收", !collapse(inside: true, outside: 999))
check("拖拽中 → 不收（中途收起会让落点消失）", !collapse(drag: true, outside: 999))
check("右键菜单开着 → 不收（收了菜单会浮在半空）", !collapse(menu: true, outside: 999))
check("拖拽 + 菜单同时成立 → 还是不收", !collapse(drag: true, menu: true, outside: 999))

// ── 时长边界 ──
check("刚离开就收是不行的", !collapse(outside: 0))
check("没到宽限期不收", !collapse(outside: hover - 0.01))
check("到了宽限期就收", collapse(outside: hover))
check("超过宽限期当然收", collapse(outside: hover + 10))

// ── 键盘唤出那条路径 ──
check("键盘唤出：鼠标不动 1 秒，不该收（还在看列表）",
      !collapse(outside: 1.0, grace: keyboard))
check("键盘唤出：到点必须收，不能一直挂在屏幕上",
      collapse(outside: keyboard, grace: keyboard))

// ══════════════════════════════════════════════════════════════
// 🔴 回归：轮询不能把收起一直往后推
// ══════════════════════════════════════════════════════════════
//
// 这一条就是 2026-08-25 那个 bug 的形状。旧写法里，每一拍都会把上一拍排的
// 收起任务取消掉重排，于是「离开多久」这个量根本没有被累计过 ——
// 下面这个循环会永远收不起来。

func simulatePolling(
    ticks: Int,
    interval: TimeInterval,
    grace: TimeInterval,
    insideAt: Set<Int> = []
) -> Int? {
    var outsideFor: TimeInterval = 0
    for tick in 1...ticks {
        let inside = insideAt.contains(tick)
        if inside {
            outsideFor = 0            // 回到面板上要清零
        } else {
            outsideFor += interval    // 🚨 关键：连续在外面的时长要**累计**
        }
        if CollapsePolicy.shouldCollapse(mouseInside: inside, isDragActive: false,
                                         isMenuOpen: false, outsideFor: outsideFor,
                                         grace: grace) {
            return tick
        }
    }
    return nil
}

let interval = 0.25
check("🔴 每 0.25 秒一拍，鼠标一直在外面 → 必须收起，不能被无限推迟",
      simulatePolling(ticks: 200, interval: interval, grace: hover) != nil,
      "跑了 200 拍（50 秒）还没收 —— 这正是那个 bug 的表现")
check("收起发生在宽限期附近，不是拖很久",
      (simulatePolling(ticks: 200, interval: interval, grace: hover) ?? 999) <= 3,
      "第 \(simulatePolling(ticks: 200, interval: interval, grace: hover) ?? -1) 拍才收")
check("键盘唤出同样会收，只是晚一点",
      (simulatePolling(ticks: 200, interval: interval, grace: keyboard) ?? 999) <= 20)

// 中途回到面板上要清零，否则「摸一下又移开」会立刻收
check("中途鼠标回到面板上 → 计时清零，不会提前收",
      simulatePolling(ticks: 3, interval: interval, grace: hover, insideAt: [2]) == nil)
check("清零之后重新离开，照样会收",
      simulatePolling(ticks: 10, interval: interval, grace: hover, insideAt: [2]) != nil)

if failed == 0 {
    print("\n\u{001B}[0;32m✓\u{001B}[0m \(total) 项全部通过")
} else {
    print("\n\u{001B}[0;31m✗\u{001B}[0m \(failed) / \(total) 项不符")
    exit(1)
}
SWIFT

xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$WORK/modcache" \
    -o "$WORK/run" "$SOURCE" "$WORK/main.swift"

"$WORK/run"
