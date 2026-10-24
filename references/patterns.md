# 任务配方（Patterns）

每个配方给出**最短路径**。原则：能用 1 次调用解决的不用 2 次，能用 `state` 看清的不用多次试探。

`M=~/.workbuddy/skills/mac-control/scripts/macctl`

---

## 配方 A：给某个联系人发消息

```bash
# 1. 置前微信（防遮挡）
M dock --app "微信"

# 2. 定位搜索框 —— 微信顶部搜索框是 AXTextArea '搜索'
M find --text "搜索" --app com.tencent.xinWeChat --role AXTextArea

# 3. 点击搜索框 + 粘贴姓名（微信对 Unicode 注入不友好，用粘贴）
M click --at <搜索框坐标>
M type --text "郑好" --app com.tencent.xinWeChat

# 4. 搜索结果出现在独立浮窗，「最常使用」首位即精确匹配
M find --text "郑好" --app com.tencent.xinWeChat
M click --text "赣州 郑好" --app com.tencent.xinWeChat

# 5. 输入并发送
M click --at <聊天输入框坐标>
M type --text "消息内容" --app com.tencent.xinWeChat
M click --text "发送" --app com.tencent.xinWeChat

# 6. 验证
M find --text "消息内容" --app com.tencent.xinWeChat
```

**要点**：第 4 步的浮窗 AX 树里能找到结果项，是 `AXStaticText`；`macctl click` 对文本类元素自动点左侧文字区。

---

## 配方 B：搜索并播放一首歌

```bash
M dock --app "酷狗音乐"

# 打开搜索：点右上角搜索按钮
M find --text "综合" --app com.kugou.mac.Music      # 确认搜索页已打开
M click --text "综合" --app com.kugou.mac.Music

# 输入歌名 —— 酷狗必须用粘贴
M click --text "搜索" --app com.kugou.mac.Music --role AXTextField
M type --text "美丽的神话" --app com.kugou.mac.Music

# 回车在酷狗不触发搜索，点联想词第一条
M find --text "美丽的神话" --app com.kugou.mac.Music
M click --text "美丽的神话" --app com.kugou.mac.Music

# 结果页出来后点歌名（首行是原唱版）
M click --text "美丽的神话, 孙楠、韩红" --app com.kugou.mac.Music

# 验证播放条
M find --text "美丽的神话 - " --app com.kugou.mac.Music
```

---

## 配方 C：设置音量

```bash
# 系统音量（最简单）
M volume --set 70

# 应用内音量
M app-volume --app com.kugou.mac.Music --to 70
# 若 app 用自绘滑条：
M set-volume-bubble --app com.kugou.mac.Music --to 70
# 调试用：
M vol-probe --app com.kugou.mac.Music
```

---

## 配方 D：浏览器搜索（无需 agent-browser）

```bash
M dock --app "Google Chrome"
M find --text "搜索" --app com.google.Chrome
M click --at <地址栏坐标>
M type --text "广东金融学院" --app com.google.Chrome
M key --key return --app com.google.Chrome
M wait --text "广东金融学院" --timeout 5
M shot --out /tmp/result.png
```

**注意**：百度等站点的滑块验证码**无法也不应绕过**，需用户手动完成。

---

## 配方 E：填写表单并提交

```bash
M state --app <id> --depth 10     # 一次看清所有输入框
# 逐个：点击输入框 → 粘贴内容
M click --at <x,y>
M type --text "内容" --app <id>
# 提交
M click --text "提交" --app <id>
```

---

## 配方 F：跨应用找东西

```bash
M find --text "关键词" --app all --limit 20
```

用于「这个东西在哪」「刚才那个窗口叫什么」这类问题。

---

## 配方 G：把某个 app 的窗口移到指定位置

```bash
# 用 AX 设置窗口位置/尺寸（部分 app 支持）
M state --app <id>          # 先确认窗口当前 frame
```

若无内置命令，用 `M click --at` 拖动标题栏即可（macctl 内部有 `mouseDrag` 能力，可扩展）。

---

## 反模式（不要这样做）

| ❌ 不要 | ✅ 改用 |
|---|---|
| 现写一个 Swift 脚本做一次点击 | `M click --at x,y` |
| 反复 `state`/`tree` 试探元素在哪 | 一次 `M state --depth 8` 看全 |
| 用 `screencapture` 命令行截图 | `M shot`（已处理 TCC 与排他捕获） |
| 手写 AX 树遍历 | `M tree` / `M find` |
| 猜坐标然后试 | `M scan` 裁剪看清 → 换算坐标 |
| AX 树空就以为没权限 | `M diagnose` 先查遮挡 |
| 用 `sleep` 等界面加载 | `M wait --text <元素>` |
| 独立截图脚本 + 手动分析像素 | 直接读截图（你是多模态模型） |

## 配方 E：把复杂任务转交给 WorkBuddy（零人工）

```bash
F=~/.workbuddy/skills/mac-control/scripts/flash
$F --handoff "帮我整理下载文件夹并写一份归档清单"          # 不带技能
$F --handoff "把下载文件夹按类型归档" --skill mac-control  # 带技能
$F --handoff "只验证链路" --dry                           # 干跑：粘完不发送
```

返回值判读：

| 返回 | 含义 | 你该做什么 |
|---|---|---|
| `{"ok":true,"step":"SENT"}` | 已送达（原文已离开输入框） | 直接报「已转交 ✅」 |
| `{"ok":false,"step":"COMPOSER"}` | 找不到输入框 | WorkBuddy 界面改版了，报给用户 |
| `{"ok":false,"step":"PASTE"}` | 内容没进输入框 | 原文已在剪贴板，让用户 ⌘V |
| `{"ok":false,"step":"SEND"}` | 回车+按钮都没提交 | 同上 |
| `{"ok":false,"step":"COLD"}` | 40s 内没起来 | 检查开场动画 / WorkBuddy 能否启动 |

**四条实测出来的规矩**（改这个链路前必须知道）：

1. **Electron 的 AX 树默认是空的**：只设 `AXManualAccessibility` 不够，
   还要设 `AXEnhancedUserInterface`，否则只能读到窗口 + 三个红绿灯按钮。
2. **空输入框的 AXValue 不是空串**：欢迎页有演示文案。「已提交」只能判
   「原文已离开输入框」，判 `value.isEmpty` 会永远为假。
3. **提交走回车，不点「发送」按钮**：AXPress 该按钮会清掉草稿但不建任务
   （欢迎页要求先选工作空间）。回车没反应才点按钮。
4. **技能候选按位置收窄**：在整棵树里按文本找 `mac-control` 会撞上侧栏里
   同名的历史任务，一点就切走会话。候选必须在输入框正上方且左缘对齐。

调试：`WB_HANDOFF_DEBUG=1 $F --handoff "..." --dry` 会打印每步的
value / 候选坐标，并把 AX 树 dump 到 `/tmp/handoff_tree.txt`。

