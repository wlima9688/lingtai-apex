#!/bin/bash
# 闪控 · screen_rec.sh — 屏幕录制（L0）
#
# ⚠⚠ 这个脚本踩过的三个坑，都写在这里了，别删（D-022）：
#
#  ① **不能用 `kill -0 <pid>` 判存活**。
#     实测在本环境 `kill -0` 对后台起的 screencapture 直接返回
#     "no such process"，`ps` 也报 "operation not permitted" ——
#     但**录屏其实正在正常工作**。用 kill -0 判活会得出
#     「进程死了」→ 脚本立刻报错「无法启动录屏」→ 静默失败。
#
#  ② **不能用 `p.isRunning` 判存活**（同上，Swift 侧同样返回 false，
#     而文件在正常增长）。唯一可靠的判据是**录屏文件的大小是否在变**。
#
#  ③ **`kill -9` 会得到损坏的 mov**（0 字节 / 播放器打不开）。
#     必须发 SIGINT（= 用户按 ⌘⌃Esc 停止），并等文件大小稳定后再报路径。
#
# 参数：
#   --start         开始录制（已在录制时返回当前状态，不重复启动）
#   --stop          停止录制并保存到桌面
#   --toggle        录制中则停止，否则开始（面板按钮用这个）
#   --status        只查状态
#   --seconds N     录制 N 秒后自动停止（可选）

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/common.sh"

ACTION="status"
SECONDS_LIMIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --start)   ACTION="start"; shift ;;
    --stop)    ACTION="stop"; shift ;;
    --toggle)  ACTION="toggle"; shift ;;
    --status)  ACTION="status"; shift ;;
    --seconds) SECONDS_LIMIT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

PID_FILE="$DIR/.screenrec.pid"
OUT_FILE_FILE="$DIR/.screenrec.out"     # ⚠ 输出路径必须持久化（见下）

# ── 统一的媒体目录（与截图共用，见 D-023）────────────────────
# ⚠ 用户原话：「截图和录屏的文件我并不清楚会放在哪个位置」。
#   原来截图在 /tmp/macctl-shot-<时间戳>.png（重启即丢、用户找不到），
#   录屏在 ~/Desktop/闪控录屏/（另一个地方）。**两个位置 = 用户找不到。**
#   现在统一：所有闪控产出的截图/录屏都在 ~/桌面/闪控/ 下。
MEDIA_DIR="$HOME/Desktop/闪控"

# 中文时间戳文件名：录屏-2026年10月22日-02时18分30秒.mov
# ⚠ 月/日/时/分/秒全部补零（%m/%d/%H/%M/%S），这样按文件名排序
#   就是按时间排序 —— 用户说「方便我搜索」，补零是这一点的前提。
stamp_cn() { date "+%Y年%m月%d日-%H时%M分%S秒"; }

# ── 当前录制目标文件 ───────────────────────────────────────────
# ⚠⚠ 原来每次调用都用 `date +%Y%m%d-%H%M%S` 重算 OUT_FILE。
#   于是 `--start` 写到 A.mov，`--status`/`--stop` 却去看 B.mov ——
#   **每次都在看一个不存在的文件** → 状态永远判「没在录」、
#   停止时读到 0 字节 → 报「可能是没给屏幕录制权限」。
#   实测踩过：录屏明明在工作，却被报成权限问题。
# 修法：开始时把路径写进 .screenrec.out，后续一律读它。
current_out() {
  if [ -f "$OUT_FILE_FILE" ]; then cat "$OUT_FILE_FILE"; fi
}

# ── 唯一可靠的存活判据：录屏文件在增长吗？──────────────────────
# ⚠ 不用 kill -0 / ps / pgrep（上面坑 ①②）：它们在这个环境全不可信。
rec_size() { stat -f%z "$(current_out)" 2>/dev/null || echo 0; }

is_recording() {
  [ -f "$PID_FILE" ] || return 1
  local a b
  a="$(rec_size)"
  sleep 0.7
  b="$(rec_size)"
  # 两次采样有变化 → 正在写 → 在录；都是 0 → 没起来
  [ "$a" != "0" ] && [ "$b" != "0" ]
}

# 开始录制
do_start() {
  if is_recording; then
    emit 1 "screen_rec" "start" 0 "已在录制中（再按一次停止）" "" "recording" "true"
    return
  fi
  mkdir -p "$MEDIA_DIR"
  rm -f "$PID_FILE" "$OUT_FILE_FILE"
  # ⚠ 路径一旦定下就持久化，后续所有子命令都读它（见current_out 上方注释）
  OUT_FILE="$MEDIA_DIR/录屏-$(stamp_cn).mov"
  echo "$OUT_FILE" > "$OUT_FILE_FILE"

  if [ "$SECONDS_LIMIT" -gt 0 ]; then
    screencapture -v -V "$SECONDS_LIMIT" "$OUT_FILE" >/dev/null 2>&1 &
  else
    # 不限时长：一直挂着，直到 --stop 发 SIGINT。
    screencapture -v "$OUT_FILE" >/dev/null 2>&1 &
  fi
  echo $! > "$PID_FILE"

  # 判活：等 1.2s 采两次文件大小
  sleep 1.2
  if ! is_recording; then
    # 最后给一次机会：某些情况下第一帧较慢
    sleep 1.5
    if ! is_recording; then
      rm -f "$PID_FILE"
      audit "screen_rec" "screen_rec.sh" "$LEVEL_L0" "fail" "$ERR_PERMISSION_DENIED" "录屏文件未生成"
      emit 0 "screen_rec" "start" 0 "无法启动录屏。请到「系统设置 → 隐私与安全性 → 屏幕录制」里给终端（或闪控）打勾" "$ERR_PERMISSION_DENIED"
      return
    fi
  fi

  audit "screen_rec" "screen_rec.sh" "$LEVEL_L0" "ok" "" "开始录制 pid=$(cat "$PID_FILE")"
  emit 1 "screen_rec" "start" 0 "● 开始录制（再按一次停止）" "" \
    "recording" "true" "out" "$(json_str "$OUT_FILE")"
}

# 停止录制
do_stop() {
  [ -f "$PID_FILE" ] || {
    emit 1 "screen_rec" "stop" 0 "当前没有在录制" "" "recording" "false"
    return
  }
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  local OUT_FILE
  OUT_FILE="$(current_out)"
  # ⚠ SIGINT 而非 SIGKILL（坑 ③）：SIGKILL 会得到损坏的 mov
  [ -n "$pid" ] && kill -INT "$pid" 2>/dev/null
  rm -f "$PID_FILE"

  # 等文件大小稳定（screencapture 收尾还在异步写）
  local prev=-1 cur_size=0 i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    cur_size="$(rec_size)"
    if [ "$cur_size" != "0" ] && [ "$cur_size" = "$prev" ]; then break; fi
    prev="$cur_size"; sleep 0.3
  done

  if [ "${cur_size:-0}" = "0" ]; then
    audit "screen_rec" "screen_rec.sh" "$LEVEL_L0" "fail" "$ERR_PERMISSION_DENIED" "录屏文件为空"
    emit 0 "screen_rec" "stop" 0 "录制中断，文件为空（可能是没给屏幕录制权限）" "$ERR_PERMISSION_DENIED"
    return
  fi
  audit "screen_rec" "screen_rec.sh" "$LEVEL_L0" "ok" "" "已保存 $OUT_FILE ($cur_size 字节)"
  emit 1 "screen_rec" "stop" 0 "✓ 已保存：桌面/闪控/$(basename "$OUT_FILE")" "" \
    "out" "$(json_str "$OUT_FILE")" "bytes" "$cur_size" "recording" "false"
  rm -f "$OUT_FILE_FILE"
}

case "$ACTION" in
  start)  do_start ;;
  stop)   do_stop ;;
  toggle)
    if is_recording; then do_stop; else do_start; fi
    ;;
  status)
    if is_recording; then
      emit 1 "screen_rec" "status" 0 "● 正在录制" "" "recording" "true"
    else
      emit 1 "screen_rec" "status" 0 "○ 未在录制" "" "recording" "false"
    fi
    ;;
esac