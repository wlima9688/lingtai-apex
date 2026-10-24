#!/bin/bash
# 闪控 · bench.sh — 性能与可靠性验收（规格书 §9）
#
# 验收标准：
#   L0  p50≤ 1.5s   p95 ≤ 3s   成功率 ≥ 95%
#   L1  p50 ≤ 3.0s  p95 ≤ 6s   成功率 ≥ 95%
#
# 硬保证：全程静音（与 selftest 同一套守卫），绝不发出声音。
#
# 用法：
#   bench.sh                默认每个 L0 脚本跑 20 次
#   bench.sh --runs 5       快速冒烟
#   bench.sh --only open_file
#   bench.sh --keep-muted   结束保持静音
#
# 输出：控制台表格 + logs/bench-<日期>.json

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/common.sh"

RUNS=20
ONLY=""
KEEP_MUTED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --keep-muted) KEEP_MUTED=1; shift ;;
    *) shift ;;
  esac
done

silence_guard_on

OUT="$SKILL_DIR/logs/bench-$(date +%Y%m%d).json"
mkdir -p "$SKILL_DIR/logs"
printf '{"ts":"%s","runs":%s,"items":[' "$(date +%Y-%m-%dT%H:%M:%S)" "$RUNS" > "$OUT"
FIRST=1

# 结果累加到全局变量
TOTAL=0; OKN=0
declare -a TIMES

# bench_one <名称> <脚本> <参数...>
bench_one() {
  local name="$1"; shift
  local script="$1"; shift
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && return 0

  local n="$RUNS"
  local times=() oks=0 i out rc started dur
  printf "  %-22s " "$name"
  for i in $(seq 1 "$n"); do
    started="$(python3 -c 'import time;print(int(time.time()*1000))')"
    out="$("$DIR/$script" "$@" 2>/dev/null)"
    rc=$?
    dur=$(( $(python3 -c 'import time;print(int(time.time()*1000))') - started ))
    if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '"ok":true'; then
      oks=$((oks+1)); times+=("$dur")
    else
      times+=("null")
    fi
    TOTAL=$((TOTAL+1))
    OKN=$((OKN+1))
    printf '.'
  done

  # 统计（跳过 null）
  local stats
  stats="$(python3 - "$n" "${times[@]}" <<'PY'
import sys
n = int(sys.argv[1])
vals = []
for a in sys.argv[2:]:
    try:
        v = int(a)
        if v >= 0:
            vals.append(v)
    except ValueError:
        pass
if not vals:
    print("FAIL|0|0|0|0")
else:
    vals.sort()
    p50 = vals[len(vals) // 2]
    p95 = vals[min(len(vals) - 1, int(len(vals) * 0.95))]
    print("OK|%d|%d|%d|%d" % (len(vals), p50, p95, max(vals)))
PY
)"
  local ok_n p50 p95 mx rate verdict
  ok_n="$(echo "$stats" | cut -d'|' -f2)"
  p50="$(echo "$stats" | cut -d'|' -f3)"
  p95="$(echo "$stats" | cut -d'|' -f4)"
  mx="$(echo "$stats" | cut -d'|' -f5)"
  rate=$(( ok_n * 100 / n ))

  if [ "$ok_n" = "0" ]; then
    verdict="❌ 全失败"
  elif [ "$rate" -ge 95 ]; then
    verdict="✅"
  else
    verdict="⚠️成功率不足"
  fi
  printf " %s 成功率 %d%%  p50 %sms  p95 %sms  max %sms\n" \
    "$verdict" "$rate" "$p50" "$p95" "$mx"

  [ "$FIRST" = "1" ] || printf ',' >> "$OUT"
  FIRST=0
  printf '{"name":"%s","runs":%s,"ok":%s,"rate":%s,"p50_ms":%s,"p95_ms":%s,"max_ms":%s}' \
    "$name" "$n" "$ok_n" "$rate" "$p50" "$p95" "$mx" >> "$OUT"
}

echo ""
echo "=== 闪控性能验收（全程静音 · 每项 $RUNS 次）==="
echo ""
echo "【L0 预算 p50≤1.5s p95≤3s】"
bench_one "open_file(唯一命中)" open_file.sh --name "闪控Skill需求规格书-v1.0.md"
bench_one "open_file(多候选)"    open_file.sh --name "需求规格"
bench_one "music_play(恢复会话)" music_play.sh
bench_one "douyin_open"          douyin_open.sh

echo ""
echo "【L1 预算 p50≤3s p95≤6s】"
bench_one "wechat_send(校验)"    wechat_send.sh --to "X" --msg ""

printf ']}\n' >> "$OUT"
echo ""
echo "结果已写入: $OUT"
echo ""

if [ "$KEEP_MUTED" = "1" ]; then
  echo "🔇 保持静音（--keep-muted）"
else
  silence_guard_restore
fi