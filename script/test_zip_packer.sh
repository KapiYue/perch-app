#!/usr/bin/env bash
#
# ZipPacker 离线自测（M4）。
#
# 和另外两个脚本同样的理由：打包是**纯文件逻辑**，不需要人肉真机操作。
# 而它恰恰是最不该靠肉眼验的一段 —— zip 坏没坏、少没少文件，
# 要拖到桌面双击解压才看得出来，出错时用户拿到的是一个「打不开的压缩包」。
#
# 编译的是 Sources/ 下的**本体**，不是拷贝。
#
#   用法：./script/test_zip_packer.sh
#   退出码：0 全过；1 有不符（可以直接进 CI）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCE="Sources/DragDrop/ZipPacker.swift"
[ -f "$SOURCE" ] || { printf '\033[0;31m✗\033[0m 找不到 %s\n' "$SOURCE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 造三个源文件，其中两个**同名**（放在不同目录里）——
# 架上完全可能有两条都叫 report.pdf 的条目，重名不错开的话 zip 里会少一个。
mkdir -p "$WORK/src/a" "$WORK/src/b"
printf 'alpha' > "$WORK/src/a/report.pdf"
printf 'beta-beta' > "$WORK/src/b/report.pdf"
# 名字里带空格和中文，顺带验证不会被 shell 或 zip 截断。
printf 'gamma content' > "$WORK/src/一 二 三.txt"

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

let work = CommandLine.arguments[1]
let sources = [
    URL(fileURLWithPath: work + "/src/a/report.pdf"),
    URL(fileURLWithPath: work + "/src/b/report.pdf"),
    URL(fileURLWithPath: work + "/src/一 二 三.txt"),
]

var failed = 0
@MainActor
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("\u{001B}[0;32m ok \u{001B}[0m \(name)")
    } else {
        failed += 1
        let extra = detail()
        print("\u{001B}[0;31mFAIL\u{001B}[0m \(name)\(extra.isEmpty ? "" : " —— \(extra)")")
    }
}

// ── 多个文件 ──
let multi = URL(fileURLWithPath: work + "/out/多选 3 个.zip")
try! FileManager.default.createDirectory(
    at: multi.deletingLastPathComponent(), withIntermediateDirectories: true
)
do {
    try ZipPacker.pack(sources, archiveName: "栖架 3 项", to: multi)
    check("多选打包不抛错", true)
} catch {
    check("多选打包不抛错", false, "\(error)")
}

let data = (try? Data(contentsOf: multi)) ?? Data()
check("产出的是真 zip（PK 魔数）", data.prefix(2) == Data([0x50, 0x4b]), "前两个字节 \(Array(data.prefix(2)))")
check("zip 不是空的", data.count > 100, "\(data.count) 字节")

// ── 单个文件 ──
// 🚨 这一条是这个脚本存在的主要理由：`.forUploading` 只对**目录**产出 zip，
// 直接压一个普通文件会原样返回它本身。ZipPacker 里那句「哪怕只有一个也先建目录」
// 要是被谁「顺手优化」掉，这里立刻红。
let single = URL(fileURLWithPath: work + "/out/单个.zip")
do {
    try ZipPacker.pack([sources[0]], archiveName: "report", to: single)
    let one = (try? Data(contentsOf: single)) ?? Data()
    check("单个文件也压成真 zip", one.prefix(2) == Data([0x50, 0x4b]), "前两个字节 \(Array(one.prefix(2)))")
} catch {
    check("单个文件也压成真 zip", false, "\(error)")
}

// ── 覆盖已存在的落点 ──
do {
    try ZipPacker.pack(sources, archiveName: "栖架 3 项", to: multi)
    check("同名落点直接覆盖，不抛错", true)
} catch {
    check("同名落点直接覆盖，不抛错", false, "\(error)")
}

// ── 空输入 ──
do {
    try ZipPacker.pack([], archiveName: "空", to: URL(fileURLWithPath: work + "/out/空.zip"))
    check("空输入要抛错", false, "居然打包成功了")
} catch {
    check("空输入要抛错", true)
}

exit(failed == 0 ? 0 : 1)
SWIFT

info() { printf '\033[0;34m==>\033[0m %s\n' "$1"; }

info "编译 $SOURCE"
swiftc -swift-version 6 -strict-concurrency=complete \
  -o "$WORK/ziptest" "$SOURCE" "$WORK/main.swift" 2>&1 | grep -v '^$' || true
[ -x "$WORK/ziptest" ] || { printf '\033[0;31m✗\033[0m 编译失败\n' >&2; exit 1; }

info "打包"
"$WORK/ziptest" "$WORK" || SWIFT_FAILED=1

info "解压回来对账（unzip 是系统自带的，和用户双击走的是同一套）"
FAILED=${SWIFT_FAILED:-0}

ok()   { printf '\033[0;32m ok \033[0m %s\n' "$1"; }
bad()  { printf '\033[0;31mFAIL\033[0m %s —— %s\n' "$1" "${2:-}"; FAILED=1; }

if unzip -tqq "$WORK/out/多选 3 个.zip" >/dev/null 2>&1; then
  ok "unzip -t 校验通过"
else
  bad "unzip -t 校验通过" "压缩包本身是坏的"
fi

mkdir -p "$WORK/unpacked"
unzip -qq "$WORK/out/多选 3 个.zip" -d "$WORK/unpacked" >/dev/null 2>&1 || true

if [ -d "$WORK/unpacked/栖架 3 项" ]; then
  ok "解压出来是一个文件夹，不是散落一地的文件"
else
  bad "解压出来是一个文件夹" "没找到「栖架 3 项」目录"
fi

COUNT=$(find "$WORK/unpacked/栖架 3 项" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT" = "3" ]; then
  ok "三个文件一个都不少（重名的那两个错开了）"
else
  bad "三个文件一个都不少" "只解出 $COUNT 个"
fi

if [ "$(cat "$WORK/unpacked/栖架 3 项/report.pdf" 2>/dev/null)" = "alpha" ] \
   && [ "$(cat "$WORK/unpacked/栖架 3 项/report 2.pdf" 2>/dev/null)" = "beta-beta" ]; then
  ok "重名的两份内容各自正确，没有互相覆盖"
else
  bad "重名的两份内容各自正确" "report.pdf / report 2.pdf 的内容对不上"
fi

if [ "$(cat "$WORK/unpacked/栖架 3 项/一 二 三.txt" 2>/dev/null)" = "gamma content" ]; then
  ok "带空格和中文的文件名原样还原"
else
  bad "带空格和中文的文件名原样还原" "内容对不上或文件名被改了"
fi

echo
if [ "$FAILED" = "0" ]; then
  printf '\033[0;32m全部通过\033[0m\n'
  exit 0
else
  printf '\033[0;31m有不符，见上面的 FAIL\033[0m\n'
  exit 1
fi
