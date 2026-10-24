#!/bin/bash
# 闪控 · route.sh — 自然语言意图路由器（L1 指令入口的大脑）
#
# 存在的理由：
#   用户想「随手打一句话就干活」，而不是每次都让我（模型）把意图翻译成命令行。
#   但路由器**不需要大模型** —— 它靠关键词 + 槽位抽取，
#   秒级响应、离线可用、零成本、不确定性低。
#
# 边界（诚实说明，别过度承诺）：
#   它只认路由表里写过的句式。认不出来就返回 ok=false + 候选提示，
#   **绝不猜着执行** —— 猜错就是发错消息、点错按钮，代价比"没听懂"高得多。
#   复杂/开放式任务（如"帮我写一篇稿子并排版"）应该切 WorkBuddy 走 L2。
#
# 参数：
#   route.sh "<一句话意图>"            路由并执行
#   route.sh --list                    列出所有可识别的句式（自省用）
#   route.sh --dry-run "<一句话>"       只解析不执行（调试/确认用）
#
# 输出：统一 JSON（见 common.sh 的 emit 契约）

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/common.sh"

DRY=0
INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --list) INPUT="__LIST__"; shift ;;
    *) INPUT="$1"; shift ;;
  esac
done

# ── 路由表 ───────────────────────────────────────────────────
# 每条规则：正则捕获 → 目标脚本 + 参数绑定
#
# ⚠ 设计原则（ponytail）：
#   只写**真正高频**的句式，一条都不加。其余一律 ok=false。
#   路由表的价值在于"覆盖高频"，不是"覆盖所有"。
#
# 槽位约定：
#   $1 = 主对象（人名/歌名/文件名）
#   $2 = 内容（消息正文）

if [ "$INPUT" = "__LIST__" ]; then
  #⚠ 一次调用两种受众（common.sh 的「一次调用原则」）：
  #   第一行 JSON 给模型解析，后面是人读的表格给用户看。
  #   之前只出多行 JSON —— 合法但人读不了，而 `--list` 大多是人敲的。
  cat <<'JSON'
{"ok":true,"patterns":[
 {"re":"给(.+)发(微信|消息)[:：]?(.+)","run":"wechat_send.sh --to <$1> --msg <$2>","desc":"给某人发微信"},
 {"re":"微信(告诉|发).+[:：]?(.+)","run":"wechat_send.sh --to <当前会话> --msg <$1>","desc":"给当前会话发消息"},
 {"re":"播放(.+)","run":"music_play.sh --song <$1>","desc":"播放某首歌"},
 {"re":"打开(抖音|快手|小红书)","run":"douyin_open.sh","desc":"打开短视频应用"},
 {"re":"打开(.+)\\.(\\w+)$","run":"open_file.sh --name <$1.$2>","desc":"按文件名打开文件"},
 {"re":"打开(.+)","run":"open_file.sh --name <$1>","desc":"按名称打开文件"},
 {"re":"截图","run":"macctl shot","desc":"截屏"},
 {"re":"音量(\\d+)","run":"macctl volume --set <$1>","desc":"设置音量"},
 {"re":"(静音|关声音)","run":"macctl volume --set 0","desc":"静音"},
 {"re":"打开(闪控帮助|帮助)","run":"macctl doctor","desc":"环境体检"},
 {"re":"桌面上有什么|看看桌面","run":"macctl overview","desc":"查看桌面概览"},
 {"re":"读(一下)?屏幕|读屏|屏幕上(写|有)什么","run":"macctl ocr","desc":"把屏幕上的字读出来"}
]}
JSON
  echo ""
  echo "── 能听懂的说法 ──"
  echo "  给张三发微信:你好给李四发消息:在吗"
  echo "  播放周杰伦的青花瓷              放一首晴天            听稻香"
  echo "  打开抖音                        打开快手              打开小红书"
  echo "  打开报告.pdf                    打开酷狗音乐"
  echo "  截图                            桌面上有什么"
  echo "  音量30                          静音"
  echo "  闪控帮助"
  echo ""
  echo "复杂任务（写稿/ 排版 / 多步操作）请切 WorkBuddy —— 那里有大脑。"
  exit 0
fi

if [ -z "$INPUT" ]; then
  audit "route" "route.sh" "$LEVEL_L0" "fail" "$ERR_ELEMENT_NOT_FOUND" "缺少指令文本"
  emit 0 "route" "" 0 "缺少指令文本" "$ERR_ELEMENT_NOT_FOUND" \
       "hint" "$(json_str '用法: route.sh "给张三发微信:你好"')"
  exit 2
fi

audit "route" "route.sh" "$LEVEL_L0" "info" "route_intent" "收到指令: $INPUT"

# ── 槽位抽取 ─────────────────────────────────────────────────
# 归一化：全角冒号/逗号 → 半角，去首尾空白。中英文标点混用太常见。
NORM="$(printf '%s' "$INPUT" \
  | sed -e 's/：/:/g' -e 's/，/,/g' -e 's/、/ /g' \
        -e 's/[[:space:]]\+/ /g' -e 's/^ *//' -e 's/ *$//')"

# 兼容「微信,给X发送:Y」「给X发送:Y」→ 归一到「给X发微信:Y」
# 只处理带冒号的发送句式；不碰「给X发邮件:Y」这类非微信目标。
NORM="$(printf '%s' "$NORM" | sed -E \
  -e 's/^微信,给(.+)(发送|发):/给\1发微信:/' \
  -e 's/^给(.+)(发送|发):/给\1发微信:/')"

TARGET=""      # 目标脚本
ARGS=()        # 传给目标脚本的参数
DESC=""        # 人类可读的动作描述（汇报用）

case "$NORM" in
  # ── 微信发消息 ──
  给*发微信:*|给*发消息:*|给*微信:*)
    # 「给张三发微信:你好」→ TO=张三 MSG=你好
    # 用 sed 一次性切开，比 grep -o 多次调用快，也避免中文按字节匹配的坑。
    PAIR="${NORM#*:}"
    HEAD="${NORM%%:*}"
    # HEAD 形如「给张三发微信」→ 去掉前缀「给」和后缀「发微信/发消息/微信」
    TO="$(printf '%s' "$HEAD" | sed -e 's/^给//' -e 's/发微信$//' -e 's/发消息$//' -e 's/微信$//')"
    TO="$(printf '%s' "$TO" | sed -e 's/^ *//' -e 's/ *$//')"
    [ -z "$TO" ] && TO="文件传输助手"
    if [ -z "$PAIR" ]; then
      emit 0 "route" "" 0 "需要补充信息：要给 $TO 发什么？" "$ERR_AMBIGUOUS" "hint" "$(json_str "给 $TO 发微信:你好")"
      exit 2
    fi
    TARGET="wechat_send.sh"; ARGS=(--to "$TO" --msg "$PAIR"); DESC="给 $TO 发微信：$PAIR"
    ;;
  给*发微信|给*发消息|给*微信)
    TO="$(printf '%s' "$NORM" | sed -e 's/^给//' -e 's/发微信$//' -e 's/发消息$//' -e 's/微信$//')"
    TO="$(printf '%s' "$TO" | sed -e 's/^ *//' -e 's/ *$//')"
    [ -z "$TO" ] && TO="文件传输助手"
    emit 0 "route" "" 0 "需要补充信息：要给 $TO 发什么？" "$ERR_AMBIGUOUS" "hint" "$(json_str "给 $TO 发微信:你好")"
    exit 2
    ;;
  微信:*|微信说:*|告诉*)
    MSG="${NORM#*:}"
    [ "$MSG" = "$NORM" ] && MSG="$NORM"   # 「告诉张三你好」这种没冒号的
    MSG="${MSG#微信}"; MSG="${MSG#说}"
    if [ -z "$MSG" ]; then
      emit 0 "route" "" 0 "需要补充信息：要发什么内容？" "$ERR_AMBIGUOUS" "hint" "$(json_str '微信:你好')"
      exit 2
    fi
    TARGET="wechat_send.sh"; ARGS=(--to "文件传输助手" --msg "$MSG"); DESC="发微信：$MSG"
    ;;
  # ── 音乐 ──
  播放*|放一首*|放首*|听*)
    SONG="${NORM#播放}"; SONG="${SONG#放一首}"; SONG="${SONG#放首}"; SONG="${SONG#听}"
    SONG="$(printf '%s' "$SONG" | sed -e 's/^ *//' -e 's/ *$//' -e 's/^的//')"
    TARGET="music_play.sh"; ARGS=(--song "$SONG"); DESC="播放 $SONG"
    ;;
  # ── 应用/文件 ──
  打开抖音|刷抖音)   TARGET="douyin_open.sh"; DESC="打开抖音" ;;
  打开快手)          TARGET="quick_open";  DESC="打开快手" ;;
  打开小红书)        TARGET="quick_open";  DESC="打开小红书" ;;
  打开闪控帮助|闪控帮助|帮助) TARGET="doctor"; DESC="环境体检" ;;
  截图|截屏|截个图)   TARGET="shot"; DESC="截图" ;;
  # 读屏：用户拍板"授权超高权限"后才有意义 —— 直接 OCR 当前屏幕
  读屏|读屏幕|读一下屏幕|屏幕上写了什么|屏幕上有什么字|屏幕上是什么)
    TARGET="readscreen"; DESC="读屏幕文字" ;;
  # 录屏：走脚本而非单条命令，因为它是「开始/停止」二态（D-022）
  录屏|开始录屏|录个屏|录一下)
    TARGET="screen_rec.sh"; ARGS=(--toggle); DESC="录屏（再按一次停止）" ;;
  停止录屏|结束录屏)
    TARGET="screen_rec.sh"; ARGS=(--stop); DESC="停止录屏" ;;
  桌面上有什么|看看桌面|看看屏幕) TARGET="overview"; DESC="查看桌面" ;;
  打开|打开文件|打开一下)
    emit 0 "route" "" 0 "需要补充信息：要打开什么？" "$ERR_AMBIGUOUS" "hint" "$(json_str '打开 报告.pdf')"
    exit 2
    ;;
  # ── 启动/运行/打开应用 ──
  # ⚠⚠ 必须排在下面的 `打开*` **之前**（D-022）：
  #   「启动一下豆包」含「打开」？不 含 —— 但它含「启动」，
  #   而 `打开*` 只匹配「打开」前缀，case 的 `*` 通配在这里意味着
  #   「启动一下豆包」会掉到口语层再被 `*打开*` 子串命中，
  #   此时 NAME 已经是剥过的「启动一下豆包」→ 再剥一次才是「豆包」。
  #   与其两层互相干扰，不如在一处把启动类统一处理掉。
  启动*|运行*|开一下*|打开*)
    # 剥掉所有启动动词与语气词，只留应用名
    APPISH="${NORM}"
    for KW in 打开 启动一下 启动 运行一下 运行 开一下 开启 打开一下; do
      case "$APPISH" in
        "$KW"*) APPISH="${APPISH#$KW}" ;;
      esac
    done
    APPISH="$(printf '%s' "$APPISH" | sed -e 's/^ *//' -e 's/ *$//' -e 's/^一下//' -e 's/一下$//' -e 's/吧$//')"
    NAME="$APPISH"
    if printf '%s' "$NAME" | grep -qE '\.[a-zA-Z0-9]{1,5}$'; then
      TARGET="open_file.sh"; ARGS=(--name "$NAME"); DESC="打开文件 $NAME"
    elif [ -n "$NAME" ]; then
      TARGET="app_open"; ARGS=(--name "$NAME"); APP_NAME="$NAME"; DESC="打开 $NAME"
    fi
    ;;
  # ── 音量 ──
  音量*)
    V="${NORM#音量}"; V="$(printf '%s' "$V" | grep -oE '[0-9]+' | head -1)"
    [ -n "$V" ] && { TARGET="volume"; ARGS=("$V"); DESC="音量调到 $V"; }
    ;;
  静音|关声音|安静点)
    TARGET="volume"; ARGS=("0"); DESC="静音"
    ;;
esac

# ── 口语化兜底层 ──────────────────────────────────────────────
# ⚠ 存在的理由（用户实测反馈：「一定要固定格式，超出格式就无法解析」）：
#   上面那层 case 只认固定句式，「放一首晴天」「帮我把音量调大点」
#   「给张三发个微信」全都会落空 —— 用户被迫去记句式，这是效率的反面。
#
#   但**不能靠无限加句式解决**（那是打地鼠，永远追不上自然语言）。
#   这里加的是**结构化线索**，而不是同义词表：
#     · 关键词（音量/静音/截图/微信…）决定「做什么」
#     · 祈使词剥离（帮我/请/麻烦/把/一下…）决定「去掉客套」
#     · 数字直接当音量值
#   这样「帮我把音量调到30」和「音量30」走同一条路，不需要各写一条。
#
#   优先级：固定句式 > 兜底层。固定句式更精确，兜底只在它没命中时接管。
if [ -z "$TARGET" ]; then
  # ── ① 否定从句先剥离 ─────────────────────────────────────────
  # 实测踩过：「帮我写三句话的项目周报，**不要操作桌面**」命中了
  # 「桌面 → 查看桌面」，被当成简单任务执行 —— 用户说的是"不要动"，
  # 闪控读成"去看一下"。否定词后面的整段话都不该参与关键词匹配。
  MATCHTXT="$(printf '%s' "$NORM" \
    | sed -E 's/(不要|别|不用|无需|禁止|请勿|不能|千万别)[^，。；,;、]*//g')"

  # ── ② 复杂任务闸：宁可少接，交出去 ───────────────────────────
  # 判据是「这句话像不像要产出/要动多步」，不是长度：让 WorkBuddy 去做，
  # 闪控硬接只会做错一半然后还得人补。命中就**跳过整个兜底层**，
  # 落到下面的「未命中」→ 面板自动转交（这正是用户要的默认）。
  if printf '%s' "$MATCHTXT" | grep -qE '写|报告|总结|周报|方案|文案|分析|整理|翻译|计划|表格|排版|PPT|ppt'; then
    :
  else
  # 剥客套：帮我/帮忙/请/麻烦/你/把/给我 … 「一下/点/吧」等语气词
  LOOSE="$(printf '%s' "$MATCHTXT" \
    | sed -e 's/^帮我\{0,1\}//' -e 's/^帮忙//' -e 's/^请//' -e 's/^麻烦你\{0,1\}//' \
          -e 's/^你\{0,1\}//' -e 's/^把//' -e 's/^给我//' -e 's/^我要//' -e 's/^我想//' \
          -e 's/一下$//' -e 's/吧$//' -e 's/呗$//' -e 's/了$//' \
          -e 's/^ *//' -e 's/ *$//')"

  case "$LOOSE" in
    # 音量：带数字就是设值
    *音量*)
      V="$(printf '%s' "$LOOSE" | grep -oE '[0-9]+' | head -1)"
      if [ -n "$V" ]; then
        TARGET="volume"; ARGS=("$V"); DESC="音量调到 $V"
      fi
      ;;
    # ⚠⚠ 顺序是**语义要求**，不是风格问题：
#   「取消静音」「打开声音」都含「静音/声音」，若放在含这些词的规则**之后**，
#   会被先匹配到「静音 = 静音」→ 把「取消静音」变成「静音」，方向完全相反。
#   这类「否定式表达」必须排在肯定式之前，否则用户说取消、闪控给你静音。
    *取消静音*|*恢复声音*|*开声音*|*打开声音*|*声音开*|*解除静音*)
      TARGET="unmute"; DESC="取消静音"
      ;;
    # 静音/声音相关
    # ⚠ 关键词要覆盖「关掉声音/声音关了/别出声」这类**动词在前**的说法 ——
    #   用户不会说「静音」，会说「把声音关了」。只匹配「静音」两字等于没做兜底。
    *静音*|*关声音*|*关掉声音*|*声音关了*|*声音关*|*安静*|*别吵*|*别出声*|*不要吵*)
      TARGET="volume"; ARGS=("0"); DESC="静音"
      ;;
    # 相对调节：只说「大一点/小一点」没提音量，但**上下文就在音量面板里** ——
    #   用户在闪控面板前说这句话，意图必然是音量。这不是猜，是对话默认。
    *调大*|*调小*|*大一点*|*小一点*|*大点*|*小点*|*声音大*|*声音小*|*大声*|*小声*)
      DELTA=10
      case "$LOOSE" in
        *调小*|*小一点*|*小点*|*降低*|*低一点*|*小声*) DELTA=-10 ;;
      esac
      CUR="$("$DIR/macctl" volume 2>/dev/null | grep -oE '= [0-9]+' | grep -oE '[0-9]+' | head -1)"
      [ -z "$CUR" ] && CUR=50
      NV=$(( CUR + DELTA ))
      [ "$NV" -lt 0 ] && NV=0
      [ "$NV" -gt 100 ] && NV=100
      TARGET="volume"; ARGS=("$NV"); DESC="音量 $CUR → $NV"
      ;;
    # 截图（⚠ 「把两张截图拼起来」是工件任务，不是截屏；交给 miss/intake）
    *截图*|*截屏*|*截个图*|*截屏图*)
      case "$NORM" in
        把*|*拼*|*合并*|*标注*|*编辑*|*导出*|*整理*|*发给*|*两张*|*三张*|*图片*)
          : ;;
        *)
          TARGET="shot"; DESC="截图"
          ;;
      esac
      ;;
    # 录屏（放在截图之后：截图规则不含「录屏」，不冲突）
    *录屏*|*录个屏*|*录一下*|*屏幕录制*)
      TARGET="screen_rec.sh"; ARGS=(--toggle); DESC="录屏（再按一次停止）"
      ;;
    # 播放音乐：含「播放/放/听/来一首/来首」且不是「打开」
    *播放*|*来一首*|*来首*|*放一首*|*放首*|*听*)
      case "$LOOSE" in
        *打开*) : ;;   # 「打开酷狗音乐」不是播放意图，交给上面那层
        *)
          SONG="$LOOSE"
          # 逐个剥掉播放动词
          for KW in 播放 来一首 来首 放一首 放首 放 听 来; do
            SONG="${SONG#$KW}"; SONG="${SONG#$KW}"
          done
          SONG="$(printf '%s' "$SONG" | sed -e 's/^ *//' -e 's/ *$//' -e 's/^的//' -e 's/^歌//')"
          if [ -n "$SONG" ]; then
            TARGET="music_play.sh"; ARGS=(--song "$SONG"); DESC="播放 $SONG"
          fi
          ;;
      esac
      ;;
    # 微信：宽松版「给X发微信/告诉X/跟X说」
    *微信*|*消息*)
      case "$LOOSE" in
        *给*发*|*给*)
          TO="$(printf '%s' "$LOOSE" | sed -e 's/^给//' -e 's/发微信.*$//' -e 's/发消息.*$//' -e 's/发个微信.*$//' -e 's/发条微信.*$//' -e 's/微信.*$//')"
          TO="$(printf '%s' "$TO" | sed -e 's/^ *//' -e 's/ *$//')"
          MSG="$(printf '%s' "$LOOSE" | sed -e 's/^.*发[给]\\{0,1\\}微信:*//' -e 's/^.*发消息:*//' -e 's/^.*微信说:*//')"
          MSG="$(printf '%s' "$MSG" | sed -e 's/^ *//' -e 's/ *$//')"
          if [ -n "$MSG" ] && [ -n "$TO" ]; then
            TARGET="wechat_send.sh"; ARGS=(--to "$TO" --msg "$MSG"); DESC="给 $TO 发微信：$MSG"
          fi
          ;;
      esac
      ;;
    # 桌面概览
    *桌面*|*屏幕上*)
      TARGET="overview"; DESC="查看桌面"
      ;;
    # 「打开/启动/运行 + 某个东西」—— 口语层最重要的一条兜底。
    # ⚠ 用户说「帮我打开微信」「启动一下WPS」「运行计算器」，
    #   剥掉客套后是「打开微信」「启动一下WPS」，
    #   如果这里不放行就会掉到最底层的「诚实失败」，让用户白等一轮。
    #   放在 case 的**最后**：上面所有更具体的规则都已先行匹配过了。
    *打开*|*启动*|*运行*|*开一下*)
      APPISH="$(printf '%s' "$LOOSE" \
        | sed -e 's/^打开//' -e 's/^启动//' -e 's/^运行//' -e 's/^开一下//' \
              -e 's/^ *//' -e 's/ *$//' -e 's/一下$//' -e 's/吧$//' -e 's/了$//')"
      if [ -n "$APPISH" ]; then
        TARGET="app_open"; ARGS=(--name "$APPISH"); APP_NAME="$APPISH"; DESC="打开 $APPISH"
      fi
      ;;
  esac
  fi   # ← 复杂任务闸的 else 结束
fi

# ── 未命中 ───────────────────────────────────────────────────
# ⚠ 这是路由器的**核心诚实性**：认不出就说认不出，绝不猜。
if [ -z "$TARGET" ]; then
  audit "route" "route.sh" "$LEVEL_L0" "fail" "$ERR_ELEMENT_NOT_FOUND" "指令未命中路由表"
  INTAKE_TMP="$(mktemp "${TMPDIR:-/tmp}/route_intake.XXXXXX")"
  CHAIN="workbuddy"; HTARGET="WorkBuddy"; PROMPT="$INPUT"
  if python3 "$HOME/.tiangong/router/intake.py" --json "$INPUT" > "$INTAKE_TMP" 2>/dev/null; then
    CHAIN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("chain","") or "workbuddy")' "$INTAKE_TMP" 2>/dev/null || echo workbuddy)"
    HTARGET="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("handoff_target","") or "WorkBuddy")' "$INTAKE_TMP" 2>/dev/null || echo WorkBuddy)"
    PROMPT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("optimized_prompt","") or "")' "$INTAKE_TMP" 2>/dev/null || true)"
    [ -z "$PROMPT" ] && PROMPT="$INPUT"
  fi
  rm -f "$INTAKE_TMP"
  PROMPT_B64="$(printf '%s' "$PROMPT" | base64 | tr -d '\n')"
  emit 0 "route" "" 0 "未命中路由表: $INPUT" "$ERR_ELEMENT_NOT_FOUND" \
       "hint" "$(json_str '复杂任务先分流；链与优化提示词见 chain/prompt_b64')" \
       "chain" "$(json_str "$CHAIN")" \
       "handoff_target" "$(json_str "$HTARGET")" \
       "prompt_b64" "$(json_str "$PROMPT_B64")"
  echo ""
  echo "── 我没听懂这句话 ──"
  echo "「${INPUT}」"
  echo ""
  echo "能听懂的说法（route.sh --list 看完整列表）："
  echo "  给张三发微信:你好      播放周杰伦的青花瓷"
  echo "  打开报告.pdf打开抖音        截图"
  echo "  音量30静音"
  echo ""
  echo "复杂任务（比如写稿、排版、多步操作）请切WorkBuddy —— 那里有大脑。"
  exit 1
fi


# 判定一条命令是否**真的**成功：看退出码，再看输出里有没有 ok:false / ❌。
#
# ⚠⚠ 这里原来一律 `emit 1 ...`（ok=true），不管子命令死活。后果实测：
#   面板点「截图」显示「✅ 截图完成」，但文件根本没生成（截图需要屏幕录制授权，
#   macctl 失败返回非 0）—— 用户看到的是"成功"，实际什么都没发生。
#   这是最坏的一类 bug：界面撒谎，比直接报错更难查。
last_ok() {
  local rc="$1" out="$2"
  [ "$rc" -ne 0 ] && { echo 0; return; }
  case "$out" in
    *'"ok":false'*|*'❌'*) echo 0 ;;
    *) echo 1 ;;
  esac
}

# ── 执行 ─────────────────────────────────────────────────────
if [ "$DRY" = "1" ]; then
  emit 1 "route" "$TARGET" 0 "解析成功(dry-run): $DESC" "" \
       "dry_run" "true" "intent" "$(json_str "$DESC")"
  echo ""
  echo "── 解析结果（未执行）──"
  echo "动作: $DESC"
  echo "命令: $TARGET ${ARGS[*]}"
  exit 0
fi

audit "route" "route.sh" "$LEVEL_L0" "info" "route_match" "命中: $DESC"

# ── 群发闸（2026-10-23 用户定义）─────────────────────────────────
# 「群发 = 同时给多个收件人发同样的内容」，明确禁止；**单群（一个群聊）允许**。
# 判据：收件人位置出现并列结构（和/、/以及/跟/与）或广播词（所有人/全部/大家）。
case "$TARGET" in
  wechat_send.sh)
    TO_CHECK=""
    i=0
    while [ $i -lt ${#ARGS[@]} ]; do
      if [ "${ARGS[$i]}" = "--to" ]; then TO_CHECK="${ARGS[$((i+1))]}"; break; fi
      i=$((i+1))
    done
    if printf '%s' "$TO_CHECK" | /usr/bin/grep -qE "(和|、|以及|跟|与).+"; then
      emit 0 "route" "wechat_send.sh" 0 "这是群发（同时发给多个收件人）——你说过不行。要发的话请一条一条来。" "BROADCAST_BLOCKED"
      echo ""
      echo "── 群发已拦下 ──"
      echo "收件人里出现了多个名字：$TO_CHECK"
      echo "逐条发：给<第一个人>发微信:<内容>  /  再发第二个人"
      exit 1
    fi
    if printf '%s' "$TO_CHECK" | /usr/bin/grep -qE "所有人|全部|大家|全体|群里所有"; then
      emit 0 "route" "wechat_send.sh" 0 "广播式发送（所有人/全部/大家）—— 不行。" "BROADCAST_BLOCKED"
      exit 1
    fi
    ;;
esac

# ── 发送前回读（不拦路，只让人看清「发给谁、说了什么」）───────────────
# 用户定稿：回读是必须的，但**不能变成二次询问**。
case "$TARGET" in
  wechat_send.sh)
    # ⚠⚠ 回读必须走 **stderr**：stdout 的第一行是机器解析的 JSON 契约。
    #   之前这两行 echo 打在 stdout，把 JSON 挤到第二行 → 面板按首行判定，
    #   看不到 AMBIGUOUS/ok 字段，于是把"多候选选择"误判成"没听懂"转交出去
    #   （2026-10-23 自己踩的坑：给人看的内容和给机器读的内容必须分通道）。
    echo "→ 收件人：$(printf '%s ' "${ARGS[@]}" | /usr/bin/sed -n 's/.*--to \([^ ]*\) --msg \(.*\)/\1/ p')" >&2
    echo "→ 内容：$(printf '%s ' "${ARGS[@]}" | /usr/bin/sed -n 's/.*--msg //p')" >&2
    ;;
esac

# ── 不再有拦截式二次确认（2026-10-23 用户定稿）──────────────────────────
# 用户原话：「只要用户在指令里要求发送或表示允许发送，即可发送；不得二次询问
# —— 二次询问用户，用户会觉得麻烦，低效、不自动化。」
# 所以这里**不再拦路**，改成「回读后直接执行」：把收件人和内容原样回读一遍，
# 让人看得见发了什么给谁，但不要求他再点一次确认。
# ⚠ 仍保留 --dry：想看而不发的人可以用它。
NEED_CONFIRM=0

# 真的执行
#
# ⚠⚠⚠ **本段的第一铁律：stdout 首行必须恒为 JSON**（D-024）
#
#   面板的 summarize() 只解析 stdout **首行**的 JSON 来决定显示什么。
#   原来这些分支直接把 macctl 的人类可读文本原样扔出去：
#     shot     → "已保存 /Users/.../截图-xxx.png (2880x1800)"
#     volume   → "系统音量 -> 30  (静音=false)"
#     doctor   → "=== 闪控环境体检 ==="
#     overview → "=== 桌面概览：47 个有效窗口 ==="
#   首行不是 JSON → 面板走不到任何解析分支 → 落到最后的兜底 →
#   用户看到「无法识别 / 报错」，**哪怕事情已经做成了**。
#   这是「执行了但说失败」的第二个来源（第一个是 app_open 的 0 字节）。
#
#   做法统一为三步：**跑命令拿输出 → emit 一行 JSON → 再回显原文给人看**。
#   JSON 在前、人话在后，机器读第一行，人读剩下的。
case "$TARGET" in
  doctor)
    OUT="$(m doctor 2>&1)"
    RC=$?
    emit "$(last_ok "$RC" "$OUT")" "route" "doctor" 0 "环境体检完成" "" \
         "intent" "$(json_str "环境体检完成")" \
         "output" "$(json_str "$OUT")"
    printf '%s\n' "$OUT"
    ;;
  readscreen)
    # 读屏：OCR 整屏，去掉坐标/置信度噪音，压成一行给面板显示
    # 只读**前台窗口**：整屏 OCR 会把桌面/别的窗口都读进来，噪音大十倍。
    FB="$(m state 2>/dev/null | /usr/bin/sed -n 's/.*bundle=\([^ ]*\).*/\1/p' | head -1)"
    # ⚠ 只读「该读的那一块」：屏幕上如果**有对话框/提示框**，用户想知道的
    #   99% 是那上面的字；整窗 OCR 会把背景内容混进来，读屏就失去意义。
    #   判据：面积不到最大窗口 45% 的，视为弹层，优先读它。
    PICK=""
    if [ -n "$FB" ]; then
      PICK="$(m windows --app "$FB" 2>/dev/null | /usr/bin/python3 -c "
import sys, re
ws = []
for line in sys.stdin:
    m = re.search(r'@\((\d+),(\d+)\) (\d+)x(\d+)', line)
    if m:
        x, y, w, h = map(int, m.groups())
        ws.append((x, y, w, h))
if not ws: sys.exit()
mx = max(w * h for _, _, w, h in ws)
small = [t for t in ws if t[2] * t[3] < mx * 0.45]
p = small[0] if small else ws[0]
print('%d,%d,%d,%d' % p)
")"
    fi
    if [ -n "$PICK" ]; then OUT="$(m ocr --rect "$PICK" 2>&1)"; else OUT=""; fi
    # 小窗可能是"迷你播放器"这类没有字的窗口 —— 读空了就退回整窗读，
    # 否则用户会得到"OCR 无结果"这种看起来像坏了的结果（实测踩到）。
    if ! printf '%s' "$OUT" | grep -q "@("; then
      if [ -n "$FB" ]; then OUT="$(m ocr --app "$FB" 2>&1)"; else OUT="$(m ocr 2>&1)"; fi
    fi
    RC=$?
    # 读不到字时别报"OCR 无结果"（听起来像坏了）—— 说清楚是哪一种情况
    if ! printf '%s' "$OUT" | grep -q "@("; then
      OUT="当前窗口没有可读文字（可能是不含文本的窗口，或内容全是图片）"
      RC=0
    fi
    SNIP="$(printf '%s' "$OUT" | head -60 \
      | /usr/bin/sed -E "s/ @\([0-9,]+\) conf=[0-9.]+//" \
      | /usr/bin/tr "\n" " " | /usr/bin/cut -c1-72)"
    emit "$(last_ok "$RC" "$OUT")" "route" "readscreen" 0 "屏幕上：$SNIP" "" \
         "intent" "$(json_str "屏幕上：$SNIP")" \
         "output" "$(json_str "$OUT")"
    printf '%s\n' "$OUT"
    ;;

  shot)
    OUT="$(m shot 2>&1)"
    RC=$?
    emit "$(last_ok "$RC" "$OUT")" "route" "shot" 0 "截图完成" "" \
         "intent" "$(json_str "截图完成")" \
         "output" "$(json_str "$OUT")"
    printf '%s\n' "$OUT"
    ;;
  overview)
    OUT="$(m overview 2>&1)"
    RC=$?
    emit "$(last_ok "$RC" "$OUT")" "route" "overview" 0 "桌面概览" "" \
         "intent" "$(json_str "桌面概览")" \
         "output" "$(json_str "$OUT")"
    printf '%s\n' "$OUT"
    ;;
  volume)
    OUT="$(m volume --set "${ARGS[0]}" 2>&1)"
    RC=$?
    emit "$(last_ok "$RC" "$OUT")" "route" "volume" 0 "$DESC" "" \
         "intent" "$(json_str "$DESC")" \
         "output" "$(json_str "$OUT")"
    printf '%s\n' "$OUT"
    ;;
  unmute)
    OUT="$(m volume --mute off 2>&1)"
    RC=$?
    emit "$(last_ok "$RC" "$OUT")" "route" "unmute" 0 "取消静音" "" \
         "intent" "$(json_str "取消静音")" \
         "output" "$(json_str "$OUT")"
    printf '%s\n' "$OUT"
    ;;
  quick_open)
    OUT="$(open -a "$DESC" 2>&1)"
    RC=$?
    emit "$(last_ok "$RC" "$OUT")" "route" "quick_open" 0 "$DESC" "" \
         "intent" "$(json_str "$DESC")"
    printf '%s\n' "$OUT"
    ;;
  app_open)
    # ── 通用应用启动（2026-10-25 改）──────────────────────────────────
    #   WorkBuddy 原来走专用分支：没在运行就先播开场动画再拉起。
    #   用户 2026-10-25 拍板：**开场动画只在开机播一次**，面板/路由点一下
    #   WorkBuddy 不该整屏播动画。所以专用分支已废，统一走下面的 launch。
    #   开机那一次由 bootanim/run-at-login.sh 负责（先动画、后其他自启）。
    APP_NAME="${APP_NAME:-$NAME}"
    case "$APP_NAME" in
      WorkBuddy|workBuddy|WORKBUDDY|闪控工作台|工作台)
        # 2026-10-25 用户拍板：开场动画只在**开机**播一次。
        #   面板/路由启动 WorkBuddy 不再播动画 —— 落到下面的通用启动路径。
        #   原实现是没在运行就后台起 wblaunch（先播动画再拉起），
        #   现在起 wblaunch 反而会让"随手点一下就整屏动画"，明确不要。
        ;;
    esac

    # 「打开X」：X 先当应用，找不到再当文件。
    # ⚠ 降级不是妥协，是必要的：用户说「打开报表.xlsx」是真要开文件，
    #   说「打开微信」是要开应用。应用优先 + 文件兜底 两者都不误伤。
    #
    # ⚠⚠ 这里曾经是「静默失败」的根源（D-024）：
    #   原来写成 `if m launch --name "$APP_NAME" --json 2>/dev/null | grep -q '"ok":true'; then exit 0; fi`
    #   —— macctl 的 JSON 被丢进 grep 只做判断，**判断完就 exit 0**，
    #   结果 route.sh 的 stdout 是 **0 字节**。
    #   后果链条：面板 runScript 判定 NO_OUTPUT → 报「脚本无输出」；
    #   用户看到「无法识别/报错」，而实际上应用早就打开了。
    #   ——「应用确实被打开了，但界面说失败」是最难查的一类矛盾。
    #
    # 修法两条铁律：
    #   ① 判断与回显**分离**：判断用的输出存到变量，不直接丢进管道；
    #   ② **任何分支都必须 emit** —— stdout 首行恒为 JSON 是本脚本的对外契约，
    #      破坏它就等于让所有调用方（面板/WorkBuddy/自检）瞎掉。
    #
    # （APP_NAME 已在上面的 WorkBuddy 专用分支里赋值过。）
    LAUNCH_OUT="$(m launch --name "$APP_NAME" --json 2>/dev/null)"
    if printf '%s' "$LAUNCH_OUT" | grep -q '"ok":true'; then
      # 应用已启动：回显 intent，面板据此显示「✅ 已打开 XX」
      emit 1 "route" "app_open" 0 "已打开 $APP_NAME" "" \
           "intent" "$(json_str "已打开 $APP_NAME")" \
           "app" "$(json_str "$APP_NAME")" \
           "detail" "$(json_str "$LAUNCH_OUT")"
      exit 0
    fi
    # 不是已安装的应用 → 改按文件名查找（open_file.sh 自己会回显结果）
    echo "「${APP_NAME}」不是已安装的应用，改按文件名查找…"
    echo ""
    "$DIR/open_file.sh" --name "$APP_NAME"
    RC=$?
    # ⚠ open_file.sh 若自己没 emit，这里补一行兜底 JSON，
    #   保证「stdout 首行恒为 JSON」这条契约在任何路径都不破。
    #   （open_file.sh 成功时首行已是 JSON，head -1 取到的就是它，不会重复。）
    HEAD="$(m launch --name "$APP_NAME" --json 2>/dev/null | head -1)"
    case "$HEAD" in
      \{*) : ;;
      *) emit 0 "route" "app_open" 0 "未能打开 $APP_NAME" "$ERR_ELEMENT_NOT_FOUND" \
              "intent" "$(json_str "未能打开 $APP_NAME")" ;;
    esac
    exit $RC
    ;;
  *)        "$DIR/$TARGET" "${ARGS[@]}" ;;
esac

exit 0