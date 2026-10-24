# 定位阶梯：从 AX 到视觉的四级降级

> 核心命题：**撞墙时不是放弃，而是换一条路。**
> 这条原则来自一次真实的误判——我们曾把「微信搜索做不到」写进代码，
> 实际上只是「AX 这一条路做不到」。见 `DIAGNOSIS.md` D-017。

## 为什么需要阶梯

单一手段必然有盲区：

| 手段 | 强在哪 | 盲区 |
|---|---|---|
| AX 树 | 快（~60ms）、精确、不依赖视觉 | **自绘控件**拿不到焦点、AX 只暴露占位元素 |
| OCR 视觉 | 什么界面都能认 | 慢（~620ms）、分辨率不够就认错、需要看得见 |
| CDP | 能穿透到Electron 应用内部 DOM | **应用侧可能主动关闭**（微信实测拒绝） |
| 坐标 | 永远可用 | 最脆弱，界面一动就失效 |

**降级不是「失败兜底」，而是主路径的一部分。** 找不到就往下走，全部走完才报，
而且必须说清每一级为什么失败 —— 笼统报「没找到」会让排查从零开始。

## 用法

```bash
# 自动降级（推荐）：AX → OCR
$ macctl locate --text "搜索" --app com.tencent.xinWeChat
'搜索' @(878,64) via=ax conf=1.00 61ms

# 强制某一级（调试用）
$ macctl locate --text "搜索" --app <id> --only ocr
'搜索' @(841,64) via=ocr conf=1.00 621ms

# JSON 输出（脚本里必须用 --out 落盘，不要走管道）
$ macctl locate --text "X" --app <id> --json --out /tmp/r.json
[{"ok":true,"x":313.75,"y":461.5,"level":"ax","confidence":0.54,...}]

# 置信度下限（默认 0.30，按需调）
$ macctl locate --text "X" --app <id> --min-conf 0.5
```

找不到时报**逐级原因**，这是排查的起点：
```
未找到「绝对不存在zzz」——已尝试：
  · L1 ax: 树里有节点，但没有元素匹配「绝对不存在zzz」
  · L2 ocr: com.tencent.xinWeChat 识别到 37 个文本块，但没有匹配「绝对不存在zzz」
```

## 实现坑（三条都踩过）

### 1. `findNodes` 的 score 是整数百分制，不是 0-1

```swift
if n.title == text { score += 100 }        // 全等
else if n.title.contains(text) { score += 60 }
score += area > 0 ? max(0, 20 - Int(area/5000)) : 0   // 面积偏好，最多 20
```
上限约 **120**。不归一化会输出 `conf=120.00`，而且没法和 OCR 的 0-1 分数比较排序。
归一化：`min(1.0, Double(score) / 120.0)`

### 2. OCR 模糊匹配必须有置信度下限

字符集重合度对**任何**文本几乎总能算出一个非零分：
```
「这个文字绝对不存在xyz」 → 匹配到「文件传输助手」conf=0.04
```
不设下限就会**误点一个完全无关的元素**。这个方向的错误比「报找不到」危险得多 ——
后者只是任务失败，前者可能在错误的位置执行了操作。

配套守卫：长度差异过大直接判0（目标 15 字 / 候选 6 字，偶然重合是必然的）。

### 3. AX 节点的 text 常含换行

列表项会把整条消息塞进 `text`，直接输出刷满终端。取第一行 + 限长 60 字符。

## 各级的实现要点

### L1 · AX（主力）
- 完全遮挡 → AX 树0 节点 → 先 `raise` / `dock`
- 自绘控件 → 树里只有占位元素 → 自然降级到 L2

### L2 · OCR（自绘控件的唯一出路）
- 截屏用 `ScreenCaptureKit`（`CGWindowListCreateImage` 在 macOS 15+ 已 unavailable）
- Vision 返回**归一化坐标 + 左下原点**，屏幕是**像素 + 左上原点**，两处都要翻：
  ```swift
  px = bb.origin.x * dispW
  py = (1.0 - bb.origin.y - bb.height) * dispH
  ```
- **分辨率不能砍**。砍到 50% 时中文识别崩坏（`幼理OETA` / `淡料浑`）
- 用 `--app` 排他窗口捕获时**不需要屏幕录制授权**，只要辅助功能权限

### L3 · CDP（谨慎启用）
仅对**确认支持**的应用。开启方式：应用重启时带 `--remote-debugging-port`。

⚠️ **微信已验证不支持**（D-015）：它是 CEF 架构（子进程 `--type=gpu-process`、
`--seatbelt-client` 等特征齐全），但主进程主动过滤了调试端口参数。
不要在微信上浪费试各种 flag 变体。

### L4 · 坐标（最后手段）
前三级全失败才用。必须配合截图确认，且每次用前重新校准。

## 与其他库的关系

本阶梯替代了 `agent-browser` 的角色：
- agent-browser 提供 CDP 通道 → 对应我们的 L3（但只对支持的 Electron 应用）
- agent-browser 的 `@eN` 短引用机制 → 我们用 AX 路径 + locate 的模糊匹配达到类似效果

**没有安装任何外部 CLI** —— 全部用Swift 原生实现，零依赖、零冲突、离线可用。

## 编写脚本时的用法

```bash
# 1. 先查静态路由表
# 2. 命中就调意图脚本（如 music_play.sh）
# 3. 表外意图 → library/scaffold.sh 生成脚本，定位一律用 locate
# 4. locate 返回 NOT_FOUND 时，把 tried 里的原因带进 evidence
```

**不要**自己调`macctl find`，它只有 L1。**统一用 `locate`** 才有降级。