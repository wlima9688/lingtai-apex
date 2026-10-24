#!/bin/bash
# 闪控 · open_file.sh — 按名称打开文件（L0）
#
# 规格书 §6.1：mdfind 按名称模糊匹配 → 唯一命中直接 open；
#              多个命中取 preferences 中的最近使用项；仍歧义则输出候选让模型问一次。
#
# 参数：
#   --name <关键词>     文件名关键词（必需）
#   --app <应用名>      指定打开方式（可选，默认系统默认 App）
#   --dry-run           只列出候选，不打开
#
# 退出：始终输出一个 JSON 对象（契约见规格书 FR-6）

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/common.sh"

NAME=""
OPEN_APP=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --app)  OPEN_APP="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) shift ;;
  esac
done

if [ -z "$NAME" ]; then
  audit "open_file" "open_file.sh" "$LEVEL_L0" "fail" "$ERR_ELEMENT_NOT_FOUND" "缺少 --name"
  emit 0 "open_file" "" 0 "缺少 --name 参数" "$ERR_ELEMENT_NOT_FOUND"
  exit 1
fi

# 本脚本**不做环境预检**（D-022）。
# 原因：本脚本全程只用 `open`（LaunchServices API）打开文件，
#   **不模拟任何输入事件**。而旧版的 precheck_env_or_exit 用「能否移动光标」
#   当阻塞判据 —— 用一个本脚本根本不需要的能力当前提，
#   于是「打开文件」被凭空拦住，报「输入事件被系统阻断」。
#   用户实测「明明没关屏幕，输入『打开微信』却报这个」，根因在此。
# 需要模拟输入的脚本（wechat_send / music_play / douyin_open）才预检。

# ── 1. 候选检索（纯 macOS 命令，亚秒级）────────────────────────────
# mdfind（Spotlight 索引）通常 0.1s 内返回，是主力。
# find 兜底必须做超时保护：Downloads 等目录可能有海量文件或网络挂载，
# 无保护扫描会拖垮整个脚本（实测踩过：find 卡死导致脚本被 SIGTERM）。
# 注意：macOS 没有 GNU timeout / gtimeout，用「后台进程 + 轮询」实现。
CANDS_FILE="$(mktemp)"

# run_with_timeout <秒> <命令...>  → 超时则 kill 并返回 124
run_with_timeout() {
  local secs="$1"; shift
  local tmpout; tmpout="$(mktemp)"
  "$@" > "$tmpout" 2>/dev/null &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((secs * 10)) ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      cat "$tmpout" 2>/dev/null
      rm -f "$tmpout"
      return 124
    fi
    sleep 0.1
    waited=$((waited+1))
  done
  wait "$pid" 2>/dev/null
  cat "$tmpout" 2>/dev/null
  rm -f "$tmpout"
  return 0
}

# 主力：mdfind 模糊匹配（kMDItemFSName == '*kw*'c）
#   注意：mdfind -name 是「全词匹配」，几乎只命中 1 条；
#   模糊查询才能暴露多个候选 → 才能触发消歧协议。
#   两条查询都跑：模糊优先，全词作为补充。
mdfind "kMDItemFSName == '*${NAME}*'c" 2>/dev/null | head -30 > "$CANDS_FILE"
mdfind -name "$NAME" 2>/dev/null | head -30 >> "$CANDS_FILE"

# 兜底：仅当 mdfind 没结果时才扫目录（限时，防卡死）
# 预算约束（规格书 §6.1：≤3s）——mdfind 命中就绝不做 find 兜底
MDFIND_N=$(grep -c . "$CANDS_FILE" 2>/dev/null || echo 0)
if [ "${MDFIND_N:-0}" = "0" ] && [ "${USE_FIND_FALLBACK:-1}" = "1" ]; then
  for d in "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads"; do
    [ -d "$d" ] || continue
    run_with_timeout 1 find "$d" -maxdepth 3 -iname "*${NAME}*" -type f | head -10
  done | awk '!seen[$0]++' | head -30 >> "$CANDS_FILE"
fi

# 统一去噪
grep -vE '/\.(Trash|git|svn|DS_Store)' "$CANDS_FILE" | awk '!seen[$0]++' > "$CANDS_FILE.tmp" && mv "$CANDS_FILE.tmp" "$CANDS_FILE"

NCAND=$(wc -l < "$CANDS_FILE" | tr -d ' ')

# ── 2. 零候选 ─────────────────────────────────────────────────────
if [ "$NCAND" = "0" ]; then
  rm -f "$CANDS_FILE"
  propose "打开文件:$NAME" "mdfind 无匹配"
  audit "open_file:$NAME" "open_file.sh" "$LEVEL_L0" "fail" "$ERR_ELEMENT_NOT_FOUND" "无匹配文件"
  emit 0 "open_file" "$NAME" 0 "未找到匹配「${NAME}」的文件" "$ERR_ELEMENT_NOT_FOUND" \
    "candidates" "[]"
  exit 1
fi

# ── 3. 唯一命中 → 直接打开 ───────────────────────────────────────
TARGET="$(head -1 "$CANDS_FILE")"
if [ "$NCAND" = "1" ]; then
  if [ "$DRY" = "1" ]; then
    rm -f "$CANDS_FILE"
    audit "open_file:$NAME" "open_file.sh" "$LEVEL_L0" "ok" "" "dry-run: $TARGET"
    emit 1 "open_file" "$TARGET" 0 "唯一匹配：${TARGET}（dry-run 未打开）" "" \
      "candidates" "[$(json_str "$TARGET")]"
    exit 0
  fi
  if [ -n "$OPEN_APP" ]; then
    open -a "$OPEN_APP" "$TARGET" 2>/dev/null
  else
    open "$TARGET" 2>/dev/null
  fi
  sleep 0.5
  rm -f "$CANDS_FILE"
  audit "open_file:$NAME" "open_file.sh" "$LEVEL_L0" "ok" "" "已打开 $TARGET"
  emit 1 "open_file" "$TARGET" 0 "已打开：$TARGET" "" \
    "candidates" "[$(json_str "$TARGET")]"
  exit 0
fi

# ── 4. 多候选 → 尝试用 preferences 的最近使用消歧 ────────────────
# preferences.md 形如：  recent_file: /path/to/xxx
PREF_HINT=""
for line in $(python3 - <<'PY'
import os,re
p = os.path.expanduser("~/.workbuddy/skills/mac-control/preferences.md")
try:
    txt = open(p,encoding="utf-8").read()
except Exception:
    txt = ""
for m in re.finditer(r'^\s*recent_file\s*:\s*(.+)$', txt, re.M):
    print(m.group(1).strip())
PY
); do
  [ -z "$line" ] && continue
  if grep -Fxq "$line" "$CANDS_FILE"; then
    PREF_HINT="$line"
    break
  fi
done

if [ -n "$PREF_HINT" ]; then
  if [ "$DRY" = "1" ]; then
    rm -f "$CANDS_FILE"
    audit "open_file:$NAME" "open_file.sh" "$LEVEL_L0" "ok" "" "dry-run: $PREF_HINT"
    emit 1 "open_file" "$PREF_HINT" 0 "命中偏好项：${PREF_HINT}（dry-run 未打开）" ""
    exit 0
  fi
  if [ -n "$OPEN_APP" ]; then
    open -a "$OPEN_APP" "$PREF_HINT" 2>/dev/null
  else
    open "$PREF_HINT" 2>/dev/null
  fi
  sleep 0.5
  rm -f "$CANDS_FILE"
  audit "open_file:$NAME" "open_file.sh" "$LEVEL_L0" "ok" "" "按偏好打开 $PREF_HINT"
  emit 1 "open_file" "$PREF_HINT" 0 "已按偏好打开：$PREF_HINT" ""
  exit 0
fi

# ── 5. 仍歧义 → 输出候选 + need_confirm（规格书 FR-5：最多问一次）──
CAND_JSON="$(python3 - "$CANDS_FILE" <<'PY'
import json,sys
items = [l.rstrip("\n") for l in open(sys.argv[1],encoding="utf-8") if l.strip()]
print(json.dumps(items[:8], ensure_ascii=False))
PY
)"
rm -f "$CANDS_FILE"
audit "open_file:$NAME" "open_file.sh" "$LEVEL_L0" "fail" "$ERR_AMBIGUOUS" "$NCAND 个候选，待确认"
emit 0 "open_file" "$NAME" 1 "有 $NCAND 个匹配「${NAME}」的文件，需确认用哪个" "$ERR_AMBIGUOUS" \
  "candidates" "$CAND_JSON"
exit 2
