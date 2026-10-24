# 灵台智枢 · LingTai Apex

> 一句话说清、一次做完的 macOS 桌面工作台。按 `⌃⌥Space` 呼出，一句话分流到
> 本地原子动作 / 内容生成 / 工件制作 / 项目规划四个执行者，全程留痕。

本仓库是它的**源码与技能包**，MIT 授权。

## 它是什么

**一个常驻的浮层面板 + 一套原子动作引擎**，把「截图 / 发微信 / 开应用 / 调音量 /
录屏 / 切前台」这类高频操作从「模型看图 → 思考 → 点击」压成一次调用。

设计出发点是**减少决策轮数**，不是"更多功能"：
慢的从来不是执行（毫秒级），而是「截图 → 模型看图 → 思考 → 再验证」这个循环。

## 组成

| 目录 | 作用 |
|---|---|
| `scripts/flash.swift` | 面板本体（AppKit，浮层 + 全局热键 + 自检栏 + 线框地球） |
| `scripts/macctl.swift` | 原子动作引擎：state / click / key / type / shot / launch / volume / scwindows… |
| `scripts/route.sh` | 一句话路由：先判能不能原子执行，再决定转交谁 |
| `scripts/common.sh` | 共用函数（审计日志、JSON 输出、焦点守卫） |
| `scripts/bootanim/` | 开机动画（WKWebView 全屏壳 + `run-at-login.sh` 顺序总控） |
| `scripts/*.sh` | 专项：微信发送、录屏、音乐、文件打开、额度抓取 |
| `SKILL.md` | 给 AI（DSH / WorkBuddy）读取的技能说明：能力、边界、调用方式 |
| `references/` | 补充文档 |

## 构建

要求：macOS 13+、Xcode 命令行工具（`xcode-select --install`）。

```bash
cd scripts

# 原子动作引擎
swiftc -O -o macctl macctl.swift

# 面板（需要把 macctl.swift 里的 Args 定义一起编译）
./build_flash.sh

# 开机动画
cd bootanim/tools && swiftc -O -o wblaunch wblaunch.swift && cd ../..
```

产物：`scripts/macctl`、`scripts/flash`、`scripts/bootanim/tools/wblaunch`。

## 运行

```bash
# 面板（首次需要辅助功能授权）
./flashctl.sh install-app      # 装到 /Applications 并启动
./flashctl.sh status

# 原子动作
./macctl state --app com.apple.finder
./macctl click --text "确定" --app com.apple.finder
./macctl shot --out /tmp/shot.png
```

## SKILL 接入（给 AI 用）

`SKILL.md` 是**自描述技能**：任何支持「读技能文件」的 AI 都可以把它当手册，
按里面的能力表与边界调用 `macctl`。目前已接入：

- **DSH（天公）**：作为 `shankong` 技能加载
- **WorkBuddy**：按 `SKILL.md` 的原子命令表调用
- **豆包**：不能执行本地命令，只做「自然语言 → 规范指令」的翻译（见知识库里的指令卡）

## 设计约束（不是 bug）

- **不做多步推理**：它只执行已知意图；需要判断的交给上层 AI。
- **发送前必须回读**：微信发送前回读收件人 + 正文；群发/广播一律拦截。
- **红区永不做**：密码、验证码、支付、系统安全设置、隐私外传，一律拒绝。
- **GUI 互斥**：多个 AI 同时操作电脑时用文件锁排队，拿不到就返回 `BUSY`，不硬抢。

## 授权

MIT，见 [LICENSE](LICENSE)。

私有路径（`/Users/<用户名>/...`）若出现在部分脚本里，是作者本机配置；换机器时按需调整。
