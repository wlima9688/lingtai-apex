#!/bin/bash
# rec_agent — 由 LaunchAgent(com.lingtai.rec) 执行的录屏进程。
#
# ⚠ 2026-10-25 实测结论：**视频捕获从 launchd 会被拒**
#   `screencapture: capture error 这项操作无法完成`（-v / -x / -D 各种组合都试过）。
#   而静帧截图从 launchd **可以**（见 mediacap.sh）。
#   所以本脚本只在「灵台智枢」已获屏幕录制授权时才有用；
#   面板侧不要指望它绕开授权 —— 它的价值是「有授权时统一由 launchd 管理进程」。
set -u
source "$(dirname "${BASH_SOURCE[0]}")/common.sh" 2>/dev/null || true
STATE="$HOME/.tiangong/rec.state"
LOG="$HOME/.tiangong/rec.log"
out="$(sed -n 's/^out=//p' "$STATE" 2>/dev/null | head -1)"
[ -n "$out" ] || exit 2
mkdir -p "$(dirname "$out")"
{
  echo "[rec] start $(date) out=$out"
  # -V 是保险丝（不带的话靠 stdin 停止，launchd 里 stdin 是 EOF 会立刻退出）
  /usr/sbin/screencapture -v -V 7200 "$out"
  rc=$?
  echo "[rec] exit=$rc $(date)"
  if [ "$rc" -eq 0 ]; then
    audit "screen_rec" "rec_agent.sh" "${LEVEL_L0:-L0}" "ok"   "" "out=$out" 2>/dev/null || true
    emit 1 "screen_rec" "record" 0 "录制结束" "" 2>/dev/null || true
  else
    audit "screen_rec" "rec_agent.sh" "${LEVEL_L0:-L0}" "fail" "REC_FAILED" "exit=$rc out=$out" 2>/dev/null || true
    emit 0 "screen_rec" "record" 0 "录制失败（缺屏幕录制授权时 video 会被拒）" "REC_FAILED" 2>/dev/null || true
  fi
} >> "$LOG" 2>&1
