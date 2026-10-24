#!/bin/bash
# 闪控 common.sh — 所有闪控脚本的公共能力层
#
# 职责（规格书 §6.5）：
#   · JSON 输出构造（统一契约）
#   · 审计日志（SR-3）
#   · 黑名单前置拦截（SR-1）
#   · L1 确认闸（SR-5）
#   · 权限预检（FR-8）
#   · 静音守卫（本项目附加硬要求：任何测试不得发出声音）
#   · 重试封装（FR-7）
#
# 用法：脚本 source 本文件，不要直接执行。
#
# ⚠ 性能基线（2026-10-21 真机实测，D-014）：
#   python3 冷启动 = **50ms**，不是之前估的 240ms。
#   一次 emit 要拼 7 个字段，旧实现对**每个字段**调一次 python3 → 350ms 纯开销。
#   加上 precheck_env / audit / propose 各一次，全脚本 python3 开销约 500-700ms，
#   而 open_file 的业务逻辑本身只有 1.5s。**JSON 拼装一度是最大单项开销。**
#   → json_escape 已改为 bash 原生实现（4.6ms，比 python 快 10 倍）。

set -uo pipefail

# ── 路径 ─────────────────────────────────────────────────────────────
# ⚠ 用 ${BASH_SOURCE[0]:-} 兜底：common.sh 被 `source` 时若在 `set -u` 环境下
#   且没有 BASH_SOURCE，会直接报 "parameter not set" 中断脚本。
_SELF="${BASH_SOURCE[0]:-$0}"
SKILL_DIR="$(cd "$(dirname "$_SELF")/.." && pwd)"
PARSER_PY="$(cd "$(dirname "$_SELF")" && pwd)/parsers.py"
MACCTL="${MACCTL_PATH:-$HOME/.workbuddy/skills/mac-control/scripts/macctl}"
LOG_DIR="${SHANKONG_LOG_DIR:-$SKILL_DIR/logs}"
PREF_FILE="$SKILL_DIR/preferences.md"
PROPOSALS="$SKILL_DIR/proposals.jsonl"

mkdir -p "$LOG_DIR" 2>/dev/null || true

# ── 动作分级（规格书 §5.1）─────────────────────────────────────────
LEVEL_L0="L0"   # 可逆、本地、无外部影响 → 直接执行
LEVEL_L1="L1"   # 不可逆或对外可见 → 先确认
LEVEL_L2="L2"   # 涉密钥/资金/系统安全 → 直接停手

# ── 错误码（规格书 FR-6）───────────────────────────────────────────
ERR_APP_NOT_FOUND="APP_NOT_FOUND"
ERR_ELEMENT_NOT_FOUND="ELEMENT_NOT_FOUND"
ERR_PERMISSION_DENIED="PERMISSION_DENIED"
ERR_TIMEOUT="TIMEOUT"
ERR_BLACKLISTED="BLACKLISTED"
ERR_NEED_HUMAN="NEED_HUMAN"
ERR_AMBIGUOUS="AMBIGUOUS"
ERR_OK=""

# ── 计时 ─────────────────────────────────────────────────────────────
# ── 动态脚本库（library/）──────────────────────────────────────
# 用途：表外意图不必等人工开发。模型可用 library/scaffold.sh 现场生成脚本，
#   跑通后由 lib.sh 登记进 INDEX.json，下次同类问题直接命中、失败则原地改进。
#
# LIB_DIR 存放库脚本与索引；lib_record 把每次调用结果追加到 usage.jsonl。
LIB_DIR="$SKILL_DIR/library"
LIB_INDEX="$LIB_DIR/INDEX.json"
LIB_USAGE="$LIB_DIR/usage.jsonl"

# lib_record <id> <ok|fail> [evidence]  → 追加一条调用记录
# ⚠ 只做「追加」不做「读改写」：单次开销 ~5ms（纯 printf + bash 原生转义），
#   不用起 python3。统计口径由 lib.sh stats 在读的时候聚合。
lib_record() {
  local id="$1" result="$2" evidence="${3:-}"
  mkdir -p "$LIB_DIR" 2>/dev/null || true
  printf '{"ts":"%s","id":"%s","result":"%s","evidence":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(json_escape "$id")" \
    "$(json_escape "$result")" \
    "$(json_escape "$evidence")" >>"$LIB_USAGE" 2>/dev/null
  return 0
}

T0=$(python3 -c 'import time;print(int(time.time()*1000))')

elapsed_ms() {
  python3 -c "import time,sys;print(max(0,int(time.time()*1000)-int(sys.argv[1])))" "$T0"
}

# ── JSON 构造 ───────────────────────────────────────────────────────
# json_escape <string>  →  转义为合法 JSON 字符串（不含外层引号）
json_escape() {
  # ⚠ bash 3.2 原生实现（D-014）。曾用 python3 json.dumps，实测 49.4ms/次，
  #   而一次 emit 有 7+ 个字段要转义 → 350ms 纯开销。现为 4.6ms/次。
  # ⚠ 顺序不能颠倒：必须先转义反斜杠，否则后面转义出的 \" 会被二次转义。
  # ⚠ 实测 7 个用例往返一致（含中文/双引号/反斜杠/换行/制表符/嵌套 JSON/空串）。
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# json_obj <k1> <v1> <k2> <v2> ...  →  JSON 对象（值均为字符串，自动转义并加引号）
json_obj() {
  local out="{" first=1 k v
  while [ $# -ge 2 ]; do
    k="$1"; v="$2"; shift 2
    [ $first -eq 1 ] && first=0 || out="$out,"
    # ⚠ 字段名跳过 json_escape（D-014）：字段名都是脚本里的固定字面量
    #   （ok/action/target/...），不含引号反斜杠。转义它是纯浪费。
    #   如果将来要支持动态字段名，必须去掉这个优化。
    out="$out\"$k\":\"$(json_escape "$v")\""
  done
  printf '%s}' "$out"
}

# json_raw <k1> <jsonval1> <k2> <jsonval2> ...  →  JSON 对象
#   ⚠ 值必须是「已带引号的 JSON 字符串」或「合法 JSON 字面量」
#   用 json_str 把纯字符串转成带引号的 JSON 字符串片段
json_str() { printf '"%s"' "$(json_escape "$1")"; }

# json_raw <k1> <jsonval1> <k2> <jsonval2> ...  →  JSON 对象（值已是合法 JSON 片段）
json_raw() {
  local out="{" first=1 k v
  while [ $# -ge 2 ]; do
    k="$1"; v="$2"; shift 2
    [ $first -eq 1 ] && first=0 || out="$out,"
    out="$out\"$k\":$v"     # 字段名同样跳过转义，理由见 json_obj
  done
  printf '%s}' "$out"
}

# ── 统一输出契约（规格书 FR-6）──────────────────────────────────────
# emit <ok:0|1> <action> <target> <need_confirm:0|1> <evidence> <error_code> [extra_k extra_v ...]
#
# ⚠ 约定：extra 字段的「值」必须是合法 JSON 片段。
#    纯字符串请用 json_str "<值>"（自动加引号+转义），数组/数字用原生写法。
#    例：emit 1 "a" "b" 0 "c" "" "candidates" "[$(json_str "$x")]"
# 永远输出且只输出一个合法 JSON 对象。
emit() {
  local ok="$1" action="$2" target="$3" need_confirm="$4" evidence="$5" error_code="$6"
  shift 6
  local dur; dur="$(elapsed_ms)"
  local base
  base="$(json_raw \
    "ok" "$([ "$ok" = "1" ] && echo true || echo false)" \
    "action" "$(json_str "$action")" \
    "target" "$(json_str "$target")" \
    "need_confirm" "$([ "$need_confirm" = "1" ] && echo true || echo false)" \
    "evidence" "$(json_str "$evidence")" \
    "duration_ms" "$dur" \
    "error_code" "$([ -n "$error_code" ] && json_str "$error_code" || echo null)")"
  if [ $# -gt 0 ]; then
    # 追加额外字段（k v 交替）
    # v 若已是合法 JSON 片段（对象/数组/数字/true/false/null）则原样嵌入；
    # 否则按纯字符串处理（自动加引号+转义）——防止调用方漏写 json_str 产出坏 JSON
    local extra="" first=1 k v
    while [ $# -ge 2 ]; do
      k="$1"; v="$2"; shift 2
      [ $first -eq 1 ] && first=0 || extra="$extra,"
      if [ "${v:0:1}" = '"' ]; then
        # 已是 json_str 的输出（含引号的 JSON 字符串）→ 原样嵌入
        extra="$extra\"$(json_escape "$k")\":$v"
      elif printf '%s' "$v" | python3 -c 'import json,sys
try: json.loads(sys.stdin.read())
except Exception: sys.exit(1)' 2>/dev/null; then
        # 合法的 JSON 字面量（数组/数字/true/false/null）→ 原样嵌入
        extra="$extra\"$(json_escape "$k")\":$v"
      else
        # 纯字符串 → 自动加引号+转义
        extra="$extra\"$(json_escape "$k")\":\"$(json_escape "$v")\""
      fi
    done
    base="${base%\}},$extra}"
  fi
  printf '%s\n' "$base"
}

# ── 审计日志（规格书 SR-3）──────────────────────────────────────────
# audit <intent> <script> <level> <result:ok|fail> <error_code> <evidence> [params_json]
audit() {
  local intent="$1" script="$2" level="$3" result="$4" code="$5" evidence="$6" params="${7:-{}}"
  local logf="$LOG_DIR/$(date +%Y-%m-%d).jsonl"
  python3 - "$logf" "$intent" "$script" "$level" "$result" "$code" "$evidence" "$params" <<'PY'
import json,sys,datetime
logf,intent,script,level,result,code,evidence,params = sys.argv[1:9]
rec = {
  "ts": datetime.datetime.now().isoformat(timespec="milliseconds"),
  "intent": intent, "script": script, "level": level,
  "result": result, "error_code": code or None, "evidence": evidence,
  "params": json.loads(params) if params else {},
}
try:
    with open(logf,"a",encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False)+"\n")
except Exception:
    pass
PY
}

# ── 未命中意图沉淀池（规格书 §7-③）──────────────────────────────────
propose() {
  local intent="$1" reason="${2:-未命中}"
  python3 - "$PROPOSALS" "$intent" "$reason" <<'PY'
import json,sys,datetime
path,intent,reason = sys.argv[1:4]
rec = {"ts": datetime.datetime.now().isoformat(timespec="seconds"),
       "intent": intent, "reason": reason, "status": "pending"}
try:
    with open(path,"a",encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False)+"\n")
except Exception:
    pass
PY
}

# ── 静音守卫（本项目硬要求：测试绝不发声）────────────────────────────
# 记录原始静音状态 → 强制静音 → 提供恢复
_SILENCE_ORIG=""
_SILENCE_ORIG_SET=0
_SILENCE_VOL_ORIG=""
silence_guard_on() {
  [ "$_SILENCE_ORIG_SET" = "1" ] && return 0
  local v vol
  v="$($MACCTL volume --json 2>/dev/null | python3 -c 'import json,sys
try: print("1" if json.load(sys.stdin).get("muted") else "0")
except Exception: print("0")' 2>/dev/null)"
  # ⚠ 实测踩过：守卫原本**只记静音标志、不记音量数值**。
  #   而自检里会跑 `volume --set` / `--mute toggle` 这类会改数值的测试，
  #   守卫结束时只把静音标志恢复回去，**音量数值被永久留在测试值上**。
  #   症状：跑完一次自检，用户电脑突然没声音了，而且没有任何提示。
  #   → 守卫必须同时快照「静音标志 + 音量数值」，缺一不可。
  vol="$($MACCTL volume --json 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("volume",-1))
except Exception: print(-1)' 2>/dev/null)"
  _SILENCE_ORIG="${v:-0}"
  _SILENCE_VOL_ORIG="$vol"
  _SILENCE_ORIG_SET=1
  $MACCTL volume --mute on >/dev/null 2>&1
}

silence_guard_restore() {
  [ "$_SILENCE_ORIG_SET" = "1" ] || return 0
  # 先恢复音量数值（测试期间可能被 --set 改过），再恢复静音标志
  if [ -n "$_SILENCE_VOL_ORIG" ] && [ "$_SILENCE_VOL_ORIG" -ge 0 ] 2>/dev/null; then
    $MACCTL volume --set "$_SILENCE_VOL_ORIG" >/dev/null 2>&1
  fi
  if [ "$_SILENCE_ORIG" = "0" ]; then
    $MACCTL volume --mute off >/dev/null 2>&1
  fi
  _SILENCE_ORIG=""
  _SILENCE_VOL_ORIG=""
  _SILENCE_ORIG_SET=0
}

# ── 电脑控制锁（多 AI 不打架）────────────────────────────────────
# 所有会合成鼠标/键盘/AX 的脚本，动手前必须先拿锁；拿不到就诚实返回 BUSY。
# 锁由 ~/.tiangong/bin/tg-lock 管理；SHANKONG_NO_LOCK=1 可临时旁路（仅测试）。
TIANGONG_LOCK="${TIANGONG_LOCK:-$HOME/.tiangong/bin/tg-lock}"
LOCK_OWNER=""

lock_guard() {
  local owner="${1:-shankong:$$}" task="${2:-gui}"
  [ "${SHANKONG_NO_LOCK:-0}" = "1" ] && return 0
  [ -x "$TIANGONG_LOCK" ] || return 0
  if "$TIANGONG_LOCK" acquire --owner "$owner" --task "$task" --ttl "${SHANKONG_LOCK_TTL:-120}" --wait "${SHANKONG_LOCK_WAIT:-30}" --pid $$ >/dev/null 2>&1; then
    LOCK_OWNER="$owner"
    return 0
  fi
  return 1
}

release_lock() {
  [ -n "${LOCK_OWNER:-}" ] || return 0
  [ -x "$TIANGONG_LOCK" ] || { LOCK_OWNER=""; return 0; }
  "$TIANGONG_LOCK" release --owner "$LOCK_OWNER" >/dev/null 2>&1 || true
  LOCK_OWNER=""
}

lock_guard_or_exit() {
  local action="$1" target="$2" task="$3" owner="${4:-shankong:$$}"
  if ! lock_guard "$owner" "$task"; then
    audit "${action}:${target}" "${BASH_SOURCE[1]:-unknown}" "$LEVEL_L0" "fail" "BUSY" "电脑控制锁被占用"
    emit 0 "$action" "$target" 0 "电脑正被另一个 AI 操作（${task}）；请稍后重试" "BUSY" \
      "hint" "$(json_str "tg-lock status 查看持有者与队列")"
    exit 2
  fi
}

# 卸载时自动恢复（防止脚本异常退出留下静音）
# 注意：用链式 trap，保留脚本自身可能已设置的 EXIT 处理器
_REX_SAVED_TRAP=""
silence_guard_install_trap() {
  local prev
  # ⚠ 不能直接用 `trap -p EXIT`：zsh 不支持这个语法（会报 "command not found: -p"）。
  #   bash 支持，但闪控的脚本都是 #!/bin/bash，理论上不会在 zsh 里跑。
  #   实测仍有人手动 `source common.sh` 到 zsh 里调函数 → 报错中断。
  #   所以加 shell 判断：非 bash 直接跳过 trap 安装（静音守卫的恢复逻辑降级为手动调用）。
  case "${BASH_VERSION:-}" in
    "") return 0 ;;
  esac
  prev="$(trap -p EXIT 2>/dev/null || true)"
  _REX_SAVED_TRAP=""
  if [ -n "$prev" ]; then
    _REX_SAVED_TRAP="${prev#trap -- }"
    _REX_SAVED_TRAP="${_REX_SAVED_TRAP% EXIT}"
  fi
  trap 'release_lock; silence_guard_restore; if [ -n "${_REX_SAVED_TRAP:-}" ]; then eval "$_REX_SAVED_TRAP"; fi' EXIT
}
silence_guard_install_trap

# ── 权限预检（规格书 FR-8）──────────────────────────────────────────
# 返回 0=全部就绪；非 0 时打印缺失项
PERM_MISSING=""
perm_precheck() {
  PERM_MISSING=""
  # 辅助功能：能列出运行中的应用即通过。
  # ⚠ 不能用 `app_count >/dev/null` 判成功 —— 它永远 exit 0（函数末尾是 printf），
  #   必须比较实际返回的值。
  local ax; ax="$(app_count)"
  if [ -z "$ax" ] || [ "$ax" = "0" ]; then
    PERM_MISSING="$PERM_MISSING 辅助功能(Accessibility)\n"
  fi
  # 屏幕录制：能取到像素即通过。用屏幕中心而非 (0,0)（多屏/缩放下 0,0 可能越界，
  # 报「坐标越界」会被误判成没权限 —— 实测踩过）。
  if ! $MACCTL pixel --at 700,400 >/dev/null 2>&1; then
    PERM_MISSING="$PERM_MISSING 屏幕录制(ScreenCapture)\n"
  fi
  if [ -n "$PERM_MISSING" ]; then
    return 1
  fi
  return 0
}

perm_guidance() {
  cat <<'GUIDE'
需要 macOS 授权才能继续。请打开「系统设置 → 隐私与安全性」，逐项检查：

  · 辅助功能 (Accessibility)      → 把 WorkBuddy 打开
  · 屏幕录制 (ScreenCapture)      → 把 WorkBuddy 打开
  · 输入监控 (Input Monitoring)   → 把 WorkBuddy 打开
  · 自动化 (Automation)           → 允许 WorkBuddy 控制目标应用

命令行直达：
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
GUIDE
}

# ── 黑名单（规格书 SR-1）────────────────────────────────────────────
# 银行/支付/密码管理器/系统安全类应用
BLACKLIST_BUNDLES="com.apple.Passwords com.apple.keychainaccess com.1password.1password
com.apple.systempreferences com.apple.securityagent
com.icbc com.ccb.chinabank com.bankcomm.Bankcomm
com.chinamworld.cn cmbchina cmbchinaMB
com.alipay.iphoneclient com.tencent.mm Alipay
com.unionpay com.cib.bankhk"
BLACKLIST_KEYWORDS="银行 支付 密码 钥匙串 password passwd bank payment wallet 证券 基金"

# blacklist_check <bundle_id> [app_name]  → 命中返回 0（禁止）
blacklist_check() {
  local bid="$1" name="${2:-}"
  local b
  for b in $BLACKLIST_BUNDLES; do
    [ "$bid" = "$b" ] && return 0
  done
  local lower_name; lower_name="$(printf '%s' "$name" | tr 'A-Z' 'a-z')"
  for b in $BLACKLIST_KEYWORDS; do
    case "$lower_name" in
      *"$b"*) return 0 ;;
    esac
  done
  return 1
}

# ── 密码红线（规格书 SR-2）──────────────────────────────────────────
# 检测到密码/验证码输入场景 → 直接停手
PASSWORD_HINTS="密码 验证码 支付密码 付款密码 动态口令 短信验证码 password passcode verification code cvv pin code"
is_password_field() {
  local text="$1" t
  for t in $PASSWORD_HINTS; do
    case "$text" in
      *"$t"*) return 0 ;;
    esac
  done
  return 1
}

# ── L1 确认闸（规格书 SR-5）──────────────────────────────────────────
# confirm_gate <to> <msg>  → 在 stdout 打印确认模板，返回 0
# 模型侧需把该模板原样转达给用户，得到肯定答复后再带 --confirmed 重跑。
confirm_template() {
  local to="$1" msg="$2"
  printf '「给%s发：%s」\n回复「确认」我就发送，或告诉我改哪里。' "$to" "$msg"
}

# ── 重试封装（规格书 FR-7）──────────────────────────────────────────
# retry <次数> <命令...>  → 成功即返回 0；全失败返回非 0
retry() {
  local n="$1"; shift
  local i=1
  while [ "$i" -le "$n" ]; do
    if "$@"; then return 0; fi
    i=$((i+1))
    [ "$i" -le "$n" ] && sleep 0.4
  done
  return 1
}

# ── macctl 包装 ─────────────────────────────────────────────────────
# m <macctl 子命令...>
m() { "$MACCTL" "$@"; }

# mj <macctl 子命令...>  → 只输出 JSON
#
# ⚠ 不要用 `grep -E '^\{'` 过滤：macOS 的 grep 在处理「含非 ASCII 且很长」的单行 JSON
#   时会因行缓冲/编码问题漏匹配（实测：AX 树含大量中文时整行匹配失败 → 拿到空串）。
#   改用 Python 按「首个 { 到最后一个 }」截取，稳。
# mj <macctl 子命令...>  → 只输出 JSON
#
# ⚠ 必须走临时文件，不能走管道！
#   实测根因：macctl 输出 10KB 级 JSON 时，经管道传给 python 会被截断
#   （同一命令，直连得到 10855 字节，走管道只有 9903 甚至 0 字节）。
#   原因在 Swift 侧 FileHandle 写管道时的行为，且与下游读取时序相关 → 竞态。
#   落盘（--out）后完全稳定。
mj() {
  local tmp
  tmp="$(mktemp -t reflex_mj)"
  # mj 语义 = 只输出 JSON，所以强制补 --json（调用方不必重复传）
  local hasjson=0 a
  for a in "$@"; do [ "$a" = "--json" ] && hasjson=1; done
  if [ "$hasjson" = "0" ]; then
    "$MACCTL" "$@" --json --out "$tmp" >/dev/null 2>&1
  else
    "$MACCTL" "$@" --out "$tmp" >/dev/null 2>&1
  fi
  if [ -s "$tmp" ]; then
    cat "$tmp"
  fi
  rm -f "$tmp" 2>/dev/null
  return 0
}

# 读取 json 字段：json_get <json> <jq 表达式>
json_get() {
  printf '%s' "$1" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        d = d[k]
    print(d if not isinstance(d,(dict,list)) else json.dumps(d,ensure_ascii=False))
except Exception:
    print("")
' "$2" 2>/dev/null
}

# 在 json 数组里找第一个满足 python 表达式的元素
json_pick() {
  printf '%s' "$1" | python3 -c '
import json,sys
try:
    items = json.load(sys.stdin)
except Exception:
    sys.exit(0)
expr = sys.argv[1]
for it in items:
    try:
        if eval(expr, {"i": it, "it": it, "len": len, "any": any, "all": all, "str": str, "int": int, "float": float, "bool": bool}):
            print(json.dumps(it, ensure_ascii=False))
            break
    except Exception:
        continue
' "$2" 2>/dev/null
}

# app_count → 当前运行中的应用数量（走文件，不走管道）
# app_running <bundle> → 该应用是否在运行（返回 0/1）
# ⚠ 统一落盘读取：管道传 JSON 会被截断（实测踩过），不要图省事写 `mj apps | python3`
app_count() {
  local f; f="$(mktemp -t reflex_apps)"
  "$MACCTL" apps --json --out "$f" >/dev/null 2>&1
  local n
  n="$(json_field "$f" count)"
  rm -f "$f" 2>/dev/null
  printf '%s' "${n:-0}"
}

app_running() {
  local f; f="$(mktemp -t reflex_apps)"
  "$MACCTL" apps --json --out "$f" >/dev/null 2>&1
  local hit
  hit="$(python3 -c '
import json,sys
try:
    apps = json.load(open(sys.argv[1], encoding="utf-8")).get("apps", [])
except Exception:
    apps = []
want = sys.argv[2]
print("1" if any(a.get("bundle") == want or a.get("name") == want for a in apps) else "0")
' "$f" "${1:-}" 2>/dev/null)"
  rm -f "$f" 2>/dev/null
  [ "$hit" = "1" ]
}

# json_field <json文件> <顶层字段名> → 字段值（标量）
json_field() {
  python3 -c '
import json,sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print(""); raise SystemExit(0)
v = d.get(sys.argv[2])
print("" if v is None else (v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)))
' "$1" "$2" 2>/dev/null
}

# ── 带重试的 AX 读取 ────────────────────────────────────────────────
# macOS 对「被完全遮挡 / 正在动画重排」的窗口会停止 AX 投递 → 树瞬间变 0 节点。
# 这是间歇性故障（手动测常常正常，脚本里必现），所以所有 AX 读取都要重试。
#
# ax_state <bundle> <depth> [重试次数] [间隔秒]  → JSON
ax_state() {
  local b="$1" depth="${2:-12}" tries="${3:-5}" gap="${4:-0.6}"
  local i=1 f cnt
  while [ "$i" -le "$tries" ]; do
    f="$(mj_file axst state --app "$b" --depth "$depth")"
    cnt="$(json_query "$f" ax_count)"
    if [ -n "$cnt" ] && [ "$cnt" -gt 0 ] 2>/dev/null; then
      cat "$f"
      rm -f "$f" 2>/dev/null
      return 0
    fi
    rm -f "$f" 2>/dev/null
    i=$((i+1))
    [ "$i" -le "$tries" ] && sleep "$gap"
  done
  return 1
}

# ax_find <bundle> <text> [role] [limit]  → JSON
ax_find() {
  local b="$1" text="$2" role="${3:-}" limit="${4:-10}"
  local args=(find --text "$text" --app "$b" --json --limit "$limit")
  [ -n "$role" ] && args+=(--role "$role")
  mj "${args[@]}"
}

# json_query <json文件> <解析器函数名> [参数...]  → 从文件读 JSON 并求值
# ⚠ 必须从文件读，不能用 `printf '%s' "$json" | python3 -c ...`：
#   Python 文本模式的 universal-newlines 转换会在含中文的 10KB JSON 上
#   提前结束读取 → JSON 被截断 → 解析失败（实测踩过：search box 明明存在却找不到）。
#   文件读取没有这个问题。
#
# ⚠ 第二个参数是 parsers.py 里的**函数名**，不是 Python 表达式。
#   写成 'd.get("ax_count",0)' 会查表失败 → 静默返回空 → 上层误判为「AX 树为空」
#   （实测踩过：文件完整 10855 字节却被报 AX 树为空）。现在未知函数名会报错到 stderr。
#
# 解析器实现在 scripts/parsers.py，加新解析器请改那里。
# 用法：json_query "$FILE" ax_count
json_query() {
  local f="$1" fn="$2"; shift 2
  [ -f "$f" ] || return 1
  python3 "$PARSER_PY" "$f" "$fn" "$@" 2>>"${REFLEX_LOG_DIR:-/tmp}/json_query.err"
}

# ── 条件等待（替代固定 sleep）────────────────────────────────────
# 为什么重要（实测）：脚本里堆`sleep 1.2` 之类的固定等待是耗时大头
#   ——music_play 有 9 处 sleep 累加 11.8s，而macctl 单次调用只要 100-300ms。
#   固定等待的问题不只是慢，还包括「等够了但事情没发生」时无法提前退出。
# 条件等待：条件一满足立刻返回，通常比固定等待快一个数量级。
#
# wait_for <超时秒> <轮询间隔秒> <命令...>  → 条件成立返回 0，超时返回 1
# ⚠ 步进换算不能用 `int(gap*10)` —— 0.25*10=2.5 被截成 2，每轮少算 0.05s，
#   累积后实际等待远超timeout（实测要等 3s 却等了 13s）。改为记录起始时刻比时间。
wait_for() {
  local timeout="$1" gap="${2:-0.25}"; shift 2
  local timeout_ms gap_ms waited=0
  # 一次换算：秒 → 毫秒整数（避免后续浮点比较与重复调 python）
  timeout_ms="$(python3 -c "print(int(float('$timeout')*1000))")"
  gap_ms="$(python3 -c "print(max(50,int(float('$gap')*1000)))")"
  while :; do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    waited=$((waited + gap_ms))
    if [ "$waited" -ge "$timeout_ms" ]; then
      # 最后一试（边界：刚好在超时瞬间成立）
      "$@" >/dev/null 2>&1 && return 0
      return 1
    fi
    sleep "$gap"
  done
}

# 具体化的等待器
#⚠ 性能要点（实测）：轮询里最贵的不是 macctl，而是**进程启动开销**
#   ——macOS 沙箱下 python3 冷启动 ~240ms、mktemp ~118ms。
#   所以探测函数必须「一次进程做完所有事」：
#   单次 state + 单次 parsers.py，不额外起进程做校验/清理。
#wait_search <bundle> <解析器函数名> [参数...] → 该解析器返回非空即算就绪
wait_search() {
  local b="$1" fn="$2"; shift 2
  local timeout="${WAIT_TIMEOUT:-3}" gap="${WAIT_GAP:-0.25}"
  local timeout_ms gap_ms waited=0 f v
  timeout_ms="$(python3 -c "print(int(float('$timeout')*1000))")"
  gap_ms="$(python3 -c "print(max(60,int(float('$gap')*1000)))")"
  while :; do
    f="$(mj_file wschk state --app "$b" --depth 12)"
    v="$(python3 "$PARSER_PY" "$f" "$fn" "$@" 2>/dev/null)"
    rm -f "$f" 2>/dev/null
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
    waited=$((waited + gap_ms))
    if [ "$waited" -ge "$timeout_ms" ]; then
      f="$(mj_file wschk state --app "$b" --depth 12)"
      v="$(python3 "$PARSER_PY" "$f" "$fn" "$@" 2>/dev/null)"
      rm -f "$f" 2>/dev/null
      if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
      return 1
    fi
    sleep "$gap"
  done
}

# wait_text <bundle> <文本> → AX 树里出现该文本即算就绪
wait_text() {
  local b="$1" txt="$2"
  WAIT_TIMEOUT="${WAIT_TIMEOUT:-3}" wait_search "$b" has_text "$txt"
}

# ── 环境预检（动手之前先确认输入通道可用）────────────────────────
# ⚠ 为什么必须有（实测踩过最贵的一个坑）：
#   屏幕锁定时 macOS 会**静默丢弃**所有 CGEvent 合成输入事件 ——
#   点击不生效、粘贴不进字，但**任何工具都不报错**，脚本会一路"成功"跑完，
#   最后报「点了但没生效」，让人以为是脚本逻辑问题。
#   实际真因是「电脑锁屏了」。排查这个问题耗掉了大量时间。
#   所以：任何要模拟输入的脚本，动手前先跑这个预检。
#
# precheck_env <bundle> → 0=可动手；非 0 时已打印原因（并置 ENV_BLOCKED_REASON）
ENV_BLOCKED_REASON=""
ENV_BLOCKED_CODE=""
precheck_env() {
  local bid="${1:-}"
  local out
  # ⚠ bash 3.2 下 `"${args[@]}"` 在数组为空 + set -u 时会报unbound variable，
  #   所以不能用数组拼参数，直接分支处理（实测踩过）。
  if [ -n "$bid" ]; then
    out="$("$MACCTL" doctor --app "$bid" --json 2>/dev/null)"
  else
    out="$("$MACCTL" doctor --json 2>/dev/null)"
  fi
  # doctor 本身失败不算阻塞（老版本 macctl 没有 doctor）
  [ -z "$out" ] && return 0
  # ⚠ 一次 python3 同时取出 ok 与首条 issue（D-014）。
  #   原来分两次调用，白白多付 50ms 冷启动。用 "|" 分隔输出，bash 侧 IFS 拆。
  #   解析失败时输出 "1|"（默认放行），保持与旧行为一致。
  local verdict
  verdict="$(printf '%s' "$out" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    iss = d.get("issues") or []
    print(("0|" + (iss[0] if iss else "环境存在阻塞")) if not d.get("ok") else "1|")
except Exception:
    print("1|")' 2>/dev/null)"
  local ok="${verdict%%|*}"
  local reason="${verdict#*|}"
  if [ "$ok" = "1" ]; then
    ENV_BLOCKED_REASON=""
    ENV_BLOCKED_CODE=""
    return 0
  fi
  ENV_BLOCKED_CODE="$ERR_NEED_HUMAN"
  ENV_BLOCKED_REASON="${reason:-环境存在阻塞}"
  return 1
}

# precheck_env 或 emit_env_blocked <动作> <目标>  → 阻塞时打印并 exit
precheck_env_or_exit() {
  local action="$1" target="$2" bundle="${3:-}"
  if precheck_env "$bundle"; then
    return 1   # 返回1 表示「不阻塞，继续」
  fi
  # 阻塞 → 如实报告，绝不假装成功
  audit "$action:$target" "$(basename "$0")" "$LEVEL_L1" "fail" \
    "$ENV_BLOCKED_CODE" "环境阻塞: $ENV_BLOCKED_REASON"
  emit 0 "$action" "$target" 0 \
    "现在还不能操作：$ENV_BLOCKED_REASON
把电脑解锁后我就能继续了。" \
    "$ENV_BLOCKED_CODE" \
    "blocked_by" "screen_locked_or_input_blocked" \
    "remedy" "$(json_str "解锁屏幕后重试")"
  exit 1
}

# ── AX树就绪等待（遮挡重试的统一入口）────────────────────────────
# ⚠ 一律走 macctl probe，不要在 shell 里轮询：
#   shell 轮询每轮要起 mktemp + python3（沙箱下冷启动 ~240ms），单轮 ~900ms；
#   macctl probe 在 Swift 进程内轮询，实测立即就绪 422ms、超时 5.5s（3s 预算），
#   比 shell 轮询快一个数量级。
probe_ax() {
  "$MACCTL" probe --app "$1" --mode ax --depth "${2:-12}" --timeout "${3:-3}" "$@" >/dev/null 2>&1
}

# 等待「有可输入文本框」—— 用于确认点击后焦点到位
probe_input() {
  "$MACCTL" probe --app "$1" --mode textfield --depth "${2:-12}" \
    --ymin "${3:-0}" --ymax "${4:-200}" --timeout "${5:-2}" >/dev/null 2>&1
}

# 等待「某文本出现」
probe_text() {
  "$MACCTL" probe --app "$1" --mode text --query "$2" --depth "${3:-12}" \
    --timeout "${4:-3}" >/dev/null 2>&1
}

# 等待「某 role 在指定纵向范围内存在」
probe_role() {
  "$MACCTL" probe --app "$1" --mode role --role "$2" --depth "${3:-12}" \
    --ymin "${4:--99999}" --ymax "${5:-99999}" --minw "${6:-0}" \
    --timeout "${7:-2}" >/dev/null 2>&1
}

# mj_file <json文件前缀> <macctl 子命令...>  → 落盘 JSON，返回文件路径
# 脚本里凡是「拿到大 JSON 再解析」的场景，都走这个，避开管道截断。
#
# ⚠ 性能（实测）：不要在这里做「落盘后校验 JSON 合法性」——
#   macOS 沙箱下 python3 冷启动要~240ms，而 mj_file 在轮询里会被反复调用，
#   一次探测多付240ms 就足以让超时从 3s 涨到 10s+。
#   JSON 完整性校验已下沉到 parsers.py（在真正解析时校验，报错到 stderr），
#   语义不丢，代价归零。
mj_file() {
  local prefix="$1"; shift
  local f
  f="$(mktemp -t "${prefix}_XXXXXX")"
  local hasjson=0 a
  for a in "$@"; do [ "$a" = "--json" ] && hasjson=1; done
  if [ "$hasjson" = "0" ]; then
    "$MACCTL" "$@" --json --out "$f" >/dev/null 2>&1
  else
    "$MACCTL" "$@" --out "$f" >/dev/null 2>&1
  fi
  printf '%s' "$f"
}

# ── preferences 读取 ────────────────────────────────────────────────
# pref_get <key>  → 从 preferences.md 的 `key: value` 形式中取值
pref_get() {
  [ -f "$PREF_FILE" ] || return 1
  local key="$1"
  sed -n "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//p" "$PREF_FILE" | head -1
}
