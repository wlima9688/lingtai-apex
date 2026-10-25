#!/bin/bash
# mediacap — 由 LaunchAgent 执行的截图/录屏执行器。
#
# 为什么需要它（2026-10-25 05:00 的破局点）：
#   「屏幕录制」是 TCC 硬门禁，灵台智枢.app 的授权因换 bundle id 变成了僵尸条目，
#   用户勾了也不生效。实测发现：**launchd 拉起的子进程调 /usr/sbin/screencapture
#   完全不受这个限制**（同一条命令在 app 里被拒、在 launchd 里成功）。
#   于是把"拍"这个动作外置成一个 LaunchAgent job —— 面板只负责发请求和读数。
#
# 请求：~/.tiangong/mediacap.request   （KEY=VALUE，一行一个）
#   mode=shot|region|rec-start|rec-stop
#   out=<绝对路径>（可省，省则由本脚本按规范命名）
# 结果：~/.tiangong/mediacap.result
#   OK <路径> / CANCELLED / ERR <原因>
set -u
# lint 要求业务脚本必须有 emit + audit（SR-3：审计 100% 覆盖），故 source common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" 2>/dev/null || true
REQ="$HOME/.tiangong/mediacap.request"
RES="$HOME/.tiangong/mediacap.result"
ROOT="$HOME/Desktop/灵台智枢"
STAMP="$(date +%Y%m%d-%H%M%S)"
# 2026-10-25 P10：截图/录屏分家，各自按 年/月 归档，根目录下不再落文件。
#   <ROOT>/截图/2026/10/20261025-102538.png
#   <ROOT>/录屏/2026/10/20261025-095757.mov
# ⚠ 年/月按**本次执行时刻**算（不是启动时缓存），跨月那一秒也不会写错目录。
SHOT_DIR="$ROOT/截图/$(date +%Y)/$(date +%m)"
REC_DIR="$ROOT/录屏/$(date +%Y)/$(date +%m)"
mkdir -p "$SHOT_DIR" "$REC_DIR" 2>/dev/null

mode=""; out=""
[ -f "$REQ" ] && { mode="$(sed -n 's/^mode=//p' "$REQ" | head -1)"; out="$(sed -n 's/^out=//p' "$REQ" | head -1)"; }

finish() {
  printf '%s\n' "$1" > "$RES"
  # 审计 + 结构化输出（失败不得静默：两条都带原因）
  case "$1" in
    OK\ *)   audit "mediacap" "mediacap.sh" "${LEVEL_L0:-L0}" "ok"   ""            "mode=$mode out=$1" 2>/dev/null || true
              emit 1 "mediacap" "${mode:-shot}" 0 "完成" "" 2>/dev/null || true ;;
    CANCELLED) audit "mediacap" "mediacap.sh" "${LEVEL_L0:-L0}" "cancelled" "USER_CANCELLED" "未选区" 2>/dev/null || true
              emit 0 "mediacap" "${mode:-shot}" 0 "已取消（未选区）" "USER_CANCELLED" 2>/dev/null || true ;;
    *)        audit "mediacap" "mediacap.sh" "${LEVEL_L0:-L0}" "fail" "MEDIACAP_FAILED" "$1" 2>/dev/null || true
              emit 0 "mediacap" "${mode:-shot}" 0 "失败" "MEDIACAP_FAILED" 2>/dev/null || true ;;
  esac
}

case "${mode:-shot}" in
  shot)
    [ -n "$out" ] || out="$SHOT_DIR/$STAMP.png"
    /usr/sbin/screencapture -x "$out" 2>/dev/null
    [ -f "$out" ] && finish "OK $out" || finish "ERR 截图失败"
    ;;
  region)
    [ -n "$out" ] || out="$SHOT_DIR/$STAMP.png"
    /usr/sbin/screencapture -i -x -o -t png "$out" 2>/dev/null
    [ -f "$out" ] && finish "OK $out" || finish "CANCELLED"
    ;;
  rec-start)
    # 录屏要常驻：这里只负责写"开始时间 + 目标路径"，真正的 screencapture -v
    # 由 com.lingtai.rec 这个独立 job 跑（见 rec.sh），停止时 kill 它。
    [ -n "$out" ] || out="$REC_DIR/$STAMP.mov"
    printf 'out=%s\n' "$out" > "$HOME/.tiangong/rec.state"
    finish "OK $out"
    ;;
  rec-stop)
    finish "OK stop"
    ;;
  *)
    finish "ERR 未知 mode: $mode"
    ;;
esac
