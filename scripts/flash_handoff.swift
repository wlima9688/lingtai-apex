// ============================================================
// flash_handoff — 工件B：把「复杂指令」全自动转交 WorkBuddy
//
// 为什么单独一个文件：flash.swift 已 1700 行，转交链路和面板 UI 没有
//   共享状态，混在一起只会让两边都难读。build_flash.sh 负责拼接。
//
// ── 为什么全靠 AX，不走深链 ─────────────────────────────
//   WorkBuddy 是 Electron 应用，深链只有 home / chat/<sessionId> /
//   automation/run —— **没有「新建任务 + 预填指令」的入口**。
//   要「零人工」，只剩两条路：AX UI 自动化，或 CGEvent 盲点坐标。
//   后者一升级就碎，所以用前者；坐标只作为最后的兜底。
//
// ── Electron 的坑（实测）──────────────────────────────
//   默认 AX 树是「一层 AXGroup 套一层 AXGroup」，按钮全无 title。
//   Chromium 有一条按需开启完整无障碍树的开关：
//   给 app 元素设 AXManualAccessibility = true，1~2 帧后整棵树才长出来。
//   不设这个，任何 find 都只会找到空 group —— 这是本文件第一件事。
// ============================================================

/// AX 属性读取。失败返回 nil（不抛错：AX 里「读不到」是常态，不是异常）。
func axAttr(_ el: AXUIElement, _ key: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
    return v
}

func axStr(_ el: AXUIElement, _ key: String) -> String {
    if let s = axAttr(el, key) as? String { return s }
    return ""
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

/// 元素对角坐标（AX 给的是「左上角 + 尺寸」，CGEvent 需要中心点）
func axFrame(_ el: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?, sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success
    else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    guard s.width > 0 || s.height > 0 else { return nil }
    return CGRect(origin: p, size: s)
}

/// 给 app 打开完整无障碍树（Electron/Chromium 专有开关）。
/// ⚠ 两个开关都发：AXManualAccessibility 是 Electron 自己的按需开关，
///   AXEnhancedUserInterface 是「读屏软件在场」的等价信号，Chromium 认这个。
///   只发一个时实测树仍然只有窗口+3 个按钮（网页内容不暴露）。
/// ⚠ 必须留一帧让渲染进程把树建出来，紧接着就 find 会读到旧树。
@discardableResult
func axEnableManual(_ appEl: AXUIElement, settle: Double = 0.35) -> Bool {
    let a = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString,
                                         kCFBooleanTrue) == .success
    let b = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString,
                                         kCFBooleanTrue) == .success
    if a || b { RunLoop.current.run(until: Date().addingTimeInterval(settle)) }
    return a || b
}

/// 广度优先找第一个满足条件的节点。
/// ⚠ 用 BFS 不用 DFS：Electron 的树又宽又深（隐藏节点全在），
///   视觉上最靠前的元素在 BFS 里先被碰到，DFS 容易一头钻进侧栏。
func axFind(_ root: AXUIElement, maxDepth: Int = 24,
            where pred: (AXUIElement) -> Bool) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var head = 0
    var seen = 0
    while head < queue.count {
        let (el, d) = queue[head]; head += 1
        seen += 1
        if seen > 6000 { return nil }   // 防环：Electron 的树偶尔会自引用
        if pred(el) { return el }
        if d < maxDepth { for c in axChildren(el) { queue.append((c, d + 1)) } }
    }
    return nil
}

/// 节点的一句话画像，用于匹配和日志。
/// placeholder 对 Electron 输入框最靠谱（title/value 常年为空）。
func axText(_ el: AXUIElement) -> String {
    [
        axStr(el, kAXTitleAttribute as String),
        axStr(el, kAXDescriptionAttribute as String),
        axStr(el, kAXValueAttribute as String),
        axStr(el, "AXPlaceholderValue"),
    ].joined(separator: " ")
}

func axRole(_ el: AXUIElement) -> String { axStr(el, kAXRoleAttribute as String) }

// ── B1 探针：dump 真实结构，用来定死「怎么找按钮/输入框」──────────
//
// ⚠ 探针必须和正式链路用**同一套 helper**，否则探出来的结构
//   到了正式代码里找不到 —— 那就成了「测的和跑的不是一个东西」。
func axProbeDump(_ appName: String, maxDepth: Int = 40) -> String {
    guard let bid = resolveBundleID(appName),
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
    else { return "PROBE_FAIL 解析/找不到运行中的 \(appName)" }

    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    let enabled = axEnableManual(appEl, settle: 0.6)

    var lines: [String] = ["# app=\(bid) pid=\(app.processIdentifier) a11y=\(enabled)"]

    func walk(_ el: AXUIElement, _ d: Int, _ prefix: String) {
        if d > maxDepth || lines.count > 4000 { return }
        let role = axRole(el)
        let txt = axText(el).trimmingCharacters(in: .whitespacesAndNewlines)
        var extra = ""
        if let f = axFrame(el) {
            extra += " @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
        }
        var names: CFArray?
        var acts: [String] = []
        if AXUIElementCopyActionNames(el, &names) == .success, let ns = names as? [String] { acts = ns }
        if !acts.isEmpty { extra += " act=\(acts.joined(separator: ","))" }
        lines.append("\(prefix)[\(role)] \(txt.prefix(90))\(extra)")
        for (i, c) in axChildren(el).enumerated() {
            walk(c, d + 1, prefix + (i == axChildren(el).count - 1 ? "  └ " : "  ├ "))
        }
    }
    if let win = (axAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement])?.first {
        walk(win, 0, "")
    } else {
        walk(appEl, 0, "")
    }
    return lines.joined(separator: "\n")
}

// ── 转交结果 ───────────────────────────────────────────────
//
// `step` 记录失败在哪一步，是整个链路唯一的排障线索：
//   AX / NEWTASK / COMPOSER / PASTE / SKILL / SEND / VERIFY
struct HandoffResult {
    var ok = false
    var step = "INIT"
    var detail = ""
    var ms = 0
    var bundle = ""

    var json: String {
        let d = detail.replacingOccurrences(of: "\"", with: "'")
                    .replacingOccurrences(of: "\n", with: " ")
        return "{\"ok\":\(ok),\"step\":\"\(step)\",\"bundle\":\"\(bundle)\",\"ms\":\(ms),\"evidence\":\"\(d)\"}"
    }
}

func hdDebug(_ s: String) {
    guard ProcessInfo.processInfo.environment["WB_HANDOFF_DEBUG"] == "1" else { return }
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// ── 键盘事件（Electron 对 AX setValue 常无反应，只能真按键）──────

func postKey(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(12_000)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
}

/// 逐块注入 Unicode。粘贴失败时的兜底 —— 比坐标点击可靠，不依赖输入框位置。
func typeUnicode(_ s: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    let units = Array(s.utf16)
    var i = 0
    while i < units.count {
        let end = min(i + 16, units.count)
        var slice = Array(units[i..<end])
        if let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            e.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            e.post(tap: .cghidEventTap)
        }
        i = end
        usleep(10_000)
    }
}

/// 真实鼠标点击（AXPress 对网页渲染出来的弹出项常常直接返回 unsupported）
func clickAt(_ p: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func clipboardText(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
}

func cliKeycodes() -> (v: CGKeyCode, a: CGKeyCode, slash: CGKeyCode, ret: CGKeyCode, del: CGKeyCode) {
    (9, 0, 44, 36, 51)
}

// ── 主链路 ─────────────────────────────────────────────────
//
// 步骤（每步独立超时，失败即返回，由调用方降级为「已复制，手动 ⌘V」）：
//   ① 剪贴板备好原文（最坏情况下用户仍能一键粘）
//   ② 拉起/置前 WorkBuddy（冷启动走 wblaunch，先播全屏动画再拉起）
//   ③ 打开完整 AX 树（Electron 不设这个只能读到 3 个按钮）
//   ④ 点「新建任务」→ ⑤ 定位输入框 → ⑥ 粘贴
//   ⑦ 可选：唤技能 → ⑧ 发送 → ⑨ 校验（输入框清空 / 出现「停止」）
/// 转交边界声明：从 handoff-policy.json 读白名单/禁止项，拼在指令尾部。
///
/// ⚠ 为什么要有：转交出去的 agent 拿到的是**同一台机器 + 同一个桌面权限**。
///   2026-10-22 实测它真的打开了「下载」、列了目录、还弹出确认框问要不要删。
///   用户拍板要白名单 —— 这是唯一的边界：让接收端在动手前就知道范围。
///   文件读不到就退化成「不附加」，绝不因为缺配置把转交搞失败。
func handoffBoundary() -> String {
    let path = scriptsDir() + "/handoff-policy.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return "" }

    // 新模型（2026-10-23 用户拍板）：**只列禁止项**，没列出的都可以做。
    // 旧模型是"白名单 + 禁止"，等于把 agent 的手脚全捆住；用户要的是"放权，
    // 但红线清楚"。所以这里优先读 deny，读到旧字段就退回旧格式（向后兼容）。
    if let deny = obj["deny"] as? [String], !deny.isEmpty {
        var lines = ["", "—— 闪控转交边界（自动附加，非用户原文）——",
                     "除下列禁止项外，其余操作你都可以直接做，不必再问："]
        for d in deny { lines.append("  禁止：" + d) }
        if let cond = obj["conditional"] as? [String], !cond.isEmpty {
            lines.append("（以下是条件项，满足条件才做，不满足就当禁止：）")
            for c in cond { lines.append("  条件：" + c) }
        }
        if let note = obj["_边界提醒"] as? String, !note.isEmpty { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    let apps = (obj["allow_apps"] as? [String]) ?? []
    let forbid = (obj["forbidden"] as? [String]) ?? []
    if apps.isEmpty && forbid.isEmpty { return "" }
    var lines = ["", "—— 闪控转交边界（自动附加，非用户原文）——"]
    if !apps.isEmpty { lines.append("只允许操作这些应用：" + apps.joined(separator: "、")) }
    for f in forbid { lines.append("禁止：" + f) }
    lines.append("超出以上范围请停下来先问我，不要自行扩大权限。")
    return lines.joined(separator: "\n")
}


/// 坐标兜底：WorkBuddy 5.8.3 的输入框**不在 AX 树里**（`AXTextArea` 为空），
/// AX 路径必然在 COMPOSER 步骤失败（实测 2026-10-25）。
/// 但它的按钮在 AX 里（`macctl click --text "新建任务"` 能命中），
/// 说明只有 contenteditable 不暴露 —— 所以改走"坐标 + 剪贴板"。
///
/// 三段都复用已验证的 CLI（不新写 CGEvent 代码）：
///   ① `macctl scwindows` 取窗口矩形 → ② `macctl click --at` 点输入框
///   → ③ `macctl type --text`（内部走剪贴板粘贴）
///
/// 校验也不读 AXValue（读不到），改看**placeholder 是否消失**：
/// 「今天帮你做些什么」这句只在空输入框里出现，它没了就说明字进去了。
func handoffByCoordinates(_ text: String, skill: String? = nil, submit: Bool = true) -> HandoffResult {
    var r = HandoffResult()
    let t0 = Date()
    func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
    let tools = scriptsDir()
    let macctl = tools + "/macctl"
    let bid = "com.tencent.workbuddy.mac"

    func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    // ① 窗口矩形：取面积最大的那个（面板/提示条都不如主窗口大）
    let wins = run(macctl, ["scwindows", "--app", bid])
    var best: CGRect = .zero
    for line in wins.split(separator: "\n") {
        guard let m = line.range(of: #"@\((\d+),(\d+)\) (\d+)x(\d+)"#, options: .regularExpression) else { continue }
        let nums = line[m].dropFirst(2).split(whereSeparator: { $0 == ")" || $0 == "(" || $0 == "," || $0 == "x" || $0 == " " })
            .compactMap { Double($0) }
        guard nums.count == 4 else { continue }
        let f = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
        if f.width * f.height > best.width * best.height { best = f }
    }
    guard best.width > 200, best.height > 200 else {
        r.ok = false; r.step = "COORD"; r.detail = "找不到 WorkBuddy 主窗口"; r.ms = ms(); return r
    }

    /* ② 点输入框：**两个候选高度**都试。
       ⚠ 2026-10-25 实测：输入框在两种页面里高度不同 ——
          · 任务详情页：窗口内约 **38%** 高（底部输入条）
          · 首页：约 **71%** 高（大号输入框在引导语下面）
       兜底只在"AX 找不到"时触发，通常就是任务详情页；但两种都试更稳。 */
    let px = Int(best.minX + best.width * 0.61)
    r.step = "COORD_CLICK"

    // ③ 粘贴（要求带唯一 marker 便于确认）
    let marker = "hdo-\(Int(Date().timeIntervalSince1970))"
    let payload = text + "\n<!-- \(marker) -->"
    r.step = "COORD_PASTE"

    /* ④ 校验：截图比对（**不能用 placeholder**）。
       ⚠ 2026-10-25 实测：`macctl find --text "今天帮你做些什么"` 从来没命中过 ——
          placeholder 根本不在 AX 树里。若拿"placeholder 消失"当成功判据，
          这个兜底会**永远返回成功**（假阳性比失败更坏：用户以为派出去了）。
       改成：粘贴前后各拍一张输入框区域，**像素一致 = 没粘进去**。 */
    let region = "\(Int(best.minX + best.width * 0.05)),\(Int(best.minY + best.height * 0.40)),\(Int(best.width * 0.90)),\(Int(best.height * 0.20))"
    let shotA = "/tmp/hdo-before.png", shotB = "/tmp/hdo-after.png"
    _ = run(macctl, ["shot", "--rect", region, "--out", shotA])
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    _ = run(macctl, ["type", "--text", payload, "--app", bid])
    RunLoop.current.run(until: Date().addingTimeInterval(0.7))
    _ = run(macctl, ["shot", "--rect", region, "--out", shotB])
    func sig(_ path: String) -> String {
        guard let d = FileManager.default.contents(atPath: path) else { return "" }
        return "\(d.count)"
    }
    // 内容变了 → 尺寸通常也变；两者都相同才判"没进去"
    var same = sig(shotA) == sig(shotB) && sig(shotA) != ""
    if same {
        // 第一个高度没命中 → 换 71%（首页那种大输入框）再试一次
        let py2 = Int(best.minY + best.height * 0.71)
        _ = run(macctl, ["click", "--at", "\(px),\(py2)"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        _ = run(macctl, ["shot", "--rect", region, "--out", shotA])
        _ = run(macctl, ["type", "--text", payload, "--app", bid])
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        _ = run(macctl, ["shot", "--rect", region, "--out", shotB])
        same = sig(shotA) == sig(shotB) && sig(shotA) != ""
    }
    if same {
        r.ok = false; r.step = "COORD_VERIFY"
        r.detail = "两个候选高度都没把字送进去"; r.ms = ms(); return r
    }

    // ⑤ 提交
    if submit {
        _ = run(macctl, ["key", "--key", "return"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        r.step = "COORD_SENT"
    }
    r.ok = true; r.detail = "坐标兜底送达（marker \(marker)）"; r.ms = ms()
    return r
}

func handoffToWorkBuddy(_ text: String, skill: String? = nil,
                        submit: Bool = true, dumpPath: String? = nil) -> HandoffResult {
    let t0 = Date()
    func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
    var r = HandoffResult()

    func fail(_ step: String, _ why: String) -> HandoffResult {
        r.ok = false; r.step = step; r.detail = why; r.ms = ms()
        hdDebug("[handoff] FAIL \(step): \(why)")
        if let p = dumpPath { try? axProbeDump("WorkBuddy").write(toFile: p, atomically: true, encoding: .utf8) }
        return r
    }

    r.bundle = "com.tencent.workbuddy.mac"
    // 正文 = 用户原文 + 边界声明（见 handoffBoundary 注释）
    let payload = text + handoffBoundary()
    hdDebug("[handoff] 正文长度 \(payload.count)（含边界 \(payload.count - text.count) 字）")
    clipboardText(payload)   // ①

    // ② 拉起 / 置前
    if !isRunningApp(r.bundle) {
        _ = runWblaunch(["play"])          // 异步：动画播完它自己拉起 WorkBuddy
        r.step = "COLD"
        let dl = Date().addingTimeInterval(40)
        while Date() < dl && !isRunningApp(r.bundle) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if !isRunningApp(r.bundle) { return fail("COLD", "40 秒内 WorkBuddy 没起来（开场动画没播完或启动失败）") }
        // 首帧窗口还没画出来时 AX 是空的
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    } else {
        let raised = raiseAppInProcess("WorkBuddy")
        if !raised.ok { hdDebug("[handoff] raise 未成功：\(raised.how) \(raised.detail)，仍尝试 AX") }
    }

    // ③ 完整的 AX 树
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: r.bundle).first else {
        return fail("AX", "进程不在")
    }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    if !axEnableManual(appEl, settle: 0.5) { return fail("AX", "打不开无障碍树（辅助功能授权？）") }
    r.step = "AX"

    // ④ 点「新建任务」（侧栏 AXRadioButton；找不到也继续 —— 可能已经在新任务页）
    if let nt = axFind(appEl, where: { axRole($0) == "AXRadioButton" && axText($0).contains("新建任务") }) {
        _ = AXUIElementPerformAction(nt, kAXPressAction as CFString)
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
    } else {
        hdDebug("[handoff] 没找到「新建任务」按钮，按已在新建页处理")
    }
    r.step = "NEWTASK"

    // ⑤ 输入框：placeholder「今天帮你做些什么」，退路是「最宽的 AXTextArea」
    func composer() -> AXUIElement? {
        axFind(appEl, where: { axRole($0) == "AXTextArea" && axText($0).contains("今天帮你做些什么") })
            ?? axFind(appEl, where: { axRole($0) == "AXTextArea" })
    }
    var boxOpt: AXUIElement?
    let dl = Date().addingTimeInterval(3)
    while Date() < dl {
        if let b = composer() { boxOpt = b; break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }
    guard let found = boxOpt else {
        // AX 找不到输入框（5.8.3 的 contenteditable 不暴露）→ 走坐标兜底，
        // 别直接失败：失败一次就少一次自动转交，用户又得手工粘。
        hdDebug("[handoff] COMPOSER 失败 → 转坐标兜底")
        let fb = handoffByCoordinates(text, skill: skill, submit: submit)
        if dumpPath != nil, let p = dumpPath { try? axProbeDump("WorkBuddy").write(toFile: p, atomically: true, encoding: .utf8) }
        return fb
    }
    var box = found

    // 聚焦：Electron 只认 AXFocused + 真实点击，二者都试
    _ = AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementPerformAction(box, kAXPressAction as CFString)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))

    hdDebug("[handoff] composer 初始 value=\(axStr(box, kAXValueAttribute as String).prefix(40))")

    // 清掉可能的草稿（新建页正常是空的，但用户可能刚打过字）
    let kc = cliKeycodes()
    postKey(kc.a, .maskCommand)
    postKey(kc.del)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    hdDebug("[handoff] ⌘A+⌫ 后 value=\(axStr(box, kAXValueAttribute as String).prefix(40))")

    // ⑤.5 唤技能（可选，尽力而为）
    //
    // 为什么要先选技能再粘正文：`/` 只在输入框**开头**才唤出技能面板，
    // 正文已经在里面时再打 `/` 就只是普通斜杠。
    //
    // ⚠⚠ 踩过：技能候选不能在整棵树里找「文本含 mac-control」——
    //   侧栏任务列表里有一条「mac-control安装谷歌网页翻译插件」，
    //   BFS 先撞上它，一点就切走了当前会话，后面粘贴直接落到别的页面。
    //   现在按**位置**收窄：候选必须在输入框正上方、且横坐标落在
    //   输入框左侧起点的 ±20px 内（弹出层是锚在输入框上的）。
    if let sk = skill, !sk.isEmpty {
        r.step = "SKILL"
        var picked = false
        for _ in 0..<2 {
            postKey(kc.slash)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            // ⚠⚠ 关键一步（2026-10-23 用户报「转交时没自动带上 mac-control 技能」）：
            //   只按 `/` 唤出的是**全量技能列表**（上百条，mac-control 排在下面
            //   根本不在 AX 树里 → 永远选不上，然后静默降级成"无技能转交"）。
            //   人是怎么做的？按 `/` 之后接着打名字过滤。这里照做：
            //   把技能名敲进输入框，候选就只剩它一个。
            typeUnicode(sk)
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            let cr = axFrame(box) ?? .zero
            if ProcessInfo.processInfo.environment["WB_HANDOFF_DEBUG"] == "1" {
                let all = axGather(appEl, where: { axText($0).lowercased().contains(sk.lowercased()) })
                for e in all {
                    let f = axFrame(e)
                    hdDebug("[skill-cand] \(axRole(e)) \(axText(e).prefix(28)) @\(f.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "无frame")")
                }
                hdDebug("[skill-cand] composer @\(Int(cr.minX)),\(Int(cr.minY)) \(Int(cr.width))x\(Int(cr.height))")
            }
            var best: (AXUIElement, CGFloat)? = nil
            axFind(appEl, where: { el in
                let role = axRole(el)
                guard role == "AXMenuItem" || role == "AXButton" || role == "AXStaticText" else { return false }
                let t = axText(el)
                // ⚠ axText 是多个属性拼起来的，开头常带空格 —— 必须先 trim，
                //   否则 hasPrefix 永远 false（踩过：候选明明在，就是选不上）
                guard t.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased().hasPrefix(sk.lowercased()) else { return false }
                guard let f = axFrame(el) else { return false }
                // 必须在输入框上方、并且贴着输入框左边缘（排除侧栏/历史列表）
                guard f.maxY <= cr.minY + 6, f.minX >= cr.minX - 24, f.minX <= cr.minX + 120 else { return false }
                if best == nil || f.maxY > best!.1 { best = (el, f.maxY) }
                return false
            })
            if let (m, _) = best {
                let pr = AXUIElementPerformAction(m, kAXPressAction as CFString)
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                if !axStr(box, kAXValueAttribute as String).lowercased().contains(sk.lowercased()) {
                    hdDebug("[handoff] AXPress 技能项失败（\(pr.rawValue)），改真鼠标点击")
                    if let f = axFrame(m) {
                        clickAt(CGPoint(x: f.midX, y: f.midY))
                        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    }
                }
                if axStr(box, kAXValueAttribute as String).lowercased().contains(sk.lowercased()) {
                    picked = true
                    hdDebug("[handoff] 技能已选中：\(sk)")
                    break
                }
                hdDebug("[handoff] 技能点了但输入框没出现技能名，value=\(axStr(box, kAXValueAttribute as String).prefix(40))")
            }
            // 没选上：把现场收拾干净（半截 `/xxx` 会把整条指令变成假命令）
            hdDebug("[handoff] 技能没选上，清空输入框重试")
            if let nb = axFind(appEl, where: { axRole($0) == "AXTextArea" && axText($0).contains("今天帮你做些什么") }) {
                box = nb
                _ = AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            postKey(kc.a, .maskCommand)
            postKey(kc.del)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if !picked { hdDebug("[handoff] 技能唤不出来，按「无技能」继续转交") }
    }

    // ⑥ 粘贴
    r.step = "PASTE"
    postKey(kc.v, .maskCommand)
    var pasted = false
    // ⚠ 判据不能只看 AXTextArea 的 AXValue：实测粘贴成功但属性要晚几百毫秒
    //   才更新（更糟时整轮读不到），于是「明明贴上了却报失败」。
    //   三条路任一命中就算成功：value / 元素自身文本 / 子节点里的静态文本。
    let probe = String(payload.prefix(6))
    func composerHasText() -> Bool {
        // ⚠ 必须**重新定位**输入框再读：Electron 每次输入都会重建 textarea 节点，
        //   手里那个旧元素读完还是空值 —— 「贴上去了却报 PASTE 失败」就是这个。
        if let fresh = composer(),
           axStr(fresh, kAXValueAttribute as String).contains(probe) { return true }
        // 最后兜底：整棵树里任何一个静态文本含这一段，就算进去了
        return axFind(appEl, where: {
            axStr($0, kAXValueAttribute as String).contains(probe)
        }) != nil
    }
    let pd = Date().addingTimeInterval(3.5)
    while Date() < pd {
        if composerHasText() { pasted = true; break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    if !pasted {
        // 兜底：直接注入字符（不依赖剪贴板，也不依赖 AX 写值）
        hdDebug("[handoff] 粘贴未生效，改逐字注入")
        typeUnicode(payload)
        let pd2 = Date().addingTimeInterval(2.5)
        while Date() < pd2 {
            if composerHasText() { pasted = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
    if !pasted { return fail("PASTE", "原文没进输入框（AX 读不到内容，可能 Electron 未暴露 value）") }
    hdDebug("[handoff] 粘贴后 value=\(axStr(box, kAXValueAttribute as String).prefix(40))")

    if let p = dumpPath {
        try? axProbeDump("WorkBuddy").write(toFile: p, atomically: true, encoding: .utf8)
    }

    if !submit { r.ok = true; r.step = "DRY"; r.detail = "干跑：已粘贴未发送"; r.ms = ms(); return r }

    // ⑧ 发送
    //
    // ⚠ 实测：直接 AXPress「发送」按钮会把输入框内容**清掉但任务不出现**
    //   （v5.8.3 欢迎页有「选择工作空间」前置条件，按钮在这种状态下
    //   只是把草稿丢弃）。所以先走**回车**——那是用户真实的提交动作，
    //   也是这个输入框自己的默认行为；回车没反应再点按钮。
    r.step = "SEND"
    hdDebug("[handoff] 发送前 value=\(axStr(box, kAXValueAttribute as String).prefix(40))")
    postKey(kc.ret)

    // ⑨ 校验：原文离开输入框（空态是占位演示文案，不是空串）
    // 同 composerHasText：必须重新定位（旧元素永远停在粘贴那一刻的内容上，
    // 用它判「已清空」会永远判成「没提交」）
    func stillHasDraft() -> Bool {
        if let fresh = composer() {
            return axStr(fresh, kAXValueAttribute as String).contains(probe)
        }
        return false
    }
    var sent = false
    var vd = Date().addingTimeInterval(2.0)
    while Date() < vd {
        if !stillHasDraft() { sent = true; break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    if !sent {
        hdDebug("[handoff] 回车未提交，改点「发送」按钮")
        if let b = axFind(appEl, where: { axRole($0) == "AXButton" && axText($0).contains("发送") }) {
            let pr = AXUIElementPerformAction(b, kAXPressAction as CFString)
            hdDebug("[handoff] AXPress 发送 → \(pr.rawValue)")
        }
        vd = Date().addingTimeInterval(2.5)
        while Date() < vd {
            if !stillHasDraft() { sent = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
    if sent {
        r.ok = true; r.step = "SENT"; r.detail = "指令已提交（原文已离开输入框）"; r.ms = ms(); return r
    }
    return fail("VERIFY", "回车和点按钮都没把指令送出去（输入框仍是原文）")
}
/// 收集所有匹配节点（调试/多候选用；正式链路优先 axFind 取第一个）
func axGather(_ root: AXUIElement, maxDepth: Int = 24,
              where pred: (AXUIElement) -> Bool, limit: Int = 40) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var head = 0
    var seen = 0
    while head < queue.count && out.count < limit {
        let (el, d) = queue[head]; head += 1
        seen += 1
        if seen > 6000 { break }
        if pred(el) { out.append(el) }
        if d < maxDepth { for c in axChildren(el) { queue.append((c, d + 1)) } }
    }
    return out
}
