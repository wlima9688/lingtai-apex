# 闪控 修复台账（Bugfix Ledger）

> 目的：**把每次踩坑变成下次的捷径**。修 bug 前先查这张表，
> 命中同类症状就直接跳到「修法」，不用再从现象重新推。
>
> 每条固定五段：症状 / 根因 / 修法 / 验证 / 可复用教训。
> 新条目追加在**最上面**（最新的在最前）。

---

## B-021 · 自检自我递归（自检里起自检，越套越深，30 分钟不结束）

- **日期**：2026-10-25（P15b 打回）
- **优先级**：P0（自检本身变成"会把机器拖住 30 分钟"的东西，比不跑还糟）
- **症状**
  - 现场进程树：`bash ./selftest.sh`(64958) → `bash ./selftest.sh`(74462)，
    同时刻 3~5 份在跑，**全部 cpu≈0%**（不是在算，是在等），30 分钟不结束，
    监工 1800s 判据始终不成立（`TIMEOUT`），最后手动 `pkill -f "selftest\.sh"` 止血。
  - 复现环境还有第二个来源：**多个会话/多个父壳各自起一份自检**，锁被
    stale 接管逻辑放行 → 同样表现为"多份在跑、都不动"。
- **根因（锁的判据选错了维度，共三处）**
  1. **`kill -0 <持锁人>` 只能回答"那个 pid 还活着吗"，回答不了"这个 pid 是不是
     我自己这条链上的"**。而子自检恰恰是持锁人的**后代** → 锁一路放行，每层再起一层。
  2. **stale 接管与"写 pid"之间有微秒级空隙**：B 读到空 pid → 判僵尸 → `mv` 接管
     → 两份同时跑。这就是"3~5 份"的第二个来源。
  3. **`kill -0` 为真不等于还是自检**：自检被 `kill -9` 后变僵尸、或 pid 被系统
     复用，锁会**永久哑火**（每次都"⏳ 已有一份在跑"却什么也没在跑）。
- **修法**（`selftest.sh`）
  1. **① 断路器**：`SELFTEST_DEPTH` 环境变量，进入时 `incoming+1 ≥ 2` 立即
     `exit 0`（顶层 0→1 跑、子层 1→2 必拒）。这是唯一**不依赖锁状态**的防线：
     锁坏了 / pid 复用 / 接管失手，它都还拦得住。
  2. **② 祖先识别**：抢锁失败先判 `_lock_verdict` = `ANCESTOR | ALIVE | DEAD`。
     `ANCESTOR`（含自身与**直系父 `$PPID`**）→ 打印"嵌套调用"直接退；
     `ALIVE` 且 `_looks_like_selftest` 为假（僵尸/pid 复用）→ 按僵尸锁接管。
  3. **读 pid 加 8×100ms 重试**：读空不再立即判僵尸，堵住 2 的竞态。
  4. **③ 防套娃回归断言（第 25 节，快速档也跑）**：`mark()` 每 5 个小节采一次
     "实例数"，`max > 1` 立刻报红并列出每个实例的 pid/ppid/命令行。
     实例数的**唯一事实源是登记簿** `/tmp/lingtai-selftest.inst/<pid>`，
     不用 `pgrep -f selftest\.sh | wc -l` —— 后者会把"命令行里提到 selftest.sh 的
     父壳"算成一份（实测 `zsh -c '... ./selftest.sh ...'` 下 pgrep 数=2、真跑的=1），
     沙箱里 `ps` 还被禁，连祖先都排除不掉。
  5. **验收测试不再 fork 整份脚本**：锁的全部判据（`_lock_verdict` / `_depth_next` /
     `mkdir` 原子性 / 登记簿）都用纯函数 + 独立临时目录单测；唯一真起进程的那条
     （25.9）是**验证断路器本身**：子层带 `SELFTEST_DEPTH=1 --no-lock-test` 启动，
     必须在抢锁之前就退出（实测 85ms，且不动锁）。
- **验证**
  ```
  ./selftest.sh --keep-muted & sleep 5; pgrep -fc "selftest\.sh"; wait   # → 1
  ./selftest.sh --keep-muted | tail -6                                   # 通过 197/失败 0/跳过 10（快速档）
  ./selftest.sh --keep-muted & sleep 2; ./selftest.sh --keep-muted       # 子层：⏳…本次退出，<1s
  ```
- **可复用教训**
  1. **判"是谁"不能只判"在不在"**。进程锁、文件锁、幂等 token 全都一样：
     持锁人身份（是不是我这条链的）与持锁人存活是两个维度，少一个就是一个炸弹。
  2. **别用"命令行里出现的字符串"当身份证据**。`pgrep -f` 会把父壳、监控脚本、
     grep 自己一起算进去 —— 要么用登记簿这种**只有当事人会写**的事实源，
     要么用内核给的 pid/ppid 关系。
  3. **断言自己也要防递归**：给"验证并发锁"的测试套一把锁，若它本身 fork 一份
     被测脚本，测试就变成了递归函数。**测函数，别测进程**；非要测进程，
     必须带深度断路器和 `--no-<该测试>` 开关。
  4. 环境降级要**显式**：`ps` 在沙箱里被禁时，祖先判定不能"查不到 ⇒ 不是祖先",
     否则防线在最需要它的时候静默失效。

---

## B-020 · 自检一次跑 25 分钟：默认档在做视觉项 + 没有并发锁 + 慢在哪没人知道

- **日期**：2026-10-25（P15）
- **优先级**：P1（每天要用，25 分钟等于"没人愿意跑"；用户原话「耗时耗精力」）
- **症状**
  - 一次自检 25 分钟；"正常"情况也要 1.5~2 分钟。
  - 偶尔三个自检同时在跑（互抢 splash 窗口 → 视觉断言全红 → 各自重试 → 时间雪球）。
- **根因（四层，逐层实测出来的）**
  1. **默认档就在放动画**：`wblaunch play --force` + `sleep 15` + 整屏截图；
     `star_round()` 一轮 25s，P13 又加了"最多 3 次"重试 → 单条最坏 75s。
  2. **没有并发锁**：两个实例同时抢 `.screenSaver` 全屏窗口，谁都不显示 →
     截图拍到背后的 WorkBuddy → 判据必红 → 重试 → 时间翻倍。
  3. **没人知道慢在哪**：只有总时长，没有分段数据，优化全靠猜。
  4. **`--layout-check` 18s**：它为了验几何，把 14 个格子挨个
     `macctl launch --resolve-only --json` 解析图标 —— `sample` 采样 874 帧里
     869 帧卡在"读子进程输出"。纯算式校验却等了 14 个 App 图标。
  5. **`common.sh` 每次 source 都 fork python**：`T0=$(python3 -c 'import time...')`
     ≈240ms，**每个脚本**都付一次（route.sh 单次 1.06s 里占 0.24s）。
- **修法**
  1. `selftest.sh` 分档：默认快速档，`--full` 全量。视觉/动画/编译反证共 10 项用
     `if [ "$FULL" != "1" ]; then skip_fast "<项名>"; else ... fi` 包起来，
     `skip_fast` 打印 `⊘ 跳过（快速档）：…` 并计数。**代码一行没删**。
  2. 并发锁：`mkdir /tmp/lingtai-selftest.lock` + 写 pid；被占则
     `⏳ 已有一份自检在跑（pid N），本次退出` + `exit 0`。僵尸锁用 `mv` 原子接管
     （`rm -rf` 后 mkdir 会让两个进程都以为抢到，实测撞到过三个并发），
     抢到后回读 pid 复核；`trap` 里按 pid 释放。
  3. 分段计时：`mark "<小节名>"` + 结尾 `⏱ 总耗时/最慢 5 项`；
     `LINGTAI_SELFTEST_TIMING=all` 打全部小节。
  4. `flash.swift`：`ICONS_DISABLED`（`--layout-check`/`--selftest-raise`/
     `--selftest-handoff` 置位）+ `resolveBundleID` 进程内缓存 → 2.4s → 0.1s。
  5. `common.sh`：毫秒时钟改用 `/usr/bin/perl -MTime::HiRes`（macOS 自带），
     source 450ms → 160ms。
  6. 只读路由解析并发预热：`rd_prefetch` / `rd`（`route.sh --dry-run` 只解析、无副作用），
     十几条断言 15~20s → 2~3s。**会真执行动作的 route 调用仍串行**。
- **验证**
  ```
  快速档：real 86s · 通过 184 项 / 失败 0 项 / 跳过 10 项
  全量档：real 278s · 通过 196 项 / 失败 0 项 / 跳过 0 项
  锁：./selftest.sh --keep-muted & ./selftest.sh --keep-muted
      → 第二份 "⏳ 已有一份自检在跑（pid N），本次退出"，退出码 0
  layout-check：0.24s → 0.10s（LAYOUT_OK 800x606 · 3x5 网格 · 14 个按钮全部在框内）
  lint.sh → ✅ lint 通过
  ```
- **可复用教训**
  1. **"慢"要拆成"等待"和"工作量"**：sleep/截图是等待（可分档跳过），
     fork 进程是工作量（要减次数）。混在一起谈"优化"必然优化错地方 ——
     这次真正的大头是 `--layout-check` 为验几何去解析 14 个 App 图标。
  2. **先量再改**：`sample` 一秒就指认了 869/874 帧卡在子进程读取；
     没有这一步，会去改 Swift 布局代码。
  3. **分档跳过必须显式打印**：静默跳过等于断言消失，下次谁都不知道它没跑。
  4. **锁的接管也要原子**：`rm -rf` + `mkdir` 不是原子的，两个进程可能都以为抢到了。

---

## B-019 · 自检把假待确认项写进生产队列，菜单栏亮起 ⚠️1（用户以为程序坏了）

- **日期**：2026-10-25（P14）
- **优先级**：P1（假待确认项**能被点**，一点就真发消息；且用户第一眼以为软件坏了）
- **症状**
  - 桌面菜单栏图标从 `⚡️` 变成 `⚠️1`，点开是一项假待确认：
    `{"title":"给张三 发微信","detail":"你好","risk":"对外发送（不可撤销）"}`
  - `queue/pending/` 里出现过 `st_args_78957.json` / `st_args_81896.json`（`title=T`），
    `queue/answered/` 里堆了 **211 个**全是自检产物（210 个 `st_*` + 1 个
    `wx_*.test-artifact.json`），从 10-22 至今没有一个真实用户确认。
- **根因（两层）**
  1. `flashkit.swift` 的 `queueDir()` **硬编码** `~/.workbuddy/skills/mac-control/queue`，
     没有任何出口 —— 自检 fork 出来的 `flash queue add` / `--selftest-confirm`
     只能往生产队列写，**测试与生产共用一条队列**。
  2. 自检只在 13.6 那条用 `rm -f` 手工擦自己写的文件，13.5
     （`flash --selftest-confirm`）**从不清理**，`answer()` 把 pending 转成
     answered 后永久留下；一旦某次自检中途挂掉，pending 里的假条目就留在那儿亮 ⚠️。
- **修法**
  1. `flashkit.swift`：`queueDir()` 认 `LINGTAI_QUEUE_DIR` 环境变量（非空即覆盖），
     没设才回落到生产路径。
  2. `selftest.sh`：`source common.sh` **之前** `export LINGTAI_QUEUE_DIR="$(mktemp -d /tmp/lt-selftest-queue.XXXXXX)/queue"`
     + `mkdir pending answered`；清理串进**已有的** `trap '_finish; _cleanup_selftest_queue' EXIT`
     （不能另起一条 `trap ... EXIT`，那会把恢复静音的 `_finish` 顶掉，电脑一直哑着）。
  3. 新增第 24 节「队列隔离回归」三条断言：24.1 队列确实指到 `/tmp/lt-selftest-queue.*`、
     24.2 生产 pending 文件数与开跑前快照一致、24.3 生产 pending 里没有含
     「张三/你好/测试」的条目。13.9 改为显式盯**生产**路径。
  4. 顺手修：自检里 lint 失败只报 `tail -3`，真正的失败项被截掉 —— 改成抓 `❌` 行。
- **验证**
  ```
  红：生产 pending 里留 2 个 st_args_*.json →
      13.9 ✗ 确认队列有残留文件：st_args_78957.json st_args_81896.json
      24.3 ✗ 生产队列混进自检假数据：st_args_78957.json st_args_81896.json
  绿：清掉后 → 通过 196 项，失败 0 项；pending=0；/tmp/lt-selftest-queue.* 已被 trap 删净
  覆盖生效：LINGTAI_QUEUE_DIR=/tmp/p14-probe/queue flash queue stat → 目录: /tmp/p14-probe/queue
  ```
- **可复用教训**
  1. **测试写的东西必须写到测试自己的地盘**。"改完记得清理"是靠不住的约定 ——
     清理代码本身会失败、会被 kill、会被后加的分支绕过；**换目录**才是结构上的隔离。
  2. **测试产物的第一个用户就是用户本人**。假待确认项不只是脏数据，它是一个
     可点击的「确认」按钮，点下去真的发微信 —— 测试污染在这里等于**外部副作用**。
  3. 断言要盯**生产目录**：13.9 原本就查 pending 是否为空，但队列被污染时它只是
     "红了"；没有和"自检是否隔离"这件事对上，所以红了也没人去改架构。

---

## B-018 · 录屏永远修不好：`tccutil reset` 之前没人先问"是不是已经好了"

- **日期**：2026-10-25（P13）
- **优先级**：P1（录屏是主路径；修一次要人肉跑五步，还容易被自己搞坏）
- **症状**：录屏报「无法启动录屏」/ 0 字节 / 只出一张静态图；`screencapture -v`
  报 capture error「这项操作无法完成」。截图完全正常（截图免授权，两码事）。
- **根因（三层）**
  1. `screencapture -v` 从 **launchd** 拉起时没有「屏幕录制」授权 → 被拒。
  2. 授权只能由**面板自己的身份**去申请；从终端直接跑会继承终端的 TCC 身份，
     等于给终端申请，面板依旧没授权（和辅助功能那个坑一模一样，见 flashctl `ax)`）。
  3. 修法是 `tccutil reset ScreenCapture` 起手 —— **这一步会清掉已有授权**。
     没有前置判断就执行，等于"每次想修都先把好的弄坏"。
- **修法**
  1. `flash.swift` 启动路径加**受环境变量保护**的一次性申请：
     `LINGTAI_REC_PROMPT=1` 且 `!CGPreflightScreenCaptureAccess()` 时才
     `CGRequestScreenCaptureAccess()`。**变量不存在时一行都不执行**（ERR-0023：
     自动弹窗被投诉过）。同时把 `rec=` 写进 `/tmp/flash.hotkey`（面板身份看到的真相）。
  2. `flashctl.sh` 新增 `rec` 子命令（结构照 `ax)`）：先读 `rec=1` 守卫 →
     reset → PlistBuddy 临时注入 `LINGTAI_REC_PROMPT=1` → bootout/bootstrap/kickstart
     → 人勾一次 → 撤变量重启 → **真录 2 秒验证文件 >10KB**。
  3. `macctl screencap`：打印 `CGPreflightScreenCaptureAccess()` 的 1/0，供脚本判断。
  4. 桌面放 `修复屏幕录制授权.command`（chmod +x、去 quarantine），一键入口。
- **验证**
  ```
  flashctl.sh rec            # 面板 rec=1 时：直接退出，什么都不做
  screen_rec.sh --start --seconds 2   # 落盘 >10KB
  ```
- **可复用教训**：**"修复"类脚本必须先判断"是不是已经好了"**。凡是第一步是
  `reset` / `clear` / 删除的操作，守卫不是可选项 —— 它是这个脚本能不能给用户跑的
  前提。另外：**授权状态必须按"真正要用的那个身份"读**，终端读到的 1 不代表面板是 1。

---

## B-017 · 「旋转环没动」偶发红：断言没有重试，把环境慢判成了功能坏

- **日期**：2026-10-25（P13）
- **优先级**：P1（自检假红 → 真的坏了也没人信）
- **症状**：`selftest` 里「旋转环没动或动静不对：帧差=… 环带=…」十跑三四红，
  同一份代码复跑就绿；同期「五角星尺寸」那条（P11 已加 3 次重试）是绿的。
- **根因**：与尺寸那条同源 —— **测量时序**，不是功能。机器负载高（正在编译/刚开机）时
  `screencapture` 偏到洗白过场，两帧几乎一样，帧差与环带一起塌。
  尺寸那条有 `star_round()` 重试，环带这条**没有**，于是同一轮坏截图只判一次。
- **修法**：`selftest.sh` 加 `star_band_ok()` + 最多 3 次重试（照 `star_round()`
  的节奏，不另发明时序），任一次达标即通过；失败信息带上**三次**的「帧差/环带」。
  阈值 `>1000 / >800` **一个字没改**。另加 `STAR_BAND_PASS` 结论位：
  删不删现场截图看结论，不看"最后一次"的数值（最后那次可能是尺寸的重试轮）。
- **验证**：`selftest.sh --keep-muted` 连跑两次，两次「失败 0 项」。
- **可复用教训**：**放宽的是"测量的机会"，不是标准**。重试必须同时做到三件事：
  ① 阈值不动；② 失败信息带上**每一次**的实测值；③ 结论用显式结论位记录，
  不要靠"最后一个变量"推断 —— 变量会被后续步骤覆盖。

---

## B-016 · 任务文本被打进了用户的微信输入框（合成事件前不校验前台）

- **日期**：2026-10-25（P13，ERR-0024）
- **优先级**：P0（动到了用户的真实会话，差一个回车就是"替他发了条消息"）
- **症状**：转交/打字任务时，字没进目标 App，出现在**用户微信的输入框**里。
- **根因**：`macctl type` / `key` / `tap-text` 发合成事件前**不校验前台**。
  `type` 在没给 `--app` 时干脆把"当前前台"当目标 —— 前台是谁，字就进谁；
  `key` / `tap-text` 连这个概念都没有。CGEvent 没有"收件人"，它只认当前焦点。
- **修法**（`macctl.swift`）
  1. 新增 `requireFront(_:)`：`frontApp()?.bundleIdentifier == bid` 不成立就打印
     `❌ 拒绝发送：目标不是前台（当前前台 X / 目标 Y）` 并返回 false。
  2. 新增 `frontGate(_:appArg:cmd:)` 统一解析三档参数：
     `--force-front` > `--require-front <bid>` > `--app <bid|名称>`；
     **一个都不给 → 拒绝**（默认安全，绝不"没给就跳过"）。
  3. `cmdType` / `cmdKey` / `cmdTapText` 在**发第一个事件之前**调用它，不通过 `exit(4)`。
  4. 所有调用点补参数：`flash.swift`（面板粘贴/回车）、`flash_handoff.swift`、
     `wechat_send.sh`、`music_play.sh`。
- **验证**
  ```
  macctl type --text TEST --app com.tencent.xinWeChat   # 微信不在前台 → exit 4 + 拒绝发送
  macctl type --text TEST                              # 不给目标 → exit 4
  macctl type --text TEST --app <前台App>               # → ✓ 成功
  flash --handoff "测试" --dry                          # → ok:true step=DRY
  ```
- **可复用教训**：**合成输入的"收件人"是前台，不是参数**。凡是要"发出去"的能力
  （键盘/鼠标/粘贴），都必须在发之前用**系统认定的事实**（frontmostApplication）
  对一次目标；默认值只能是"拒绝"，绝不能是"放行"。

---

## B-015 · 开机动画"窗口一切正常，屏幕上却没有它"（连挂两项视觉自检）

- **日期**：2026-10-25（P10 目录重构时顺手结掉的陈账）
- **优先级**：P0（动画 = 开机第一眼；而且它把两条视觉断言长期染红，真假分不清）
- **症状**：`selftest` 里「旋转环帧差」「五角星包围盒」两项长期红：
  `帧差=0 环带=0`、`包围盒 2384×569px`（星体只有 ~300px，全宽说明拍到的是别的窗口）。
  而 debug 日志明明写着 `window 1440x900 visible=true key=true firstResp=true active=true`。
- **根因**（两层，叠在一起才看不见）
  1. **二进制比源码旧**：`bootanim/tools/wblaunch` 是 01:14 编的，源码 02:27 又改过
     （加「近黑容器 + WebView alpha=0 → didFinish 才淡入」的防白屏改动）。
     旧二进制没有这套淡入，页面 `done` 信号又一直不来，窗口就停在"透明"状态：
     **visible/key/active 全 true，但屏幕上一个像素都没画**。
  2. **测试清场清不干净**：自检只 `pkill -f "wblaunch play"`，登录时
     `com.lingtai.bootanim` 拉起的 `wblaunch boot` 若卡在那个透明状态就杀不掉。
     两个 `.screenSaver` 级全屏窗口互相压制 → 新起的 play 窗口不显示，
     截图拍到背后的 WorkBuddy（亮、彩色）→ 判据被污染成全宽亮块。
- **修法**
  1. 按 `bootctl.sh` 里写的正规命令重编译：
     `cd bootanim/tools && swiftc -O -o wblaunch wblaunch.swift`（旧版留 `/tmp/wblaunch.old-1014`）。
  2. `selftest.sh` 星体那一段的清场改成 `pkill -f "wblaunch"`（连 boot 一起杀）+ `sleep 0.8`；
     并把「测量后立刻删截图」改成**两项都通过才删** —— 失败要留现场，别再"删完才报错"。
- **验证**
  ```
  干净一轮：changed 339654 / band 87323 / bbox 293×283   （阈值 >1000 / >800 / 275~350）
  脏一轮（只杀 play）：bbox 2384×569                      ← 就是上面那堆假红
  selftest.sh --keep-muted → 通过 193 项，失败 0 项
  ```
- **可复用教训**
  1. **改了 .swift 必须重编译**，`ls -l` 比一下源码和二进制的时间戳，
     比从现象倒推快 100 倍（这次源码比二进制新 73 分钟）。
  2. **`visible=true` 不等于"用户看得见"** —— 和 B-013「前台≠可见」、B-009 同一条根：
     判据要盯**画面里的像素**，不要盯窗口属性。
  3. **清场要按"这一类进程"清，不是按"我刚才起的那个"清**：
     遗留实例会安静地把下一条测试变成假红。

---

## B-014 · 常用操作的 App 图标全部上下颠倒

- **日期**：2026-10-24（B-013 之后的同一次改动里引入）
- **优先级**：P1（不影响功能，但一眼就看出是坏的）
- **症状**：换成 App 原图标后，**微信的两个气泡、访达的笑脸、抖音的音符、WPS 的 W 全部上下颠倒**。
  文字是正的，只有图标反了。
- **根因**：为了把 18pt 尺寸"固定下来"，我做了一次**离屏重绘**：
  ```swift
  let out = NSImage(size: 18x18)
  out.lockFocus(); icon.draw(in: 0,0,18,18); out.unlockFocus()
  ```
  `lockFocus()` 建的是**非翻转**的位图上下文，而 tile 的绘制路径和图标自身 rep 的朝向假设不一致，
  于是重绘出来的位图被翻转存下来，之后在哪个视图里画都是反的。
  **真正的问题是：我根本不需要这次重绘。** 只想改尺寸，改 `size` 就够了。
- **修法**
  1. 删掉离屏重绘：`icon.copy()` → 只设 `size = 18x18`、`isTemplate = false`（保住品牌色）。
  2. 绘制改成 `draw(in:from:operation:fraction:respectFlipped: true, hints: nil)`，
     把"朝向"交给 AppKit 按当前视图决定，而不是我猜。
- **验证**：截图放大对比——微信/访达/抖音/WPS/计算器 图标全部正立，与 Dock 一致。
- **可复用教训**
  1. **只想改尺寸就别重绘**。`NSImage.size` 是缩放提示，重绘到离屏画布会引入坐标系假设，
     坐标系假设一旦错，方向就反——而这类错误**编译不报、运行不崩，只有人眼看才看得见**。
  2. **凡是"我顺手多做一步"的地方，都是 bug 的高发区**（这一步本来可以不做）。
  3. 图标类改动**必须截图放大看**，不能只看 layout-check 过没过——
     布局检查只管"在不在框内"，不管"画得对不对"。


## B-013 · 常用操作点了应用不置前（最小化的窗口也不起来）

- **日期**：2026-10-24
- **优先级**：P0（用户主路径，每天点十几次）
- **症状**
  - 应用已打开、被别的窗口挡着 → 点「常用操作」里的格子，界面没变化
  - 应用已最小化在 Dock → 点了也不恢复
  - 面板状态还显示"已打开"，看起来像成功了
- **根因（两层，第二层才是真凶）**
  1. `NSRunningApplication.activate(.activateAllWindows)` 只把**应用**提到前台，
     **最小化窗口仍然留在 Dock**；macOS 不会因为 activate 就 deminiaturize。
  2. 成功判据写的是 `waitFrontmost(bid)` —— 只问"谁在前台"。
     应用成了前台，判据就返回 true，于是脚本报告成功，用户看到的是没反应。
     **"应用在前台" ≠ "窗口可见"**，这两件事必须分开验证。
- **修法**（`flash.swift`）
  1. 新增 `deminiaturizeAll(pid:)`：遍历 `kAXWindowsAttribute`，
     对 `kAXMinimized == true` 的窗口直接 `AXUIElementSetAttributeValue(..., kCFBooleanFalse)`，
     再对每个窗口发 `kAXRaiseAction`。
  2. 新增 `anyWindowVisible(pid:)`：存在**未最小化且宽高 > 80** 的窗口才算真可见。
  3. `raiseAppInProcess` 改为 **T0（deminiaturize）→ T1（activate）→ 判据改成
     `waitFrontmost && anyWindowVisible`**；再加 T1b 二次尝试，T3 前也补一次 deminiaturize。
- **验证**（可复现的两条）
  ```
  /tmp/minz com.tencent.xinWeChat        # 把微信最小化
  面板 → 点「微信」格                    # 期望：窗口恢复 + 到最前
  → iswin 探针：最小化=false、708x775、前台=com.tencent.xinWeChat  ✅

  Finder 置前 → 面板 → 点「微信」
  → 前台变为 com.tencent.xinWeChat  ✅
  ```
- **可复用教训**
  1. **判据要盯"用户看得见的东西"**，不能盯中间状态（前台/进程存在/返回值）。
     这和 B-009「不报风险」、B-011「有音轨但静音」是同一类错误：
     **验证了能验证的，而不是该验证的。**
  2. macOS 上"让 App 出现"是**至少三步**：deminiaturize → activate → AXRaise，
     少任何一步都会在某种窗口状态下失效。
  3. 凡是"点了没反应"的 bug，先问：**是我的判据通过了吗？** 通过就是判据错了。
