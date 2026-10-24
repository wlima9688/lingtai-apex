import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Vision
import ImageIO

// ============================================================
// macctl — macOS 桌面自动化统一工具
// 一次编译，长期使用；每个子命令完成一个完整意图
// ============================================================

let VERSION = "1.0.0"
let CACHE_DIR = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".workbuddy/skills/mac-control/cache")
let LEARN_FILE = CACHE_DIR.appendingPathComponent("learned.json")

// MARK: - AX 基础

struct Node {
    let el: AXUIElement
    let role: String
    let title: String
    let desc: String
    let value: String
    let pos: CGPoint
    let size: CGSize
    var text: String { [title, desc, value].filter { !$0.isEmpty }.joined(separator: "|") }
    var center: CGPoint { CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2) }
}

func axStr(_ el: AXUIElement, _ attr: String) -> String {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &out) == .success else { return "" }
    return (out as? String) ?? ""
}
func axVal(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &out) == .success else { return nil }
    return out
}
func axPos(_ el: AXUIElement) -> CGPoint {
    guard let v = axVal(el, kAXPositionAttribute) else { return .zero }
    guard CFGetTypeID(v) == AXValueGetTypeID() else { return .zero }
    var p = CGPoint.zero
    guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return .zero }
    return p
}
func axSize(_ el: AXUIElement) -> CGSize {
    guard let v = axVal(el, kAXSizeAttribute) else { return .zero }
    guard CFGetTypeID(v) == AXValueGetTypeID() else { return .zero }
    var s = CGSize.zero
    guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return .zero }
    return s
}
func axBool(_ el: AXUIElement, _ attr: String) -> Bool {
    (axVal(el, attr) as? Bool) ?? false
}
func axDouble(_ el: AXUIElement, _ attr: String) -> Double? {
    guard let v = axVal(el, attr) else { return nil }
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}

func appPID(_ bundleID: String) -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
}

func appElement(_ bundleID: String) -> AXUIElement? {
    guard let pid = appPID(bundleID) else { return nil }
    return AXUIElementCreateApplication(pid)
}

func windows(of axApp: AXUIElement) -> [AXUIElement] {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &out) == .success,
          let ws = out as? [AXUIElement] else { return [] }
    return ws
}

/// AX 树的遍历根集合 = AX 窗口 + app 级子元素
///
/// ⚠ 实测踩过（D-019）：只遍历 windows(of:) 会漏掉一整类应用。
///   Dock 的 AX 窗口数是 **0**（它不是普通窗口，是 layer=20 的 LPSpringboard），
///   图标全部挂在 app 级子元素的 AXList 里。只走 windows() 会得到「Dock 图标: 」
///   空列表 —— 表现为「Dock 明明有图标，却说找不到」。
///   同理适用于菜单栏代理类、无窗口的工具类应用。
///   所以这里把两类根合并返回，让所有遍历入口都覆盖到。
func axRoots(of axApp: AXUIElement) -> [AXUIElement] {
    var roots = windows(of: axApp)
    var extra: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &extra) == .success,
       let kids = extra as? [AXUIElement] {
        roots.append(contentsOf: kids)
    }
    return roots
}

func node(_ el: AXUIElement) -> Node {
    Node(el: el, role: axStr(el, kAXRoleAttribute), title: axStr(el, kAXTitleAttribute),
         desc: axStr(el, kAXDescriptionAttribute), value: axStr(el, kAXValueAttribute),
         pos: axPos(el), size: axSize(el))
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &out) == .success,
          let cs = out as? [AXUIElement] else { return [] }
    return cs
}

/// 深度优先遍历 AX 树
func walk(_ el: AXUIElement, _ depth: Int = 0, _ maxDepth: Int = 40, _ out: inout [Node]) {
    if depth > maxDepth { return }
    out.append(node(el))
    for c in children(el) { walk(c, depth + 1, maxDepth, &out) }
}

func treeNodes(bundleID: String, maxDepth: Int = 40) -> [Node] {
    guard let ax = appElement(bundleID) else { return [] }
    var out: [Node] = []
    for w in axRoots(of: ax) { walk(w, 0, maxDepth, &out) }
    return out
}

func frontApp() -> NSRunningApplication? {
    NSWorkspace.shared.frontmostApplication
}

/// 应用名（磁盘目录名 / CFBundleName）→ bundle id。
///
/// ⚠ 只走 Spotlight 的**精确**匹配（kMDItemFSName == 'X.app'），
///   一次 mdfind 就够 —— 不做全量包含匹配（那要拉 300+ 条索引，慢且会误选）。
func bundleIDForAppName(_ name: String) -> String? {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    p.arguments = ["kMDItemFSName == '\(name).app'cd"]
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let lines = String(data: data, encoding: .utf8)?
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasSuffix(".app") } ?? []
    guard let first = lines.first else { return nil }
    let bid = Bundle(url: URL(fileURLWithPath: first))?.bundleIdentifier ?? ""
    return bid.isEmpty ? nil : bid
}

/// 把用户说的名字解析成 bundle id。
///
/// ⚠⚠ 别名表必须**优先于**名字模糊匹配（2026-10-22 实测踩坑）：
///   用户说「打开浏览器」，而这台机器上正跑着**豆包浏览器**
///   （com.bot.neotix.doubao.browser，显示名含"浏览器"三个字）。
///   原来的模糊匹配 `localizedName.contains("浏览器")` 会先命中它 →
///   「打开浏览器」打开的却是豆包内置浏览器，完全不是用户要的。
///   所以先过 APP_ALIASES（「浏览器」→「Google Chrome」），
///   只有别名表没有的词才走模糊匹配。
///
/// ⚠ 模糊匹配仍要留着：用户可能说出一个别名表里没有的名字
///   （比如某个第三方 App 的本地化名）。
func resolveBundle(_ s: String) -> String? {
    // ① 别名表优先（中文俗称 → 真实应用名）
    if let alias = APP_ALIASES[s] ?? APP_ALIASES[s.lowercased()] {
        // 别名是**应用名**（不是 bundle id）。先在运行中的应用里按
        // bundle 目录名/CFBundleName 精确匹配 —— 不碰 mdfind，快且准。
        for app in NSWorkspace.shared.runningApplications {
            guard let burl = app.bundleURL else { continue }
            let fname = burl.deletingPathExtension().lastPathComponent
            if fname.caseInsensitiveCompare(alias) == .orderedSame {
                return app.bundleIdentifier
            }
            if let cn = Bundle(url: burl)?
                .object(forInfoDictionaryKey: "CFBundleName") as? String,
               cn.caseInsensitiveCompare(alias) == .orderedSame {
                return app.bundleIdentifier
            }
        }
        // 没在跑 → 解析出 bundle id（供上层走「拉起」分支）
        if let bid = bundleIDForAppName(alias) { return bid }
    }
    // ② 原名就是 bundle id 或已安装应用名
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: s).first { return s }
    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s) { return s }
    // ③ 按名字模糊匹配（只对别名表没有的词生效）
    for app in NSWorkspace.shared.runningApplications {
        if app.localizedName?.lowercased() == s.lowercased() { return app.bundleIdentifier }
        if app.bundleIdentifier?.lowercased().contains(s.lowercased()) == true { return app.bundleIdentifier }
    }
    for app in NSWorkspace.shared.runningApplications {
        if app.localizedName?.contains(s) == true { return app.bundleIdentifier }
    }
    return nil
}

/// 排除不该被「打开X」选中的后台辅助进程。
///
/// ⚠ 实测踩到的坑：`macctl launch --name 浏览器` 曾解析到
///   `com.apple.WebKit.Networking` —— 它的显示名里含「浏览器」三个字，
///   但它是**隐藏的 0 节点后台进程**，启动了也没有界面。
///   判据：没有 Dock 图标（activationPolicy == .prohibited）
///   且 AX 树为空 → 不是用户想打开的东西。
func isUserVisibleApp(_ bid: String) -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { return true }
    if app.activationPolicy == .prohibited { return false }
    if app.activationPolicy == .accessory {
        // 菜单栏类应用（没有任何窗口）也算不可见
        return windows(of: AXUIElementCreateApplication(app.processIdentifier)).isEmpty == false
    }
    return true
}

/// 按名称查找已安装的应用，**连没运行的也能找到**。
///
/// ⚠ 为什么必须单独写一个（不能靠 resolveBundle）：
///   resolveBundle 只遍历 `runningApplications`，也就是**只查正在跑的**。
///   用户说「打开 WPS」时 WPS 往往是关着的 → 解析失败 → 上层只能去搜文件，
///   于是「打开WPS」变成在磁盘里搜名字带 wps 的文件，报 AMBIGUOUS。
///   这是 D-022 记录的「打开X 全部退化成打开文件」的直接根因。
///
/// ⚠ 也不能用 `NSWorkspace.urlsForApplications(toOpen:)`：
///   实测它只返回 **2 个**（关联了文档类型的应用），系统自带的计算器、
///   访达、预览全都不在里面。这个API 在 macOS 26 上基本不可用于「列出应用」。
///   唯一稳定的办法是**扫标准目录 + 读 Info.plist**（实测 100% 命中）。
func resolveAppURL(_ name: String) -> URL? {
    // 0) 中文/俗称 → 英文真实名（用户说「计算器」，磁盘上是 Calculator.app）
    let lookup = APP_ALIASES[name] ?? APP_ALIASES[name.lowercased()] ?? name

    // 1) 直接当 bundle id 解析（最快，覆盖 "com.apple.finder" 这类写法）
    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return u }
    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: lookup) { return u }

    // 1.5) Spotlight 应用索引（mdfind）
    //
    // ⚠ 为什么必须是首选之一（实测踩坑）：
    //   FileManager.contentsOfDirectory(at: "/Applications") 在本机只返回 **49** 条，
    //   而 mdfind 返回 **345** 个应用。差的都是被 SIP/TCC 保护的目录
    //   （/Applications/Safari.app 就读不到，但mdfind 能定位到）。
    //   所以只靠扫目录 = 「Safari 明明装了却说找不到」。
    if let u = spotlightAppURL(named: lookup) { return u }
    if lookup != name, let u = spotlightAppURL(named: name) { return u }

    // 2) 扫标准安装目录
    var roots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        URL(fileURLWithPath: NSHomeDirectory() + "/Applications"),
    ]
    // 3) /Applications 下的子目录里也常藏应用（如 Adobe 全家桶、Microsoft Office）
    if let kids = try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: "/Applications"),
        includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
        roots.append(contentsOf: kids.filter { $0.hasDirectoryPath })
    }

    /// 归一化：小写 + 去掉空格/连字符/下划线，让「WPS 文字」「wps文字」都能互认
    func norm(_ s: String) -> String {
        s.lowercased().filter { !" -_.".contains($0) }
    }
    let key = norm(lookup)
    var partial: (URL, Int)? = nil   // 记录最长的包含匹配，优先选更具体的那个

    for root in roots {
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
        for u in kids where u.pathExtension == "app" {
            let fname = u.deletingPathExtension().lastPathComponent
            let b = Bundle(url: u)
            let disp = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? fname
            // 精确命中：文件名或显示名完全相等 → 直接返回
            if fname == name || disp == name { return u }
            let n = norm(fname), dn = norm(disp)
            if n == key || dn == key { return u }
            // 包含匹配：记下更长的候选（"wpsoffice" 优于 "wpsofficehelper"）
            if !key.isEmpty, let len = [n, dn].first(where: { $0.contains(key) })?.count {
                if partial == nil || len > partial!.1 { partial = (u, len) }
            }
        }
    }
    return partial?.0
}

// MARK: - 事件注入

let HID = CGEventSource(stateID: .hidSystemState)

func mouseMove(_ pt: CGPoint) {
    CGEvent(mouseEventSource: HID, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}
func mouseClick(_ pt: CGPoint, count: Int = 1, button: CGMouseButton = .left) {
    mouseMove(pt); usleep(120_000)
    for _ in 0..<count {
        CGEvent(mouseEventSource: HID, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: button)?
            .post(tap: .cghidEventTap)
        usleep(40_000)
        CGEvent(mouseEventSource: HID, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: button)?
            .post(tap: .cghidEventTap)
        usleep(40_000)
    }
    usleep(80_000)
}
func mouseDrag(_ from: CGPoint, _ to: CGPoint, steps: Int = 20) {
    mouseMove(from); usleep(120_000)
    CGEvent(mouseEventSource: HID, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(80_000)
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        CGEvent(mouseEventSource: HID, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(12_000)
    }
    usleep(80_000)
    CGEvent(mouseEventSource: HID, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(100_000)
}

/// 慢速拖拽（对"按住才响应"的控件更可靠，如滑块）
/// 关键：按下后先停 300ms（让控件识别到 grab），每步间隔 30ms，释放前停 200ms
func mouseDragSlow(_ from: CGPoint, _ to: CGPoint, steps: Int = 24) {
    mouseMove(from); usleep(150_000)
    CGEvent(mouseEventSource: HID, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(300_000)                       // 让控件感知到「抓住」
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        CGEvent(mouseEventSource: HID, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(30_000)
    }
    usleep(200_000)                       // 释放前稳定
    CGEvent(mouseEventSource: HID, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(150_000)
}
func scroll(_ pt: CGPoint, _ delta: Int32) {
    mouseMove(pt); usleep(100_000)
    CGEvent(scrollWheelEvent2Source: HID, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
    usleep(200_000)
}

let KEYCODES: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
]
/// 字母/数字/标点 → ANSI 虚拟键码（macOS 的键码**不是**按字母顺序排的：
/// A=0、S=1、D=2、F=3、H=4、G=5、Z=6、X=7、C=8、V=9、B=11 …）。
///
/// ⚠⚠ 这里曾经写的是 `CGKeyCode(大写字母 - 64)`，也就是 A→1、B→2 ——
///   结果 `--key a` 打出的是 "s"、`--key b` 打出的是 "d"，
///   而 `type` 的粘贴路径调的 `keyPress("v", cmd: true)` 实际发的是 **⌘6**：
///   粘贴从来没生效过（只是 AX 通道盖住了这个 bug，一换到 blind 模式就露馅）。
///   2026-10-22 实测：面板输入框粘不进去，就是栽在这。
let ANSI_KEYCODE: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
    "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
]

func keyCode(_ name: String) -> CGKeyCode? {
    let n = name.lowercased()
    if let c = KEYCODES[n] { return c }
    return ANSI_KEYCODE[n]
}
func keyPress(_ name: String, cmd: Bool = false, shift: Bool = false, alt: Bool = false, ctrl: Bool = false) {
    guard let vk = keyCode(name) else { return }
    var flags: CGEventFlags = []
    if cmd { flags.insert(.maskCommand) }
    if shift { flags.insert(.maskShift) }
    if alt { flags.insert(.maskAlternate) }
    if ctrl { flags.insert(.maskControl) }
    let d = CGEvent(keyboardEventSource: HID, virtualKey: vk, keyDown: true)!
    d.flags = flags
    d.post(tap: .cghidEventTap); usleep(60_000)
    let u = CGEvent(keyboardEventSource: HID, virtualKey: vk, keyDown: false)!
    u.flags = flags
    u.post(tap: .cghidEventTap); usleep(60_000)
}
func typeUnicode(_ s: String) {
    for ch in s.unicodeScalars {
        var buf = Array(String(ch).utf16)
        let d = CGEvent(keyboardEventSource: HID, virtualKey: 0, keyDown: true)!
        d.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf)
        d.post(tap: .cghidEventTap); usleep(45_000)
        let u = CGEvent(keyboardEventSource: HID, virtualKey: 0, keyDown: false)!
        u.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf)
        u.post(tap: .cghidEventTap); usleep(45_000)
    }
}
func clipboardSet(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
}
func clipboardGet() -> String { NSPasteboard.general.string(forType: .string) ?? "" }

/// 焦点元素
func focusedElement(_ bundleID: String) -> AXUIElement? {
    guard let ax = appElement(bundleID) else { return nil }
    guard let f = axVal(ax, kAXFocusedUIElementAttribute) else { return nil }
    if CFGetTypeID(f) == AXUIElementGetTypeID() { return f as! AXUIElement }
    return nil
}

// MARK: - 学习缓存

struct Learned: Codable {
    var inputMethod: [String: String] = [:]     // bundleID -> "ax"|"paste"|"unicode"
    var notes: [String: String] = [:]           // bundleID -> 交互模型备注
    var updated: String = ""
}
func loadLearned() -> Learned {
    guard let data = try? Data(contentsOf: LEARN_FILE),
          let l = try? JSONDecoder().decode(Learned.self, from: data) else { return Learned() }
    return l
}
func saveLearned(_ l: Learned) {
    var l = l
    l.updated = ISO8601DateFormatter().string(from: Date())
    try? FileManager.default.createDirectory(at: CACHE_DIR, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(l) { try? data.write(to: LEARN_FILE) }
}

// MARK: - 截图 / 像素

/// 排他捕获某个 app 的主窗口，返回图像 + 窗口在屏幕上的原点
/// （只显示该 app，其余窗口被 exceptingWindows 排除，可绕过 z-order 遮挡）
func captureAppWindow(_ bid: String) -> (CGImage, CGRect)? {
    var result: (CGImage, CGRect)?
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.current
            let wins = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bid && $0.frame.height > 120 && $0.frame.width > 200
            }
            guard let display = content.displays.first else { return }
            let titled = wins.filter { !($0.title ?? "").isEmpty }
            let pool = titled.isEmpty ? wins : titled
            guard let target = pool.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { return }
            let others = content.windows.filter { $0.windowID != target.windowID }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: others)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(display.frame.width) * 2
            cfg.height = Int(display.frame.height) * 2
            cfg.scalesToFit = false
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
            let scale = CGFloat(img.width) / display.frame.width
            let f = target.frame
            result = (img.cropping(to: CGRect(x: f.origin.x * scale, y: f.origin.y * scale,
                                              width: f.width * scale, height: f.height * scale))!,
                      CGRect(origin: f.origin, size: f.size))
        } catch { }
    }
    sem.wait()
    return result
}
func captureDisplay(exceptWindowID: UInt32? = nil) -> (CGImage, CGRect)? {
    var result: (CGImage, CGRect)?
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(display.frame.width) * 2
            cfg.height = Int(display.frame.height) * 2
            cfg.scalesToFit = false
            let filter: SCContentFilter
            if let wid = exceptWindowID {
                let others = content.windows.filter { $0.windowID != wid }
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: others)
            } else {
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            }
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            result = (img, display.frame)
        } catch { }
    }
    sem.wait()
    return result
}

func savePNG(_ img: CGImage, _ path: String) {
    // ⚠ 目录可能不存在（闪控媒体目录首次使用时是空的），先建再写。
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

// ── 统一媒体目录（D-023）─────────────────────────────────────────
// ⚠ 用户原话：「截图和录屏的文件我并不清楚会放在哪个位置」。
//   原来：截图 → /tmp/macctl-shot-<unix时间戳>.png（重启即丢、用户找不到）
//         录屏 → ~/Desktop/闪控录屏/（另一个地方）
//   **两个位置 = 用户找不到 = 功能等于没有。**
//   现在统一到 ~/桌面/闪控/，截图与录屏同目录，中文时间戳文件名。
let MEDIA_DIR = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Desktop/闪控"

/// 中文时间戳文件名，如 `截图-2026年10月22日-02时18分30秒.png`
/// ⚠ 月/日/时/分/秒全部补零：这样按文件名排序 == 按时间排序，
///   这是用户「方便我搜索」的前提（不补零的话 2月 会排在 12月 后面）。
func mediaStamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy年MM月dd日-HH时mm分ss秒"
    return f.string(from: Date())
}

/// 闪控媒体目录里的一个完整文件路径，并保证目录已建好
func mediaPath(_ prefix: String, _ ext: String) -> String {
    try? FileManager.default.createDirectory(atPath: MEDIA_DIR, withIntermediateDirectories: true)
    return "\(MEDIA_DIR)/\(prefix)-\(mediaStamp()).\(ext)"
}

/// 从整屏截图中按屏幕逻辑坐标裁剪（注意 CG 坐标原点在左下，需翻转）
func crop(_ img: CGImage, screenRect: CGRect, displayFrame: CGRect) -> CGImage? {
    let scale = CGFloat(img.width) / displayFrame.width
    // SCK 捕获图像的行序为自上而下，与屏幕坐标同向，直接映射
    let cgRect = CGRect(x: screenRect.origin.x * scale,
                        y: screenRect.origin.y * scale,
                        width: screenRect.width * scale, height: screenRect.height * scale)
    return img.cropping(to: cgRect)
}

func pixels(_ img: CGImage) -> (w: Int, h: Int, buf: [UInt8])? {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}

// MARK: - 命令行解析

struct Args {
    var cmd = ""
    var flags: [String: String] = [:]
    var bools: Set<String> = []
    var positional: [String] = []
    init(_ raw: [String]) {
        let argv = raw.count > 1 ? Array(raw.dropFirst()) : raw
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                // ⚠ 实测踩过（队列 args 全丢的根因）：
                //   原来只要下一个 token 以 "--" 开头就判定它是**新 flag**，
                //   于是 `--args "--to,张三,--msg,你好"` 里的值被当成 flag 丢掉，
                //   flags["args"] 为 nil → list() 返回 [] → 参数全丢 → 脚本空跑。
                //   而队列里存的恰恰就是这种「值本身以 -- 开头」的参数 ——
                //   它是常态，不是特例。
                //
                // 修法：值以 "--" 开头时，只有当它**能被解析成已知 flag 之外的独立选项**
                //   才当新 flag 不可靠；这里改用「显式赋值的 flag 需要值」的规则：
                //   若下一个 token 形如 "--xxx,..."（含逗号），它是列表值而非新 flag。
                let next = i + 1 < argv.count ? argv[i + 1] : nil
                let nextIsListValue = next.map { $0.hasPrefix("--") && $0.contains(",") } ?? false
                if let n = next, !n.hasPrefix("--") || nextIsListValue {
                    flags[key] = n; i += 2
                } else {
                    bools.insert(key); i += 1
                }
            } else if a.hasPrefix("-") && a.count > 1 {
                bools.insert(String(a.dropFirst())); i += 1
            } else {
                positional.append(a); i += 1
            }
        }
        cmd = positional.first ?? "help"
    }
    func str(_ k: String, _ d: String = "") -> String { flags[k] ?? d }
    func has(_ k: String) -> Bool { bools.contains(k) || flags[k] != nil }
    func num(_ k: String, _ d: Double) -> Double { flags[k].flatMap(Double.init) ?? d }
    func int(_ k: String, _ d: Int) -> Int { flags[k].flatMap(Int.init) ?? d }
    func list(_ k: String) -> [String] {
        guard let v = flags[k] else { return [] }
        return v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    func pt(_ k: String) -> CGPoint? {
        guard let v = flags[k] else { return nil }
        let parts = v.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// 输出到 stdout。
/// ⚠ 不要用 print()：Swift 的 print 对超长字符串会分段写入，
///   管道缓冲区满时下游可能只读到前半段（实测：AX 树 JSON 有 10KB 时，
///   `macctl state --json | python` 偶发只读到 9.8KB 甚至 0 字节）。
///   改用 FileHandle 一次性原子写入，彻底消除截断。
/// 全局输出文件（由 --out 指定）。非 nil 时 out() 写文件而非 stdout。
/// 用途：大 JSON 输出走管道时会被截断（Swift FileHandle 写管道 + 下游提前读会丢数据），
///      用 --out 落盘可完全规避。
var gOutFile: String? = nil
/// 常驻写句柄。⚠ 必须在进程启动时打开一次并定位到文件头：
///   若每次 out() 都重新 FileHandle(forWritingAtPath:) 打开，句柄默认定位在**末尾**，
///   而 out() 会被多次调用（诊断头 + JSON 主体）→ 产生 "Extra data: line 2" 的
///   损坏JSON（实测踩过：同一路径复用时被上一次的内容污染）。
var gOutHandle: FileHandle? = nil

func out(_ s: String = "") {
    var data = Data(s.utf8)
    data.append(0x0A)  // 换行
    if gOutHandle != nil {
        gOutHandle?.write(data)
    } else {
        FileHandle.standardOutput.write(data)
    }
}

/// 打开 --out 目标文件：截断已有内容 + 建立常驻句柄。必须只调用一次。
func outFileOpen(_ path: String) {
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let h = FileHandle(forWritingAtPath: path) else { return }
    h.truncateFile(atOffset: 0)   // 关键：清空旧内容，避免复用路径时叠加
    gOutHandle = h
    gOutFile = path
}

// MARK: - locate：四级降级定位阶梯
//
// 为什么需要（实测，2026-10-21）：
//   微信 4.x 搜索框是自绘控件，AX 树里只有占位元素，AXPress 无效、拿不到焦点。
//   曾经把它判为「应用侧限制，绕不过」—— 那只是**AX 这一条路**走不通。
//   实测 OCR 能精确找到它：'搜索' @(841,64) conf=1.00，点击后即可输入。
//
// 四级阶梯（按可靠性排序，逐级降级，每级都比上一级慢/脆）：
//   L1 AX   —— 读无障碍树。最快最准，但自绘控件拿不到。
//   L2 OCR  —— 截图 + Vision 识别。慢几百 ms，但什么界面都能认。
//   L3 CDP  —— Electron 应用的 DOM 层。仅对确认支持的应用有效（微信已验证不支持，D-015）。
//   L4 坐标 —— 纯像素。永远可用，但最脆弱，只在文本匹配不上时兜底。
//
// ⚠ 关键设计：**降级不是「失败兜底」，而是主路径的一部分。**
//   过去的行为是「AX 找不到 → 报元素不存在」，让上层误以为是业务问题。
//   现在 AX 找不到会自动往下走，只有全部走完才报，并说清每一级为什么失败。

/// 单个定位结果
struct Located {
    var x: Double, y: Double
    var level: String      // "ax" / "ocr" / "cdp"
    var confidence: Double
    var role: String
    var text: String
    var elapsedMs: Int
}

func cmdLocate() {
    let a = Args(ARGV)
    let text = a.str("text").isEmpty ? a.positional.first ?? "" : a.str("text")
    guard !text.isEmpty else { die("需要 --text <要定位的文字>") }
    let scope = a.str("app")
    let asJSON = a.has("json")
    // ⚠ OCR 的字符集重合度对短文本几乎总能算出一个非零分
    //   （实测「这个文字绝对不存在xyz」→「文件传输助手」= 0.04）。
    //   不设下限就会瞎指一个元素然后误点 —— 这比报「找不到」危险得多。
    //   默认 0.30：要求至少三成相似度才认。
    let minConf = Double(a.str("min-conf")) ?? 0.30
    // --only ax|ocr 限定只走某一级（调试用）
    let only = a.str("only")

    let bids: [String]
    if scope == "all" {
        bids = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    } else if scope.isEmpty {
        bids = [frontApp()?.bundleIdentifier ?? ""]
    } else {
        bids = [resolveBundle(scope) ?? scope]
    }

    let t0 = Date()
    var tried: [String] = []   // 每一级尝试过什么、为什么失败

    // ── L1: AX 树 ────────────────────────────────────────────────
    // 最快最准。放在第一位，多数情况一步到位。
    if only.isEmpty || only == "ax" {
        var best: Located? = nil
        for b in bids where !b.isEmpty {
            guard let ax = appElement(b) else { continue }
            var nodes: [Node] = []
            for w in windows(of: ax) { walk(w, 0, 40, &nodes) }
            if nodes.isEmpty {
                tried.append("L1 ax: \(b) 的 AX 树为 0 节点（窗口被遮挡或正在重排）")
                continue
            }
            let ms = findNodes(nodes, text: text, role: a.flags["role"])
            if let m = ms.first {
                let n = m.node
                // ⚠ findNodes 的 score 是**整数百分制**：title 全等 +100，
                //   面积偏好再加最多 20 → 上限约 120。不归一化就会出现 conf=120。
                let norm = min(1.0, Double(m.score) / 120.0)
                let cand = Located(x: n.pos.x + n.size.width / 2,
                                   y: n.pos.y + n.size.height / 2,
                                   level: "ax", confidence: norm,
                                   role: n.role,
                                   text: firstLine(n.text.isEmpty ? n.desc : n.text),
                                   elapsedMs: Int(Date().timeIntervalSince(t0) * 1000))
                if best == nil || cand.confidence > best!.confidence { best = cand }
            }
        }
        if let b = best {
            return emitLocated([b], tried: tried, asJSON: asJSON, totalMs: Int(Date().timeIntervalSince(t0) * 1000))
        }
        if !tried.contains(where: { $0.hasPrefix("L1") }) {
            tried.append("L1 ax: 树里有节点，但没有元素匹配「\(text)」")
        }
    }

    // ── L2: OCR（自绘控件的唯一出路）────────────────────────────────
    // 实测 414ms，且 --app 排他捕获**不需要屏幕录制授权**。
    if only.isEmpty || only == "ocr" {
        for b in bids where !b.isEmpty {
            guard let (img, org) = captureAppWindow(b) else {
                tried.append("L2 ocr: \(b) 窗口捕获失败")
                continue
            }
            let items = ocrItems(img)
            if items.isEmpty {
                tried.append("L2 ocr: \(b) 窗口内没识别到任何文字")
                continue
            }
            // Vision 的 bbox 是「图像归一化坐标 + 左下原点」，
            // 屏幕是「像素 + 左上原点」，两处都要翻（D-016 踩过）。
            let iw = Double(img.width), ih = Double(img.height)
            let scale = iw / max(1, org.width)
            var best: Located? = nil
            for (t, bb, conf) in items {
                let norm = fuzzyMatch(t, text)
                guard norm > 0 else { continue }
                // 置信度取「识别置信度」与「文本匹配度」的乘积：
                // 只认得清但文本不符，或文本相符但认得糊，都不该赢。
                let score = Double(conf) * norm
                guard score >= minConf else { continue }
                let cx = org.origin.x + (bb.midX * iw) / scale
                let cy = org.origin.y + (ih - bb.midY * ih) / scale
                let cand = Located(x: cx, y: cy, level: "ocr",
                                   confidence: score, role: "AXUnknown",
                                   text: t,
                                   elapsedMs: Int(Date().timeIntervalSince(t0) * 1000))
                if best == nil || cand.confidence > best!.confidence { best = cand }
            }
            if let b = best {
                return emitLocated([b], tried: tried, asJSON: asJSON,
                                   totalMs: Int(Date().timeIntervalSince(t0) * 1000))
            }
            tried.append("L2 ocr: \(b) 识别到 \(items.count) 个文本块，但没有匹配「\(text)」")
        }
    }

    // ── L3: CDP（仅 Electron 应用，且该应用确认支持）──────────────────
    // ⚠ 实测微信是 CEF 但主动过滤了 --remote-debugging-port，此路不通（D-015）。
    //   所以这里**不自动尝试**——自动尝试只会白等几秒然后失败。
    //   需要时显式 --cdp-port <port>，由调用方确认该应用支持。
    if !a.str("cdp-port").isEmpty {
        // 收到参数但**不实现**：实测微信是 CEF 却主动过滤调试端口（D-015），
        // 自动尝试只会白等几秒。诚实告知，别让调用方误以为已生效。
        tried.append("L3 cdp: 未实现——CDP 穿透需应用侧开放调试端口，微信已验证拒绝（D-015）")
    }

    // 全部走完
    if asJSON {
        var parts: [String] = []
        for t in tried { parts.append("{\"stage\":\(jesc(t))}") }
        out("{\"ok\":false,\"error\":\"NOT_FOUND\",\"text\":\(jesc(text)),"
            + "\"tried\":[\(parts.joined(separator: ","))],"
            + "\"elapsed_ms\":\(Int(Date().timeIntervalSince(t0) * 1000))}")
    } else {
        out("未找到「\(text)」——已尝试：")
        for t in tried { out("  · \(t)") }
        out("提示：控件可能自绘且当前不可见 → 确认窗口在前台，或先用 raise/dock 置前")
    }
}

/// 取第一行并限长 60 字符。
/// AX 的 AXStaticText 经常把整条列表项（含换行）塞进 text，
/// 直接输出会把终端刷满（实测微信会话列表就是这样）。
func firstLine(_ s: String) -> String {
    let l = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
    return l.count <= 60 ? l : String(l.prefix(60)) + "…"
}

/// 模糊匹配：返回 0（不匹配）或一个相似度分。
/// OCR 会把「搜索」认成「搜索」「搜索 」甚至「搜 索」，所以不能要求全等。
func fuzzyMatch(_ s: String, _ t: String) -> Double {
    let a = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let b = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if a.isEmpty || b.isEmpty { return 0 }
    if a == b { return 1.0 }
    // 双向包含：OCR 常见的「超集」情况（识别出「搜索框」而目标是「搜索」）
    if a.contains(b) || b.contains(a) {
        let ratio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        return 0.70 + 0.28 * ratio
    }
    // 字符集重合度：应对 OCR 认错个别字（「搜索」vs「搜素」）。
    // ⚠ 长度差异过大时直接判0：目标 15 字、候选 6 字，
    //   字符集偶然重合是必然的，继续算分只会制造假阳性。
    if a.count >= 2 && b.count >= 2 {
        let shortLen = min(a.count, b.count), longLen = max(a.count, b.count)
        if Double(shortLen) / Double(longLen) < 0.5 { return 0 }
    }
    let sa = Set(a), sb = Set(b)
    let inter = Double(sa.intersection(sb).count)
    let union = Double(sa.union(sb).count)
    return union > 0 ? (inter / union) * 0.6 : 0
}

/// 输出定位结果
func emitLocated(_ rs: [Located], tried: [String], asJSON: Bool, totalMs: Int) {
    if asJSON {
        var parts: [String] = []
        for r in rs {
            parts.append("{\"ok\":true,\"x\":\(jnum(r.x)),\"y\":\(jnum(r.y)),"
                       + "\"level\":\(jesc(r.level)),\"confidence\":\(jnum(r.confidence)),"
                       + "\"role\":\(jesc(r.role)),\"text\":\(jesc(r.text)),"
                       + "\"elapsed_ms\":\(r.elapsedMs)}")
        }
        out("[\(parts.joined(separator: ","))]")
    } else {
        for r in rs {
            out("'\(r.text)' @(\(Int(r.x)),\(Int(r.y))) via=\(r.level) conf=\(String(format: "%.2f", r.confidence)) \(r.elapsedMs)ms")
        }
    }
}

// MARK: - JSON 输出（供闪控等上层脚本精确解析）

/// JSON 字符串转义
func jesc(_ s: String) -> String {
    var o = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += "\\n"
        case "\r": o += "\\r"
        case "\t": o += "\\t"
        default:
            if ch.value < 0x20 {
                o += String(format: "\\u%04x", ch.value)
            } else {
                o.unicodeScalars.append(ch)
            }
        }
    }
    return "\"" + o + "\""
}

/// JSON 数值（整数或小数）
func jnum(_ v: Double) -> String {
    if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
    return String(v)
}

/// AX 节点 → JSON 对象
func jnode(_ n: Node) -> String {
    return "{\"role\":\(jesc(n.role)),\"title\":\(jesc(n.title)),\"desc\":\(jesc(n.desc)),"
         + "\"value\":\(jesc(n.value)),\"text\":\(jesc(n.text)),"
         + "\"x\":\(jnum(n.pos.x)),\"y\":\(jnum(n.pos.y)),"
         + "\"w\":\(jnum(n.size.width)),\"h\":\(jnum(n.size.height))}"
}
func die(_ s: String) -> Never {
    FileHandle.standardError.write(("macctl: " + s + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - 目标定位

struct Match {
    let node: Node
    let score: Int
}

/// 在 AX 树中按文本查找节点（多策略打分）
func findNodes(_ nodes: [Node], text: String, role: String? = nil) -> [Match] {
    let t = text.lowercased()
    var out: [Match] = []
    for n in nodes {
        if let r = role, n.role != r { continue }
        let title = n.title.lowercased(), desc = n.desc.lowercased(), val = n.value.lowercased()
        var score = 0
        if n.title == text { score += 100 }
        else if n.title.lowercased() == t { score += 100 }
        else if n.title.contains(text) { score += 60 }
        else if n.desc.contains(text) { score += 45 }
        else if n.value.contains(text) { score += 35 }
        else if n.text.contains(text) { score += 25 }
        if score > 0 {
            // 偏好小而精确的元素
            let area = n.size.width * n.size.height
            score += area > 0 ? max(0, 20 - Int(area / 4000)) : 0
            out.append(Match(node: n, score: score))
        }
    }
    return out.sorted { $0.score > $1.score }
}

/// 找一个元素是否存在（用于变更检测）
func signature(_ bundleID: String) -> String {
    guard let ax = appElement(bundleID) else { return "" }
    var parts: [String] = []
    for w in windows(of: ax) {
        let n = node(w)
        parts.append("\(n.title)@\(Int(n.pos.x)),\(Int(n.pos.y))")
    }
    if let f = focusedElement(bundleID) {
        let n = node(f)
        parts.append("focus:\(n.role):\(n.title)")
    }
    parts.append("count:\(treeNodes(bundleID: bundleID, maxDepth: 3).count)")
    return parts.joined(separator: "|")
}

// MARK: - 命令实现

func cmdApps() {
    if ARGV.contains("--json") {
        var arr: [String] = []
        for app in NSWorkspace.shared.runningApplications.sorted(by: { $0.localizedName ?? "" < $1.localizedName ?? "" }) {
            guard app.bundleIdentifier != nil, app.activationPolicy == .regular else { continue }
            arr.append("{\"name\":\(jesc(app.localizedName ?? "?")),\"bundle\":\(jesc(app.bundleIdentifier ?? "")),"
                + "\"pid\":\(app.processIdentifier),\"active\":\(app.isActive),\"hidden\":\(app.isHidden)}")
        }
        out("{\"count\":\(arr.count),\"apps\":[\(arr.joined(separator: ","))]}")
        return
    }
    out("=== 运行中的应用 ===")
    for app in NSWorkspace.shared.runningApplications.sorted(by: { $0.localizedName ?? "" < $1.localizedName ?? "" }) {
        guard app.bundleIdentifier != nil, app.activationPolicy == .regular else { continue }
        out("  \(app.localizedName ?? "?")\t\(app.bundleIdentifier ?? "")\tpid=\(app.processIdentifier)\tactive=\(app.isActive)\thidden=\(app.isHidden)")
    }
}

func cmdWindows() {
    let a = Args(ARGV)
    let bid = a.str("app")
    let list = bid.isEmpty ? NSWorkspace.shared.runningApplications.map { $0.bundleIdentifier } : [bid]
    for b in list {
        guard let b = b, let ax = appElement(b) else { continue }
        let ws = windows(of: ax)
        guard !ws.isEmpty else { continue }
        out("=== \(b) (\(ws.count) 窗口) ===")
        for (i, w) in ws.enumerated() {
            let n = node(w)
            out("  #\(i) '\(n.title)' @(\(Int(n.pos.x)),\(Int(n.pos.y))) \(Int(n.size.width))x\(Int(n.size.height))")
        }
    }
}

func cmdState() {
    let a = Args(ARGV)
    let fa = frontApp()
    if a.has("json") {
        let bid0 = a.str("app").isEmpty ? (fa?.bundleIdentifier ?? "") : a.str("app")
        let b0 = resolveBundle(bid0) ?? bid0
        var winJ: [String] = []
        if let ax = appElement(b0) {
            for (i, w) in windows(of: ax).enumerated() {
                let n = node(w)
                winJ.append("{\"i\":\(i),\"title\":\(jesc(n.title)),\"x\":\(jnum(n.pos.x)),\"y\":\(jnum(n.pos.y)),\"w\":\(jnum(n.size.width)),\"h\":\(jnum(n.size.height))}")
            }
        }
        let nodes0 = treeNodes(bundleID: b0, maxDepth: a.int("depth", 6))
        let filt0 = a.str("text")
        let shown0 = filt0.isEmpty ? nodes0 : nodes0.filter { $0.text.contains(filt0) }
        var focusJ = "null"
        if let f = focusedElement(b0) { focusJ = jnode(node(f)) }
        out("{\"front_app\":\(jesc(fa?.localizedName ?? "")),\"front_bundle\":\(jesc(fa?.bundleIdentifier ?? "")),"
            + "\"app\":\(jesc(b0)),\"windows\":[\(winJ.joined(separator: ","))],"
            + "\"ax_count\":\(nodes0.count),\"nodes\":[\(shown0.map { jnode($0) }.joined(separator: ","))],"
            + "\"focus\":\(focusJ)}")
        return
    }
    out("=== 前台应用 ===")
    if let fa = fa {
        out("  \(fa.localizedName ?? "?")  bundle=\(fa.bundleIdentifier ?? "?")  pid=\(fa.processIdentifier)")
    }
    let bid = a.str("app").isEmpty ? (fa?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用: \(bid)") }
    out("=== 窗口 (\(b)) ===")
    if let ax = appElement(b) {
        for (i, w) in windows(of: ax).enumerated() {
            let n = node(w)
            out("  #\(i) '\(n.title)' @(\(Int(n.pos.x)),\(Int(n.pos.y))) \(Int(n.size.width))x\(Int(n.size.height))")
        }
    }
    let nodes = treeNodes(bundleID: b, maxDepth: a.int("depth", 6))
    if nodes.isEmpty {
        out("=== AX 树 (0 节点) ===")
        out("  ⚠ 该 app 当前 AX 树为空，通常是被其他窗口遮挡。")
        out("  → 先 `macctl front --app \(b)` 置前，或用 `macctl diagnose --app \(b)` 查遮挡者")
    } else {
    out("=== AX 树 (\(nodes.count) 节点, depth<=\(a.int("depth", 6))) ===")
    let filt = a.str("text")
    for n in nodes {
        if !filt.isEmpty && !n.text.contains(filt) { continue }
        out("  [\(n.role)] '\(n.text.prefix(70))' @(\(Int(n.pos.x)),\(Int(n.pos.y))) \(Int(n.size.width))x\(Int(n.size.height))")
    }
    }
    if let f = focusedElement(b) {
        let n = node(f)
        out("=== 焦点 === [\(n.role)] '\(n.text.prefix(50))' @(\(Int(n.pos.x)),\(Int(n.pos.y)))")
    }
    let shot = a.str("shot")
    if !shot.isEmpty {
        if let (img, frame) = captureDisplay() {
            savePNG(img, shot); out("截图 -> \(shot)")
        }
    }
}

func cmdTree() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用: \(bid)") }
    var nodes = treeNodes(bundleID: b, maxDepth: a.int("depth", 40))
    if let r = a.flags["role"] { nodes = nodes.filter { $0.role == r } }
    if let t = a.flags["text"] { nodes = nodes.filter { $0.text.contains(t) } }
    if a.has("json") {
        out("{\"app\":\(jesc(b)),\"count\":\(nodes.count),\"nodes\":[\(nodes.map { jnode($0) }.joined(separator: ","))]}")
        return
    }
    out("=== \(b) 节点 \(nodes.count) ===")
    for (i, n) in nodes.enumerated() {
        out("  [\(i)] [\(n.role)] '\(n.text.prefix(70))' @(\(Int(n.pos.x)),\(Int(n.pos.y))) \(Int(n.size.width))x\(Int(n.size.height))")
    }
}

func cmdFind() {
    let a = Args(ARGV)
    let text = a.str("text").isEmpty ? a.positional.first ?? "" : a.str("text")
    guard !text.isEmpty else { die("需要 --text") }
    let scope = a.str("app")
    let bids: [String]
    if scope == "all" {
        bids = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    } else if scope.isEmpty {
        bids = [frontApp()?.bundleIdentifier ?? ""]
    } else {
        bids = [resolveBundle(scope) ?? scope]
    }
    let asJSON = a.has("json")
    var allJSON: [String] = []
    for b in bids {
        guard !b.isEmpty, let ax = appElement(b) else { continue }
        var nodes: [Node] = []
        for w in windows(of: ax) { walk(w, 0, a.int("depth", 40), &nodes) }
        let ms = findNodes(nodes, text: text, role: a.flags["role"])
        if asJSON {
            for m in ms.prefix(a.int("limit", 10)) {
                let n = m.node
                let cx = n.pos.x + n.size.width / 2
                let cy = n.pos.y + n.size.height / 2
                allJSON.append("{\"app\":\(jesc(b)),\"score\":\(m.score),\"role\":\(jesc(n.role)),"
                    + "\"title\":\(jesc(n.title)),\"desc\":\(jesc(n.desc)),\"value\":\(jesc(n.value)),"
                    + "\"text\":\(jesc(n.text)),\"x\":\(jnum(n.pos.x)),\"y\":\(jnum(n.pos.y)),"
                    + "\"w\":\(jnum(n.size.width)),\"h\":\(jnum(n.size.height)),"
                    + "\"cx\":\(jnum(cx)),\"cy\":\(jnum(cy))}")
            }
            continue
        }
        guard !ms.isEmpty else { continue }
        out("=== \(b) 命中 \(ms.count) ===")
        for (i, m) in ms.prefix(a.int("limit", 10)).enumerated() {
            out("  [\(i)] score=\(m.score) [\(m.node.role)] '\(m.node.text.prefix(60))' @(\(Int(m.node.pos.x)),\(Int(m.node.pos.y))) \(Int(m.node.size.width))x\(Int(m.node.size.height))")
        }
    }
    if asJSON {
        out("{\"count\":\(allJSON.count),\"hits\":[\(allJSON.joined(separator: ","))]}")
    }
}

func cmdClick() {
    let a = Args(ARGV)
    if let pt = a.pt("at") {
        mouseClick(pt, count: a.int("count", 1))
        if a.has("json") {
            out("{\"ok\":true,\"method\":\"quartz\",\"role\":\"\",\"text\":\"\",\"x\":\(jnum(pt.x)),\"y\":\(jnum(pt.y))}")
        } else {
            out("点击 (\(Int(pt.x)),\(Int(pt.y)))")
        }
        return
    }
    let text = a.str("text").isEmpty ? a.positional.first ?? "" : a.str("text")
    guard !text.isEmpty else { die("需要 --text 或 --at") }
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用: \(bid)") }

    var nodes: [Node] = []
    if let ax = appElement(b) { for w in windows(of: ax) { walk(w, 0, 40, &nodes) } }
    var ms = findNodes(nodes, text: text, role: a.flags["role"])
    if ms.isEmpty && a.int("scroll", 0) > 0 {
        // 滚动查找：优先在会话/列表区域滚动
        for _ in 0..<a.int("scroll", 0) {
            let list = nodes.filter { $0.role == "AXList" && $0.size.height > 100 }
            let target = list.first ?? nodes.first { $0.size.height > 100 }
            if let t = target {
                scroll(CGPoint(x: t.pos.x + t.size.width / 2, y: t.pos.y + t.size.height / 2), -3)
                usleep(400_000)
            }
            nodes = []
            if let ax = appElement(b) { for w in windows(of: ax) { walk(w, 0, 40, &nodes) } }
            ms = findNodes(nodes, text: text, role: a.flags["role"])
            if !ms.isEmpty { break }
        }
    }
    guard let m = ms.first else {
        if a.has("json") { out("{\"ok\":false,\"error\":\"未找到文本 \(jesc(text))\"}"); exit(1) }
        die("未找到文本 '\(text)'")
    }
    let n = m.node
    // 优先 AXPress，无效则真实点击
    let before = signature(b)
    var pressed = false
    if n.role == "AXButton" || n.role == "AXMenuItem" || n.role == "AXCheckBox" {
        let r = AXUIElementPerformAction(n.el, kAXPressAction as CFString)
        pressed = (r == .success)
    }
    usleep(500_000)
    let after = signature(b)
    var method = "axpress"
    var clickedPt = n.center
    if !pressed || before == after {
        // 真实鼠标点击：文本类元素点在偏左文字处，按钮点中心
        let pt: CGPoint
        if n.role == "AXStaticText" || n.role == "AXTextArea" {
            pt = CGPoint(x: n.pos.x + min(24, n.size.width / 2), y: n.pos.y + n.size.height / 2)
        } else {
            pt = n.center
        }
        mouseClick(pt, count: a.int("count", 1))
        method = "quartz"
        clickedPt = pt
        if !a.has("json") { out("真实点击 \(Int(pt.x)),\(Int(pt.y)) [\(n.role)] '\(n.text.prefix(40))'") }
    } else if !a.has("json") {
        out("AXPress 成功 [\(n.role)] '\(n.text.prefix(40))'")
    }
    if a.has("json") {
        out("{\"ok\":true,\"method\":\(jesc(method)),\"role\":\(jesc(n.role)),\"text\":\(jesc(n.text)),"
            + "\"x\":\(jnum(clickedPt.x)),\"y\":\(jnum(clickedPt.y))}")
    }
}

func cmdType() {
    let a = Args(ARGV)
    var text = a.str("text")
    if text.isEmpty { text = a.positional.joined(separator: " ") }
    guard !text.isEmpty else { die("需要 --text") }
    // --blind：打给「当前焦点」，不去解析目标 App。
    // ⚠ 为什么需要：闪控面板自己是裸二进制（没有 bundle id），
    //   普通路径的第一步「定位应用」就会失败 —— 面板的输入框恰恰要靠它来测。
    //   blind 模式只做「剪贴板 + ⌘V」，不校验内容（读不到就没法校验，如实说明）。
    let blind = a.has("blind")
    let bid = blind ? "" : (a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app"))
    let b: String
    if blind {
        b = ""
    } else {
        guard let r = resolveBundle(bid) else { die("无法定位应用: \(bid)") }
        b = r
    }

    var learned = loadLearned()
    var order: [String]
    if blind {
        // blind 走 Unicode 注入：不碰剪贴板、不依赖 ⌘V，重复执行也不会双份
        order = ["unicode"]
    } else if let m = learned.inputMethod[b] {
        order = [m]
        for alt in ["ax", "paste", "unicode"] where alt != m { order.append(alt) }
    } else {
        order = ["ax", "paste", "unicode"]
    }

    func readFocused() -> String {
        guard let f = focusedElement(b) else { return "" }
        return axStr(f, kAXValueAttribute) + "|" + axStr(f, kAXTitleAttribute)
    }

    for method in order {
        switch method {
        case "ax":
            guard let f = focusedElement(b) else { continue }
            let r = AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, text as CFTypeRef)
            usleep(400_000)
            if r == .success && readFocused().contains(text.prefix(4)) {
                learned.inputMethod[b] = "ax"; saveLearned(learned)
                if a.has("json") { out("{\"ok\":true,\"method\":\"ax\",\"text\":\(jesc(text))}") }
                else { out("✓ AX setValue 成功: '\(text)'") }
                return
            }
        case "paste":
            clipboardSet(text)
            keyPress("v", cmd: true)
            usleep(600_000)
            if blind {
                if a.has("json") { out("{\"ok\":true,\"method\":\"paste-blind\",\"text\":\(jesc(text))}") }
                else { out("✓ 已粘贴到当前焦点（blind 模式，未校验）") }
                return
            }
            let cur = readFocused()
            if cur.isEmpty || cur.contains(text.prefix(4)) {
                learned.inputMethod[b] = "paste"; saveLearned(learned)
                if a.has("json") { out("{\"ok\":true,\"method\":\"paste\",\"text\":\(jesc(text))}") ; return }
                out("✓ 剪贴板粘贴成功: '\(text)'"); return
            }
        case "unicode":
            typeUnicode(text)
            usleep(600_000)
            if blind {
                if a.has("json") { out("{\"ok\":true,\"method\":\"unicode-blind\",\"text\":\(jesc(text))}") }
                else { out("✓ 已注入到当前焦点（blind 模式，未校验）") }
                return
            }
            let cur = readFocused()
            if cur.isEmpty || cur.contains(text.prefix(4)) {
                learned.inputMethod[b] = "unicode"; saveLearned(learned)
                if a.has("json") { out("{\"ok\":true,\"method\":\"unicode\",\"text\":\(jesc(text))}") }
                else { out("✓ Unicode 注入成功: '\(text)'") }
                return
            }
        default: break
        }
    }
    if a.has("json") { out("{\"ok\":false,\"error\":\"所有输入方式均未确认成功\",\"text\":\(jesc(text))}") }
    else { out("⚠ 所有输入方式均未确认成功: '\(text)'") }
    exit(2)
}

/// 清空聚焦的输入框（AX setValue 空串，失败则退化为 cmd+a + delete）
func cmdClear() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用: \(bid)") }
    var method = "none"
    if let f = focusedElement(b) {
        let r = AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, "" as CFTypeRef)
        usleep(300_000)
        let now = axStr(f, kAXValueAttribute)
        if r == .success && now.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            method = "ax"
        }
    }
    if method == "none" {
        keyPress("a", cmd: true)
        usleep(200_000)
        keyPress("delete")
        usleep(300_000)
        method = "quartz"
    }
    if a.has("json") {
        out("{\"ok\":true,\"method\":\(jesc(method)),\"app\":\(jesc(b))}")
    } else {
        out("清空输入框 [\(method)]")
    }
}

func cmdKey() {
    let a = Args(ARGV)
    let name = a.str("key").isEmpty ? a.positional.first ?? "" : a.str("key")
    guard !name.isEmpty else { die("需要 --key") }
    let n = a.int("count", 1)
    for _ in 0..<n {
        keyPress(name, cmd: a.has("cmd"), shift: a.has("shift"), alt: a.has("alt"), ctrl: a.has("ctrl"))
        usleep(120_000)
    }
    out("按键 \(name) x\(n)")
}

/// 合成"修饰键组合"事件（flagsChanged）。
///
/// ⚠ 为什么需要：`macctl key` 发的是 keyDown/keyUp，而「纯修饰键热键」
///   （例如 ⌃⌥⌘ 三键同按）只能从 **flagsChanged** 里看出来 —— 没有这个命令，
///   这种热键就无法自测，只能靠人肉按，坏了也说不清。
func cmdMods() {
    let a = Args(ARGV)
    var f: CGEventFlags = []
    if a.has("ctrl") { f.insert(.maskControl) }
    if a.has("alt") { f.insert(.maskAlternate) }
    if a.has("cmd") { f.insert(.maskCommand) }
    if a.has("shift") { f.insert(.maskShift) }
    guard !f.isEmpty else { die("至少要给一个修饰键，例如 --ctrl --alt --cmd") }

    /// 按位"逐个叠加"，模拟人一根一根按下去，最后全部松开
    func post(_ flags: CGEventFlags) {
        let e = CGEvent(source: HID)
        e?.type = .flagsChanged
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(80_000)
    }
    let order: [CGEventFlags] = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    var acc: CGEventFlags = []
    for bit in order where f.contains(bit) {
        acc.insert(bit)
        post(acc)
    }
    usleep(120_000)
    post([])            // 松开
    out("已合成修饰键：\(f.rawValue)")
}

func cmdVolume() {
    let a = Args(ARGV)
    // 静音控制：--mute on|off|toggle
    if let m = a.flags["mute"] {
        let want: Bool
        switch m.lowercased() {
        case "on", "true", "1", "yes": want = true
        case "off", "false", "0", "no": want = false
        case "toggle": want = !(currentMuted())
        default: die("--mute 只接受 on|off|toggle")
        }
        let s = NSAppleScript(source: "set volume output muted \(want)")
        s?.executeAndReturnError(nil)
        // ⚠ 条件等待代替固定 sleep（D-014）：原来硬编码 usleep(300_000)，
        //   实测单次 volume 调用 450ms，其中 300ms 是纯盲等。
        //   改为「轮询到目标状态即返回」，典型 1-2 轮（~40-80ms）。
        var settled = false
        for _ in 0..<10 {
            usleep(40_000)
            if currentMuted() == want { settled = true; break }
        }
        let note = settled ? "" : "，注意：状态未在 400ms 内确认"
        out("系统静音 -> \(want ? "开" : "关")  (静音=\(currentMuted())\(note))")
        return
    }
    if let v = a.flags["set"] {
        let iv = max(0, min(100, Int(v) ?? 0))
        let script = NSAppleScript(source: "set volume output volume \(iv)")
        script?.executeAndReturnError(nil)
        var reached = false
        for _ in 0..<10 {
            usleep(40_000)
            if currentVolume() == iv { reached = true; break }
        }
        let note = reached ? "" : "，注意：音量未在 400ms 内确认"
        out("系统音量 -> \(iv)  (静音=\(currentMuted())\(note))")
    } else {
        let cv = currentVolume()
        if ARGV.contains("--json") {
            out("{\"ok\":true,\"volume\":\(cv),\"muted\":\(currentMuted())}")
        } else {
            out("系统音量 = \(cv)  静音=\(currentMuted())")
        }
    }
}

/// 当前系统输出音量（0-100）
func currentVolume() -> Int {
    let r = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(nil)
    return max(0, min(100, Int(r?.stringValue ?? "0") ?? 0))
}

func currentMuted() -> Bool {
    let r = NSAppleScript(source: "output muted of (get volume settings)")?.executeAndReturnError(nil)
    return (r?.stringValue ?? "false") == "true"
}

/// 找应用内音量滑块
func findAppVolumeSlider(_ b: String) -> Node? {
    let nodes = treeNodes(bundleID: b, maxDepth: 40)
    if let n = nodes.first(where: { $0.role == "AXSlider" }) { return n }
    return nil
}

/// 播放条最底一排的小图标按钮（自适应用「最底行」而非固定条带，避开窗口边缘误差）
/// 排除有名字的按钮（如"取消收藏"），防止误触收藏/列表
func bottomRowButtons(_ b: String) -> [Node] {
    let nodes = treeNodes(bundleID: b, maxDepth: 40)
    guard let w = nodes.first(where: { $0.role == "AXWindow" && $0.size.width > 300 })
    else { return [] }
    let minX = w.pos.x + w.size.width * 0.55
    let minY = w.pos.y + w.size.height * 0.70
    var pool = nodes.filter {
        $0.role == "AXButton" && $0.title.isEmpty &&
        $0.size.width <= 44 && $0.size.height <= 44 &&
        $0.pos.x > minX && $0.pos.y > minY
    }
    guard !pool.isEmpty else { return [] }
    let maxRowY = pool.map { $0.pos.y }.max()!
    pool = pool.filter { abs($0.pos.y - maxRowY) <= 14 }
    return pool.sorted { $0.pos.x < $1.pos.x }
}

func cmdAppVolume() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用: \(bid)") }
    let target = a.int("to", 70)

    // 策略 1：原生 AXSlider
    if let s = findAppVolumeSlider(b) {
        let maxV = (axVal(s.el, kAXMaxValueAttribute) as? Double) ?? 100
        let minV = (axVal(s.el, kAXMinValueAttribute) as? Double) ?? 0
        let want = minV + (maxV - minV) * Double(target) / 100.0
        let r = AXUIElementSetAttributeValue(s.el, kAXValueAttribute as CFString, want as CFTypeRef)
        usleep(400_000)
        let got = (axVal(s.el, kAXValueAttribute) as? Double) ?? -1
        out("AXSlider 音量 -> \(Int(got))% (目标 \(target)%, raw=\(r.rawValue))")
        if abs(got - want) < 2 { return }
    }

    // 策略 2：音量气泡 + 像素几何 + 闭环校正
    // 找 % 文本
    func readPct() -> (Int, CGPoint)? {
        let nodes = treeNodes(bundleID: b, maxDepth: 40)
        for n in nodes where n.title.hasSuffix("%") && n.title.count <= 4 && Int(n.title.dropLast()) != nil {
            return (Int(n.title.dropLast())!, n.pos)
        }
        return nil
    }
    var pct = readPct()
    if pct == nil {
        // 打开气泡：点击播放条右下角按钮，逐个试探
        let nodes = treeNodes(bundleID: b, maxDepth: 40)
        let win = nodes.first { $0.role == "AXWindow" }
        let cands = nodes.filter {
            $0.role == "AXButton" && win != nil &&
            $0.pos.y > win!.pos.y + win!.size.height * 0.8 &&
            $0.pos.x > win!.pos.x + win!.size.width * 0.6
        }.sorted { $0.pos.x < $1.pos.x }
        for c in cands {
            mouseClick(c.center); usleep(900_000)
            if readPct() != nil { break }
        }
        pct = readPct()
    }
    guard var (curPct, _) = pct else { die("未找到应用内音量控件") }
    out("当前应用音量 = \(curPct)%")

    // 像素定位蓝色滑条
    guard let (img, frame) = captureDisplay() else { die("截图失败") }
    guard let px = pixels(img) else { die("像素读取失败") }
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    for y in 0..<px.h {
        for x in 0..<px.w {
            let i = (y * px.w + x) * 4
            let r = Int(px.buf[i]), g = Int(px.buf[i + 1]), b = Int(px.buf[i + 2])
            if b > 170 && r < 140 && b - r > 80 && g > 100 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX > 0 else { die("未在屏幕上找到蓝色音量滑条") }
    let scale = CGFloat(px.w) / frame.width
    // CG 图像 y 原点在底部 -> 转为屏幕坐标
    let barX = frame.origin.x + Double(Double(minX + maxX) / 2) / Double(scale)
    var barTopY = frame.origin.y + Double(px.h - maxY) / Double(scale)
    var barBotY = frame.origin.y + Double(px.h - minY) / Double(scale)
    out("滑条 x=\(Int(barX))  y \(Int(barTopY))..\(Int(barBotY))  当前 \(curPct)%")

    // 闭环：点一次 → 读回 → 校正
    for attempt in 0..<6 {
        let wantY = barBotY - (barBotY - barTopY) * Double(target) / 100.0
        mouseClick(CGPoint(x: barX, y: wantY))
        usleep(800_000)
        guard let (now, _) = readPct() else { break }
        out("  尝试 \(attempt + 1): \(now)%")
        if now == target { out("✓ 应用音量 = \(now)%"); return }
        if now == curPct { break }
        // 线性校正
        let err = Double(target - now)
        let perPct = (barBotY - barTopY) / 100.0
        let dy = err * perPct
        barTopY = barTopY + dy
        barBotY = barBotY + dy
        curPct = now
    }
    if let (now, _) = readPct() { out("最终应用音量 = \(now)%") }
}

func cmdShot() {
    let a = Args(ARGV)
    // ⚠ 截图必须要有「屏幕录制」授权。没有时 screencapture 会静默产出空/黑图，
    //   上层于是显示"✅ 截图完成"但目录里什么都没有（用户 2026-10-23 实测）。
    //   这里做前置检查 + 主动申请：申请会弹系统框，把「闪控」加进授权列表。
    if a.str("out").isEmpty, !CGPreflightScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
        out("❌ 缺少「屏幕录制」授权：系统设置 > 隐私与安全性 > 屏幕录制，勾上「闪控」后重开闪控")
        exit(3)
    }
    let outPath = a.str("out").isEmpty ? mediaPath("截图", "png") : a.str("out")
    let bid = a.str("app")

    // --app 模式：排他捕获目标 app 的主窗口（不受遮挡影响）
    if !bid.isEmpty {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            defer { sem.signal() }
            do {
                let content = try await SCShareableContent.current
                let wins = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == bid && $0.frame.height > 120 && $0.frame.width > 200
                }
                guard let display = content.displays.first else { return }
                let titled = wins.filter { !($0.title ?? "").isEmpty }
                let pool = titled.isEmpty ? wins : titled
                guard let target = pool.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                    out("未找到 \(bid) 的可捕获窗口"); return
                }
                let others = content.windows.filter { $0.windowID != target.windowID }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: others)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(display.frame.width) * 2
                cfg.height = Int(display.frame.height) * 2
                cfg.scalesToFit = false
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
                let scale = CGFloat(img.width) / display.frame.width
                let f = target.frame
                var rect = CGRect(x: f.origin.x * scale, y: f.origin.y * scale, width: f.width * scale, height: f.height * scale)
                // --app 模式同样支持 --rect（rect 为屏幕逻辑坐标）
                if let r = a.flags["rect"], let p = parseRect(r) {
                    rect = CGRect(x: p.origin.x * scale, y: p.origin.y * scale, width: p.width * scale, height: p.height * scale)
                }
                guard let cr = img.cropping(to: rect) else { return }
                if let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(d, cr, nil); CGImageDestinationFinalize(d)
                    out("已保存 \(outPath) (\(cr.width)x\(cr.height)) 窗口='\(target.title ?? "")' @(\(Int(f.origin.x)),\(Int(f.origin.y))) \(Int(f.width))x\(Int(f.height))")
                    out("  ↳ 裁剪图坐标基准: 屏幕左上(\(Int(f.origin.x)),\(Int(f.origin.y)))，像素÷2 = 屏幕点")
                }
            } catch { out("ERR: \(error.localizedDescription)") }
        }
        sem.wait()
        return
    }

    if let (img, frame) = captureDisplay() {
        if let r = a.flags["rect"], let p = parseRect(r) {
            if let c = crop(img, screenRect: p, displayFrame: frame) {
                savePNG(c, outPath); out("已保存 \(outPath) (\(c.width)x\(c.height)) 区域=\(r)"); return
            }
        }
        savePNG(img, outPath); out("已保存 \(outPath) (\(img.width)x\(img.height))")
        return
    }
    die("截图失败")
}
func parseRect(_ s: String) -> CGRect? {
    let p = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard p.count == 4, p.allSatisfy({ $0 != nil }) else { return nil }
    return CGRect(x: p[0]!, y: p[1]!, width: p[2]!, height: p[3]!)
}

func cmdPixel() {
    let a = Args(ARGV)
    guard let pt = a.pt("at"), let (img, frame) = captureDisplay() else { die("需要 --at x,y") }
    guard let px = pixels(img) else { die("像素失败") }
    let scale = CGFloat(px.w) / frame.width
    let x = Int(Double(pt.x - frame.origin.x) * Double(scale))
    let y = px.h - Int(Double(pt.y - frame.origin.y) * Double(scale))
    guard x >= 0, x < px.w, y >= 0, y < px.h else { die("坐标越界") }
    let i = (y * px.w + x) * 4
    out("像素(\(Int(pt.x)),\(Int(pt.y))) = R\(px.buf[i]) G\(px.buf[i+1]) B\(px.buf[i+2])")
}

/// doctor — 诊断「为什么点了没反应 / 输了没进去」
///
/// 实测背景（这个命令是为了解决一个极难定位的问题而加的）：
///   闪控脚本跑完整套流程毫无错误，但**界面毫无反应** —— 点击不生效、粘贴不进字。
///   逐项排查后发现真凶是**屏幕已锁定**（loginwindow 进程在跑），
///   此时 macOS 会丢弃所有 CGEvent 合成输入事件，且**不报任何错**。
///   没有这个命令就只能靠猜，浪费了大量时间。
///
/// 检查项：
///   1. 屏幕是否锁定 / 屏保是否激活 —— 锁定时输入事件全部失效
///   2. 系统空闲时长 —— 超过阈值说明用户离开，自动锁屏风险
///   3. 目标应用是否存在高层浮窗（layer 很高的 CGWindow 会吞掉点击）
///   4. 输入事件投递自检（移动光标后看位置是否真的变了）
///
/// 用法：macctl doctor [--app <id>] [--no-mouse]
func cmdDoctor() {
    let a = Args(ARGV)
    var issues: [String] = []
    var warns: [String] = []

    // ── 1. 输入投递自检（**唯一的可靠判据，必须先跑**）──
    //
    // ⚠ 血泪教训（D-013）：
    //   原实现把「loginwindow 进程存在」当成锁屏判据，**这是错的**。
    //   loginwindow 是**常驻登录进程**，解锁后依然在跑（实测 pid 全程不变）。
    //   更糟的是：因为先判locked=true，代码直接 `if !locked` 跳过了输入自检，
    //   于是**唯一的可靠证据被误判给屏蔽了**，导致屏幕明明解锁却报「已锁定」。
    //
    // 正确判据优先级：
    //   1. 实测移动光标，位置真的变了吗？   ← 唯一可靠，直接反映系统是否接受合成事件
    //   2. loginwindow 进程只作参考信息，不作判据（它一直在）
    //   3. CGSSessionScreenIsLocked 实测返回 nil（不可用），ioreg 里也读不到
    //
    // ⚠⚠ D-022 修正：原来**只测一次**，一次失败就报「输入事件被系统阻断」。
    //   用户实测「明明没关屏幕，输入『打开微信』却报这个」。
    //   真实原因不是屏幕锁了，而是这个单点探测**本身就不稳定**：
    //     · 屏幕保护/防休眠软件会在那一刻弹窗抢焦点并把光标拉回去；
    //     · 用户可能正在动鼠标，两次采样互相干扰；
    //     · CGEvent 投递有排队延迟，260ms 不一定够。
    //   单次采样 + 无重试 = 把偶发抖动当成硬阻塞，
    //   而**报错文案把结论说成「屏幕已锁定」**，用户完全无法自查。
    //
    // 改法：① 连续测 3 次，取多数；② 失败时再做第二类独立判据
    //      （能否枚举到当前前台窗口 —— 锁屏时锁屏界面拿不到正常窗口）；
    //   ③ 只有两类判据**都**失败才判阻塞，且文案不再断言「屏幕已锁定」。
    let noMouse = a.has("no-mouse")
    var inputOK = true
    var inputNote = ""
    var successCount = 0
    let TRIES = 3
    if noMouse {
        inputNote = "跳过光标探测（--no-mouse）"
    } else {
        for _ in 0..<TRIES {
            let before = currentMousePos()
            // 往反方向偏移，避开屏幕边缘；偏移量足够小以免打扰用户
            let probe = CGPoint(x: before.x - 36, y: before.y - 24)
            // 越界则改向内偏移
            let target = (probe.x < 4 || probe.y < 4)
                ? CGPoint(x: before.x + 36, y: before.y + 24)
                : probe
            mouseMove(target)
            usleep(300_000)          // 比原来多给 40ms：投递有排队延迟
            let after = currentMousePos()
            if abs(after.x - before.x) > 5 || abs(after.y - before.y) > 5 {
                successCount += 1
                mouseMove(before)  // 复位，别打扰用户
                usleep(100_000)
            } else {
                usleep(80_000)
            }
        }
        inputOK = successCount * 2 > TRIES     // 2/3 即算通过（多数决）
    }

    // 第二判据：锁屏时拿不到正常的应用窗口（锁屏界面由 WindowServer 直接绘制）
    //   只在光标探测已经失败时才跑 —— 避免无谓开销。
    if !inputOK {
        let ws = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // 有「正常尺寸的窗口」= 有人在用 = 大概率没锁屏
        let hasRealWindow = ws.contains { w in
            let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
            let name = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let ww = (w[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0
            let hh = (w[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0
            return layer == 0 && ww > 200 && hh > 200 && !name.contains("loginwindow")
                && !name.contains("Lock")
        }
        if hasRealWindow {
            inputOK = true
            inputNote = "光标探测抖动（\(TRIES) 次里成功 \(successCount) 次），但屏幕上存在正常窗口 → 判定未锁定"
        } else {
            inputNote = String(format: "光标 %d 次探测均未移动，且屏幕上没有正常大小的窗口", TRIES)
        }
    }

    //锁屏状态由实测反推 —— 不再依赖任何单一标志位
    let locked = !inputOK

    // loginwindow 仅作参考信息
    var loginPid = 0
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "loginwindow"]
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let outStr = String(data: data, encoding: .utf8) ?? ""
        if let first = outStr.split(separator: "\n").first,
           let pid = Int(first.trimmingCharacters(in: .whitespaces)) {
            loginPid = pid
        }
    } catch {
        // pgrep 不可用时不阻塞主流程
    }

    if locked {
        // ⚠ 文案刻意**不断言「屏幕已锁定」**（D-022）：
        //   用户实测「明明没关屏幕」却被告知输入被阻断。
        //   把猜测当结论写进报错，等于让用户去查一个不存在的问题。
        //   改为列事实 + 给可自查的方向。
        issues.append("系统不接受模拟输入事件（实测光标无法移动、屏幕上也没有正常窗口）。可能原因：① 屏幕已锁定或处于休眠；② 正在使用远程桌面且会话未激活；③ 闪控没有「辅助功能/Accessibility」权限。若你确认屏幕没锁，请到「系统设置 → 隐私与安全性 → 辅助功能」里给终端/闪控打勾。")
    }

    if !inputNote.isEmpty {
        warns.append("输入通道探测：" + inputNote)
    }

    // ── 2. 高层浮窗检测 ──
    var blockers: [String] = []
    let bidRaw = a.str("app")
    if !bidRaw.isEmpty, let bid = resolveBundle(bidRaw), let pid = pidForBundle(bid) {
        for w in cgWindowList() where w.pid == pid && w.layer >= 100 && w.h <= 140 {
            blockers.append("layer=\(w.layer) '\(w.title)' @(\(Int(w.x)),\(Int(w.y))) \(Int(w.w))x\(Int(w.h))")
        }
    }
    if !blockers.isEmpty {
        warns.append("存在高层浮窗（可能吞掉点击）：" + blockers.joined(separator: "; "))
    }

    // ── 3. 输入通道结论已在第 1 步得出，此处不重复检测 ──

    // ── 输出 ──
    let okAll = issues.isEmpty
    if a.has("json") {
        let iss = issues.map { jesc($0) }.joined(separator: ",")
        let wns = warns.map { jesc($0) }.joined(separator: ",")
        let blk = blockers.map { jesc($0) }.joined(separator: ",")
        out("{\"ok\":\(okAll ? "true" : "false"),\"locked\":\(locked),\"input_ok\":\(inputOK),"
            + "\"loginwindow_pid\":\(loginPid),\"blockers\":[\(blk)],"
            + "\"issues\":[\(iss)],\"warnings\":[\(wns)]}")
        return
    }
    out("=== 闪控环境体检 ===")
    out("屏幕锁定: \(locked ? "⚠️ 是（输入事件会全部失效）" : "否")")
    out("输入通道: \(locked ? "跳过（已锁定）" : (inputOK ? "✅ 正常" : "❌ 失效"))")
    if !inputNote.isEmpty { out("  \(inputNote)") }
    if !blockers.isEmpty {
        out("高层浮窗:")
        for b in blockers { out("  ⛔ \(b)") }
    }
    if issues.isEmpty {
        out("✅ 未发现阻塞项")
    } else {
        out("")
        out("问题:")
        for i in issues { out("  ❌ \(i)") }
    }
    if !warns.isEmpty && issues.isEmpty {
        out("")
        for w in warns { out("  ⚠️ \(w)") }
    }
}

/// 当前鼠标位置（用于输入通道自检）
func currentMousePos() -> CGPoint {
    guard let e = CGEvent(source: nil) else { return .zero }
    return e.location
}

/// 同步列出 CoreGraphics 层窗口（含 CGWindow 的 layer 信息）
/// ⚠ 为什么不用 ScreenCaptureKit：SCK 是异步 API（SCShareableContent.current），
///   只能用在 async 命令里；这里的 doctor 需要同步结果。
///   CGWindowListCopyWindowInfo 虽然拿不到应用名，但 ownerPID + layer 够用了。
struct CGWinInfo {
    let pid: pid_t
    let layer: Int
    let title: String
    let x: Double, y: Double, w: Double, h: Double
}

func cgWindowList() -> [CGWinInfo] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [CGWinInfo] = []
    for d in arr {
        let pid = (d[kCGWindowOwnerPID as String] as? pid_t) ?? 0
        let layer = (d[kCGWindowLayer as String] as? Int) ?? 0
        let title = (d[kCGWindowName as String] as? String) ?? ""
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        if let r = d[kCGWindowBounds as String] as? [String: Any] {
            x = (r["X"] as? Double) ?? 0
            y = (r["Y"] as? Double) ?? 0
            w = (r["Width"] as? Double) ?? 0
            h = (r["Height"] as? Double) ?? 0
        }
        out.append(CGWinInfo(pid: pid, layer: layer, title: title, x: x, y: y, w: w, h: h))
    }
    return out
}

/// 按 bundle id 找到进程 pid（取第一个）
func pidForBundle(_ bid: String) -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.processIdentifier
}

func cmdProbe() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用 \(bid)") }
    let mode = a.str("mode").isEmpty ? "nonempty" : a.str("mode")
    let q = a.str("query")
    let timeout = Double(a.int("timeout", 3))
    let depth = a.int("depth", 12)
    let roleFilter = a.str("role")
    let minW = Double(a.int("minw", 0))
    let yMin = Double(a.int("ymin", -99999))
    let yMax = Double(a.int("ymax", 99999))
    let xMin = Double(a.int("xmin", -99999))
    let xMax = Double(a.int("xmax", 99999))

    /// 在 Swift 进程内做「拿树 → 判定 → 等 → 再判定」，条件满足即输出并退出。
    /// ⚠ 为什么必须有这个命令（实测）：把等待放在 shell 里做，每轮探测要起
    ///   1 个 mktemp + 1~2 个 python3 进程；macOS 沙箱下 python3 冷启动~240ms，
    ///   单轮探测 ~900ms。3 秒预算只够 3 轮，实际等待 9 秒都还不回来。
    ///   在 Swift 内轮询则是每轮 1~3ms（treeNodes 已缓存），差距两个数量级。
    var waited = 0.0
    let deadline = timeout
    while true {
        let nodes = treeNodes(bundleID: b, maxDepth: depth)
        var matched = false
        if !nodes.isEmpty {
            switch mode {
            case "ax":
                matched = true                       // AX 树非空即就绪
            case "text":
                matched = findNodes(nodes, text: q).isEmpty == false
            case "role":
                matched = nodes.contains { n in
                    (roleFilter.isEmpty || n.role == roleFilter)
                        && n.size.width >= minW
                        && n.pos.y >= yMin && n.pos.y <= yMax
                        && n.pos.x >= xMin && n.pos.x <= xMax
                }
            case "textfield":
                // 「有一个可输入的文本框」—— 用于确认点击后焦点到位
                matched = nodes.contains { n in
                    (n.role == "AXTextField" || n.role == "AXTextArea")
                        && n.pos.y >= yMin && n.pos.y <= yMax
                }
            default:
                matched = true
            }
        }
        if matched {
            if a.has("json") {
                out("{\"ok\":true,\"mode\":\(jesc(mode)),\"ax_count\":\(nodes.count),\"waited_ms\":\(Int(waited * 1000))}")
            } else {
                out("✓ 就绪 (AX \(nodes.count) 节点, \(String(format: "%.1f", waited))s)")
            }
            return
        }
        if waited >= deadline {
            if a.has("json") {
                out("{\"ok\":false,\"mode\":\(jesc(mode)),\"ax_count\":\(nodes.count),\"waited_ms\":\(Int(waited * 1000)),\"error\":\"超时未就绪\"}")
                exit(1)
            }
            die("超时 \(timeout)s 未就绪")
        }
        // 重试间隔随次数递增：treeNodes 单次要 ~700ms（AX 跨进程调用，无法避免），
        // 高频重试没有意义还浪费时间。200ms 起步，每次 ×1.6，上限 600ms。
        let gap = min(0.6, 0.2 * pow(1.6, waited / 0.5))
        usleep(UInt32(gap * 1_000_000))
        waited += gap
    }
}

func cmdWait() {
    let a = Args(ARGV)
    let text = a.str("text").isEmpty ? a.positional.first ?? "" : a.str("text")
    let timeout = a.int("timeout", 10)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用") }
    var waited = 0
    while waited < timeout * 10 {
        let nodes = treeNodes(bundleID: b, maxDepth: a.int("depth", 12))
        if !findNodes(nodes, text: text).isEmpty {
            if a.has("json") { out("{\"ok\":true,\"text\":\(jesc(text)),\"waited_ms\":\(waited * 100)}") }
            else { out("✓ '\(text)' 已出现 (\(Double(waited)/10.0)s)") }
            return
        }
        usleep(100_000); waited += 1
    }
    if a.has("json") { out("{\"ok\":false,\"error\":\"超时未出现\",\"text\":\(jesc(text))}"); exit(1) }
    die("超时 \(timeout)s 未出现 '\(text)'")
}

func cmdScroll() {
    let a = Args(ARGV)
    let dir = a.str("dir", "down")
    let n = a.int("n", 3)
    var pt = a.pt("at")
    if pt == nil {
        let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
        if let b = resolveBundle(bid) {
            let nodes = treeNodes(bundleID: b, maxDepth: 20)
            if let l = nodes.first(where: { $0.role == "AXList" && $0.size.height > 80 }) {
                pt = CGPoint(x: l.pos.x + l.size.width / 2, y: l.pos.y + l.size.height / 2)
            } else if let w = nodes.first(where: { $0.role == "AXWindow" }) {
                pt = CGPoint(x: w.pos.x + w.size.width / 2, y: w.pos.y + w.size.height / 2)
            }
        }
    }
    guard let p = pt else { die("无法确定滚动位置") }
    let d: Int32 = dir == "up" ? 3 : (dir == "down" ? -3 : 0)
    if d == 0 {
        // 左右
        let dx: Int32 = dir == "left" ? 3 : -3
        for _ in 0..<n { scroll(p, dx); usleep(150_000) }
    } else {
        for _ in 0..<n { scroll(p, d); usleep(150_000) }
    }
    out("滚动 \(dir) x\(n) @(\(Int(p.x)),\(Int(p.y)))")
}

/// launch --name <应用名>  按**名称**启动/唤醒应用。
///
/// ⚠ 为什么要单独一个命令（而不是让上层用 front/raise）：
///  ① front/raise 都要求 bundle id，上层得先知道 id —— 但用户说的是「WPS」
///     「豆包」这种本地化名字，映射表不全就会 fail；
///  ② front 要求**应用已在运行**，未运行时直接 die「应用未运行」。
///     「打开WPS」时 WPS 常常是关着的 → 这条路径原本必然失败；
///  ③ 最关键的：上层（route.sh）拿不到名字→id 的映射时，会退化成
///     「去磁盘搜同名文件」，于是「打开微信」变成搜出 40 个含"微信"的文档
///     并报 AMBIGUOUS —— 表现为「明明电脑没锁，却说输入被阻断」的困惑。
///
/// 无声启动一个应用 —— **保证不弹任何系统对话框**。
///
/// ⚠⚠ 为什么不能用 `NSWorkspace.openApplication(at:)`：
///   它在启动失败时会让 LaunchServices 弹一个**系统级**模态框
///   （CoreServicesUIAgent，标题「警告」/「应用程序无法打开」）。
///   这个框会浮在用户桌面上，且**不受我们的进程控制** —— 无法关闭、
///   无法抑制、还会挡住后续操作。
///   2026-10-22 实测根因：Safari 的真实路径在 cryptex 卷
///   （/System/Volumes/Preboot/Cryptexes/...），
///   用 openApplication 打开它必然返回 -600 → 必然弹窗。
///   而 `/usr/bin/open` CLI 走同一条 LaunchServices 链路，
///   失败时**只往 stderr 写一行**，绝不弹窗。
///
/// ⚠ 为什么按 bundle id 而不是按路径启动：
///   cryptex 应用按路径 open 一定失败（-600），
///   但 `open -b com.apple.Safari` 是成功的（系统自己认得 cryptex 路径）。
///   所以优先级是：**bundle id → 路径**。
///
/// 返回值：(是否已受理启动, 错误描述)
@discardableResult
func launchSilently(bundleID: String, path: String) -> (ok: Bool, err: String) {
    var lastErr = ""

    // ① 按 bundle id 启动（cryptex 应用只有这条路能通）
    if !bundleID.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", bundleID]
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        if (try? p.run()) != nil {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return (true, "") }
            lastErr = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "open -b 失败"
        }
    }

    // ② 退到按路径启动（第三方应用走这条）
    if !path.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [path]
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        if (try? p.run()) != nil {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return (true, "") }
            let e2 = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !e2.isEmpty { lastErr = e2 }
        }
    }

    return (false, lastErr.isEmpty ? "无法启动" : lastErr)
}

/// 启动/唤醒应用后，用 Dock 点击兜底（AX 仍读不到时）。
///
/// ⚠ 为什么不直接在 Swift 里点 Dock：Dock 的 AX 遍历 + 坐标点击逻辑
///   已经在 cmdDock 里实现并调过（踩过两个坑：Dock 无 AX 窗口、图标角色是
///   AXDockItem），复制一份必然随两边漂移。复用命令更稳。
///   失败也无所谓 —— 这本来就是兜底路径。
func dockFallback(_ name: String) {
    guard let me = Bundle.main.executableURL else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [me.deletingLastPathComponent().appendingPathComponent("macctl").path,
                   "dock", "--app", name]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return }
    p.waitUntilExit()
}

/// 把一个**已在运行**的应用可靠地提到最上层。
///
/// ⚠⚠ 为什么不用 `app.activate(options:)`：
///   2026-10-22 实测踩坑—— 从**命令行进程**（.accessory 策略、不是前台 App）
///   调 `NSRunningApplication.activate`，**完全不生效**：
///   目标 App 的 AX 树读得到、进程也在，但 `frontmostApplication` 仍是原来那个。
///   这是 AppKit 的老规矩：非前台进程没有资格改变全局激活权。
///
///   `open -b <bundleid>` 走LaunchServices 的另一条链路，
///   它由系统进程代劳激活，**对已运行的 App 是纯置前**（实测 PID 不变，
///   不会重启），且失败只写 stderr、绝不弹系统框。
func frontmost(_ bundleID: String) -> Bool {
    guard !bundleID.isEmpty else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-b", bundleID]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        dockFallback(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID)
        return false
    }
    return true
}

/// 行为：已运行 → 置前唤醒（等价 front，容忍 AX 仍被遮挡）；
///       未运行 → 无声拉起（绝不弹系统框）；再失败 → 退到 Dock 点击。
func cmdLaunch() {
    let a = Args(ARGV)
    let name = a.str("name").isEmpty ? a.positional.first ?? "" : a.str("name")
    guard !name.isEmpty else { die("用法: macctl launch --name <应用名>") }

    // --resolve-only：只回答「能不能解析到它、在哪」，不启动任何东西。
    // ⚠ 自检需要验证中文名↔英文名映射，但测试不该真的把 4 个 App 弹起来。
    //   没有这个开关，唯一能测的办法就是制造副作用 —— 那不是测试，是捣乱。
    if a.has("resolve-only") {
        let url = resolveAppURL(name)
        if let u = url {
            let bid = Bundle(url: u)?.bundleIdentifier ?? ""
            let disp = (Bundle(url: u)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? ""
            if a.has("json") {
                out("{\"ok\":true,\"name\":\(jesc(name)),\"path\":\(jesc(u.path)),\"bundle\":\(jesc(bid)),\"display\":\(jesc(disp))}")
            } else {
                out("✓ \(name) → \(u.path)\(bid.isEmpty ? "" : "  [\(bid)]")")
            }
        } else {
            if a.has("json") {
                out("{\"ok\":false,\"name\":\(jesc(name)),\"error\":\"APP_NOT_FOUND\"}")
            } else {
                out("❌ 找不到应用「\(name)」")
            }
        }
        return
    }

    var jName = jesc(name)
    var jApp = ""
    var jState = "notfound"
    var jAx = 0

    // 路径 1：已在运行 → 置前
    //
    // ⚠ 先试 activate（进程自己是前台时它最快、副作用最小），
    //   再无条件走 open -b 兜底 —— 因为从 CLI 进程 activate 可能完全无效，
    //   而 open -b 对已运行 App 是纯置前，两次都调的开销可以忽略。
    if let bid = resolveBundle(name), isUserVisibleApp(bid),
       let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
        app.activate(options: [.activateAllWindows])
        usleep(300_000)
        var fronted = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bid)
        if !fronted {
            fronted = frontmost(bid)
            usleep(400_000)
        }
        // 置前后再校验一次 AX；读不到不判失败（可能被遮挡），下轮用 Dock 兜
        let n = treeNodes(bundleID: bid, maxDepth: 8).count
        if n > 0 {
            jApp = jesc(bid); jState = fronted ? "activated" : "activated_no_ax"; jAx = n
        } else {
            // AX 仍为 0：应用激活了但界面不可读。用 Dock 再点一次（D-019 的经验）
            dockFallback(name)
            usleep(1_200_000)
            let n2 = treeNodes(bundleID: bid, maxDepth: 8).count
            jApp = jesc(bid)
            jState = n2 > 0 ? "dock_activated" : (fronted ? "activated_no_ax" : "launch_error")
            jAx = n2
        }
    } else if let url = resolveAppURL(name) {
        // 路径 2：没运行 → 拉起
        //
        // ⚠⚠ 这里**绝不能**用 NSWorkspace.openApplication：
        //   它失败时会弹系统级「应用程序无法打开」框，浮在用户桌面上，
        //   关不掉也挡路。2026-10-22 实测：cryptex 应用（Safari）
        //   用 openApplication 必然 -600 → 必然弹窗。
        //   launchSilently 走 /usr/bin/open CLI，失败只写 stderr。
        let bid = Bundle(url: url)?.bundleIdentifier ?? ""
        let (accepted, launchErr) = launchSilently(bundleID: bid, path: url.path)
        var ok = accepted
        var n = 0

        // 「受理启动」≠「起来了」—— 真正判据是 AX 树有没有节点。
        //（open CLI 对 cryptex 应用会立刻返回成功，但进程起来要 1-2 秒）
        if bid.isEmpty == false {
            for _ in 0..<24 {
                usleep(500_000)
                n = treeNodes(bundleID: bid, maxDepth: 8).count
                if n > 0 { ok = true; break }
            }
        }
        // 真的没起来 → 用 Dock 点击再试一次（走 AX 语义点击，绕过沙箱限制）
        if !ok && bid.isEmpty == false {
            dockFallback(url.deletingPathExtension().lastPathComponent)
            usleep(1_500_000)
            n = treeNodes(bundleID: bid, maxDepth: 8).count
            if n > 0 { ok = true }
        }
        jApp = jesc(bid); jAx = n
        jState = ok ? "launched" : "launch_error"
        _ = launchErr   // 保留在栈上便于排查时打印
        // ⚠ 起来了还不算完 —— 必须**真的到最上层**。
        //   open -b 在冷启动时只负责把进程拉起来，
        //   抢到激活权这件事对刚起来的 App 不保证（实测备忘录/计算器
        //   冷启动后经常停在后台）。这里无条件再置前一次。
        if ok && bid.isEmpty == false {
            _ = frontmost(bid)
            usleep(300_000)
        }
        if ok && n == 0 {
            // 拉起了但 AX 读不到（还在加载/被遮挡）—— 不算失败，加一次 Dock 点击
            dockFallback(name)
            usleep(1_200_000)
            jAx = treeNodes(bundleID: bid, maxDepth: 8).count
            if jAx > 0 { jState = "launched_dock" }
        }
    } else {
        if a.has("json") {
            out("{\"ok\":false,\"name\":\(jName),\"error\":\"APP_NOT_FOUND\"}")
        } else {
            out("❌ 找不到应用「\(name)」—— 已安装列表里没有它")
        }
        return
    }

    let okAll = jState != "notfound" && jState != "launch_error"
    if a.has("json") {
        out("{\"ok\":\(okAll ? "true" : "false"),\"name\":\(jName),\"app\":\(jApp),\"state\":\(jesc(jState)),\"ax_count\":\(jAx)}")
    } else {
        let label: String
        switch jState {
        case "activated":       label = "已置前"
        case "dock_activated":  label = "已置前（经 Dock 唤醒）"
        case "launched":        label = "已启动"
        case "launched_dock":   label = "已启动（经 Dock 置前）"
        case "activated_no_ax": label = "已置前，但界面暂不可读（可能被遮挡）"
        default:                label = "启动失败"
        }
        out("\(okAll ? "✓" : "❌") \(name)：\(label)  AX \(jAx)")
    }
}

/// 启动/唤醒应用后，用 Dock 点击兜底（AX 仍读不到时）。
///
/// 用户常用的中文/俗称 → 磁盘上真实的英文应用名。
///
/// ⚠ 为什么必须有这张表（D-022 的第二层根因）：
///   磁盘上的目录名和 Info.plist 显示名**常常是英文**：
///     /System/Applications/Calculator.app  → CFBundleDisplayName = "Calculator"
///     /Applications/Doubao.app             → "Doubao"
///   用户嘴里说的是「计算器」「豆包」。系统自带应用的本地化名藏在
///   InfoPlist.strings 里（要读 Resources/<lang>.lproj/），第三方应用则**根本没有**
///   中文本地化 —— 所以纯靠扫目录永远认不出「计算器」。
///
///   这不是「打地鼠式加同义词」：这张表只覆盖**操作系统自带 + 用户明确点名的**
///   那几十个应用，是有限集；自然语言的无限开放由 route.sh 的分层负责。
private let APP_ALIASES: [String: String] = [
    // 系统自带
    // ⚠⚠ 系统自带的**中文名只存在于运行时**（NSRunningApplication.localizedName），
    //   磁盘目录名和 Info.plist 里全是英文。所以下面这些别名不是「方便」，
    //   是「不映射就必然找不到」：
    //     访达 = Finder.app / 计算器 = Calculator.app / 文本编辑 = TextEdit.app
    "访达": "Finder", "文件管理器": "Finder", "桌面文件": "Finder",
    "计算器": "Calculator", "日历": "Calendar", "邮件": "Mail",
    "备忘录": "Notes", "提醒事项": "Reminders", "地图": "Maps",
    // ⚠ macOS 上「记事本」这个中文名根本不存在（那是 Windows 的叫法），
    //   用户很可能照 Windows 习惯这么叫 → 必须映射到 TextEdit。
    "记事本": "TextEdit", "便签": "Stickies",
    "信息": "Messages", "通讯录": "Contacts", "照片": "Photos",
    "音乐": "Music", "播客": "Podcasts", "图书": "Books",
    "新闻": "News", "股市": "Stocks", "钱包": "Wallet",
    "语音备忘录": "VoiceMemos", "脚本编辑器": "ScriptEditor",
    "系统设置": "SystemSettings", "系统偏好设置": "SystemSettings",
    "实用工具": "Utilities", "活动监视器": "ActivityMonitor",
    "终端": "Terminal", "预览": "Preview", "文本编辑": "TextEdit",
    "字体册": "FontBook", "钥匙串访问": "KeychainAccess",
    "截图": "Screenshot", "数码测色计": "DigitalColorMeter",
    "旁白": "VoiceOver", "语音识别": "SpeechRecognition",
    "家庭": "Home", "图书app": "Books", "字典": "Dictionary",
    // 浏览器
    // ⚠ 2026-10-22 用户明确要求：「打开浏览器」默认开**谷歌浏览器**。
    //   所以「浏览器」「网页」都指向 Chrome，Safari 只能用「safari」显式叫。
    //   注意 Chrome 的磁盘名是 "Google Chrome.app"、CFBundleName 是 "Chrome"，
    //   两个都得写进别名表 —— 只写 "Chrome" 时 Spotlight 精确匹配
    //   （kMDItemFSName == 'Chrome.app'）命不中，得靠包含匹配兜。
    // ⚠ 别名必须写死成**具体 app 名**，绝不能让「浏览器」落到包含匹配上：
    //   WebKit.Networking（com.apple.WebKit.Networking）的显示名含"浏览器"三个字，
    //   实测会被误选 —— 一个 0 节点的隐藏进程。
    "浏览器": "Google Chrome", "网页": "Google Chrome",
    "谷歌浏览器": "Google Chrome", "google chrome": "Google Chrome",
    "chrome": "Google Chrome", "Chrome": "Google Chrome",
    // Safari 保留显式入口（用户想用系统自带浏览器时说「safari」）
    "safari": "Safari", "Safari": "Safari", "苹果浏览器": "Safari",
    // 第三方（用户环境实测确认存在）
    // ⚠ 微信是最典型的坑：磁盘上是 /Applications/WeChat.app，
    //   CFBundleDisplayName 也是 "WeChat" —— 中文名**只在运行后才显示**。
    //   所以「打开微信」在它未运行时必然解析失败。
    "微信": "WeChat", "wechat": "WeChat", "企业微信": "WeCom",
    "豆包": "Doubao", "抖音": "Douyin", "快手": "Kuaishou",
    "小红书": "Xiaohongshu", "wps": "wpsoffice", "wps文档": "wpsoffice",
    "wps office": "wpsoffice", "wpsoffice": "wpsoffice", "金山文档": "wpsoffice",
    "qq": "QQ", "钉钉": "DingTalk", "飞书": "Lark", "百度网盘": "BaiduNetdisk",
    "剪映": "CapCut", "网易云音乐": "NetEaseMusic", "酷狗": "kugou",
    "幕布": "mubu", "向日葵": "AweSun", "腾讯会议": "TencentMeeting",
    "网易邮箱": "NeteaseMail", "网易邮箱大师": "NeteaseMailMaster",
    "夸克网盘": "QuarkCloudDrive", "印象笔记": "Evernote", "有道": "Youdao",
    // 网络工具（用户环境实测确认：/Applications/iKuuuVPN.app，CFBundleName=iKuuuVPN）
    // ⚠ 中文别名同时覆盖「VPN」「加速器」「飞机」等口语说法 —— 用户日常说的是这些词，
    //   而磁盘/app 名是 iKuuuVPN，不映射就等于没做。
    "iKuuuVPN": "iKuuuVPN", "ikuuuvpn": "iKuuuVPN", "ikuuu vpn": "iKuuuVPN",
    "vpn": "iKuuuVPN", "加速器": "iKuuuVPN", "科学上网": "iKuuuVPN", "飞机": "iKuuuVPN",
]

/// 通过 Spotlight 索引按名字找应用。
///
/// ⚠ 存在的理由：FileManager 枚举 /Applications 会被 SIP/TCC 挡住一部分条目
///   （实测 49 vs 345，Safari 就属于读不到的那批），而 mdfind 走的是
///   系统索引，**能看到完整清单**。这是唯一能全覆盖「已安装应用」的手段。
func spotlightAppURL(named name: String) -> URL? {
    func norm(_ s: String) -> String { s.lowercased().filter { !" -_.".contains($0) } }
    let key = norm(name)
    guard !key.isEmpty else { return nil }

    // 先按文件名精确查（最快，命中即返回）
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    p.arguments = ["kMDItemFSName == '\(name).app'cd"]
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let lines = String(data: data, encoding: .utf8)?
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty } ?? []
    if let first = lines.first, first.hasSuffix(".app") { return URL(fileURLWithPath: first) }

    // 再全量列出应用做包含匹配（一次 mdfind，不逐个查）
    let p2 = Process()
    let pipe2 = Pipe()
    p2.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    p2.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
    p2.standardOutput = pipe2
    p2.standardError = Pipe()
    guard (try? p2.run()) != nil else { return nil }
    let d2 = pipe2.fileHandleForReading.readDataToEndOfFile()
    p2.waitUntilExit()
    let all = String(data: d2, encoding: .utf8)?
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasSuffix(".app") } ?? []

    var partial: (URL, Int)? = nil
    for path in all {
        let fname = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let n = norm(fname)
        if n == key { return URL(fileURLWithPath: path) }
        if let len = n.contains(key) ? n.count : nil {
            if partial == nil || len > partial!.1 { partial = (URL(fileURLWithPath: path), len) }
        }
    }
    return partial?.0
}

func cmdFront() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? a.positional.first ?? "" : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用 \(bid)") }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first else { die("应用未运行") }
    // 关键：激活后必须校验 AX 树是否恢复。
    // macOS 对「被完全遮挡」的窗口停止 AX 投递 → activate 之后如果目标窗口
    // 仍被盖住，AX 树会持续为 0。必须循环：激活 → 校验 → 必要时重试。
    let tries = a.int("tries", 4)
    var lastCount = 0
    // 等待策略：先短等再渐进加长。
    // 原实现固定等 700ms，而实测应用已激活时 AX 树通常 150ms 内就恢复 →
    // 固定等待让 front 单次就吃 1s，是脚本总耗时的大头（实测 front=1034ms）。
    // 渐进等待能在保证可靠性的同时把常见情况的耗时压到 ~200ms。
    let waits: [UInt32] = [150_000, 350_000, 600_000, 900_000]
    for attempt in 1...tries {
        app.activate(options: [.activateAllWindows])
        usleep(waits[min(attempt - 1, waits.count - 1)])
        let nodes = treeNodes(bundleID: b, maxDepth: 8)
        lastCount = nodes.count
        if !nodes.isEmpty {
            if a.has("json") {
                out("{\"ok\":true,\"app\":\(jesc(b)),\"ax_count\":\(nodes.count),\"attempts\":\(attempt)}")
            } else {
                out("已激活 \(app.localizedName ?? b)  AX 节点 \(nodes.count)\(attempt > 1 ? "  (第 \(attempt) 次尝试)" : "")")
            }
            return
        }
        // AX 树仍空 → 目标窗口可能被完全遮挡 → 用 raise 点击标题栏强制置前
        if attempt == 1 {
            _ = cmdRaiseQuiet(b)
        }
        usleep(200_000)
    }
    if a.has("json") {
        out("{\"ok\":false,\"app\":\(jesc(b)),\"ax_count\":0,\"error\":\"激活后 AX 树仍为空（窗口被完全遮挡）\"}")
    } else {
        out("已激活 \(app.localizedName ?? b)  ⚠ AX 树仍为空（窗口被完全遮挡，用 diagnose 查遮挡者）")
    }
}

/// winback — 把某窗口「后置」，用于解决窗口互相遮挡导致点不到目标控件的问题。
///
/// 实测场景（微信）：搜索框在主窗口上，但聊天窗口浮在它上方且完全覆盖该区域
///   → 点击搜索框命中的是聊天窗口，粘贴报成功但毫无反应。
///   把聊天窗口后置后，搜索框重新可点。
///
/// 用法：
///   macctl winback --app <bundle> [--index <n>] [--title <子串>]
///   --index 不给时后置「除主窗口外的所有窗口」（最常见的诉求）
func cmdWinback() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? a.positional.first ?? "" : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用 \(bid)") }
    guard let ax = appElement(b) else { die("应用未运行或无 AX 权限") }
    let ws = windows(of: ax)
    let idx = a.int("index", -1)
    let titleFilter = a.str("title")

    // 选出要后置的窗口
    var targets: [AXUIElement] = []
    if idx >= 0 {
        if idx < ws.count { targets = [ws[idx]] }
    } else if !titleFilter.isEmpty {
        for w in ws {
            let t = (axStr(w, kAXTitleAttribute) as? String) ?? ""
            if t.contains(titleFilter) { targets.append(w) }
        }
    } else {
        // 默认：面积最大的当主窗口，其余全部后置
        if ws.count >= 2 {
            var bestIdx = 0
            var bestArea: CGFloat = 0
            for (i, w) in ws.enumerated() {
                let sz = axSize(w)
                let area = sz.width * sz.height
                if area > bestArea { bestArea = area; bestIdx = i }
            }
            for (i, w) in ws.enumerated() where i != bestIdx { targets.append(w) }
        }
    }

    if targets.isEmpty {
        if a.has("json") { out("{\"ok\":true,\"app\":\(jesc(b)),\"moved\":0,\"note\":\"无可后置窗口\"}") }
        else { out("无需后置（窗口数 \(ws.count)）") }
        return
    }

    // 通过「移到屏幕外再移回」强制让窗口退到同应用其他窗口之后。
    // （AXUIElementSetAttributeValue(kAXPosition) 是 macOS 上让窗口让位的可靠手段；
    //   AXRaise 只能把窗口「提到最前」，没有对应的「后置」API。）
    var moved = 0
    for w in targets {
        let t = (axStr(w, kAXTitleAttribute) as? String) ?? ""
        let home = axPos(w)
        _ = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString,
                                         CGPoint(x: -2000, y: -2000) as CFTypeRef)
        usleep(220_000)
        _ = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString,
                                         CGPoint(x: home.x, y: home.y) as CFTypeRef)
        usleep(220_000)
        moved += 1
        let now = axPos(w)
        if !a.has("json") { out("已后置窗口 「\(t)」 @(\(Int(now.x)),\(Int(now.y)))") }
    }
    usleep(400_000)
    if a.has("json") {
        let names = targets.map { jesc((axStr($0, kAXTitleAttribute) as? String) ?? "") }.joined(separator: ",")
        out("{\"ok\":true,\"app\":\(jesc(b)),\"moved\":\(moved),\"titles\":[\(names)]}")
    } else {
        out("已后置 \(moved) 个窗口")
    }
}

/// raise 的静默版本：只做置前动作，不打印（供 cmdFront 内部调用）
func cmdRaiseQuiet(_ b: String) {
    guard let ax = appElement(b) else { return }
    var nodes: [Node] = []
    for w in windows(of: ax) { walk(w, 0, 12, &nodes) }
    guard let win = nodes.first(where: { $0.role == "AXWindow" && $0.size.width > 300 }) else { return }
    // 在窗口标题栏附近采样，找被遮挡层数最少的点点击
    var best: (pt: CGPoint, layers: Int)? = nil
    let topY = win.pos.y + 12
    for gx in stride(from: win.pos.x + 20, through: win.pos.x + win.size.width - 20, by: 44) {
        for gy in stride(from: topY, through: topY + 20, by: 8) {
            let layers = occlusionLayers(at: CGPoint(x: gx, y: gy))
            if best == nil || layers < best!.layers {
                best = (CGPoint(x: gx, y: gy), layers)
            }
        }
    }
    if let p = best { mouseClick(p.pt) }
}

/// 计算某点被多少层窗口覆盖（用于找未遮挡点）
/// 用 CGWindowList 拿到所有窗口矩形（比 NSRunningApplication 更全，含浮层）
func occlusionLayers(at pt: CGPoint) -> Int {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return 99 }
    var count = 0
    for w in list {
        guard let rectDict = w[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: rectDict as CFDictionary) else { continue }
        guard r.width > 0, r.height > 0 else { continue }
        if NSPointInRect(pt, r) { count += 1 }
    }
    return count
}

func cmdRecall() {
    let l = loadLearned()
    out("=== 学习缓存 ===")
    out("更新于: \(l.updated)")
    if l.inputMethod.isEmpty { out("  (无)") }
    for (k, v) in l.inputMethod.sorted(by: { $0.key < $1.key }) { out("  输入方式 \(k) -> \(v)") }
    for (k, v) in l.notes.sorted(by: { $0.key < $1.key }) { out("  备注 \(k): \(v)") }
}

func cmdNote() {
    let a = Args(ARGV)
    let app = a.str("app")
    let text = a.str("text").isEmpty ? a.positional.joined(separator: " ") : a.str("text")
    guard !app.isEmpty, !text.isEmpty else { die("需要 --app 和 --text") }
    var l = loadLearned()
    l.notes[app] = text
    saveLearned(l)
    out("已记录 \(app): \(text)")
}


func cmdSCWindows() {
    let a = Args(ARGV)
    let bid = a.str("app")
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.current
            var list = content.windows
            if !bid.isEmpty, let b = resolveBundle(bid) {
                list = list.filter { $0.owningApplication?.bundleIdentifier == b }
            }
            out("=== SCK 窗口 \(list.count) ===")
            for w in list.sorted(by: { $0.frame.origin.y < $1.frame.origin.y }) {
                let appName = w.owningApplication?.applicationName ?? "?"
                out("  id=\(w.windowID) layer=\(w.windowLayer) '\(w.title ?? "")' @(\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y))) \(Int(w.frame.width))x\(Int(w.frame.height)) [\(appName)]")
            }
        } catch { out("ERR: \(error.localizedDescription)") }
    }
    sem.wait()
}

/// 关闭指定图层/坐标上的浮窗：点击其关闭按钮或发送 ESC
func cmdClosePopup() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用") }
    // 优先 ESC
    keyPress("escape")
    usleep(700_000)
    // 找所有窗口检查是否还在
    let ax = appElement(b)
    if let ax = ax {
        let ws = windows(of: ax)
        out("剩余窗口 \(ws.count):")
        for w in ws { let n = node(w); out("  '\(n.title)' @(\(Int(n.pos.x)),\(Int(n.pos.y))) \(Int(n.size.width))x\(Int(n.size.height))") }
    }
}


/// 区域像素分析：找出主色条（用于音量滑条等自绘控件）
struct ColorBar { var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, count = 0 }

func analyzeColorBar(_ img: CGImage, hue: String) -> ColorBar {
    var bi = ColorBar()
    guard let px = pixels(img) else { return bi }
    for y in 0..<px.h {
        for x in 0..<px.w {
            let i = (y * px.w + x) * 4
            let r = Int(px.buf[i]), g = Int(px.buf[i + 1]), b = Int(px.buf[i + 2])
            var hit = false
            switch hue {
            case "blue":  hit = (b > 170 && r < 140 && b - r > 80 && g > 100)
            case "red":   hit = (r > 170 && g < 110 && r - g > 80)
            case "green": hit = (g > 140 && r < 140 && g - r > 50 && g - b > 30)
            case "gray":  hit = (abs(r - g) < 14 && abs(g - b) < 14 && r > 100 && r < 210)
            case "white": hit = (r > 235 && g > 235 && b > 235)
            default: hit = false
            }
            if hit {
                bi.minX = min(bi.minX, x); bi.maxX = max(bi.maxX, x)
                bi.minY = min(bi.minY, y); bi.maxY = max(bi.maxY, y)
                bi.count += 1
            }
        }
    }
    return bi
}

/// 在指定屏幕区域内找出某一颜色的条，返回屏幕逻辑坐标
func findColorBar(screenRect: CGRect, hue: String) -> (x: Double, topY: Double, botY: Double)? {
    guard let (img, frame) = captureDisplay() else { return nil }
    guard let c = crop(img, screenRect: screenRect, displayFrame: frame) else { return nil }
    let bi = analyzeColorBar(c, hue: hue)
    guard bi.count > 20, bi.maxX > 0 else { return nil }
    let scale = CGFloat(c.width) / screenRect.width
    let cx = screenRect.origin.x + Double(Double(bi.minX + bi.maxX) / 2) / Double(scale)
    let topY = screenRect.origin.y + Double(bi.minY) / Double(scale)
    let botY = screenRect.origin.y + Double(bi.maxY) / Double(scale)
    return (cx, topY, botY)
}

/// vol-set：应用内音量闭环调值（自绘气泡场景）
/// 关键事实（实测）：
///   - 音量气泡是「独立浮窗 + 自绘」，AX 树完全读不到百分比 → 必须 OCR
///   - 排他捕获主窗口会把浮窗排掉 → 像素分析必须用「全屏捕获」作坐标基准
///   - 气泡是「开关式」：再点一次喇叭就关闭
///   - 点击轨道空白处不改变音量 → 必须「拖拽蓝色滑块圆点」
///   - 滑块行程：轨道顶端 = 100%，圆点 y 随值线性下移
/// 流程：定位喇叭 → 开气泡 → OCR 读百分比 → 像素找蓝点圆心
///      → 两点标定「圆点 y ↔ 百分比」→ 拖拽逼近目标 → OCR 校验
func cmdVolSet() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用") }
    let target = max(0, min(100, a.int("to", 70)))

    // ---- 1. 定位喇叭按钮 ----
    // 播放条最底行图标顺序固定：心形(收藏) | 喇叭 | 词 | 列表 | 歌单
    // 但「收藏」有时带文字标签会挤掉位置 → 不能按索引猜
    // 做法：用几何特征。喇叭图标是「喇叭+两道声波」，在播放条上呈现为
    //      一组竖直排列的深色像素簇；先用候选按钮做冒烟测试，找出能弹出气泡的那个。
    let buttons = bottomRowButtons(b)
    guard !buttons.isEmpty else { die("找不到播放条按钮") }
    out("播放条按钮候选: " + buttons.map { "(\(Int($0.pos.x + $0.size.width/2)),\(Int($0.pos.y + $0.size.height/2)))" }.joined(separator: " "))

    // ---- 2. 全屏捕获（唯一坐标基准）----
    // 返回：图像、显示区域、每逻辑点对应像素数
    func grab() -> (CGImage, CGRect, CGFloat)? {
        // 排他捕获目标 app：排除 WorkBuddy 等其它窗口，避免读到自己的界面
        if let (img, org) = captureAppWindow(b) {
            return (img, org, CGFloat(img.width) / org.width)
        }
        guard let (img, frame) = captureDisplay() else { return nil }
        return (img, frame, CGFloat(img.width) / frame.width)
    }
    /// grab() 返回的图像与屏幕坐标的换算参数
    func makeMapper(_ img: CGImage, _ org: CGRect, _ scale: CGFloat) -> (Double, Double) {
        (org.origin.x, org.origin.y)
    }
    /// 在屏幕区域做 OCR，返回 (文本, 屏幕中心坐标, 置信度)
    /// 注意：img 的原点是 org.origin（排他捕获时是 app 窗口左上角）
    func readText(_ img: CGImage, _ org: CGRect, _ scale: CGFloat, _ rect: CGRect) -> [(String, CGPoint, Float)] {
        let rel = CGRect(x: (rect.origin.x - org.origin.x) * scale, y: (rect.origin.y - org.origin.y) * scale,
                         width: rect.width * scale, height: rect.height * scale)
        guard let cr = img.cropping(to: rel) else { return [] }
        var res: [(String, CGPoint, Float)] = []
        for (text, bb, conf) in ocrItems(cr) {
            let b2 = CGRect(x: bb.origin.x * CGFloat(cr.width), y: bb.origin.y * CGFloat(cr.height),
                            width: bb.width * CGFloat(cr.width), height: bb.height * CGFloat(cr.height))
            let cx = rect.origin.x + Double(b2.midX) / Double(scale)
            let cy = rect.origin.y + Double(CGFloat(cr.height) - b2.midY) / Double(scale)
            res.append((text, CGPoint(x: cx, y: cy), conf))
        }
        return res
    }
    /// 解析百分比：从 OCR 文本里抠出整数
    func parsePct(_ s: String) -> Int? {
        guard s.contains("%") else { return nil }
        let head = s.split(separator: "%").first ?? ""
        let digits = head.filter { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    // 播放条右侧图标区的包围盒（扫描蓝点用）
    let barRegion: (minX: Double, maxX: Double, maxY: Double) = {
        let xs = buttons.map { $0.pos.x + $0.size.width / 2 }
        let ys = buttons.map { $0.pos.y + $0.size.height / 2 }
        return (xs.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
    }()

    /// 读当前状态：蓝色滑块圆心 + 百分比 + 轨道 x
    /// 策略（不猜气泡位置）：全屏扫描 → 找「饱和蓝像素簇」= 滑块圆点
    ///   → 圆点 x 即轨道 x → 圆点下方就是百分比文字
    let verbose = a.has("verbose")
    func probe() -> (pct: Int, knobY: Double, trackX: Double)? {
        guard let (img, org, scale) = grab() else { return nil }
        guard let buf = pixels(img) else { return nil }
        // 扫描范围：播放条右半区（图标行）正上方 300pt 的带状区域
        // 用 barRegion 而非 sp，避免与喇叭识别形成循环依赖
        // 图像像素坐标 = (屏幕坐标 - org.origin) * scale
        let topY = max(0, Int((barRegion.maxY - 300 - org.origin.y) * scale))
        let botY = min(buf.h, Int((barRegion.maxY - 8 - org.origin.y) * scale))
        let x0 = max(0, Int((barRegion.minX - 30 - org.origin.x) * scale))
        let x1 = min(buf.w, Int((barRegion.maxX + 30 - org.origin.x) * scale))
        // 蓝色滑块的结构（实测）：一个圆形手柄 + 一条向下的「已填充轨道」尾迹
        // → 圆点是蓝像素簇的「最上端」，取中点会落到尾迹上（曾导致大量误判）
        var best: (cx: Int, cy: Int, count: Int)? = nil
        for cx in x0..<x1 {
            var run: [Int] = []
            var bestRun: [Int] = []
            for cy in topY..<botY {
                let i = (cy * buf.w + cx) * 4
                let r = Int(buf.buf[i]), g = Int(buf.buf[i+1]), bl = Int(buf.buf[i+2])
                let sat = max(r, max(g, bl)) - min(r, min(g, bl))
                if sat > 45 && bl >= r + 25 {
                    run.append(cy)
                } else {
                    if run.count > bestRun.count { bestRun = run }
                    run = []
                }
            }
            if run.count > bestRun.count { bestRun = run }
            // 手柄最宽（横向像素最多）的那一列即轨道所在列
            if bestRun.count > 8, best == nil || bestRun.count > best!.count {
                best = (cx: cx, cy: bestRun.first!, count: bestRun.count)
            }
        }
        if verbose {
            out("  [probe] org=\(Int(org.origin.x)),\(Int(org.origin.y)) \(Int(org.width))x\(Int(org.height)) scale=\(String(format: "%.1f", scale))")
            out("  [probe] 扫描区 x \(x0)..\(x1) y \(topY)..\(botY) (px)")
        }
        guard let b = best else {
            if verbose { out("  [probe] 未找到蓝色滑块") }
            return nil
        }
        let trackX = Double(b.cx) / Double(scale) + org.origin.x
        let knobY = Double(b.cy) / Double(scale) + org.origin.y
        // 百分比文字固定在气泡底部（不随圆点移动）
        // → 搜索范围从「气泡顶部」到「气泡底部」，而不是从圆点往下（圆点高时会漏掉）
        let bubbleTop = knobY - 200
        let pctRect = CGRect(x: trackX - 55, y: bubbleTop, width: 110, height: 260)
        var pctVal: Int? = nil
        for (text, _, conf) in readText(img, org, scale, pctRect) where conf > 0.12 {
            if let v = parsePct(text) { pctVal = v; break }
        }
        if verbose {
            out("  [probe] 蓝点 @(\(Int(b.cx)),\(Int(b.cy)))px → 屏幕(\(Int(trackX)),\(Int(knobY)))  百分比=\(pctVal.map(String.init) ?? "未读到")")
        }
        guard let pv = pctVal else { return nil }
        return (pct: pv, knobY: knobY, trackX: trackX)
    }

    // ---- 3. 自动识别喇叭按钮 ----
    // 气泡是「开关式」：可能本来就开着。所以先探测现状：
    //   情况 A：气泡已开 → 蓝点 x 就是喇叭 x，直接反推喇叭位置
    //   情况 B：气泡关闭 → 逐个候选点击，看哪个能弹出气泡
    var sp = CGPoint.zero
    var found = false
    if let st0 = probe() {
        // 气泡已开：轨道 x = 喇叭 x（气泡与喇叭垂直对齐）
        sp = CGPoint(x: st0.trackX, y: buttons.map { $0.center.y }.min() ?? st0.trackX)
        found = true
        out("✓ 气泡已开，轨道 x=\(Int(st0.trackX))")
    } else {
        for cand in buttons {
            let c = cand.center
            mouseClick(c)
            usleep(450_000)
            if probe() != nil {
                sp = c
                found = true
                out("✓ 喇叭按钮 = @(\(Int(c.x)),\(Int(c.y)))")
                break
            }
            // 不是音量按钮 → 可能是别的开关，再点一次复原
            mouseClick(c)
            usleep(250_000)
        }
    }
    if !found { die("所有候选按钮都无法弹出音量气泡") }

    // ---- 4. 读取当前状态 ----
    guard var cur = probe() else { die("无法读取音量气泡") }
    out("当前 \(cur.pct)%  蓝点 y=\(Int(cur.knobY))  轨道 x=\(Int(cur.trackX))")

    // 调试导出
    if !a.str("save").isEmpty, let (img, org, scale) = grab() {
        let bubbleRect = CGRect(x: cur.trackX - 70, y: cur.knobY - 200, width: 140, height: 270)
        let rel = CGRect(x: (bubbleRect.origin.x - org.origin.x) * scale, y: (bubbleRect.origin.y - org.origin.y) * scale,
                         width: bubbleRect.width * scale, height: bubbleRect.height * scale)
        if let cr = img.cropping(to: rel) { savePNG(cr, a.str("save")); out("已保存气泡图 \(a.str("save"))") }
    }

    // ---- 5. 迭代逼近：拖拽 → 读回 → 用最新两点重新拟合 ----
    // 线性模型：pct = a * y + b（y 越小值越大）
    // 每轮用「当前点 + 上一轮点」两点拟合，比单点外推稳定得多
    var history: [(y: Double, pct: Int)] = [(cur.knobY, cur.pct)]
    var lastY = cur.knobY, lastPct = cur.pct

    for attempt in 0..<8 {
        if lastPct == target { out("✓ 应用音量 = \(lastPct)%"); return }
        // 拟合：至少两点；不足则先做大位移取第二点
        var a: Double, b: Double
        if history.count >= 2 {
            // 取最近两点（相邻两轮，位移大、信噪比高）
            let h0 = history[history.count - 2], h1 = history[history.count - 1]
            if h0.y == h1.y {
                a = -1.0; b = Double(h1.pct) - a * h1.y
            } else {
                a = Double(h1.pct - h0.pct) / (h1.y - h0.y)
                b = Double(h0.pct) - a * h0.y
            }
        } else {
            // 单点：假设行程 100pt，做一次大位移取第二点
            a = -1.0; b = Double(lastPct) - a * lastY
        }
        var wantY = (Double(target) - b) / a
        // 限幅：单次最多移动 70pt，防止跑飞
        wantY = max(lastY - 70, min(lastY + 70, wantY))
        // 位移过小会被 App 判为点击（会关闭气泡）→ 至少 6pt
        if abs(wantY - lastY) < 6 { wantY = lastY - 6 }
        out("  尝试 \(attempt + 1): \(lastPct)% → \(target)%，拟合 a=\(String(format: "%.3f", a))，拖到 y=\(Int(wantY))")
        mouseDragSlow(CGPoint(x: cur.trackX, y: lastY), CGPoint(x: cur.trackX, y: wantY), steps: 24)
        usleep(600_000)

        // 读回
        var st: (pct: Int, knobY: Double, trackX: Double)?
        if let p = probe() { st = p }
        else {
            out("  气泡消失，重开")
            mouseClick(sp); usleep(500_000)
            st = probe()
        }
        guard let s2 = st else {
            // 重开失败：可能点错了位置（原按钮已移位）→ 重新扫描播放条
            out("  重开失败，重新扫描播放条按钮")
            mouseClick(sp); usleep(400_000)
            mouseClick(sp); usleep(400_000)
            guard let s3 = probe() else { die("气泡无法恢复") }
            lastY = s3.knobY; lastPct = s3.pct; cur = s3
            history = [(s3.knobY, s3.pct)]
            continue
        }
        out("  → 读回 \(s2.pct)% @ y=\(Int(s2.knobY))")
        lastY = s2.knobY; lastPct = s2.pct
        cur = s2
        history.append((s2.knobY, s2.pct))
        if history.count > 4 { history.removeFirst(history.count - 4) }
    }
    out("最终应用音量 = \(cur.pct)%（目标 \(target)%）")
}

/// set 音量气泡：闭环点击 + 读回百分比
func cmdSetVolumeBubble() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用") }
    let target = a.int("to", 70)
    let hue = a.str("hue", "blue")

    func readPct() -> Int? {
        guard let ax = appElement(b) else { return nil }
        var nodes: [Node] = []
        for w in windows(of: ax) { walk(w, 0, 40, &nodes) }
        var extra: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &extra) == .success,
           let kids = extra as? [AXUIElement] {
            for k in kids { walk(k, 0, 40, &nodes) }
        }
        for n in nodes {
            let t = n.title
            if t.hasSuffix("%"), t.count <= 4, let v = Int(t.dropLast()) { return v }
        }
        return nil
    }
    func pctPos() -> CGPoint? {
        guard let ax = appElement(b) else { return nil }
        var nodes: [Node] = []
        for w in windows(of: ax) { walk(w, 0, 40, &nodes) }
        var extra: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &extra) == .success,
           let kids = extra as? [AXUIElement] {
            for k in kids { walk(k, 0, 40, &nodes) }
        }
        for n in nodes where n.title.hasSuffix("%") && n.title.count <= 4 { return n.pos }
        return nil
    }

    // 打开气泡：点击播放条最底行按钮并检测百分比出现
    if readPct() == nil {
        for c in bottomRowButtons(b) {
            mouseClick(c.center); usleep(900_000)
            if readPct() != nil { break }
        }
    }
    guard let cur = readPct() else { die("未找到音量百分比控件") }
    out("当前应用音量 = \(cur)%")

    // 气泡通常在百分比文字正上方偏右
    guard let pctPos = pctPos() else { die("找不到百分比文本位置") }
    // 搜索区域：百分比文字正上方（竖向滑条在文字上方）
    let searchRect = CGRect(x: pctPos.x - 24, y: pctPos.y - 200, width: 90, height: 210)
    guard let bar = findColorBar(screenRect: searchRect, hue: hue) else {
        die("在区域 \(searchRect) 未找到 \(hue) 色滑条")
    }
    out("滑条 x=\(Int(bar.x))  y \(Int(bar.topY))..\(Int(bar.botY))")

    var topY = bar.topY, botY = bar.botY
    for attempt in 0..<8 {
        let wantY = botY - (botY - topY) * Double(target) / 100.0
        mouseClick(CGPoint(x: bar.x, y: wantY))
        usleep(800_000)
        guard let now = readPct() else { break }
        out("  尝试 \(attempt + 1): \(now)%")
        if now == target { out("✓ 应用音量 = \(now)%"); return }
        let perPct = (botY - topY) / 100.0
        let dy = Double(target - now) * perPct
        topY += dy; botY += dy
    }
    if let now = readPct() { out("最终应用音量 = \(now)%") } else { out("无法确认") }
}

/// 视觉定位辅助：把某个屏幕区域切成网格返回颜色特征，供多模态模型判读
func cmdScan() {
    let a = Args(ARGV)
    let r = a.str("rect")
    guard let rect = parseRect(r) else { die("需要 --rect x,y,w,h") }
    // --app 模式：基于该 app 的排他窗口图裁剪（不受遮挡影响）
    let bidOpt = a.str("app")
    if !bidOpt.isEmpty, let bid = Optional(bidOpt) {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            defer { sem.signal() }
            do {
                let content = try await SCShareableContent.current
                let wins = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == bid && $0.frame.height > 120 && $0.frame.width > 200
                }
                guard let display = content.displays.first else { return }
                let titled = wins.filter { !($0.title ?? "").isEmpty }
                let pool = titled.isEmpty ? wins : titled
                guard let target = pool.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
                let others = content.windows.filter { $0.windowID != target.windowID }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: others)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(display.frame.width) * 2
                cfg.height = Int(display.frame.height) * 2
                cfg.scalesToFit = false
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
                let scale = CGFloat(img.width) / display.frame.width
                let f = target.frame
                let winImg = img.cropping(to: CGRect(x: f.origin.x * scale, y: f.origin.y * scale, width: f.width * scale, height: f.height * scale))
                guard let winImg = winImg else { return }
                // 屏幕坐标 → 窗口内相对坐标
                let rel = CGRect(x: rect.origin.x - f.origin.x, y: rect.origin.y - f.origin.y, width: rect.width, height: rect.height)
                let crect = CGRect(x: rel.origin.x * scale, y: rel.origin.y * scale, width: rel.width * scale, height: rel.height * scale)
                guard let cr = winImg.cropping(to: crect) else { return }
                let outPath = a.str("out").isEmpty ? mediaPath("截图-选区", "png") : a.str("out")
                if let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(d, cr, nil); CGImageDestinationFinalize(d)
                    out("已保存 \(outPath) (\(cr.width)x\(cr.height))")
                    out("  ↳ 基准: 屏幕(\(Int(rect.origin.x)),\(Int(rect.origin.y)))，像素÷2 = 屏幕点")
                }
            } catch { out("ERR: \(error.localizedDescription)") }
        }
        sem.wait()
        return
    }
    guard let (img, frame) = captureDisplay() else { die("截图失败") }
    guard let c = crop(img, screenRect: rect, displayFrame: frame) else { die("裁剪失败") }
    let outPath = a.str("out").isEmpty ? mediaPath("截图-选区", "png") : a.str("out")
    savePNG(c, outPath)
    out("区域 \(r) 已保存 \(outPath) (\(c.width)x\(c.height)) 屏幕坐标基准: 左上(\(Int(rect.origin.x)),\(Int(rect.origin.y)))")
}


/// 诊断：为什么这个 app 的 AX 树读不到？
func cmdDiagnose() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用") }
    out("=== 诊断 \(b) ===")
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
        out("  pid=\(app.processIdentifier) active=\(app.isActive) hidden=\(app.isHidden) terminated=\(app.isTerminated)")
    } else {
        out("  应用未运行"); return
    }
    let ax = appElement(b)
    guard let ax = ax else { out("  AX 句柄创建失败"); return }
    let ws = windows(of: ax)
    out("  AX 窗口数 = \(ws.count)")
    if ws.isEmpty {
        out("  ⚠ AX 窗口为空 —— 常见原因：")
        out("    1) 该 app 窗口被其他窗口完全遮挡（macOS 会对被遮挡窗口停止 AX 投递）")
        out("    2) 该 app 正处于模态/弹窗状态")
        out("    3) 该 app 使用了自绘 UI，不暴露 AX")
        out("    4) Accessibility 权限不足")
    }
    // 统计节点
    var nodes: [Node] = []
    for w in ws { walk(w, 0, 40, &nodes) }
    out("  AX 节点数 = \(nodes.count)")
    if nodes.isEmpty && !ws.isEmpty {
        out("  ⚠ 窗口存在但树为空 —— 极可能是被遮挡")
    }
    // 遮挡检测：列出所有可见窗口，检查谁盖在上面
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.current
            let mine = content.windows.filter { $0.owningApplication?.bundleIdentifier == b && $0.frame.height > 100 }
            for w in mine {
                let f = w.frame
                out("  目标窗口 '\(w.title ?? "")' @(\(Int(f.origin.x)),\(Int(f.origin.y))) \(Int(f.width))x\(Int(f.height)) layer=\(w.windowLayer)")
                // 谁盖在上面
                for o in content.windows where o.windowID != w.windowID && o.frame.height > 60 {
                    let of_ = o.frame
                    let overlap = !(of_.origin.x + of_.width <= f.origin.x || of_.origin.x >= f.origin.x + f.width
                                 || of_.origin.y + of_.height <= f.origin.y || of_.origin.y >= f.origin.y + f.height)
                    if overlap && o.windowLayer >= 0 {
                        out("    ⛔ 被遮挡: '\(o.title ?? "")' @(\(Int(of_.origin.x)),\(Int(of_.origin.y))) \(Int(of_.width))x\(Int(of_.height)) layer=\(o.windowLayer) [\(o.owningApplication?.applicationName ?? "?")]")
                    }
                }
            }
        } catch { out("  SCK 枚举失败: \(error.localizedDescription)") }
    }
    sem.wait()
    out("=== 建议 ===")
    out("  先 `macctl front --app \(b)` 把它置前，再读 AX；或用 `macctl shot` 走视觉路线")
}



/// 找出某窗口上未被其他窗口遮挡的采样点
func findExposedPoint(targetFrame: CGRect, excludeApp: String) -> CGPoint? {
    let sem = DispatchSemaphore(value: 0)
    var best: CGPoint? = nil
    var bestScore = -1.0
    Task.detached {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.current
            let others = content.windows.filter {
                $0.owningApplication?.bundleIdentifier != excludeApp &&
                $0.frame.height > 40 && $0.frame.width > 40 &&
                $0.windowLayer >= 0
            }
            // 在目标窗口内网格采样
            let stepsX = 12, stepsY = 8
            var pts: [(CGPoint, Double)] = []
            for iy in 0..<stepsY {
                for ix in 0..<stepsX {
                    let fx = (Double(ix) + 0.5) / Double(stepsX)
                    let fy = (Double(iy) + 0.5) / Double(stepsY)
                    let p = CGPoint(x: targetFrame.origin.x + targetFrame.width * fx,
                                    y: targetFrame.origin.y + targetFrame.height * fy)
                    var covered = 0
                    for o in others {
                        let f = o.frame
                        if p.x >= f.origin.x && p.x <= f.origin.x + f.width &&
                           p.y >= f.origin.y && p.y <= f.origin.y + f.height { covered += 1 }
                    }
                    pts.append((p, Double(covered)))
                }
            }
            // 选遮挡最少的点
            let minCover = pts.map { $0.1 }.min() ?? 0
            let candidates = pts.filter { $0.1 == minCover }
            if !candidates.isEmpty {
                // 在这些点中选靠近中心偏上的（通常是标题栏/内容区）
                let c = candidates.min { a, b in
                    let da = abs(a.0.x - targetFrame.midX) + abs(a.0.y - targetFrame.origin.y + 40) * 0.6
                    let db = abs(b.0.x - targetFrame.midX) + abs(b.0.y - targetFrame.origin.y + 40) * 0.6
                    return da < db
                }
                best = c?.0
                bestScore = minCover
            }
        } catch { }
    }
    sem.wait()
    if best != nil { out("  可点击未遮挡点: (\(Int(best!.x)),\(Int(best!.y))) 遮挡层数=\(Int(bestScore))") }
    return best
}

/// 智能置前：点击目标窗口上未被遮挡的位置（抗遮挡）
func cmdRaise() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用") }
    // ⚠ 应用未运行时**自动拉起**（2026-10-22 实测修正）：
    //   原来直接 die("应用未运行") → 面板上的「打开微信」按钮在微信没开时
    //   点了毫无反应，用户只会认为按钮坏了。
    //   语义上「raise 就是让这个 App 出现在前台」，没运行就该先启动，
    //   否则「点两下才生效」是明显的交互缺陷。
    var app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first
    if app == nil {
        if a.has("no-launch") {
            die("应用未运行（已按 --no-launch 跳过自动启动）")
        }
        // ⚠ 用 launchSilently（/usr/bin/open CLI）启动，**不要用 NSWorkspace.openApplication**：
        //   ① open -a 要的是**应用名**不是 bundle id（`open -a com.kugou.mac.Music` 报
        //      "Unable to find application named ..."），但 `open -b <bundleid>` 可以；
        //   ② 更重要：openApplication 失败会弹**系统级**模态框
        //      （CoreServicesUIAgent「应用程序无法打开」），用户关不掉、
        //      还会挡住桌面 —— 闪控是后台工具，绝不能往用户脸上弹系统对话框。
        let ws = NSWorkspace.shared
        let appURL = ws.urlForApplication(withBundleIdentifier: b)
        let (accepted, launchErr) = launchSilently(
            bundleID: b, path: appURL?.path ?? "")
        if !accepted {
            die("启动应用失败: \(b)\(launchErr.isEmpty ? "" : "（\(launchErr)）")")
        }
        // 轮询等它起来（实测约 0.6-1.2s）
        for _ in 0..<24 {
            usleep(100_000)
            if let a2 = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
                app = a2; break
            }
        }
        guard let a2 = app else { die("启动应用失败: \(b)") }
        usleep(600_000)   // 等窗口创建
    }
    guard let app = app else { die("应用未运行") }

    app.activate(options: [.activateAllWindows])
    usleep(500_000)
    if let ax = appElement(b) { for w in windows(of: ax) { AXUIElementPerformAction(w, kAXRaiseAction as CFString) } }
    usleep(400_000)

    // 找目标窗口 frame
    let sem = DispatchSemaphore(value: 0)
    var frame: CGRect? = nil
    Task.detached {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.current
            let mine = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == b &&
                $0.frame.height > 300 && $0.frame.width > 400
            }
            // 优先有标题的窗口，否则取面积最大
            let titled = mine.filter { !($0.title ?? "").isEmpty }
            let pool = titled.isEmpty ? mine : titled
            if let m = pool.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                frame = m.frame
                out("  选中窗口: '\(m.title ?? "")' @(\(Int(m.frame.origin.x)),\(Int(m.frame.origin.y))) \(Int(m.frame.width))x\(Int(m.frame.height))")
            } else {
                out("  ⚠ 未找到合适窗口（>300x400）")
            }
        } catch { }
    }
    sem.wait()

    if let f = frame {
        out("目标窗口 @(\(Int(f.origin.x)),\(Int(f.origin.y))) \(Int(f.width))x\(Int(f.height))")
        if let pt = findExposedPoint(targetFrame: f, excludeApp: b) {
            mouseClick(pt)
            usleep(1_200_000)
        }
    }
    let n2 = treeNodes(bundleID: b, maxDepth: 8)
    if n2.isEmpty {
        out("⚠ AX 树仍为空：可能存在全屏/置顶浮窗，用 `macctl scwindows` 查 layer>0 的窗口")
    } else {
        out("✓ \(app.localizedName ?? b) AX 节点 \(n2.count)")
    }
}


/// 通过 Dock 图标切换到目标 app（抗遮挡，最可靠的置前方式）
func cmdDock() {
    let a = Args(ARGV)
    let target = a.str("app").isEmpty ? a.positional.first ?? "" : a.str("app")
    guard !target.isEmpty else { die("需要 --app <名称>") }
    var wantBundle = resolveBundle(target)
    for app in NSWorkspace.shared.runningApplications {
        if app.localizedName == target || app.bundleIdentifier == target {
            wantBundle = app.bundleIdentifier
        }
    }
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
        die("未找到 Dock 进程")
    }
    dock.activate(options: [.activateAllWindows])
    usleep(500_000)
    let ax = AXUIElementCreateApplication(dock.processIdentifier)
    var found: [(AXUIElement, String, CGPoint, CGSize)] = []
    func walk(_ el: AXUIElement) {
        let role = axStr(el, kAXRoleAttribute)
        let t = axStr(el, kAXTitleAttribute)
        let d = axStr(el, kAXDescriptionAttribute)
        // ⚠ 实测踩过（D-019）：Dock 图标的角色是 **AXDockItem**，不是 AXButton。
        //   原实现只认 AXButton → 一个图标都匹配不到 → 报「Dock 未找到 X」，
        //   但 Dock 上明明有。这是「Dock 明明有图标却说找不到」的真正根因。
        //   AXDockItem 有 title（应用名），坐标也能正常取到。
        if role == "AXDockItem" || role == "AXButton" {
            let label = t.isEmpty ? d : t
            if !label.isEmpty { found.append((el, label, axPos(el), axSize(el))) }
        }
        for c in children(el) { walk(c) }
    }
    // Dock 的 AX 窗口数为 0，图标全挂在 app 级子元素的 AXList 里 → 必须走 axRoots
    for w in axRoots(of: ax) { walk(w) }
    var hit: (AXUIElement, String, CGPoint, CGSize)? = nil
    for (el, label, p, sz) in found {
        if label.contains(target) { hit = (el, label, p, sz); break }
    }
    guard let (el, label, p, sz) = hit else {
        out("Dock 未找到 '\(target)'。Dock 图标: " + found.map { $0.1 }.joined(separator: ", "))
        exit(1)
    }
    out("Dock 图标 '\(label)' @(\(Int(p.x)),\(Int(p.y)))")
    // 优先走 AXPress：Dock 图标位置会随数量/缩放漂移，按语义点击比按坐标稳。
    // AXPress 失败再回退坐标点击（实测 Dock 有时不给 AXPress）。
    var pressed = false
    if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { pressed = true }
    if !pressed {
        mouseClick(CGPoint(x: p.x + sz.width / 2, y: p.y + sz.height / 2))
    }
    usleep(1_500_000)
    if let b = wantBundle {
        let nodes = treeNodes(bundleID: b, maxDepth: 8)
        out(nodes.isEmpty ? "⚠ 已点击但 AX 树仍为空" : "✓ 已切换，AX 节点 \(nodes.count)")
    } else { out("✓ 已点击 Dock 图标") }
}


/// 全局概览：按应用聚合窗口 + 遮挡关系 + 可点击建议
func cmdOverview() {
    let a = Args(ARGV)
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.current
            // 只看有意义的窗口
            let meaningful = content.windows.filter { w in
                w.frame.width > 60 && w.frame.height > 60
            }
            // 按应用聚合
            var byApp: [String: [(String, CGRect, Int)]] = [:]
            for w in meaningful {
                let appName = w.owningApplication?.applicationName ?? "?"
                byApp[appName, default: []].append((w.title ?? "", w.frame, w.windowLayer))
            }
            out("=== 桌面概览：\(meaningful.count) 个有效窗口 / \(byApp.count) 个应用 ===")
            for (app, ws) in byApp.sorted(by: { $0.value.count > $1.value.count }) {
                let biggest = ws.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height })
                out("  [\(app)] \(ws.count) 窗")
                for (t, f, l) in ws.sorted(by: { $0.1.width * $0.1.height > $1.1.width * $1.1.height }).prefix(3) {
                    out("    layer=\(l) '\(t)' @(\(Int(f.origin.x)),\(Int(f.origin.y))) \(Int(f.width))x\(Int(f.height))")
                }
            }
            // 找出「最上层的大窗口」——通常用户正在看的
            if let top = meaningful.filter({ $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                out("=== 最大 layer0 窗口（通常在最上） ===")
                out("  '\(top.title ?? "")' @(\(Int(top.frame.origin.x)),\(Int(top.frame.origin.y))) \(Int(top.frame.width))x\(Int(top.frame.height)) [\(top.owningApplication?.applicationName ?? "?")]")
            }
            // 置顶层（layer>0）的浮窗——这些最可能是障碍
            let floaters = meaningful.filter { $0.windowLayer > 0 }
            if !floaters.isEmpty {
                out("=== 置顶浮窗 (layer>0) —— 常见遮挡源 ===")
                for f in floaters.sorted(by: { $0.windowLayer > $1.windowLayer }) {
                    out("  layer=\(f.windowLayer) '\(f.title ?? "")' @(\(Int(f.frame.origin.x)),\(Int(f.frame.origin.y))) \(Int(f.frame.width))x\(Int(f.frame.height)) [\(f.owningApplication?.applicationName ?? "?")]")
                }
            }
        } catch { out("ERR: \(error.localizedDescription)") }
    }
    sem.wait()
}


/// 在屏幕区域里找"最像某个 app 图标"的圆角方形（用于点击 Dock 图标）
/// 策略：找该区域内饱和蓝色像素的聚集中心
func cmdFindIcon() {
    let a = Args(ARGV)
    guard let rect = parseRect(a.str("rect")) else { die("需要 --rect x,y,w,h") }
    let hue = a.str("hue", "blue")
    guard let (img, frame) = captureDisplay() else { die("截图失败") }
    guard let c = crop(img, screenRect: rect, displayFrame: frame) else { die("裁剪失败") }
    guard let px = pixels(c) else { die("像素失败") }
    // 逐列统计命中数，找聚集峰
    var colCount = [Int](repeating: 0, count: px.w)
    var rowCount = [Int](repeating: 0, count: px.h)
    var total = 0
    for y in 0..<px.h {
        for x in 0..<px.w {
            let i = (y * px.w + x) * 4
            let r = Int(px.buf[i]), g = Int(px.buf[i + 1]), b = Int(px.buf[i + 2])
            var hit = false
            switch hue {
            case "blue": hit = (b > 170 && r < 120 && b - r > 90)
            case "green": hit = (g > 130 && r < 130 && g - r > 50)
            case "red": hit = (r > 160 && g < 110 && r - g > 70)
            case "white": hit = (r > 240 && g > 240 && b > 240)
            default: hit = false
            }
            if hit { colCount[x] += 1; rowCount[y] += 1; total += 1 }
        }
    }
    guard total > 50 else { die("区域内未找到 \(hue) 色像素 (total=\(total))") }
    // 找列聚集峰
    var bestX = 0, bestV = 0
    for x in 0..<px.w where colCount[x] > bestV { bestV = colCount[x]; bestX = x }
    var bestY = 0, bestRV = 0
    for y in 0..<px.h where rowCount[y] > bestRV { bestRV = rowCount[y]; bestY = y }
    let scale = CGFloat(c.width) / rect.width
    let sx = rect.origin.x + Double(bestX) / Double(scale)
    let sy = rect.origin.y + Double(bestY) / Double(scale)
    out("\(hue) 聚集中心: 屏幕 (\(Int(sx)),\(Int(sy)))  命中 \(total) 像素, 列峰 x=\(bestX)(\(bestV)) 行峰 y=\(bestY)(\(bestRV))")
}


/// 列出某 app 的所有 AX 窗口（AXWindow 角色）+ 每个窗口的节点数
func cmdAXWindows() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用") }
    guard let ax = appElement(b) else { die("AX 失败") }
    var ws = windows(of: ax)
    out("=== AX 窗口 (kAXWindowsAttribute) \(ws.count) ===")
    for (i, w) in ws.enumerated() {
        let n = node(w)
        var cnt = 0
        var tmp: [Node] = []
        walk(w, 0, 40, &tmp); cnt = tmp.count
        out("  [\(i)] '\(n.title)' @(\(Int(n.pos.x)),\(Int(n.pos.y))) \(Int(n.size.width))x\(Int(n.size.height)) 节点=\(cnt)")
    }
    // app 级子元素
    var extra: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &extra) == .success,
       let kids = extra as? [AXUIElement] {
        out("=== app 级子元素 \(kids.count) ===")
        for (i, k) in kids.enumerated() {
            let n = node(k)
            var cnt = 0
            var tmp2: [Node] = []
            walk(k, 0, 40, &tmp2); cnt = tmp2.count
            out("  [\(i)] [\(n.role)] '\(n.text.prefix(40))' @(\(Int(n.pos.x)),\(Int(n.pos.y))) \(Int(n.size.width))x\(Int(n.size.height)) 节点=\(cnt)")
        }
    }
}


/// 原子化：打开音量气泡并立即读回百分比（气泡是瞬时的，必须连读）
func cmdVolProbe() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用") }
    guard let ax = appElement(b) else { die("AX 失败") }

    func pct() -> (Int, CGPoint)? {
        var nodes: [Node] = []
        for w in windows(of: ax) { walk(w, 0, 40, &nodes) }
        var extra: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &extra) == .success,
           let kids = extra as? [AXUIElement] {
            for k in kids { walk(k, 0, 40, &nodes) }
        }
        for n in nodes where n.title.hasSuffix("%") && n.title.count <= 4 {
            if let v = Int(n.title.dropLast()) { return (v, n.pos) }
        }
        return nil
    }

    // 若已有百分比直接返回
    if let (v, p) = pct() { out("pct=\(v) @(\(Int(p.x)),\(Int(p.y)))"); return }

    // 遍历播放条最底行按钮逐个点击，每次立即读
    let cands = bottomRowButtons(b)
    out("候选按钮 \(cands.count) 个: " + cands.map { "(\(Int($0.pos.x + $0.size.width/2)),\(Int($0.pos.y + $0.size.height/2)))" }.joined(separator: " "))

    for (i, c) in cands.enumerated() {
        mouseClick(c.center)
        // 立即连读，不等待
        for _ in 0..<12 {
            usleep(120_000)
            if let (v, p) = pct() {
                out("✓ 按钮#\(i) @(\(Int(c.pos.x + c.size.width/2)),\(Int(c.pos.y + c.size.height/2))) → pct=\(v) 文本@(\(Int(p.x)),\(Int(p.y)))")
                return
            }
        }
    }
    die("所有候选按钮都未产生音量气泡")
}


/// 拖拽：从一点拖到另一点
func cmdDrag() {
    let a = Args(ARGV)
    guard let from = a.pt("from") else { die("需要 --from x,y") }
    guard let to = a.pt("to") else { die("需要 --to x,y") }
    mouseDrag(from, to, steps: a.int("steps", 20))
    out("拖拽 (\(Int(from.x)),\(Int(from.y))) → (\(Int(to.x)),\(Int(to.y)))")
}

/// hover：纯鼠标移动，不点击（用于触发悬浮气泡 / tooltip）
func cmdHover() {
    let a = Args(ARGV)
    guard let pt = a.pt("at") else { die("需要 --at x,y") }
    mouseMove(pt)
    usleep(UInt32(a.int("wait", 300)) * 1000)
    out("悬停 (\(Int(pt.x)),\(Int(pt.y)))")
}


/// 纯 AX 动作：不依赖窗口在前台，直接对元素执行 AXPress / 设置值
func cmdAXAction() {
    let a = Args(ARGV)
    let bid = a.str("app").isEmpty ? (frontApp()?.bundleIdentifier ?? "") : a.str("app")
    guard let b = resolveBundle(bid) else { die("无法定位应用") }
    guard let ax = appElement(b) else { die("AX 失败") }
    var nodes: [Node] = []
    for w in windows(of: ax) { walk(w, 0, 40, &nodes) }
    var extra: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &extra) == .success,
       let kids = extra as? [AXUIElement] {
        for k in kids { walk(k, 0, 40, &nodes) }
    }

    // --index 精确指定
    if let idx = a.flags["index"].flatMap(Int.init) {
        guard idx >= 0, idx < nodes.count else { die("index 越界 (共 \(nodes.count))") }
        let n = nodes[idx]
        let r = AXUIElementPerformAction(n.el, kAXPressAction as CFString)
        out("AXPress [\(n.role)] '\(n.text.prefix(50))' @(\(Int(n.pos.x)),\(Int(n.pos.y))) -> \(r.rawValue)")
        return
    }
    // --text 定位后 AXPress
    let text = a.str("text")
    guard !text.isEmpty else { die("需要 --text 或 --index") }
    let ms = findNodes(nodes, text: text, role: a.flags["role"])
    guard let m = ms.first else { die("未找到 '\(text)'") }
    let n = m.node
    let r = AXUIElementPerformAction(n.el, kAXPressAction as CFString)
    out("AXPress [\(n.role)] '\(n.text.prefix(50))' @(\(Int(n.pos.x)),\(Int(n.pos.y))) -> \(r.rawValue)")
    if r != .success { out("  ⚠ AXPress 失败，建议改用 `macctl click --at x,y`") }
}


/// OCR 区域内文字并点击指定词（用 Vision 框架）
func cmdTapText() {
    let a = Args(ARGV)
    let target = a.str("text").isEmpty ? a.positional.first ?? "" : a.str("text")
    guard !target.isEmpty else { die("需要 --text") }
    let rect = parseRect(a.str("rect"))
    let appOpt = a.str("app")

    // 取图：--app 用排他窗口图，否则全屏
    var img: CGImage? = nil
    var origin = CGPoint.zero
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(display.frame.width) * 2
            cfg.height = Int(display.frame.height) * 2
            cfg.scalesToFit = false
            if !appOpt.isEmpty {
                let wins = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == appOpt && $0.frame.height > 120 && $0.frame.width > 200
                }
                let titled = wins.filter { !($0.title ?? "").isEmpty }
                let pool = titled.isEmpty ? wins : titled
                guard let target = pool.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
                let others = content.windows.filter { $0.windowID != target.windowID }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: others)
                guard let full = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
                let scale = CGFloat(full.width) / display.frame.width
                let f = target.frame
                img = full.cropping(to: CGRect(x: f.origin.x * scale, y: f.origin.y * scale, width: f.width * scale, height: f.height * scale))
                origin = f.origin
            } else {
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                origin = .zero
            }
        } catch { }
    }
    sem.wait()
    guard let base = img else { die("截图失败") }

    // 限定区域
    var workImg = base
    var workOrigin = origin
    if let r = rect {
        let rel = CGRect(x: (r.origin.x - origin.x) * 2.0, y: (r.origin.y - origin.y) * 2.0, width: r.width * 2.0, height: r.height * 2.0)
        guard let c = base.cropping(to: rel) else { die("裁剪失败") }
        workImg = c
        workOrigin = CGPoint(x: r.origin.x, y: r.origin.y)
    }

    // Vision OCR
    guard let cg = workImg as CGImage? else { die("图像无效") }
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    do {
        try handler.perform([request])
    } catch { die("OCR 失败: \(error.localizedDescription)") }
    guard let obs = request.results, !obs.isEmpty else { die("OCR 无结果") }

    let scale = CGFloat(cg.width) / (rect.map { $0.width } ?? CGFloat(cg.width) / 2)
    var best: (String, CGRect)? = nil
    var bestConf: Float = -1
    for o in obs {
        guard let t = o.topCandidates(1).first else { continue }
        if t.string.contains(target) || target.contains(t.string) {
            let b = o.boundingBox
            let r = CGRect(x: b.origin.x * CGFloat(cg.width), y: b.origin.y * CGFloat(cg.height), width: b.width * CGFloat(cg.width), height: b.height * CGFloat(cg.height))
            if t.confidence > bestConf { bestConf = t.confidence; best = (t.string, r) }
        }
    }
    guard let (text, bbox) = best else {
        out("OCR 结果:")
        for o in obs { if let t = o.topCandidates(1).first { out("  '\(t.string)' (\(String(format: "%.2f", t.confidence)))") } }
        die("未找到 '\(target)'")
    }
    // Vision 坐标原点在左下，需翻转 y
    let cx = workOrigin.x + (bbox.midX / 2)
    let cy = workOrigin.y + (Double(cg.height) - bbox.midY) / 2
    out("OCR 命中 '\(text)' -> 点击 (\(Int(cx)),\(Int(cy)))")
    mouseClick(CGPoint(x: cx, y: cy))
}

/// OCR 识别：返回 (文本, 归一化包围盒) 列表
/// 图像坐标原点在左下（Vision 惯例）
func ocrItems(_ img: CGImage) -> [(String, CGRect, Float)] {
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    guard (try? handler.perform([request])) != nil else { return [] }
    guard let obs = request.results else { return [] }
    var items: [(String, CGRect, Float)] = []
    for o in obs {
        guard let t = o.topCandidates(1).first else { continue }
        items.append((t.string, o.boundingBox, t.confidence))
    }
    return items
}

/// cmdOCR: 读区域内的所有文字（可加 --app 排他捕获、--num 只看数字）
func cmdOCR() {
    let a = Args(ARGV)
    let bid = a.str("app")
    let rect = parseRect(a.str("rect"))
    let wantNum = a.flags["num"] != nil
    let saveTo = a.str("out")

    // 取图：--app 用排他窗口图（原点=窗口左上），否则全屏
    var base: CGImage? = nil
    var origin = CGPoint.zero
    var scale: CGFloat = 2.0

    if !bid.isEmpty {
        if let (img, org) = captureAppWindow(bid) {
            base = img; origin = org.origin
        } else { die("排他捕获 \(bid) 失败") }
    } else {
        if let (img, frame) = captureDisplay() {
            base = img
            origin = .zero
            scale = CGFloat(img.width) / frame.width
        } else { die("截图失败") }
    }
    guard let full = base else { die("截图失败") }

    // 区域裁剪（rect 为屏幕逻辑坐标）
    var work = full
    var workOrigin = origin
    if let r = rect {
        let rel = CGRect(x: (r.origin.x - origin.x) * scale, y: (r.origin.y - origin.y) * scale,
                         width: r.width * scale, height: r.height * scale)
        guard let c = full.cropping(to: rel) else { die("裁剪失败") }
        work = c
        workOrigin = CGPoint(x: r.origin.x, y: r.origin.y)
    }

    if !saveTo.isEmpty { savePNG(work, saveTo); out("已保存 \(saveTo) (\(work.width)x\(work.height))") }

    let items = ocrItems(work)
    if items.isEmpty { out("OCR 无结果"); return }
    let imgScale = CGFloat(work.width) / (rect.map { CGFloat($0.width) } ?? (CGFloat(work.width) / scale))
    for (text, bb, conf) in items {
        if wantNum {
            let digits = text.filter { $0.isNumber }
            if digits.isEmpty { continue }
        }
        let px = CGRect(x: bb.origin.x * CGFloat(work.width), y: bb.origin.y * CGFloat(work.height),
                        width: bb.width * CGFloat(work.width), height: bb.height * CGFloat(work.height))
        // Vision 原点左下 → 屏幕坐标
        let cx = workOrigin.x + Double(px.midX) / Double(imgScale)
        let cy = workOrigin.y + Double(CGFloat(work.height) - px.midY) / Double(imgScale)
        out("'\(text)' @(\(Int(cx)),\(Int(cy))) conf=\(String(format: "%.2f", conf))")
    }
}

func cmdHelp() {
    out("""
macctl \(VERSION) — macOS 桌面自动化统一工具

用法: macctl <命令> [选项]

  ⚡ 通用选项: --json   让命令输出结构化 JSON（供上层脚本精确解析）

  state      --app <id> [--text <过滤>] [--depth N] [--shot <路径>]
             一次拿到：前台应用、窗口列表、AX 树、焦点、截图
  apps                                  列出运行中的应用
  windows   --app <id>                 列出窗口及坐标
  tree      --app <id> [--role R] [--text T] [--depth N]
  find      --text <T> [--app all|id] [--role R] [--limit N]
  click     --text <T> [--app <id>] [--count N] [--scroll N] | --at x,y
  type      --text <T> [--app <id>]    智能输入（AX/粘贴/Unicode 自动择优并记忆）
  key       --key <name> [--cmd] [--shift] [--count N]
  mods      --ctrl --alt --cmd          合成「纯修饰键组合」（测三键同按类热键）
  clear     [--app <id>]                清空聚焦输入框（AX 优先，回退 cmd+a+delete）
  volume    [--set N]                  系统输出音量
  app-volume --app <id> --to N         应用内音量（AXSlider 或气泡像素闭环）
  shot      [--out <路径>] [--rect x,y,w,h] [--app <id>]
  pixel     --at x,y                   读取屏幕某点颜色
  wait      --text <T> [--timeout S] [--app <id>]
  scroll    [--dir up|down|left|right] [--n N] [--at x,y] [--app <id>]
  front     --app <id>                 激活应用
  launch    --name <应用名>            按名称启动/唤醒应用（没运行会自动拉起）
  scwindows [--app <id>]              列出所有屏幕窗口（含 AX 不可见的浮窗/图层）
  close-popup --app <id>               ESC 关闭浮窗并回报剩余窗口
  set-volume-bubble --app <id> --to N [--hue blue|red|green]
                                     音量气泡闭环调值（点击-读回-校正）
  scan     --rect x,y,w,h [--out <路径>]  裁剪屏幕区域供视觉判读
  diagnose --app <id>                   诊断 AX 树为何读不到（遮挡/权限/自绘）
  raise      --app <id> [--close-others]  强行置前（activate+AX raise+点击标题栏）
  dock       --app <名称>               通过 Dock 图标切换（抗遮挡，最可靠置前）
  overview                              桌面全局概览（窗口聚合+置顶浮窗+遮挡源）
  find-icon --rect x,y,w,h [--hue blue|green|red|white]
                                     在区域内定位彩色图标中心（点 Dock 用）
  axwindows --app <id>                 列出 app 的所有 AX 窗口及节点数
  vol-probe --app <id>                 原子探测音量气泡（点击后立即读百分比）
  vol-set   --app <id> --to N          应用内音量闭环调值（OCR读数+滑块视觉定位+差值校正）
  drag      --from x,y --to x,y [--steps N]   鼠标拖拽
  hover     --at x,y [--wait ms]            纯鼠标移动不点击（触发悬浮气泡/tooltip）
  ocr       [--rect x,y,w,h] [--app <id>] [--num] [--out <路径>]
                                     OCR 读区域文字（--app 排他捕获，--num 只看数字）
  axclick  --text <T> [--role R] | --index N [--app <id>]
                                     纯 AX 动作（不依赖窗口在前台，适合 WorkBuddy 挡屏时）
  tap-text --text <词> [--rect x,y,w,h] [--app <id>]
                                     OCR 识别区域文字并点击（坐标盲区终极解法）
  recall                                查看学习缓存
  note      --app <id> --text <描述>    记录 App 交互模型备注

  键名: return tab space esc left right up down delete a-z
""")
}

// MARK: - 入口

let ARGV = CommandLine.arguments
let args = Args(ARGV)
// 全局 --out 支持：state/find/tree 等命令的 JSON 输出可直接落盘
// （大 JSON 走管道会被截断 —— Swift FileHandle 写管道时下游提前读会丢数据）
let outPath = args.str("out")
if args.has("out") && !outPath.isEmpty {
    let cmds = ["state", "find", "tree", "apps", "volume", "locate"]
    if cmds.contains(args.cmd) { outFileOpen(outPath) }
}
switch args.cmd {
case "apps": cmdApps()
case "windows": cmdWindows()
case "winback": cmdWinback()
case "probe": cmdProbe()
case "doctor": cmdDoctor()
case "state": cmdState()
case "tree": cmdTree()
case "find": cmdFind()
case "locate": cmdLocate()
case "click": cmdClick()
case "type": cmdType()
case "key": cmdKey()
    case "mods": cmdMods()
case "clear": cmdClear()
case "volume": cmdVolume()
case "app-volume": cmdAppVolume()
case "shot": cmdShot()
case "pixel": cmdPixel()
case "wait": cmdWait()
case "scroll": cmdScroll()
case "front": cmdFront()
case "launch": cmdLaunch()
case "scwindows": cmdSCWindows()
case "close-popup": cmdClosePopup()
case "set-volume-bubble": cmdSetVolumeBubble()
case "scan": cmdScan()
case "diagnose": cmdDiagnose()
case "raise": cmdRaise()
case "dock": cmdDock()
case "overview": cmdOverview()
case "find-icon": cmdFindIcon()
case "axwindows": cmdAXWindows()
case "vol-probe": cmdVolProbe()
case "vol-set": cmdVolSet()
case "drag": cmdDrag()
case "hover": cmdHover()
case "ocr": cmdOCR()
case "axclick": cmdAXAction()
case "tap-text": cmdTapText()
case "recall": cmdRecall()
case "note": cmdNote()
case "version": out(VERSION)
default: cmdHelp()
}
// 落盘句柄必须显式关闭：Swift 不会自动 flush，进程退出时缓冲区内容可能丢失
if let h = gOutHandle { try? h.close() }
