# macOS 权限配置说明

macctl 依赖以下 TCC 授权。缺失时症状各不相同。

| 权限 | TCC 服务名 | 缺失症状 | 用途 |
|---|---|---|---|
| 辅助功能 | Accessibility | AX 树为空、AXPress 无效果 | 读取界面结构、点击控件 |
| 屏幕录制 | ScreenCapture | 截图只有桌面壁纸/菜单栏，应用窗口全被抹掉 | 截图与视觉定位 |
| 输入监控 | ListenEvent | Quartz 真实鼠标/键盘事件不生效 | 点击、输入、按键 |
| 自动化 | AppleEvents | `osascript` 报 -10004 权限违例 | 系统音量、激活 app |
| 完全磁盘访问 | SystemPolicyAllFiles | 读 `TCC.db` 被拒 | **本技能不需要** |

## 授权步骤

**方式一：一键脚本**（本机已有）
```bash
~/Desktop/一键授权WorkBuddy.command
```
双击运行，逐步在打开的系统设置面板中勾选对应权限。

**方式二：手动**
1. 打开「系统设置 → 隐私与安全性 → 辅助功能」，勾选 **WorkBuddy**
2. 同页 → 「屏幕录制」，勾选 **WorkBuddy**
3. 同页 → 「输入监控」，勾选 **WorkBuddy**
4. 同页 → 「自动化」，在 WorkBuddy 下勾选目标 app（系统事件、系统设置等）

命令行直达各面板：
```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
```

## 重置（授权错乱时）

`reset` 只能重置、不能授予，需在**用户自己的终端**执行（沙箱内会报 Operation not permitted）：
```bash
tccutil reset Accessibility com.tencent.workbuddy.mac
tccutil reset ScreenCapture com.tencent.workbuddy.mac
tccutil reset ListenEvent com.tencent.workbuddy.mac
tccutil reset AppleEvents com.tencent.workbuddy.mac
```
重置后重新走一遍授权流程，并在弹窗出现时点「好」。

## 验证

```bash
M=~/.workbuddy/skills/mac-control/scripts/macctl
M state --app com.apple.finder   # 能读到窗口列表 → Accessibility OK
M shot --out /tmp/t.png           # 能拍到应用窗口 → ScreenCapture OK
M click --at 700,450              # 界面有反应 → Input Monitoring OK
```

## 已知环境事实

- WorkBuddy 进程树：`swift → 内置 zsh → sandbox-cli → Electron`
- 负责授权的 bundle id：`com.tencent.workbuddy.mac`
- 沙箱内 `ps` 会报 "operation not permitted"，用 `pgrep -fl` 替代
- 直接 exec Chrome 等 app 二进制会失败，必须走 LaunchServices（`open -a`）
- `screencapture`/`CGWindowListCreateImage` 在 macOS 15 已弃用，**必须用 ScreenCaptureKit**（macctl 已封装）

## 固化辅助功能 / 桌面授权（别再被弹窗骚扰）

**问题**：明明勾了「允许」，下次启动还是弹「"flash" 想使用辅助功能」或
「想要访问你的"桌面"文件夹」。

**为什么**：ad-hoc 签名的「指定要求」是 **cdhash**。每改一次代码重新编译，
cdhash 就变，macOS 认为这是另一个程序，之前的授权全部失效。

**一次修好**（本机已经做过，换机器时照做）：

```bash
# 1. 造一张固定的自签代码签名证书（10 年有效）
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=Shankong Local Signer/O=Shankong" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -out sk.p12 -inkey key.pem -in cert.pem -passout pass:shankong
security import sk.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -P shankong

# 2. 重新签名（build_flash.sh 每次编译后会自动做这一步）
~/.workbuddy/skills/mac-control/scripts/flashctl.sh sign

# 3. 只授权这一次
~/.workbuddy/skills/mac-control/scripts/flashctl.sh ax   # 需要辅助功能时
```

签名后可验证：

```bash
codesign -d -r- ~/.workbuddy/skills/mac-control/scripts/flash
# designated => identifier "com.lingtai.apex" and certificate root = H"8296c5f8…"
```

只要这条要求里的**证书根不变**，重编译就不会让授权失效。

**另外两条规矩（别再犯）**：

- 启动路径**不许访问** ~/Desktop、~/Documents、~/Downloads：面板每次唤起都会
  跑自检，碰一次就弹一次「访问桌面」框。文件数这类展示信息应延迟到用户真正
  打开目录时再取。（2026-10-23 用户投诉的直接原因）
- **不许在启动时主动弹授权框**。缺权限只降级；需要授权时由人跑
  `flashctl.sh ax`。
