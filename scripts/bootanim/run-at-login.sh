#!/bin/bash
# 闪控 · run-at-login.sh — 开机顺序总控
#
# 用户 2026-10-25 拍板：
#   ① 开场动画是全机**第一个**被唤醒的用户可见程序，全屏（盖住菜单栏/Dock）；
#   ② 动画播完，再拉起其他开机自启项；
#   ③ WorkBuddy 不再开机自启（要调用时由面板/DSH 拉起）；
#   ④ DeepSeek Harness 加入开机自启。
#
# 为什么要有这个脚本：macOS 的登录项是**并行**启动的，谁先谁后不由用户决定。
#   要实现「动画一定先出现」，只能把其他自启项从登录项里摘掉，
#   由这里在动画结束后按序拉起 —— 顺序才是确定的。
#
# 三条安全底线（不能省，省了就会开机后一片空白）：
#   1) 动画最多等 MAX_ANIM 秒，超时强杀，照样往下走；
#   2) 无论动画成功/失败/被跳过，`finish()` 一定执行（trap EXIT）；
#   3) 每个 app 单独 open，一个失败不影响其余。
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANIM="$DIR/tools/wblaunch"
LOG="/tmp/bootanim.log"
MAX_ANIM=75          # 动画硬上限：正常 15~50 秒（场景闸门每幕最多再等 3 秒）

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

log "=== 开机顺序总控启动 (pid $$) ==="

launch_app() {   # $1=显示名  $2=路径
  local name="$1" path="$2"
  [ -e "$path" ] || { log "跳过 $name（不存在：$path）"; return 1; }
  if /usr/bin/open -a "$path" >>"$LOG" 2>&1; then
    log "已拉起 $name"
  else
    log "⚠️ 拉起失败 $name"
    return 1
  fi
}

# 后台启动并隐藏：open -g 不抢焦点；再把它藏起来（相当于 ⌘H）。
# 为什么不用 "open 后最小化窗口"：四个 App 的窗口结构各不相同（Electron / 原生 / 微信），
# 逐个最小化窗口要写四套 AX 逻辑；"整应用隐藏"是唯一对所有 App 都成立的做法。
launch_hidden() {
  local name="$1" path="$2" proc="$3"
  [ -e "$path" ] || { log "跳过 $name（不存在：$path）"; return 1; }
  if /usr/bin/open -g -a "$path" >>"$LOG" 2>&1; then
    log "已拉起 $name（后台）"
  else
    log "⚠️ 拉起失败 $name"; return 1
  fi
  for _ in 1 2 3 4 5 6; do
    sleep 1
    if osascript -e "tell application \"System Events\" to set visible of process \"$proc\" to false" >>"$LOG" 2>&1; then
      log "已隐藏 $name"; return 0
    fi
  done
  log "⚠️ $name 起来了但隐藏失败（可能进程名不是「$proc」）"
}

finished=0
finish() {
  [ "$finished" = "1" ] && return 0
  finished=1
  log "--- 动画阶段结束，开始按序拉起 5 个自启项 ---"

  # 启动规则（用户 2026-10-25 拍板）：
  #   · 只有这 5 个：灵台智枢 / 微信 / DSH / WorkBuddy / 豆包
  #   · 动画最高优先级，播完才拉起它们
  #   · 只有 DSH 允许出现在前台；其余四个起来后都隐藏

  # ① 灵台智枢（面板本身常驻，无 Dock 图标，面板默认不显示 → 天然"最小化"）
  if ! launchctl kickstart -k "gui/$(id -u)/com.lingtai.apex" >>"$LOG" 2>&1; then
    log "kickstart 失败，改用 open"
    /usr/bin/open -g -a "/Applications/灵台智枢.app" >>"$LOG" 2>&1
  else
    log "已拉起 灵台智枢（launchd）"
  fi

  # ② 微信 / ③ WorkBuddy / ④ 豆包 —— 后台起，不抢焦点，起来后隐藏
  launch_hidden "微信"        "/Applications/WeChat.app"        "微信"
  launch_hidden "WorkBuddy"   "/Applications/WorkBuddy.app"     "WorkBuddy"
  launch_hidden "豆包"        "/Applications/Doubao.app"        "Doubao"

  # ⑤ DSH 最后起、且**唯一允许在前台**：它是用户开机后真正要看的那一屏
  if /usr/bin/open -a "/Applications/DeepSeek Harness.app" >>"$LOG" 2>&1; then
    log "已拉起 DeepSeek Harness（前台）"
  else
    log "⚠️ DeepSeek Harness 拉起失败"
  fi
  sleep 1
  osascript -e 'tell application "System Events" to set frontmost of process "DeepSeek Harness" to true' >>"$LOG" 2>&1 \
    || log "⚠️ DSH 置前失败（不影响启动）"

  log "=== 开机顺序总控结束 ==="
}
trap finish EXIT INT TERM

if [ ! -x "$ANIM" ]; then
  log "⚠️ 找不到启动器：$ANIM（跳过动画，直接拉其他自启）"
  exit 0
fi

log "播放开场动画（--no-launch：拉起别的东西由本脚本负责）"
"$ANIM" boot --no-launch >>"$LOG" 2>&1 &
anim_pid=$!

# 看门狗：超时就杀掉动画，不让它拖住开机
(
  slept=0
  while [ "$slept" -lt "$MAX_ANIM" ]; do
    sleep 1
    slept=$((slept + 1))
    kill -0 "$anim_pid" 2>/dev/null || exit 0
  done
  log "⚠️ 动画超过 ${MAX_ANIM}s，强制结束"
  kill "$anim_pid" 2>/dev/null
  sleep 1
  kill -9 "$anim_pid" 2>/dev/null
) &
watchdog=$!

wait "$anim_pid" 2>/dev/null
anim_rc=$?
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null

log "动画退出 rc=$anim_rc"
exit 0
