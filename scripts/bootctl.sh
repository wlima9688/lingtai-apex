#!/bin/bash
# 闪控 · bootctl.sh — WorkBuddy 开场动画的开机自启管理脚本
#
# 为什么需要这个：
#   用户要求「WorkBuddy 开机自启动时播放开场动画」。
#   WorkBuddy 自己用 SMAppService 注册了登录项（sfltool dumpbtm 里能看到
#   2.com.tencent.workbuddy.mac），系统直接放行，**没有任何拦截点**。
#   所以我们不去抢「先启动」这个位置 —— 改为注册自己的 LaunchAgent，
#   在登录时和 WorkBuddy 同时起来，动画窗口用 .floating 层级盖在 WorkBuddy 上面，
#   播完再把 WorkBuddy 置前。视觉效果与「WorkBuddy 先启动、动画后盖上」一致。
#
# 关键约束（全部来自实测踩坑）：
#   ① 手动双击打开 WorkBuddy → **不播**。
#      手动路径走 LaunchServices / Dock，完全不经过本脚本 → 天然满足。
#   ② 闪控转交复杂任务（WorkBuddy 已在运行）→ **不播**。
#      route.sh 里判定「已在运行」就不调启动器 → 天然满足。
#   ③ 闪控启动 WorkBuddy（此前未运行）→ **播**。route.sh 负责调 `wblaunch play`。
#   ④ 开机自启动 → **播**。本脚本注册的 LaunchAgent 调 `wblaunch boot`。
#
# 用法：
#   bootctl.sh install    注册开机自启（动画会在下次登录时播）
#   bootctl.sh uninstall  取消开机自启
#   bootctl.sh status     看状态
#   bootctl.sh test       立刻试播一次（不等开机）
#   bootctl.sh logs       看日志

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.shankong.wbboot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LAUNCHER="$DIR/bootanim/tools/wblaunch"
LOG="/tmp/wbboot.log"
ERRLOG="/tmp/wbboot.err.log"

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \?//'
}

is_running() { pgrep -f "wblaunch boot" > /dev/null 2>&1; }

write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents"
  # ⚠ 路径必须写绝对路径：LaunchAgent 的工作目录不是 skill 目录，
  #   相对路径会找不到二进制 → 开机时静默失败。
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$LAUNCHER</string>
        <string>boot</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$ERRLOG</string>
</dict>
</plist>
PLISTEOF
  plutil -lint "$PLIST" > /dev/null 2>&1 || { echo "❌ plist 语法错误"; exit 1; }
}

cmd="${1:-status}"

case "$cmd" in
  install)
    if [ ! -x "$LAUNCHER" ]; then
      echo "❌ 启动器未编译：cd $DIR/bootanim/tools && swiftc -O -o wblaunch wblaunch.swift"
      exit 1
    fi
    write_plist
    # ⚠ 不要信 launchctl 的返回值，只信「注册是否真的生效」。
    #   实测在沙箱/受限环境里 launchctl load 会返回 0 但什么都没注册。
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    launchctl unload "$PLIST" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null
    launchctl load "$PLIST" 2>/dev/null
    sleep 1
    if launchctl list 2>/dev/null | grep -q "$LABEL"; then
      echo "✅ 已注册开机自启（${LABEL}）"
      echo "   下次登录时：WorkBuddy 与开场动画同时启动，动画盖在 WorkBuddy 之上，播完自动置前"
    else
      echo "⚠️  已写入 plist，但 launchctl 未生效（常见于沙箱/SSH 会话）"
      echo "   请在图形界面的终端里执行："
      echo "     launchctl bootstrap gui/\$(id -u) $PLIST"
    fi
    ;;

  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    launchctl unload "$PLIST" 2>/dev/null
    rm -f "$PLIST"
    echo "✅ 已取消开机自启（不再播开场动画）"
    ;;

  status)
    echo "WorkBuddy 开场动画 · 开机自启状态"
    echo "  启动器:   $LAUNCHER$([ -x "$LAUNCHER" ] && echo ' ✅' || echo ' ❌ 未编译')"
    echo "  plist:    $PLIST$([ -f "$PLIST" ] && echo ' ✅' || echo ' ❌ 未注册')"
    if launchctl list 2>/dev/null | grep -q "$LABEL"; then
      echo "  launchd:  ✅ 已加载"
    else
      echo "  launchd:  ❌ 未加载（重启后会失效）"
    fi
    echo ""
    echo "  播放规则（当前实现）："
    echo "    开机自启动          → 播 ✅"
    echo "    闪控启动（未运行）  → 播 ✅"
    echo "    闪控转交（已运行）  → 不播 ✅"
    echo "    手动双击打开        → 不播 ✅（走 LaunchServices，不经过本启动器）"
    ;;

  test)
    if [ ! -x "$LAUNCHER" ]; then
      echo "❌ 启动器未编译"
      exit 1
    fi
    echo "▶ 试播一次（模拟开机自启场景）…"
    WB_LAUNCH_DEBUG=1 "$LAUNCHER" boot 2>&1 | sed 's/^/  /'
    ;;

  logs)
    tail -30 "$LOG" 2>/dev/null
    echo "--- stderr ---"
    tail -20 "$ERRLOG" 2>/dev/null
    ;;

  *) usage ;;
esac
