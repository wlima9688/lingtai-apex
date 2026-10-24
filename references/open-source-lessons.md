# 从七个开源项目吸收的工程做法

> 记录：哪些做法进了闪控，哪些明确不进，以及为什么。
> 来源：2026-10-21 用户导入的 7 个 GitHub 仓库评估。

## 一览与取舍

| 项目 | 本质 | 结论 | 吸收了什么 |
|---|---|---|---|
| **agent-browser** | CDP 自动化 CLI（Apache-2.0） | **不装 CLI，吸收方法论** | 四级降级阶梯、`@ref` 短引用思想 |
| **cua** | 商业云沙盒 + CLI |不装 | 沙盒隔离的思路（留接口） |
| **remotey** | 远程 Windows 操控 | 不装 | 远程操控的架构分层 |
| **ponytail** | 编码风格（少写代码，MIT） | **吸收其风格** | 见下 |
| **self-operating-computer** | 纯像素 GUI agent（MIT，需 API key） | 不装 | 屏幕坐标缩放的经典问题 |
| **Mano-P** | 4B GUI-VLA 模型（Apache-2.0） | 不装 | think-act-verify 推理循环 |
| **e2e** | 测试框架（Apache-2.0） | 不装 | record/replay 机制 |

**为什么大多数不装**：它们的 skill 依赖各自的 CLI（未安装则完全不可用）、
或依赖模型权重（Mano-P 需 M4+32GB）、或只覆盖别的平台（remotey 只控 Windows）。
装进WorkBuddy 只会变成一堆点不亮的灯。

**核心判断**：对闪控有价值的是**方法论**，不是**运行时**。
所以我们吸收思路、用 Swift 原生实现，零依赖、离线可用。

---

## ponytail 的编码风格（已全面采用）

它的核心主张：**「最好的代码是没写的代码」—— 用最少的新代码完整解决问题，
并且给忙人的回复一眼能读懂。** 具体落到闪控的做法：

| 主张 | 在闪控的体现 |
|---|---|
| 「List every place your change must reach」 | 改脚本后跑 `lint.sh` 校验路由表↔脚本双向一致 |
| 「End your reply with what you skipped」 | 每个脚本的 `evidence` 字段说清做了什么、跳过了什么 |
| 标注 `shortcut:` 注释，避免拖延变永久 | 每处妥协都写明**上限与升级路径**（见下方注释规范） |
| 不做没被要求的功能 | 表外意图走 `library/scaffold.sh` 现场生成，不预先铺一堆脚本 |

### 闪控的注释规范

所有非平凡的决策都要注释，且必须写明**为什么现在这样做**：

```bash
# ⚠ 不能用`trap -p EXIT`：zsh 不支持这个语法。
#   实测有人手动 source common.sh 到 zsh 里调函数 → 报错中断。
```

三条硬要求：
1. 注释解释**为什么**，不是**是什么**（`# 调 macctl` 是废话）
2. 写明**实测数据**（`450ms → 105ms` 而不是「优化了性能」）
3. 写明**上限**（什么时候这个做法会失效）

---

## agent-browser 的 `@ref` 短引用机制

**它的问题**：传统流程要把整个 DOM/AX 树塞进上下文让模型解析 → 3000-5000 token。
**它的解法**：给每个可交互元素分配一个短引用 `@e12`，上下文降到 200-400 token。

```
传统：Full DOM → AI 解析 → CSS selector → Action        (~3000-5000 tokens)
闪控：紧凑快照 → 分配短 ID → 直接交互                 (~200-400 tokens)
```

**它的引用生命周期规则**（这套规则值得学）：
- 同文档更新保留存活节点的引用
- 节点被替换 → 引用失效，**失效的 ID 在会话内永不复用**
- 节点被替换时回退到「同名同角色的唯一元素」；**若因此产生歧义，操作失败而不执行**
- 重新 `snapshot` 拿到新引用

⚠️「歧义时失败而不执行」这条尤其重要 —— 闪控的 `locate` 置信度下限是同一个思路：
**宁可不动作，也不要动错地方**。

**闪控的对应实现**：用 `locate` 的模糊匹配 + 置信度下限实现类似效果，
不引入 DOM/HTML 解析层（AX 树本来就不是 HTML）。

---

## e2e 的 record/replay 机制

> 「An agent step that a later assertion verifies records its actions, and the
> next run replays them with no model calls until the app changes.」

**思路**：agent 探索性操作一旦被断言验证通过，就录制成脚本；
下次运行时**先重放**，只有当应用行为变了才重新调用模型。
「测试里没有 agent 步骤就不需要模型。」

**为什么闪控需要**：闪控的 `library/` 动态脚本库就是这个思路的简化实现 ——
现场生成脚本 → 跑通 → 登记入库 → 下次直接命中（`lib_record` 记录成败，
失败时原地改进）。

**闪控的取舍**：e2e 有完整的断言语言，闪控没有（那是一整套测试框架）。
闪控只做「跑通即入库 + 记录成败」，不做断言 DSL。这是 ponytail 精神的体现：
**只做解决当前问题所需的最小的那部分。**

---

## Mano-P 的 think-act-verify 循环

Mano-CUA 的推理机制是「think → act → verify」，配合闭环数据回流。

**闪控的对应**：
- **think** → `locate` 的四级降级（不是试一次就放弃）
- **act** → `click` / `type`
- **verify** → 每个意图脚本末尾的 `verify_result` / `has_text`（没有验证就不算成功）

**已落地**：D-017 就是这个循环的直接产物 —— 撞墙（AX 失败）→ 换路（OCR）→ 验证（读到'测试'）→ 改代码。

---

## self-operating-computer 的坐标缩放问题

2023 年的纯像素方案，需要 OpenAI/Gemini API key，纯截图定位。

**它解决的老问题**（闪控也踩过）：截图分辨率与屏幕逻辑坐标不一致时，
点击位置会偏移。闪控的 `captureAppWindow` 用 `scale = img.width / org.width` 换算。

**不采用其主路线**：纯像素定位比 AX 慢且脆得多。
闪控把 OCR 定位放在**降级链的第二级**而不是主路径 —— 视觉是兜底，不是主力。

---

## remotey / cua 的架构分层

两者都是「agent 大脑 ↔ 执行端」的分离架构：

**remotey**：agent 在Mac/Linux，通过 Tailscale 隧道 + HTTP/JSON 驱动远程 Windows。
**cua**：`cua do switch <target>` 切换到不同执行端（沙盒/relay/本地主机）。

**吸收的点**：闪控的**意图层 / 控制层**分离已经是同一思路
（`SKILL.md` 路由表 = 大脑，`macctl` = 执行端）。

**未来的接口预留**（暂不实现）：
```
macctl doctor --remote <host>   → 接远程执行端
library/ --target sandbox        → 接云沙盒
```
用户没有第二块显示器、也不需要远程，所以现在不做 —— 但架构上是通的。

---

## 没吸收的（以及为什么）

| 做法 | 为什么不要 |
|---|---|
| CDP 穿透所有 Electron 应用 | 微信实测拒绝（D-015）。对不支持的应用，自动尝试只是白等几秒 |
| 云沙盒 | 用户没有第二块显示器；且云沙盒装不了本机 App |
| 像素截图喂模型让模型自己找坐标 | 慢、贵、不准。定位应该由工具做，不是由模型看图猜 |
| 完整断言 DSL（e2e 风格） | 成本高，闪控只需要「跑通即入库」 |
| Mano-P 的模型推理 | 要 M4+32GB 跑 4B 模型，阶段一还没开源 skill |