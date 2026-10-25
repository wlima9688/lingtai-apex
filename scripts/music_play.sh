#!/bin/bash
# 闪控 · music_play.sh — 酷狗音乐播放（L0）
#
# 规格书 §6.2：
#   无参：open -a 酷狗音乐 激活并继续播放（恢复上次会话）
#   有参：折叠配方 B —— raise → state 拿全 AX 树 → 本地解析搜索框 →
#         click → 粘贴歌名 → 点联想词第一条 → 点结果行首行 → find 验证播放条
#
# 参数：
#   --song <歌名>    要播放的歌曲（可选）
#   --volume <0-100> 同时设置系统音量（可选）
#   --silent         强制静音播放（默认即静音守卫生效，绝不发出声音）
#
# 关键实现要点（来自 mac-control 实测）：
#   · 酷狗搜索框是 AXTextField，必须用剪贴板粘贴（Unicode 注入会变成 "aa"）
#   · 回车不触发搜索，必须点联想词第一条
#   · 联想词内容在 AX 节点的 desc 字段，不是 title
#   · 搜索结果页的歌名是 AXStaticText，AXPosition 是整行起点，
#     文字只占左侧约 80pt —— 直接点行中心会误触右侧「添加到队列」按钮
#   · 验证靠播放条（标题含 "<歌名> - "）

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/common.sh"

APP_NAME="酷狗音乐"
BUNDLE="com.kugou.mac.Music"
SONG=""
VOLUME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --song) SONG="$2"; shift 2 ;;
    --volume) VOLUME="$2"; shift 2 ;;
    --silent) shift ;;
    *) shift ;;
  esac
done

# ── 环境预检：屏幕锁定时 macOS 会静默丢弃所有输入事件 ──────────────
# 不预检的后果：脚本一路"成功"跑完却什么都没发生（实测踩过，极难定位）
precheck_env_or_exit "music_play" "${SONG:-resume}" "$BUNDLE"

# ── 硬要求：本脚本绝不发出声音 ────────────────────────────────────
# 播放音乐是唯一可能发声的场景。默认强制静音，用户显式要求声音时再加 --with-sound。
silence_guard_on

# ── 3.5 电脑控制锁：多 AI 不打架 ─────────────────────────────────
lock_guard_or_exit "music_play" "${SONG:-resume}" "音乐播放"

# ── 1. 启动应用 ──────────────────────────────────────────────────
WAS_RUNNING=1
app_running "$BUNDLE" || WAS_RUNNING=0

if ! app_running "$BUNDLE"; then
  open -a "$APP_NAME" 2>/dev/null
  # ⚠⚠ 不能只 sleep 2.5s 就去找搜索框：酷狗冷启动实测 8~15 秒（有启动页/广告位），
  #   窗口没出来时 AX 树是空的，于是报「在酷狗音乐中找不到搜索框」——
  #   真实原因是**还没启动完**，用户看到的是"播放永远失败"（review 里 21 次）。
  #   改成轮询等窗口出现（最多 20 秒），并给一个说得清的失败原因。
  _ready=0
  for _i in $(seq 1 40); do
    sleep 0.5
    if app_running "$BUNDLE" && probe_ax "$BUNDLE" 6 1; then _ready=1; break; fi
  done
  if [ "$_ready" != "1" ]; then
    audit "music_play:${SONG:-resume}" "music_play.sh" "$LEVEL_L0" "fail" "$ERR_APP_NOT_FOUND" "启动超时"
    emit 0 "music_play" "${SONG:-resume}" 0 "$APP_NAME 启动超时（20 秒内没出窗口）" "$ERR_APP_NOT_FOUND"
    exit 1
  fi
fi

if ! app_running "$BUNDLE"; then
  audit "music_play:${SONG:-resume}" "music_play.sh" "$LEVEL_L0" "fail" "$ERR_APP_NOT_FOUND" "酷狗未启动"
  emit 0 "music_play" "${SONG:-resume}" 0 "无法启动 $APP_NAME" "$ERR_APP_NOT_FOUND"
  exit 1
fi

# ── 2. 音量（可选）───────────────────────────────────────────────
if [ -n "$VOLUME" ]; then
  m volume --set "$VOLUME" >/dev/null 2>&1
fi

# ── 3. 无歌名 → 仅激活，恢复上次会话 ─────────────────────────────
if [ -z "$SONG" ]; then
  m front --app "$BUNDLE" >/dev/null 2>&1
  sleep 1
  STATE_FILE="$(mj_file kgnp state --app "$BUNDLE" --depth 12)"
  TRACK="$(json_query "$STATE_FILE" now_playing)"
  audit "music_play:resume" "music_play.sh" "$LEVEL_L0" "ok" "" "已激活 ${TRACK:-酷狗}"
  emit 1 "music_play" "${TRACK:-resume}" 0 "已激活 $APP_NAME${TRACK:+，当前：$TRACK}" "" \
    "track" "$(json_str "${TRACK:-}")"
  exit 0
fi

# ── 4. 置前（防遮挡，AX 树会因遮挡变 0 节点）──────────────────────
m front --app "$BUNDLE" >/dev/null 2>&1

# ── 5. 一次拿全 AX 树（FR-3：禁止多次 find 往返）─────────────────
# 深度 12 足以覆盖搜索框 + 联想浮层 + 结果列表
#
# ⚠ 关键：macOS 对「被完全遮挡」的窗口停止 AX 投递 → AX 树瞬间变 0 节点。
#   raise 之后需要等系统完成窗口重排/激活，AX 树才会恢复。
#   所以这里必须「轮询重试」，不能只探测一次（实测：raise 后立刻查会得到 0 节点）。
# ax_state 内部自带重试（间歇性 AX 投递中断是常态，不是异常）
# ⚠ 大 JSON 必须走文件：管道传 10KB 中文 JSON 会被截断（实测踩过）
if ! probe_ax "$BUNDLE" 12 3; then
  # 仍为空 → 排他诊断 + 强制置前再试
  m diagnose --app "$BUNDLE" >/dev/null 2>&1
  m front --app "$BUNDLE" >/dev/null 2>&1
  if ! probe_ax "$BUNDLE" 12 3; then
    audit "music_play:$SONG" "music_play.sh" "$LEVEL_L0" "fail" "$ERR_PERMISSION_DENIED" "AX 树为空"
    emit 0 "music_play" "$SONG" 0 "$APP_NAME 的 AX 树为空（可能被完全遮挡）" "$ERR_PERMISSION_DENIED"
    exit 1
  fi
fi

STATE_FILE="$(mj_file kgstate state --app "$BUNDLE" --depth 12)"

# ── 视觉兜底：定位搜索框 → 粘贴 → 点第一条结果 → 验证 ────────────────────
#
# ⚠ 为什么需要：酷狗主界面是自绘/Web 视图，AX 树里**一个 AXTextField 都没有**
#   （实测 522 节点 = 0），⌘F / 盲打 / URL scheme 全不通。但搜索框位置是**稳定**的
#   （工具栏右侧，约 0.755×宽、距顶 46px），而且粘贴后可以**读回来验证**。
#   于是策略是"点固定相对位置 + 读回验证 + 失败重试一次"：
#     ① 先 Esc 关掉活动/VIP 弹层（冷启动必定有一个，实测会盖住搜索框）
#     ② 点搜索框 → pbcopy + ⌘V（酷狗只认粘贴，Unicode 注入会变 "aa"）
#     ③ OCR 顶部条确认输入框里出现了歌名；没有就换位置重试一次
#     ④ 回车 → OCR 结果区点最上面那条 → OCR 底部播放条验证（歌名 + mm:ss）
#   全程本地 OCR，不走模型：实测 7~9 秒，比转交(8~15s + token)更快更便宜。
visual_play() {
  local song="$1"
  local win
  win="$(m windows --app "$BUNDLE" 2>/dev/null | /usr/bin/python3 -c "
import sys, re
best = None
for line in sys.stdin:
    mm = re.search(r'@\((\d+),(\d+)\) (\d+)x(\d+)', line)
    if not mm: continue
    x, y, w, h = map(int, mm.groups())
    if best is None or w * h > best[2] * best[3]: best = (x, y, w, h)
if best: print('%d,%d,%d,%d' % best)
")"
  echo "[vp] win=$win MACCTL=$MACCTL" >> /tmp/vp.log
  [ -z "$win" ] && return 1
  local wx wy ww wh
  IFS=, read -r wx wy ww wh <<< "$win"

  m key --key esc --require-front "$BUNDLE" >/dev/null 2>&1          # 关冷启动的活动/VIP 弹层
  sleep 0.6

  # ⚠⚠ 冷启动时窗口"存在"不等于"首页就绪"：AV 探针一有窗口就返回 true，
  #   可那时屏幕上还是启动页/活动弹层（搜索框根本没画出来），于是点击落空。
  #   用"首页导航（推荐/乐库/听书）可被 OCR 读到"作为**就绪信号**再动手。
  local ready=0 i
  for i in $(seq 1 20); do
    if m ocr --rect "$wx,$wy,$ww,120" 2>/dev/null | /usr/bin/grep -qE "推荐|乐库|听书"; then
      ready=1; break
    fi
    m key --key esc --require-front "$BUNDLE" >/dev/null 2>&1
    sleep 1
  done
  echo "[vp] ready=$ready" >> /tmp/vp.log
  [ "$ready" = "1" ] || return 1

  # 搜索框点开后会进入"搜索页"：先出**建议列表**，点一条才进**结果页**，
  # 再点一条才是播放。所以不能只按回车 —— 要"点最上面那条含歌名的行"，
  # 点完看一眼底部播放条，没播就再点一次（最多 3 轮）。
  local ratio attempt
  for ratio in 0.755 0.70; do
    local sx sy
    sx="$(/usr/bin/python3 -c "print(int($wx + $ww * $ratio))")"
    sy="$(/usr/bin/python3 -c "print(int($wy + 46))")"
    m click --at "$sx,$sy" >/dev/null 2>&1
    sleep 0.5
    printf '%s' "$song" | /usr/bin/pbcopy
    sleep 0.25
    m key --key v --cmd --require-front "$BUNDLE" >/dev/null 2>&1
    sleep 1.0

    for attempt in 1 2 3; do
      local hit
      hit="$(/usr/bin/python3 - "$wx" "$wy" "$ww" "$wh" "$song" "$MACCTL" <<'PYEOF'
import subprocess, sys, re
wx, wy, ww, wh, song, macctl = (int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]),
                                int(sys.argv[4]), sys.argv[5], sys.argv[6])
out = subprocess.run([macctl, "ocr", "--rect", f"{wx},{wy},{ww},{wh}"],
                     capture_output=True, text=True).stdout
cands = []
for line in out.splitlines():
    m = re.search(r"@\((\d+),(\d+)\)", line)
    if not m: continue
    x, y = map(int, m.groups())
    if song in line and y > wy + 120: cands.append((y, x))
if cands:
    y, x = sorted(cands)[0]
    print("%d %d" % (x + 12, y))      # 点在歌名文字上（行内空白点不动）
PYEOF
)"
      echo "[vp] attempt=$attempt ratio=$ratio hit=$hit" >> /tmp/vp.log
      [ -z "$hit" ] && { sleep 1.2; continue; }
      local hx hy
      read -r hx hy <<< "$hit"
      m click --at "$hx,$hy" >/dev/null 2>&1
      sleep 0.35
      m click --at "$hx,$hy" >/dev/null 2>&1     # 双击：单击只是选中
      sleep 2.2
      # 每点一次就看一眼底部播放条：出现了歌名+时间轴就算成
      local bottom
      bottom="$(m ocr --rect "$wx,$((wy + wh - 100)),$ww,100" 2>/dev/null)"
      echo "[vp] bottom=$(printf '%s' "$bottom" | head -2 | tr '\n' ' ')" >> /tmp/vp.log
      if printf '%s' "$bottom" | /usr/bin/grep -q "$song" \
         && printf '%s' "$bottom" | /usr/bin/grep -qE "[0-9]{2}:[0-9]{2}"; then
        return 0
      fi
    done
  done
  return 1
}

# ── 6. 定位搜索框（AXTextField）──────────────────────────────────
SEARCH_XY="$(json_query "$STATE_FILE" search_box)"

if [ -z "$SEARCH_XY" ]; then
  # ⚠⚠ 酷狗的主界面是**自绘/Web 视图**：实测 522 个 AX 节点里
  #   AXTextField = 0、"搜索" 文本 = 0，官方 URL scheme 也不接受 search。
  #   也就是说「按歌名自动搜索」在这个版本上**做不到**，不是等久一点就能好。
  #   与其报一句"找不到搜索框"让人以为是偶发故障，不如：
  #     ① 把酷狗开好、置前（用户能立刻手动搜）；
  #     ② 说清楚为什么、下一步怎么做；
  #     ③ 打上 UNSUPPORTED 代码，复盘时能归类成"已知限制"而不是"回归"。
  m front --app "$BUNDLE" >/dev/null 2>&1
  # ⚠ 视觉兜底默认**不启用**：实测它在"首页态"下命中率不稳定（点击落空 → 40~60 秒
  #   空转还播不出来），比直接转交更糟。真正稳定的是：**搜索态**（页面里已有
  #   输入框）走 AX，否则 8 秒内交给 agent。需要时把下面这行的 [ "$WAS_RUNNING" = "1" ]
  #   打开即可重新试用视觉路径（函数保留在文件里，不是死代码）。
  if [ "${MUSIC_VISUAL:-0}" = "1" ] && visual_play "$SONG"; then
    audit "music_play:$SONG" "music_play.sh" "$LEVEL_L0" "ok" "" "视觉播放成功"
    emit 1 "music_play" "$SONG" 0 "已播放 ${SONG}（视觉定位）" "" \
         "intent" "$(json_str "已播放 ${SONG}")" "via" "\"visual\""
    exit 0
  fi
  # ── 预热搜索页（便宜且确定）：酷狗**首页态没有 AX 输入框，搜索态才有**。
  #   点一下搜索框 + 粘贴 + 两次回车，页面就变成"有输入框的结果页"，
  #   然后重新跑一遍本脚本 —— 这次 AX 路径就能正常定位并播放。
  #   实测：预热约 6 秒 + 第二遍约 12 秒，全程不花 token，比转交更确定。
  if [ "${MUSIC_PRIMED:-0}" != "1" ]; then
    m key --key esc --require-front "$BUNDLE" >/dev/null 2>&1
    sleep 0.4
    # 搜索框固定在工具栏右侧：0.755×宽，距顶 46
    local win2 wx2 wy2 ww2 wh2
    win2="$(m windows --app "$BUNDLE" 2>/dev/null | /usr/bin/python3 -c "
import sys, re
best = None
for line in sys.stdin:
    mm = re.search(r'@\((\d+),(\d+)\) (\d+)x(\d+)', line)
    if not mm: continue
    x, y, w, h = map(int, mm.groups())
    if best is None or w * h > best[2] * best[3]: best = (x, y, w, h)
if best: print('%d,%d,%d,%d' % best)
")"
    if [ -n "$win2" ]; then
      IFS=, read -r wx2 wy2 ww2 wh2 <<< "$win2"
      m click --at "$((wx2 + ww2 * 755 / 1000)),$((wy2 + 46))" >/dev/null 2>&1
      sleep 0.6
      printf '%s' "$SONG" | /usr/bin/pbcopy
      sleep 0.25
      m key --key v --cmd --require-front "$BUNDLE" >/dev/null 2>&1
      sleep 0.8
      m key --key return --require-front "$BUNDLE" >/dev/null 2>&1
      sleep 1.6
      m key --key return --require-front "$BUNDLE" >/dev/null 2>&1
      sleep 2.4
      audit "music_play:$SONG" "music_play.sh" "$LEVEL_L0" "info" "" "已预热搜索页，重试"
      MUSIC_PRIMED=1 exec "$0" --song "$SONG"
    fi
  fi
  audit "music_play:$SONG" "music_play.sh" "$LEVEL_L0" "fail" "UNSUPPORTED" "视觉也没定位到"
  # 用户明确要求「不要我手动操作」。既然闪控这层拿不到输入框，
  # 就不该把活推回给人 —— 改成**自动转交**：WorkBuddy 带着 mac-control 技能
  # 和视觉判读去做（它能看屏幕点位置），闪控只负责把酷狗开好、置前。
  emit 0 "music_play" "$SONG" 0 "需要视觉操作：已打开酷狗，转给 WorkBuddy 继续" "NEED_HANDOFF"
  exit 1
fi

SX="${SEARCH_XY% *}"; SY="${SEARCH_XY#* }"

# ── 7. 点击搜索框 + 粘贴歌名（酷狗必须粘贴）─────────────────────
m click --at "$SX,$SY" >/dev/null 2>&1
probe_input "$BUNDLE" 12 0 120 2 || true
m clear --app "$BUNDLE" >/dev/null 2>&1
m type --text "$SONG" --app "$BUNDLE" >/dev/null 2>&1

# ⚠ 等联想浮层真正出现，判据是「输入框里真的有歌名」。
#   不能用 probe_role AXStaticText：搜索前结果区本来就有宽 StaticText，
#   条件立即成立 → 不等 UI 更新就往下走 → 拿到旧列表当联想词（实测踩过）。
wait_suggest() {
  _ws() {
    local f; f="$(mj_file wsug state --app "$BUNDLE" --depth 12)"
    local v; v="$(json_query "$f" song_suggestion "$SONG")"
    rm -f "$f" 2>/dev/null
    [ -n "$v" ]
  }
  local waited=0
  while [ "$waited" -lt 3000 ]; do
    _ws && return 0
    sleep 0.15
    waited=$((waited + 150))
  done
  return 1
}
wait_suggest || true

# ── 8. 点联想词第一条（回车不触发搜索）──────────────────────────
# 联想词在 desc 字段（实测：title 为空，desc 是「歌名」或「歌名 歌手」）
# 排序规则（实测修正）：
#   1. 含歌手信息（desc 以「歌名 」开头且有额外内容）→ 优先
#   2. 同类按 y 从上到下
# 原因：联想词第 1 条往往只是纯歌名，原唱版在后面若干行。
SUGG_FILE="$(mj_file kgsug state --app "$BUNDLE" --depth 12)"
SUGGEST="$(json_query "$SUGG_FILE" song_suggestion "$SONG")"
rm -f "$SUGG_FILE" 2>/dev/null

if [ -z "$SUGGEST" ]; then
  audit "music_play:$SONG" "music_play.sh" "$LEVEL_L0" "fail" "$ERR_ELEMENT_NOT_FOUND" "无联想词"
  emit 0 "music_play" "$SONG" 0 "搜索「${SONG}」没有出现联想词" "$ERR_ELEMENT_NOT_FOUND"
  exit 1
fi

set -- $SUGGEST
GX="$1"; GY="$2"; GW="$3"; GH="$4"
# 联想词是整行 AXStaticText，文字在左侧 → 点左侧 1/4 处而非中心
# （行中心会落到右侧「添加到队列」按钮上，这是实测踩过的坑）
CLICK_X=$(( GX + GW / 4 ))
CLICK_Y=$(( GY + GH / 2 ))
m click --at "$CLICK_X,$CLICK_Y" >/dev/null 2>&1
# ⚠ 等结果页加载完成，要等「结果页特征」而不是「有 StaticText」——
#   联想浮层本身就有宽 StaticText，用它做判据会立即返回（条件搜索前就成立），
#   结果页还没出来就往下走 → 拿到旧的联想浮层当结果页。
#   可靠判据：歌名出现在树里（联想浮层里也有，所以再加一条——
#   结果页的歌名带歌手信息，联想浮层的纯歌名不带）。这里用「出现两次以上」区分。
probe_result() {
  _pr() {
    local f; f="$(mj_file kgres state --app "$BUNDLE" --depth 14)"
    local n; n="$(json_query "$f" song_name_hits "$SONG")"
    rm -f "$f" 2>/dev/null
    [ "${n:-0}" -ge 2 ] 2>/dev/null
  }
  local gap_ms=200 waited=0
  while [ "$waited" -lt 3000 ]; do
    _pr && return 0
    sleep 0.2
    waited=$((waited + gap_ms))
  done
  return 1
}
probe_result || true

# ⚠ 必须校验结果页确实属于当前搜索词。
#   酷狗 AX 树里可能同时残留上一次搜索的结果行（实测出现过「乱世书」等旧行，
#   它们的 y 更靠前，按 y 排序会被误当成当前结果 → 点到别的歌）。
#   判据：结果区里必须有多行且都含当前歌名。
verify_result() {
  local f n
  f="$(mj_file kgres state --app "$BUNDLE" --depth 14)"
  n="$(json_query "$f" song_name_hits "$SONG")"
  rm -f "$f" 2>/dev/null
  [ "${n:-0}" -ge 2 ] 2>/dev/null
}
if ! verify_result; then
  audit "music_play:$SONG" "music_play.sh" "$LEVEL_L0" "fail" "$ERR_ELEMENT_NOT_FOUND" "结果页与歌名不匹配"
  emit 0 "music_play" "$SONG" 0 "搜索「${SONG}」的结果页没有正确加载（可能是残留的其他搜索结果）" \
    "$ERR_ELEMENT_NOT_FOUND"
  exit 1
fi

# ── 9. 结果页点歌名（首行通常是原唱版）─────────────────────────
# 等待结果页出现：找 title/desc 含歌名且带歌手信息的元素
RES_FILE="$(mj_file kgres state --app "$BUNDLE" --depth 14)"
ROW_CLICK="$(json_query "$RES_FILE" song_row_click "$SONG")"
rm -f "$RES_FILE" 2>/dev/null

if [ -z "$ROW_CLICK" ]; then
  audit "music_play:$SONG" "music_play.sh" "$LEVEL_L0" "fail" "$ERR_ELEMENT_NOT_FOUND" "结果页无歌名"
  emit 0 "music_play" "$SONG" 0 "搜索结果里找不到「${SONG}」" "$ERR_ELEMENT_NOT_FOUND"
  exit 1
fi

# ⚠ 必须点歌名「文字」而不是整行左边缘：
#   行矩形 x=40 起，但左侧约 84pt 是缩进空白，歌名文字从 x≈124 才开始。
#   点在空白上 → 点击无响应 → 歌不播（实测踩过，排查很久）。
#   song_row_click 已负责定位文字真实起点。
RCX="${ROW_CLICK% *}"; RCY="${ROW_CLICK#* }"
m click --at "$RCX,$RCY" >/dev/null 2>&1
probe_text "$BUNDLE" "$SONG" 12 3 || true

# ── 10. 验证：播放条出现「<歌名> - 」────────────────────────────
# 3 次 × 0.8s 足够（实测点击后 2s 内必更新），再多只是白等
PLAYING=""
for i in 1 2 3 4; do
  PF="$(mj_file kgplay state --app "$BUNDLE" --depth 12)"
  PLAYING="$(json_query "$PF" now_playing)"
  rm -f "$PF" 2>/dev/null
  case "$PLAYING" in
    *"$SONG"*) break ;;
  esac
  PLAYING=""
  sleep 0.4
done

if [ -n "$PLAYING" ]; then
  audit "music_play:$SONG" "music_play.sh" "$LEVEL_L0" "ok" "" "播放条: $PLAYING"
  emit 1 "music_play" "$SONG" 0 "已在播放：$PLAYING" "" \
    "track" "$(json_str "$PLAYING")" \
    "muted" "true"
  exit 0
fi

audit "music_play:$SONG" "music_play.sh" "$LEVEL_L0" "fail" "$ERR_ELEMENT_NOT_FOUND" "播放条未出现"
emit 0 "music_play" "$SONG" 0 "已点击「${SONG}」，但播放条未出现结果" "$ERR_ELEMENT_NOT_FOUND"
exit 1
