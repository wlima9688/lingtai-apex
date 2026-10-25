# mac-control

高效操控 macOS 桌面应用的 AgentSkill。

## 解决什么问题

在 macOS 上操控 GUI 时，AI 往往陷入这个循环：

> 写一个 Swift 脚本 → 编译（3-8 秒）→ 运行 → 发现 AX 树里没有目标 → 再写一个 → ……

单个任务消耗 20-40 次工具调用，而其中 90% 是重复劳动：重写 AX 遍历、重写点击注入、重写截图、反复试探元素在哪。

本技能把这些固化成**一个预编译二进制 + 27 个子命令**，并规定了一套工作流纪律。

## 效率对比（实测）

| 场景 | 之前 | 之后 |
|---|---|---|
| 读界面状态 | 4-6 次探测往返 | **1 次** `state`（45 毫秒） |
| 找元素 | 反复 `tree` + 人工比对 | **1 次** `find --text` |
| 中文输入 | 试 unicode→失败→试粘贴 | **自动降级 + 记住**，第二次直接走最优路径 |
| 元素点不动 | 猜坐标试 | **自动 AXPress→真实点击降级** |
| AX 树突然空了 | 怀疑权限、瞎试 | **1 次** `diagnose` 定位遮挡者 |
| 编译开销 | 每个任务 3-8 秒 × N | **0**（预编译） |

端到端实测（Chrome 搜索）：**5 次调用**完成置前→定位→点击→输入→回车→验证。

## 安装

已安装在 `~/.workbuddy/skills/mac-control/`，无需额外操作。

```bash
M=~/.workbuddy/skills/mac-control/scripts/macctl
$M help
```

## 目录结构

```
mac-control/
├── SKILL.md                        # 主文档：铁律 + 工作流 + 命令速查
├── manifest.json
├── scripts/
│   ├── macctl                      # 预编译二进制（arm64 macOS 13+）
│   └── macctl.swift                # 源码
└── references/
    ├── troubleshooting.md           # 故障排查：现象→根因→处置
    ├── patterns.md                 # 任务配方：发消息/搜索播放/调音量/填表
    └── permissions.md              # TCC 权限配置与验证
```

## 重新编译

修改 `macctl.swift` 后：

```bash
cd ~/.workbuddy/skills/mac-control/scripts
/usr/bin/swiftc -O -o macctl macctl.swift
```

## 学习缓存

`macctl` 会把每个 app 的有效交互方式记入
`~/.workbuddy/skills/mac-control/cache/learned.json`：

```bash
$M recall                          # 查看已学到的交互模型
$M note --app <bundleId> --text "描述"   # 手工补充
```

## 权限

需要：辅助功能、屏幕录制、输入监控、自动化。详见 `references/permissions.md`。
