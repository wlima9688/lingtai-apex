# 闪控 修复台账（Bugfix Ledger）

> 目的：**把每次踩坑变成下次的捷径**。修 bug 前先查这张表，
> 命中同类症状就直接跳到「修法」，不用再从现象重新推。
>
> 每条固定五段：症状 / 根因 / 修法 / 验证 / 可复用教训。
> 新条目追加在**最上面**（最新的在最前）。

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
