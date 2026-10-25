#!/bin/bash
# 闪控 · flashctl.sh — 热键入口与开机自启的管理脚本
#
# 为什么需要这个：flash 是个常驻进程（要一直监听全局热键）。
# macOS 上让程序开机自动跑的标准方式是 LaunchAgent，
# 而 launchctl 在某些受限环境（沙箱/SSH）里会报 "I/O error"，
# 所以做成一个脚本，让用户在**正常终端**里一条命令搞定。
#
# 用法：
#   flashctl.sh install    注册开机自启（同时立刻启动）
#   flashctl.sh install-boot  注册开机开场动画自启（wblaunch，独立装）
#   flashctl.sh uninstall  取消开机自启并停止
#   flashctl.sh uninstall-boot  取消开机开场动画自启
#   flashctl.sh start      立刻启动（不注册自启）
#   flashctl.sh stop       停止
#   flashctl.sh status     看状态
#   flashctl.sh key f5 "ctrl+alt"  改热键并重装自启（默认 ⌃⌥S）

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.lingtai.apex"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
FLASH="$DIR/flash"
# ⚠ 装了登录项以后，真正在跑的是 /Applications/灵台智枢.app（SMAppService 只认这里）。
#   flashctl 的所有启动/重启都要跟着走，否则会拉起旧 bundle 造成两份实例。
if [ -d "/Applications/灵台智枢.app" ]; then
  APP_BUNDLE="/Applications/灵台智枢.app"
else
  APP_BUNDLE="$DIR/灵台智枢.app"
fi
LOG="/tmp/flash.log"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
}

# ⚠ 判「在不在跑」不能只靠 pgrep：沙箱里 `pgrep` 可能被拦（operation not
#   permitted），于是进程明明活着，status 却报「未运行」—— 用户会以为闪控没起。
#   第二判据是常驻进程自己写的 /tmp/flash.hotkey 里的 pid，用 kill -0 试探。
flash_pid() {
  local p
  p="$(pgrep -x flash 2>/dev/null | head -1)"
  [ -n "$p" ] && { echo "$p"; return 0; }
  p="$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' /tmp/flash.hotkey 2>/dev/null | head -1)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { echo "$p"; return 0; }
  return 1
}
is_running() { flash_pid > /dev/null 2>&1; }

write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents"
  # ⚠ 为什么用 `open -g -a 灵台智枢.app` 而不是直接跑二进制：
  #   裸二进制由 shell 拉起时，**进程会跟着父 shell 一起被回收**（实测：
  #   调用一结束进程就没了，用户按热键当然没反应）；经 LaunchServices 启动的
  #   进程由 launchd 托管，能一直活着，而且带 app 身份（可双击、可进登录项）。
  #   `-g` = 不抢焦点，开机时不能把用户正在用的窗口挤掉。
  make_app >/dev/null
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/灵台智枢.app/Contents/MacOS/flash</string>
$EXTRA_ARGS    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- KeepAlive：进程一退出 launchd 立刻拉起。
         这正是「热键时好时坏」的第二大来源 —— 老配置 KeepAlive=false，
         闪控一旦被谁杀掉（改代码重编、系统清理、崩溃），就再也没人把它叫回来，
         用户下次按热键当然是死的。 -->
    <!-- KeepAlive 用 SuccessfulExit=false：只在**异常退出**时拉起。
         登录项（SMAppService）也会在登录时启动一份；如果这里写 true，
         被单实例锁挡掉的那份 clean exit 会让 launchd 反复重启 → 死循环。 -->
    <key>KeepAlive</key>
    <dict>
      <key>SuccessfulExit</key>
      <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>3</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>/tmp/flash.err.log</string>
</dict>
</plist>
PLISTEOF
  plutil -lint "$PLIST" > /dev/null 2>&1 || { echo "❌ plist 语法错误"; exit 1; }
}

# ── 灵台智枢.app：可双击、可放进登录项的外壳 ──────────────────────────
# ⚠ 为什么需要：裸 Mach-O 二进制没有 bundle，用户没法「双击启动」，
#   也没法在「登录项」里选它（登录项只收 .app）。而 launchd 的
#   bootstrap 在某些环境会被拦（本机实测 I/O error），所以要有一条
#   「不依赖 launchd / 不依赖终端」的启动路径。
# ⚠ 为什么壳里是 exec 原二进制，而不是复制一份：复制会换掉路径，
#   辅助功能授权（TCC）按路径+签名认人，复制等于要用户重新授权一次。
make_app() {
  local APP="$DIR/灵台智枢.app"
  mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>灵台智枢</string>
  <key>CFBundleDisplayName</key><string>灵台智枢</string>
  <key>CFBundleIdentifier</key><string>com.lingtai.apex</string>
  <key>CFBundleExecutable</key><string>flash</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.9.1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLISTEOF
  # ⚠ 这里**必须复制二进制**，不能再用 shell 壳 exec 外部文件：
  #   ① 登录项 / 自启要求是个正经 app bundle；
  #   ② 更重要的是签名：TCC 的辅助功能授权绑在**代码签名**上，而 app 的
  #      主可执行必须是 Mach-O 才签得上。以前用 shell 壳 → bundle 签不了 →
  #      授权永远绑在 ad-hoc 的 cdhash 上 → 每次重编译就作废 → 用户天天被
  #      「flash 想使用辅助功能」弹窗骚扰（2026-10-23 用户投诉）。
  # ⚠⚠ 必须删掉旧版的 shell 壳 run：老 bundle 里留着它时，LaunchServices 会
  #   继续执行 run → run 再 exec 成外部裸二进制 → 进程的 Bundle.main 变成 nil，
  #   于是 TCC 看到的是"裸二进制"而不是"灵台智枢.app"，用户把 app 拖进辅助功能也
  #   不生效（实测 ax 一直是 0，state 里 bid=nil(bare)）。
  rm -f "$APP/Contents/MacOS/run"
  cp -f "$DIR/flash" "$APP/Contents/MacOS/flash"
  chmod +x "$APP/Contents/MacOS/flash"
  # 字体随包走：scripts/Resources/Fonts → Contents/Resources/Fonts。
  # ⚠ 只把文件塞进 bundle 是不够的 —— AppKit 不会自动登记，必须由 flash 启动时
  #   用 CTFontManagerRegisterFontsForURL 注册（见 flash.swift 的 BundledFonts）。
  #   这里漏拷的直接后果是「字体没生效」，而面板会静默回退到系统字体：
  #   看起来只是"没那么好看"，不会报错，所以拷贝放在 cp 旁边的同一段里。
  if [ -d "$DIR/Resources/Fonts" ]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp -f "$DIR/Resources/Fonts/"*.ttf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
    cp -f "$DIR/Resources/Fonts/"LICENSE-*.txt "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
  else
    echo "   ⚠️ 没找到 $DIR/Resources/Fonts —— 本次 bundle 不含字体，将回退系统字体"
  fi
  # 让 LaunchServices 重新读一遍 Info.plist（否则它可能还按旧的可执行名启动）
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
  echo "✅ 已生成 $APP"
}

cmd="${1:-status}"
EXTRA_ARGS=""

case "$cmd" in
  install|start)
    [ -x "$FLASH" ] || { echo "❌ flash 未编译：cd $DIR && swiftc -O -o flash flash.swift"; exit 1; }
    # 用户可能在 install 时顺带改热键：install f5 ctrl+alt
    if [ $# -ge 3 ] && [ $# -eq 3 ]; then
      EXTRA_ARGS="        <string>--keyname</string>
        <string>$2</string>
        <string>--mods</string>
        <string>$3</string>"
    fi
    write_plist

    # 先停掉旧的再装新的，否则会同时有两个 flash 抢热键
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    launchctl unload "$PLIST" 2>/dev/null
    is_running && kill "$(flash_pid)" 2>/dev/null && sleep 1

    #⚠ 关键：**不要信launchctl 的返回值**，只信「进程是否真的活着」。
    #   实测在沙箱/受限环境里，`launchctl load` 会返回 0（看起来成功）
    #   但实际什么也没注册 —— 只看返回值会误报成功，然后进程根本没起来。
    #   （2026-10-21 实测踩到。）
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null
    launchctl load "$PLIST" 2>/dev/null
    sleep 2

    if ! is_running; then
      # ⚠ 兜底必须走 open（LaunchServices）：nohup 起的进程会随父 shell 被回收
      /usr/bin/open -g -a "$APP_BUNDLE" 2>/dev/null
      sleep 2
    fi

    if is_running; then
      # 现在能跑：再确认自启是否真的注册上了（决定重启后还在不在）
      if launchctl list 2>/dev/null | grep -q "$LABEL"; then
        echo "✅ 已注册开机自启（${LABEL}），重启后自动运行"
      else
        echo "⚠️  已启动，但开机自启**未生效**（常见于沙箱/SSH 会话）"
        echo "   本次会话可用。想开机自启，请在图形界面的终端里执行："
        echo "     launchctl bootstrap gui/\$(id -u) $PLIST"
      fi
      echo "✅ flash 运行中（pid $(pgrep -x flash)），按 ⌃⌥⌘ 同按唤起"
    else
      echo "❌ 启动失败，日志："
      tail -5 "$LOG" 2>/dev/null
      tail -5 /tmp/flash.err.log 2>/dev/null
      exit 1
    fi
    ;;

  uninstall|stop)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    launchctl unload "$PLIST" 2>/dev/null
    if is_running; then kill "$(flash_pid)" 2>/dev/null; echo "✅ 已停止"; else echo "（本来就未运行）"; fi
    [ "$cmd" = "uninstall" ] && rm -f "$PLIST" && echo "✅ 已删除 plist，不再开机自启"
    ;;

  status)
    echo "灵台智枢 · 状态"
    echo "  二进制:   $FLASH$([ -x "$FLASH" ] && echo ' ✅' || echo ' ❌ 未编译')"
    echo "  plist:    $PLIST$([ -f "$PLIST" ] && echo ' ✅' || echo ' ❌ 未注册')"
    if is_running; then echo "  进程:     ✅ 运行中 (pid $(flash_pid))"; else echo "  进程:     ❌ 未运行"; fi
    echo "  热键:"
    "$FLASH" --status 2>&1 | grep -E "目标热键|Carbon 注册|事件监听|运行中实例" | sed 's/^/    /'
    echo ""
    echo "  开场动画: $([ -x "$DIR/bootanim/tools/wblaunch" ] && echo 'wblaunch ✅' || echo 'wblaunch ❌ 未编译')"
    if launchctl list 2>/dev/null | grep -q "com.lingtai.bootanim"; then
      echo "  开机动画自启: ✅ 已注册（重启后先播动画再弹 WorkBuddy）"
    else
      echo "  开机动画自启: ❌ 未注册（重启不播动画）→ flashctl.sh install-boot"
    fi
    echo ""
    echo "  快捷操作: flashctl.sh install | install-boot | uninstall | restart | logs"
    ;;

  restart)
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || {
      is_running && kill "$(pgrep -x flash)" 2>/dev/null; sleep 1
      /usr/bin/open -g -a "$APP_BUNDLE" 2>/dev/null   # 同 install：必须经 LaunchServices
    }
    sleep 2; is_running && echo "✅ 已重启" || echo "❌ 重启失败"
    ;;

  # ── 装到 /Applications 并注册成登录项（用户不用手动启动）────────────
  # SMAppService 只对 /Applications 下的 app 生效，所以必须复制过去。
  # 复制后签名与 TCC 要求不变（identifier + 证书根），授权继续有效。
  install-app)
    make_app
    /usr/bin/ditto "$DIR/灵台智枢.app" "/Applications/灵台智枢.app" || { echo "❌ 复制失败"; exit 1; }
    echo "✅ 已安装到 /Applications/灵台智枢.app"
    APP_BUNDLE="/Applications/灵台智枢.app"
    is_running && { kill "$(flash_pid)" 2>/dev/null; sleep 1; }
    /usr/bin/open -g -a "$APP_BUNDLE"
    sleep 3
    echo "—— 登录项 ——"
    echo "   已安装：/Applications/灵台智枢.app（app 启动时通过 SMAppService 自我注册为登录项）"
    echo "   验证：./flashctl.sh diagnose 看 ③，应显示「已注册为登录项」"
    ;;

  app)
    make_app ;;
  # ── 用自签证书签名：让 TCC 授权跨重编译存活 ────────────────────────
  # 背景：ad-hoc 签名的「指定要求」是 cdhash，重编译一次就变，辅助功能授权
  # 随之作废 → 用户每次更新都要重新授权，且中间一直被系统弹窗骚扰。
  # 用一张固定的自签证书签名后，授权绑在「identifier + 证书」上，重编译不再影响。
  sign)
    ID="Shankong Local Signer"
    # ⚠ 自签证书是"未受信任"的，`find-identity -v -p codesigning` 会把它过滤掉；
    #   但 codesign 仍然能用它签（TCC 认的是指定要求，不是信任链）。
    #   所以这里用不带 -p 的查询，只确认identity存在。
    if ! security find-identity 2>/dev/null | grep -q "$ID"; then
      echo "⚠️  没找到自签证书「${ID}」。先导入（一次性）："
      echo "   见 references/permissions.md 的「固化辅助功能授权」一节"
      echo "   现在退化为 ad-hoc 签名（重编译后需要重新授权）"
      ID="-"
    fi
    make_app
    # --identifier 固定成 com.lingtai.apex：ad-hoc 时它会被写成 flash-<uuid>，
    # 那样 TCC 的指定要求每次都变，白签。固定 identifier + 固定证书 = 稳定身份。
    codesign --force --identifier com.lingtai.apex --sign "$ID" "$DIR/flash" 2>&1 | tail -2
    codesign --force --deep --sign "$ID" "$DIR/灵台智枢.app" 2>&1 | tail -2
    echo "—— 签名结果 ——"
    codesign -dv "$DIR/flash" 2>&1 | grep -E "Identifier|Authority|Signature"
    codesign -dv "$DIR/灵台智枢.app" 2>&1 | grep -E "Identifier|Authority|Signature"
    echo "✅ 已签名。到「系统设置 > 隐私与安全性 > 辅助功能」里勾一次「闪控」，之后重编译不必再勾。"
    ;;

  # ── 显式申请辅助功能授权（只在这里才弹系统框，平时绝不打扰）──────
  #
  # ⚠⚠ 这一支曾经写的是 `SHANKONG_AX_PROMPT=1 "$DIR/flash" --status`，
  #   **从来就没有生效过**（两个独立的死因叠在一起）：
  #     1. flash.swift 的 --status 段打完状态就 `exit(0)`（约 3447 行），
  #        根本走不到 3519 行那段「按 SHANKONG_AX_PROMPT 弹授权框」的代码；
  #     2. 就算走到了也不会弹 —— 从终端直接跑会继承**终端自己**的 TCC 授权身份，
  #        系统认为要申请授权的是「终端」，灵台智枢仍然没有被登记。
  #   唯一有效的做法（桌面「修复辅助功能授权.command」实测）：
  #     · 先用 tccutil 清掉旧的僵尸记录（改 bundle id / 重签后会残留一条
  #       「显示已勾选、实际绑旧哈希」的死条目，手动勾多少遍都没用）；
  #     · 用 PlistBuddy 给 LaunchAgent **临时**注入 SHANKONG_AX_PROMPT=1，
  #       再 bootout/bootstrap/kickstart —— **必须由 launchd 拉起**，
  #       进程才会以灵台智枢自己的身份去申请；
  #     · 用户勾完回车后撤掉变量、重启面板、回读 ax= 值验证。
  #   全程只弹这一次；弹窗代码默认静默（见 ERR-0023）。
  ax)
    UID_N="$(id -u)"
    # ⚠⚠ 守卫：已经授权就**什么都别做**。
    #   本分支第一步是 `tccutil reset`，那会**主动清掉**现有授权。
    #   用户手一抖跑一次，刚拿到的好授权就没了 —— 必须先判断。
    if tr ' ' '\n' < /tmp/flash.hotkey 2>/dev/null | grep -q '^ax=1$'; then
      echo "✅ 辅助功能已经是好的（ax=1），不需要修。"
      echo "   本命令会先 tccutil reset 清授权，所以**不做任何操作**。"
      echo "   真怀疑它坏了，先跑：$0 diagnose"
      exit 0
    fi
    if [ ! -f "$PLIST" ]; then
      echo "❌ 还没注册开机自启（缺 ${PLIST}）"
      echo "   先跑：$0 install   然后再跑 $0 ax"
      exit 1
    fi

    echo "═══ 灵台智枢 · 辅助功能授权 ═══"
    echo "  只会弹这一次授权框，之后不再弹。"
    echo ""

    # ① 清掉旧记录（僵尸条目）
    echo "① 清理旧的授权记录"
    tccutil reset "Accessibility" "$LABEL" 2>&1 | head -1
    echo "   ✅ 已清空（系统设置里那条「灵台智枢」会消失，这是正常的）"
    echo ""

    # ② 临时注入环境变量，让 **launchd 拉起的** 面板主动申请一次
    echo "② 让 launchd 拉起的面板申请授权"
    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:SHANKONG_AX_PROMPT" "$PLIST" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$PLIST" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:SHANKONG_AX_PROMPT string 1" "$PLIST" 2>/dev/null
    if ! /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:SHANKONG_AX_PROMPT" "$PLIST" 2>/dev/null | grep -q 1; then
      echo "   ❌ 写 plist 失败（$PLIST 不可写？）"
      exit 1
    fi
    # ⚠ 顺序不能换：先 bootout 再 pkill，否则 KeepAlive 会在杀掉后立刻拉起一份
    #   没带环境变量的旧实例，把申请时机吃掉。
    launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null
    pkill -f "MacOS/flash" 2>/dev/null
    sleep 1
    launchctl bootstrap "gui/$UID_N" "$PLIST" 2>/dev/null
    launchctl kickstart -k "gui/$UID_N/$LABEL" 2>/dev/null
    sleep 4
    echo "   ✅ 面板已由 launchd 重启，授权框应该已经弹出来了"
    echo ""

    # ③ 让用户去勾（这一次）
    echo "③ 请你操作（就这一次）"
    echo "   屏幕上的框：「灵台智枢」想使用辅助功能来控制这台电脑"
    echo "     → 点「打开系统设置」"
    echo "     → 在「辅助功能」列表里找到「灵台智枢」，把开关打开"
    echo "     → 列表里没有就点左下角 + 号，选 $APP_BUNDLE"
    printf '\n   勾好了就按回车，我来收尾：'
    read -r _ </dev/tty 2>/dev/null || { echo ""; echo "   （没有交互终端，3 秒后自动继续）"; sleep 3; }
    echo ""

    # ④ 撤掉临时变量并重启面板
    echo "④ 撤掉临时变量并重启面板"
    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:SHANKONG_AX_PROMPT" "$PLIST" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables" "$PLIST" 2>/dev/null
    launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null
    pkill -f "MacOS/flash" 2>/dev/null
    sleep 1
    launchctl bootstrap "gui/$UID_N" "$PLIST" 2>/dev/null
    launchctl kickstart -k "gui/$UID_N/$LABEL" 2>/dev/null
    sleep 4
    echo "   ✅ 面板已重启"
    echo ""

    # ⑤ 验证：回读运行实例自己写的 /tmp/flash.hotkey 里的 ax=
    echo "⑤ 验证"
    ax_val="$(tr ' ' '\n' < /tmp/flash.hotkey 2>/dev/null | grep '^ax=' | head -1)"
    if [ "$ax_val" = "ax=1" ]; then
      echo "   ✅ 辅助功能已生效（${ax_val}）—— 面板现在可以控制其它 App 了"
    else
      echo "   ❌ 仍是 ${ax_val:-（读不到 /tmp/flash.hotkey）}"
      echo "      可能原因：勾的是旧条目 / 勾完没让面板重启 / 勾的时候面板没退出"
      echo "      再跑一次 $0 ax 即可（可重复执行，安全）。"
    fi
    echo "   热键状态：$(tr ' ' '\n' < /tmp/flash.hotkey 2>/dev/null | grep -E '^(carbon|tap|ax)=' | tr '\n' ' ')"
    ;;

  open)
    make_app
    /usr/bin/open -g -a "$APP_BUNDLE" 2>/dev/null && echo "✅ 已启动（${APP_BUNDLE}）" || echo "❌ 启动失败"
    ;;
  # ── 一条命令回答「它现在到底哪儿坏了」 ────────────────────────────
  # 用户报「用不了」时，问题可能在任何一层：没在跑 / 没自启 / 没授权 /
  # 热键被占 / 面板拿到了键盘但 App 没激活 / 路由不认这句话。
  # 每一层都给「现象 + 判定 + 下一步」，不让人猜。
  diagnose)
    echo "═══ 闪控自检报告 $(date '+%H:%M:%S') ═══"
    bad=0
    # 1 二进制
    if [ -x "$FLASH" ]; then
      echo "① 程序        ✅ $(stat -f '%Sm' -t '%m-%d %H:%M' "$FLASH") 编译"
    else
      echo "① 程序        ❌ 没编译 → ./build_flash.sh"; bad=1
    fi
    # 2 .app 外壳
    if [ -d "$DIR/灵台智枢.app" ]; then
      echo "② 应用外壳    ✅ 灵台智枢.app（可双击启动）"
    else
      echo "② 应用外壳    ⚠️  缺 → ./flashctl.sh app（不影响热键）"
    fi
    # 3 自启（BTM 才是「重启会不会自启」的真相，不是 launchctl list）
    # ⚠ Disposition（enabled/allowed）在 Identifier 的**上面**几行，
    #   所以要用 -B6 往回看，而不是 -A6 往后看（踩过：永远判成"未登记"）
    # ⚠⚠ 绝对不要在这里调 `sfltool dumpbtm`：它需要管理员授权，
    #   每跑一次诊断就弹一次「"sfltool" 想要进行更改 / 输入密码」
    #   —— 用户 2026-10-23 投诉的"这个窗口老是弹"就是它。
    #   改用**无权限**的两条判断：
    #     · launchd 有没有加载（launchctl print，不需要密码）
    #     · 登录项：app 在 /Applications 里且当前实例就是从那里起的（bp=）
    loaded="$(launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo 1 || echo 0)"
    if is_running && printf '%s' "$(cat /tmp/flash.hotkey 2>/dev/null)" | /usr/bin/grep -q "bp=/Applications/灵台智枢.app"; then
      echo "③ 开机自启    ✅ 已注册为登录项（/Applications/灵台智枢.app，登录时自动运行）"
    elif [ "$loaded" = "1" ]; then
      echo "③ 开机自启    ✅ LaunchAgent 已加载"
    elif [ -d "/Applications/灵台智枢.app" ]; then
      echo "③ 开机自启    ⚠️  app 已装但当前实例不是从 /Applications 起的 → ./flashctl.sh open"; bad=1
    else
      echo "③ 开机自启    ❌ 未安装 → ./flashctl.sh install-app"; bad=1
    fi
    # 4 常驻进程 + 热键 + 上一次面板焦点
    if is_running; then
      echo "④ 常驻进程    ✅ pid $(flash_pid)"
      st="$(cat /tmp/flash.hotkey 2>/dev/null)"
      local_mode="$(printf '%s' "$st" | grep -o 'key=0')"
      if [ -n "$local_mode" ]; then
        # 纯修饰键模式（⌃⌥⌘ 三键同按）：Carbon 注册不了这种组合，只能靠事件监听
        case "$st" in
          *"tap=1"*) echo "   热键通道    ✅ 纯修饰键 ⌃⌥⌘（事件监听在线）；已触发 $(printf '%s' "$st" | sed -n 's/.*fires=\([0-9]*\).*/\1/p') 次" ;;
          *) echo "   热键通道    ❌ 事件监听没装上 —— 纯修饰键模式将**完全没有热键**"; bad=1 ;;
        esac
      else
        case "$st" in
          *"carbon=1"*"tap=1"*) echo "   热键通道    ✅ Carbon + 事件监听双通道；已触发 $(printf '%s' "$st" | sed -n 's/.*fires=\([0-9]*\).*/\1/p') 次" ;;
          *"tap=1"*) echo "   热键通道    ⚠️  只有事件监听（合成按键也认）" ;;
          *"carbon=1"*) echo "   热键通道    ⚠️  只有 Carbon（合成按键测不了，物理按键仍可用）" ;;
          *) echo "   热键通道    ❌ 两条通道都没注册上（大概率被别的 App 占用）"; bad=1 ;;
        esac
      fi
      case "$st" in
        *"ax=1"*) echo "   辅助功能    ✅ 运行实例已授权（事件监听通道可用，合成按键也能测）" ;;
        *) if printf '%s' "$st" | grep -q "key=0"; then
             echo "   辅助功能    ❌ 纯修饰键模式必须要有——没有它事件监听装不上，热键＝完全没有"; bad=1
           else
             echo "   辅助功能    ⚠️  运行实例没有辅助功能授权（面板的 AX 动作会退化）"
           fi
           echo "               ★ 一次性做法：把下面这个 app 拖进「辅助功能」列表并打开开关"
           echo "                 $DIR/灵台智枢.app"
           echo "                 （已经勾了「flash」也可能无效：旧条目绑的是老签名，"
           echo "                   拖 app 进去才会按当前证书登记）"
           echo "                 打开面板：open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
           echo "                 打开文件夹：open -R '$DIR/灵台智枢.app'" ;;
      esac
      case "$st" in
        *"key=1 active=1 fr=NSTextView"*) echo "   面板焦点    ✅ 窗口是 key、App 已激活、输入框已聚焦" ;;
        *"show"*) echo "   面板焦点    ❌ 上次唤起时 key/active 不对 → 打字会落到别的 App（这就是「打字没反应」）"; bad=1 ;;
        *) echo "   面板焦点    （本会话还没唤起过面板，按一次 ⌃⌥⌘ 再看）" ;;
      esac
    else
      echo "④ 常驻进程    ❌ 没在跑 → 热键必然没反应。手动起：./flashctl.sh open"; bad=1
    fi
    # 5 授权
    ax="$("$FLASH" --status 2>/dev/null | sed -n 's/.*辅助功能: \(.\).*/\1/p' | head -1)"
    if [ "$ax" = "✅" ]; then echo "⑤ 辅助功能    ✅ 二进制本身已授权（注意：经 .app 启动的是另一个 TCC 身份，看 ④ 那行）"
    else echo "⑤ 辅助功能    ❌ 未授权 → 系统设置 > 隐私与安全性 > 辅助功能 里勾上 flash"; bad=1; fi
    # 6 路由命中率（最近 60 条 route）
    logf="$HOME/.workbuddy/skills/mac-control/logs/$(date +%Y-%m-%d).jsonl"
    # 凌晨自检时今天的日志还是空的，退一天看昨天的
    [ -s "$logf" ] || logf="$HOME/.workbuddy/skills/mac-control/logs/$(date -v-1d +%Y-%m-%d).jsonl"
    if [ -f "$logf" ]; then
      /usr/bin/python3 - "$logf" <<'PYEOF'
import sys, json, collections
hit = miss = 0
for line in open(sys.argv[1], encoding="utf-8").readlines()[-400:]:
    try: d = json.loads(line)
    except: continue
    if d.get("intent") != "route": continue
    if d.get("error_code") == "route_match": hit += 1
    elif d.get("error_code") == "ELEMENT_NOT_FOUND": miss += 1
tot = hit + miss
if tot:
    print("⑥ 路由        %d/%d 命中（最近一批），未命中 %d 条会走转交" % (hit, tot, miss))
else:
    print("⑥ 路由        今天还没有指令记录")
PYEOF
    else
      echo "⑥ 路由        今天还没有审计日志"
    fi
    # 7 媒体目录（2026-10-25：截图与录屏合成一个目录，png/mov 并排）
    if [ -w "$HOME/Desktop/灵台智枢" ] || mkdir -p "$HOME/Desktop/灵台智枢" 2>/dev/null; then
      echo "⑦ 截图目录    ✅ ~/Desktop/灵台智枢"
    else
      echo "⑦ 截图目录    ❌ 不可写"; bad=1
    fi
    echo ""
    if [ "$bad" -eq 0 ]; then
      echo "结论：一切正常。把 ⌃⌥⌘ 三个键一起按下，应该弹出面板并直接打字。"
    else
      echo "结论：上面带 ❌ 的地方就是「用不了」的原因，按提示那一条处理即可。"
    fi
    ;;

  # ── 释放/恢复 macOS 对 ⌃⌥Space 的占用 ─────────────────────────────
  # 系统默认把 ⌃⌥Space 绑给了「选择下一个输入法」（symbolichotkeys key 61）。
  # 系统级快捷键会抢在应用前面消费按键，这就是闪控「时好时坏」的根源。
  # 关掉它以后 ⌃⌥Space 才真正属于闪控；⌃⌥S 作为备用键始终可用。
  ime-key)
    PREF="$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"
    case "${2:-off}" in
      off)
        cp -n "$PREF" "$HOME/Library/Preferences/com.apple.symbolichotkeys.backup.plist" 2>/dev/null
        # ⚠ 不能用 `defaults write ... -dict-add 61 '{enabled = 0;}'`：它把 0 写成
        #   **字符串 "0"**，系统按"非空即真"处理 → 快捷键其实没关掉（实测踩过）。
        #   必须写真正的布尔值。
        /usr/bin/python3 - "$PREF" false <<'PYEOF'
import plistlib, sys, subprocess
p, val = sys.argv[1], sys.argv[2] == 'false'
d = plistlib.load(open(p, 'rb'))
hk = d.setdefault('AppleSymbolicHotKeys', {})
e = hk.setdefault('61', {})
e['enabled'] = (not val)
if val:
    e['enabled'] = False
else:
    e['enabled'] = True
    e['value'] = {'parameters': [32, 49, 786432], 'type': 'standard'}
hk['61'] = e
plistlib.dump(d, open(p, 'wb'))
subprocess.run(['/usr/bin/killall', 'cfprefsd'], capture_output=True)
PYEOF
        echo "✅ 已关闭系统快捷键「选择下一个输入法」（⌃⌥Space）"
        echo "   回滚：flashctl.sh ime-key on"
        echo "   注意：macOS 可能要注销/重新登录才真正释放这个组合。"
        ;;
      on)
        /usr/bin/python3 - "$PREF" true <<'PYEOF'
import plistlib, sys, subprocess
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
hk = d.setdefault('AppleSymbolicHotKeys', {})
hk['61'] = {'enabled': True, 'value': {'parameters': [32, 49, 786432], 'type': 'standard'}}
plistlib.dump(d, open(p, 'wb'))
subprocess.run(['/usr/bin/killall', 'cfprefsd'], capture_output=True)
PYEOF
        echo "✅ 已恢复系统快捷键「选择下一个输入法」（⌃⌥Space 交还系统）"
        ;;
      status)
        # ⚠ 别用正则去啃 `defaults read` 的文本输出（格式会变，我第一版就误报成"已关闭"）。
        #   直接读 plist 里的布尔值。
        /usr/bin/python3 - "$PREF" <<'PYEOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
hk = d.get('AppleSymbolicHotKeys', {}).get('61', {})
v = hk.get('enabled')
on = v if isinstance(v, bool) else str(v).strip().lower() in ('1', 'true', 'yes')
print('  系统「选择下一个输入法」(⌃⌥Space)：', '开启 —— 会跟闪控抢这个组合' if on else '关闭 —— ⌃⌥Space 归闪控')
PYEOF
        ;;
      *) echo "用法：flashctl.sh ime-key off|on|status" ;;
    esac
    ;;

  # ── 安静复盘：把今天失败过的事情归类，告诉人"什么在反复坏" ─────────────
  # 设计取向（用户 2026-10-23）：「安静的复盘并解决问题」——
  #   面板不当场吼用户，但每一次没成都进了 failures-YYYY-MM-DD.jsonl，
  #   这里按原因聚合并给出处置建议，让"没反应"变成"可修的一条"。
  review)
    # 数据源用**审计日志**（route.sh/macctl 每次执行都会写，已经被大量实测验证），
    # 而不是面板自己另写一份 —— 少一份日志就少一处会坏的地方。
    /usr/bin/python3 - "$HOME/.workbuddy/skills/mac-control/logs" "${2:-3}" <<'PYEOF'
import sys, json, os, glob, collections
logdir, days = sys.argv[1], int(sys.argv[2])
files = sorted(glob.glob(os.path.join(logdir, "20*.jsonl")), reverse=True)[:days]
fails, oks = [], 0
for f in files:
    for line in open(f, encoding="utf-8"):
        try: d = json.loads(line)
        except Exception: continue
        res = (d.get("result") or "").lower()
        if res in ("fail", "error") or d.get("error_code") in ("ELEMENT_NOT_FOUND", "PERMISSION_DENIED"):
            fails.append(d)
        elif res in ("info", "ok", "success"):
            oks += 1
print("最近 %d 天：%d 次执行，%d 次没成" % (days, oks + len(fails), len(fails)))
if not fails:
    print("✅ 没有失败记录"); sys.exit(0)
by = collections.Counter()
for d in fails:
    by["%s ← %s" % (str(d.get("intent"))[:14], str(d.get("evidence"))[:44])] += 1
print("\n—— 什么在反复坏 ——")
for k, n in by.most_common(8):
    print("  %2d×  %s" % (n, k))
HINTS = {
    "music_play": "已知限制：酷狗主界面自绘、无 AX 输入框 → 播放改手动（不是回归）",
    "open_file": "open_file.sh（文件名匹配）；若报‘缺少 --name’是自检用例，忽略",
    "wechat_send": "wechat_send.sh（会话搜索/输入框定位）",
    "route": "route.sh 路由表；‘指令未命中’是转交，不是故障",
    "perm": "TCC 授权（屏幕录制/辅助功能）",
}
print("\n—— 该改哪里 ——")
seen = set()
for d in fails:
    act = str(d.get("intent") or "")
    for k, v in HINTS.items():
        if k in act and k not in seen:
            seen.add(k); print("  %-12s → %s" % (k, v))
if not seen:
    print("  （没有命中已知类别，需要人工看一眼原句）")
print("\n—— 最近 5 条 ——")
for d in fails[-5:]:
    print("  %s  %s  %s" % (d.get("t") or d.get("ts") or "", str(d.get("intent"))[:12], str(d.get("evidence"))[:46]))
PYEOF
    ;;

  # ── 今日简报：今天做了什么 / 哪里慢 / 哪里重复 ─────────────────────
  # 用户 2026-10-24 要求：每日复盘要**回忆今天完成了哪些任务**，
  # 并复盘"如何更快"，而不只是数失败次数。
  # 数据源同样是审计日志（已经是每次执行的必写项），不另建埋点。
  digest)
    /usr/bin/python3 - "$HOME/.workbuddy/skills/mac-control/logs" "${2:-1}" <<'PYEOF'
import sys, json, os, glob, collections, datetime

logdir, days = sys.argv[1], int(sys.argv[2])
files = sorted(glob.glob(os.path.join(logdir, "20*.jsonl")), reverse=True)[:days]
rows = []
for f in files:
    for line in open(f, encoding="utf-8"):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("error_code") in ("route_intent",):   # 纯回显，不算动作
            continue
        rows.append(d)

if not rows:
    print("今天没有执行记录。"); sys.exit(0)

OK = ("ok", "info", "success")
ok = [r for r in rows if (r.get("result") or "").lower() in OK]
bad = [r for r in rows if (r.get("result") or "").lower() in ("fail", "error")]

def short(r, n=34):
    ev = str(r.get("evidence") or "")
    return ev[:n]

print("═══ 最近 %d 天（截至 %s）═══" % (days, datetime.date.today()))
print("执行 %d 次，成功 %d 次，失败 %d 次" % (len(rows), len(ok), len(bad)))

# 按动作类别聚合
def kind(r):
    it = str(r.get("intent") or "")
    for k in ("wechat_send", "music_play", "open_file", "shot", "volume",
              "readscreen", "route", "handoff", "handoff_retry"):
        if k in it:
            return k
    return it.split(":")[0][:12] or "其他"

by = collections.Counter(kind(r) for r in ok)
print("\n—— 做成的事 ——")
for k, n in by.most_common(10):
    print("  %-14s %d 次" % (k, n))

# 重复动作：同类别 ≥3 次 → 可以合并成一步
rep = [(k, n) for k, n in by.items() if n >= 3]
print("\n—— 重复劳动（可合并/可一键）——")
if rep:
    for k, n in sorted(rep, key=lambda t: -t[1]):
        print("  %-14s %d 次 → 考虑做成一个组合动作" % (k, n))
else:
    print("  没有明显重复，动作足够分散")

# 失败集中度
if bad:
    fb = collections.Counter(kind(r) for r in bad)
    print("\n—— 卡住的地方 ——")
    for k, n in fb.most_common(5):
        why = collections.Counter(short(r, 22) for r in bad if kind(r) == k).most_common(1)
        print("  %-14s %d 次  最常见原因：%s" % (k, n, why[0][0] if why else "—"))

print("\n—— 复盘三问 ——")
print("  1. 今天哪件事做了 3 次以上？能不能合并成一句话完成？")
print("  2. 哪个动作失败最多？是环境（授权/窗口态）还是逻辑？")
print("  3. 明天最该省掉的那一步是什么？")
PYEOF
    ;;

  logs)
    tail -30 "$LOG" 2>/dev/null
    echo "--- stderr ---"
    tail -20 /tmp/flash.err.log 2>/dev/null
    ;;

  # ── 开机开场动画的自启注册（com.lingtai.bootanim → wblaunch boot）───────
  # ⚠⚠ 2026-10-22 实测教训：这个 plist 曾经**躺在磁盘上但从没被 bootstrap**，
  #   症状就是「重启后开场动画根本不弹，/tmp/wbboot.log 连文件都不存在」。
  #   plist 存在 ≠ 注册成功 —— 判据只有一个：launchctl list 里有没有这个 label。
  #   与 flash 分开装：动画是独立工件（二进制在 bootanim/tools/），
  #   用户可以只要闪控不要动画。
  install-boot)
    WBL="$DIR/bootanim/tools/wblaunch"
    [ -x "$WBL" ] || { echo "❌ wblaunch 未编译：cd $DIR/bootanim/tools && swiftc -O -o wblaunch wblaunch.swift"; exit 1; }
    WBLABEL="com.lingtai.bootanim"
    WBPLIST="$HOME/Library/LaunchAgents/$WBLABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$WBPLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$WBLABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$WBL</string>
        <string>boot</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/wbboot.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/wbboot.err.log</string>
</dict>
</plist>
PLISTEOF
    plutil -lint "$WBPLIST" > /dev/null 2>&1 || { echo "❌ plist 语法错误"; exit 1; }
    launchctl bootout "gui/$(id -u)/$WBLABEL" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$WBPLIST" 2>/dev/null
    launchctl load "$WBPLIST" 2>/dev/null
    sleep 1
    # 与 install 同一条铁律：不信 launchctl 返回值，只信 launchctl list
    if launchctl list 2>/dev/null | grep -q "$WBLABEL"; then
      echo "✅ 已注册开机开场动画（${WBLABEL}）：重启后先播动画，WorkBuddy 后登场"
    else
      echo "⚠️  注册没生效（常见于沙箱/SSH 会话）。请在图形界面终端里执行："
      echo "    launchctl bootstrap gui/\$(id -u) $WBPLIST"
    fi
    ;;

  uninstall-boot)
    WBLABEL="com.lingtai.bootanim"
    launchctl bootout "gui/$(id -u)/$WBLABEL" 2>/dev/null
    launchctl unload "$HOME/Library/LaunchAgents/$WBLABEL.plist" 2>/dev/null
    rm -f "$HOME/Library/LaunchAgents/$WBLABEL.plist"
    echo "✅ 已取消开机开场动画自启（${WBLABEL}）"
    ;;

  *) usage ;;
esac