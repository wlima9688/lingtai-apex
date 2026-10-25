# 闪控 mac-control：把 N轮指挥压成 1轮

**慢的不是执行，是决策轮次。** 点击、打字都是毫秒级，慢在「截图→看图→思考→坐标→执行→再截图」的循环。
本技能 = **意图层**（一句话 → 一整件事）+ **控制层**（`macctl` 原子命令）。
**优先用意图层**，路由表不覆盖时才直接调 `macctl`。

## 一、意图层：路由表（唯一事实源）

| 触发语（含同义句） | 命令 | 级别 | 预算 | 状态 |
|---|---|---|---|---|
| 开音乐 / 继续放 / 放首歌 / 播放《X》 | `scripts/music_play.sh --song? --volume?` | L0 | ≤8s | ✅ 静音执行，原唱优先 |
| 刷抖音 / 看会儿抖音 | `scripts/douyin_open.sh --url?` | L0 | ≤3s | ✅ 端到端通过 |
| 给 XX 发微信说 YY | `scripts/wechat_send.sh --to --msg` | L1 | ≤10s | ✅ 搜索已打通（D-017） |
| 截图（免授权）/ 截图·含窗口 / 录屏执行器 | `scripts/mediacap.sh`（`mode=shot\|region`，由 `com.lingtai.mediacap` 拉起）、`scripts/rec_agent.sh` | L0 | ≤2s / 常驻 | ✅ 落 桌面/灵台智枢/截图/年/月/；「含窗口」版面板不藏，其余流程相同 |
| 录屏 / 开始录屏 / 停止录屏 | `scripts/screen_rec.sh --toggle\|--stop\|--status` | L0 | ≤3s | ✅ 开始/停止二态 |
| 打开 XX 应用 / 启动 XX | `macctl launch --name "XX"` | L0 | ≤3s | ✅ 中文名自动映射，未运行会拉起 |
| 声音大点 / 音量调到 N | `macctl volume --set N` | L0 | <1s | ✅ |
| 一句话下达指令 / 随手指挥 | `scripts/route.sh "给张三发微信:你好"` | L0/L1 | <1s | ✅ 热键 ⌃⌥Space 唤起 flash |
| 电脑能操作吗 / 环境检查 | `macctl doctor` | L0 | <2s | ✅ |
| 找 X 在哪 / X 的坐标 | `macctl locate --text "X"` | L0 | <1s | ✅ AX→OCR 自动降级 |
| 转给 WorkBuddy / 这条你做不了 / 复杂任务 | `scripts/flash --handoff "原文" [--skill mac-control]` | L0 | ≤12s | ✅ 全自动：新建任务→粘贴→选技能→发送 |
| 闪控支持什么 | 读本表 | — | — | — |

**⚠️ 定位一律用 `macctl locate`，不要用 `macctl find`。**
`find` 只有 AX 一条路，撞到自绘控件就报「找不到」；`locate` 会自动降级到 OCR 视觉定位
（微信搜索框就是自绘控件，曾因此误判为「能力受限」，D-017 已打通）。

脚本目录 `S=~/.workbuddy/skills/mac-control/scripts`，下表命令都按此路径调用。
**用户不在电脑前时不用问要不要继续。** 直接调用——脚本会自动检测锁屏并快速返回原因。
**截图/录屏固定落盘 `~/桌面/灵台智枢/{截图,录屏}/年/月/`**（两类分家，各自按 `年/月` 归档；**根下不再有文件**），文件名 `20261025-102538.png` / `20261025-095757.mov`（`yyyyMMdd-HHmmss`，时间戳即排序）；汇报时**必须念出这个路径**。

### 三条铁律

1. **命中即执行。** 不先 `state` 试探、不拆多步。脚本自己处理遮挡、置前、验证。
2. **最多问一次。** 缺参按「显式 > 上下文 > preferences.md > 最近同类」推断并**带默认项**；不中就降级，绝不追问第二句。
3. **表外意图不接。** 说明「这个我还不会，已记入沉淀池」并写 `proposals.jsonl`，不要手搓脚本。

### 转交（工件B）：闪控做不了的事，自己送过去

`flash --handoff "原文" [--skill mac-control]` 一条命令跑完，失败会带 `step` 断点且
原文留在剪贴板。**细节与判据见 `references/patterns.md` 配方 E** —— 别自己拼 AX 点击。

---

## 二、返回契约与失败处置

意图脚本返回统一 JSON（**只看这个，不要截图确认**）：
`{"ok":true,"action":"...","target":"...","need_confirm":false,"evidence":"...","duration_ms":5230,"error_code":null}`

`evidence` 是给人看的证据，**直接念给用户**。退出码：`0` 成功 / `1` 失败 / `2` 需确认 / `3` 停手交人。
完整字段定义与错误码枚举见 `references/engineering-rules.md`。

**拿到 `error_code` 后不要自己再去截图或试探** —— 脚本已完成排查：

| `error_code` | 你该做什么 |
|---|---|
| `NEED_HUMAN` + `blocked_by: screen_locked_or_input_blocked` | 「电脑锁屏了，解锁后我再来」 |
| `NEED_HUMAN` + 其他 `blocked_by` | 念 `manual_step`，请用户手动做那一步 |
| `PERMISSION_DENIED` | 引导打开系统设置对应开关 |
| `APP_NOT_FOUND` / `ELEMENT_NOT_FOUND` | 问是否要装 / 记 `proposals.jsonl` 并告知「界面认不出了」 |
| `TIMEOUT` / `AMBIGUOUS` | 报 `evidence` 里的实测耗时建议重试 / 带 `candidates` 问一次（**带默认项**） |

---

## 三、安全边界（自动生效，无需你判断）

- **L0 可逆本地**（开文件、播歌、调音量、开App）→ 直接执行
- **L1 对外可见不可逆**（发消息）→ 停下等确认
- **L2 密钥资金**（密码/验证码、支付/银行/密码管理器）→ 停手返回 `NEED_HUMAN`
- **密码红线**：像密码/验证码的内容 → 永不输入、永不存储
- **静音守卫**：执行期间强制静音（音乐也静音），退出恢复；每次执行写 `logs/YYYY-MM-DD.jsonl`

### L1 确认流程（发消息）

`wechat_send.sh` 分两段：**第 1 次调用**（无 `--confirmed`）→ 返回
`{"need_confirm":true,"confirm_prompt":"..."}` →你**原样**转达用户 →
**第 2 次调用**（用户确认后）→ 同样的参数 + `--confirmed`，脚本发送并自验证。

**绝不允许**在同一次调用里既确认又发送。**绝不允许**改写确认文本（防理解偏差）。

### 环境预检

> **锁屏时 macOS 会静默丢弃所有 CGEvent 合成输入**：点击不生效、粘贴不进字，
> `AXPress` 返回 success 而界面毫无变化，**任何工具都不报错**。
> 判据只有一条：**实测移动光标看位置是否真变**（`CGSSessionScreenIsLocked` 为 nil、
> `loginwindow` 常驻，都不能用）。单次探测会误报（D-022），现在探 3 次取多数 +
> 「屏幕上有无正常窗口」交叉验证，且报错文案**不断言锁屏**，只列事实。
需模拟输入的脚本动手前跑 `doctor`；只走 Launch Services 的（如 `open_file.sh`）
**不应预检** —— 对它做光标探测是假阻塞。

---

## 四、控制层：macctl

```bash
M=~/.workbuddy/skills/mac-control/scripts/macctl
```

**控制层铁律**：不现写 Swift、不猜坐标、**不用 `sleep`（用 `probe`）**、AX 树空先 `diagnose`、
**动手前先 `doctor`**。改完源码必须 `/usr/bin/swiftc -O -o macctl macctl.swift` 重编译。

### 常用命令

| 命令 | 用途 |
|---|---|
| `doctor [--app <id>]` | **环境体检**（实测输入通道 + 高层浮窗），动手前必跑 |
| `probe --app <id> --mode ax\|text\|role\|textfield` | **进程内条件等待，代替 sleep** |
| `overview` / `state --app <id>` | 全局窗口聚合 / 窗口+AX树+焦点 |
| `find --text <T>` / `click --text <T>` / `--at x,y` | 定位 / 语义点击（自动降级 Quartz）/ 坐标点击 |
| `type --text <T>` / `key --key <k> [--cmd]` | 智能中文输入（三级降级+记忆）/ 键盘 |
| `winback` / `clear --app <id>` | 窗口后置 / 清空输入框（`[ax]`/`[quartz]` 标明生效路径） |
| `shot` / `scan` / `pixel` / `scroll` / `drag` | 截图（默认存 `~/桌面/灵台智枢/截图/年/月/`）/ 裁剪 / 取色 / 滚动 / 拖拽 |
| `diagnose` / `raise` / `dock` / `front` | 诊断 AX 为空 / 置前抗遮挡 |
| **`launch --name <应用名>`** | **按名称启动/唤醒应用**：中文名自动映射（计算器↔Calculator）、未运行会拉起、Dock 兜底。「打开X」走它，别走 `open_file.sh` |
| **`dock --app <名称>`** | **点 Dock 图标唤醒 —— 应用「在运行但最小化」时的首选手段** |
| `apps --json` / `volume [--set N]` / `app-volume` | 列应用 / 系统音量 / 应用内音量 |
 | `recall` / `note --app <id> --text <描述>` | 查看 / 记录 app 交互模型 |
键名：`return tab space esc left right up down delete a-z`；修饰符 `--cmd --shift --alt --ctrl`。
**输出**：大结果用 `--out <file>`（同路径重复安全）。**不要用管道传大 JSON**。完整命令表见 `references/troubleshooting.md`。

### 标准四步 + 条件等待

```bash
$M overview# 1 谁在前台、谁挡了谁
$M state --app <bundleId> --depth 8    # 2 深入目标
$M click --text "发送" --app <id>      # 3 动作
$M find --text "发送" --app <id>       # 4 验证
```
**不用 `sleep` 盲等**，用 `probe`（条件一成立立即返回）：实测超时场景 shell 轮询 13.4s vs `probe` 5.5s。

## 五、持续优化

**未命中意图** → 写 `proposals.jsonl`；**新App 交互模型** → `macctl note`；**加脚本** → `scripts/` 新建 +
**路由表加一行** + 跑 `lint.sh`；**改完自检** → `selftest.sh`（170 项，静音）；**性能** → `bench.sh --runs 20`。
**改完 flash 面板** → 必跑 `flash --layout-check`；⚠ 窗口高度**不许手写**，`Layout.H` 必须由算式累加，否则加内容必溢出。

**动手前先查**：`BUGFIX.md`（修复台账，症状→根因→修法→验证→教训，同类症状直接跳修法）、`DIAGNOSIS.md`、`references/engineering-rules.md`（铁律 + bash/Swift/AX 陷阱 +
返回契约）、`references/troubleshooting.md`（故障手册 + 命令表）、`references/patterns.md`、
`references/permissions.md`（TCC）、`CHANGELOG.md`。

### 五条设计铁律（每条都对应一次真实故障）

1. **工具层失败必须显式报错** —— 静默兜底会让上层把工具故障误读成「业务对象不存在」。
2. **能用应用自己的排序解决，就不要在脚本里猜** —— 脚本猜不准业务语义，应用的数据源不会错。
3. **动手之前先确认「能不能动手」** —— 环境阻塞在入口拦截，不让它伪装成业务错误。
4. **参数校验 → 环境预检 → 业务动作** —— 顺序有语义，`lint.sh` 会检查。
5. **布局不许手写常数** —— 高度必须由算式累加（"排版超格"的根因）。
6. **判据必须盯「用户看得见的东西」** —— 前台≠可见、有音轨≠有声、点了≠做到（B-013）。

**意图消歧：最多一问。** 缺歌名→「继续放上次那首」；缺联系人→用 `preferences.md` 的 `default_contact`；文件多匹配→脚本返回 `candidates`，带选项问一次；不明→问一次带默认项，不中就降级。
