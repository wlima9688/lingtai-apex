# 写脚本前必读

这份文档是闪控（mac-reflex）在从「能跑」到「可靠」过程中沉淀出来的工程约束。
**每一条都对应一次真实故障**，不是理论洁癖。改脚本前先扫一遍，能省掉整轮返工。

---

## 一、四条设计铁律

### ① 工具层失败必须显式报错

解析器收到未知函数名，要 `stderr` + 非零退出，**不能静默返回空串或默认值**。

**反面教材（本项目真实发生）：**

```bash
# 错：json_query 第二参数是「parsers.py 的函数名」，这里却传了 Python 表达式
json_query "$STATE_FILE" 'd.get("ax_count",0)'
#   → 查表失败 → 静默返回空 → 被读成 0 → 报「AX 树为空」
```

实际后果：落盘文件完整 10855 字节、`ax_count` 单独调用稳定返回 95，
但脚本读出来是 0。**排查了整整一轮坐标、AX 树、应用状态，根因只是一次查表失败。**
更糟的是它还制造了一个假象——「点歌名没反应」也被归到这个错误上，实际是解析失败被误读成元素不存在。

**正确写法：**

```python
if fn not in FUNCS:
    sys.stderr.write("未知解析器 %r；可用: %s\n" % (fn, ", ".join(sorted(FUNCS))))
    sys.exit(3)
try:
    d = json.loads(open(path, encoding="utf-8").read())
except FileNotFoundError:
    sys.stderr.write("文件不存在 %s\n" % path); sys.exit(4)
except Exception as e:
    sys.stderr.write("JSON 解析失败 %s (%s)\n" % (path, e)); sys.exit(5)
```

**原则：静默兜底会让「工具故障」被误读成「业务对象不存在」，把排查方向完全带偏。**

---

### ② 能用应用自己的排序解决，就不要在脚本里猜

**实例：** 用户要「美丽的神话」。脚本按歌手偏好去匹配，选中了
「美丽的神话 · **扎西尕尔**」（翻唱版），而不是「美丽的神话 · 孙楠、韩红」（原唱）。

问题在于：**歌手偏好无法从歌名文本推断出来。**

**改法：** 点「纯歌名」条目 → 进入完整结果页 → **让酷狗自己按热度排**，原唱自然排第一。

```
旧：解析联想词 → 按歌手名筛选 → 在候选里挑最匹配的   （猜，且猜错）
新：点纯歌名 → 进结果页 → 读第一行                （不猜，用应用的数据源）
```

**原则：脚本猜不准业务语义，应用的数据源不会错。**

配套：`song_result` 解析器加了 `_tier_of()` 分级 —— tier0 = 原唱无版本后缀，
tier1 = 带版本后缀，tier2 = 其他。当脚本确实必须自己挑时，至少要**显式分级**而不是无脑取第一个。

---

### ③ 动手之前先确认「能不能动手」

环境阻塞要在**入口拦截**，而不是让它伪装成业务错误。

**代价对比（真实实测）：**

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 锁屏跑 `music_play.sh` | 跑 14 秒，报「点击无效」 | **704ms**，报「屏幕已锁定，解锁后我就能继续」 |
| 锁屏跑 `open_file.sh` | —— | 1958ms **仍然成功** |

**注意第二条**：预检是**按需**的。`open_file.sh` 用 Launch Services，不需要模拟输入，
所以**不做**这个检查。这说明预检不该无脑套在所有脚本上，要按「这个动作是否需要输入通道」判断。

实现见 `scripts/common.sh` 的 `precheck_env` / `precheck_env_or_exit`，
底层是 `macctl doctor`（**实测移动光标**看位置是否真变 → 高层浮窗检测）。

**最贵的坑**：屏幕锁定时 macOS 会**静默丢弃所有 CGEvent 合成输入事件**。
点击不生效、粘贴不进字、`AXPress` 返回 success——**任何工具都不报错**。

**唯一可靠的判据：实测移动光标，看位置是否真变。**

| 候选信号 | 能否用作判据 | 原因 |
|---|---|---|
| **实测移动光标** | ✅ **唯一可靠** | 直接反映系统是否接受合成事件 |
| `CGSSessionScreenIsLocked` | ❌ | 实测返回 **nil**（不是 false，是拿不到）；`ioreg` 里也读不到 |
| `loginwindow` 进程存在 | ❌ | **常驻登录进程**，解锁后依然在跑（实测 pid 全程不变） |

> D-013 的代价：我曾用「`loginwindow` 存在」当判据，导致屏幕明明解锁却报「已锁定」，
> 所有输入类脚本全部拒绝执行。更隐蔽的是——因为先判 locked=true，
> 代码里的 `if !locked { 输入自检 }` 被跳过，**唯一的可靠证据被自己的误判屏蔽了**。

**防御原则：不要相信任何单一信号，要用实测交叉验证。**
更根本的是：**上游脚本要对工具结论保持怀疑，而不是无条件采信。**

---

### ④ 参数校验 → 环境预检 → 业务动作，顺序有语义

反过来会让「缺参数」这种一秒就能发现的错误，先等 1.5 秒预检才报出来。

```
✅ 参数校验（最便宜，毫秒级）
✅ 环境预检（~700ms-1.5s）
✅ 业务动作
```

`lint.sh` 会检查这个顺序，**别把预检挪到参数校验前面**。

---

## 二、bash 3.2 的坑（macOS 自带 bash，必踩）

### 1. 全角字符紧跟 `$VAR` 会被吞进变量名

```bash
echo "$TO」"          # 读的是名为 "TO」" 的变量 → 空
echo "${TO}」"        # ✅ 正确
```

中文文案里这个特别容易中招：`"$TO」发消息了"` 看起来完全正常。

`lint.sh` 的 **7'. bash 变量边界** 检查会扫这个。

### 2. `BASH_SOURCE[0]` 在 `set -u` 下报 parameter not set

```bash
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
#                ^^^^^^^^ 这个 :- 不能省
```

### 3. 空数组 `"${arr[@]}"` 展开报 unbound variable

```bash
args=()
"$MACCTL" doctor "${args[@]}" --json     # ❌ unbound variable（set -u 时）

if [ -n "$bid" ]; then
  "$MACCTL" doctor --app "$bid" --json
else
  "$MACCTL" doctor --json
fi                                          # ✅ 分支处理
```

### 4. `if ! func` 判的是退出码不是输出

以 `printf` 结尾的函数**永远 exit 0**，所以 `if ! app_count` 永远为假。

```bash
# ❌ 原来：永远进不了 then 分支
RUNNING="$(... | python3 -c 'sys.exit(0 if r else 1)')"
if ! app_running "$BUNDLE"; then ...; fi     # ✅ 用返回码

# ✅ 正确：让函数用 return code 表达真假
app_running() { ...; [ "$hit" = "1" ]; }
```

### 5. 命令替换 `$(...)` 捕获 stdout 而非退出码

```bash
RUNNING="$(... | sys.exit(0 if r else 1))"    # ❌ 拿到的是空串，退出码被吞
if ! app_running "$BUNDLE"; then ...          # ✅
```

---

## 三、Swift 编译易踩的坑

| 症状 | 原因 | 修正 |
|---|---|---|
| `consecutive statements on a line must be separated by ';'` | 括号多了一层 | 数一遍 |
| `initializer for conditional binding must have Optional type, not 'Process'` | `if let a = Process(), let b = Pipe()` | 分开赋值 |
| `argument type 'CGPoint' expected` / `value of type 'CGSize' has no member 'x'` | 类型推断跑偏 | 显式标注类型 |
| `cannot find 'AXRaise'` | 该 API 不可用 | 改用 `axPos(w)` + `AXUIElementSetAttributeValue(kAXPosition)` |
| `jarrRaw` not found | 自己没定义这个 helper | 用 `targets.map { jesc(...) }.joined(separator: ",")` |

**另一个坑**：`FileHandle(forWritingAtPath:)` 的句柄**默认定位在文件末尾**。
如果 `out()` 被调用多次，每次重开 → 内容叠加 → JSON 解析报 `Extra data: line 2 column 1`。

```swift
// ✅ 启动时截断 + 常驻句柄，退出时显式 close
var gOutHandle: FileHandle? = nil
func outFileOpen(_ path: String) {
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let h = FileHandle(forWritingAtPath: path) else { return }
    h.truncateFile(atOffset: 0)
    gOutHandle = h
}
```

---

## 四、性能：不要用 `sleep`，用条件等待

```bash
# ❌ 慢：无论界面多久更新，固定等 2 秒
sleep 2; M find --text "播放" --app <id>

# ✅ 快：条件一成立立即返回
M probe --app <id> --text "播放" --timeout 5
```

**实测差距（超时场景）**：shell 轮询 **13.4s** vs `probe` **5.5s** —— 快一个数量级。
`probe` 在 Swift 进程内完成「拿树 → 判定 → 等 → 再判定」，没有反复启动进程的开销。

### 常见的「超时了却等了很久」

| 症状 | 根因 | 修正 |
|---|---|---|
| `timeout 3` 实际跑 13s | 步进换算 `int(gap*10)` 把 0.25 截成 0.2，每轮少算 0.05s，累积后严重超时 | 用**毫秒整数累加**，只在开头调一次运行时 |
| 明明立即就绪却等满全程 | 判据在动作发生**之前就已成立** | 换用「目标元素真的出现」作判据 |

第二条的真实案例：`probe_role AXStaticText` 的判据在**搜索前就成立** → 立即返回，
但那不是我们要等的。改用 `song_name_hits ≥ 2`（区分「联想浮层」1 条与「结果页」7 条）才正确。

### python3 冷启动开销

沙箱下 macOS 的 `python3` 冷启动约 **240ms**，是 bash 脚本的主要瓶颈。

- 不要用 `printf | python3` 传大 JSON（而且文本模式的 universal-newlines 会让
  `sys.stdin.read()` 在含中文的 10KB JSON 上**提前结束读取**）
- 统一用 `mj_file`（写文件）+ `json_query`（解析器）
- 把 python 调用次数压到最少（循环里不要调）

---

## 五、AX 树的两个反直觉特性

### 1. macOS 会对**被完全遮挡**的窗口停止 AX 投递

不是权限问题，不是应用 bug。`macctl diagnose` 列出遮挡者，
`raise` / `winback` / `dock` 解决。

`winback` 的做法是把非主窗口**先移到屏幕外再移回**，强制它退到窗口序后面。

### 2. AX 坐标可能**溢出窗口边界**

酷狗播放条窗口从 x=370 开始，但歌名报在 **x=300** —— 向左溢出约 70pt。

所以判断「是不是播放条的歌名」要**锁定水平带 + 允许向左溢出 ~120pt**，
不能严格要求落在窗口矩形内。否则会读到主窗口里的无关文本（本项目实测读到 `Luxury - 한나`）。

### 3. 展开态首行高度异常

酷狗搜索结果页展开时，首行 h=145（比其他行高），下方是详情与标签按钮。

行内点击位置用**固定偏移 `rx + 160`**，**不要用 `rx + rw//4`** ——
后者算出来是 328，落到右侧按钮区，点击无效（而 AX 返回成功）。

---

## 六、自绘控件：识别与止损

**现象**：AX 树正常、`find --text "搜索"` 精准命中、点下去也有反应，
但 `type` 之后 value 恒空。

**决定性证据**：
```bash
M clear --app com.tencent.xinWeChat
# 输出：清空输入框 [quartz]
```

`[ax]` = AX 路径成功。**`[quartz]` = AX 路径失败、退化到 Quartz 合成事件
—— 说明没有任何输入控件持有焦点。**

**根因**：控件是应用自绘的（自己画 UI，只向 AX 暴露占位元素）。
AX 能看见它、点得动它，但无法给它输入焦点。

**已知实例**：微信 4.x macOS 版顶部搜索框。

**处置原则**：这是**应用侧限制**，脚本无法绕过。
① 如实报告能力受限（`NEED_HUMAN` + `blocked_by` + `manual_step`），**不要假装失败**；
② 提供人工兜底路径（用户手动打开会话 → 脚本跳过搜索直接操作）。

**不要在这个控件上继续尝试坐标或按键技巧** —— 会浪费大量轮次且不可能成功。