#!/bin/bash
# 闪控 · douyin_open.sh — 打开抖音（L0）
#
# 规格书 §6.3：
#   open -a 抖音 → 进入推荐流即停手（纯导航，不做持续代刷）
#   App 不在则退化为浏览器打开 douyin.com
#
# 参数：
#   --url <地址>    可选，直接打开指定抖音链接
#
# 规格书 §8-2：刷抖音 = 打开 App 进入推荐流即停手（L0）。
# 「持续滑动代刷」不做 —— 那是视觉循环，违背快路径哲学。

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/common.sh"

APP_NAME="抖音"
BUNDLE="com.bytedance.douyin.desktop"

# 环境预检：屏幕锁定时输入事件全部失效（实测踩过）
precheck_env_or_exit "douyin_open" "抖音" "$BUNDLE"
URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── 1. App 是否存在 ──────────────────────────────────────────────
if [ -n "$URL" ]; then
  open "$URL" 2>/dev/null
  sleep 1
  audit "douyin_open:$URL" "douyin_open.sh" "$LEVEL_L0" "ok" "" "已打开链接 $URL"
  emit 1 "douyin_open" "$URL" 0 "已打开：$URL" ""
  exit 0
fi

if [ -d "/Applications/$APP_NAME.app" ] || [ -d "$HOME/Applications/$APP_NAME.app" ]; then
  open -a "$APP_NAME" 2>/dev/null
  sleep 2.5

  # ⚠ 这里原本用 `$(... | python3 -c 'sys.exit(0 if ... else 1)')` 存返回值，
  #   但命令替换拿到的是 stdout（成功时为空串），不是退出码 →
  #   `if [ "$RUNNING" = "0" ]` 永远不成立，失败分支形同虚设（实测是bug）。
  #   现在用 app_running 直接返回布尔退出码。
  if ! app_running "$BUNDLE"; then
    audit "douyin_open" "douyin_open.sh" "$LEVEL_L0" "fail" "$ERR_APP_NOT_FOUND" "抖音未启动"
    emit 0 "douyin_open" "$APP_NAME" 0 "无法启动 $APP_NAME" "$ERR_APP_NOT_FOUND"
    exit 1
  fi

  # 置前并进入推荐流（点「推荐」标签，纯导航一步）
  m front --app "$BUNDLE" >/dev/null 2>&1
  sleep 1.0
  m click --text "推荐" --app "$BUNDLE" >/dev/null 2>&1 || true
  sleep 0.8

  # 首次运行：探测并沉淀该 App 的交互模型（供后续脚本复用）
  if ! m recall 2>/dev/null | grep -q "$BUNDLE"; then
    m note --app "$BUNDLE" --text "首页推荐流在左侧导航「推荐」标签；窗口首次出现时主窗口可能不在 AX 树中，先 raise 置前" >/dev/null 2>&1 || true
  fi

  audit "douyin_open" "douyin_open.sh" "$LEVEL_L0" "ok" "" "已打开抖音推荐流"
  emit 1 "douyin_open" "$APP_NAME" 0 "已打开 $APP_NAME 并进入推荐流" "" \
    "bundle" "\"$BUNDLE\""
  exit 0
fi

# ── 2. App 不存在 → 退化为浏览器 ─────────────────────────────────
open "https://www.douyin.com" 2>/dev/null
sleep 2
audit "douyin_open" "douyin_open.sh" "$LEVEL_L0" "ok" "" "App 不存在，已用浏览器打开"
emit 1 "douyin_open" "https://www.douyin.com" 0 "$APP_NAME 未安装，已用浏览器打开抖音网页" "" \
  "fallback" "true"
exit 0
