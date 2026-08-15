#!/usr/bin/env bash
#
# 本地构建 Perch（ad-hoc 签名）。
#
# 目的：让没有 Apple 开发者账号的人 clone 下来也能自己构建出可运行的 App。
# 正式发布用的签名 + 公证 + DMG 在 script/build_release.sh（M6）。
#
#   用法：./script/build_unsigned.sh [--run]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="Perch"
CONFIGURATION="Debug"
DERIVED_DATA="$ROOT/build/DerivedData"

info() { printf '\033[0;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[0;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ── Rosetta 检查 ──
# Apple Silicon 上如果终端勾了「使用 Rosetta 打开」，进程会被翻译成 x86_64 运行。
# 后果：装在 /opt/homebrew 的 ARM 版 Homebrew 会直接拒绝安装
# （Cannot install under Rosetta 2 in ARM default prefix），Swift 编译也会明显变慢。
if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" = "1" ]; then
  fail "当前终端运行在 Rosetta 2 下（uname -m = $(uname -m)）。

    临时绕过：arch -arm64 ./script/build_unsigned.sh ${1:-}

    根治：访达 → 应用程序 → 实用工具 → 右键「终端」→ 显示简介
          → 取消勾选「使用 Rosetta 打开」→ 重开终端
          验证：uname -m 应输出 arm64
"
fi

# ── 依赖检查 ──
command -v xcodebuild >/dev/null 2>&1 \
  || fail "找不到 xcodebuild。请先安装 Xcode，并执行：sudo xcode-select -s /Applications/Xcode.app"

if ! command -v xcodegen >/dev/null 2>&1; then
  fail "找不到 xcodegen。工程文件由 project.yml 生成，不入库。请先安装：

    brew install xcodegen

  若提示 Cannot install under Rosetta 2，改用：arch -arm64 brew install xcodegen
"
fi

# ── 生成工程 ──
# *.xcodeproj 不入库，每次构建都从 project.yml 重新生成，
# 避免有人手改工程设置后忘了同步回 project.yml。
info "从 project.yml 生成 Perch.xcodeproj"
xcodegen generate --quiet

# ── 构建 ──
# CODE_SIGN_IDENTITY="-" 是 ad-hoc 签名：能在本机运行，但不能分发给别人。
info "构建 ${SCHEME}（${CONFIGURATION}，ad-hoc 签名）"
xcodebuild \
  -project "Perch.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$SCHEME.app"
[ -d "$APP_PATH" ] || fail "构建似乎成功了，但没找到产物：$APP_PATH"

printf '\033[0;32m✓\033[0m 构建完成\n'
echo "   $APP_PATH"
echo
echo "   Perch 是菜单栏应用（LSUIElement），启动后 Dock 里不会有图标，"
echo "   请看屏幕右上角菜单栏。"

# ── 可选：直接运行 ──
if [ "${1:-}" = "--run" ]; then
  info "启动"
  # 先杀掉可能还在跑的旧实例，否则会出现两个菜单栏图标
  pkill -x "$SCHEME" 2>/dev/null || true
  open "$APP_PATH"
fi
