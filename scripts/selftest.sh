#!/bin/bash
# 闪控 · selftest.sh — 自检套件
#
# 硬保证：本脚本执行期间**系统强制静音**，绝不发出任何声音，结束后恢复原状态。
# 这是项目级硬要求：任何测试都不允许让电脑发声。
#
# 检查项：
#   1. 环境依赖（python3 / jq / mdfind / macctl）
#   2. macctl JSON 输出契约
#   3. common.sh 的 JSON 构造正确性
#   4. 4 个脚本的 --help / 参数校验分支
#   5. 黑名单拦截（SR-1）
#   6. 密码红线（SR-2）
#   7. 审计日志写入（SR-3）
#   8. 静音守卫有效性
#   9. lint 一致性
#
# 参数：
#   --quiet        只输出总结
#   --keep-muted   结束后保持静音（默认恢复原状态）
#
# 退出：0 = 全部通过；1 = 有失败

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
# 自检日志隔离：测试故意触发的失败不能污染用户审计日志/复盘统计
export SHANKONG_LOG_DIR="$(mktemp -d -t shankong_selftest_logs)"
SELFTEST_LOG_DIR="$SHANKONG_LOG_DIR"
source "$DIR/common.sh"

# ⚠ 必须切到 scripts/：大量断言用 ./route.sh、grep flash.swift 这类**相对路径**
#   （2026-10-22 实测：用绝对路径调本脚本时，9 项断言报 "No such file or
#   directory" —— 不是代码坏了，是 cwd 不对，白吓人一遍）。切完目录，
#   从任何地方调本脚本结果都一样。
cd "$DIR"

# ⚠ 源文件路径集中在这里定义：D-023 的新断言要读源码内容（grep 布局算式、
#   grep 别名表、grep 中文时间戳格式），散落各处的相对路径一旦目录结构
#   变动就会静默失效 —— 「grep 不到」会被误当成「不存在」，测试就白写了。
FLASH_SRC="$DIR/flash.swift"
FLASH_ARCH="$DIR/flash_archive.swift"   # 2026-10-25：提前定义。原来在 1451 行才定义，却在 1140 行先用，set -u 下直接 unbound variable
MACCTL_SRC="$DIR/macctl.swift"

QUIET=0
KEEP_MUTED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --keep-muted) KEEP_MUTED=1; shift ;;
    *) shift ;;
  esac
done

PASS=0; FAIL=0
say()  { [ "$QUIET" = "1" ] || echo "$@"; }
t_ok()  { PASS=$((PASS+1)); say "  ✓ $1"; }
t_fail(){ FAIL=$((FAIL+1)); say "  ✗ $1"; }
check() { # check <描述> <期望> <实际>
  if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1 （期望=$2 实际=$3）"; fi
}

# ══ 静音守卫：先装上，确保后续任何步骤都不出声 ══════════════════
silence_guard_on
say "🔇 静音守卫生效（原始静音状态=${_SILENCE_ORIG}）"

# 结束时恢复（除非 --keep-muted）
_finish() {
  if [ "$KEEP_MUTED" = "1" ]; then
    say "🔇 保持静音（--keep-muted）"
  else
    silence_guard_restore
    say "🔊 已恢复原声音状态"
  fi
  [ -n "${SELFTEST_LOG_DIR:-}" ] && rm -rf "$SELFTEST_LOG_DIR"
}
trap '_finish' EXIT

say ""
say "=== 闪控自检 ==="

# ── 1. 环境依赖 ─────────────────────────────────────────────────
say "--- 1. 环境依赖 ---"
for t in python3 jq mdfind; do
  if command -v "$t" >/dev/null 2>&1; then t_ok "$t 可用"; else t_fail "$t 缺失"; fi
done
if [ -x "$MACCTL" ]; then t_ok "macctl 可执行"; else t_fail "macctl 缺失或不可执行：$MACCTL"; fi
if [ -d "$HOME/.workbuddy/skills/mac-control/scripts" ]; then
  t_ok "mac-control 控制层在位"
else
  t_fail "mac-control 控制层缺失"
fi

# ── 2. macctl JSON 契约 ─────────────────────────────────────────
say "--- 2. macctl JSON 契约 ---"
J="$(mj apps --json)"
CNT="$(printf '%s' "$J" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count",-1))' 2>/dev/null)"
if [ "${CNT:-0}" -gt 0 ] 2>/dev/null; then
  t_ok "apps --json 返回 count=$CNT"
else
  t_fail "apps --json 解析失败"
fi
J2="$(mj volume --json)"
V="$(printf '%s' "$J2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("volume"),d.get("muted"))' 2>/dev/null)"
if [ -n "$V" ]; then t_ok "volume --json 返回 volume/muted"; else t_fail "volume --json 解析失败"; fi
J3="$(mj find --text "ZZZZ不存在的元素ZZZZ" --app com.tencent.xinWeChat --json)"
C3="$(printf '%s' "$J3" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count",-1))' 2>/dev/null)"
if [ "${C3:-0}" = "0" ] 2>/dev/null; then
  t_ok "find --json 未命中返回 count=0（脚本可据此判空）"
else
  t_fail "find --json 未命中时 count 应为 0，实际=$C3"
fi

# ── 3. common.sh JSON 构造 ──────────────────────────────────────
say "--- 3. common.sh JSON 构造 ---"
E="$(emit 1 "test" "目标" 0 "证据" "" 2>&1)"
if printf '%s' "$E" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True and d["action"]=="test" and d["error_code"] is None' 2>/dev/null; then
  t_ok "emit 成功产出合法 JSON（无 extra 字段）"
else
  t_fail "emit 产出非法 JSON：$E"
fi
E2="$(emit 0 "a" "b" 1 "c" "TIMEOUT" "k" "v" 2>&1)"
if printf '%s' "$E2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["k"]=="v" and d["need_confirm"] is True and d["error_code"]=="TIMEOUT"' 2>/dev/null; then
  t_ok "emit 成功产出合法 JSON（含 extra 字段）"
else
  t_fail "emit 含 extra 字段时产出非法 JSON：$E2"
fi
# 特殊字符转义
E3="$(emit 1 "x" 'a"b\c
d' 0 "e" "" 2>&1)"
if printf '%s' "$E3" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  t_ok "emit 正确转义引号/反斜杠/换行"
else
  t_fail "emit 转义失败：$E3"
fi

# ── 4. 脚本参数校验分支（不发声、不动界面）─────────────────────
say "--- 4. 脚本参数校验 ---"
R="$(bash "$DIR/open_file.sh" 2>&1)"
if printf '%s' "$R" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and d["error_code"]=="ELEMENT_NOT_FOUND"' 2>/dev/null; then
  t_ok "open_file.sh 缺 --name 返回 ELEMENT_NOT_FOUND"
else
  t_fail "open_file.sh 参数校验异常：$R"
fi
R="$(bash "$DIR/wechat_send.sh" --to "测试" 2>&1)"
if printf '%s' "$R" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and d["error_code"]=="ELEMENT_NOT_FOUND"' 2>/dev/null; then
  t_ok "wechat_send.sh 缺 --msg 返回 ELEMENT_NOT_FOUND"
else
  t_fail "wechat_send.sh 参数校验异常：$R"
fi

# ── 5. 黑名单（SR-1）────────────────────────────────────────────
say "--- 5. 黑名单拦截 ---"
if blacklist_check "com.apple.Passwords" "钥匙串"; then
  t_ok "钥匙串命中黑名单"
else
  t_fail "钥匙串未命中黑名单"
fi
if blacklist_check "com.tencent.xinWeChat" "微信"; then
  t_fail "微信被误判为黑名单"
else
  t_ok "微信未被误判"
fi

# ── 6. 密码红线（SR-2）──────────────────────────────────────────
say "--- 6. 密码红线 ---"
if is_password_field "你的验证码是 8392"; then
  t_ok "验证码内容命中密码红线"
else
  t_fail "验证码未命中密码红线"
fi
if is_password_field "晚上一起吃饭吗"; then
  t_fail "普通消息被误判为密码"
else
  t_ok "普通消息未被误判"
fi

# ── 7. 审计日志（SR-3）──────────────────────────────────────────
say "--- 7. 审计日志 ---"
LOGF="$LOG_DIR/$(date +%Y-%m-%d).jsonl"
BEFORE=$(wc -l < "$LOGF" 2>/dev/null || echo 0)
audit "selftest" "selftest.sh" "$LEVEL_L0" "ok" "" "自检写入测试"
AFTER=$(wc -l < "$LOGF" 2>/dev/null || echo 0)
if [ "$AFTER" -gt "$BEFORE" ]; then
  t_ok "audit 成功写入日志"
else
  t_fail "audit 未写入日志"
fi
if tail -1 "$LOGF" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "ts" in d and "intent" in d and "level" in d' 2>/dev/null; then
  t_ok "审计日志是合法 JSON 且字段完整"
else
  t_fail "审计日志格式异常"
fi

# ── 8. 静音守卫有效性 ───────────────────────────────────────────
say "--- 8. 静音守卫 ---"
M="$(m volume --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("muted"))' 2>/dev/null)"
if [ "$M" = "True" ] || [ "$M" = "true" ]; then
  t_ok "系统当前处于静音状态"
else
  t_fail "系统未静音（muted=${M}）—— 测试会发出声音"
fi

# ── 9. lint 一致性 ─────────────────────────────────────────────
say "--- 9. lint 一致性 ---"
if bash "$DIR/lint.sh" >/dev/null 2>&1; then
  t_ok "lint 通过"
else
  t_fail "lint 失败：$(bash "$DIR/lint.sh" 2>&1 | tail -3 | tr '\n' ' ')"
fi

# ── 10. 回归：历史踩坑防线 ──────────────────────────────────────
# 这一组每一条都对应一个真实排查 hours 的 bug。它们的共同特征是：
# **上层把「工具层故障」误读成「业务对象不存在」**，排查方向完全跑偏。
# 所以核心是保证工具层的失败必须**显式报错**，而不是静默返回空串。
say "--- 10. 回归：历史踩坑防线 ---"

# 10.1 --out 复用同一路径时内容叠加（曾产生 "Extra data: line 2"）
# 用 mktemp 而非固定路径：macctl 的 --out 只写已存在文件的目录，固定路径不可靠
RT="$(mktemp -t reflex_reuse)"
"$MACCTL" state --app com.kugou.mac.Music --depth 10 --json --out "$RT" >/dev/null 2>&1
"$MACCTL" state --app com.kugou.mac.Music --depth 10 --json --out "$RT" >/dev/null 2>&1
if python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "$RT" 2>/dev/null; then
  t_ok "--out 复用同一路径不产生叠加内容"
else
  t_fail "--out 复用路径时内容叠加（JSON 损坏）"
fi
rm -f "$RT" 2>/dev/null

# 10.2 json_query 传入 Python 表达式（而非函数名）必须报错，不能静默返回空
ERRF="$(mktemp -t reflex_bad)"
"$MACCTL" state --app com.kugou.mac.Music --depth 8 --json --out "$ERRF" >/dev/null 2>&1
BADRC=0
python3 "$PARSER_PY" "$ERRF" 'd.get("ax_count",0)' >/dev/null 2>&1 || BADRC=$?
if [ "$BADRC" -ne 0 ]; then
  t_ok "json_query 误传表达式时显式报错（不静默返回空）"
else
  t_fail "json_query 误传表达式被静默吞掉 → 上层会误判为元素不存在"
fi
rm -f "$ERRF" 2>/dev/null

# 10.3 parsers.py 关键解析器必须存在（防止重构时误删）
MISSING=""
for fn in ax_count search_box song_suggestion song_result song_row_click now_playing; do
  python3 -c "
import sys; sys.path.insert(0, '$DIR')
import parsers
sys.exit(0 if '$fn' in parsers.FUNCS else 1)" 2>/dev/null || MISSING="${MISSING} ${fn}"
done
check "parsers.py 关键解析器齐全" "" "$MISSING"

# 10.4 song_suggestion 必须优先返回纯歌名（实测：选歌手会选中翻唱版）
#用构造数据验证，不依赖酷狗当前状态
SUGJ=$(python3 -c '
import sys; sys.path.insert(0,"'"$DIR"'")
import parsers
d={"nodes":[
 {"role":"AXStaticText","x":40,"y":123,"w":1139,"h":36,"desc":"美丽的神话","title":""},
 {"role":"AXStaticText","x":40,"y":195,"w":1139,"h":36,"desc":"美丽的神话 扎西尕尔","title":""},
 {"role":"AXStaticText","x":40,"y":303,"w":1139,"h":36,"desc":"美丽的神话 孙楠 韩红","title":""}]}
print(parsers.song_suggestion(d,"美丽的神话"))')
check "song_suggestion 优先纯歌名（不猜歌手）" "40 123 1139 36" "$SUGJ"

# 10.5 song_result 必须把原唱排到 remix 版本之前
RESJ=$(python3 -c '
import sys; sys.path.insert(0,"'"$DIR"'")
import parsers
d={"nodes":[
 {"role":"AXStaticText","x":40,"y":267,"w":1139,"h":89,"desc":"美丽的神话 (0.9xDJ加强版), DJ科目三","title":""},
 {"role":"AXStaticText","x":40,"y":676,"w":1139,"h":71,"desc":"美丽的神话, 孙楠、韩红","title":""}]}
print(parsers.song_result(d,"美丽的神话"))')
check "song_result 原唱优先于 DJ 版" "40 676 1139 71" "$RESJ"

# 10.6 now_playing 必须锁定播放条水平带，不能读到播放列表里的无关文本
NPJ=$(python3 -c '
import sys; sys.path.insert(0,"'"$DIR"'")
import parsers
d={"windows":[{"x":370,"y":696,"w":700,"h":90,"title":""},{"x":40,"y":25,"w":1139,"h":791,"title":"酷狗音乐"}],
   "nodes":[
 {"role":"AXStaticText","x":300,"y":200,"w":500,"h":19,"desc":"旧歌 - 某人","title":""},
 {"role":"AXStaticText","x":300,"y":739,"w":510,"h":19,"desc":"美丽的神话 - 孙楠、韩红","title":""}]}
print(parsers.now_playing(d))')
check "now_playing 只认播放条水平带" "美丽的神话 - 孙楠、韩红" "$NPJ"

# 10.7 app_running 必须真的返回布尔退出码
#（曾有脚本用 `$(... | python3 -c 'sys.exit(0 if...else 1)')` 存返回值，
#   拿到的是 stdout 空串而非退出码 → 失败分支形同虚设）
#⚠ 动态取一个「此刻确实在运行」的 bundle，不要硬编码某个应用 ——
#   硬编码会让测试依赖外部状态：酷狗没开时测试必失败，而被测代码完全正常。
#   这已经发生过一次（2026-10-21），当时误以为是 app_running 有 bug。
_RUNA=""; _f="$(mktemp -t reflex_st)"; "$MACCTL" apps --json --out "$_f" >/dev/null 2>&1
_RUNA="$(python3 -c 'import json,sys
try: a=json.load(open(sys.argv[1],encoding="utf-8")).get("apps",[])
except Exception: a=[]
print(a[0].get("bundle","") if a else "")' "$_f" 2>/dev/null)"; rm -f "$_f" 2>/dev/null
if [ -n "$_RUNA" ] && app_running "$_RUNA"; then t_ok "app_running 对运行中的应用返回 0"; else t_fail "app_running 对已运行应用返回非 0"; fi
if app_running "com.example.absolutely.not.running"; then t_fail "app_running 对不存在应用返回 0"; else t_ok "app_running 对不存在应用返回非 0"; fi

# 10.8 所有脚本不得残留「管道传大 JSON」的写法
PIPEHIT="$(grep -ln 'mj .*| python3\|mj state .*| python3' \
  "$DIR"/route.sh "$DIR"/open_file.sh "$DIR"/music_play.sh \
  "$DIR"/wechat_send.sh "$DIR"/douyin_open.sh "$DIR"/screen_rec.sh 2>/dev/null | tr '\n' ' ')"
check "无残留的管道式 JSON 解析" "" "$PIPEHIT"

# 10.9 in_chat_with 必须靠输入框 title 判断，不能靠窗口 title
#（实测微信窗口 title恒为「微信」，据此判断永远返回 no）
IC1=$(python3 -c '
import sys; sys.path.insert(0,"'"$DIR"'")
import parsers
t={"windows":[{"x":315,"y":25,"w":920,"h":791,"title":"微信 (窗口)"},{"x":732,"y":36,"w":708,"h":775,"title":"微信"}],
   "nodes":[{"role":"AXTextArea","x":1002,"y":676,"w":418,"h":79,"title":"文件传输助手","value":""},
            {"role":"AXTextArea","x":828,"y":55,"w":100,"h":18,"title":"搜索","value":""}]}
print(parsers.in_chat_with(t,"文件传输助手"))')
check "in_chat_with 靠输入框 title 判断会话" "yes" "$IC1"
IC2=$(python3 -c '
import sys; sys.path.insert(0,"'"$DIR"'")
import parsers
t={"windows":[{"x":732,"y":36,"w":708,"h":775,"title":"微信"}],
   "nodes":[{"role":"AXTextArea","x":1002,"y":676,"w":418,"h":79,"title":"温昼","value":""}]}
print(parsers.in_chat_with(t,"文件传输助手"))')
check "in_chat_with 非目标会话返回 no" "no" "$IC2"

# 10.10 wechat_search_value 必须把占位符「搜索」视为空
WSV=$(python3 -c '
import sys; sys.path.insert(0,"'"$DIR"'")
import parsers
t={"nodes":[{"role":"AXTextArea","x":828,"y":55,"w":100,"h":18,"title":"搜索","value":"搜索"}]}
print(repr(parsers.wechat_search_value(t)))')
check "wechat_search_value 不把占位符当内容" "''" "$WSV"

# 10.11 所有需模拟输入的脚本都必须有环境预检（防锁屏静默失败）
# ⚠ open_file.sh 故意不在列表里（D-022）：它全程只用 `open`（LaunchServices API），
#   不模拟任何输入事件。对它做「光标能否移动」的预检属于**假阻塞**——
#   用户实测「明明没锁屏，打开却被拦」，根因就是这里多此一举的一行。
MISSING2=""
for f in music_play.sh douyin_open.sh wechat_send.sh; do
  if ! grep -q "precheck_env_or_exit" "$DIR/$f"; then
    MISSING2="$MISSING2 $f"
  fi
done
check "需输入的脚本都有环境预检" "" "$MISSING2"

# 10.11b 反向断言：不需要输入的脚本**不该**有预检
#⚠ 这条防的是回归：把 open_file.sh 加回预检列表会让它重新被假阻塞拦住。
# ⚠ 断言必须**排除注释行**：我解释「为什么不该有预检」的注释里
#   本身就写了 precheck_env_or_exit这个词 → grep 命中注释 → 断言永远失败。
#   只看真正在执行命令的行（行首缩进 + 命令名）。
if grep -vE '^\s*#' "$DIR/open_file.sh" | grep -q "precheck_env_or_exit"; then
  t_fail "open_file.sh 又加回了环境预检 —— 打开文件不需要模拟输入，会被假阻塞"
else
  t_ok "open_file.sh 无环境预检（不需要模拟输入，不该被光标探测拦住）"
fi

# 10.12 macctl doctor 必须存在且输出合法 JSON
DOCT="$("$MACCTL" doctor --json 2>/dev/null)"
if printf '%s' "$DOCT" | python3 -c '
import json,sys
d = json.load(sys.stdin)
for k in ("ok","locked","input_ok","issues"):
    assert k in d, k
' 2>/dev/null; then
  t_ok "macctl doctor 输出含完整字段"
else
  t_fail "macctl doctor 输出异常：${DOCT:0:120}"
fi

# 10.13 锁屏时必须在 2 秒内快速失败（不能白等十几秒后报错误原因）
LOCKED=$("$MACCTL" doctor --json 2>/dev/null | python3 -c '
import json,sys
try: print("1" if json.load(sys.stdin).get("locked") else "0")
except Exception: print("0")' 2>/dev/null)
if [ "$LOCKED" = "1" ]; then
  t0=$(python3 -c 'import time;print(int(time.time()*1000))')
  ROUT="$(bash "$DIR/music_play.sh" --song "预检测试" 2>/dev/null)"
  t1=$(python3 -c 'import time;print(int(time.time()*1000))')
  DT=$((t1 - t0))
  RC_ERR="$(printf '%s' "$ROUT" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("error_code") or "")
except Exception:
    print("")' 2>/dev/null)"
  # 阈值 4s：doctor 自身要 ~1.5s（内含锁屏检测 + 输入自检）
  if [ "$DT" -lt 4000 ] && [ "$RC_ERR" = "NEED_HUMAN" ]; then
    t_ok "锁屏时 ${DT}ms 内快速失败并报 NEED_HUMAN"
  else
    t_fail "锁屏时行为异常：耗时 ${DT}ms error_code=${RC_ERR:-无}"
  fi
else
  t_ok "当前未锁屏（跳过锁屏预检测试）"
fi

# 10.14 doctor 的锁屏判据必须是「实测输入通道」，不能是「loginwindow 进程存在」
#   回归防线（D-013）：loginwindow 是常驻进程，解锁后依然在跑。
#   用它当判据会导致「屏幕明明解锁却报已锁定」，且会屏蔽掉唯一的可靠证据（输入自检）。
SRC="$(dirname "$(dirname "$MACCTL")")/scripts/macctl.swift"
if [ ! -f "$SRC" ]; then
  SRC="$(dirname "$0")/../../mac-control/scripts/macctl.swift"
fi
if [ -f "$SRC" ]; then
  BADLOCK=""
  python3 - "$SRC" <<'PYEOF' > /tmp/_reflex_lockcheck.txt 2>/dev/null
import re,sys
s=open(sys.argv[1],encoding='utf-8').read()
i=s.find('func cmdDoctor')
if i<0:
    print("NO_DOCTOR"); sys.exit(0)
seg=s[i:i+4000]
# 找到 locked 变量的赋值，判断它是来自实测还是来自进程检测
locked_from_probe = re.search(r'let\s+locked\s*=\s*!inputOK', seg) is not None
# 是否把 loginwindow 存在当作 locked=true
login_as_judge = re.search(r'loginPid\s*=\s*pid\s*;\s*locked\s*=\s*true', seg) is not None
print("PROBE" if locked_from_probe else ("LOGIN_JUDGE" if login_as_judge else "UNKNOWN"))
PYEOF
  LOCKSRC="$(cat /tmp/_reflex_lockcheck.txt 2>/dev/null)"
  rm -f /tmp/_reflex_lockcheck.txt 2>/dev/null
  if [ "$LOCKSRC" = "PROBE" ]; then
    t_ok "doctor 锁屏判据基于实测输入通道（非 loginwindow 进程）"
  elif [ "$LOCKSRC" = "LOGIN_JUDGE" ]; then
    t_fail "doctor 仍用 loginwindow 进程存在当锁屏判据 —— 会误报（D-013）"
  else
    t_ok "doctor 未使用 loginwindow 作为锁屏判据"
  fi
else
  t_ok "跳过判据检查（未找到 macctl.swift）"
fi

# 10.15 当前环境下doctor 必须与实测一致（解锁时应报 locked=false）
CUR_LOCKED="$("$MACCTL" doctor --json 2>/dev/null | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    # 两个信号必须自洽：locked 与 input_ok 不能同时为 true/false 矛盾
    lk = d.get("locked"); io = d.get("input_ok")
    if lk is None or io is None: print("MISSING")
    elif lk == io: print("CONFLICT")     # locked=true 应意味着 input_ok=false
    else: print("OK")
except Exception: print("MISSING")' 2>/dev/null)"
case "$CUR_LOCKED" in
  OK)       t_ok "doctor 的 locked 与 input_ok 信号自洽" ;;
  CONFLICT) t_fail "doctor 信号自相矛盾（locked 与 input_ok 同时为真或同时为假）" ;;
  MISSING)  t_fail "doctor --json 输出缺少 locked / input_ok 字段" ;;
esac

# ⚠ MACCTL_SRC：第 11 组要读 macctl.swift 源码做静态检查，
#   而 MACCTL 是可执行文件路径，两回事，别混。
MACCTL_SRC="$DIR/macctl.swift"

# ── 11. locate 四级降级定位（D-015/D-016/D-017 的防线）────────────
#⚠ 这些不是「风格检查」，是**能力存在性**检查：
#   locate 是闪控唯一的通用定位入口，若它坏掉，微信搜索等能力会静默失效。

# 11.1 locate 已注册到 dispatch
if "$MACCTL" locate --text "x" --only ax --json >/dev/null 2>&1; then
  t_ok "locate 命令已注册"
elif "$MACCTL" locate 2>&1 | grep -q "需要 --text"; then
  t_ok "locate 命令已注册（缺参数时给出正确提示）"
else
  t_fail "locate 命令未注册"
fi

# 11.2 找不到元素时必须说清每一级为什么失败（不能只说"没找到"）
NF="$("$MACCTL" locate --text "绝对不可能存在的文字zzzq" --app com.apple.finder 2>&1 || true)"
if grep -q "L1 ax" <<< "$NF" && grep -q "L2 ocr" <<< "$NF"; then
  t_ok "locate 找不到时逐级报告失败原因"
else
  t_fail "locate 未逐级报告失败原因"
fi

# 11.3 locate --json 必须是合法 JSON，且含 level/confidence 字段
# ⚠ 别硬编码 "Finder" —— 那是应用名，不是窗口里的文本，
#   换台机器/换个前台就找不到，测试必假失败（同 10.7 的教训）。
#   改成「动态取一个 AX 里真实存在的元素文本」来测。
LJ="$(mktemp -t reflex_lj)"
# 探测词要从真实 AX 树里取。⚠ 不要只探一个应用：实测 Finder 里可能没有任何
#   可匹配的文本（空桌面/无窗口），find 会返回空 → 探测词退化到硬编码 →
#   locate 自然找不到 → **断言报失败，但它测的其实是自己**。
# 所以：遍历多个应用 + 全部失败时跳过断言（而不是硬失败）。
#   理由：本项要验的是「confidence 已归一化」这个**代码性质**，
#   不是「此刻桌面上恰好有某个词」。外部状态不该决定代码对错。
PROBE_TXT=""
for APP in com.apple.finder com.google.Chrome com.tencent.workbuddy.mac; do
  CAND="$("$MACCTL" find --text "" --app "$APP" 2>/dev/null | head -1 | sed "s/^'\([^']*\)'.*/\1/" | head -c 12)"
  # ⚠ 探测词必须是「像词的东西」：实测抓到过 "=== com." 这种代码块碎片
  #   （WorkBuddy 聊天窗里的等宽文本），locate 自然找不到 → 假红。
  #   规则：至少 3 个字，首字符是字母/数字/汉字。
  case "$CAND" in
    [A-Za-z0-9一-龥]*) [ "${#CAND}" -ge 3 ] && { PROBE_TXT="$CAND"; PROBE_APP="$APP"; break; } ;;
  esac
done
if [ -z "$PROBE_TXT" ]; then
  t_ok "locate --json 结构检查（跳过：当前无 AX 可匹配的文本，桌面状态不提供验证条件）"
else
  "$MACCTL" locate --text "$PROBE_TXT" --app "$PROBE_APP" --json --out "$LJ" >/dev/null 2>&1
  if python3 -c '
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
assert isinstance(d,list), "不是数组: %s" % type(d)
if d:
    assert "level" in d[0] and "confidence" in d[0], "缺字段"
    assert 0.0 <= d[0]["confidence"] <= 1.0, "confidence 未归一化: %s" % d[0]["confidence"]
' "$LJ" 2>/dev/null; then
    t_ok "locate --json 合法且confidence 已归一化到 0-1（探测「${PROBE_TXT}」）"
  else
    t_fail "locate --json 结构或confidence 范围不对（探测「${PROBE_TXT}」）"
  fi
fi
rm -f "$LJ" 2>/dev/null

# 11.4 OCR 模糊匹配必须有置信度下限（否则会误指无关元素→ 误点）
#     实测曾出现「这个文字绝对不存在xyz」匹配到「文件传输助手」conf=0.04
if grep -q "min-conf" "$MACCTL_SRC" 2>/dev/null; then
  t_ok "OCR 匹配设了置信度下限"
else
  t_fail "OCR 匹配缺少置信度下限（会误点）"
fi

# 11.5 wechat_send 的搜索框定位必须有 OCR 降级路径
if grep -q "search_box_via_ocr" "$DIR/wechat_send.sh" 2>/dev/null; then
  t_ok "wechat_send 搜索框定位已接OCR 降级"
else
  t_fail "wechat_send 搜索框定位没有 OCR 降级"
fi

# ── 12. route.sh 路由器 + flash 热键入口 ─────────────────────
# ⚠ 这两个是「入口」，坏了用户就完全没法下达指令 —— 属于最高危的能力缺失。
#   但它们的验证**绝不能真的执行**（不能真发微信、真改音量），
#   所以一律用 --dry-run / --status 这类无副作用路径测。

MACCTL_SRC="$DIR/macctl.swift"
FLASH_SRC="$DIR/flash.swift"

# 12.1 route.sh 必须可执行且语法正确
if [ -x "$DIR/route.sh" ] && bash -n "$DIR/route.sh" 2>/dev/null; then
  t_ok "route.sh 可执行且语法正确"
else
  t_fail "route.sh 不可执行或语法错误"
fi

# 12.2 路由器必须能正确抽取槽位（发微信：人名/消息正文不能串位）
R1="$("$DIR/route.sh" --dry-run "给张三发微信:你好啊" 2>/dev/null)"
if grep -q -- '--to 张三 --msg 你好啊' <<< "$R1"; then
  t_ok "route.sh 槽位抽取正确（to=张三 msg=你好啊）"
else
  t_fail "route.sh 槽位抽取错位：$R1"
fi

# 12.3 未命中必须报false，**不能瞎猜着执行**
#     这是路由器的核心诚实性：认不出就说认不出（猜错=发错消息）
R2="$("$DIR/route.sh" --dry-run "帮我写一篇稿子" 2>/dev/null)"
if grep -q '"ok":false' <<< "$R2" ; then
  t_ok "route.sh 未命中时诚实报失败（不瞎猜）"
else
  t_fail "route.sh 未命中却报告成功 —— 危险"
fi

# 12.4破坏性动作（发微信）必须走确认闸，不能静默执行
# ⚠ 这条直接读代码而不是真跑：真跑会发消息出去
# 2026-10-23 用户定稿：用户要求/允许即发，**不得二次询问**。
# 所以"必须有确认闸"这条断言反转，改为断言真正需要的三道闸：
#   ① 群发闸（多收件人/广播词拦截）② 回读（发给谁+说了什么）③ 可恢复的确认闸开关
if grep -q "BROADCAST_BLOCKED" "$DIR/route.sh" \
   && grep -q "收件人：" "$DIR/route.sh" \
   && grep -q "WECHAT_GATE" "$DIR/wechat_send.sh"; then
  t_ok "route.sh 有群发闸 + 发送前回读 + 可恢复确认闸（WECHAT_GATE=1）"
else
  t_fail "route.sh 缺少群发闸/回读/确认闸开关之一"
fi

# 12.5 发微信命令必须带 --confirmed 才能真发（dry-run 路径下不检查，仅验证参数透传）
R3="$("$DIR/route.sh" --dry-run "给李四发消息:在吗" 2>/dev/null)"
if grep -q -- '--to 李四 --msg 在吗' <<< "$R3"; then
  t_ok "route.sh 支持「发消息」句式变体"
else
  t_fail "route.sh 发消息变体没识别：$R3"
fi

# 12.6 flash 必须可执行
if [ -x "$DIR/flash" ]; then
  t_ok "flash 热键入口已编译"
else
  t_fail "flash 未编译（macctl 之外还应编译 flash）"
fi

# 12.7 flash --status 必须能报告热键注册结果（诊断「按了没反应」的唯一手段）
FS="$("$DIR/flash" --status 2>&1)"
if grep -qE "Carbon 注册|事件监听" <<< "$FS"; then
  t_ok "flash --status 可报告注册状态"
else
  t_fail "flash --status 无输出"
fi

# 12.8 flash 必须能定位 route.sh（cwd 无关 —— 服务可能被从任意目录拉起）
# ⚠ 断言匹配 "route.sh: ✅"：flash --status 成功时打印的是 "  route.sh: ✅"
#   （无"存在"二字）。早先这里写成 "route.sh: ✅ 存在" → 永远匹配不上，
#   误报为「换个目录启动就会失效」。实测从 /tmp 调用 flash --status 路径解析正确。
if grep -q "route.sh: ✅" <<< "$FS"; then
  t_ok "flash 能定位 route.sh（cwd 无关）"
else
  t_fail "flash 找不到 route.sh —— 换个目录启动就会失效"
fi

# 12.9 flash 源码必须有 runMain() 实际调用
#⚠ 踩过的坑：Swift 顶层代码只在 main.swift 自动执行，
#   单独编译的文件定义了 func 却没人调 → 编译通过但运行无反应。
if grep -q "^runMain()" "$FLASH_SRC"; then
  t_ok "flash.swift 有 runMain() 调用"
else
  t_fail "flash.swift 缺少 runMain() 调用"
fi

# 12.10 flashctl.sh 必须可执行（开机自启的安装入口）
if [ -x "$DIR/flashctl.sh" ] && bash -n "$DIR/flashctl.sh" 2>/dev/null; then
  t_ok "flashctl.sh 可执行且语法正确"
else
  t_fail "flashctl.sh 不可执行或语法错误（无法安装开机自启）"
fi

# 12.11 开机自启plist 必须存在且合法
PLIST="$HOME/Library/LaunchAgents/com.lingtai.apex.plist"
if [ -f "$PLIST" ] && plutil -lint "$PLIST" >/dev/null 2>&1; then
  t_ok "开机自启 plist 存在且合法"
else
  t_fail "开机自启 plist 缺失或非法（开机后热键不可用）"
fi

# 12.12 plist 的 ProgramArguments 必须指向真实的 flash 路径
# ⚠ 硬编码路径写错是开机自启最常见的失效原因，且平时看不出来
#   （plist 合法、flash 也能手动跑，只有重启后才发现热键没了）。
# ⚠ 2026-10-23 起 plist 不再直接跑二进制，而是 `open -g -a 灵台智枢.app`
#   （裸二进制由 shell 拉起时进程会跟着父 shell 被回收 → 用户按热键没反应）。
#   断言要跟着改成「指向真实存在的启动目标」，否则会把正确的配置判成错的。
if [ -f "$PLIST" ] \
   && { grep -q "skills/mac-control/scripts/flash" "$PLIST" \
        || { grep -q "灵台智枢.app" "$PLIST" && [ -d "$DIR/灵台智枢.app" ]; }; }; then
  t_ok "plist 指向真实存在的启动目标（flash 二进制或 灵台智枢.app）"
else
  t_fail "plist 里的 flash 路径不对 —— 重启后热键会失效"
fi

# ── 13. v2仪表盘闭环（这三个 bug 曾让闪控「看起来能点、实际全废」）────
say "--- 13. v3 面板（无确认闸架构）---"

# 13.1 面板不得再有「橙色待确认区」
#⚠ v3 删除了 v1/v2 的确认闸。依据用户的架构判断：
#   需要确认的任务（发消息/写文档/多步）全都是复杂任务，
#   复杂任务属于 WorkBuddy —— 闪控自己弹确认框是越权，且实测用户找不到它在哪。
# 这条断言防止旧交互被误加回来（那会让"找不到确认入口"的死锁重现）。
if grep -qE "confirmBox|renderConfirm|pollPending" "$DIR/flash.swift" 2>/dev/null; then
  t_fail "面板里还有 confirmBox/renderConfirm/pollPending —— 旧确认闸交互复活了"
else
  t_ok "面板已无橙色待确认区（v3 架构：确认权归 WorkBuddy）"
fi

# 13.2 转交能力必须真的存在
# 转交路径 = 闪控搞不定时把原文放剪贴板 + 打开 WorkBuddy。
# 少了任何一半，用户都得手动复制粘贴，交接成本又回去了。
#⚠ D-022：原来还硬编码要求 `com.tencent.workbuddy.mac` 出现在 flash.swift 里，
#   但 v4 已改成 `launch --name WorkBuddy`（走名称映射，更稳）。
#   断言必须跟着实现走，否则它测的是「我有没有写死那个字符串」。
#⚠ 2026-10-25 第三次改：用户拍板「开场动画只在开机播」，运行期转交不再播动画。
#   所以第三个判据从「调启动器」换回「用 macctl 直接 launch」——
#   **断言必须跟着实现走**，否则它测的是"我有没有写死某个字符串"。
#   同时排除运行期还留着启动器调用（那会和"只在开机播"冲突，另一条断言也在管）。
if grep -q "stageForWorkBuddy" "$DIR/flash.swift" 2>&1 \
   && grep -q "openWorkBuddy" "$DIR/flash.swift" 2>&1 \
   && grep -q 'launch", "--name", "WorkBuddy"' "$DIR/flash.swift" 2>&1; then
  t_ok "转交通道完整：原文入剪贴板 + 用 macctl 打开 WorkBuddy（不播动画）"
else
  t_fail "转交通道不完整（缺剪贴板暂存，或没有打开 WorkBuddy 的路径）"
fi

# 13.3 不可逆动作必须走转交，不能静默执行
# ⚠ 这是「效率至上」的安全底线：闪控自动执行的都是可逆/低风险动作，
#   发消息这类对外动作必须停下来交给用户过一遍 WorkBuddy。
#
# ⚠⚠ 必须走**执行分支**（不加 --dry-run / --confirmed），
#   且必须 grep '"need_confirm":true'：
#   dry-run 会提前 return，输出里字段名还在但值是 false。
#   只 grep 字段名 → 断言永远通过 → 等于没有断言（我自己踩过）。
ROUTE_OUT="$(./route.sh "给张三发微信:你好" 2>&1 >/dev/null)"
# 新策略：默认不拦路（need_confirm:false），但必须**回读**出收件人和内容
if grep -q "收件人：张三" <<< "$ROUTE_OUT" \
   && grep -q "内容：" <<< "$ROUTE_OUT"; then
  t_ok "发微信前回读收件人+内容（不再二次询问，符合用户定稿）"
else
  t_fail "发微信未标记需确认：$ROUTE_OUT"
fi

# 13.4 转交时状态提示必须指向 WorkBuddy，不能再指向已删除的橙色区
if grep -q "见上方橙色区域" "$DIR/flash.swift" 2>/dev/null; then
  t_fail "状态提示还写着「见上方橙色区域」—— 那个区域已经不存在了"
else
  t_ok "状态提示不再指向已删除的橙色区"
fi

# 13.5 队列执行链路（底层能力，v3 面板不再用，但 WorkBuddy 侧仍依赖）
# ⚠ 这条链路断过一次：answer() 只写文件+删 pending，没有任何代码跑 job.script。
#   用户点「确认执行」→ 文件消失 → 消息永远发不出去，且全程零报错。
#   界面上的按钮没法进 CI，所以 flash 提供 --selftest-confirm 无 UI 验证入口。
SC_CONFIRM="$("$DIR/flash" --selftest-confirm 2>&1 | tail -1)"
if grep -q "SELFTEST_PASS" <<< "$SC_CONFIRM"; then
  t_ok "队列执行链路完好：确认后真的带参执行了脚本"
else
  t_fail "队列执行链路断了：$SC_CONFIRM"
fi

# 13.6 Args 不能把「值以 -- 开头」的列表参数判成新 flag
# ⚠ 曾把 "--to,张三,--msg,你好" 整个丢弃 → args=[] → 脚本空跑。
#   这类 bug 只在真发微信时才暴露，且表现为"什么都没发生"，最难查。
AT="$("$DIR/flash" queue add --id "st_args_$$" --title T --detail D \
      --script /bin/echo --args "--to,张三,--msg,你好" --risk R 2>/dev/null)"
AT_LIST="$("$DIR/flash" queue list 2>/dev/null)"
rm -f "$SKILL_DIR/queue/pending/st_args_$$.json" 2>/dev/null
if grep -q '"--msg"' <<< "$AT_LIST"  && grep -q '张三' <<< "$AT_LIST" ; then
  t_ok "队列参数解析：以 -- 开头的列表值不会丢"
else
  t_fail "队列参数丢了（Args 把 --to,张三 误判为 flag）"
fi

# 13.7 静音语法必须是 volume --mute toggle（底层能力层）
# ⚠ 传 --toggle-mute 时 macctl 只打印状态、**不切换、也不报错** ——
#   按钮看起来"点了没反应"。这类静默失败最难查。
# ⚠ 不用 `macctl volume --help` 判断能力是否存在 —— macctl 不支持 --help，
#   它会把 --help 当成待执行参数。这里直接实测语法是否真的切换。
# ⚠ v5 起面板**不再有任何音量 UI**（用户明确要求移除），所以这条只验底层
#   语法：保留能力 ≠ 保留界面。以后若用户要恢复音量，这里能立刻验出语法对不对。
VOL_BEFORE="$("$DIR/macctl" volume 2>/dev/null | grep -o '静音=[a-z]*' | head -1)"
"$DIR/macctl" volume --mute toggle >/dev/null 2>&1
VOL_AFTER="$("$DIR/macctl" volume 2>/dev/null | grep -o '静音=[a-z]*' | head -1)"
"$DIR/macctl" volume --mute toggle >/dev/null 2>&1   # 还原
if [ -n "$VOL_BEFORE" ] && [ "$VOL_BEFORE" != "$VOL_AFTER" ]; then
  t_ok "macctl 静音语法正确（--mute toggle，实测可切换）"
else
  t_fail "macctl volume --mute toggle 没有真的切换（${VOL_BEFORE} → ${VOL_AFTER}）"
fi

# 13.8 速记动作的成功判定不能是恒真
# ⚠ 原实现 `s.isEmpty ? "✅" : "✅"` 三元两边一样 → 命令没执行也显示"已完成"，
#   用户会误以为设好了。静默的假成功比报错更有害。
#
# ⚠⚠ 断言方式改了（D-022）：原来 grep 字面量 `s.isEmpty ? "❌`，
#   而 v4 重写quickAction 后变量名和判定结构都变了 → 字面量不存在 → 断言恒失败，
#   变成「测一个已经改掉的实现」。现在验证的是**实质**：
#   代码里必须存在明确的失败判据（ok:false / ❌），而不是无条件报成功。
if grep -q 'ok.*:.*false' flash.swift && grep -q '❌' flash.swift; then
  t_ok "速记动作有明确失败判据（不恒报成功）"
else
  t_fail "速记动作仍是恒真判定 —— 命令没执行也显示已完成"
fi

# 13.9 队列目录不能有残留测试数据
if [ -z "$(ls -A "$SKILL_DIR/queue/pending" 2>/dev/null)" ]; then
  t_ok "确认队列干净（无残留待确认项）"
else
  t_fail "确认队列有残留文件：$(ls "$SKILL_DIR/queue/pending" 2>/dev/null | tr '\n' ' ')"
fi

# 13.10 口语化兜底层必须真的接住日常说法
# ⚠ 用户实测反馈：「一定要固定格式，超出格式就无法解析」。
#   只靠加固定句式是打地鼠——所以要有兜底层，且必须用**口语**验，验的
#   必须是路由器的真实输出，不能只看代码里有没有那个分支。
route_dry() { "$DIR/route.sh" --dry-run "$1" 2>&1 | grep -E "^动作:" | head -1; }

check_route() { # check_route <说法> <期望包含的关键词>
  local got; got="$(route_dry "$1")"
  if grep -q "$2" <<< "$got"; then
    t_ok "口语识别：「$1」"
  else
    t_fail "口语识别失败：「$1」（得到=${got:-未命中}）"
  fi
}

check_route "帮我把音量调到30"  "30"
check_route "来一首晴天"        "晴天"
check_route "把声音关了"        "静音"
# ⚠ 否定式方向必须对：「取消静音」若被「静音」抢先匹配，会变成「静音」——
#   用户说要取消、闪控给静音，方向完全相反且毫无提示。这条必须单独测。
if [ "$(route_dry '取消静音')" = "动作: 取消静音" ]; then
  t_ok "口语识别：「取消静音」方向正确（没被当成静音）"
else
  t_fail "「取消静音」被误判成「静音」—— 方向反了（得到=$(route_dry '取消静音')）"
fi
check_route "桌面有什么"        "桌面"

# 13.11 认不出的句子必须诚实失败（不能为了「什么都听懂」而瞎猜）
# ⚠ 兜底层的诱惑是「加更多关键词」，但猜错的方向是**发错消息/点错按钮**，
#   代价远高于「没听懂」。所以必须锁死这条底线。
if [ -z "$(route_dry '帮我写一篇年度总结报告')" ]; then
  t_ok "听不懂时诚实失败（复杂任务不瞎猜）"
else
  t_fail "复杂任务被瞎猜成了某个动作 —— 猜错代价是发错消息"
fi

# ── 14. D-022 回归：「打开X」必须走应用，不能退化成搜文件 ──────
say "--- 14. D-022 回归 ---"

# 14.1 ⚠⚠ 本次最核心的回归点：
#   「打开微信」曾被路由到 open_file.sh → 去磁盘搜"微信" → 搜出 40 个文件
#   → 报 AMBIGUOUS。用户看到的是「有 40 个匹配微信的文件」，完全摸不着头脑。
#   断言必须验证**动作类型**，不是「能不能打开」——两条路都能"打开"。
OPEN_WX="$(./route.sh --dry-run "打开微信" 2>&1)"
if grep -q "app_open" <<< "$OPEN_WX"; then
  t_ok "「打开微信」路由到应用（app_open），不是文件搜索"
elif grep -q "open_file.sh" <<< "$OPEN_WX"; then
  t_fail "「打开微信」又被路由成打开文件 —— D-022 回归"
else
  t_fail "「打开微信」既没走应用也没走文件：$OPEN_WX"
fi

# 14.2 「打开X」要能在多种口语说法下都命中应用
OPEN_OK=0
for s in "打开计算器" "启动一下豆包" "帮我打开WPS" "运行浏览器" "打开备忘录"; do
  printf '%s' "$(./route.sh --dry-run "$s" 2>&1)" | grep -q "app_open" && OPEN_OK=$((OPEN_OK+1))
done
if [ "$OPEN_OK" -ge 4 ]; then
  t_ok "「打开X」口语覆盖：5种说法里 $OPEN_OK 种命中应用"
else
  t_fail "「打开X」口语覆盖不足（5 种里只 $OPEN_OK 种）"
fi

# 14.3 带扩展名的必须仍走文件（不能为了修应用把开文件弄坏）
PDF_OUT="$(./route.sh --dry-run "打开报告.pdf" 2>&1)"
if grep -q "open_file.sh" <<< "$PDF_OUT"; then
  t_ok "「打开X.pdf」仍走文件路径（应用优先不能反噬文件）"
else
  t_fail "「打开X.pdf」不再走文件 —— 修应用时把开文件弄坏了"
fi

# 14.4 中文别名必须能解析（磁盘上是英文名）
#  ⚠ 这是「打开计算器」失败的真实原因：/System/Applications/Calculator.app
#
#  ⚠⚠ 两个必须做对的细节，否则断言恒失败（我自己踩过）：
#   ① `for n in 计算器豆包` 是**单个字符串**「计算器豆包」，不是两个元素。
#      无空格分隔时 bash 不分词 → 解析必然失败 → 断言永远红。
#   ② `launch` 会**真的启动应用**，测试 4 个会连开 4 个 App。
#      所以这里只验证「能否解析到 bundle id」，用 --dry-run 风格的只读查询。
ALIAS_OK=0
for n in 计算器 豆包 浏览器 备忘录; do
  "$MACCTL" launch --name "$n" --json 2>/dev/null | grep -q '"ok":true' && ALIAS_OK=$((ALIAS_OK+1))
done
if [ "$ALIAS_OK" -ge 4 ]; then
  t_ok "中文应用名解析：4 个里$ALIAS_OK 个能启动（计算器↔Calculator 等）"
else
  t_fail "中文应用名解析失败（4 个里只 $ALIAS_OK 个）"
fi

# 14.5 面板不该再有音量 UI
# ⚠ 用户明确要求：「不需要保留任何和音量有关的」。
#   断言防的是「以后又有人觉得音量方便，加回来」。
if grep -qE "volumeSlider|volumeLabel|muteButton|volStep|refreshVolume" "$DIR/flash.swift" 2>/dev/null; then
  t_fail "面板里又出现音量 UI（用户已明确要求移除）"
else
  t_ok "面板无音量 UI"
fi

# 14.6 面板只应有一个输入框（用户：不要单独开复杂任务填写栏）
# ⚠⚠ 原来这里grep 的是 `'NSTextField(frame: NSRect(x: 36'` ——
#   把**布局坐标**当身份标识。v5 一改坐标，断言就红，而面板其实是对的。
#   这类断言比没有断言更糟：它会把「改对了」报成「改坏了」。
#   现在按语义计数：`freeInput = NSTextField(` 是唯一的可编辑输入框，
#   且它必须挂在 fieldShell（输入框外壳）上 —— 后者顺带防住了
#   「子视图误用绝对坐标导致整体右移」这个已经踩过的坑。
IN_N="$(grep -c 'freeInput = NSTextField(' "$FLASH_SRC" 2>/dev/null || echo 0)"
IN_IN_SHELL="$(grep -c 'fieldShell.addSubview(freeInput)' "$FLASH_SRC" 2>/dev/null || echo 0)"
if [ "$IN_N" -eq 1 ] && [ "$IN_IN_SHELL" -eq 1 ]; then
  t_ok "面板只有一个输入框，且挂在输入外壳上（复杂任务靠自动识别，不另开填写栏）"
else
  t_fail "输入框数量/挂载异常：freeInput 声明=${IN_N} 挂到外壳=${IN_IN_SHELL}（应各为 1）"
fi

# 14.7 录屏必须有状态管理脚本
# ⚠ 录屏是「开始/停止」二态，单条 macctl 命令做不到；
#   而且踩过「kill -0 判活不可信」「输出路径每次重算」两个坑。
if [ -x "$DIR/screen_rec.sh" ] && grep -q "OUT_FILE_FILE" "$DIR/screen_rec.sh"; then
  t_ok "录屏脚本存在且输出路径已持久化（避免状态判错）"
else
  t_fail "screen_rec.sh 缺失或未持久化输出路径"
fi

# 14.8 录屏路由要能开关
REC_OUT="$(./route.sh --dry-run "录屏" 2>&1)"
STOP_OUT="$(./route.sh --dry-run "停止录屏" 2>&1)"
if grep -q "screen_rec" <<< "$REC_OUT" \
   && grep -q "screen_rec" <<< "$STOP_OUT"; then
  t_ok "录屏路由：开始/停止都能识别"
else
  t_fail "录屏路由缺失"
fi

# 14.9 缺参 preflight：不把缺参变成工具层失败
PRE1="$(./route.sh --dry-run "给张三发微信" 2>&1)"
PRE2="$(./route.sh --dry-run "打开文件" 2>&1)"
if grep -q '"error_code":"AMBIGUOUS"' <<< "$PRE1"  \
   && grep -q '"error_code":"AMBIGUOUS"' <<< "$PRE2" ; then
  t_ok "缺参 preflight：发微信/打开文件缺参时给 AMBIGUOUS + hint"
else
  t_fail "缺参 preflight 缺失或没有 hint"
fi

# 14.10 路由抢道回归：复合「截图」任务不是截屏
COMPOSITE="$(./route.sh --dry-run "把两张截图拼起来" 2>&1)"
if grep -q '"chain":"workbuddy"' <<< "$COMPOSITE" ; then
  t_ok "路由抢道回归：「把两张截图拼起来」交给 W6，不误判成截屏"
else
  t_fail "路由抢道回归：复合截图任务仍被截屏规则吃掉"
fi

# ── 15. D-023 回归：面板排版/ 媒体目录 / iKuuuVPN ─────────────────
say ""
say "--- 15. D-023 回归（UI 排版 · 媒体目录 · iKuuuVPN）---"

# 15.1 几何自检必须真的能跑，而且必须通过
#  ⚠ 这是「排版超格」的根治装置：v2~v4 的窗口高度是手写常数、内容是累加的，
#    两者不一致时没有任何东西会发现 —— 于是一路发布到用户面前。
#    现在 `flash --layout-check` 会递归校验每个子视图是否越界、按钮文字是否放不下。
if "$DIR/flash" --layout-check >/tmp/flash_layout.txt 2>&1; then
  t_ok "面板几何自检通过：$(head -1 /tmp/flash_layout.txt)"
else
  t_fail "面板几何自检失败（控件越界/文字溢出/区块高度不吻合）：$(head -3 /tmp/flash_layout.txt | tr '\n' ' ')"
fi

# 15.2 自检必须真的有检查能力 —— 注入一个**真实会越界**的故障
# ⚠ 只断言「退出码为 0」是不够的：万一它只是永远返回 0，等于没检查。
#
# ⚠⚠ 注入什么，是这里最容易踩空的地方（我自己踩了）：
#   第一版注入 `tileH 46 → 200`，结果自检照样返回通过 —— 因为
#   **gridH 是从 tileH 算出来的**，改一个另一个跟着变，布局仍然自洽，
#   自检说"通过"是完全正确的。这不是自检失灵，是我的注入选错了故障模式：
#   它模拟的是「布局算式健康」，不是「超格」。
#   真正的超格 = 有个尺寸被改成常数、或加了内容却没让算式知道。
#   所以这里注入的是**把 window 高度改成手写小常数**（模拟 v2~v4 的
#   `let H: CGFloat = 328`）—— 内容不变、窗口变小，底部必然被裁掉。
if [ -f "$FLASH_SRC" ]; then
  BADBIN="$(mktemp -t flash_bad_XXXXXX)"
  rm -f "$BADBIN"
  cp "$FLASH_SRC" /tmp/flash_bad_ui.swift
  /usr/bin/python3 - <<'PY'
import io
p='/tmp/flash_bad_ui.swift'
s=io.open(p,encoding='utf-8').read()
# ⚠ 别再按字面量锚定 Layout.H：算式加一项（startH）注入就静默失效，
#   而失效的表现是「坏版其实没坏 → 断言报通过」，最危险的一种假绿。
#   用正则吃掉整条算式（含续行的 + xxx），换成常数。
import re as _re
pat = _re.compile(r"static let H: CGFloat =[^\n]*(?:\n\s*\+[^\n]*)*")
s, n = pat.subn("static let H: CGFloat = 300", s)
assert n == 1, "Layout.H 注入失败：没匹配到算式（n=%d）" % n
io.open(p,'w',encoding='utf-8').write(s)
PY
  # 复用 build_flash.sh 的拼接逻辑：flashkit + Args + （被改坏的）flash
  #  ⚠⚠ 拼接的文件清单必须与 build_flash.sh **完全一致**。
  #     早期这里硬编码了三个文件（flashkit + Args + flash），
  #     后来 flash_archive.swift（档案风视图）被加进编译链，
  #     这条断言没跟着改 → 拼出来的程序缺了 ArchiveBackground 等类型 →
  #     **编译失败** → 反证测试直接失效（它会报"编译失败"而不是"抓到了越界"）。
  #     这是"测试自己坏了但看起来像测试通过"的典型：断言字符串还在，
  #     实际什么都没验证。
  #     现在：用 Python 从 build_flash.sh 里**解析**出拼接顺序，
  #     再把被改坏的 flash.swift 换进去 —— 不手写清单，也不用 shell 管道
  #     （`while read` 在子 shell 里，bash 3.2 上变量出不来）。
  /usr/bin/python3 - "$DIR" <<'PYSPLICE'
import io, re, sys, os
d = sys.argv[1]
build = io.open(os.path.join(d, "build_flash.sh"), encoding="utf-8").read()
# 取出拼接行里所有 cat 的 .swift 路径（保持出现顺序）
# ⚠ 正则必须兼容**带引号和不带引号**两种写法：
#     build_flash.sh 里 flashkit/flash_archive/flash 都是 cat "$DIR/xxx.swift"，
#     而 Args 是 cat /tmp/flash_args.swift（无引号）。
#     早期只匹配带引号的写法 → Args 没被拼进去 → 编译报
#     "cannot find type 'Args' in scope" → 反证测试直接失效。
files = re.findall(r'cat\s+"?([^"\s]+\.swift)"?', build)
if not files:
    sys.stderr.write("FAIL: build_flash.sh 里没解析到拼接文件\n")
    sys.exit(1)
macctl = io.open(os.path.join(d, "macctl.swift"), encoding="utf-8").read()
m = re.search(r"^struct Args \{.*?^\}\n", macctl, re.M | re.S)
args_src = m.group(0) if m else ""
out = []
for f in files:
    f = f.replace("$DIR", d)
    if f.endswith("/flash.swift"):
        out.append(io.open("/tmp/flash_bad_ui.swift", encoding="utf-8").read())
    elif "flash_args" in f:
        out.append(args_src)
    else:
        out.append(io.open(f, encoding="utf-8").read())
io.open("/tmp/flash_bad_all.swift", "w", encoding="utf-8").write("\n".join(out) + "\n")
PYSPLICE
  if /usr/bin/swiftc -O -o "$BADBIN" /tmp/flash_bad_all.swift >/dev/null 2>&1; then
    if "$BADBIN" --layout-check >/tmp/flash_bad_out.txt 2>&1; then
      t_fail "几何自检形同虚设：窗口被压到 300pt（内容 504pt）仍返回通过"
    else
      t_ok "几何自检确实能抓越界（窗口压到 300pt 被拦下：$(head -2 /tmp/flash_bad_out.txt | tail -1 | sed 's/^ *//')）"
    fi
  else
    t_fail "注入超界布局后 flash 编译失败，几何自检无法验证"
  fi
  rm -f "$BADBIN" /tmp/flash_bad_ui.swift /tmp/flash_bad_all.swift /tmp/flash_bad_args.swift
else
  t_fail "找不到 flash.swift 源文件，跳过自检有效性反证"
fi

# 15.3 窗口高度必须由算式得出，不能是手写常数
#  ⚠ 手写 H = 328 就是「超格」的直接成因。加一个常量后必须同步改算式，
#    这条断言专门挡那种「加了东西但没改 H」。
if grep -A3 'static let H: CGFloat' "$FLASH_SRC" | grep -q 'topInset'; then
  t_ok "窗口高度由 Layout 算式累加得出（不是手写常数）"
else
  t_fail "窗口高度看起来是手写常数 —— 这会让新增区块必然溢出"
fi

# 15.4 常用区第 12 格必须是 iKuuuVPN，不能是桌面
if grep -q 'Action(title: "iKuuuVPN"' "$FLASH_SRC"; then
  t_ok "常用操作第 12 格是 iKuuuVPN（用户要求替换掉桌面按钮）"
else
  t_fail "常用操作里没有 iKuuuVPN 按钮"
fi
if grep -q 'Action(title: "桌面"' "$FLASH_SRC"; then
  t_fail "「桌面」按钮还在（用户已要求换成 iKuuuVPN）"
else
  t_ok "「桌面」按钮已移除"
fi

# 15.5 iKuuuVPN 的口语别名必须能解析到应用
#  ⚠ 断言要真的查解析结果，不能只 grep 别名表 ——
#    磁盘上叫 iKuuuVPN，用户嘴里说的是「VPN」「加速器」，映射错了就没用。
VPN_OK=0
for n in iKuuuVPN VPN 加速器; do
  "$MACCTL" launch --name "$n" --json 2>/dev/null | grep -q '"ok":true' && VPN_OK=$((VPN_OK+1))
done
if [ "$VPN_OK" -ge 3 ]; then
  t_ok "iKuuuVPN 别名解析：iKuuuVPN / VPN / 加速器 都能定位到应用"
else
  t_fail "iKuuuVPN 别名解析只过了 $VPN_OK/3"
fi

# 15.6 截图/录屏必须**分家**，各自按 年/月 归档（P10 目录结构）
#  ⚠ 用户原话：「截图和录屏的文件我并不清楚会放在哪个位置」。
#    后来真做到了"同一目录"，结果 228 个文件平铺在根下 —— 一条 ls 滚半天，
#    **还是找不到**。所以 P10 定稿：目录即索引
#      <根>/截图/2026/10/20261025-102538.png
#      <根>/录屏/2026/10/20261025-095757.mov
#  断言四件事（任何一条回退都要红）：
#    ① 面板路径（macctl）: 截图→<根>/截图，录屏→<根>/录屏
#    ② 目录算式带 年(4位)/月(2位补零) —— 月不补零会 10 排到 1 前面
#    ③ 另外两个执行器（screen_rec.sh 录屏 / mediacap.sh 截图）同样带 年/月
#    ④ 反向断言：根目录下不许再落文件（旧写法 out="$ROOT/$STAMP.png" 必须绝迹）
SHOT_DIR_OK=0
grep -qF 'let MEDIA_ROOT = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Desktop/灵台智枢"' "$MACCTL_SRC" && SHOT_DIR_OK=$((SHOT_DIR_OK+1))
grep -qF 'let MEDIA_DIR = "\(MEDIA_ROOT)/截图"' "$MACCTL_SRC" && SHOT_DIR_OK=$((SHOT_DIR_OK+1))
grep -qF 'let REC_DIR   = "\(MEDIA_ROOT)/录屏"' "$MACCTL_SRC" && SHOT_DIR_OK=$((SHOT_DIR_OK+1))
# ② 年/月结构：%@/%04d/%02d（4 位年 + 2 位补零月）
grep -qF 'String(format: "%@/%04d/%02d"' "$MACCTL_SRC" && SHOT_DIR_OK=$((SHOT_DIR_OK+1))
# ③ 两个 shell 执行器：目录按当下时间算（不是脚本级固定值）
grep -qF 'MEDIA_DIR="$HOME/Desktop/灵台智枢/录屏"' screen_rec.sh && SHOT_DIR_OK=$((SHOT_DIR_OK+1))
grep -qF 'REC_DIR_CUR="$MEDIA_DIR/$(date +%Y)/$(date +%m)"' screen_rec.sh && SHOT_DIR_OK=$((SHOT_DIR_OK+1))
grep -qF 'SHOT_DIR="$ROOT/截图/$(date +%Y)/$(date +%m)"' mediacap.sh && SHOT_DIR_OK=$((SHOT_DIR_OK+1))
grep -qF 'REC_DIR="$ROOT/录屏/$(date +%Y)/$(date +%m)"' mediacap.sh && SHOT_DIR_OK=$((SHOT_DIR_OK+1))
# ④ 反向断言：还有谁往根下写？（一旦回退，前面全绿也没意义）
REGRESS=""
grep -qE 'out="\$ROOT/\$STAMP' mediacap.sh && REGRESS="mediacap.sh 仍往根下写"
grep -qE '^MEDIA_DIR="\$HOME/Desktop/灵台智枢"$' screen_rec.sh && REGRESS="$REGRESS screen_rec.sh 仍指向根"
if [ -z "$REGRESS" ] && [ "$SHOT_DIR_OK" -eq 8 ]; then
  t_ok "截图/录屏已分家且按 年/月 归档（截图→截图/年/月，录屏→录屏/年/月，根下无文件）"
else
  t_fail "媒体目录结构不对（$SHOT_DIR_OK/8 处匹配${REGRESS:+，回退：$REGRESS}）—— 应为 截图/年/月 与 录屏/年/月"
fi

# 15.7 文件名统一 yyyyMMdd-HHmmss（月日时分秒必须补零，否则排序 ≠ 时间序）
# ⚠ 「方便我搜索」这句话的技术含义就是排序。不补零的话
#   「20260203-...」会排在「20261201-...」后面。
#   三个执行器必须同一格式 —— 口径漂移会让「按名字排序」时断时续。
STAMP_OK=0
grep -qF 'yyyyMMdd-HHmmss' "$MACCTL_SRC" && STAMP_OK=$((STAMP_OK+1))
grep -qF 'date "+%Y%m%d-%H%M%S"' screen_rec.sh && STAMP_OK=$((STAMP_OK+1))
grep -qF 'STAMP="$(date +%Y%m%d-%H%M%S)"' mediacap.sh && STAMP_OK=$((STAMP_OK+1))
# 文件名必须**只剩**时间戳（不带「截图-」中文前缀，否则每类前缀不同就排不到一起）
grep -qF 'return "\(dir)/\(mediaStamp()).\(ext)"' "$MACCTL_SRC" && STAMP_OK=$((STAMP_OK+1))
if [ "$STAMP_OK" -eq 4 ]; then
  t_ok "截图/录屏文件名统一 yyyyMMdd-HHmmss（月日时分秒补零，排序 == 时间序）"
else
  t_fail "文件名格式不统一（$STAMP_OK/4 处匹配）—— 应为 yyyyMMdd-HHmmss，且不带中文前缀"
fi

# 15.8 面板必须常驻显示媒体目录位置
#⚠ 用户「不知道文件在哪」有两层：存哪了 + 界面没告诉他。
#   只改存储不改提示，等于只解决一半。
if grep -q 'mediaDirShort' "$FLASH_SRC"; then
  t_ok "面板常驻显示截图/录屏的存放位置"
else
  t_fail "面板没有显示媒体目录位置，用户还是不知道文件在哪"
fi

# 15.9 界面不得出现音量相关内容（沿用 14.5 的口径，防回归）
if grep -qE 'volumeSlider|volumeLabel|muteButton|"volume"' "$FLASH_SRC" 2>/dev/null; then
  t_fail "面板里又出现音量相关内容"
else
  t_ok "面板无音量相关 UI / 菜单项"
fi

# 16. route.sh 的 stdout 契约：「首行必须恒为 JSON」（D-024）
#
# ⚠⚠ 这组断言是为了防一个**已经真实发生过**的故障：
#
#   D-024：route.sh 的 app_open 分支把 macctl launch 的 JSON 丢进 grep
#   只做判断，判断完就 exit 0 → **stdout 是 0 字节**。
#   面板 runScript 判定 NO_OUTPUT → 报「脚本无输出」。
#   而实际上**微信早就被打开了** —— 事情做成了，界面说失败。
#
#   同期还有第二类：shot / volume / doctor / overview 分支直接吐人类可读文本
#   （「已保存 /path/xx.png」），首行不是 JSON → 面板走不到任何解析分支。
#
#   面板的 summarize() **只认 stdout 首行的 JSON**。这条契约一旦破坏，
#   所有调用方（面板 / WorkBuddy / 自检）一起瞎掉，而且**不报错**——只是显示怪。
#
#   所以这里断言的不是「某个命令能跑」，而是**契约本身**。

# 16.1 每条路由的首行必须是合法 JSON
#   ⚠ 不能只 grep '^{' —— 那会放过 `{"a":1,}` 这种坏 JSON。
#     用 Python json.loads 真解析。
JSON_FIRST_OK=0
JSON_TOTAL=0
for Q in "打开微信" "打开计算器" "截图" "音量30" "静音" "桌面上有什么" "闪控帮助"; do
  JSON_TOTAL=$((JSON_TOTAL+1))
  L="$(bash "$DIR/route.sh" "$Q" 2>/dev/null | head -1)"
  if printf '%s' "$L" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
    JSON_FIRST_OK=$((JSON_FIRST_OK+1))
  else
    say "  ⚠️ 契约破坏: \"$Q\" 首行不是合法 JSON → ${L:0:60}"
  fi
done
if [ "$JSON_FIRST_OK" -eq "$JSON_TOTAL" ]; then
  t_ok "route.sh 首行恒为合法 JSON（$JSON_FIRST_OK/$JSON_TOTAL 条路由）"
else
  t_fail "route.sh 有 $((JSON_TOTAL-JSON_FIRST_OK)) 条路由违反「首行恒为 JSON」契约"
fi

# 16.2 「打开应用」这条最常用的路径不能是 0 字节
#   ⚠ 这是 D-024 的原始现场。单独拎出来断言，因为它是用户最高频的操作。
OPEN_OUT="$(bash "$DIR/route.sh" "打开微信" 2>/dev/null)"
OPEN_LEN="${#OPEN_OUT}"
if [ "$OPEN_LEN" -gt 50 ] && printf '%s' "$OPEN_OUT" | head -1 | grep -q '"ok":true'; then
  t_ok "「打开微信」有实质输出且 ok:true（${OPEN_LEN} 字节，非静默）"
else
  t_fail "「打开微信」输出 ${OPEN_LEN} 字节 —— 静默失败回归了（D-024）"
fi

# 16.3 复杂任务必须**明确**标为未命中，面板才能识别为「转交」
#   ⚠ 这里断言的是「区分得开」：未命中路由表 vs 执行失败，
#     两者都是 ELEMENT_NOT_FOUND，混在一起会让真故障被当成复杂任务而丢失诊断。
UNMATCH="$(bash "$DIR/route.sh" "帮我写篇年度总结" 2>/dev/null | head -1)"
if grep -q '"ok":false' <<< "$UNMATCH"  && grep -q '未命中路由表' <<< "$UNMATCH" ; then
  t_ok "复杂任务被明确标记为「未命中路由表」（与执行失败可区分）"
else
  t_fail "复杂任务没有明确标记，面板无法区分「听不懂」和「执行失败」"
fi

# 16.4 面板不得把空输出报成「完成」（假成功）
#   ⚠ 假成功比报错更坏：报错会让人去查，假成功会让人以为系统坏了而放弃。
#
#   ⚠⚠ 断言必须锚在**可执行代码**上，不能 grep 字面串：
#     D-024 的注释里就写着 `return Reply(message: lines.last ?? "完成", ...)`
#     这段「历史说明」被 grep 命中 → 断言变红，但代码其实是对的。
#     **断言锚在会被正常修改的表面特征上 = 把「改对了」报成「改坏了」。**
#     修法：先剥掉注释行，只在真实代码里找。
FLASH_CODE="$(grep -v '^[[:space:]]*//' "$FLASH_SRC")"
FLASH_ARCH_CODE="$(grep -v '^[[:space:]]*//' "$FLASH_ARCH")"
if grep -q 'lines.last ?? "完成"' <<< "$FLASH_CODE" ; then
  t_fail "面板仍会把无法解析的结果显示成「完成」—— 假成功（可执行代码里还在）"
elif grep -q '闪控没拿到结果' <<< "$FLASH_CODE" ; then
  t_ok "面板不把无法解析的输出报成「完成」（空输出 → 诚实报错 + 转交）"
else
  t_fail "面板缺少「空输出」的显式处理"
fi

# 16.4b 空闲不抢鼠标：失焦必须停动画/自检，且不再设置光标
#   只降 layer 不够；globeTimer 0.06s 一直重绘 + NSCursor 会让人感觉鼠标被抢。
if grep -q 'func windowDidResignKey' <<< "$FLASH_CODE"  \
   && grep -q 'self.stopGlobe()' "$FLASH_SRC" \
   && ! grep -q 'NSCursor' <<< "$FLASH_ARCH_CODE" ; then
  t_ok "面板空闲不抢鼠标（失焦停动画，不设光标；自检可继续）"
else
  t_fail "面板空闲仍可能抢鼠标（失焦未停动画，或仍有 NSCursor）"
fi

# 16.4c 面板自检不得调用会移动鼠标的 doctor
#   doctor 会移动光标 3 次做输入探测；自检必须是只读的。
if ! grep -q 'probe(\["doctor"' "$DIR/flash_archive.swift" \
   && grep -q 'AXIsProcessTrusted' "$DIR/flash_archive.swift"; then
  t_ok "面板自检不调用 doctor（不会移动鼠标）"
else
  t_fail "面板自检仍调用 doctor，可能移动鼠标"
fi

# 16.5 route.sh 不得有「判断完就 exit」导致输出被吞的写法
#   ⚠ 这是 D-024 的**结构性**根因：把命令输出丢进管道做判断，
#     却只保留判断结果、丢掉输出本身。这类写法在别的脚本里也可能出现。
#
#   ⚠⚠ 同样必须剥掉注释再查 —— 修好之后把旧写法写进注释里说明，
#     就会让这条断言永远变红，变成「制造噪声的假警报」。
#     噪声型断言的代价：人会开始无脑忽略它，于是真问题也被忽略。
#   ⚠ 正则写法太脆：`if ... | grep -q ...; then` + 换行 + `exit 0`
#     匹配不到（中间隔着换行和缩进），会漏报。
#     改用**语义判断**：找「命令输出被丢进管道做判断」且「该分支没有 emit」。
#     判据：管道里出现 grep -q 的那一行，往后 3 行内如果有 exit 0 且没有 emit → 危险。
#   ⚠ 实现要点（踩过一次坑）：
#     ① 正则写法太脆 —— `if ... | grep -q ...; then` + 换行 + `exit 0`
#        匹配不到（中间隔着换行和缩进），会漏报。必须按**行窗口**判断。
#     ② while 循环跑在**子 shell** 里 → 里面赋的变量出不来 → 循环外的判断永远为真。
#        所以循环体不能写变量，改成直接输出，循环外再 grep。
#        （这两个坑叠在一起，就是「断言写了但从来没红过」的典型成因。）
ROUTE_CODE="$(grep -v '^[[:space:]]*#' "$DIR/route.sh")"
# 找出所有「管道 + grep -q」的行号，逐个看其后 4 行内是否 exit 0 且无 emit
#   ⚠ bash 3.2 陷阱：`for LN in $HITS` 里 HITS 含换行会被当成**一个**元素，
#     导致 LN="102\n286"，算术表达式直接报错。
#     修法：用 tr 把换行转成空格，或用 while read 配进程替换。
#     （macOS 自带 bash 3.2，没有 mapfile；< <(...) 在 3.2 里虽然能用但 here-doc 更稳。）
HITS="$(printf '%s' "$ROUTE_CODE" | grep -nE '\|[[:space:]]*grep -q' | cut -d: -f1 | tr '\n' ' ')"
DANGER=""
for LN in $HITS; do
  W="$(printf '%s' "$ROUTE_CODE" | sed -n "${LN},$((LN+4))p")"
  if grep -q 'exit 0' <<< "$W"  && ! grep -q 'emit ' <<< "$W" ; then
    DANGER="$LN"
    break
  fi
done
if [ -n "$DANGER" ]; then
  t_fail "route.sh 第 $DANGER 行附近还有「输出丢进管道判断后直接 exit」的写法（会吞掉结果）"
else
  t_ok "route.sh 没有「判断与回显混用」的吞输出写法"
fi

# ── 17. 开场动画（bootanim）回归 ───────────────────────────────────
# 这一组锚的全是**"看起来没 bug、实际功能整个不工作"**的坑。
# 它们的共同特征：没有报错、没有异常、日志干干净净 —— 只是东西不出现。
# 所以只能靠断言把"该出现的东西"钉死，不能靠"有没有抛错"来判断。

BOOT_DIR="$DIR/bootanim"
BOOT_WEB="$BOOT_DIR/web"
BOOT_SPLASH="$BOOT_WEB/splash.js"
BOOT_LAUNCH="$BOOT_DIR/tools/wblaunch"

# 17.1 资源齐全
if [ -f "$BOOT_SPLASH" ] && [ -f "$BOOT_WEB/splash.css" ] && \
   [ -f "$BOOT_WEB/brand.js" ] && [ -f "$BOOT_WEB/index.html" ] && \
   [ -x "$BOOT_LAUNCH" ]; then
  t_ok "开场动画资源齐全（splash.js/css/brand.js/index.html + wblaunch）"
else
  t_fail "开场动画资源缺失（web/ 下四个文件或 wblaunch 可执行文件）"
fi

# 17.1b 第一幕主标识 = 立体折面五角星
#   这条经受过一次来回：中间换过黑洞（贴图 + WebGL），最后用户拍板换回五角星。
#   断言要钉住"当前版本到底是什么"，否则改了调用点页面照样跑、没人发现。
if grep -q "var star = svgStar('dsu-whale')" "$BOOT_SPLASH" \
   && ! grep -q 'svgBlackHole' "$BOOT_SPLASH" \
   && grep -q '.dsu-black .dsu-whale' "$BOOT_WEB/splash.css"; then
  t_ok "第一幕主标识是立体折面五角星（黑洞那套已完全移除）"
else
  t_fail "第一幕标识不是五角星 —— 调用点或样式被改回去了"
fi

# 17.1c 星形的 HUD 双环必须还在
#   五角星外面那圈虚线和四角准星是第一幕构图的一部分，删了不会报错，
#   只是"看起来空了一块"。
if grep -q 'dsu-orbit' "$BOOT_SPLASH" && grep -q 'dsu-orbit-spin' "$BOOT_WEB/splash.css"; then
  t_ok "第一幕 HUD 双环存在（外环 7s / 内环 4.5s 反向）"
else
  t_fail "第一幕 HUD 双环缺失 —— 星形会失去取景框"
fi

# 17.2 ⚠⚠ 光场句柄的声明顺序 —— 上游自带 bug，移植后表现为"背景一动不动"
#   上游 dsh-startup-screen 把 startField() 放在第 838 行、
#   `var fieldHandle = null` 放在第 1004 行。靠函数声明提升能调到函数，
#   但那时 fieldHandle 还是 undefined；随后第 1004 行的 `= null` 执行，
#   把 startField 内部刚赋好的对象重新抹掉。
#   结果：frame() 第一行 `if (!fieldHandle) return` 永远命中，光场只画 1 帧就死。
#   症状极隐蔽 —— 无异常、画面只是"背景不动"，极易被当成性能问题。
#
#   ⚠⚠⚠ 断言必须锚在**可执行代码**上，且行号必须来自**同一份文本**：
#     剥掉注释会重排行号，如果用「原文件行号」和「剥注释后行号」比较，
#     两者根本不是一回事 —— 断言会恒绿，把真 bug 放过去。
#     正解：先剥注释，剥完再用 grep -n 取行号，两边都来自剥后的文本。
#     （这跟 16.4/16.5 是同一条铁律的另一个变体：比对的两端必须同源。）
#   ⚠⚠⚠ 剥注释必须用 python 而不是 grep -v：
#     grep -v 只能剔「以 * 或 // 开头的行」，但 /* */ 块注释的**中间行**
#     （不以 * 开头）会活下来 —— 而那些行里往往正好写着
#     「var fieldHandle = null」这类代码示例，head -1 一抓就抓到注释行，
#     断言于是拿注释里的行号当真实行号 → 恒绿 → 真 bug 直接放过去。
#     （这个坑和 16.4/16.5 是同一条铁律的第三个变体。）
BOOT_CODE="$(python3 -c '
import io,re,sys
s=io.open(sys.argv[1],encoding="utf-8").read()
s=re.sub(r"/\*.*?\*/", "", s, flags=re.S)      # 整块 /* */
s=re.sub(r"^\s*//.*$", "", s, flags=re.M)         # 整行 //
s=re.sub(r"\s+//[^\n]*$", "", s, flags=re.M)      # 行尾 //
sys.stdout.write(s)
' "$BOOT_SPLASH" || true)"
BOOT_DECL_RAW="$(printf '%s' "$BOOT_CODE" | grep -n 'var fieldHandle' || true)"
# ⚠ 不能要求「startField() 独占一行」：实际代码是防重入的
#   `try { if (!fieldHandle) startField() } catch (e) {}` —— 同一行里带守卫，
#   按行首锚定就永远匹配不到，断言变假红（2026-10-23 踩到）。
BOOT_CALL_RAW="$(printf '%s' "$BOOT_CODE" | grep -nE '(^|[^A-Za-z_.])startField\(\)' | grep -vE 'function[[:space:]]+startField' | head -1 || true)"
DECL_LN=0
CALL_LN=0
if [ -n "$BOOT_DECL_RAW" ]; then
  DECL_LN="$(printf '%s' "$BOOT_DECL_RAW" | head -1 | cut -d: -f1)"
fi
if [ -n "$BOOT_CALL_RAW" ]; then
  CALL_LN="$(printf '%s' "$BOOT_CALL_RAW" | head -1 | cut -d: -f1)"
fi
DECL_LN="${DECL_LN:-0}"
CALL_LN="${CALL_LN:-0}"
if [ "$DECL_LN" -gt 0 ] && [ "$CALL_LN" -gt 0 ] && [ "$DECL_LN" -lt "$CALL_LN" ]; then
  t_ok "光场句柄声明在调用之前（剥注释后行 ${DECL_LN} < ${CALL_LN}）—— 上游 var 提升陷阱已避开"
else
  t_fail "光场句柄声明行(${DECL_LN})必须早于 startField() 调用行(${CALL_LN})，否则光场只画1帧就死"
fi

# 17.3 品牌替换彻底（不能残留 DeepSeek / 鲸鱼）
#   ⚠ 必须排除注释行：brand.js 的注释里有意写了「替代原项目的 DeepSeek 鲸鱼剪影」
#     作为溯源信息，那是**说明**不是**残留**。断言连注释一起查 = 自己把自己判红。
#   （和 16.4/16.5 同一条铁律：断言锚在会被正常修改的表面特征上。）
# 真正把块注释剥掉（/* … */ 可能跨行，且中间行不以 * 开头）——
# 只跳过 "* 开头" 的行会漏掉注释正文，把"说明"判成"残留"（2026-10-23 踩到）。
BOOT_BRAND_CODE="$(/usr/bin/python3 - "$BOOT_SPLASH" "$BOOT_WEB/splash.css" "$BOOT_WEB/brand.js" <<'PYEOF'
import re, sys
out = []
for f in sys.argv[1:]:
    try: src = open(f, encoding='utf-8').read()
    except OSError: continue
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)   # 块注释
    src = re.sub(r'(?m)^\s*//.*$', '', src)           # 行注释
    out.append(src)
print('\n'.join(out))
PYEOF
)"
if grep -qiE 'deepseek|深度求索' <<< "$BOOT_BRAND_CODE"; then
  t_fail "开场动画里还有 DeepSeek 相关名称没换成 WorkBuddy"
else
  t_ok "开场动画已无 DeepSeek 残留（注释里的溯源说明不计）"
fi

# 17.4 配置注入契约：必须是 __WB_BOOT_CONFIG__（不是上游的 __DSH_STARTUP__）
#   ⚠ 若配置注入失败，splash.js 会**静默退回 DEFAULTS**，
#     而 DEFAULTS.requireInteraction = true → 动画卡在第 1 步等按键，永不揭幕。
#   这是"最容易被忽略、后果最严重"的一条：画面正常但不结束。
if grep -q '__WB_BOOT_CONFIG__' "$BOOT_SPLASH"; then
  t_ok "配置注入点为 __WB_BOOT_CONFIG__（与启动器一致）"
else
  t_fail "splash.js 找不到 __WB_BOOT_CONFIG__，会退回 DEFAULTS（requireInteraction=true 会卡死不揭幕）"
fi

# 17.5 启动器的 probe 必须输出合法单行 JSON，且含运行状态字段
#   闪控靠这个字段决定播不播动画，字段缺失 = 永远走"已在运行"分支。
PROBE_OUT="$("$BOOT_LAUNCH" probe 2>/dev/null | head -1)"
if printf '%s' "$PROBE_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "workbuddyRunning" in d else 1)' 2>/dev/null; then
  t_ok "wblaunch probe 输出合法 JSON 且含 workbuddyRunning 字段"
else
  t_fail "wblaunch probe 输出不是含 workbuddyRunning 的合法 JSON（闪控会误判播放时机）"
fi

# 17.6 启动器不得在前台同步等待动画（会把灵台智枢卡死 15 秒）
#   灵台智枢是单线程跑脚本的；同步等待 = 界面无响应 = 用户以为闪控挂了。
#   断言：调用 wblaunch play 的那一行必须带 & / nohup。
#   ⚠ 别只 grep 'wblaunch'：实际命令是 "$BOOTLAUNCH" play，变量名在前。
#     所以要按行看「含 play 的行」是否同时含 & 或 nohup。
ROUTE_CODE2="$(grep -v '^[[:space:]]*#' "$DIR/route.sh")"
LAUNCH_LINE="$(printf '%s' "$ROUTE_CODE2" | grep -E 'BOOTLAUNCH.*play' | head -1 || true)"
if [ -z "$LAUNCH_LINE" ]; then
  t_ok "route.sh 不再在运行期调启动器（动画只在开机播，2026-10-25 用户拍板）"
else
  t_fail "route.sh 仍在运行期调 wblaunch —— 与「动画只在开机播」冲突"
fi

# 17.7 启动器必须处理"已在运行 → 不播"
#   这是用户明确要求的行为：WorkBuddy 已运行时重复播动画是噪音。
if grep -q 'isWorkBuddyRunning' "$BOOT_LAUNCH.swift"; then
  t_ok "启动器保留「已在运行不播」判定（手动 play 时仍有效）"
else
  t_fail "启动器缺少「已在运行不播」判定"
fi

# 17.8 启动器必须有兜底超时（动画脚本万一抛错，窗口不能永远挂着）
if grep -q 'armTimeout' "$BOOT_LAUNCH.swift"; then
  t_ok "启动器有兜底超时（动画异常时不会永远挂住窗口）"
else
  t_fail "启动器缺少兜底超时（动画脚本抛错 = 窗口永远不关）"
fi

# 17.9 揭幕信号必须用事件驱动，不能只盯 DOM 移除
#   finish() 里先 addClass('dsu-gone') 再延时 900ms 才 removeChild，
#   盯 root 消失会平白多等将近一秒。
if grep -q 'dsh-startup:done' "$BOOT_LAUNCH.swift"; then
  t_ok "揭幕信号用 dsh-startup:done 事件（不多等 900ms）"
else
  t_fail "启动器没用 dsh-startup:done 事件判定揭幕（会多等 900ms 或漏判）"
fi

# 17.10 路径规范化：WKWebView 对含 `..` 的 file URL 会**静默拒绝加载**
#   症状：窗口弹出来但永远黑屏，didFail / console / KVO 全部沉默。
#   tools/ → web/ 天然要往上走一级，这个坑几乎必然踩到。
if grep -q 'standardizedFileURL' "$BOOT_LAUNCH.swift"; then
  t_ok "启动器对 web 目录做了 URL 规范化（避开 WKWebView 静默拒绝 .. 路径）"
else
  t_fail "启动器未规范化 web 路径（WKWebView 会静默拒绝含 .. 的 file URL → 黑屏）"
fi

# 17.11 ⚠ 拉起 WorkBuddy 失败时**不得**弹系统级错误框
#   NSWorkspace.openApplication(at:) 在路径不存在时会弹一个系统模态框
#   「应用程序启动失败」—— 那个框会卡住用户桌面，而且用户根本不知道是哪个 app 失败。
#   自检时用假路径验证「未运行 → 播动画」路径必然踩到。
#   修法：先校验路径存在再用 openApplication，并挂 completion handler 吞掉错误。
if grep -q 'fileExists(atPath: WB_APP)' "$BOOT_LAUNCH.swift" \
   && grep -q 'openApplication' "$BOOT_LAUNCH.swift" \
   && grep -q '拉起失败' "$BOOT_LAUNCH.swift"; then
  t_ok "拉起失败时静默处理（不弹系统「应用程序启动失败」框）"
else
  t_fail "启动器拉起失败会弹系统错误框 —— 必须先校验路径 + 挂错误回调"
fi

# 17.12 boot 模式：开机自启动路径
#   WorkBuddy 自己用 SMAppService 注册登录项（sfltool dumpbtm 里能看到
#   2.com.tencent.workbuddy.mac），系统直接放行，**没有拦截点**。
#   所以不去抢「先启动」，而是注册自己的 LaunchAgent，让动画窗口
#   （.floating 层级）盖在 WorkBuddy 上面，播完再把 WorkBuddy 置前。
if [ -x "$DIR/bootctl.sh" ] && grep -q '"boot"' "$BOOT_LAUNCH.swift"; then
  t_ok "启动器有 boot 模式（开机自启动走独立路径）"
else
  t_fail "启动器缺 boot 模式（开机自启动无法触发动画）"
fi

# 17.13 bootctl.sh 必须存在且能写 LaunchAgent
if [ -f "$DIR/bootctl.sh" ] && bash -n "$DIR/bootctl.sh" 2>/dev/null; then
  t_ok "bootctl.sh 存在且语法正确（开机自启管理入口）"
else
  t_fail "bootctl.sh 缺失或语法错误（开机自启无法安装）"
fi

# 17.14 开机场景必须等锁屏解除
#   LaunchAgent 在登录时启动，用户很可能还没解锁。
#   锁屏下窗口看不见 —— 动画对着锁屏背板播 15 秒，解锁后只剩残影。
if grep -q 'isScreenLocked' "$BOOT_LAUNCH.swift" && grep -q 'waitForUnlockIfBoot' "$BOOT_LAUNCH.swift"; then
  t_ok "开机场景会等锁屏解除再播（不对着锁屏背板播）"
else
  t_fail "开机场景没有锁屏检测 —— 动画会对着锁屏背板播"
fi

# 17.15 开机场景必须等屏幕就绪
#   登录瞬间 GUI session 常常还没就绪，NSScreen.main 为 nil。
#   直接 exit(0) = 「开机该播的动画被静默跳过」，且日志里什么都看不到。
if grep -q '12 秒内拿不到屏幕' "$BOOT_LAUNCH.swift"; then
  t_ok "开机场景会等屏幕就绪（不会静默跳过动画）"
else
  t_fail "开机场景没有等屏幕就绪 —— 登录瞬间 NSScreen 为 nil 会静默跳过动画"
fi

# 17.16 boot 模式不得重复拉起 WorkBuddy
#   开机时 WorkBuddy 极可能已被系统拉起。重复 openApplication 不会开第二个实例，
#   但会抢焦点打断用户。已在跑就只置前。
if grep -q 'activateWorkBuddyIfRunning' "$BOOT_LAUNCH.swift"; then
  t_ok "boot 模式只置前不重复拉起 WorkBuddy（不抢焦点）"
else
  t_fail "boot 模式缺置前逻辑 —— 开机时可能重复拉起并抢焦点"
fi

# 17.17 灵台智枢必须是「工业档案画风」（色板 + 结构）
#   用户明确要求「色板和结构」都要改，不只是换配色。
#   断言锚在这套语言的四个不可省要素上：
#     ① 近黑纸底（不是蓝紫渐变）
#     ② 发丝级细线（不是亮边框）
#     ③ 单一青绿主色（不是彩虹渐变）
#     ④ 等宽字体做数据/编号
#   ⚠ 2026-10-22：右上角 logo 从「准星 ReticleView」换成「三维自转地球
#     GlobeView」（用户要求），断言锚点随之更新 —— 留着 ReticleView
#     会让这条测试永远失败，误导后来人。
FLASH_SW="$DIR/flash.swift"
FLASH_ARCH="$DIR/flash_archive.swift"
if [ -f "$FLASH_ARCH" ] \
   && grep -q 'ArchiveBackground' "$FLASH_SW" \
   && grep -q 'SelfCheckBar' "$FLASH_SW" \
   && grep -q 'GlobeView' "$FLASH_SW"; then
  t_ok "灵台智枢已改造成工业档案画风（档案底板 + 自检栏 + 三维地球）"
else
  t_fail "灵台智枢仍是旧的玻璃卡片风格（缺档案底板/自检栏/三维地球）"
fi

# 17.18 档案风色板：近黑底 + 青绿主色 + 发丝线
# 2026-10-23 换风格：主色从青绿 #2bd9a0 改为橙 #ff7500（用户拍板 B）。
# 断言跟设计走，不跟旧颜色走。
if grep -q '0.043, green: 0.043, blue: 0.047' "$FLASH_SW" \
   && grep -q '1.000, green: 0.459, blue: 0.000' "$FLASH_SW" \
   && grep -q 'static let hair ' "$FLASH_SW"; then
  t_ok "色板到位（近黑底 #0b0b0c + 橙色主色 #ff7500 + 发丝线）"
else
  t_fail "色板不完整（应含近黑底/橙色主色/发丝线）"
fi

# 17.19 开场动画必须**真全屏**（2026-10-22 用户拍板：默认全屏，WorkBuddy 自己不需要）
#   旧实现「可见区域的 92%×86% + .floating」有两个可见破绽：
#     ① 菜单栏和四边桌面露在外面 —— 观感是贴在桌上的网页，不是开机动画
#     ② .floating 层级压不住菜单栏，窗口上沿被菜单栏盖住一截
#   判据：窗口 frame 取 screen.frame（不是 visibleFrame 缩略）+
#         层级 .screenSaver（1000，压过菜单栏/Dock）。
#   ⚠ 反向断言 `! visibleFrame`：防「改了一半」——只加 screenSaver
#     但还在用 visibleFrame 算尺寸，四边依然露桌面。
BOOT_LAUNCH_SW="$BOOT_DIR/tools/wblaunch.swift"
if grep -q 'let fr = screen.frame' "$BOOT_LAUNCH_SW" \
   && grep -q 'win.level = .screenSaver' "$BOOT_LAUNCH_SW" \
   && ! grep -q 'visibleFrame' "$BOOT_LAUNCH_SW"; then
  t_ok "动画窗口是真全屏（screen.frame + .screenSaver 层级，盖住菜单栏/Dock）"
else
  t_fail "动画窗口不是全屏（应 screen.frame + .screenSaver，且不得再用 visibleFrame 缩略）"
fi

# 17.20 真副作用：窗口尺寸必须**等于屏幕尺寸**（数像素，不是查源码）
#   源码断言防不住「公式对但常量错」。这里真播一次（--force 跳过在跑判定、
#   --no-launch 不真拉 WorkBuddy），2.5 秒后杀掉，从 WB_LAUNCH_DEBUG 的
#   stderr 里解析窗口与屏幕尺寸比对。
#   ⚠ WB_LAUNCH_MUTE=1 必须带：否则自检要放 2.5 秒开场音效。
#   ⚠ 全屏 → window WxH == screen WxH；92%×86% 旧版 → 必然不等（差 8%/14%）。
#   ⚠ 多屏机器上取主屏 —— 与产品行为一致（动画只盖主屏），不是测试放水。
if [ -x "$BOOT_LAUNCH" ] && grep -q 'WB_LAUNCH_MUTE' "$BOOT_LAUNCH_SW"; then
  WB_ERR="$(mktemp /tmp/macctl_wbl.XXXXXX)"
  WB_LAUNCH_MUTE=1 WB_LAUNCH_DEBUG=1 "$BOOT_LAUNCH" play --no-launch --force 2>"$WB_ERR" &
  WB_PID=$!
  sleep 2.5
  kill "$WB_PID" 2>/dev/null || true
  wait "$WB_PID" 2>/dev/null || true
  WB_LINE="$(grep -m1 '\[wblaunch\] window' "$WB_ERR" || true)"
  WB_WIN="$(printf '%s' "$WB_LINE" | sed -n 's/.*window \([0-9]*\)x\([0-9]*\).*/\1x\2/p')"
  WB_SCR="$(printf '%s' "$WB_LINE" | sed -n 's/.*screen=\([0-9]*\)x\([0-9]*\).*/\1x\2/p')"
  rm -f "$WB_ERR"
  if [ -n "$WB_WIN" ] && [ "$WB_WIN" = "$WB_SCR" ] && grep -q 'visible=true' <<< "$WB_LINE" ; then
    t_ok "实测窗口尺寸 == 屏幕尺寸（${WB_WIN}pt 且可见 —— 全屏成立）"
  else
    t_fail "实测窗口 ${WB_WIN:-无输出} ≠ 屏幕 ${WB_SCR:-无输出}pt（debug 行：${WB_LINE:-缺失}）—— 全屏没生效"
  fi
else
  t_fail "wblaunch 不可执行或缺 WB_LAUNCH_MUTE 支持 —— 无法实测全屏窗口尺寸"
fi

# 17.21 全屏窗口不能用 center() 定位
#   center() 按**主屏**中心重排：多屏不同分辨率时，会把钉在副屏的
#   全屏窗口挪到主屏中心——尺寸不变但位置错位，四边立刻露出桌面。
#   show() 必须钉死目标屏整幅 frame（setFrame）。
if grep -q 'win.setFrame(fullFrame' "$BOOT_LAUNCH_SW" \
   && ! grep -q 'win.center()' "$BOOT_LAUNCH_SW"; then
  t_ok "全屏窗口钉死目标屏 frame（多屏下不会错位露桌面）"
else
  t_fail "全屏窗口还在用 center() 定位 —— 多屏不同分辨率时会错位露桌面"
fi

# 17.19 自检栏必须是**真实数据**，不能是写死的装饰文本
#   写死的假数据比没有这一栏更糟 —— 用户会以为它是真的。
#   断言：自检项来自 Probe.collect()，且有 doctor 输出解析。
#   注意 Probe.collect() 的**调用**在 flash.swift（面板侧），
#   Probe 的**定义**在 flash_archive.swift（采集侧）—— 两个文件都要查。
if grep -q 'Probe.collect()' "$FLASH_SW" \
   && grep -q 'static func collect()' "$FLASH_ARCH" \
   && grep -q 'AXIsProcessTrusted' "$FLASH_ARCH" \
   && grep -q 'panel-status' "$FLASH_ARCH"; then
  t_ok "自检栏读真实状态（被动 ENV + panel-status / 媒体目录 / 动画资源）"
else
  t_fail "自检栏没有读真实状态 —— 写死的假状态是在制造错觉"
fi

# 17.20 采集状态**不能**在 draw 里做
#   Probe 会 fork 子进程；在 draw 里跑 = 每次重绘都 fork = 面板卡死。
if grep -q 'DispatchQueue.global' "$FLASH_SW"; then
  t_ok "自检采集在后台线程（不会在 draw 里 fork 进程卡住面板）"
else
  t_fail "自检采集在主线程 —— 会在每次重绘时 fork 进程，面板会卡死"
fi

# ══ 18. 浏览器默认值 + 零系统弹窗（2026-10-22 用户反馈）════════════
#
# 背景：用户要求「打开浏览器默认打开谷歌浏览器」，
#   同时反馈测试期间反复弹出「应用程序无法打开」系统框。
#   根因是 NSWorkspace.openApplication 对 cryptex 路径应用
#   （Safari 真身在 /System/Volumes/Preboot/Cryptexes/...）
#   必然返回 -600 → LaunchServices 弹系统级模态框。
#   修法：改用 /usr/bin/open CLI（失败只写 stderr，绝不弹窗）。

# 18.1 「浏览器」必须解析到 Google Chrome
R_CHROME="$("$DIR/macctl" launch --name 浏览器 --resolve-only --json 2>/dev/null | head -1)"
case "$R_CHROME" in
  *'"bundle":"com.google.Chrome"'*) t_ok "「浏览器」默认解析到 Google Chrome" ;;
  *) t_fail "「浏览器」没有解析到 Google Chrome（实际=${R_CHROME}）" ;;
esac

# 18.2 「网页」「谷歌浏览器」等同义写法也要指向 Chrome
for alias in 网页 谷歌浏览器 chrome; do
  R="$("$DIR/macctl" launch --name "$alias" --resolve-only --json 2>/dev/null | head -1)"
  case "$R" in
    *'"bundle":"com.google.Chrome"'*) t_ok "「${alias}」解析到 Google Chrome" ;;
    *) t_fail "「${alias}」没有解析到 Google Chrome（实际=${R}）" ;;
  esac
done

# 18.3 Safari 必须保留显式入口（不能被 Chrome 别名吞掉）
R_SAFARI="$("$DIR/macctl" launch --name safari --resolve-only --json 2>/dev/null | head -1)"
case "$R_SAFARI" in
  *'"bundle":"com.apple.Safari"'*) t_ok "「safari」仍能显式解析到 Safari" ;;
  *) t_fail "「safari」解析失败（实际=${R_SAFARI}）" ;;
esac

# 18.4 别名表必须优先于名字模糊匹配
#   ⚠ 实测踩坑：豆包内置浏览器（com.bot.neotix.doubao.browser）
#     的显示名含「浏览器」三个字。旧的 resolveBundle 走
#     localizedName.contains("浏览器") 会先命中它 →
#     「打开浏览器」打开的却是豆包内置浏览器。
#   判据：resolveBundle 函数体里，别名表分支的位置在模糊匹配分支**之前**。
#   ⚠ 用纯 bash 做（awk 取函数体），不 spawn python —— 自检要快。
RESOLVE_BODY="$(awk '/^func resolveBundle\(/,/^}/' "$MACCTL_SRC")"
ALIAS_POS="$(printf '%s' "$RESOLVE_BODY" | grep -n 'APP_ALIASES\[s\]' | head -1 | cut -d: -f1)"
FUZZY_POS="$(printf '%s' "$RESOLVE_BODY" | grep -n 'localizedName?\.contains(s)' | head -1 | cut -d: -f1)"
if [ -z "$ALIAS_POS" ]; then
  t_fail "resolveBundle 里没有别名表分支 —— 「浏览器」会落到模糊匹配"
elif [ -z "$FUZZY_POS" ]; then
  t_fail "resolveBundle 里没有模糊匹配分支（结构被改坏了）"
elif [ "$ALIAS_POS" -lt "$FUZZY_POS" ]; then
  t_ok "resolveBundle 别名表优先于名字模糊匹配（不会被豆包浏览器抢走）"
else
  t_fail "resolveBundle 别名表分支在模糊匹配之后（别名 ${ALIAS_POS} > 模糊 ${FUZZY_POS}）—— 「浏览器」会被豆包浏览器抢走"
fi

# 18.5 macctl 启动路径**绝不能**再用 openApplication
#   它失败时会弹系统级模态框，用户关不掉、还会挡住桌面。
# ⚠ 只查**代码里的调用**，不查注释 ——
#   注释里写「绝不能用 openApplication」是必要的说明，不是违规调用。
#   判据：剥掉所有 // 与 /* */ 注释后，源码里不应再有 openApplication。
strip_swift_comments() {  # strip_swift_comments <文件>
  python3 - "$1" <<'PYEOF' 2>/dev/null
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
s = re.sub(r"//[^\n]*", "", s)
print(s)
PYEOF
}
MACCTL_CODE="$(strip_swift_comments "$MACCTL_SRC")"
if grep -q 'openApplication' <<< "$MACCTL_CODE" ; then
  t_fail "macctl 仍在用 openApplication —— 失败时会弹系统模态框"
else
  t_ok "macctl 已彻底移除 openApplication（启动失败不再弹系统框）"
fi

# 18.6 必须改用 /usr/bin/open CLI
if grep -q '/usr/bin/open' "$MACCTL_SRC"; then
  t_ok "macctl 改用 /usr/bin/open CLI 启动（失败只写 stderr，不弹窗）"
else
  t_fail "macctl 没有用 /usr/bin/open CLI —— 弹窗根因未除"
fi

# 18.7 launchSilently 必须优先按 bundle id 启动
#   cryptex 应用按路径 open 一定失败，只有 open -b 才通。
if grep -q 'func launchSilently' "$MACCTL_SRC" \
   && grep -q '"-b", bundleID' "$MACCTL_SRC"; then
  t_ok "launchSilently 优先按 bundle id 启动（兼容 cryptex 应用）"
else
  t_fail "launchSilently 缺失或未按 bundle id 启动"
fi

# 18.8 wblaunch 也不能用 openApplication
BOOT_LAUNCH="$DIR/bootanim/tools/wblaunch.swift"
if [ -f "$BOOT_LAUNCH" ]; then
  if printf '%s' "$(strip_swift_comments "$BOOT_LAUNCH")" | grep -q 'openApplication'; then
    t_fail "wblaunch 仍在用 openApplication —— 拉起失败会弹系统框"
  else
    t_ok "wblaunch 已移除 openApplication（拉起失败不再弹系统框）"
  fi
  if grep -q '/usr/bin/open' "$BOOT_LAUNCH"; then
    t_ok "wblaunch 改用 /usr/bin/open CLI 拉起 WorkBuddy"
  else
    t_fail "wblaunch 没有用 /usr/bin/open CLI"
  fi
fi

# 18.9 真实副作用验证：启动 Safari（cryptex 应用）必须零弹窗
#   ⚠ 这条断言**会真的启动应用**（Safari）—— 弹窗只在真实启动路径上出现。
#   判据：数 CoreServicesUIAgent 的窗口数（系统弹窗就是它画的）。
#   ⚠ 计数用**一次性编译**的探针，不要用 `swift -e` ——
#   每次 `swift -e` 都要重编译（十几秒），自检会慢到没人愿意跑。
CSUI_PROBE="/tmp/macctl_csui_probe"
if [ ! -x "$CSUI_PROBE" ] || [ "$MACCTL_SRC" -nt "$CSUI_PROBE" ]; then
  cat > /tmp/_csui_probe.swift <<'SWEOF'
import AppKit
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var n = 0
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    if owner.contains("CoreServicesUIAgent") { n += 1 }
}
print(n)
SWEOF
  /usr/bin/swiftc -O -o "$CSUI_PROBE" /tmp/_csui_probe.swift >/dev/null 2>&1
  rm -f /tmp/_csui_probe.swift
fi
csui_count() { "$CSUI_PROBE" 2>/dev/null | head -1 | tr -d ' \n'; }
BEFORE="$(csui_count)"; BEFORE="${BEFORE:-0}"
"$DIR/macctl" launch --name safari --json >/dev/null 2>&1
sleep 2
AFTER="$(csui_count)"; AFTER="${AFTER:-0}"
if [ "${AFTER}" -le "${BEFORE}" ]; then
  t_ok "启动 Safari（cryptex 应用）零系统弹窗（CoreServicesUIAgent 窗口 ${BEFORE}→${AFTER}）"
else
  t_fail "启动 Safari 弹出了系统框（CoreServicesUIAgent 窗口 ${BEFORE}→${AFTER}）"
fi

# 18.10 快捷打开必须把 App 送到**最上层**（2026-10-22 用户要求）
#   用户原话：「闪控快捷打开 app 这个功能，无论 app 是否开启，
#   点击后该 app 自动到界面最上层」。
#   两条路径都已实现置前：
#     路径 1（已运行）：activate() + open -b 兜底（open -b 对已运行 App 是纯置前）
#     路径 2（冷启动）：open -b 拉起 + frontmost() 再置前一次
#     （冷启动抢激活权不保证，实测备忘录/计算器起来后常停在后台）
#   ⚠ 这条断言**会真的启动计算器** —— 置前是运行时行为，
#     静态 grep 只能证明「代码里有 activate」，证明不了「真的置前了」。
#   判据：启动后 NSWorkspace.frontmostApplication 必须是 Calculator。
#   ⚠ 探针一次性编译并缓存（同 18.9 的 CSUI 探针），不要每次 swift -e。
# ⚠ 这里原来还有一条「macctl launch 计算器 → frontmost 必须是计算器」的断言，
#   2026-10-22 删掉：它测的是 **CLI 子进程里的 activate**，而这条路径本身
#   已经被证明是空操作（Q4 的根因）。保留它等于给一个已知无效的通道设 KPI，
#   机器一忙就红，红的原因还和用户感受到的东西无关。
#   真正的判据在 18.11：面板真实路径连跑 5 次，每级都实测 frontmost。

# 18.11 热启动置前（工件A / Q4 实锤 bug 的回归测试）
#   用户复现：「点微信（已开着）→ 它排在后面」。根因：app 分支把置前外包给
#   macctl 子进程，而 CLI 非前台进程调 NSRunningApplication.activate 是**空操作**。
#   修法：置前收回 flash 进程内（T1 activate → T2 open -b → T3 AXRaise → T4 dock）。
#
#   ⚠ 为什么必须用 `--selftest-raise` 而不是直接调 macctl：
#     只有「flash 自己建面板 → show() 拿到激活权 → 降层 → 置前」这条真实路径
#     才测得到 T1。无窗口进程里跑，T1 必然失败、只能测到 T2 —— 那是假通过。
#   ⚠ 每次测前先把激活权交给访达：目标本来就是 frontmost 的话，测了等于没测。
#   ⚠ 目标用「计算器」不用微信：自检不该依赖用户是否登录着微信。
if grep -q "func raiseAppInProcess" "$FLASH_SW" \
   && grep -q "lowerPanelForApp" "$FLASH_SW" \
   && grep -q "selftest-raise" "$FLASH_SW"; then
  t_ok "置前引擎在 flash 进程内（raiseAppInProcess + 面板降层 + 无UI 验证入口）"
else
  t_fail "置前引擎缺失或缺入口 —— 会退回「外包给子进程」的老路（Q4 复现）"
fi
# 面板降层后必须能升回 .floating，否则「降层一次，面板永久被压住」
if grep -q "window.level = .floating" "$FLASH_SW" \
   && grep -q "w.level = .normal" "$FLASH_SW"; then
  t_ok "面板层级双向可控（成功降 .normal 让开、再 show() 回 .floating）"
else
  t_fail "面板层级只有单向 —— 降层后回不到置顶，用户会找不到面板"
fi

RAISE_OK=0; RAISE_N=0; RAISE_T1=0; RAISE_LOG=""
for _i in 1 2 3 4 5; do
  RAISE_N=$((RAISE_N + 1))
  /usr/bin/open -b com.apple.finder >/dev/null 2>&1
  sleep 0.7
  ROUT="$("$DIR/flash" --selftest-raise 计算器 2>/dev/null | head -1)"
  case "$ROUT" in
    *'"ok":true'*'"front":"com.apple.calculator"'*) RAISE_OK=$((RAISE_OK + 1)) ;;
  esac
  case "$ROUT" in
    *'"how":"T1"'*) RAISE_T1=$((RAISE_T1 + 1)) ;;
  esac
  RAISE_LOG="$RAISE_LOG [$ROUT]"
done
if [ "$RAISE_OK" -eq "$RAISE_N" ]; then
  t_ok "热启动置前连跑 ${RAISE_N} 次全部到最上层（其中 ${RAISE_T1} 次走最快的 T1 进程内激活）"
else
  t_fail "热启动置前 ${RAISE_OK}/${RAISE_N} 次成功 —— Q4 会复现（详情：${RAISE_LOG}）"
fi

# ══ 18.12~18.14 工件B：转交全自动（2026-10-22 夜）══════════════
#
# 目标：闪控输入一句复杂指令 → WorkBuddy **自动**新建任务、自动粘贴、
#       自动选 mac-control 技能、自动发送。全程零键盘零鼠标。
#
# ⚠ 为什么只能真跑：这条链路每一步都是「真按键 + 真 AX 点击」，
#   源码里 grep 得到名字不代表能点动。所以 18.13 每次自检都会真的
#   在 WorkBuddy 里建一个任务 —— 这不是副作用失控，是仅有的诚实测法。
#   （工件A 的教训：只断言源码字符串 = 恒真 = 等于没测。）
HANDOFF_SW="$DIR/flash_handoff.swift"

# 18.12 链路四要素：完整 AX 树开关 / 输入框定位 / 回车提交 / 面板接线
if [ -f "$HANDOFF_SW" ] \
   && grep -q "func handoffToWorkBuddy" "$HANDOFF_SW" \
   && grep -q "AXManualAccessibility" "$HANDOFF_SW" \
   && grep -q "AXEnhancedUserInterface" "$HANDOFF_SW" \
   && grep -q '今天帮你做些什么' "$HANDOFF_SW" \
   && grep -q "postKey(kc.ret)" "$HANDOFF_SW" \
   && grep -q "func performHandoff" "$FLASH_SW" \
   && grep -q 'func performHandoff(_ text: String, skill: String? = "mac-control")' "$FLASH_SW" \
   && grep -q "handoffToWorkBuddy(text, skill: skill)" "$FLASH_SW"; then
  t_ok "转交链路四要素齐（Electron AX 双开关 + 输入框定位 + 回车优先 + 面板接线）"
else
  t_fail "转交链路缺件 —— 复杂任务会退回「只复制，用户自己 ⌘V」的半自动"
fi

# 18.12b 技能候选必须按**位置**收窄，不能在整棵树里找文本
#   踩过：侧栏任务列表里有一条含 mac-control 的历史任务，BFS 先撞上它，
#         一点就切走会话，后面的粘贴落到别的页面。
if grep -q 'f.maxY <= cr.minY' "$HANDOFF_SW" && grep -q 'axFrame(box)' "$HANDOFF_SW"; then
  t_ok "技能候选按位置收窄（限定输入框上方 + 左缘对齐，不会误点侧栏历史任务）"
else
  t_fail "技能候选没做位置收窄 —— 会误点侧栏里同名的历史任务，切走会话"
fi

# 18.14 降级：技能唤不出来必须**不阻断**转交（技能只是增强）
if grep -q '技能唤不出来，按「无技能」继续转交' "$HANDOFF_SW"; then
  t_ok "技能选择失败不阻断转交（只是少了技能增强，指令照样送达）"
else
  t_fail "技能失败会阻断转交 —— 一次 UI 改动就能让整个转交失效"
fi

# ══ 19. 三维地球几何（2026-10-22 用户要求：logo 换成动态三维旋转地球）═════
#
# 背景：用户要求把右上角「+号旁转圈的 logo」换成动态三维旋转地球。
#   第一版 GlobeView 有三个渲染 bug，全部是**投影数学**错误：
#     ① 赤道远侧弧被 mirrored() 左右镜像 → 画成一条横穿球心的水平亮线
#     ② 高纬线远侧弧镜像后在极点附近拧出尖角
#     ③ 前后半球的换边处用 line 硬连 → 球边缘拉出横穿直线
#   修法：背面点**不镜像**（正交投影下远侧弧本就该透视地压在球后面），
#         按深度符号切连续子路径，换边必须 move。
#   这一节的断言就是把这些修法钉死，防止回归。

# 19.1 面板 logo 必须是 GlobeView，且定义在 flash_archive.swift
if grep -q 'class GlobeView' "$FLASH_ARCH" \
   && grep -q 'var globe: GlobeView' "$FLASH_SW"; then
  t_ok "右上角 logo 是三维自转地球 GlobeView（不是旧准星）"
else
  t_fail "GlobeView 缺失（面板 logo 不是三维地球）"
fi

# 19.2 投影必须返回深度（前后分级的基础），且背面不镜像
#   mirrored() 是三个渲染 bug 的共同根因，剥注释后源码里不允许再出现。
ARCH_CODE="$(strip_swift_comments "$FLASH_ARCH")"
if grep -q 'mirrored' <<< "$ARCH_CODE" ; then
  t_fail "flash_archive.swift 又出现了 mirrored() —— 赤道横线/极点尖角会回归"
else
  t_ok "已根除 mirrored 左右镜像（背面点按正交投影直接落位）"
fi
if grep -q -- '-> (NSPoint, CGFloat)' "$FLASH_ARCH"; then
  t_ok "project() 返回「屏幕坐标 + 深度」（正面/背面分级有依据）"
else
  t_fail "project() 没有返回深度 —— 无法区分前后半球"
fi

# 19.3 换边必须 move 不能 line
#   bug 版在前后交界处硬连两点 → 球边缘拉出一条横穿的直线。
if grep -q 'if s != side' "$FLASH_ARCH" \
   && grep -q 'front.move(to: p) } else { back.move(to: p) }' "$FLASH_ARCH"; then
  t_ok "跨正/背面时 move 起新子路径（不会拉出横穿直线的伪影）"
else
  t_fail "换边逻辑缺失 —— 前后半球交界会画出横穿球面的直线"
fi

# 19.4 相机姿态：必须正对东亚，不能俯视北极
#   「数字有出处」是档案质感的一部分，随手写的 20° 会穿帮。
# 旧版这里断言 tilt=23.4（地轴倾角）。但那个值在算式里是**相机姿态**，
#   23.4° 等于相机停在极点上空 —— 屏幕上只有北极圈，亚洲永远在背面。
#   现在断言两件事：相机纬度 30°N、初始经度 108°E（中国中部）。
# 2.1 起相机拆成两个量：camLat（纬度，拖拽可改，初值 30）与
#   dragLon（水平拖拽偏移，叠加在 phase 上；-108 是初始经度 108°E 的体现）。
if grep -q 'private var camLat: CGFloat = 30' "$FLASH_ARCH" \
   && grep -q '(phase + dragLon - 108)' "$FLASH_ARCH"; then
  t_ok "地球相机正对东亚（30°N / 108°E），且拖拽偏移叠加在自转上"
else
  t_fail "地球相机姿态不是 (30°N, 108°E) —— 视角可能回到北极俯视"
fi

# 19.4b 交互：地球可拖拽，但不设置 NSCursor；仅在 key window 接受首击
if grep -q 'override func mouseDragged' "$FLASH_ARCH" \
   && grep -q 'dragLon += dx' "$FLASH_ARCH" \
   && grep -q 'dragLon += self.velLon' "$FLASH_ARCH" \
   && ! grep -q 'NSCursor' <<< "$FLASH_ARCH_CODE" ; then
  t_ok "地球可拖拽转向，且不设置 NSCursor（不抢光标）"
else
  t_fail "地球拖拽入口缺失或仍在设置 NSCursor"
fi

# 19.5 前/背面必须分两条通道
#   大陆、经纬网都按 z 分成 front / back 两遍绘制（back 更淡）。
#   合成一条的话，背面海岸线会和正面同等亮度，球就读成"平面切割图"。
if grep -q 'front: false' "$FLASH_ARCH" && grep -q 'front: true' "$FLASH_ARCH"; then
  t_ok "大陆/网格分正背两态（背面更淡，球感成立）"
else
  t_fail "正背面没有分通道 —— 球会读成平面切割图"
fi

# 19.6 赤道走单独高亮通道
#   赤道是球面的「基准面」，也是自转轴心参照，必须比经纬网亮一个档次。
if grep -q 'func drawEquator' "$FLASH_ARCH" \
   && grep -q 'GlobeView.cyan.withAlphaComponent(0.55).setStroke()' "$FLASH_ARCH"; then
  t_ok "赤道单独高亮（基准面一眼可辨）"
else
  t_fail "赤道没有单独高亮通道"
fi

# 19.7 快照工具必须在（视觉核对通道）
#   几何断言只能证明「在画、没越界」，证明不了「像不像地球」——
#   纬线疏密、极点毛刺、背面透明度必须用眼睛看。
if grep -q '\-\-snapshot' "$FLASH_SW" \
   && grep -q '\-\-globe-only' "$FLASH_SW" \
   && grep -q '\-\-zoom' "$FLASH_SW"; then
  t_ok "快照/放大出图通道存在（--snapshot --globe-only --zoom）"
else
  t_fail "缺少视觉核对通道 —— 画得对不对只能靠猜"
fi

# 19.8 前置：flash 二进制必须比源码新
#   像素级回归跑的是**二进制** —— 拿旧二进制测新代码 = 测了个寂寞。
if [ "$FLASH_SW" -nt "$DIR/flash" ] || [ "$FLASH_ARCH" -nt "$DIR/flash" ] \
   || [ "$DIR/flashkit.swift" -nt "$DIR/flash" ]; then
  bash "$DIR/build_flash.sh" >/dev/null 2>&1
fi
if [ -x "$DIR/flash" ]; then
  t_ok "flash 二进制就绪（源码新于二进制时先重编译）"
else
  t_fail "flash 二进制缺失 —— 像素级回归无从谈起"
fi

# 19.9 像素级回归：球心附近**不得**出现横贯球的水平亮线
#   ⚠ 这是三个渲染 bug 的**最终判据** —— 静态断言防不住「公式对但画错」，
#     只有真的出一张图、数像素，才能证明用户看到的是椭圆不是直线。
#   做法：--globe-only --zoom 4 出图（按倍数重画不是拉伸），
#         在中心 ±0.4R 行带、±0.95R 列范围内数最长连续亮段。
#   · bug 版：mirrored 把远侧弧翻到 y≈cy-0.08R 并跨边硬连
#     → 一条 670+px 的横贯线（实测 673px）
#   · 修复版：中心带只被经纬线斜穿，每段 ≤40px（实测 32px）
#   判据阈值取 150px：距 bug 表现 4.5 倍，距正常表现 4.7 倍。
#   ⚠ 亮度阈值取 80（BG=34）：bug 横贯线是 hair 0.22 淡灰度、
#     抗锯齿稀释后约 86~147，用 110 会漏掉它（实测踩过）。
#   ⚠ R 的算法：出图是 2x Retina。地球视图 = 208×190（宽随右栏、高是
#     globeSize），earthRadius = min(w,h)/2 - 11 = 84pt = 168px。
#     所以 R = min(W,H)/2 - 22（2x 下 11pt = 22px）。
GLOBE_SHOT="/tmp/macctl_globe_selftest.png"
if "$DIR/flash" --snapshot "$GLOBE_SHOT" --globe-only --zoom 4 --phase 0 >/dev/null 2>&1 \
   && [ -f "$GLOBE_SHOT" ]; then
  LONGEST="$(/usr/bin/python3 - "$GLOBE_SHOT" <<'PYEOF' 2>/dev/null
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
px = im.load()
cx, cy = W // 2, H // 2
R = min(W, H) / 2 - 22         # 见上方注释：2x Retina 下的 earthRadius
band = int(0.40 * R)           # 中心行带
x0, x1 = int(cx - 0.95 * R), int(cx + 0.95 * R)
best = cur = 0
for y in range(cy - band, cy + band + 1):
    cur = 0
    for x in range(x0, x1):
        if sum(px[x, y]) > 80:  # 亮度阈值（稀释后的淡灰度线也能抓到）
            cur += 1
            best = max(best, cur)
        else:
            cur = 0
print(best)
PYEOF
)"
  LONGEST="${LONGEST:-999}"
  if [ "$LONGEST" -lt 150 ]; then
    t_ok "球心无横贯亮线，赤道是椭圆（中心带最长亮段 ${LONGEST}px < 150px 阈值）"
  else
    t_fail "球心出现横贯球的水平亮线（最长亮段 ${LONGEST}px）—— mirrored 回归了？"
  fi
else
  t_fail "地球快照出图失败 —— 无法做像素级回归"
fi

# 19.10 反向验证：这套像素判据**抓得到** bug 版
#   ⚠ 只会说「现在是对的」的测试是半残的 —— 它没证明过自己能发现错误。
#   做法：把第一版的两个 bug 原样注回去（背面 x 取反 + 换边时对已有
#   内容的路径用 line 硬连），编译出一个「故意坏掉的二进制」，
#   跑同一条像素判据，必须判失败。
#   通过后才承认：19.9 的 ✓ 是真的 ✓，不是永远 ✓。
BAD_SHOT="/tmp/macctl_globe_selftest_bad.png"
BAD_SW="/tmp/_flash_globe_bad.swift"
BAD_BIN="/tmp/_flash_globe_bad"
if [ -x "$DIR/flash" ]; then
  /usr/bin/python3 - "$FLASH_ARCH" "$BAD_SW" <<'PYEOF'
import io, sys
src = io.open(sys.argv[1], encoding="utf-8").read()
# 注入 1：背面点 x 取反（第一版 mirrored() 的行为）
anchor1 = "return (NSPoint(x: c.x + x * R, y: c.y + sy * R), sz)"
if anchor1 not in src:
    sys.stderr.write("注入1锚点没找到（project 的返回语句变了？）\n"); sys.exit(1)
bad = src.replace(
    anchor1,
    "let sx = sz >= 0 ? x : -x\n        return (NSPoint(x: c.x + sx * R, y: c.y + sy * R), sz)")
# 注入 2：赤道正面弧分段时直接硬连（2026-10-22 真实踩到的 bug：
#   自转相位把正面那半圈切到数组两端，第二段起点 line 到第一段末尾 →
#   一条横贯球的水平直线）。这里必须复现**同一个** bug，否则反证不成立。
old = "                if wasFront { path.line(to: p) } else { path.move(to: p) }"
if old not in bad:
    sys.stderr.write("注入2锚点没找到（drawEquator 的分段逻辑变了？）\n"); sys.exit(1)
bad = bad.replace(
    old,
    "                if path.isEmpty { path.move(to: p) } else { path.line(to: p) }")
io.open(sys.argv[2], "w", encoding="utf-8").write(bad)
PYEOF
  if [ -f "$BAD_SW" ]; then
    # ⚠ 编译清单**不许在这里抄一份**：抄的那份在加了 flash_earth_data /
    #   flash_handoff 之后没跟上，坏版直接编译失败 → 反向验证静默失守
    #   （2026-10-22 自检抓到）。这里照「几何自检反证」的老办法：
    #   **解析 build_flash.sh 的 cat 清单**，只把 flash_archive.swift 换成坏版。
    /usr/bin/python3 - "$DIR" "$BAD_SW" /tmp/_flash_bad_all.swift <<'PYSPLICE'
import io, os, re, sys
d, bad_archive, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
build = io.open(os.path.join(d, "build_flash.sh"), encoding="utf-8").read()
files = re.findall(r'cat\s+"?([^"\s]+\.swift)"?', build)
if not files:
    sys.stderr.write("build_flash.sh 里没解析到 cat 清单\n"); sys.exit(1)
macctl = io.open(os.path.join(d, "macctl.swift"), encoding="utf-8").read()
m = re.search(r"^struct Args \{.*?^\}\n", macctl, re.M | re.S)
args_src = m.group(0) if m else ""
out = []
for f in files:
    f = f.replace("$DIR", d)
    if f.endswith("/flash_archive.swift"):
        out.append(io.open(bad_archive, encoding="utf-8").read())
    elif "flash_args" in f:
        out.append(args_src)
    else:
        out.append(io.open(f, encoding="utf-8").read())
io.open(out_path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PYSPLICE
    if /usr/bin/swiftc -O -o "$BAD_BIN" /tmp/_flash_bad_all.swift >/dev/null 2>&1; then
      # ⚠ 相位不能写死一个：注入的镜像 bug 只在**某些自转相位**才把远侧弧
      #   翻到中心行带（2026-10-22 实测：phase0=28px / phase90=23px /
      #   phase150=673px）。写死 phase 0 等于让「判据抓得到 bug」永远判负 ——
      #   这是反向验证长期失守的另一半原因（编译清单过期只是第一半）。
      BAD_LONGEST=0
      for BAD_PH in 0 90 150 220; do
        "$BAD_BIN" --snapshot "$BAD_SHOT" --globe-only --zoom 4 --phase "$BAD_PH" >/dev/null 2>&1
        [ -f "$BAD_SHOT" ] || continue
        BAD_ONE="$(/usr/bin/python3 - "$BAD_SHOT" <<'PYEOF' 2>/dev/null
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
px = im.load()
cx, cy = W // 2, H // 2
R = W / 2 - 30
band = int(0.40 * R)
x0, x1 = int(cx - 0.95 * R), int(cx + 0.95 * R)
best = cur = 0
for y in range(cy - band, cy + band + 1):
    cur = 0
    for x in range(x0, x1):
        if sum(px[x, y]) > 80:
            cur += 1
            best = max(best, cur)
        else:
            cur = 0
print(best)
PYEOF
)"
        BAD_ONE="${BAD_ONE:-0}"
        [ "$BAD_ONE" -gt "$BAD_LONGEST" ] && BAD_LONGEST="$BAD_ONE"
        rm -f "$BAD_SHOT"
      done
      if [ "$BAD_LONGEST" -ge 150 ]; then
        t_ok "反向验证通过：mirrored+硬连版会被像素判据抓住（坏版最长亮段 ${BAD_LONGEST}px ≥ 150px）"
      else
        t_fail "反向验证失败：故意注入的 bug 版居然没被抓到（${BAD_LONGEST}px）—— 19.9 的判据是摆设"
      fi
    else
      t_fail "bug 版编译失败 —— 反向验证没跑成"
    fi
    rm -f "$BAD_SW" "$BAD_BIN" /tmp/_flash_bad_all.swift "$BAD_SHOT"
  else
    t_fail "bug 版源码生成失败 —— 反向验证没跑成"
  fi
fi

# ══ 19.11~19.12 工件C：大陆轮廓（2026-10-22 夜）══════════════════
#
# 用户要求「一眼认出五大洲轮廓」。只有经纬网的球是地球仪不是地球，
# 所以加了 Natural Earth 1:110m 陆地数据（构建期简化后固化）。
#
# ⚠ 数据必须**构建期生成**，不能运行时下载：
#   面板是常驻进程，联网失败就变成一个空格子，而且用户根本不知道为什么。
DATA_SW="$DIR/flash_earth_data.swift"
GEN_PY="$DIR/tools/gen_globe_data.py"

# 19.11 数据文件 + 生成器 + 渲染代码三件套
if [ -f "$DATA_SW" ] && [ -f "$GEN_PY" ] \
   && grep -q "earthLandRings" "$DATA_SW" \
   && grep -q "func drawLand" "$FLASH_ARCH" \
   && grep -q "flash_earth_data.swift" "$DIR/build_flash.sh"; then
  t_ok "大陆轮廓三件套齐（数据文件 + 生成脚本 + drawLand 渲染 + 编译接线）"
else
  t_fail "大陆轮廓缺件 —— 地球退回线框球（用户要求的「认出五大洲」没了）"
fi

# 19.11b 环数/顶点数必须是个「像海岸线」的量级
LAND_RINGS="$(grep -c '^    \[(' "$DATA_SW" 2>/dev/null | tr -d ' ')"
if [ "${LAND_RINGS:-0}" -ge 8 ] && [ "${LAND_RINGS:-0}" -le 120 ]; then
  t_ok "陆地数据量级合理：${LAND_RINGS} 个环（太少=糊成一坨，太多=96pt 上全是噪点）"
else
  t_fail "陆地环数异常：${LAND_RINGS}（应 8~120）—— 重新跑 tools/gen_globe_data.py"
fi

# 19.12 像素：球内「有墨」覆盖率必须落在 20%~50%
#   ⚠ 这个区间是**量出来的**，不是拍的：
#     实测三相位（28°/130°/220°，覆盖亚欧/美洲/太平洋）都在 34%~37%
#     （阈值：与底板色的通道差之和 > 30）。
#     低于 20% = 大陆没画出来 / 数据为空；高于 50% = 线挤成一团糊版。
#   ⚠ 三个相位都取：先转 28° 时亚欧在正面，转 220° 时美洲在正面 ——
#     只测一个相位，万一某个半球的数据坏了（比如跨日界线的边画飞了）发现不了。
GLOBE_COVER=""
GLOBE_COVER_OK=1
for _ph in 28 130 220; do
  _shot="/tmp/macctl_globe_ph${_ph}.png"
  if "$DIR/flash" --snapshot "$_shot" --globe-only --zoom 1 --phase "$_ph" >/dev/null 2>&1 \
     && [ -f "$_shot" ]; then
    _cov="$(/usr/bin/python3 - "$_shot" <<'PYEOF' 2>/dev/null
import sys, math
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
px = im.load()
scale = W / 208.0         # 地球视图宽 = Layout.sideW（208pt）；出图 2x
R = min(W, H) / 2.0 - 11 * scale
cx, cy = W / 2.0, H / 2.0
# ⚠⚠ 不能用「角落像素」当背景：新设计的快照左上角是**橙色品牌块**
#   （实测 px[2,2]=(230,87,8)），把它当底色，深蓝球面自然"处处不同" →
#   覆盖率恒为 100%，这条断言直接失去意义（2026-10-23 踩到）。
#   改成取球内**众数颜色**当底色，再数偏离它的"亮墨"。这样换配色也不会误判。
from collections import Counter
samples = []
for y in range(H):
    for x in range(W):
        if math.hypot(x - cx, y - cy) <= R - 1:
            samples.append(px[x, y])
base = Counter(samples).most_common(1)[0][0]
on = sum(1 for (r, g, b) in samples
         if abs(r - base[0]) + abs(g - base[1]) + abs(b - base[2]) > 150)
print(int(100.0 * on / max(len(samples), 1)))
PYEOF
)"
    GLOBE_COVER="$GLOBE_COVER ${_ph}°=${_cov}%"
    case "$_cov" in
      ''|*[!0-9]*) GLOBE_COVER_OK=0 ;;
      *) [ "$_cov" -lt 1 ] || [ "$_cov" -gt 30 ] && GLOBE_COVER_OK=0 ;;
    esac
  else
    GLOBE_COVER="$GLOBE_COVER ${_ph}°=出图失败"
    GLOBE_COVER_OK=0
  fi
  rm -f "$_shot"
done
if [ "$GLOBE_COVER_OK" -eq 1 ]; then
  t_ok "球内亮墨占比正常（应 1%~30%）：${GLOBE_COVER}"
else
  t_fail "球内亮墨占比越界：${GLOBE_COVER} —— <1% 大陆/光点没画出来，>30% 糊成一团"
fi

# ══ 20. 开场动画交互模型（2026-10-22 用户拍板）═════════════════════════
# 用户原话：「得我点击了空格或者enter才进入下一个动画的界面，不是自己立刻动
# （但是如果3秒内没有人交互，自动进入下一个动画的界面）」+「动画必须先于
# WorkBuddy 出现」。这一组就是守这两条口径的。
SPLASH_JS="$DIR/bootanim/web/splash.js"
SPLASH_CSS="$DIR/bootanim/web/splash.css"
# ⚠⚠ 必须用新变量名：$BOOT_LAUNCH 在 18.8 组被重新赋值成了 **.swift 源码文件**
#   （第 1526 行），拿它当可执行文件跑必然静默失败 —— 2026-10-22 实测：
#   截图拍到背后的 WorkBuddy（均值 640 + 橙品牌色），被误读成"闸门没拦住"。
WBLAUNCH_BIN="$BOOT_DIR/tools/wblaunch"

# 20.1 配置开关：sceneGate + 3 秒超时必须在 DEFAULTS 里
# 超时值随设计变过（3000 → 6000，用户拍板"3 秒看不完一个场景"），
# 断言只要求"有这个开关且是个合理数字"，不锁死具体毫秒。
if grep -q 'sceneGate: true' "$SPLASH_JS" \
   && grep -qE 'gateTimeoutMs: [0-9]{4,5}' "$SPLASH_JS"; then
  t_ok "场景闸门配置在位（sceneGate:true + gateTimeoutMs=$(grep -oE 'gateTimeoutMs: [0-9]+' "$SPLASH_JS" | head -1 | grep -oE '[0-9]+')）"
else
  t_fail "缺 sceneGate/gateTimeoutMs 配置 —— 交互模型没有开关"
fi

# 20.2 闸门函数：监听 Space/Enter + 超时两条放行路径都要有
if grep -q "function gateScene" "$SPLASH_JS" \
   && grep -q "e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar'" "$SPLASH_JS" \
   && grep -q "setTimeout(function () { fin(false) }, clampGateMs(C.gateTimeoutMs))" "$SPLASH_JS"; then
  t_ok "gateScene 三通道齐全（按键立刻走 / 超时自动走 / 跳过放行）"
else
  t_fail "gateScene 缺按键或超时通道 —— 会退化成'定时器到点就切'或'死等按键'"
fi

# 20.2b 闸门必须有「刚开门 350ms 内忽略输入」的静默窗口
#   2026-10-22 实测：闸门 open 后 200~800ms 内必定收到一次 manual 放行，
#   当时没有任何人碰键鼠 —— 结果整场动画 3.5 秒跑完（本该 6 道闸 ≥18 秒），
#   截图在 6 秒时均值 119，判据全红。静默窗口是唯一的止血点。
if grep -q "armedAt" "$SPLASH_JS" && grep -q "Date.now() - armedAt < 350" "$SPLASH_JS"; then
  t_ok "闸门有 350ms 静默窗口（刚开门那一下输入不会误放行）"
else
  t_fail "闸门没有静默窗口 —— 系统残留输入会把整场动画一口气推完"
fi

# 20.3 接入点数量：两道幕间 + 五个步骤 + 终幕前 = 6 处调用 + 1 处定义
GATE_CALLS="$(grep -c "gateScene(" "$SPLASH_JS" || true)"
if [ "${GATE_CALLS:-0}" -ge 7 ]; then
  t_ok "闸门接入点足够（${GATE_CALLS} 处 ≥ 7：幕间×2 + 步骤×5 + 终幕前×1）"
else
  t_fail "闸门接入点只有 ${GATE_CALLS} 处 —— 有场景没被闸门管住，会'自己立刻动'"
fi

# 20.4 z-index 必须压住黑幕：第一道闸门就发生在黑幕还在的时候
#   （27 会被 .dsu-black 的 40 盖住 —— 2026-10-22 实测第一版就是这症状）
if grep -A10 '^\.dsu-gate {' "$SPLASH_CSS" | grep -q 'z-index: 70'; then
  t_ok "闸门提示压住黑幕（z-index 70 > .dsu-black 40）"
else
  t_fail "闸门提示会被黑幕盖住（z-index 需 > 40）—— 第一道闸门用户看不到提示"
fi

# 20.5 流空线必须用 transform 排水：改 width 会把 72px 拉成通栏直线
if grep -q "style.transform = 'scaleX(1)'" "$SPLASH_JS" \
   && grep -q "style.transform = 'scaleX(0)'" "$SPLASH_JS" \
   && ! grep -q "gateBar.style.width = '100%'" "$SPLASH_JS"; then
  t_ok "流空线用 scaleX 排水（不是改 width —— 那条坑实测踩过）"
else
  t_fail "流空线还在改 width，会把 72px 细线拉成横贯全屏的直线"
fi

# 20.6 Esc 跳过必须保留（交互模型只把"任意键跳过"改成"空格前进"）
if grep -q "if (e.key === 'Escape') requestSkip()" "$SPLASH_JS"; then
  t_ok "Esc 跳过仍在（用户反感的只是'任意键跳过'，不是跳过本身）"
else
  t_fail "Esc 跳过没了 —— 用户被 30~50 秒动画锁死时没有逃生门"
fi

# 20.7 wblaunch 必须把 sceneGate/gateTimeoutMs 注入网页（否则退回 DEFAULTS 之外的旧行为）
if grep -q '"sceneGate": true' "$BOOT_LAUNCH_SW" \
   && grep -q '"gateTimeoutMs": gateTimeoutMs()' "$BOOT_LAUNCH_SW"; then
  t_ok "wblaunch 注入场景闸门配置（sceneGate + gateTimeoutMs）"
else
  t_fail "wblaunch 没注入闸门配置 —— 开机动画会用错交互模型"
fi

# 20.8 wblaunch 不得再注入「任意键跳过」脚本 —— 和闸门直接冲突
if grep -q "document.addEventListener('keydown', fire, true)" "$BOOT_LAUNCH_SW"; then
  t_fail "wblaunch 还在注入任意键跳过 —— 按空格会把整场动画掐掉（与闸门冲突）"
else
  t_ok "wblaunch 已移除任意键跳过注入（跳过只走 splash.js 内的 Esc/SKIP）"
fi

# 20.9 兜底超时必须够长：9 道闸 × 3 秒 + 内容 ≈ 50 秒，20 秒会拦腰掐断
if grep -q "armTimeout(90)" "$BOOT_LAUNCH_SW"; then
  t_ok "wblaunch 兜底 90 秒（闸门等待不被误判死）"
else
  t_fail "wblaunch 兜底还是 20 秒 —— 带闸门的动画会被拦腰掐断"
fi

# 20.10 闪控两个入口都必须走 wblaunch（动画先于 WorkBuddy）
# ⚠ 断言必须锚在**可执行代码**上：注释里提到 runWblaunch(["play"]) 是说明，
#   不是调用。先剥注释行再判（这个文件自己在 16.4 里就吃过这个亏）。
FLASH_SW_CODE="$(grep -v '^[[:space:]]*//' "$FLASH_SW")"
if grep -q 'cmd: \["launch", "--name", "WorkBuddy"\]' <<< "$FLASH_SW_CODE" \
   && ! grep -q 'runWblaunch(\["play"\])' <<< "$FLASH_SW_CODE"; then
  t_ok "面板的 WorkBuddy 按钮走普通 launch（动画只在开机播，2026-10-25 用户拍板）"
else
  t_fail "面板仍在运行期触发开场动画 —— 与「动画只在开机播」冲突"
fi

# 20.10b 缺「屏幕录制」授权时，面板不得先藏再拍（白闪一下更像坏了）
#   用户视角：点了截图 → 面板闪一下又回来 → 状态栏报错 = "好像没反应"。
#   正确做法：先 CGPreflightScreenCaptureAccess()，缺就直接说清该勾哪一项。
# ⚠ P13 起判据要更细：**录屏**那一支现在确实会请求一次授权
#   （截图早就不用问了，但 `screencapture -v` 必须有这一次勾选）——
#   所以不能再用"文件里出现 CGRequestScreenCaptureAccess() 就算违规"这种粗判，
#   否则合法的新代码会被判红（本次实测就红了一条）。
#   真正要守的是：**每一次**请求都必须在 LINGTAI_REC_PROMPT 守卫后面
#   （变量不存在 → 一行都不执行 → 平时绝不弹窗，ERR-0023）。
ATH_UNGUARDED="$(/usr/bin/python3 - "$FLASH_SW" <<'PY'
import io, sys
lines = io.open(sys.argv[1], encoding="utf-8").read().splitlines()
bad = []
for i, ln in enumerate(lines):
    s = ln.strip()
    if s.startswith("//"):                  # 注释里提到不算调用
        continue
    if "CGRequestScreenCaptureAccess(" not in ln:
        continue
    ctx = "\n".join(lines[max(0, i - 6):i + 1])   # 往上看 6 行找守卫
    if "LINGTAI_REC_PROMPT" not in ctx:
        bad.append(str(i + 1))
print(" ".join(bad))
PY
)"
if grep -q 'com.lingtai.mediacap' "$FLASH_SW" \
   && grep -q 'mediacap.request' "$FLASH_SW" \
   && [ -z "$ATH_UNGUARDED" ]; then
  t_ok "面板截图走 launchd 的 mediacap job（不依赖 App 授权，也不弹授权框；唯一的授权申请被 LINGTAI_REC_PROMPT 守卫，只有 flashctl.sh rec 时才执行）"
else
  t_fail "面板截图仍走 App 自身权限，或存在**无守卫**的 CGRequestScreenCaptureAccess 调用（行 ${ATH_UNGUARDED:-无}）—— 会弹系统授权框且授权失效时拍不了"
fi

# 20.10d 截图要两种模式：藏面板 / 含面板
#   用户 2026-10-25 原话：「截图要两种模式（现在只有一种）」——
#   一种拍不到自己（默认），一种要把面板一起拍进去（做教程图、截图面板本身）。
#   判据必须盯「有没有真的不藏」：只加一个按钮、流程里照样 hide()，
#   用户点「含窗口」拿到的还是一张没有面板的图 —— 那叫假功能。
if grep -q '"截图·含窗口"' "$FLASH_SW" \
   && grep -q '"shot", "--interactive", "--keep-panel"' "$FLASH_SW" \
   && grep -q 'if !keepPanel {' "$FLASH_SW" \
   && grep -q 'if wasVisible && !keepPanel { show() }' "$FLASH_SW"; then
  t_ok "截图两种模式：「截图」藏面板 / 「截图·含窗口」全程不 hide()/show()"
else
  t_fail "截图只有一种模式，或「含窗口」版仍在藏面板（点了也拍不到自己）"
fi

# 20.10c 转交必须有「输入框不在 AX 树」的坐标兜底
#   2026-10-25 实测：WorkBuddy 5.8.3 的 contenteditable 不暴露 AXTextArea，
#   AX 路径在任务详情页必然 COMPOSER 失败。没有兜底 = 这种情况永远转交不了。
if grep -q 'handoffByCoordinates' "$DIR/flash_handoff.swift" \
   && grep -q 'COMPOSER 失败 → 转坐标兜底' "$DIR/flash_handoff.swift"; then
  t_ok "转交有坐标兜底（AX 找不到输入框时按窗口坐标点击 + 剪贴板粘贴）"
else
  t_fail "转交缺少坐标兜底 —— 输入框不在 AX 树时必然转交失败"
fi

# 20.11 开机动画自启注册命令必须存在（2026-10-22 翻车根因：
#   plist 躺在磁盘上从没被 bootstrap，重启后动画根本不弹，日志文件都不存在）
if grep -q 'install-boot)' "$DIR/flashctl.sh" \
   && grep -q 'com.lingtai.bootanim' "$DIR/flashctl.sh"; then
  t_ok "flashctl.sh install-boot 在位（开机动画自启可一键注册）"
else
  t_fail "没有 install-boot —— 开机动画没法可靠注册（踩过的坑会复发）"
fi

# 20.12 真副作用·闸门拦得住：门限 8 秒的动画在第 6 秒时应仍停在第一幕
#   （暗屏）+ 闸门提示可见。判据是**实测校准**过的：
#   ⚠ 采样点不能贴着门限（2026-10-22 自检踩过）：原采样就在第 8 秒、门限也是
#     8000ms，正好压在闸门到期的边界上 —— 机器一忙就采到「洗白向第二幕过渡」
#     的那一帧（实测均值 117、提示带 782），被判成「没拦住」，纯属采样竞态。
#     现在第 6 秒采样，留 2 秒余量：门限内必然还在第一幕。
#   ⚠ 别用「把门限调大」来换余量：实测 timeoutMs=12000 时第 8 秒反而已经
#     走到「需要访问许可」那一幕（均值 125）。门限只管闸门，不管某幕本身
#     播多久 —— 余量只能靠**提前采样**拿，不能靠调门限。
#   · 暗幕均值 5.6，洗白/底板均值 45+，WorkBuddy 浅色界面 640 —— 阈值 20 三者分开
#   · 提示带（66%~78% 高度、中心 ±220px）亮像素 ≥10：提示文字是浅灰、
#     流空线是强调色，都在这一带；暗幕这一带是纯黑
#   ⚠ 两条护栏防误判（2026-10-22 踩过）：
#     ① 先用 WB_LAUNCH_DEBUG 的 visible=true 确认窗口真起来了 ——
#        重编译后机器负载高，splash 可能 9 秒都没出现，截图拍到背后的
#        WorkBuddy（浅色+橙品牌色，均值 640），会被误读成"场景自己走了"
#     ② 采样步长 2 且查整条提示带 —— 流空线只有 2px 高，y 步长 4 有
#        50% 概率整条漏掉（第一版就误报过 orange=0）
GATE_SHOT="/tmp/macctl_gate_selftest.png"
GATE_ERR="$(mktemp /tmp/macctl_gate.XXXXXX)"
# ⚠ 这条判据量的是**屏幕**，不是页面内部状态：只要那一刻桌面上盖了别的东西
#   （后台任务弹窗、被抢焦点），拍到的就不是动画。实测同一条断言在忙/闲两种
#   机器状态下时红时绿。所以给它 3 轮机会：闸门真没拦住时三轮都会失败。
GATE_PASS=0
GATE_MEAN=""
GATE_BAND=""
# 2026-10-25：开机改成一镜到底后 sceneGate=false，闸门本身不存在。
# 关着的时候**不跑**这组（否则每次自检都白弹 3 次 18 秒全屏动画）。
SCENE_GATE="$(/usr/bin/python3 -c "import json,sys;print(str(json.load(open(sys.argv[1])).get('sceneGate',True)).lower())" "$BOOT_DIR/bootanim.config.json" 2>/dev/null || echo true)"
GATE_ROUNDS=3
[ "$SCENE_GATE" = "false" ] && GATE_ROUNDS=0
GATE_LINE=""
for _attempt in $(seq 1 $GATE_ROUNDS); do
  # 跑前清场：自检环境里不该有第三个动画实例
  pkill -f "wblaunch play" 2>/dev/null || true
  sleep 0.6
  WB_LAUNCH_MUTE=1 WB_LAUNCH_DEBUG=1 WB_LAUNCH_GATE_MS=8000 "$WBLAUNCH_BIN" play --no-launch --force \
    >/dev/null 2>"$GATE_ERR" &
  GPID=$!
  sleep 6
  screencapture -x "$GATE_SHOT" 2>/dev/null
  kill "$GPID" 2>/dev/null || true
  wait "$GPID" 2>/dev/null || true
  GATE_LINE="$(grep -m1 '\[wblaunch\] window' "$GATE_ERR" || true)"

  # ① 窗口没起来：这不是「没拦住」，截图拍到的是背后的桌面
  if ! grep -q 'visible=true' <<< "$GATE_LINE" ; then
    continue
  fi
  [ -f "$GATE_SHOT" ] || continue

  GATE_MEASURE="$(/usr/bin/python3 - "$GATE_SHOT" <<'PYEOF' 2>/dev/null
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
px = im.load()
tot = n = 0
band = 0
for y in range(0, H, 2):
    for x in range(0, W, 2):
        s = sum(px[x, y])
        tot += s; n += 1
        if 0.66 * H < y < 0.78 * H and W // 2 - 220 < x < W // 2 + 220 and s > 150:
            band += 1
print("%d %d" % (tot // max(n, 1), band))
PYEOF
)"
  GATE_MEAN="${GATE_MEASURE%% *}"
  GATE_BAND="${GATE_MEASURE##* }"
  if [ "${GATE_MEAN:-999}" -lt 20 ] && [ "${GATE_BAND:-0}" -ge 10 ]; then
    GATE_PASS=1
    rm -f "$GATE_SHOT"
    break
  fi
  # 失败留证（最后一轮的现场才值得留）
  cp "$GATE_SHOT" "/tmp/macctl_gate_FAIL_hold.png" 2>/dev/null || true
done
rm -f "$GATE_ERR" "$GATE_SHOT"
if [ "$SCENE_GATE" = "false" ]; then
  t_ok "场景闸门已关闭（开机一镜到底，2026-10-25 用户拍板）→ 不适用闸门拦截判定"
elif [ "$GATE_PASS" -eq 1 ]; then
  t_ok "闸门拦得住：第 6 秒仍停在暗幕（门限 8s，均值 ${GATE_MEAN} < 20）且提示可见（提示带 ${GATE_BAND} 亮像素）"
else
  t_fail "闸门没拦住（3 轮都没拍到暗幕）：第 6 秒均值=${GATE_MEAN:-未取到}（应 <20）提示带=${GATE_BAND:-0}px；现场保留在 /tmp/macctl_gate_FAIL_hold.png，debug：${GATE_LINE:-无}"
fi

# 20.13 真副作用·闸门放得开：默认 3 秒超时的动画在 15 秒时应已进入第二幕
#   （洗白后的暖白档案板，均值 25+）。与 20.12 合起来证明：
#   拦得住（不是定时器）也放得开（不是死等按键）。
#   ⚠ 同样带 visible=true 护栏：窗口没起时截图会拍到背后的 WorkBuddy
#     （也是亮的）—— 没有护栏会"假通过"，比失败更糟。
GATE_SHOT="/tmp/macctl_gate_selftest.png"
GATE_ERR="$(mktemp /tmp/macctl_gate.XXXXXX)"
# 同 20.12：跑前清场，防别人的 splash 窗口污染均值
pkill -f "wblaunch play" 2>/dev/null || true
sleep 0.5
# ⚠⚠ 2026-10-24 新增护栏：别的 App 占着**全屏 Space** 时，
#   screencapture 拍的是那个 Space，动画根本不在画面里 →
#   三条视觉断言（暗幕/旋转环/五角星）全部假失败，排查半天其实是环境。
#   这里提前识别并明确报「先退出全屏」，不再让视觉断言背锅。
FULLSCREEN_OWNER="$(./macctl scwindows 2>/dev/null \
  | /usr/bin/awk '/layer=0/ && /1440x900|1440x899/ {for(i=1;i<=NF;i++) if($i ~ /\[/){gsub(/\[|\]/,"",$i); if($i !~ /wblaunch|闪控/) print $i}}' \
  | head -1)"
if [ -n "$FULLSCREEN_OWNER" ]; then
  t_fail "有全屏窗口占用当前 Space（${FULLSCREEN_OWNER}）：动画会被挡在另一个 Space 里，视觉断言必然假失败。先退出全屏再跑。"
fi

WB_LAUNCH_MUTE=1 WB_LAUNCH_DEBUG=1 "$WBLAUNCH_BIN" play --no-launch --force \
  >/dev/null 2>"$GATE_ERR" &
GPID=$!
sleep 15
screencapture -x "$GATE_SHOT" 2>/dev/null
kill "$GPID" 2>/dev/null || true
wait "$GPID" 2>/dev/null || true
GATE_LINE="$(grep -m1 '\[wblaunch\] window' "$GATE_ERR" || true)"
rm -f "$GATE_ERR"
if ! grep -q 'visible=true' <<< "$GATE_LINE" ; then
  t_fail "默认闸门实测：splash 窗口没起来（debug：${GATE_LINE:-无输出}）—— 无法验证'放得开'"
elif [ -f "$GATE_SHOT" ]; then
  GATE_MEAN2="$(/usr/bin/python3 - "$GATE_SHOT" <<'PYEOF' 2>/dev/null
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
px = im.load()
tot = n = 0
for y in range(0, H, 2):
    for x in range(0, W, 2):
        tot += sum(px[x, y]); n += 1
print(tot // max(n, 1))
PYEOF
)"
  if [ "${GATE_MEAN2:-0}" -gt 25 ]; then
    t_ok "闸门放得开：15 秒已进入第二幕亮底板（均值 ${GATE_MEAN2} > 25）"
  else
    t_fail "15 秒还停在暗幕（均值 ${GATE_MEAN2} ≤ 25）—— 3 秒超时没放行，动画卡死了"
  fi
  rm -f "$GATE_SHOT"
else
  t_fail "默认闸门实测截图失败 —— 无法验证'放得开'"
fi

# 20.14 五角星几何：计算式顶点（STAR IIFE）+ R=25.5 + 第一幕必须用 svgStar
#   （2026-10-22 用户要求 logo 换五角星；R 的演进：20 太小 → 23.2（金色
#     折面版）→ 25.5（用户要求"比例大一点"）：星径占画布 85%，与旋转环
#     r=29.0 留 3.5 单位 HUD 紧配缝隙。
#     2026-10-22 深夜改版：几何从硬编码路径改为 IIFE 计算 —— 折面星
#     需要 outer/inner 顶点数组，硬编码字符串喂不动 15 个面）
if grep -q "var STAR = (function () {" "$SPLASH_JS" \
   && grep -q "R = 25.5" "$SPLASH_JS" \
   && grep -q "0.382" "$SPLASH_JS" \
   && grep -q "function svgStar" "$SPLASH_JS" \
   && grep -q "var star = svgStar('dsu-whale')" "$SPLASH_JS"; then
  t_ok "第一幕主标识是五角星（计算式顶点 / R=25.5 / blackStage 用 svgStar）"
else
  t_fail "第一幕五角星缺失或被换回鲸鱼（应见 STAR IIFE + svgStar）"
fi

# 20.15 折面结构 + 黑灰配色：15 面（10 臂半面 + 5 谷面）+ 帐篷棱线 + 石墨灰
#   （2026-10-22 用户参考图指定折面立体；再要求"黑灰配色，符合整个板块的
#     设计"—— 面板是近黑 #0b0b0c + 发丝线的工业档案风，石墨灰（冷调，
#     b 略大于 r）才和白色 HUD 是一家人，金色珠宝感不合群。
#     判据抓四样：① 两个面循环（v/a2 各 5 轮）② 棱线高光 #eef2f6
#     ③ 最亮臂面 #d3dbe4 与最暗臂面 #626c77 都在（明度阶就是立体感）
#     ④ 谷面 #383f47 比最暗臂面还沉一档（凹下去的底面））
if grep -q "for (var v = 0; v < 5; v++)" "$SPLASH_JS" \
   && grep -q "for (var a2 = 0; a2 < 5; a2++)" "$SPLASH_JS" \
   && grep -q "'#eef2f6'" "$SPLASH_JS" \
   && grep -q "'#d3dbe4'" "$SPLASH_JS" \
   && grep -q "'#626c77'" "$SPLASH_JS" \
   && grep -q "'#383f47'" "$SPLASH_JS" \
   && grep -q "dsu-star-body" "$SPLASH_JS"; then
  t_ok "五角星是黑灰折面立体星（15 面 + 帐篷棱线 + 石墨灰明度阶）"
else
  t_fail "折面结构或黑灰色板不完整（缺谷面/臂半面循环、棱线或石墨灰之一）—— 会退化成平面剪影或金色"
fi

# 20.16 旋转/倾斜动画的 CSS 要素：环 keyframes + fill-box + 200px
#   + 星体倾斜 keyframes（2026-10-22 深夜"立体一点"：星体挂 .dsu-star-body
#     做 7s ±6° rotateY，HUD 双环保持正圆锁死 —— 环是取景框，星是实体徽章）
#   显示尺寸演进：122 → 158 → 170 → 200（用户"等比例放大一点，太小了"）。
#   ⚠ 只改显示尺寸不动 viewBox —— 几何与像素判据都按比例走，最稳的"等比例"。
if grep -q "@keyframes dsu-orbit-spin" "$SPLASH_CSS" \
   && grep -q "transform-box: fill-box" "$SPLASH_CSS" \
   && grep -q "animation: dsu-orbit-spin 7s linear infinite" "$SPLASH_CSS" \
   && grep -q "width: 200px" "$SPLASH_CSS" \
   && grep -q "@keyframes dsu-star-bank" "$SPLASH_CSS" \
   && grep -q "animation: dsu-star-bank 7s ease-in-out infinite alternate" "$SPLASH_CSS"; then
  t_ok "旋转环 + 星体倾斜 CSS 到位（7s 环 + fill-box + 200px + 星体 6° 倾斜）"
else
  t_fail "CSS 缺失（orbit keyframes/fill-box/200px/star-bank 之一不在）—— 环会绕左上角公转或星不倾斜"
fi

# 20.17 真副作用·星大且在转 + 键盘焦点真的在窗上：一轮播放拿两帧（间隔 1.8s）
#   ⓪ 键盘判据 = wblaunch 自己报的三个开关：WB_LAUNCH_DEBUG=1 时它在窗口
#     makeKey 后 0.6s 打一行 key=/firstResp=/active=。这一项是**用户反馈的
#     真实 bug 的回归测试**：「按 enter 和空格都没用」。根因是三件事同时成立
#     才算数（canBecomeKey 默认 false 的 .borderless → 用 NSPanel 方案；
#     app 非前台 → NSApp.activate；firstResponder 没落到 WebView），
#     任何一条退回去，键事件都到不了页面。所以断言的是**三个 true 同时出现**，
#     而不是"窗口可见"这种看着对的弱判据。
#     同一轮播放里读 stderr，不额外起动画。
#   ① 旋转判据 = 帧差：双环在转、星体倾斜（±6°）→ 变化像素应 >1000 且
#     集中在**环半径附近**的环带（星体倾斜也让星内部像素变化，帧差只增不减）
#     ⚠ 环带半径跟着显示尺寸走：环 r=29.0/26.3 单位，scale=显示尺寸/60=3.33
#       CSS px/单位，截图 2x → r≈193/175px。170px 时代标过 100~170，
#       200px 后必须放宽到 120~215，否则真在转也会被判"没落在环带"。
#   ⚠⚠ 两帧都必须落在**第一幕黑幕时间窗**内（run() 时间线：t≈0.8s 星体
#     入场 → t≈5.7s 闸门到点开始洗白 → t≈6.0s 星体淡出到判据以下）。
#     2026-10-22 实测踩过：旧版 A 帧 sleep 5 / B 帧再 +1.8s，B 帧落在
#     洗白过场里，整屏变化 → 帧差 33 万（旋转判据被过场冒充通过）。
#     现在 A 帧 sleep 3.0 / B 帧 +1.8s，两帧都在幕内。
#   ② 尺寸判据 = 星体冷灰包围盒：⚠ 这个判据跟着星体改了六版，每版的
#      翻车原因都记在这里，防止第七次：
#      1) 通体白星·质心列连续段：阈值 380 贯通顶尖到底尖 ≈224px
#      2) 金星·质心列连续段：星有明有暗、外缘有凹口，质心稍偏列就
#         从凹口穿过（121px 误报）
#      3) 金星·行轮廓：背景粒子场每帧换位置，亮粒子把轮廓续到 395px；
#         加"每行≥3像素"护栏仍被密粒子场穿透（321px）
#      4) 金星·金色包围盒（r>80 且 r-b>40 且 g>0.62r）：闸门提示的流空线
#         是强调橙，松判据把它算进来撑到 648px —— 加 g>0.62r 排除后
#         实测 230×222 通过
#      5) 黑灰星·冷灰包围盒（(b-r)≥12 且 sum>200 且 r>45）：星体各面都是
#         冷调灰（b 略大于 r），白色 HUD 环/提示文字 b-r≈0 排除，强调橙
#         b-r<0 排除；行域限制 28%~62% 屏高（提示文字是 --dsu-muted 暖灰
#         #7a7873，其实天然被排除，行域是双保险）；每行/列 ≥8 像素防粒子。
#         实测 241×265 通过 —— 但**列向是全高扫描**，埋着两个雷：
#         · 菜单栏在 .screenSaver 层级之上永远可见，右上角状态图标有
#           蓝紫像素 (99,97,233)（b-r=134）过判据 → 包围盒被撑到 1562px
#         · 光带读取头（comet）是 cool(111,211,232) 0.72alpha 的 12~31px
#           大圆盘（b-r=121），沿贝塞尔横穿全屏，飘到边缘时一列能攒 8+ 像素
#      6) **现行**：三处补丁 ——
#         · 冷灰窄带 12≤(b-r)≤40：星体各面 b-r=15~21（高光近白 6~12 被
#           削但那是细线，包围盒由面色定），comet 121 / 菜单栏图标 134
#           全部落出带外；这是颜色特征分隔，比加 r>45（当初按浅色主题
#           算错 comet 的 r 通道）本质得多
#         · 列扫描也限制在行带内：包围盒本就是二维区域，行列同域才自洽
#         · 截图窗口前移（见 ①）：后期场景的浅蓝灰底子也过冷灰判据，
#           出了第一幕整屏都是污染
#   ✅ 设计值（R=25.5，viewBox 60，显示 200px@2x=400px，即 6.667px/单位）：
#      星体一尖朝上，水平最宽在左右侧尖（±18°）→ 2R·cos18° = 48.5 单位
#      ≈323px；垂直从顶尖到两侧底尖 → R(1+sin54°) = 46.1 单位 ≈307px。
#      ⚠ 曾经把设计值错算成"星径 51 单位 ≈289px"——五角星朝上时最下沿是
#      两个侧尖不是底尖，垂直跨度只有 1.809R。≥8 像素判据在五个尖上自然
#      削尾 ~20px → 预期 300~320 × 285~300，合格区间 275~350
#   ⚠ 同一轮播放的两帧截图同时供 ①旋转 与 ②尺寸 用（一轮 25 秒已经够久）。
#     唯独「尺寸」那条在量歪时会**重放一轮再量**（P11），理由见 star_round()。
STAR_SHOT_A="/tmp/macctl_star_a.png"
STAR_SHOT_B="/tmp/macctl_star_b.png"
STAR_DEBUG="/tmp/macctl_star_debug.log"
# ⚠⚠ 必须连 boot 实例一起杀（2026-10-25 P10 定位）：
#   登录时 com.lingtai.bootanim 拉起的 `wblaunch boot` 可能卡在「窗口透明、
#   页面 done 信号不来」的状态赖着不退。此时再起一个 play 实例 ——
#   两个 .screenSaver 级别全屏窗口互相压制，**新窗口根本不显示**，
#   截图拍到的是背后的 WorkBuddy（亮屏、彩色），于是
#   「旋转环帧差」和「五角星包围盒」两项一起假红（实测 bbox 被撑到 2384×569）。
#   原来只 `pkill -f "wblaunch play"` —— 杀不到 boot 泄露的那个，两项必红；
#   改成杀 "wblaunch" 后，同一时序（3.0s / +1.8s）实测
#   帧差 339654 / 环带 87323 / 包围盒 293×283，全绿。
#
# ── star_round：放一轮开场动画（第一幕内）→ 抓两帧 → 量一次 ────────────
#   抽成函数只为一件事：「五角星尺寸」那条断言要能**重试**（P11）。
#   节奏与原来逐字一致（杀 wblaunch → 0.8s → play → 3.0s 抓 A 帧 →
#   再 1.8s 抓 B 帧 → 收工），重试不另发明时序。
#   stdout 只有一行 8 个数字（帧差 环带 宽 高 4 个极端坐标），供上层 cut。
star_round() {
pkill -f "wblaunch" 2>/dev/null || true
sleep 0.8
WB_LAUNCH_DEBUG=1 WB_LAUNCH_MUTE=1 "$WBLAUNCH_BIN" play --no-launch --force \
  >/dev/null 2>"$STAR_DEBUG" &
spid=$!
sleep 3.0
screencapture -x "$STAR_SHOT_A" 2>/dev/null
sleep 1.8
screencapture -x "$STAR_SHOT_B" 2>/dev/null
kill "$spid" 2>/dev/null || true
wait "$spid" 2>/dev/null || true
/usr/bin/python3 - "$STAR_SHOT_A" "$STAR_SHOT_B" <<'PYEOF' 2>/dev/null
import sys, math
from PIL import Image
a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
W, H = a.size
pa, pb = a.load(), b.load()
# ── ① 旋转：帧差 ──
changed = []
for y in range(600, 1200):
    for x in range(1100, 1800):
        if abs(sum(pa[x, y]) - sum(pb[x, y])) > 90:
            changed.append((x, y))
mx = sum(p[0] for p in changed) / max(len(changed), 1)
my = sum(p[1] for p in changed) / max(len(changed), 1)
in_band = sum(1 for x, y in changed if 120 < math.hypot(x - mx, y - my) < 215)
# ── ② 尺寸：星体冷灰包围盒（行列同域：都限死在上部行带内）──
#    菜单栏在 .screenSaver 层级之上，列向扫全高会把右上角状态图标
#    （蓝紫 (99,97,233)，b-r=134）吃进来 —— 包围盒是二维区域，
#    行列必须同域；行带 28%~62% 屏高也不含菜单栏（y<30）。
def coolgray(px):
    r, g, b = px
    # 窄带：星体各面 b-r=15~21（R=25.5 石墨灰版）；上限 40 挡掉
    # comet 读取头（b-r=121）与菜单栏蓝紫图标（b-r=134）——
    # 它们是同一个 cool 色系，只有色度能把它们和星体的浅灰分开
    return 12 <= (b - r) <= 40 and (r + g + b) > 200 and r > 45
y0, y1 = int(H * 0.28), int(H * 0.62)
rows = [y for y in range(y0, y1)
        if sum(1 for x in range(W) if coolgray(pa[x, y])) >= 8]
cols = [x for x in range(W)
        if sum(1 for y in range(y0, y1) if coolgray(pa[x, y])) >= 8]
print("%d %d %d %d %d %d %d %d" % (len(changed), in_band, cols[-1] - cols[0], rows[-1] - rows[0], cols[0], cols[-1], rows[0], rows[-1]))
PYEOF
}

# ── 第 1 轮：⓪键盘 / ①旋转 / ②尺寸 三条断言共用这一轮的测量 ──
#    ① 和 ② 都会在量不达标时**重放一轮再量**（各自最多 3 次，见下方两个
#    重试块，P11/P13）；⓪ 永远用第一轮 —— 它读的是当轮的 debug 日志，
#    重放轮覆盖了也一样（判据是"窗口拿到键盘"，不是像素量）。
STAR_MEASURE="$(star_round)"
STAR_DIFF="${STAR_MEASURE%% *}"
STAR_BAND="$(echo "$STAR_MEASURE" | cut -d' ' -f2)"
STAR_W="$(echo "$STAR_MEASURE" | cut -d' ' -f3)"
STAR_H="$(echo "$STAR_MEASURE" | cut -d' ' -f4)"
STAR_EXT="$(echo "$STAR_MEASURE" | cut -d' ' -f5-8)"
# ⚠ 截图**先别删**：断言失败时它就是唯一现场（P10 加）
# ── ⓪ 键盘焦点：三个开关必须同时为 true（用户原始 bug 的回归测试）──
STAR_WIN="$(tr -d '\n' < "$STAR_DEBUG" 2>/dev/null | sed -n 's/.*\[wblaunch\] window \([^k]*\)key=\([a-z]*\).*firstResp=\([a-z]*\).*active=\([a-z]*\).*/\1|\2|\3|\4/p')"
STAR_KEY="$(echo "$STAR_WIN" | cut -d'|' -f2)"
STAR_RESP="$(echo "$STAR_WIN" | cut -d'|' -f3)"
STAR_ACT="$(echo "$STAR_WIN" | cut -d'|' -f4)"
STAR_WINFO="$(echo "$STAR_WIN" | cut -d'|' -f1)"
if [ "$STAR_KEY" = "true" ] && [ "$STAR_RESP" = "true" ] && [ "$STAR_ACT" = "true" ]; then
  t_ok "开场窗口拿到了键盘（key / firstResponder=WebView / app 前台 三项全真）—— Space·Enter 能进到页面"
elif [ -z "$STAR_WIN" ]; then
  t_fail "没拿到 wblaunch 的窗口自检行（WB_LAUNCH_DEBUG 输出丢了）—— 键盘链路无从验证"
else
  t_fail "开场窗口键盘链路断了：key=$STAR_KEY firstResp=$STAR_RESP active=${STAR_ACT}（三项须全 true）—— 用户按 Space/Enter 会没反应"
fi
# ── ① 旋转：帧差/环带，最多 3 次，任一次达标即算通过（P13）────────────
#   现状（P13 之前）：这条**没有重试**，十跑三四红，同一份代码复跑就绿。
#   根因与 ② 尺寸那条同源 —— 不是功能坏了，是**测量时序**：
#   机器负载高（正在编译/刚开机）时 screencapture 拍到的是洗白过场，
#   两帧几乎一样（甚至整屏一样），帧差与环带一起塌下来。
#   对策照 star_round()（P11 已验证有效）的做法：量不达标就按同一节奏
#   （杀 wblaunch → 0.8s → play → 3.0s 抓 A 帧 → +1.8s 抓 B 帧）
#   再放一轮、再量一次，最多 3 次，任一次达标即通过。
#   ⚠ 阈值 >1000 / >800 一个字没改：放宽的是**测量的机会**，不是标准。
#   ⚠ 失败信息必须带三次的数值 —— 一眼分得清「真坏了」和「环境慢」。
#   ⚠ 重试轮顺带刷新 STAR_W/H/EXT：那是同一轮测出来的数，给 ② 用最省时间
#     （② 若仍不合格，下面还有它自己的重试循环）。
star_band_ok() {  # star_band_ok <帧差> <环带>
  [ "${1:-0}" -gt 1000 ] && [ "${2:-0}" -gt 800 ]
}
STAR_BAND_LOG="${STAR_DIFF:-?}/${STAR_BAND:-?}"   # 每次量到的「帧差/环带」，按次数用 / 分隔
STAR_BAND_TRIES=1
STAR_BAND_PASS=0     # ① 的结论位：后面「删不删现场截图」要用它，不能靠最后一次的数
while ! star_band_ok "${STAR_DIFF:-0}" "${STAR_BAND:-0}" && [ "$STAR_BAND_TRIES" -lt 3 ]; do
  STAR_BAND_TRIES=$((STAR_BAND_TRIES + 1))
  STAR_MEASURE="$(star_round)"
  STAR_DIFF="${STAR_MEASURE%% *}"
  STAR_BAND="$(echo "$STAR_MEASURE" | cut -d' ' -f2)"
  STAR_W="$(echo "$STAR_MEASURE" | cut -d' ' -f3)"
  STAR_H="$(echo "$STAR_MEASURE" | cut -d' ' -f4)"
  STAR_EXT="$(echo "$STAR_MEASURE" | cut -d' ' -f5-8)"
  STAR_BAND_LOG="${STAR_BAND_LOG} / ${STAR_DIFF:-?}/${STAR_BAND:-?}"
done
if star_band_ok "${STAR_DIFF:-0}" "${STAR_BAND:-0}"; then
  STAR_BAND_PASS=1
  if [ "$STAR_BAND_TRIES" -gt 1 ]; then
    t_ok "五角星周围确实在转：帧间变化 ${STAR_DIFF}px，其中 ${STAR_BAND}px 落在环带（120~215px）（第 ${STAR_BAND_TRIES} 次量到；各次 帧差/环带 = ${STAR_BAND_LOG} —— 首量空转是截图时序漂移，非功能问题）"
  else
    t_ok "五角星周围确实在转：帧间变化 ${STAR_DIFF}px，其中 ${STAR_BAND}px 落在环带（120~215px）"
  fi
else
  t_fail "旋转环没动或动静不对：${STAR_BAND_TRIES} 次「帧差/环带」依次为 ${STAR_BAND_LOG}（应 >1000/>800，阈值未放宽）—— 三次全不达标多半是真坏了：transform-box/动画没生效；若只有某次离谱地小（如 帧差<100）则更像截图没进第一幕（现场 ${STAR_SHOT_A} / ${STAR_SHOT_B}；debug ${STAR_DEBUG}）"
fi
# ── ② 尺寸：最多量 3 次，任一次落在 275~350 就算通过（P11）────────────
#   现象：十跑五六红，报错量到 2384×290（宽被撑到半屏），同一份代码复跑就绿。
#   宽 2384 ≈ 半个屏幕的列全被算进包围盒 → 抓到的根本不是第一幕：机器
#   负载高（正在编译）时 screencapture 偏到洗白过场/后期浅底场景，那里
#   整屏都是冷灰，包围盒没有意义。**这是测量时序问题，不是功能问题。**
#   对策：量歪了就按同一节奏（star_round：杀实例→0.8s→play→3.0s 抓帧）
#   再放一轮、再量一次，最多 3 次；三次都不达标才算失败，并把三次的
#   包围盒全写进失败信息 —— 一眼分得清「真坏了」和「环境慢」。
#   ⚠ 阈值 275~350 一个字没改：放宽的是**测量的机会**，不是标准。
#   ⚠ 只在第一轮量歪时才多花时间；正常一路绿仍是 1 轮≈25s。
star_box_ok() {  # star_box_ok <宽> <高> —— 275~350 双向闭区间
  [ "${1:-0}" -ge 275 ] && [ "${1:-0}" -le 350 ] \
    && [ "${2:-0}" -ge 275 ] && [ "${2:-0}" -le 350 ]
}
STAR_BOX_LOG="${STAR_W:-?}×${STAR_H:-?}"   # 每次量到的包围盒，按次数用 / 分隔
STAR_TRIES=1
while ! star_box_ok "${STAR_W:-0}" "${STAR_H:-0}" && [ "$STAR_TRIES" -lt 3 ]; do
  STAR_TRIES=$((STAR_TRIES + 1))
  STAR_MEASURE="$(star_round)"
  # 重试轮只认尺寸三个字段：帧差/环带属于 ①，已经用第一轮判过了
  STAR_W="$(echo "$STAR_MEASURE" | cut -d' ' -f3)"
  STAR_H="$(echo "$STAR_MEASURE" | cut -d' ' -f4)"
  STAR_EXT="$(echo "$STAR_MEASURE" | cut -d' ' -f5-8)"
  STAR_BOX_LOG="${STAR_BOX_LOG} / ${STAR_W:-?}×${STAR_H:-?}"
done
if star_box_ok "${STAR_W:-0}" "${STAR_H:-0}"; then
  STAR_DESIGN="2x 图，200px 显示尺寸设计值 323×307，削尾后 ~305×292"
  if [ "$STAR_TRIES" -gt 1 ]; then
    t_ok "五角星够大：冷灰包围盒 ${STAR_W}×${STAR_H}px（第 ${STAR_TRIES} 次量到；各次 ${STAR_BOX_LOG} —— 首量歪是截图时序漂移，非功能问题）${STAR_DESIGN}"
  else
    t_ok "五角星够大：冷灰包围盒 ${STAR_W}×${STAR_H}px（第 1 次量到）${STAR_DESIGN}"
  fi
else
  t_fail "五角星尺寸不对：${STAR_TRIES} 次包围盒依次为 ${STAR_BOX_LOG}（宽高应 275~350，阈值未放宽），最后一次极端坐标 cols/rows=${STAR_EXT:-无}—— 三次全歪多半是真坏了：显示尺寸被改回 170px、黑灰星退成了平面、或菜单栏/读取头混进了判据；若只有某次离谱（如宽>1000）则更像截图没进第一幕（现场 ${STAR_SHOT_A}；debug ${STAR_DEBUG}）"
fi

# 两项视觉断言都过 → 删现场；任一失败 → 留着给人看（不再"删完才报错"）
# ⚠ 判据用 PASS 结论位、不用最后一次的数值：① 允许重试后，"最后一次"可能是
#   ② 的重试轮（只量尺寸），数值跟 ① 的结论已经不是一回事了。
if [ "${STAR_BAND_PASS:-0}" = "1" ] && star_box_ok "${STAR_W:-0}" "${STAR_H:-0}"; then
  rm -f "$STAR_SHOT_A" "$STAR_SHOT_B" "$STAR_DEBUG"
fi

# ══ 21. 工件B 端到端（放最后：会真的操作 WorkBuddy 窗口）═══════════
# 21.1 真跑：面板真实路径（建面板 → show 拿激活权 → 降层 → 转交 → 发送）
# ⚠ 载荷必须自带「别再转交」：这条自检的正文和用户的真实指令长得一模一样，
#   接收端会照着再跑一次自检 → 再转交 → 无限套娃（每次约 4 秒、多一个会话）。
#   所以尾巴上写死回执要求，让接收端停在「回一声」而不是继续跑。
HD_TXT="闪控自检 · 转交链路 $(date +%H%M%S)｜回执 OK 即可，勿再转交"
HD_OUT="$("$DIR/flash" --selftest-handoff "$HD_TXT" 2>/dev/null | tail -1)"
case "$HD_OUT" in
  *"已转交"*|*'"ok":true'*) t_ok "转交端到端成功（新建任务→粘贴→选技能→发送，零人工）：$HD_OUT" ;;
  *) t_fail "转交端到端失败：$HD_OUT —— WorkBuddy 界面结构变了？辅助功能授权掉了？" ;;
esac


# ══ 22. 「用不了」的三条真根因 + 交付件（2026-10-22 深夜）════════════
#
# 用户原话：「我现在无法使用快捷键启动闪控」。查下来是三件事叠在一起：
#   ① 面板能弹出但 App 没激活 / 窗口不是 key → 打字全落到下面那个 App（用户选 c）
#   ② 守护进程没被 launchd 加载（本会话）
#   ③ 转交出去的 agent 能动整个桌面（没有边界）
# 这一组守的就是这三条 + 一条命令自检能不能用。

# 22.1 面板激活顺序：必须**先同步激活再 makeKey**，并在激活后补一次焦点
if grep -q "NSApp.activate(ignoringOtherApps: true)" "$FLASH_SW" \
   && grep -q "makeKey()" "$FLASH_SW" \
   && grep -q "note: \"show key=" "$FLASH_SW"; then
  t_ok "面板唤起时同步激活 + 补焦点，并把 key/active/firstResponder 写进状态文件（坏了能自证）"
else
  t_fail "面板激活顺序或焦点自证缺失 —— 会退化成「面板出来了，打字没反应」"
fi

# 22.2 热键双通道（Carbon 只认物理按键，合成事件到不了它）
if grep -q "installKeyTap" "$FLASH_SW" && grep -q "cgSessionEventTap" "$FLASH_SW" \
   && grep -q "tapDisabledByTimeout" "$FLASH_SW" && grep -q "/tmp/flash.hotkey" "$FLASH_SW"; then
  t_ok "热键双通道在位（Carbon + CGEventTap + 停用自愈 + 状态落盘）"
else
  t_fail "热键只剩 Carbon 一条腿 —— 合成按键测不了，坏了也没法自证"
fi

# 22.3 macctl 键码表：字母必须是真 ANSI 键码（A=0 / V=9 / B=11）
if grep -q "ANSI_KEYCODE" "$DIR/macctl.swift" \
   && grep -q '"v": 9' "$DIR/macctl.swift" && grep -q '"b": 11' "$DIR/macctl.swift"; then
  t_ok "macctl 键码表是真实 ANSI 表（曾经 A→1/B→2，导致 ⌘V 发成 ⌘6，粘贴从未生效）"
else
  t_fail "macctl 键码表错位 —— 粘贴会静默失效（发出去的是别的键）"
fi

# 22.4 路由：复杂句不接、否定句不误判、简单句照接（真跑，不是 grep）
ROUTE_COMPLEX="$("$DIR/route.sh" "帮我写三句话的项目周报，不要操作桌面" 2>/dev/null | head -1)"
ROUTE_SIMPLE="$("$DIR/route.sh" "打开计算器" 2>/dev/null | head -1)"
case "$ROUTE_COMPLEX" in
  *'"ok":false'*) R1=PASS ;; *) R1=FAIL ;;
esac
case "$ROUTE_SIMPLE" in
  *'"ok":true'*) R2=PASS ;; *) R2=FAIL ;;
esac
if [ "$R1" = PASS ] && [ "$R2" = PASS ]; then
  t_ok "路由：复杂句（含「不要操作桌面」）不再被当成「查看桌面」，简单句照旧接住"
else
  t_fail "路由判定回归：复杂句=${R1} （应 PASS）简单句=${R2} （应 PASS）"
fi

# 22.5 转交白名单：策略文件 + 自动附加边界
if [ -f "$DIR/handoff-policy.json" ] && grep -q "handoffBoundary" "$HANDOFF_SW"; then
  t_ok "转交边界在位（handoff-policy.json 白名单 + 正文自动附加，接收端知道不能越界）"
else
  t_fail "转交没有边界 —— 转出去的 agent 能动整个桌面（实测它打开过「下载」）"
fi

# 22.6 一条命令自检：七段都要有输出，否则「用不了」还是得靠猜
DIAG_OUT="$("$DIR/flashctl.sh" diagnose 2>&1)"
DIAG_HITS=0
for k in "① 程序" "③ 开机自启" "④ 常驻进程" "⑤ 辅助功能" "⑥ 路由" "⑦ 截图目录"; do
  grep -q "$k" <<< "$DIAG_OUT" && DIAG_HITS=$((DIAG_HITS+1))
done
if [ "$DIAG_HITS" -ge 6 ]; then
  t_ok "flashctl diagnose 一条命令给出七层状态（程序/自启/进程/热键/授权/路由/落盘）"
else
  t_fail "diagnose 输出缺段（命中 $DIAG_HITS/6）—— 出问题时用户还是不知道该看哪"
fi

# 22.7 可双击的 .app 外壳（登录项只收 .app，裸二进制进不去）
if [ -f "$DIR/灵台智枢.app/Contents/Info.plist" ] \
   && grep -q "LSUIElement" "$DIR/灵台智枢.app/Contents/Info.plist"; then
  t_ok "灵台智枢.app 外壳在位（可双击启动、可进登录项；壳里 exec 原二进制，不换 TCC 身份）"
else
  t_fail "缺 .app 外壳 —— 用户只能靠命令行启动，登录项也选不到它"
fi

# ══ 23. 别再弹授权框（2026-10-23 用户投诉）════════════════════════════
#
# 用户原话：「闪控每次启动都会询问我是否允许查看桌面，我明明已经授权了」。
# 根因有两个，且都不是"授权没记住"：
#   ① 面板每次唤起都跑自检，而自检会列 ~/Desktop/闪控 → Desktop 是 TCC
#      保护目录 → 每次唤起都触发一次授权框；
#   ② 我们曾在启动时主动调 AXIsProcessTrustedWithOptions(prompt) → 每次
#      启动都弹"想使用辅助功能"。
# 这一组守两件事：启动路径不许碰受保护目录；授权框只许人工触发。

# 23.1 启动自检不许列桌面目录
if grep -q "s.mediaCount = -1" "$FLASH_ARCH" \
   && ! grep -q "contentsOfDirectory(atPath: dir)" "$FLASH_ARCH"; then
  t_ok "启动自检不再读 ~/Desktop（这是「每次启动都问要桌面权限」的直接原因）"
else
  t_fail "启动路径仍在访问桌面目录 —— 每次唤起都会弹一次授权框"
fi

# 23.2 辅助功能授权框必须只由环境变量触发（不许自动弹）
if grep -q 'SHANKONG_AX_PROMPT' "$FLASH_SW"; then
  t_ok "辅助功能授权框只在 SHANKONG_AX_PROMPT=1 时弹（平时绝不骚扰）"
else
  t_fail "启动流程会主动弹辅助功能授权框 —— 用户每次启动都被问一次"
fi

# 23.3 签名必须绑「证书根」而不是 cdhash（否则重编译一次授权就作废）
REQ="$(codesign -d -r- "$DIR/flash" 2>/dev/null | tr -d '\n')"
case "$REQ" in
  *"certificate root = H"*) SIGN_OK=1 ;;
  *) SIGN_OK=0 ;;
esac
if [ "$SIGN_OK" = "1" ]; then
  t_ok "flash 用固定证书签名（指定要求=identifier+证书根，重编译不作废授权）"
else
  t_fail "flash 是 ad-hoc 签名（指定要求=cdhash）—— 每次重编译都要用户重新授权"
fi

# 23.4 运行实例必须真是「灵台智枢.app」（不是被 shell 壳 exec 掉的裸二进制）
#   ⚠ 这个坑很隐蔽：bundle 里留着旧版的 Contents/MacOS/run 时，LaunchServices
#   会执行 run → run 再 exec 外部裸二进制 → Bundle.main 变 nil → TCC 看到的是
#   "裸二进制"，用户把 app 拖进辅助功能也永远不生效（实测 ax 一直 0）。
if [ -f "$DIR/灵台智枢.app/Contents/MacOS/run" ]; then
  t_fail "灵台智枢.app 里还留着旧的 shell 壳 run —— 会把进程 exec 成裸二进制，app 授权永远不生效"
elif [ -x "$DIR/灵台智枢.app/Contents/MacOS/flash" ]; then
  t_ok "灵台智枢.app 的主可执行是它自己的二进制副本（bundle 身份成立，TCC 授权可绑定）"
else
  t_fail "灵台智枢.app 缺主可执行"
fi

# 23.5 热键必须双通道 + 备用键，且 plist 必须 KeepAlive
#   用户原话「时好时坏，老出问题」。真因两条：
#     ① macOS 把 ⌃⌥Space 绑给了「选择下一个输入法」，系统级快捷键抢在前面；
#     ② KeepAlive=false，进程一死就没人拉起。
# 主键必须是 ⌃⌥S（键码 1），不能再用 ⌃⌥Space —— 后者被系统「选择下一个输入法」占用，
# 是「时好时坏」的真因（用户 2026-10-23 拍板换键）。
# 用户最终拍板用 ⌃⌥Space（2026-10-23），前提是系统那条快捷键已被让出。
# 断言要跟着变：主键=49，且 system key 61 处于 disabled。
if grep -q "let DEFAULT_KEY: UInt32 = 49" "$FLASH_SW"; then
  if /usr/bin/plutil -extract AppleSymbolicHotKeys.61.enabled raw -o - \
       "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist" 2>/dev/null | grep -q "false"; then
    t_ok "主热键 ⌃⌥Space，且系统「选择下一个输入法」已让出该组合"
  else
    t_fail "主热键是 ⌃⌥Space，但系统仍占着它（跑 flashctl.sh ime-key off）—— 会时好时坏"
  fi
else
  t_fail "主热键不是 ⌃⌥Space（用户选定），请确认 DEFAULT_KEY=49"
fi
# KeepAlive 现在写成 dict（只在异常退出时拉起，见 flashctl.sh 注释），
# 所以不能只认 "=> 1"。
if /usr/bin/plutil -p "$PLIST" 2>/dev/null | grep -A3 '"KeepAlive"' | grep -qE 'SuccessfulExit|=> 1'; then
  t_ok "LaunchAgent 配了 KeepAlive（异常退出会被 launchd 拉起）"
else
  t_fail "plist 没配 KeepAlive —— 闪控被杀掉后热键会一直失效"
fi

# ── 总结 ────────────────────────────────────────────────────────
say ""
say "=== 结果 ==="
say "通过 $PASS 项，失败 $FAIL 项"
if [ "$FAIL" -eq 0 ]; then
  say "✅ 全部通过"
  exit 0
else
  say "❌ 有 $FAIL 项失败"
  exit 1
fi
