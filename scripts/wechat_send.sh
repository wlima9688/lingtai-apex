#!/bin/bash
# 闪控 · wechat_send.sh — 微信发消息（L1，发送前需确认）
#
# 规格书 §6.4：折叠配方 A（约 9 步）
#   raise → state 拿全 AX 树 → 解析搜索框 → click → 粘贴联系人名 →
#   找浮窗结果 → click 结果项 → click 聊天输入框 → 粘贴消息 →
#   click「发送」→ find 验证消息已上屏
#
# 参数：
#   --to <联系人>    联系人名（必需）
#   --msg <内容>    消息内容（必需）
#   --confirmed      已获得用户确认，跳过确认闸（由模型在用户答复后带上）
#   --dry-run        只做定位与预览，不发送
#   --restart-wechat 万不得已时的末位手段：重启微信进程。
#                     会丢失微信里未发送的草稿，所以默认不开。
#                     ⚠ 正常场景永远不需要它 —— 微信只是最小化时，
#                       点 Dock 图标即可唤醒（见下方 §5.9唤醒阶梯）。
#
# L1 语义（规格书 §5.1 / SR-5）：
#   未带 --confirmed 时，脚本完成所有可逆步骤（定位、准备），然后停下并返回
#   need_confirm=true + 确认模板。模型把模板转达用户，用户确认后重跑带 --confirmed。
#   绝不「问一次就自己发」。

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/common.sh"

APP_NAME="微信"
BUNDLE="com.tencent.xinWeChat"
TO=""
MSG=""
CONFIRMED=0
DRY=0
RESTART_WECHAT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO="$2"; shift 2 ;;
    --msg) MSG="$2"; shift 2 ;;
    --confirmed) CONFIRMED=1; shift ;;
    #⚠ 自动重启微信：实测是「AX 树 0 节点」唯一有效的恢复手段。
    #   代价是会丢未发送草稿，所以默认不开，显式传才生效。
    --restart-wechat) RESTART_WECHAT=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) shift ;;
  esac
done

# ⚠ 参数校验必须在环境预检**之前**：
#   缺参数是调用方的问题，与环境无关；而锁屏预检要 1.5s，
#   放在前面会让「参数写错」这种秒级错误也等1.5s，还报错原因不对。
if [ -z "$TO" ] || [ -z "$MSG" ]; then
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_ELEMENT_NOT_FOUND" "缺少 --to 或 --msg"
  emit 0 "wechat_send" "$TO" 0 "缺少 --to 或 --msg" "$ERR_ELEMENT_NOT_FOUND"
  exit 1
fi

# 环境预检：屏幕锁定时输入事件全部失效（实测踩过）
precheck_env_or_exit "wechat_send" "$TO" "$BUNDLE"

# ── 1. 权限预检（FR-8：缺失就一次性给指引，别执行到一半才失败）────
if ! perm_precheck; then
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_PERMISSION_DENIED" "权限缺失"
  emit 0 "wechat_send" "$TO" 0 "缺少必要授权，请先完成系统设置" "$ERR_PERMISSION_DENIED" \
    "guidance" "$(json_str "$(perm_guidance)")"
  exit 1
fi

# ── 2. 密码红线（SR-2）：消息内容像密码/验证码 → 直接停手 ────────
if is_password_field "$MSG" || is_password_field "$TO"; then
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L2" "fail" "$ERR_NEED_HUMAN" "命中密码红线"
  emit 0 "wechat_send" "$TO" 0 "内容疑似密码/验证码，已停手，请人工处理" "$ERR_NEED_HUMAN"
  exit 3
fi

# ── 3. 黑名单前置（SR-1）────────────────────────────────────────
if blacklist_check "$BUNDLE" "$APP_NAME"; then
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L2" "fail" "$ERR_BLACKLISTED" "命中黑名单"
  emit 0 "wechat_send" "$TO" 0 "$APP_NAME 在黑名单中，已拒绝执行" "$ERR_BLACKLISTED"
  exit 3
fi

# ── 3.5 电脑控制锁：多 AI 不打架 ─────────────────────────────────
lock_guard_or_exit "wechat_send" "$TO" "微信发消息"

# ── 4. 置前（防遮挡：AX 树会因被完全遮挡而变成 0 节点）───────────
m front --app "$BUNDLE" >/dev/null 2>&1
sleep 1.2

# ── 5. 一次拿全 AX 树（FR-3）──────────────────────────────────
# ⚠ macOS 对「被完全遮挡」的窗口停止 AX 投递 → AX 树瞬间变 0 节点。
#   front 后需等系统完成窗口重排，AX 树才恢复 → 必须轮询重试。
# ⚠ 大 JSON 必须落盘：管道传含中文的 JSON 会被截断（实测踩过，
#   表现为「元素明明存在却找不到」）。统一走 mj_file + json_query + parsers.py。
AXN=0
for attempt in 1 2 3 4 5; do
  STATE_FILE="$(mj_file wx1 state --app "$BUNDLE" --depth 10)"
  AXN="$(json_query "$STATE_FILE" ax_count)"
  [ "${AXN:-0}" != "0" ] && break
  rm -f "$STATE_FILE" 2>/dev/null
  if [ "$attempt" = "1" ]; then
    m diagnose --app "$BUNDLE" >/dev/null 2>&1
    m front --app "$BUNDLE" >/dev/null 2>&1
  fi
  sleep 0.8
done

# ── 5.9 唤醒阶梯：AX 树为空时逐级升级（不重启优先）──────────────
#⚠ 2026-10-22 改造（用户实测纠正）：
#   原实现在这里直接「重启微信」，理由是"AX 树 0 节点时重启是唯一有效手段"。
#   **这个结论是错的。** 用户指出：微信一直都开着，只是**最小化**在 Dock 上，
#   点一下 Dock 图标就能唤醒 —— 不需要重启。
#
#   复现与验证（2026-10-22 实测）：
#   微信最小化 → macctl dock --app 微信 → AX 节点 15 → 163，窗口正常唤起。
#   根因是 macOS 对「最小化/被完全遮挡」的窗口停止 AX 投递，
#   点Dock 图标让窗口重新上屏，AX 投递自然恢复。
#
#   所以唤醒要分级，能不动进程就不动：
#     L1 Dock 点击（用户建议，抗遮挡，零副作用）→ L2 重复点击（切换掉最小化态）
#     → L3 强制 raise → L4 才考虑重启（会丢草稿，需显式 --restart-wechat）
#
#   为什么 Dock 点击比 front/raise 更可靠：
#   front/raise 走 NSRunningApplication.activate，对「已运行但最小化」的窗口
#   常常只是激活进程而不还原窗口 → AX 树仍然为空。Dock 点击是「真的把窗口叫回来」。
if [ "${AXN:-0}" = "0" ]; then
  rm -f "$STATE_FILE" 2>/dev/null

  # L1+L2：点 Dock 图标（连点两次以覆盖「点一下反而最小化」的情况）
  WAKE_BY="dock"
  for _ in 1 2; do
    m dock --app "微信" >/dev/null 2>&1
    sleep 1.2
    STATE_FILE="$(mj_file wxw1 state --app "$BUNDLE" --depth 10)"
    AXN="$(json_query "$STATE_FILE" ax_count)"
    if [ "${AXN:-0}" != "0" ]; then break; fi
    rm -f "$STATE_FILE" 2>/dev/null
  done

  # L3：Dock 唤不回来再试强制 raise（activate + AX raise + 点标题栏）
  if [ "${AXN:-0}" = "0" ]; then
    WAKE_BY="raise"
    m raise --app "$BUNDLE" >/dev/null 2>&1
    sleep 1.5
    STATE_FILE="$(mj_file wxw2 state --app "$BUNDLE" --depth 10)"
    AXN="$(json_query "$STATE_FILE" ax_count)"
    rm -f "$STATE_FILE" 2>/dev/null
  fi

  if [ "${AXN:-0}" != "0" ]; then
    audit "wechat_send:${TO}" "wechat_send.sh" "$LEVEL_L1" "ok" "" "经${WAKE_BY} 唤醒微信，AX=${AXN}，未重启进程"
    STATE_FILE="$(mj_file wxw3 state --app "$BUNDLE" --depth 10)"
    AXN="$(json_query "$STATE_FILE" ax_count)"
  elif [ "$RESTART_WECHAT" = "1" ]; then
    # L4：末位手段 —— 用户显式要求才走
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "" "Dock+raise 均无效，按 --restart-wechat 重启微信"
    osascript -e 'tell application "WeChat" to quit' >/dev/null 2>&1 || pkill -x WeChat
    sleep 3
    pgrep -x WeChat >/dev/null 2>&1 && { pkill -9 -x WeChat; sleep 2; }
    m raise --app "$BUNDLE" >/dev/null 2>&1     # raise 现在会自动拉起未运行的应用
    sleep 4
    STATE_FILE="$(mj_file wxw4 state --app "$BUNDLE" --depth 10)"
    AXN="$(json_query "$STATE_FILE" ax_count)"
    if [ "${AXN:-0}" = "0" ]; then
      rm -f "$STATE_FILE" 2>/dev/null
      audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_PERMISSION_DENIED" "重启微信后 AX 树仍为空"
      emit 0 "wechat_send" "$TO" 0 "重启微信后仍无法访问界面。请手动打开微信确认它已登录，然后再试" "$ERR_PERMISSION_DENIED"
      exit 1
    fi
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "ok" "" "重启微信后恢复，AX=$AXN"
  else
    # 唤醒阶梯全部失败 —— 报「能力受限」并给出人话指引，而不是让用户去猜
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_PERMISSION_DENIED" "AX 树为空且 Dock/raise 唤醒无效"
    emit 0 "wechat_send" "$TO" 0 "微信已最小化且闪控自动唤醒失败（点 Dock 图标 + 强制置前都试过了）。
请你手动点一下 Dock 上的微信图标把它叫出来，然后回复「已打开」，我会立刻继续发送。
（如果你确认微信可以重启，也可以让我用 --restart-wechat 重试，但会丢失微信里未发送的草稿。）" "$ERR_PERMISSION_DENIED" \
      "hint" "$(json_str "手动点 Dock 上的微信图标唤醒，或授权 --restart-wechat 重试")"
    exit 1
  fi
fi

# ── 5.5 幂等检查：是否已处于目标会话中？────────────────────────
#⚠ 必需（实测踩过）：脚本第二次跑时，若上轮已定位到会话，再点搜索框会
#   打断当前会话 → 第二次必然失败。已确认在会话中则跳过搜索。
ALREADY="$(json_query "$STATE_FILE" in_chat_with "$TO")"

# ── 5.9 会话列表兜底（B 方案）───────────────────────────────────
# 搜索框点不上时，直接在左侧会话列表里找这个人点进去。
# 列表是虚拟滚动的，所以「找 → 滚 → 再找」最多 5 轮。
# ⚠ 这里用 awk 而不是内嵌 python：外层是 "$( ... )"，里面再套双引号会截断
#   命令替换（实测直接报 `line 313: TO` 这种莫名错误）。
open_via_list() {
  local who="$1" i hit rows wx wy ww wh
  # ⚠ 会话列表的位置必须**相对于微信窗口**算，不能写死 x<300：
  #   实测微信窗口可能在 (732,36)，写死的左边距会把整个人类列表排除掉，
  #   于是"文件传输助手明明在列表里"也报找不到（2026-10-23 踩到）。
  local rect
  rect="$(m windows --app "$BUNDLE" 2>/dev/null | /usr/bin/sed -E -n 's/.*@\(([0-9]+),([0-9]+)\) ([0-9]+)x([0-9]+).*/\1 \2 \3 \4/p' | /usr/bin/awk '$3*$4 > m { m=$3*$4; print $1, $2, $3, $4 }')"
  [ -z "$rect" ] && return 1
  read -r wx wy ww wh <<< "$rect"
  local xmax=$(( wx + ww * 45 / 100 ))   # 左侧 45% 视为会话列表

  for i in 1 2 3 4 5; do
    rows="$(m find --text "$who" --app "$BUNDLE" 2>/dev/null)"
    hit="$(printf '%s' "$rows" \
      | /usr/bin/sed -E -n 's/.*@\(([0-9]+),([0-9]+)\) ([0-9]+)x([0-9]+).*/\1 \2 \3 \4/p' \
      | /usr/bin/awk -v xmax="$xmax" '$1 < xmax && $2 > 60 { printf "%d,%d", $1 + $3 / 2, $2 + $4 / 2; exit }')"
    if [ -n "$hit" ]; then
      m click --at "$hit" >/dev/null 2>&1
      sleep 1.8
      audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "list_open" "已从会话列表进入「${who}」"
      return 0
    fi
    m scroll --dir down --n 4 --at "$(( wx + ww / 6 )),$(( wy + wh / 2 ))" >/dev/null 2>&1
    sleep 0.5
  done
  return 1
}

# ── 6. 定位搜索框（AX 优先，拿不到就降级 OCR）───────────────────
SEARCH_XY="$(json_query "$STATE_FILE" wechat_search_box)"
rm -f "$STATE_FILE" 2>/dev/null

if [ "$ALREADY" != "yes" ]; then
  # ⚠ 降级（D-017）：微信搜索框是自绘控件，AX 有时只暴露占位元素。
  #   实测 AX 有时能拿到（58ms），有时拿不到 —— 取决于窗口状态。
  #   所以不能只信 AX，拿不到时用 locate 降级到 OCR 视觉定位。
  if [ -z "$SEARCH_XY" ]; then
    # ⚠ 走 --out 落盘，不走管道：管道传 JSON 会被截断（lint 8'会拦）
    LOCF="$(mj_file wxloc locate --text "搜索" --app "$BUNDLE" --json)"
    SEARCH_XY="$(json_query "$LOCF" locate_xy)"
    rm -f "$LOCF" 2>/dev/null
    [ -n "$SEARCH_XY" ] && [ "${SEARCH_XY%% *}" != "" ] && \
      audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "search_box_via_ocr" "AX 拿不到搜索框，已用 OCR 视觉定位"
  fi

  if [ -z "$SEARCH_XY" ]; then
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_ELEMENT_NOT_FOUND" "无搜索框"
    emit 0 "wechat_send" "$TO" 0 "在微信中找不到搜索框" "$ERR_ELEMENT_NOT_FOUND"
    exit 1
  fi

  SX="${SEARCH_XY% *}"; SY="${SEARCH_XY#* }"

  # ── 7. 搜索联系人 ────────────────────────────────────────────
  # ⚠ 两条实测教训（见 DIAGNOSIS.md D-001）：
  #  ① 微信的聊天窗口会完全覆盖搜索框 → 先把非主窗口后置，让搜索框露出来
  #  ② 微信搜索框是**自绘控件**，AX 只暴露占位元素，点击拿不到焦点
  #     （macctl clear 会退化到 quartz 合成事件 = 没有控件持有焦点的确证）
  #    所以这里用「粘贴后回读搜索框值」作为成功判据，而不是盲信 type 的成功回报。
  m winback --app "$BUNDLE" >/dev/null 2>&1
  sleep 0.6

  # ⚠⚠ 2026-10-23 实测事故：AX 快照里的窗口几何是**过期**的（920x791，实际 708x775），
  #   点击坐标落到上层浏览器 → 中文被粘进浏览器搜索框。
  #   两条防线：
  #   ① 点之前**重新读当前窗口矩形**，坐标不在窗口内就重新算；
  #   ② 输入前断言**前台就是微信**，不是就先唤回，唤不回直接放弃
  #      （宁可不发，也不能把消息打进别的 App）。
  REAL_RECT="$(m windows --app "$BUNDLE" 2>/dev/null | /usr/bin/sed -E -n 's/.*@\(([0-9]+),([0-9]+)\) ([0-9]+)x([0-9]+).*/\1 \2 \3 \4/p' | /usr/bin/awk '$3*$4 > m { m=$3*$4; print $1, $2, $3, $4 }')"
  if [ -n "$REAL_RECT" ]; then
    read -r RWX RWY RWW RWH <<< "$REAL_RECT"
    # 微信可能处于「迷你窗」状态（实测 280x380）：这种窗口里根本没有搜索框，
    # 硬按比例算坐标只会点到别处 —— 直接叫停，让人点一下展开。
    if [ "$RWW" -lt 500 ]; then
      audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "MINI_WINDOW" "微信处于迷你窗 ${RWW}x${RWH}"
      emit 0 "wechat_send" "$TO" 0 "微信现在是迷你窗（${RWW}x${RWH}），里面没有搜索框。点一下窗口右上角展开成正常大小，再说一次。" "MINI_WINDOW"
      exit 1
    fi
    if [ "$SX" -lt "$RWX" ] || [ "$SX" -gt $(( RWX + RWW )) ] \
       || [ "$SY" -lt "$RWY" ] || [ "$SY" -gt $(( RWY + RWH )) ]; then
      audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "geometry_stale" "搜索框坐标($SX,$SY)不在当前窗口($RWX,$RWY,${RWW}x${RWH})内，已按当前位置重算"
      SX=$(( RWX + RWW * 62 / 100 ))
      SY=$(( RWY + 26 ))
    fi
  fi

  FRONT_BID="$(m state 2>/dev/null | /usr/bin/sed -n 's/.*bundle=\([^ ]*\).*/\1/p' | head -1)"
  if [ "$FRONT_BID" != "$BUNDLE" ]; then
    m raise --app "$BUNDLE" >/dev/null 2>&1
    sleep 0.8
    FRONT_BID="$(m state 2>/dev/null | /usr/bin/sed -n 's/.*bundle=\([^ ]*\).*/\1/p' | head -1)"
  fi
  if [ "$FRONT_BID" != "$BUNDLE" ]; then
    # ⚠ AppleScript activate 是第三条路：实测「Dock 点击 + raise 都失败」时它有效
    #   （2026-10-23 微信最小化后前两条都没唤回来，activate 一下就前台了）。
    /usr/bin/osascript -e 'tell application "WeChat" to activate' >/dev/null 2>&1
    sleep 1.0
    FRONT_BID="$(m state 2>/dev/null | /usr/bin/sed -n 's/.*bundle=\([^ ]*\).*/\1/p' | head -1)"
    [ "$FRONT_BID" = "$BUNDLE" ] && \
      audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "wake_osascript" "Dock/raise 无效，osascript activate 唤回"
  fi
  if [ "$FRONT_BID" != "$BUNDLE" ]; then
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "NOT_FRONT" "微信不是前台，已放弃输入"
    emit 0 "wechat_send" "$TO" 0 "微信没到前台（前台是 ${FRONT_BID}）—— 没敢输入，怕打进别的窗口。再试一次？" "NOT_FRONT"
    exit 1
  fi

  # ── 7.1 聚焦 + 输入：**带重试、多策略**（2026-10-23 用户拍板 A+B 结合）──
  # 实测自绘搜索框有时点不上（3 次里 2 次），一次失败就让人手动处理太脆。
  # 三种策略依次试，任一成功即继续：
  #   ① 直接点 AX/OCR 定位到的搜索框
  #   ② 用 OCR 现场重新找「搜索」二字再点（窗口位置可能变了）
  #   ③ ⌘F 唤搜索（微信原生快捷键）
  focus_and_type() {
    local sx="$1" sy="$2"
    m click --at "$sx,$sy" >/dev/null 2>&1
    sleep 0.7
    m clear --app "$BUNDLE" >/dev/null 2>&1
    m type --text "$TO" --app "$BUNDLE" >/dev/null 2>&1
    sleep 1.4
    local f v
    f="$(mj_file wxchk state --app "$BUNDLE" --depth 10)"
    v="$(json_query "$f" wechat_search_value)"
    rm -f "$f" 2>/dev/null
    if [ -z "$v" ]; then
      v="$(m ocr --app "$BUNDLE" 2>/dev/null | /usr/bin/grep -F "'$TO'" | head -1)"
    fi
    [ -n "$v" ]
  }

  FOCUSED=0
  if focus_and_type "$SX" "$SY"; then FOCUSED=1; fi

  if [ "$FOCUSED" = "0" ]; then
    # ② 重新 OCR 定位再试（窗口可能被移动过）
    LOCF2="$(mj_file wxloc locate --text "搜索" --app "$BUNDLE" --json)"
    XY2="$(json_query "$LOCF2" locate_xy)"; rm -f "$LOCF2" 2>/dev/null
    if [ -n "$XY2" ]; then
      if focus_and_type "${XY2% *}" "${XY2#* }"; then
        FOCUSED=1
        audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "focus_retry" "第 2 次（OCR 重定位）成功"
      fi
    fi
  fi

  if [ "$FOCUSED" = "0" ]; then
    # ③ ⌘F 原生快捷键
    m key --key f --cmd >/dev/null 2>&1
    sleep 0.8
    m clear --app "$BUNDLE" >/dev/null 2>&1
    m type --text "$TO" --app "$BUNDLE" >/dev/null 2>&1
    sleep 1.4
    if m ocr --app "$BUNDLE" 2>/dev/null | /usr/bin/grep -qF "'$TO'"; then
      FOCUSED=1
      audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "focus_retry" "第 3 次（⌘F）成功"
    fi
  fi

  # ④ 都失败 → 走 B 方案：直接在左侧会话列表里找这个人点进去
  if [ "$FOCUSED" = "0" ]; then
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "list_fallback" "搜索框点不上，改走会话列表"
    if open_via_list "$TO"; then
      FOCUSED="list"
      ALREADY="yes"        # 已在会话里了，后续不再走搜索/点结果
    fi
  fi

  if [ "$FOCUSED" = "0" ]; then
    # 连列表都没有 → 这才需要人
    propose "微信搜索框与会话列表都没找到「${TO}」" "见 DIAGNOSIS.md D-002"
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_ELEMENT_NOT_FOUND" "搜索框与列表都没定位到"
    emit 0 "wechat_send" "$TO" 1 "没能在微信里定位到「${TO}」（搜索框点不上、会话列表里也没有）。给我更准的写法？" "$ERR_ELEMENT_NOT_FOUND" \
      "to" "$(json_str "$TO")" "msg" "$(json_str "$MSG")"
    exit 1
  fi

  # 回读确认：搜索框真的拿到内容了吗
  # ⚠ 必须用 OCR 回读，不能只信 AX 的 value（D-017）：
  #   自绘控件的 AX value 常常读不到真实内容（读到的还是占位符「搜索」），
  #   但 OCR 能看到屏幕上真实的文字。实测 type 之后 OCR 读到 '测试'。
  SB_VALUE=""
  CHK_FILE="$(mj_file wxchk state --app "$BUNDLE" --depth 10)"
  SB_VALUE="$(json_query "$CHK_FILE" wechat_search_value)"
  rm -f "$CHK_FILE" 2>/dev/null
  # AX 读不到时降级 OCR 视觉回读
  if [ -z "$SB_VALUE" ]; then
    SB_VALUE="$(m ocr --app "$BUNDLE" 2>/dev/null | grep -F "'$TO'" | head -1)"
    [ -n "$SB_VALUE" ] && \
      audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "search_readback_via_ocr" "AX 读不到搜索内容，已用 OCR 回读确认"
  fi

  if [ -z "$SB_VALUE" ]; then
    # 搜索框不接受输入 → 明确报「能力受限」，而不是笼统的「没搜到」
    propose "微信搜索框不接受输入（自绘控件）" "需改走会话列表匹配路径，见 DIAGNOSIS.md D-002"
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_ELEMENT_NOT_FOUND" "搜索框不可输入"
    TIP_HUMAN="微信的搜索框不接受自动输入（macOS 版自绘控件，AX 拿不到焦点）。
已定位到微信窗口，但没法搜索联系人，所以现在还不能发送。

临时办法：你在微信里手动打开「${TO}」的会话窗口，然后回复「已打开」，我就继续发送。"
    TIP_STEP="在微信中手动打开与「${TO}」的会话窗口"
    emit 0 "wechat_send" "$TO" 1 "$TIP_HUMAN" "$ERR_NEED_HUMAN" \
      "to" "$(json_str "$TO")" \
      "msg" "$(json_str "$MSG")" \
      "blocked_by" "wechat_search_unfocusable" \
      "manual_step" "$(json_str "$TIP_STEP")"
    exit 2
  fi

  # ── 8. 找搜索结果（浮窗里的结果项）────────────────────────────
  RES_FILE="$(mj_file wx2 state --app "$BUNDLE" --depth 12)"
  RESULT="$(json_query "$RES_FILE" contact_result "$TO")"
  # 多候选：用户定稿「匹配到多个或只是模糊 → 问一句，给选项我选择（面板弹窗）」。
  # 只要去重后超过 1 个，就不猜，把选项交回面板。
  CANDS="$(json_query "$RES_FILE" contact_candidates "$TO" 2>/dev/null)"
  # 「文件传输助手」这类只出现在搜索下拉「功能」段的条目：联系人规则匹配不到，
  # 用通用匹配兜底（标题完全相等即可点）。
  if [ -z "$RESULT" ]; then
    ANY="$(json_query "$RES_FILE" search_any "$TO" 2>/dev/null)"
    if [ -n "$ANY" ]; then
      RESULT="$ANY"
      audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "matched_via_feature_section" "命中搜索下拉的「功能」段：$TO"
    fi
  fi
  # ⚠ `grep -c` 在没有匹配时**退出码是 1**，后面的 `|| echo 0` 会再打一个 0，
  #   于是 N_CANDS="0\n0" → `[ "0<换行>0" -ge 2 ]` 报
  #   `[: 0 0: integer expression expected`。grep -c 本来就输出 0，不要兜底。
  N_CANDS="$(printf '%s' "$CANDS" | /usr/bin/grep -c '|' 2>/dev/null)"
  N_CANDS="${N_CANDS:-0}"
  rm -f "$RES_FILE" 2>/dev/null

  if [ "${N_CANDS:-0}" -ge 2 ]; then
    NAMES="$(printf '%s' "$CANDS" | /usr/bin/cut -d'|' -f1 | /usr/bin/paste -sd'、' -)"
    NAMES_JSON="$(printf '%s' "$CANDS" | /usr/bin/cut -d'|' -f1 \
      | /usr/bin/awk 'BEGIN{ORS=""} {printf "%s\"%s\"", (NR>1?",":""), $0}')"
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "ambiguous" "多个候选：$NAMES"
    emit 0 "wechat_send" "$TO" 0 "「${TO}」匹配到 ${N_CANDS} 个：${NAMES}" "AMBIGUOUS" \
         "candidates" "[${NAMES_JSON}]" \
         "to" "$(json_str "$TO")" "msg" "$(json_str "$MSG")"
    exit 1
  fi

  if [ -z "$RESULT" ]; then
    # ── 收件人找不到时：问一句，但不猜（用户定稿：实在找不到才问）──
    # ⚠ 试过"自动列出最接近的候选"，实测全屏 OCR 把聊天列表/时间戳也当成候选，
    #   给出「温昼、昨天 22:28」这种噪音 —— 猜错比不猜更糟（会让人以为系统认错了人）。
    #   所以这里只**明确问一句**，把判断权交回用户。
    propose "微信搜索联系人:$TO" "未命中"
    audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_ELEMENT_NOT_FOUND" "未找到联系人"
    emit 0 "wechat_send" "$TO" 0 "没搜到「${TO}」。给我一个更准的写法（全名/备注名/群名）我就发。" "$ERR_ELEMENT_NOT_FOUND"
    exit 1
  fi

  set -- $RESULT
  RX="$1"; RY="$2"; RW="$3"; RH="$4"
  # 点结果项左侧文字区（AX 报告整行起点，文字只占左侧）
  RCLICK_X=$(( RX + 24 ))
  RCLICK_Y=$(( RY + RH / 2 ))
  m click --at "$RCLICK_X,$RCLICK_Y" >/dev/null 2>&1
  sleep 1.5
fi

# ── 9. 定位聊天输入框 ──────────────────────────────────────────
STATE2_FILE="$(mj_file wx3 state --app "$BUNDLE" --depth 10)"
INPUT_XY="$(json_query "$STATE2_FILE" chat_input_box)"
rm -f "$STATE2_FILE" 2>/dev/null

if [ -z "$INPUT_XY" ]; then
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_ELEMENT_NOT_FOUND" "无聊天输入框"
  emit 0 "wechat_send" "$TO" 0 "找不到聊天输入框" "$ERR_ELEMENT_NOT_FOUND"
  exit 1
fi

IX="${INPUT_XY% *}"; IY="${INPUT_XY#* }"

# ── 10. 确认闸（L1：未确认不发送）───────────────────────────────
# 此时所有可逆步骤已完成（已定位到正确会话），但「发送」不可逆。
#
# ⚠ 2026-10-22 改造（回应用户实测反馈）：
#   原实现在这里emit need_confirm 就退出，把确认提示**打在终端 stdout**。
#   而用户人在 flash 面板前 —— 一个需要确认的流程，确认入口不在用户眼前
#   就等于死锁（用户原话：「他让我确认，可我根本不知道该在界面哪里去确认」）。
#
#   现在改为：把待确认项写进 flash 的确认队列，flash 面板每 400ms 扫一次，
#   把它渲染成「⚠️ 等待你确认 + 确认执行/放弃」按钮。**点一下即完成。**
#   同时保留原来的 emit —— 这样模型（WorkBuddy）那条路径依然能拿到提示词。
#
#   没有 flash 在跑也不要紧：队列只是多写一个 JSON 文件，
#   下次 `flashctl.sh status` 或面板唤起时会显示出来，不影响原流程。
# ── 确认闸的开关（2026-10-23 用户定稿）─────────────────────────────
# 用户原话：「只要用户在指令里要求发送或表示允许发送，即可发送；不得二次询问
# —— 二次询问用户，用户会觉得麻烦，低效、不自动化。」
# 所以**默认不再拦路**：走到这里说明是用户的指令要求发的（或 agent 被要求发的），
# 定位到会话后直接发，只把「收件人+内容」回读出来。
# 想恢复"发前必须点一次确认"：WECHAT_GATE=1。
# ⚠ 唯一保留的"问用户"场景：收件人定位不到（见上面的候选列表分支）。
if [ "${WECHAT_GATE:-0}" = "1" ] && [ "$CONFIRMED" != "1" ]; then
  TEMPLATE="$(confirm_template "$TO" "$MSG")"
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "" "待用户确认: $TEMPLATE"

  # 写入 flash 确认队列（id 用 to+msg 的哈希，稳定可重复查询）
  QID="wx_$(printf '%s|%s' "$TO" "$MSG" | shasum 2>/dev/null | cut -c1-12)"
  if [ -x "$DIR/flash" ]; then
    "$DIR/flash" queue add \
      --id "$QID" \
      --title "给${TO} 发微信" \
      --detail "${MSG}" \
      --script "wechat_send.sh" \
      --args "--to,${TO},--msg,${MSG},--confirmed" \
      --risk "对外发送（不可撤销）" >/dev/null 2>&1 || true
  fi

  emit 0 "wechat_send" "$TO" 1 "$TEMPLATE" "" \
    "confirm_prompt" "$(json_str "$TEMPLATE")" \
    "confirm_id" "$(json_str "$QID")" \
    "confirm_hint" "$(json_str "在灵台智枢点「确认执行」即可完成；或重跑并加 --confirmed")" \
    "to" "$(json_str "$TO")" \
    "msg" "$(json_str "$MSG")"
  exit 2
fi

if [ "$DRY" = "1" ]; then
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "ok" "" "dry-run 已定位到 $TO 的会话"
  emit 1 "wechat_send" "$TO" 0 "已定位到「${TO}」会话（dry-run 未发送）" ""
  exit 0
fi

# ── 11. 输入并发送 ─────────────────────────────────────────────
# ⚠⚠ 2026-10-23 实测事故：跑完显示"已点击发送，但未在窗口中看到消息"，
#   而对方**根本没收到**（用户确认）。原因有两个：
#   ① 消息可能压根没进输入框（clear/type 失败没人管），点"发送"等于发空；
#   ② `click --text 发送` 依赖按钮文字定位，窗口一变就点偏。
#   改法：
#   ① 输入后**必须回读输入框**，没有字就重来一次，绝不"盲发"；
#   ② 用 **Enter 发送**（微信原生行为，不依赖坐标），失败再退回点按钮。
send_attempt() {
  m click --at "$IX,$IY" >/dev/null 2>&1
  sleep 0.35
  m clear --app "$BUNDLE" >/dev/null 2>&1
  # ⚠ 微信的聊天输入框也是自绘的：`type`（AX/合成键）常常打不进去，
  #   实测必须走剪贴板粘贴（跟酷狗同一个坑）。失败时再退回 type。
  printf '%s' "$MSG" | /usr/bin/pbcopy
  sleep 0.25
  m key --key v --cmd >/dev/null 2>&1
  sleep 0.8
  if ! m ocr --app "$BUNDLE" 2>/dev/null | /usr/bin/grep -qF "$MSG"; then
    m type --text "$MSG" --app "$BUNDLE" >/dev/null 2>&1
    sleep 0.8
  fi
  # 回读：输入框里到底有没有这段字（OCR 比 AX 可靠，微信输入框是自绘的）
  _OCR="$(m ocr --app "$BUNDLE" 2>/dev/null)"
  if [ "${WECHAT_DEBUG:-0}" = "1" ]; then
    printf '[dbg] IX=%s IY=%s front=%s ocr_hit=%s\n' "$IX" "$IY" \
      "$(m state 2>/dev/null | /usr/bin/sed -n 's/.*bundle=\([^ ]*\).*/\1/p' | head -1)" \
      "$(printf '%s' "$_OCR" | /usr/bin/grep -cF "$MSG")" >> /tmp/wxdbg.log
  fi
  if ! printf '%s' "$_OCR" | /usr/bin/grep -qF "$MSG"; then
    return 1
  fi
  m key --key return >/dev/null 2>&1     # 微信：回车即发送
  sleep 1.6
  return 0
}

TYPED=0
for i in 1 2 3; do
  if send_attempt; then TYPED=1; break; fi
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "info" "input_retry" "第 ${i} 次输入没回读到内容，重试"
  sleep 0.6
done
if [ "$TYPED" = "0" ]; then
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "INPUT_FAILED" "输入框没收到内容，未发送"
  emit 0 "wechat_send" "$TO" 0 "消息没能输入到微信输入框（试了两次），所以没发出去 —— 这次不是发失败，是没发。" "INPUT_FAILED"
  exit 1
fi

# ── 12. 验证：消息已上屏（FR-2：脚本自己验证，模型不追加调用）────
SENT=""
for i in 1 2 3 4; do
  ST_FILE="$(mj_file wx4 state --app "$BUNDLE" --depth 12)"
  SENT="$(json_query "$ST_FILE" has_text "$MSG")"
  rm -f "$ST_FILE" 2>/dev/null
  [ "$SENT" = "yes" ] && break
  SENT=""
  sleep 0.8
done

if [ -n "$SENT" ]; then
  audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "ok" "" "消息已上屏: $MSG"
  emit 1 "wechat_send" "$TO" 0 "消息已出现在与「${TO}」的聊天窗口" "" \
    "msg" "$(json_str "$MSG")"
  exit 0
fi

audit "wechat_send:$TO" "wechat_send.sh" "$LEVEL_L1" "fail" "$ERR_TIMEOUT" "消息未上屏"
emit 0 "wechat_send" "$TO" 0 "已点击发送，但未在窗口中看到消息" "$ERR_TIMEOUT"
exit 1
