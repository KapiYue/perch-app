#!/usr/bin/env bash
#
# CodeDetector 离线自测。
#
# 这是整个项目唯一一段**不需要人肉真机操作**就能验的逻辑 —— 剪贴板、拖拽、
# 窗口层级都得靠手，只有「这段文本是不是代码、是哪门语言」是纯函数。
# 所以它值得有一个跑得起来的回归脚本，而不是躺在测试手册里当一条口述步骤。
#
# 编译的是 Sources/Models/CodeDetector.swift **本体**，不是拷贝 ——
# 拷一份出来做测试，改了实现却忘了同步，脚本就会一直报绿。
#
#   用法：./script/test_code_detector.sh
#   退出码：0 全过；1 有不符（可以直接进 CI）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCE="Sources/Models/CodeDetector.swift"
[ -f "$SOURCE" ] || { printf '\033[0;31m✗\033[0m 找不到 %s\n' "$SOURCE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 驱动文件必须叫 main.swift —— Swift 只允许这个文件名写顶层语句。
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

/// `(输入, 期望语言)`。期望 nil = **不该**被判成代码。
///
/// 后半段那些反例和正例一样重要：这个识别器最贵的错误不是漏判一段代码，
/// 而是把一段中文笔记标成 `perl`。加新语言时**必须同时加反例**。
let cases: [(String, String?)] = [

    // ── 该认出来的 ──
    ("""
    func handle(_ click: ClickContext, on item: PerchItem) {
        guard click.clickCount >= 2 else { return }
        store.togglePin(item.id)
    }
    """, "swift"),

    ("""
    def load(path):
        with open(path) as f:
            return json.load(f)
    """, "python"),

    ("{\"name\": \"perch\", \"version\": \"1.0.0\"}", "json"),

    ("SELECT id, name FROM users WHERE age > 18 ORDER BY name;", "sql"),

    ("git clone https://github.com/KapiYue/perch-app.git && cd perch-app", "bash"),

    ("""
    const items = list.filter((x) => x.kind === 'code');
    console.log(items.length);
    """, "javascript"),

    ("""
    interface Item { id: string; kind: string }
    export const parse = (raw: string): Item => JSON.parse(raw);
    """, "typescript"),

    ("""
    .panel {
      background: rgba(24,24,27,.9);
      backdrop-filter: blur(40px);
    }
    """, "css"),

    ("""
    package main

    func main() {
        fmt.Println("hi")
    }
    """, "go"),

    ("<div class=\"row\"><span>hello</span></div>", "html"),

    ("#!/usr/bin/env python3\nprint('hi')", "python"),

    // ── 绝对不能认成代码的 ──
    ("今天下午三点开会，记得把上周的数据整理一下发给我。", nil),
    ("Please review the pull request and let me know if anything looks off.", nil),
    ("Perch 是一个 macOS 顶部中转站，复制过的内容会自动上架。", nil),
    ("13800138000", nil),
    ("会议纪要：1. 确认许可证换成 GPL-3.0；2. 云备份放到 1.1；3. 类型筛选本期做。", nil),
    ("select the file from the list and press enter", nil),
    ("Let me know when you have a moment to talk about the new design.", nil),
    // 太短，证据不足，一律不判
    ("let x = 1", nil),
]

func pad(_ text: String, _ width: Int) -> String {
    let count = text.count
    return count >= width ? text : text + String(repeating: " ", count: width - count)
}

var failed = 0
for (input, expected) in cases {
    let got = CodeDetector.detect(input)
    let ok = got == expected
    if !ok { failed += 1 }

    let head = input.split(separator: "\n").first.map(String.init) ?? input
    let mark = ok ? "\u{001B}[0;32m ok \u{001B}[0m" : "\u{001B}[0;31mFAIL\u{001B}[0m"
    print(mark,
          pad("期望 " + (expected ?? "—"), 18),
          pad("实得 " + (got ?? "—"), 18),
          String(head.prefix(52)))
}

if failed == 0 {
    print("\n\u{001B}[0;32m✓\u{001B}[0m \(cases.count) 例全部通过")
} else {
    print("\n\u{001B}[0;31m✗\u{001B}[0m \(failed) / \(cases.count) 例不符")
    exit(1)
}
SWIFT

# 和 App 一样的语言版本与并发检查，避免「脚本里过、工程里不过」。
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$WORK/modcache" \
    -o "$WORK/run" "$SOURCE" "$WORK/main.swift"

"$WORK/run"
