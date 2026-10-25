# 升级指南

闪控（mac-reflex）跑在 `~/.workbuddy/skills/` 下，**每次打开 WorkBuddy 都会被自动发现并启用**，
不需要手动安装或加载。本文件说明如何安全地改它。

---

## 改之前：三条红线

**① 任何测试都不能让电脑发出声音。**
所有脚本已内置静音守卫，但**你新写的测试命令也要自己保证静音**。
不确定的时候先加 `--keep-muted` 或显式 mute。

**② 不要用 `rm` 改技能目录。**
`~/.workbuddy/skills/` 不是临时缓存。改坏了用 `CHANGELOG.md` 里的版本回滚。

**③ 不要在测试时手动点屏幕。**
会和你脚本里的动作打架，产生难以复现的竞态。要手动验证就用 `--only <case>` 单独跑。

---

## 标准改动流程

```
改代码 → selftest.sh → lint.sh → 手动冒烟 → 更新 CHANGELOG.md → 提版本号
```

### 1. 改之前先查 DIAGNOSIS.md

`DIAGNOSIS.md` 记录了 12 条实测踩坑（现象 → 定位过程 → 结论 → 处理方式）。
**你要改的每个脚本，里面大概率已经有对应条目。** 改之前先看，能省掉整轮返工。

### 2. 跑自检（静音，自动）

```bash
~/.workbuddy/skills/mac-reflex/scripts/selftest.sh
```

36 项，全过才会输出 `✅ 全部通过`。**不要跳过这一步直接上线。**

### 3. 跑一致性检查

```bash
~/.workbuddy/skills/mac-reflex/scripts/lint.sh
```

它会检查：路由表 ↔ scripts 双向一致、JSON 输出契约完整性、审计日志、
参数校验顺序、**bash 变量边界**（全角字符紧跟 `$VAR`）、**禁止管道传大 JSON**。

> 新增脚本后忘记在 `SKILL.md` 路由表加行 → lint 会报错。这是故意的。

### 4. 性能验收（可选，但改动涉及等待逻辑时必跑）

```bash
~/.workbuddy/skills/mac-reflex/scripts/bench.sh --runs 20
```

**必须在解锁状态下跑。** 锁屏时所有需要模拟输入的脚本都会在预检阶段快速失败，
数据没有意义。输出 `logs/bench-YYYY-MM-DD.json`。

预算：**L0 p50 ≤ 1.5s / p95 ≤ 3s / 成功率 ≥ 95%**。

### 5. 更新文档

- 改了什么行为 → `CHANGELOG.md` 加条目（写**为什么改**，不写改了什么）
- 加了新命令 → 同步 `mac-control/SKILL.md` 的命令速查表
- 踩了新坑 → `DIAGNOSIS.md` 加一条 D-0XX

### 6. 提版本号

`manifest.json` 的 `version` 字段。约定见 `CHANGELOG.md` 末尾。

---

## 加一个新意图（最常见的改动）

以「打开终端」为例：

**① 写脚本** `scripts/open_terminal.sh`

必须遵守的模板：
```bash
#!/bin/bash
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
. "$SELF_DIR/common.sh"          # 公共库：JSON、日志、等待、预检

# 1) 参数校验（最先，最便宜）
# 2) 环境预检（仅当需要模拟输入）
#    precheck_env_or_exit "open_terminal" "" "$BUNDLE"
# 3) 业务动作
# 4) 自验证 + emit_result + audit_exit
```

**② 在 `SKILL.md` 路由表加一行**（lint 会强制你加）

**③ 在 `manifest.json` 的 `scripts` 里登记**

**④ 在 `selftest.sh` 加自检项**

**⑤ 跑 lint + selftest**

> 别复用旧脚本里的取巧写法。`printf | python3` 传大 JSON 在 bash 3.2 下会因
> universal-newlines 截断而提前结束读取——统一用 `mj_file` + `json_query` + `parsers.py`。

---

## 改 `macctl`（控制层）

源码：`~/.workbuddy/skills/mac-control/scripts/macctl.swift`

```bash
cd ~/.workbuddy/skills/mac-control/scripts
/usr/bin/swiftc -O -o macctl macctl.swift
```

改完必须：
1. 在 `mac-control/SKILL.md` 命令速查表登记新命令
2. 在 `mac-control/references/troubleshooting.md` 记可能引入的新故障模式
3. 重新跑闪控的 `selftest.sh`（闪控依赖 macctl，改底层会影响上层）

### Swift 编译易踩的坑

| 症状 | 原因 |
|---|---|
| `consecutive statements on a line must be separated by ';'` | 括号多了一层 |
| `initializer for conditional binding must have Optional type, not 'Process'` | `if let x = Process(), let y = Pipe()` → 分开赋值 |
| `cannot find 'AXRaise'` | 该 API 不可用，改用 `AXUIElementSetAttributeValue(kAXPosition)` |

---

## 回滚

技能目录是纯文件，没有数据库、没有云端状态。回滚就是覆盖文件：

```bash
# 备份（改之前先做）
cp -r ~/.workbuddy/skills/mac-reflex /tmp/mac-reflex-backup-$(date +%Y%m%d)

# 回滚配置文件
cp ~/.workbuddy/skills/mac-reflex/preferences.md{,.bak}
cp ~/.workbuddy/skills/mac-reflex/proposals.jsonl{,.bak}
```

脚本本身建议用 git 管：

```bash
cd ~/.workbuddy/skills/mac-reflex && git init && git add -A && git commit -m "v1.1.0"
```

---

## 排错入口

| 现象 | 先看 |
|---|---|
| 脚本报某个 `error_code` | `logs/YYYY-MM-DD.jsonl` 审计日志 |
| 界面行为和预期不符 | `DIAGNOSIS.md` |
| AX 树为 0 节点 | `macctl diagnose --app <bundleId>` |
| 点击不生效、但工具报成功 | **`macctl doctor`** —— 大概率是屏幕锁了 |
| 脚本卡住不动 | 加 `REFLEX_LOG_DIR=/tmp bash -x <script>` 跟执行 |
| `parsers.py` 报错退出码 3 | 传了不存在的解析器名，stderr 会列出可用的 |
| 需要看每个 JSON 字段怎么算的 | `scripts/parsers.py` 里搜对应函数名 |

---

## 版本兼容

- **bash**：macOS 自带 3.2，**不要用 bash 4+ 语法**（关联数组、`${var,,}` 等）。
- **Swift**：系统自带 `swiftc`，target 用默认值，不要设太高的部署版本。
- **Python**：只用标准库（`json` / `re` / `os`），**不要依赖 pip 包**。
- **macOS**：13+。