import Foundation
import AppKit
import CoreText
import ServiceManagement
import Carbon
import ApplicationServices

// ============================================================
// flash — 闪控指令面板（v5 · 深空玻璃拟态）
//
// ── v5 改了什么（用户三条实测反馈）────────────────────────
//
//   ①「窗口太难看，排版混乱，都超格了」
//      → 根因不是配色，是**布局没有单一算式**：v2~v4 的高度是手写的估值，
//        按钮区只按 3 行算，实际有超出的部分跑到卡片外 → 文字/控件越界。
//      → v5 的硬规矩：**所有尺寸由一组常量算出，几何全部写在 Layout 里，
//        并且提供 `--layout-check` 模式做递归越界自检**（见 validateLayout）。
//        这不是"这次排好看点"，是让"排版错"这件事以后不可能再发生。
//
//   ②「截图和录屏的文件我不清楚会放在哪个位置」
//      → 落点固定且分家（P10）：`~/桌面/灵台智枢/截图/年/月/` 与
//        `~/桌面/灵台智枢/录屏/年/月/`，文件名形如 `20261025-102538.png`
//        （yyyyMMdd-HHmmss，保证「按文件名排序 == 按时间排序」）。
//        面板底部常驻显示这个位置（年月随当下时间走）。
//
//   ③「把桌面按钮换成 iKuuuVPN」
//      → 常用区最后一格从「桌面」换成 iKuuuVPN，走 macctl launch，
//        并在 macctl 别名表里补了 vpn/加速器/飞机 等口语映射。
//
// ── v5 视觉语言 ─────────────────────────────────────────────
//
//   深空底 + 双色辉光 + 玻璃卡片 + SF Symbols 线性图标。
//   选中「不用emoji」：emoji 在 macOS 上是彩色位图字体，跟线性图标混排
//   时字号基线对不齐、饱和度不统一 —— 这正是"看起来不专业"的主要来源。
// ============================================================

let HOTKEY_SIG: OSType = 0x4D4B5353
let HOTKEY_ID: UInt32 = 1
// ⚠⚠ 主键为什么从 ⌃⌥Space 改成 **⌃⌥S**（2026-10-23 用户决定）：
//   macOS 默认把 ⌃⌥Space 绑给了「选择下一个输入法」（symbolichotkeys key 61，
//   parameters=[32,49,786432]）。系统级快捷键抢在应用前面消费按键，导致闪控
//   时而能收到、时而收不到 —— 用户原话「时好时坏，老出问题」。
//   ⌃⌥S（kVK_ANSI_S = 1）没有任何系统占用，Carbon 与事件监听两条通道都稳定。
//   决定是「应用避开系统」，而不是「让用户改系统」——所以系统那个快捷键保持原样。
// 主键 = **⌃⌥Space**（用户 2026-10-23 最终选定：三个键、好按）。
//
// ⚠ macOS 默认把 ⌃⌥Space 绑给了「系统设置 > 键盘 > 快捷键 > 输入法 >
//   选择下一个输入法」（symbolichotkeys key 61，parameters=[32,49,786432]）。
//   系统级快捷键会抢在应用前面消费按键 —— 这就是"时好时坏"的真正原因。
//   所以用这个组合的前提是：**把系统那条关掉**（`flashctl.sh ime-key off`）。
//   ⌃⌥Space 有真实键码，Carbon 能正常注册，是双通道，比"纯修饰键"稳。
let DEFAULT_KEY: UInt32 = 49                  // kVK_Space
let DEFAULT_MODS: UInt32 = UInt32(controlKey | optionKey)

var gHotKey: EventHotKeyRef?

// MARK: - 设计令牌

// MARK: - 色板（工业档案画风）
//
// ⚠ 色板不是"换几个颜色"就完了 —— 它和**结构**是一套东西：
//   深近黑底 + 发丝细线 + 单一橙色主色 + 等宽字体做数据，
//   这四件事绑在一起才是"技术档案"的观感。少任何一件都会退化成
//   "又一个深色玻璃面板"。
// 取值对齐开场动画的 CSS 变量（bootanim/web/splash.css），
// 保证灵台智枢和启动动画看起来是同一套设计语言。
enum Palette {
    /* 主色：参考稿 splash.css 的 --dsu-accent #ff7500。
       ⚠ 上一版是青绿 #2bd9a0，那是 WorkBuddy 图标色；参考稿整套视觉语言里
         只有**一个**强调色，而且它不是绿色 —— 绿会让"档案纸"变回"终端"。
         橙色在这套色板里承担的是"正在生效 / 可以按"的语义，
         大量出现的元素（图标、网格）一律走墨色层次，不抢主色。 */
    static let accent  = NSColor(srgbRed: 1.000, green: 0.459, blue: 0.000, alpha: 1) // #ff7500
    static let accent2 = NSColor(srgbRed: 1.000, green: 0.694, blue: 0.408, alpha: 1) // #ffb168
    static let warm    = NSColor(srgbRed: 1.000, green: 0.851, blue: 0.659, alpha: 1) // #ffd9a8

    /* 状态三档：正常不上色（墨色）｜注意=主色｜异常=故障红。
       参考稿的检查行就是这个逻辑 —— "一切正常"是沉默的，
       只有异常才让眼睛停下来。原来的三档全是彩色，等于没有优先级。 */
    static let ok   = NSColor(srgbRed: 0.812, green: 0.808, blue: 0.796, alpha: 1) // #cfcecb
    static let warn = NSColor(srgbRed: 1.000, green: 0.459, blue: 0.000, alpha: 1) // #ff7500
    static let bad  = NSColor(srgbRed: 1.000, green: 0.231, blue: 0.188, alpha: 1) // #ff3b30
    /// 旧别名保留：面板里还有引用
    static let cyan   = accent
    static let violet = accent2

    // 文字层级：档案风靠"亮度差"分层，不靠字号堆叠
    static let title = NSColor(srgbRed: 0.949, green: 0.945, blue: 0.933, alpha: 1)  // #f2f1ee
    static let body  = NSColor(srgbRed: 0.812, green: 0.808, blue: 0.796, alpha: 1)  // #cfcecb
    static let dim   = NSColor(srgbRed: 0.522, green: 0.518, blue: 0.498, alpha: 1)  // #85847f
    static let faint = NSColor(srgbRed: 0.400, green: 0.396, blue: 0.380, alpha: 1)

    // 底板：不是"蓝紫渐变"，是接近纯黑的两级灰 —— 档案纸的质感来自低饱和
    static let bgTop    = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.047, alpha: 1) // #0b0b0c
    static let bgBottom = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.082, alpha: 1) // #131315

    // 发丝线：档案风的核心。细，而不是亮。
    static let hair     = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)
    static let hairSoft = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
    static let edge     = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)

    /// 档案风专用：卡片不再是"玻璃"，是"纸"——不透明、发丝描边
    static let cardBg = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.060, alpha: 0.92)

    /// 反白铭牌：参考稿最重的锚点是"黑底上压一块近白牌"（终幕那块 #f2f1ee），
    /// 全画面只有它是亮的。面板的主操作照这个规则走。
    static let plaque    = NSColor(srgbRed: 0.949, green: 0.945, blue: 0.933, alpha: 1) // #f2f1ee
    static let pureWhite = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1)
    static let plaqueInk = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.047, alpha: 1) // #0b0b0c

    /// 闪控媒体根目录：截图与录屏都在这下面（与 macctl.swift 的 MEDIA_ROOT 一致）
    /// ⚠ P10（2026-10-25）：截图与录屏**分家**并按 年/月 归档 ——
    ///     <根>/截图/2026/10/20261025-102538.png
    ///     <根>/录屏/2026/10/20261025-095757.mov
    ///   这个常量仍是「打开媒体文件夹」菜单项的落点（打开根，两类都看得到）。
    static var mediaDir: String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/Desktop/灵台智枢"
    }
    /// 根目录的短写法（tooltip / 状态行用）
    static var mediaDirShort: String { "桌面/灵台智枢" }
    /// 面板底部常驻提示：这次的图会落在哪。
    /// ⚠ 年月按**当下时间**算，不写死示例 —— 下个月打开面板还得是对的。
    ///   宽度按 9pt 等宽实测 ≈150pt，标签框 260pt 放得下，不会溢出到窗口外。
    static var mediaHint: String {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let y = cal.component(.year,  from: now)
        let m = cal.component(.month, from: now)
        return String(format: "截图 → 灵台智枢/截图/%04d/%02d", y, m)
    }
}

// MARK: - 启动动画配置（闪控写 / 动画读）

/// 这一个枚举就是"设置从动画搬到闪控"的全部接口面。
/// 文件只有一份，写在 bootanim/bootanim.config.json；
/// 启动器 wblaunch 读它合进 window.__WB_BOOT_CONFIG__，动画本身只读不写。
enum BootCfg {
    static var path: String {
        "\(NSHomeDirectory())/.workbuddy/skills/mac-control/scripts/bootanim/bootanim.config.json"
    }

    static var current: [String: Any] {
        guard let d = FileManager.default.contents(atPath: path),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return [:] }
        return o
    }

    @discardableResult
    static func write(_ obj: [String: Any]) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: obj,
                                                  options: [.prettyPrinted, .sortedKeys])
        else { return false }
        do {
            try d.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch { return false }
    }
}

// MARK: - 布局算式
//
// ⚠⚠ 这是 v5 最重要的部分。
//   v2~v4 的窗口高度是手写的常数（let H: CGFloat = 328），
//   而内容总高是**累加**出来的 —— 一旦按钮多一行、或某块卡片加高，
//   高度不会跟着变，最后一块就跑到窗口外 → 用户看到的「超格」。
//   现在：H 由下面这组常量**算出来**，不手写。
enum Layout {
    // ⚠ 档案风窗口比原来宽：右侧要放实时自检栏，主区被压窄。
    //   但常用操作仍保持 3 列 —— 4 列会让每个按钮只有 120pt，
    //   「iKuuuVPN」这种 7 字符标签放不下（实测 --layout-check 会报文字溢出）。
    static let W: CGFloat = 800
    static let pad: CGFloat = 20          // 窗口左右留白
    static let topInset: CGFloat = 30      // 红绿灯所在的那一行
    static let headerH: CGFloat = 46
    static let gap1: CGFloat = 12

    // 右侧自检栏宽度
    static let sideW: CGFloat = 208
    static let sideGap: CGFloat = 14
    /// 右侧地球块的尺寸（正方形）
    static let globeSize: CGFloat = 190
    /// 地球块与自检块之间的间距
    static let sideGap2: CGFloat = 10

    static let cols = 3
    static let rows = 5                   // 15 格位置：14 个动作（末行 2 格均分整行）
    static let tileH: CGFloat = 44
    static let gap: CGFloat = 8
    static let cardPad: CGFloat = 16
    static let gridTitleH: CGFloat = 30   // 分区标题 + 与网格的间距
    static let gridH: CGFloat = gridTitleH + CGFloat(rows) * tileH
                          + CGFloat(rows - 1) * gap + cardPad

    static let gap2: CGFloat = 12
    static let inputH: CGFloat = 84
    static let gap3: CGFloat = 12
    /// 启动动画设置卡（从动画里搬出来的那批设置）
    static let startH: CGFloat = 62
    static let statusH: CGFloat = 22
    static let bottom: CGFloat = 16

    static let H: CGFloat = topInset + headerH + gap1 + gridH + gap2
                          + inputH + gap3 + startH + gap3 + statusH + bottom
    /// 整个内容区宽度
    static let CW: CGFloat = W - pad * 2
    /// 主区（网格 + 输入）宽度：内容区减去右侧自检栏
    static let mainW: CGFloat = CW - sideW - sideGap
    static let tileW: CGFloat = (mainW - cardPad * 2 - CGFloat(cols - 1) * gap) / CGFloat(cols)

    // 各区块底边 y（从下往上排，最后一个正好留 bottom）
    static var headerY: CGFloat { H - topInset - headerH }
    static var gridY:   CGFloat { headerY - gap1 - gridH }
    static var inputY:  CGFloat { gridY - gap2 - inputH }
    static var startY:  CGFloat { inputY - gap3 - startH }
    static var statusY: CGFloat { startY - gap3 - statusH }
    /// 右侧栏顶边（与网格顶对齐）
    static var sideY:   CGFloat { gridY + gridH }
    /// 右侧栏 x（靠右）
    static var sideX:   CGFloat { W - pad - sideW }
    /// 地球块底边（自检块顶边）
    static var sideSplitY: CGFloat { sideY - globeSize - sideGap2 }
    /// 自检块高度 = 右侧栏总高 - 地球块 - 间距
    /// ⚠ 右侧栏的总高必须跟着左栏走：左栏现在是「网格 + 输入 + 启动动画」三段，
    ///   如果还按 gridH 算，自检块会在启动动画卡那一行的右侧留出一大块空白 ——
    ///   左右两栏底边差 200pt，面板会读成"没排完"。
    /// 自检块高度：按 5 条数据 + 标题 + 摘要给（≈248），不再拉满整条右栏。
    /// ⚠ 拉满的后果是面板右侧 40% 的面积是一个空框 —— 那看起来像没排完，
    ///   而不像留白。留白要有边界，空框没有。
    /// 自检卡高度：让它的底边与左栏最后一张卡（03 / STARTUP）对齐。
    /// 220 是"内容够用"的值，但两栏底边会差 35pt —— 面板右下方会空出一块
    /// 谁都不属于的三角，读起来是"没排完"。255 是实测对齐值。
    static var sideCheckH: CGFloat { 225 }
}

// MARK: - 工具

/// 脚本目录（相对二进制定位，保证 cwd 无关）
/// 脚本目录（macctl / route.sh / screen_rec.sh 都在这里）。
///
/// ⚠⚠ 这个函数曾经只是「可执行文件所在目录」，而闪控现在装在
///   `/Applications/灵台智枢.app/Contents/MacOS/flash` 里 —— 那里**没有 macctl**。
///   后果：面板上所有常用操作点了都没反应（runMacctl 找不到可执行文件，
///   直接返回空字符串，错误被吞掉）。用户看到的就是"点了没有任何回应"。
///   修法：按可信度依次回退，找到真正放着 macctl 的目录为止。
func scriptsDir() -> String {
    let fm = FileManager.default
    func hasMacctl(_ p: String) -> Bool { fm.isExecutableFile(atPath: p + "/macctl") }

    let fromExec = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent().path
    if hasMacctl(fromExec) { return fromExec }

    // ① 环境变量（launchd plist 里可以注入，便于换机器/换路径）
    if let env = ProcessInfo.processInfo.environment["SHANKONG_SCRIPTS"], hasMacctl(env) {
        return env
    }
    // ② 约定路径：技能安装目录
    let home = fm.homeDirectoryForCurrentUser.path
    let cand = home + "/.workbuddy/skills/mac-control/scripts"
    if hasMacctl(cand) { return cand }

    return fromExec
}

func runMacctl(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: scriptsDir() + "/macctl")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do {
        try p.run()
    } catch {
        // ⚠ 子进程根本没起来时，原来直接返回空串 —— 上层把"空输出"当成成功，
        //   于是界面显示"✅ 已截图"但文件根本没生成。这里必须留痕。
        let msg = "[runMacctl] 启动失败 \(scriptsDir())/macctl \(args.first ?? "") : \(error)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/flash.macctl.log") {
            h.seekToEndOfFile(); h.write(msg.data(using: .utf8)!); h.closeFile()
        } else {
            try? msg.write(toFile: "/tmp/flash.macctl.log", atomically: true, encoding: .utf8)
        }
        return ""
    }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}

/// detached 拉起 wblaunch（WorkBuddy 开场动画启动器）。
///
/// ⚠⚠ 必须 **detached**（不 waitUntilExit）：动画全程 15~50 秒
///   （场景闸门上线后每幕最多再等 3 秒），同步等待会把面板线程卡死 —
///   用户看到的是「闪控无响应」，比不播动画糟得多。route.sh 侧同理（后台 &）。
/// ⚠ env 必须带 WB_LAUNCH_REASON=flash：wblaunch 靠它写 facts.reason，
///   出问题时一眼分出这次是开机自启、闪控拉起还是手动打开。
/// ⚠ 播不播、播完拉不拉 WorkBuddy，全由 wblaunch 内部判定
///   （未运行 → 先播动画再拉起；已运行 → 只置前不播）。面板不重复判断。
func runWblaunch(_ args: [String]) -> String {
    let bin = scriptsDir() + "/bootanim/tools/wblaunch"
    guard FileManager.default.isExecutableFile(atPath: bin) else {
        return "{\"ok\":false,\"error\":\"WBLAUNCH_NOT_FOUND\",\"evidence\":\"找不到可执行文件 \(bin)\"}"
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["WB_LAUNCH_REASON"] = "flash"
    p.environment = env
    // 输出接管道但不读：wblaunch 正常运行期零 stdout，不会写满管道
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    do { try p.run() } catch {
        return "{\"ok\":false,\"error\":\"WBLAUNCH_SPAWN_FAILED\",\"evidence\":\"无法启动 \(bin)\"}"
    }
    // ⚠ 插值里不能再套带引号的表达式（Swift 不允许在 \( ) 内用转义引号）——
    //   先算成常量再拼，2026-10-22 踩过：直接写 \(args.joined(separator: " ")) 编译不过。
    let joined = args.joined(separator: " ")
    return "{\"ok\":true,\"evidence\":\"wblaunch 已异步启动（\(joined)）\"}"
}

/// 跑一个脚本。name 可以是 scripts/ 下的相对名，也可以是绝对路径。
func runScript(_ name: String, _ args: [String]) -> String {
    let p = Process()
    // ⚠ 实测踩过（自检抓到的真bug）：
    //   原来无条件拼 `scriptsDir() + "/" + name`。
    //   当 name 是**绝对路径**（队列里的 --script 就是这么存的）时，
    //   会拼成 "/…/scripts//tmp/fake_job.sh" → 路径不存在 → 进程静默失败，
    //   **返回值是空字符串、不报错**。表现就是「确认了但什么都没发生」。
    //   —— 队列里存的本来就是绝对路径，所以这条路径是常态而非特例。
    let scriptPath = name.hasPrefix("/") ? name : scriptsDir() + "/" + name
    guard FileManager.default.isReadableFile(atPath: scriptPath) else {
        return "{\"ok\":false,\"error\":\"SCRIPT_NOT_FOUND\",\"evidence\":\"找不到脚本 \(scriptPath)\"}"
    }
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [scriptPath] + args
    let pipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = pipe
    // ⚠ stderr 必须回收：不接的话子进程写 stderr 会让管道写满而**死锁**，
    //   表现为脚本莫名其妙不执行。先读 stdout 再读 stderr 避免互相阻塞。
    p.standardError = errPipe
    do { try p.run() } catch {
        return "{\"ok\":false,\"error\":\"SPAWN_FAILED\",\"evidence\":\"无法启动 \(scriptPath)\"}"
    }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    let e = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: d, encoding: .utf8) ?? ""
    let err = String(data: e, encoding: .utf8) ?? ""
    if out.isEmpty && !err.isEmpty {
        // 静默失败是最坏的一种：用户看到「已执行」但其实啥也没发生
        // ⚠ 必须带 stderr 原文：没有它就无法区分「脚本崩了」和「脚本没说话」。
        //   D-024 里 app_open 分支正是 stdout 0 字节 + stderr 也空，
        //   结果面板只显示「脚本无输出」五个字，用户完全无从判断。
        let ev = "脚本无输出：" + err.prefix(120)
        return "{\"ok\":false,\"error\":\"NO_OUTPUT\",\"error_code\":\"NO_OUTPUT\",\"evidence\":\"\(ev.replacingOccurrences(of: "\"", with: "'"))\"}"
    }
    if out.isEmpty && err.isEmpty {
        // ⚠ stdout 和 stderr 都空 = 脚本**静默退出**（最隐蔽的一种）。
        //   route.sh 的 app_open 分支曾长期处于这个状态（D-024）。
        //   绝不能报「完成」—— 假成功会让用户以为系统坏了而放弃。
        return "{\"ok\":false,\"error\":\"EMPTY\",\"error_code\":\"NO_OUTPUT\",\"evidence\":\"脚本静默退出，无任何输出\"}"
    }
    return out
}

/// 按 id 从队列里取出一项并从磁盘移除（避免重复渲染/重复执行）
///
/// ⚠ 抽成全局函数而不是只留在 Panel 里：面板按钮和无 UI 自检（--selftest-confirm）
///   必须走**同一条**执行路径。两边各写一份 → 自检验证的不是真实路径，等于白测。
func takePendingForTest(_ id: String) -> Pending? {
    let all = loadPending()
    guard let job = all.first(where: { $0.id == id }) else { return nil }
    try? FileManager.default.removeItem(atPath: "\(queueDir())/pending/\(id).json")
    return job
}

// MARK: - 置前引擎（工件A）

/// 置前结果。`how` 记录**哪一级成功**，是排查「为什么这次没上来」的唯一线索。
struct RaiseOutcome {
    var ok: Bool = false
    var how: String = "FAIL"
    var bundle: String = ""
    var front: String = "NONE"
    var ms: Int = 0
    var detail: String = ""

    var json: String {
        let d = detail.replacingOccurrences(of: "\"", with: "'")
        return "{\"ok\":\(ok),\"how\":\"\(how)\",\"bundle\":\"\(bundle)\",\"front\":\"\(front)\",\"ms\":\(ms),\"detail\":\"\(d)\"}"
    }
}

/// 把「用户怎么说」解析成 bundle id，零副作用（只问地址，不启动）。
func resolveBundleID(_ name: String) -> String? {
    let s = runMacctl(["launch", "--name", name, "--resolve-only", "--json"])
    guard let d = s.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          (o["ok"] as? Bool) == true,
          let bid = o["bundle"] as? String, !bid.isEmpty else { return nil }
    return bid
}

func frontBundleID() -> String {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "NONE"
}

func isRunningApp(_ bid: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
}

/// `open -b`：LaunchServices 的另一条链路，由系统进程代劳激活。
/// 对已运行 App 是**纯置前**（PID 不变），失败只写 stderr、绝不弹系统框。
@discardableResult
func openBundle(_ bid: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-b", bid]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// 在主线程里等 frontmost 变成目标（最多 `seconds`）。
/// ⚠ 必须跑 run loop 而不是 sleep：激活是别的进程完成的，光睡等不到任何东西。
func waitFrontmost(_ bid: String, _ seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if frontBundleID() == bid { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
    }
    return frontBundleID() == bid
}

/// T3：AX 直接抬窗口。用于「进程活着、窗口也在，但抢不到激活权」的 App。
/// ⚠ 需要辅助功能授权；没授权时这里静默返回 false（继续走 T4），不报错。
func axRaise(pid: pid_t) -> Bool {
    let appEl = AXUIElementCreateApplication(pid)
    var any = false
    // 先试「把 app 设为 frontmost」（等价激活，但走 AX 通道，不依赖激活权）
    if AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString,
                                    kCFBooleanTrue) == .success { any = true }
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v) == .success,
       let wins = v as? [AXUIElement] {
        for w in wins where AXUIElementPerformAction(w, kAXRaiseAction as CFString) == .success {
            any = true
        }
    }
    return any
}

/// 把已运行/未运行的目标 App 送到最上层。
///
/// ⚠⚠ 为什么必须由 flash（GUI 进程）自己做，不能外包给 macctl 子进程：
///   2026-10-22 实锤 —— 从**命令行子进程**里调 `NSRunningApplication.activate`
///   是**空操作**：AX 树读得到、进程活着，`frontmostApplication` 却纹丝不动。
///   这是 AppKit 的规矩（非前台进程没资格改变全局激活权）。
///   微信在热启动场景稳定翻车（Q4）就是踩在这上面。
///
/// 分级重试，每级之后**实测 frontmost** 才认：
///   T1 进程内 activate      —— 最快，面板刚让位时几乎必成
///   T2 open -b              —— 系统代劳，对已运行 App 纯置前
///   T3 AX frontmost/raise   —— 抢不到激活权时直接抬窗口
///   T4 macctl launch        —— 其中含 Dock 图标点击兜底（最小化/被完全遮挡时）
/// 判据不看「命令返回值」——Q4 的形状正是「命令都执行了，App 就是没上来」。
@discardableResult
/// 取消该应用**所有窗口**的最小化状态（AX 直接置 kAXMinimized = false）
///
/// ⚠⚠ 2026-10-24 用户报的 bug 根因就在这里：
///   `app.activate(.activateAllWindows)` 只把**应用**提到前台，
///   **最小化的窗口仍然躺在 Dock 里**。而原来的成功判据只看"谁是前台"，
///   于是判断通过、界面却没反应 —— 用户看到的就是"点了没跳上来"。
///   置前 ≠ 窗口可见，这两件事必须分别验证。
func deminiaturizeAll(pid: pid_t) -> Int {
    let ax = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
          let wins = v as? [AXUIElement] else { return 0 }
    var n = 0
    for w in wins {
        var m: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m) == .success,
           (m as? Bool) == true {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            n += 1
        }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }
    return n
}

/// 是否存在**未最小化且尺寸正常**的窗口（这才是"用户真的能看见"）
func anyWindowVisible(pid: pid_t) -> Bool {
    let ax = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
          let wins = v as? [AXUIElement] else { return false }
    for w in wins {
        var m: CFTypeRef?
        let min = (AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m) == .success
                   && (m as? Bool) == true)
        if min { continue }
        var szV: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &szV) == .success,
           let raw = szV {
            // CF 类型不能条件转换（Swift 6 会报"always succeeds"），用位转换
            var cg = CGSize.zero
            if AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &cg),
               cg.width > 80, cg.height > 80 { return true }
        }
    }
    return false
}

/// 取某个 App 的**原始图标**（Dock 里那个），统一缩放到 18pt 供格子绘制。
/// 解析不到（没装/名字对不上）就返回 nil，调用方退回 SF Symbol —— 不能因为图标缺失就不显示。
func appIconImage(for name: String) -> NSImage? {
    guard let bid = resolveBundleID(name),
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else {
        return nil
    }
    // ⚠⚠ 2026-10-24 修 B-014：**不要**再走 NSImage(size:)+lockFocus() 离屏重绘。
    //   那次重绘把一个"从上往下"的位图画进了"从下往上"的坐标里，结果**图标上下颠倒**
    //   （微信的两个气泡、访达的脸、抖音的音符全反了）。
    //   正确做法：拿系统原图，复制一份、只改 size，让绘制时按视图坐标系自己处理朝向。
    guard let copy = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else { return nil }
    copy.size = NSSize(width: 18, height: 18)
    copy.isTemplate = false          // 保持品牌色，别被当成模板图染色
    return copy
}

func raiseAppInProcess(_ name: String) -> RaiseOutcome {
    let t0 = Date()
    func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

    var out = RaiseOutcome()
    // ⚠ 不能用 defer 收尾：`return out` 在 defer 之前就取好了值，
    //   defer 里改的 ms/front 根本进不了返回值（静默丢数据）。
    func done(_ ok: Bool, _ how: String, _ detail: String = "") -> RaiseOutcome {
        out.ok = ok
        out.how = how
        out.detail = detail
        out.ms = ms()
        out.front = frontBundleID()
        return out
    }

    guard let bid = resolveBundleID(name) else {
        return done(false, "RESOLVE", "解析不到应用「\(name)」")
    }
    out.bundle = bid

    // ── 冷启动：先拉起，等进程与首帧窗口出现 ──
    var cold = false
    if !isRunningApp(bid) {
        cold = true
        _ = openBundle(bid)
        let dl = Date().addingTimeInterval(6)
        while Date() < dl && !isRunningApp(bid) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        // 进程刚起来时窗口还没画出来，太早置前会被系统忽略
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        if !isRunningApp(bid) {
            return done(false, "COLD", "6 秒内没起来")
        }
    }
    let p = cold ? "COLD+" : ""

    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
        let pid = app.processIdentifier
        // T0：先取消最小化（不然 activate 只提应用、窗口还躺在 Dock 里）
        let unmin = deminiaturizeAll(pid: pid)
        if unmin > 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        // T1
        app.activate(options: [.activateAllWindows])
        if waitFrontmost(bid, 0.5) && anyWindowVisible(pid: pid) {
            return done(true, p + "T1" + (unmin > 0 ? "+UNMIN(\(unmin))" : ""))
        }
        // T1b：前台了但窗口仍不可见（极端情况：刚恢复又被打回去）→ 再来一轮
        _ = deminiaturizeAll(pid: pid)
        app.activate(options: [.activateAllWindows])
        if waitFrontmost(bid, 0.4) && anyWindowVisible(pid: pid) {
            return done(true, p + "T1b")
        }
        // T2
        if openBundle(bid) && waitFrontmost(bid, 0.45) { return done(true, p + "T2") }
        // T3
        _ = deminiaturizeAll(pid: app.processIdentifier)
        if axRaise(pid: app.processIdentifier) && waitFrontmost(bid, 0.45)
            && anyWindowVisible(pid: app.processIdentifier) {
            return done(true, p + "T3")
        }
    }

    // T4：交给 macctl（它是 CLI，activate 无效，但 open -b + Dock 点击兜底还在）
    _ = runMacctl(["launch", "--name", name, "--json"])
    if waitFrontmost(bid, 1.2) { return done(true, p + "T4") }

    return done(false, "FAIL", "四级都没能把 \(name) 置前")
}


/// 从命令输出里抽出媒体文件路径并缩短（~/ 前缀折叠为 ~）
/// ⚠ 用户要能一眼看到「文件存哪了」，所以截图/录屏执行后必须回显真实路径。
func mediaPathFrom(_ s: String) -> String? {
    var raw: String? = nil
    if let r = s.range(of: "\"out\":\"") {
        let rest = s[r.upperBound...]
        if let e = rest.firstIndex(of: "\"") { raw = String(rest[rest.startIndex..<e]) }
    }
    if raw == nil, let r = s.range(of: "已保存 ") {
        let rest = s[r.upperBound...]
        raw = String(rest.prefix { $0 != " " })
    }
    guard let p = raw, !p.isEmpty else { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

// MARK: - 全局热键

func registerHotKey(keyCode: UInt32, mods: UInt32) -> Bool {
    let id = EventHotKeyID(signature: HOTKEY_SIG, id: HOTKEY_ID)
    var ref: EventHotKeyRef?
    let st = RegisterEventHotKey(keyCode, mods, id, GetEventDispatcherTarget(), 0, &ref)
    guard st == noErr, let r = ref else { return false }
    gHotKey = r
    return true
}

private func carbonHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ ud: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var ident = EventHotKeyID()
    let st = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &ident)
    guard st == noErr, ident.signature == HOTKEY_SIG, ident.id == HOTKEY_ID else {
        return OSStatus(eventNotHandledErr)
    }
    fireHotKey("carbon")
    return noErr
}

// ── 热键第二通道：事件监听 ───────────────────────────────────
//
// ⚠ 为什么 Carbon 一条路不够：`RegisterEventHotKey` 只对**系统认定**的按键
//   生效。实测注册返回成功、物理按下能唤起面板，但任何**合成**按键
//   （CGEvent / 自动化脚本 / 我们的自检）都到不了它 —— 于是「这条链路到底
//   通不通」永远没法自证，坏了只能靠人肉按一下试。
//   CGEventTap 能看到完整按键流（含合成事件），补上这条腿之后：
//     · 物理按键：Carbon 先到，tap 在 400ms 去抖窗口里被忽略
//     · 合成/异常：tap 兜底，功能不丢
//   代价：要辅助功能权限（闪控本来就要），系统超时停用 tap 时必须自己重启。
var gTapPort: CFMachPort?
var gTapKey: Int64 = 1           // 见 DEFAULT_KEY 注释
var gTapNeedCtrl = true
var gTapNeedOpt = true
var gTapNeedCmd = true
var gModsOnly = false            // 纯修饰键模式（无字母键）
var gModArmed = true             // 松开全部修饰键后才重新武装
var gLastHotKeyAt: CFAbsoluteTime = 0
var gHotKeyFires = 0
/// 只有**常驻守护进程**才写 /tmp/flash.hotkey。
/// ⚠ 实测踩过：自检会同时起 --panel-probe / --selftest-handoff 等临时实例，
///   它们也会调用 show()，于是把守护进程的状态行覆盖掉 —— 之后 diagnose
///   读到的是「某个临时进程的报告」，会给出完全误导的结论（key=0 active=0）。
var gStateEnabled = false

/// 统一的热键出口。Carbon 与 tap 都走这里，靠时间去抖避免按一下开两下。
func fireHotKey(_ from: String) {
    let now = CFAbsoluteTimeGetCurrent()
    if now - gLastHotKeyAt < 0.4 { return }
    gLastHotKeyAt = now
    gHotKeyFires += 1
    writeHotKeyState(note: "fire:\(from)")
    DispatchQueue.main.async { Panel.shared.show() }
}

/// 失败复盘日志（"安静地失败，但一定留痕"）。
///
/// 用户 2026-10-23 的明确要求：「安静的复盘并解决问题」。
/// 即：**别用红字吼他**，但每一次没成都要能被查、被归类、被修掉。
/// 所以失败时只轻轻说一句人话，真相全写进
/// `logs/failures-YYYY-MM-DD.jsonl`，`flashctl.sh review` 汇总。
func logFailure(action: String, input: String, reason: String, code: String = "") {
    let fm = FileManager.default
    let dir = scriptsDir() + "/../logs"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let path = dir + "/failures-" + df.string(from: Date()) + ".jsonl"
    let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
    let obj: [String: Any] = ["t": tf.string(from: Date()), "action": action,
                              "input": input, "reason": reason, "code": code]
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          var line = String(data: data, encoding: .utf8) else { return }
    line += "\n"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// 把热键状态写到固定文件，`flashctl status` 读它 —— 这样报的是**在跑的进程**
/// 的真实状态，而不是另起一个进程试注册一次的推测值。
func writeHotKeyState(note: String = "") {
    guard gStateEnabled else { return }   // 临时实例不写（见 gStateEnabled 注释）
    let path = "/tmp/flash.hotkey"
    let carbon = gHotKey != nil ? 1 : 0
    let tap = gTapPort != nil ? 1 : 0
    // ⚠ ax 要一起记：经 LaunchServices（open -a 灵台智枢.app）启动时，进程的 TCC
    //   身份变成「灵台智枢.app」，而辅助功能是按 app 授权的 —— 裸二进制有授权、
    //   app 身份可能没有，表现就是「热键能按（Carbon 不需要授权），但事件监听
    //   装不上、合成按键测不了」。不写这一位，就只能靠猜。
    let ax = AXIsProcessTrusted() ? 1 : 0
    // rec 要一起记（P13）：屏幕录制有没有授权，是**这个进程身份**下的真相。
    //   录屏（screencapture -v）从 launchd 会被拒、必须有一次人工勾选，
    //   `flashctl.sh rec` 靠这一位做守卫 —— 已经是 1 就绝不 tccutil reset（那会清掉好授权）。
    //   ⚠ 这里只**读**不申请（CGPreflightScreenCaptureAccess 不弹窗）。
    let rec = CGPreflightScreenCaptureAccess() ? 1 : 0
    // exe/bid 要一起记：TCC 是按「可执行文件 + 签名 + 负责进程」判定的，
    // 排查授权不生效时，第一件要确认的就是"到底跑的是哪个可执行文件"。
    let exe = (Bundle.main.executablePath as NSString?)?.lastPathComponent ?? "?"
    let bid = Bundle.main.bundleIdentifier ?? "nil(bare)"
    let bp = Bundle.main.bundlePath
    // sd = 实际解析出来的脚本目录（排查"按钮点了没反应"时第一个要看的东西）
    let sd = scriptsDir()
    let body = "pid=\(getpid()) carbon=\(carbon) tap=\(tap) ax=\(ax) rec=\(rec) sd=\(sd) " +
               "exe=\(exe) bid=\(bid) bp=\(bp) fires=\(gHotKeyFires) " +
               "key=\(gTapKey) note=\(note) at=\(Int(Date().timeIntervalSince1970))\n"
    try? body.write(toFile: path, atomically: true, encoding: .utf8)
}

private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                         _ event: CGEvent, _ ud: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // 被系统停用（回调太慢/用户输入过多）→ 立刻重开，否则热键从此静默失效
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let p = gTapPort { CGEvent.tapEnable(tap: p, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // ── 纯修饰键模式：⌃⌥⌘ 三键同按 ──────────────────────────────
    // 只在"按住的修饰键正好是 ⌃⌥⌘"的那一瞬间触发一次；全部松开后重新武装。
    // 不武装的话，按住不放会被系统不断送来 flagsChanged，面板会反复开。
    if type == .flagsChanged, gModsOnly {
        let rel: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        let cur = event.flags.intersection(rel)
        let want: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if cur == want {
            if gModArmed {
                gModArmed = false
                fireHotKey("mods")
            }
        } else if cur.isEmpty {
            gModArmed = true      // 全松开 → 重新武装
        } else if !cur.isSubset(of: want) {
            gModArmed = true      // 按了别的修饰键（如 ⇧）→ 这次不算，也重新武装
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, gTapKey != 0 else { return Unmanaged.passUnretained(event) }
    guard event.getIntegerValueField(.keyboardEventKeycode) == gTapKey else {
        return Unmanaged.passUnretained(event)
    }
    let f = event.flags
    // 三个修饰键都必须**精确匹配**：多按了 ⇧ 或少了 ⌘ 都不算，
    // 否则 ⌃⌥⌘S 会和 ⌃⌥S / ⌘S 互相误触。
    let okCtrl = f.contains(.maskControl) == gTapNeedCtrl
    let okOpt  = f.contains(.maskAlternate) == gTapNeedOpt
    let okCmd  = f.contains(.maskCommand) == gTapNeedCmd
    let okShift = !f.contains(.maskShift)
    guard okCtrl, okOpt, okCmd, okShift else { return Unmanaged.passUnretained(event) }
    fireHotKey("tap")
    return Unmanaged.passUnretained(event)   // listenOnly，不吞键
}

@discardableResult
func installKeyTap(keyCode: UInt32, mods: UInt32) -> Bool {
    gModsOnly = (keyCode == 0)
    gTapKey = Int64(keyCode)
    gTapNeedCtrl = (mods & UInt32(controlKey)) != 0
    gTapNeedOpt = (mods & UInt32(optionKey)) != 0
    gTapNeedCmd = (mods & UInt32(cmdKey)) != 0
    // 纯修饰键模式要听 flagsChanged；带字母键的模式听 keyDown。两个都听，逻辑里分流。
    let mask = CGEventMask((1 << CGEventType.keyDown.rawValue)
                           | (1 << CGEventType.flagsChanged.rawValue))
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                       place: .headInsertEventTap,
                                       options: .listenOnly,
                                       eventsOfInterest: mask,
                                       callback: tapCallback,
                                       userInfo: nil) else { return false }
    gTapPort = port
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    return true
}

func installHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    var ref: EventHandlerRef?
    InstallEventHandler(GetEventDispatcherTarget(), carbonHandler, 1, &spec, nil, &ref)
}

// MARK: - 菜单栏哨兵
//
// 常驻轮询（与面板可见性无关），有待确认项时图标变成警示计数。
// 这样「确认入口永远在屏幕上」，不可能出现「找不到在哪确认」。

final class MenuBarSentinel: NSObject, NSMenuDelegate {
    static let shared = MenuBarSentinel()
    private var status: NSStatusItem?
    private var watchTimer: Timer?
    private var lastCount = -1
    var onClick: (() -> Void)?

    func install() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = status?.button {
            b.title = "⚡️"
            b.font = .systemFont(ofSize: 14)
            b.toolTip = "灵台智枢 —— 点这里打开面板"
            b.target = self
            b.action = #selector(openPanel(_:))
        }
        let menu = NSMenu()
        menu.delegate = self
        status?.menu = menu
        watch()
    }

    /// 常驻轮询：**与面板可见性无关**，面板关着也扫队列
    func watch() {
        watchTimer?.invalidate()
        update()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func update() {
        let n = loadPending().count
        guard n != lastCount else { return }
        lastCount = n
        DispatchQueue.main.async {
            guard let b = self.status?.button else { return }
            b.title = n > 0 ? "⚠️\(n)" : "⚡️"
            b.font = .systemFont(ofSize: n > 0 ? 15 : 14)
            b.toolTip = n > 0 ? "灵台智枢 —— 有\(n) 项等你确认，点这里处理" : "灵台智枢 —— 点这里打开面板"
        }
    }

    @objc func openPanel(_ sender: Any?) { onClick?() }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let n = loadPending().count
        if n > 0 {
            let head = NSMenuItem(title: "⚠️ \(n) 项等你确认", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: "打开面板", action: #selector(openPanel(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        // ⚠ 用户明确要求闪控界面不出现任何音量相关内容，这里也就不放。
        let media = NSMenuItem(title: "打开截图/录屏文件夹", action: #selector(openMedia(_:)), keyEquivalent: "")
        media.target = self
        menu.addItem(media)
        let quit = NSMenuItem(title: "退出灵台智枢", action: #selector(quitAction(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc func openMedia(_ sender: Any?) {
        try? FileManager.default.createDirectory(atPath: Palette.mediaDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: Palette.mediaDir))
    }

    @objc func quitAction(_ sender: Any?) { NSApp.terminate(nil) }
}

// MARK: - 背景：深空渐变 + 双色辉光

final class TechBackground: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSGradient(starting: Palette.bgTop, ending: Palette.bgBottom)?
            .draw(in: r, angle: -90)

        // 辉光：径向渐变到透明，制造「光源在面板里」的体积感。
        // ⚠ 强度是调过的：第一版给了 0.15/0.12，实测两个辉光在面板中部
        //   叠成一道斜向亮带，深色玻璃卡片正好骑在亮带上 → 卡片看起来
        //   「不干净」、像蒙了层雾。辉光的作用是**边缘**的空气感，
        //   不是把底板照亮。现在压到 0.09/0.07 并把半径拉大，中心保持沉。
        func glow(_ c: NSColor, _ p: NSPoint, _ radius: CGFloat, _ alpha: CGFloat) {
            NSGradient(starting: c.withAlphaComponent(alpha),
                       ending: c.withAlphaComponent(0))?
                .draw(fromCenter: p, radius: radius, toCenter: p, radius: 0, options: [])
        }
        glow(Palette.cyan,   NSPoint(x: -r.width * 0.10, y: r.height * 1.02), r.width * 0.80, 0.10)
        glow(Palette.violet, NSPoint(x: r.width * 1.08, y: -r.height * 0.02), r.width * 0.70, 0.08)

        // 顶部一条高光分割线，让"窗沿"有厚度
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: r.maxY - 1, width: r.width, height: 1).fill()
    }
}

// MARK: - 玻璃卡片

final class GlassCard: NSView {
    var radius: CGFloat = 18
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSColor.white.withAlphaComponent(0.07).setFill()
        p.fill()
        // 顶部内高光 —— 玻璃的"厚度"来源
        NSGradient(starting: NSColor.white.withAlphaComponent(0.085),
                   ending: NSColor.white.withAlphaComponent(0))?
            .draw(in: NSRect(x: r.minX, y: r.maxY - 30, width: r.width, height: 30), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.15).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

// MARK: - 图标着色
//
// ⚠ SF Symbols 默认是黑色模板图，直接 draw 出来是黑的、在深色背景上等于看不见。
//   这里做一次离屏「sourceAtop」染色并缓存 —— 每次重绘重新生成 12 张位图会掉帧。

enum SymbolCache {
    private static var cache: [String: NSImage] = [:]

    static func tinted(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let key = "\(name)|\(size)|\(color.description)"
        if let hit = cache[key] { return hit }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let sized = base.withSymbolConfiguration(cfg) else { return nil }
        let sz = sized.size
        guard sz.width > 0, sz.height > 0 else { return nil }
        let img = NSImage(size: sz)
        img.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: sz)
        sized.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        rect.fill(using: NSCompositingOperation.sourceAtop)   // 只染到不透明像素上
        img.unlockFocus()
        cache[key] = img
        return img
    }
}

// MARK: - 按钮（自绘，含hover/按下反馈 + 文字自适应缩排）

final class TileButton: NSButton {
    enum Kind { case tile, accent, ghost }

    var kind: Kind = .tile
    var symbol: String = ""
    /// App 自己的图标（彩色、原样）。非空时**优先于** symbol 绘制。
    var appIcon: NSImage?
    /// 圆角。⚠ 档案风不要胶囊 —— 12pt 圆角在 46pt 高的按钮上
    ///   等于把按钮变成药丸，视觉上立刻退回"现代 App"而不是"技术档案"。
    ///   4pt 是"还能看出是按钮、但已经是硬边"的临界值。
    var radius: CGFloat = 4
    private var hovering = false
    private var pressing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // ⚠ 不设 isBezeled/drawsBackground：那俩在新SDK 里已下沉到 NSCell，
        //   而且本类完全自绘（draw 里不调 super），留着只会画出系统默认边框。
        cell?.isBezeled = false
        focusRingType = .none
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with e: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent)  { hovering = false; pressing = false; needsDisplay = true }
    /// ⚠⚠ 这里踩了个大坑：自绘按钮**必须**在 mouseDown 里调 super。
    ///
    /// NSButton 的 action 不是 mouseUp 里发的，而是 NSCell 在
    /// `super.mouseDown` 内部的 trackMouse 循环里判定的（按下→按住→松开才发）。
    /// 之前只重写 mouseDown 做按压视觉、没调 super → 跟踪循环根本没跑 →
    /// **所有常用操作点了都没反应**（用户 2026-10-23 报的就是这个），
    /// 而按钮看着完全正常、AX 里也还是 AXButton，极难查。
    /// 本次按下是否已经把 action 发出去了（防止重复触发）
    private var fired = false

    /// NSButton 无论走哪条路发 action，最后都会经过这里 —— 用来打标记。
    override func sendAction(_ a: Selector?, to t: Any?) -> Bool {
        fired = true
        return super.sendAction(a, to: t)
    }

    override func mouseDown(with e: NSEvent) {
        pressing = true
        fired = false
        needsDisplay = true
        super.mouseDown(with: e)      // 让 NSCell 走完跟踪（它能发就它发）
        pressing = false
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        pressing = false
        needsDisplay = true
        super.mouseUp(with: e)
        // 兜底：如果跟踪循环没有替我们发出 action（自绘按钮的常见坑），
        // 在"松开点仍在按钮内"时手动发一次。有 fired 标记，不会重复。
        if !fired, let act = action,
           bounds.contains(convert(e.locationInWindow, from: nil)) {
            NSApp.sendAction(act, to: target, from: self)
        }
    }

    /// 文字排版：先按 12.5pt 排，放不下就逐步缩到 9.5pt，再放不下才截断。
    /// ⚠ 这就是"超格"的根治点：以前是把 12pt 硬塞进固定宽度里，
    ///   「WPS文档」「WorkBuddy」这类长标签必然溢出按钮边框。
    /// ⚠⚠ 字体换了（2026-10-25：系统字体 → Inter）之后**这个循环就是唯一的
    ///   溢出口**：Inter 的字面比 SF Pro 略宽，同一字号下「iKuuuVPN」
    ///   「DeepSeek Harness」会比以前长 2–4pt。所以这里必须跟着 uiFont 走，
    ///   不能继续写死 systemFont —— 否则按钮文字还是 SF Pro，
    ///   只有标题变了，屏幕上会同时出现三套字。
    func fitAttributes(maxWidth: CGFloat) -> NSAttributedString {
        var size: CGFloat = 12.5
        while size >= 9.5 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: uiFont(size: size, weight: .medium),
                .foregroundColor: Palette.title,
            ]
            let s = NSAttributedString(string: title, attributes: attrs)
            if s.size().width <= maxWidth { return s }
            size -= 0.5
        }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: uiFont(size: 9.5, weight: .medium),
            // 反白牌上的字必须是深墨：白字压白牌等于没有字
            .foregroundColor: kind == .accent ? Palette.plaqueInk : Palette.title,
            .paragraphStyle: p,
        ]
        return NSAttributedString(string: title, attributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        switch kind {
        case .tile:
            // 档案风：常态几乎透明（只有发丝边），hover 时纸面微微提亮。
            // 常态的 0.055 白 + 0.10 边是"半透明玻璃"时代的参数 ——
            // 在近黑底上会显出一格一格的灰块，破坏"整片纸"的观感。
            let a: CGFloat = pressing ? 0.11 : (hovering ? 0.075 : 0.028)
            NSColor.white.withAlphaComponent(a).setFill(); p.fill()
            let edge = hovering ? 0.34 : 0.13
            NSColor.white.withAlphaComponent(edge).setStroke()
            p.lineWidth = 1; p.stroke()
            // 悬停时左侧亮一条：键位"被压住"的最短表达，比整块发光克制
            if hovering || pressing {
                Palette.accent.withAlphaComponent(pressing ? 1 : 0.85).setFill()
                NSRect(x: 2, y: r.midY - r.height * 0.26, width: 2,
                       height: r.height * 0.52).fill()
            }
        case .accent:
            /* 反白铭牌，不是彩色按钮。
               参考稿里最重的视觉锚点是"黑底上压一块近白 (#f2f1ee) 的牌"，
               整个画面只有那一块是亮的。面板里的主操作（执行 ↑）照这个规则走：
               白牌 + 深墨字 + 下沿一道 2pt 橙线 ——
               橙线是它与整套色板唯一的硬连接，也是"可以按"的信号。
               ⚠ 不做彩色填充：橙底白字在近黑板上会像一颗按钮糖，
                 和两侧的发丝线卡片不是同一材质。 */
            let fill: NSColor = pressing ? Palette.pureWhite
                : (hovering ? Palette.pureWhite : Palette.plaque)
            fill.setFill(); p.fill()
            /* 橙线沿着**下沿**、并且裁进圆角里。
               上一版直接画了一条矩形：圆角是 3pt，直线在两端会探出白面，
               看起来是"贴歪的胶带"而不是"铭牌的底座"。
               ⚠ 按钮的 bounds 是翻转系（NSButton），下沿 = maxY - 2.6。 */
            NSGraphicsContext.saveGraphicsState()
            p.addClip()
            Palette.accent.withAlphaComponent(pressing ? 0.55 : 0.95).setFill()
            NSRect(x: r.minX, y: r.maxY - 2.6, width: r.width, height: 2.6).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(hovering ? 0.20 : 0.12).setStroke()
            p.lineWidth = 1; p.stroke()
        case .ghost:
            if hovering || pressing {
                NSColor.white.withAlphaComponent(hovering ? 0.10 : 0.06).setFill(); p.fill()
            }
            NSColor.white.withAlphaComponent(isEnabled ? 0.22 : 0.08).setStroke()
            p.lineWidth = 1; p.stroke()
        }

        NSGraphicsContext.saveGraphicsState()

        // 图标 + 文字整体水平居中
        let gap: CGFloat = symbol.isEmpty ? 0 : 6
        let iconSize: CGFloat = kind == .tile ? 17 : 16
        // App 原图标优先：彩色原样绘制（不再 tinted，否则品牌色会被洗掉）
        let icon: NSImage? = appIcon ?? (symbol.isEmpty ? nil
            : SymbolCache.tinted(symbol, size: iconSize, weight: .medium,
                                 color: kind == .accent ? Palette.plaqueInk : Palette.body))
        let iconW = (icon?.size.width ?? 0) + gap
        // 可用文字宽度 = 按钮宽 - 左右内边距 - 图标宽
        let textMax = max(20, bounds.width - 24 - iconW)
        let attrs = fitAttributes(maxWidth: textMax)
        let textW = min(attrs.size().width, textMax)
        let total = iconW + textW
        var x = (bounds.width - total) / 2
        let midY = bounds.midY

        if let ic = icon {
            // respectFlipped: true —— 让 AppKit 按当前视图的坐标系处理朝向，
            // 这是唯一能同时兼容"翻转/不翻转"两种视图的写法（B-014 的修法）
            ic.draw(in: NSRect(x: x, y: midY - ic.size.height / 2,
                               width: ic.size.width, height: ic.size.height),
                    from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
            x += iconW
        }
        attrs.draw(at: NSPoint(x: x, y: midY - attrs.size().height / 2))

        NSGraphicsContext.restoreGraphicsState()

        if !isEnabled {
            // 幽灵按钮禁用态：整体压暗，而不是靠系统自动变灰（那套在深色底上很脏）
            NSColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 0.62).setFill()
            r.fill()
        }
    }
}

// MARK: - 品牌标记

final class BrandMark: NSView {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        /* 不再套"标签框"。
           上一版是一个 28pt 的方框里塞六边形线框 —— 那读起来是"一个图标位"，
           不是标识。参考稿的标识是直接落在纸上的（没有底板、没有边框），
           体量靠星体本身的明暗撑起来。去掉框之后，同一个 34pt 反而更亮。
           几何与配色见 StarGlyph（与开场动画同一套）。 */
        StarGlyph.draw(in: bounds.insetBy(dx: 0.5, dy: 0.5))
    }
}

// MARK: - 立体折面五角星（与开场动画同一套几何）
//
// 为什么在 AppKit 里重画，而不是截一张动画的图贴上来：
//   ① 标识在 Retina 上要按物理像素出，34pt 的位图会糊边；
//   ② 面板整体是矢量线框语言（见 GlobeView），贴一张带渐变的位图立刻破功；
//   ③ 动画侧要改颜色，这里只改四个十六进制值，不用重新导图。
//
// 几何全部照搬动画 `svgStar(_, 'gem')`：
//   画布 60×60｜外接半径 R=25.5｜凹点半径 R×0.382｜外尖从 -90° 起、凹点从 -54° 起。
//   15 个折面 = 5 个谷面（中心五边形）+ 10 个臂半面；光源固定在左上。
//   ⚠ Y 轴要翻：SVG 向下为正，AppKit 向上为正 —— 不翻的话星尖朝下，
//     是"倒着的星"，不是同一个标识。
enum StarGlyph {
    private static let R: CGFloat = 25.5
    private static let rIn: CGFloat = 25.5 * 0.382

    /// 动画里的三组折面色（谷面最暗、左臂受光、右臂背光）
    private static let valley  = ["#4a525b", "#383f47", "#41484f", "#545c66", "#4e565f"]
    private static let planeL  = ["#c9d2db", "#909aa5", "#555e68", "#808a95", "#bfc9d2"]
    private static let planeR  = ["#b0bac3", "#707a85", "#626c77", "#a0aab4", "#d3dbe4"]

    private static func map(_ x: CGFloat, _ y: CGFloat, _ r: NSRect) -> NSPoint {
        NSPoint(x: r.minX + x / 60 * r.width,
                y: r.minY + (60 - y) / 60 * r.height)   // 翻 Y
    }

    private static func hex(_ h: String, _ a: CGFloat = 1) -> NSColor {
        let v = UInt32(h.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255,
                       alpha: a)
    }

    private static let outer: [CGPoint] = (0..<5).map { i in
        let a = (-90.0 + Double(i) * 72) * Double.pi / 180
        return CGPoint(x: 30 + R * CGFloat(cos(a)), y: 30 + R * CGFloat(sin(a)))
    }
    private static let inner: [CGPoint] = (0..<5).map { i in
        let a = (-54.0 + Double(i) * 72) * Double.pi / 180
        return CGPoint(x: 30 + rIn * CGFloat(cos(a)), y: 30 + rIn * CGFloat(sin(a)))
    }

    static func draw(in rect: NSRect) {
        let r = rect
        guard r.width > 4 else { return }
        let s = r.width / 60                      // 动画 1 单位 = 多少 pt
        let C = map(30, 30, r)
        let O = outer.map { map($0.x, $0.y, r) }
        let I = inner.map { map($0.x, $0.y, r) }

        func tri(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: a); p.line(to: b); p.line(to: c); p.close()
            return p
        }

        /// 面内渐变：亮端 → 暗端，方向与动画的左上光源一致（-58°）。
        func facet(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint, _ base: String) {
            let path = tri(a, b, c)
            let top = hex(base)
            // 落差值 0.80 承自动画：小于 0.9 才有"折面"，大于 0.7 会变成脏灰。
            let bot = hex(base).blended(withFraction: 0.30, of: .black) ?? top
            NSGradient(starting: top, ending: bot)?.draw(in: path, angle: -58)
        }

        NSGraphicsContext.saveGraphicsState()

        // ① 谷面（中心五边形，最暗的一圈，它是"凹进去"的那部分）
        for v in 0..<5 {
            facet(C, I[v], I[(v + 1) % 5], valley[v])
        }
        // ② 臂半面：每臂左右两半各一个面，明暗不同 → 折痕
        for i in 0..<5 {
            facet(O[i], I[(i + 4) % 5], C, planeL[i])
            facet(O[i], I[i], C, planeR[i])
        }

        // ③ 棱线：五道从外尖到中心的高光，这是"立体"的来源
        //    ⚠ 宽度不能直接沿用动画的 0.55 单位 —— 34pt 上那是 0.31pt，
        //      在 1x 屏只有 0.3 个物理像素，等于没画。按 1.6 单位给。
        hex("#eef2f6", 0.90).setStroke()
        for i in 0..<5 {
            let p = NSBezierPath()
            p.move(to: O[i]); p.line(to: C)
            p.lineWidth = max(0.55, 1.2 * s)
            p.lineCapStyle = .round
            p.stroke()
        }

        // ④ 镀边：整星轮廓一道浅白，把星体从近黑底上"剥"出来
        let rim = NSBezierPath()
        rim.move(to: O[0])
        for j in 0..<5 {
            rim.line(to: I[j])
            rim.line(to: O[(j + 1) % 5])
        }
        rim.close()
        hex("#d8e0e7", 0.32).setStroke()
        rim.lineWidth = max(0.5, 1.1 * s)
        rim.lineJoinStyle = .round
        rim.stroke()

        // ⑤ 中心核：一层径向光晕 + 一个亮点（动画里是 3.6 / 0.85 单位）
        let haloR = 3.6 * s
        let halo = NSBezierPath(ovalIn: NSRect(x: C.x - haloR, y: C.y - haloR,
                                              width: haloR * 2, height: haloR * 2))
        NSGradient(starting: hex("#eef2f6", 0.5),
                   ending: hex("#eef2f6", 0))?.draw(in: halo, relativeCenterPosition: .zero)
        let dotR = max(0.7, 0.85 * s)
        hex("#f4f7fa").setFill()
        NSBezierPath(ovalIn: NSRect(x: C.x - dotR, y: C.y - dotR,
                                    width: dotR * 2, height: dotR * 2)).fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}

/// WorkBuddy 标识的几何（与开场动画 brand.js 同一套形状）
///
/// 单独抽出来是因为：开场动画在浏览器里画（SVG path），
/// 面板在 AppKit 里画（NSBezierPath）—— 形状必须一致，
/// 否则用户会看到"两个 WorkBuddy 长得不一样"。
enum WorkBuddyGlyph {
    /// 六边形机芯壳（归一化坐标 0..1，Y 轴向上）
    private static let shell: [(CGFloat, CGFloat)] = [
        (0.50, 0.96), (0.94, 0.70), (0.94, 0.30), (0.50, 0.04),
        (0.06, 0.30), (0.06, 0.70),
    ]
    /// 内环（反向绘制 → 挖空）
    private static let inner: [(CGFloat, CGFloat)] = [
        (0.50, 0.79), (0.83, 0.61), (0.83, 0.39), (0.50, 0.21),
        (0.17, 0.39), (0.17, 0.61),
    ]
    /// 中心方孔
    private static let center: [(CGFloat, CGFloat)] = [
        (0.40, 0.44), (0.60, 0.44), (0.60, 0.56), (0.40, 0.56),
    ]

    private static func pts(_ poly: [(CGFloat, CGFloat)],
                            in r: NSRect) -> [NSPoint] {
        poly.map { p in
            NSPoint(x: r.minX + p.0 * r.width,
                    y: r.minY + (1 - p.1) * r.height)   // 翻 Y：SVG 向下为正
        }
    }

    static func path(in r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let s = pts(shell, in: r)
        p.move(to: s[0])
        for q in s.dropFirst() { p.line(to: q) }
        p.close()
        return p
    }

    static func hole(in r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let c = pts(center, in: r)
        p.move(to: c[0])
        for q in c.dropFirst() { p.line(to: q) }
        p.close()
        return p
    }
}

// MARK: - 自带字体（Inter / Roboto Mono）

/// 随 app 一起打包的字体，启动时注册进当前进程。
///
/// 为什么必须自己注册：Inter 和 Roboto Mono 都不在 macOS 的系统字体表里。
/// 只把文件塞进 bundle 是不生效的 —— `NSFont(name:)` 会返回 nil，
/// 然后代码静默退回系统字体，屏幕上看不出任何变化。这种"改了但没生效"
/// 是最难发现的一类失败，所以这里把「注册成功没有」显式记下来。
///
/// ⚠ 只认**静态 .ttf/.otf**：CoreText 的 CTFontManager 不支持 woff2
///   （网页字体），塞进来只会注册失败。
enum BundledFonts {
    /// (文件名去掉扩展名, PostScript 名)。`NSFont(name:)` 认的是 PS 名。
    static let files: [(file: String, ps: String)] = [
        ("Inter-Regular",     "Inter-Regular"),
        ("Inter-Medium",      "Inter-Medium"),
        ("Inter-SemiBold",    "Inter-SemiBold"),
        ("RobotoMono-Regular","RobotoMono-Regular"),
        ("RobotoMono-Medium", "RobotoMono-Medium"),
    ]

    /// 注册成功的 PS 名。空集 = 全部退回系统字体。
    private(set) static var ready: Set<String> = []
    /// 实际使用的字体目录（诊断用）
    private(set) static var dir: String = "—"

    /// 字体目录的候选位置。按优先级：
    ///   ① `灵台智枢.app/Contents/Resources/Fonts` —— 打包后的正路
    ///   ② 可执行文件同级 `scripts/Resources/Fonts` —— 直接跑裸二进制
    ///      （`./flash --layout-check`）时 Bundle.main 是 nil，这条是主力
    ///   ③ 向上两级 `scripts/../Resources/Fonts` —— 兜底
    static func locate() -> URL? {
        var cands: [URL] = []
        if let r = Bundle.main.resourceURL {
            cands.append(r.appendingPathComponent("Fonts"))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let exeDir = exe.deletingLastPathComponent()
        cands.append(exeDir.appendingPathComponent("Resources/Fonts"))
        cands.append(exeDir.deletingLastPathComponent()
                        .appendingPathComponent("Resources/Fonts"))
        for c in cands where FileManager.default.fileExists(atPath: c.path) { return c }
        return nil
    }

    /// 注册。返回是否至少有一个字体可用。
    @discardableResult
    static func register() -> Bool {
        guard let d = locate() else {
            dir = "未找到 Resources/Fonts"
            return false
        }
        dir = d.path
        var ok = 0
        for f in files {
            let url = d.appendingPathComponent(f.file + ".ttf")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var err: Unmanaged<CFError>?
            // .process 作用域：只对本进程有效，不污染系统字体表。
            // 已注册过会返回 false（"already registered"），那不算失败。
            let r = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
            if r || NSFont(name: f.ps, size: 10) != nil {
                ready.insert(f.ps); ok += 1
            }
        }
        return ok == files.count
    }
}

// MARK: - 文字标签

/// UI 字体：Inter 优先，取不到就退回系统字体（宁可字形变，也不能缺字）。
///
/// 为什么是 Inter 而不是继续用 Avenir Next（用户 2026-10-25 定）：
/// 要求是「工整、能轻松看清、不许花式」。Inter 是专为屏幕小字号设计的
/// 中性无衬线：x-height 大、开口宽、字重齐（Regular/Medium/SemiBold），
/// 和数据区的 Roboto Mono 同属「仪表」语汇，比 Avenir Next 的几何感更"正"。
///
/// ⚠ Inter 不含汉字。中文会走 CoreText 的级联回退（系统中文字体），
///   这是对的 —— 强行塞一个中文字体反而会和西文基线打架。
func uiFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    // 只有三档静态字重，所以 .bold / .black 也只能落到 SemiBold。
    // 不去合成假粗体：合成加粗在 9–12pt 的西文和数字上会把笔画糊死，
    // 那比"不够粗"难看得多，也更难读。
    let name: String
    switch weight {
    case .bold, .heavy, .black, .semibold: name = "Inter-SemiBold"
    case .medium:                          name = "Inter-Medium"
    default:                               name = "Inter-Regular"
    }
    if BundledFonts.ready.contains(name), let f = NSFont(name: name, size: size) {
        return f
    }
    // 退回旧逻辑：Avenir Next（系统自带）→ 系统字体
    let fb: String
    switch weight {
    case .bold, .heavy, .black:      fb = "AvenirNext-Bold"
    case .semibold:                  fb = "AvenirNext-DemiBold"
    case .medium:                    fb = "AvenirNext-Medium"
    default:                         fb = "AvenirNext-Regular"
    }
    if let f = NSFont(name: fb, size: size) { return f }
    return .systemFont(ofSize: size, weight: weight)
}

/// 等宽字体：Roboto Mono 优先，取不到退回系统等宽（SF Mono）。
///
/// 为什么数据区必须是等宽：自检栏是「键左值右」的表格，数字要能上下对齐；
/// 比例字体里 1 和 8 的宽度不同，竖着看就歪了。Roboto Mono 比 SF Mono
/// 略窄、字重更均匀，和 Inter 并排时不会一个偏粗一个偏细。
func monoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    // 同样只有两档静态字重：常规 / 中等。.bold 也落到 Medium。
    let name = (weight == .regular || weight == .light || weight == .thin)
        ? "RobotoMono-Regular" : "RobotoMono-Medium"
    if BundledFonts.ready.contains(name), let f = NSFont(name: name, size: size) {
        return f
    }
    return .monospacedSystemFont(ofSize: size, weight: weight)
}

func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight,
               color: NSColor, align: NSTextAlignment = .left,
               kern: CGFloat = 0) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    /* 字体：标题与区块名走 Inter（随包带的 OFL 字体，见 BundledFonts）。
       为什么不是参考项目那套 Jura：用户 2026-10-25 明确「不能是花式，要工整、
       能轻松看清」。Inter 在 8–11pt 上字面宽、开口大、数字不糊边，
       和右侧数据栏的 Roboto Mono 是同一种"仪表"语汇。
       之前用的 Avenir Next 也是好字体，但它是**比例几何体**，混排时
       和等宽数据栏的节奏对不上 —— 这就是"两套字"的来源。 */
    t.font = uiFont(size: size, weight: weight)
    t.textColor = color
    t.alignment = align
    t.lineBreakMode = .byTruncatingTail
    t.cell?.truncatesLastVisibleLine = true
    /* 字距：档案风的标题不是"最黑的那一行"，而是"被拉开的一行"。
       参考稿的中文标签全部带 0.2em 以上的字距，靠间距建立秩序感，
       而不是靠加粗。kern 默认 0，只有区块标题传值 —— 正文加字距会变难读。 */
    if kern != 0 {
        let ps = NSMutableParagraphStyle()
        ps.alignment = align
        ps.lineBreakMode = .byTruncatingTail
        t.attributedStringValue = NSAttributedString(
            string: s,
            attributes: [
                .font: uiFont(size: size, weight: weight),
                .foregroundColor: color,
                .kern: kern,
                .paragraphStyle: ps,
            ])
    }
    return t
}

// MARK: - 面板

/// 扫描线：每隔约 9 秒，一条极淡的横向亮线自上而下扫过整块面板。
///
/// 为什么加这个：借自 ai-workstation 的「仪表盘在呼吸」这一层观感 ——
/// 面板大部分时间是静止的（地球在转，其余不动）。一条偶尔划过的线，
/// 让静止画面有了时间感，几乎不占注意力。
/// 三条纪律：
///   ① `hitTest` 返回 nil —— 它盖在所有按钮之上，绝不能吃掉点击；
///   ② 透明度上限 0.12 —— 再高就变成"干扰阅读的扫描特效"；
///   ③ 空闲时不调 `needsDisplay` —— 只有扫的那 1.1 秒才重绘。
final class ScanlineView: NSView {
    private var timer: Timer?
    private var idle: Double = 0
    private var progress: CGFloat = -1        // <0 = 空闲；0…1 = 正在扫
    private let period: Double = 9
    private let sweepDuration: Double = 1.1
    private let tick: Double = 1.0 / 30.0

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    func start() {
        guard timer == nil else { return }
        idle = 0
        progress = -1
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.progress < 0 {
                self.idle += self.tick
                if self.idle >= self.period { self.idle = 0; self.progress = 0 }
                return
            }
            self.progress += CGFloat(self.tick / self.sweepDuration)
            if self.progress > 1 { self.progress = -1; return }
            self.needsDisplay = true
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        progress = -1
        idle = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard progress >= 0 else { return }
        // 首尾各淡入淡出一段，避免"线凭空出现/消失"
        let env: CGFloat = progress < 0.15 ? progress / 0.15
                          : (progress > 0.85 ? (1 - progress) / 0.15 : 1)
        let a = 0.12 * env
        guard a > 0.004 else { return }

        let y = bounds.maxY - progress * bounds.height
        // 上方 48pt 的渐隐拖尾（像扫描头后面的余晖）
        let trail = NSRect(x: 0, y: y, width: bounds.width, height: 48)
        NSGradient(starting: Palette.accent.withAlphaComponent(a * 0.5),
                   ending: Palette.accent.withAlphaComponent(0))?.draw(in: trail, angle: 90)
        // 亮线本体
        Palette.accent.withAlphaComponent(a).setFill()
        NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
    }
}


final class Panel: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = Panel()

    var window: NSPanel!
    var statusLabel: NSTextField!
    var freeInput: NSTextField!
    /// 转交提示条（输入框上方的一行提示，不是独立输入栏）
    var hintLabel: NSTextField!
    /// 「转到 WorkBuddy」按钮 —— 只在需要转交时才高亮
    var wbButton: TileButton!
    /// 输入框外框，用于聚焦时点亮描边
    var fieldShell: GlassCard!
    /// 右侧实时自检栏（工业档案画风）
    var selfCheck: SelfCheckBar!
    /// 右侧三维自转地球（工业档案画风）
    var globe: GlobeView!
    private var watermark: GlobeWatermark?
    private var noiseLayer: NoiseView?
    private var watermarkTick = 0
    // 启动动画设置卡的控件（值来自 bootanim/bootanim.config.json）
    private var bootName: NSTextField?
    private var bootCode: NSTextField?
    private var bootThemeBtn: TileButton?
    private var bootNote: NSTextField?
    private var bootTheme: String = "dark"
    var busy = false

    /// 最近一次判定为「复杂任务」的原文。转交按钮和自动转交都用它，
    /// 避免两处各自去读剪贴板（用户中途复制了别的东西就会串味）。
    var pendingHandoff: String?
    var pendingTarget: String?
    var keyMonitor: Any?
    private var built = false
    /// 地球自转相位（自检刷新时推进）
    private var globePhase: CGFloat = 0

    /// 常用动作。
    /// ⚠ **只放高频**：低频动作放进来只会让面板拥挤、增加找的时间 —— 那是负效率。
    struct Action {
        let title: String
        let symbol: String
        let cmd: [String]
        let done: String
        /// 有状态的动作（如录屏的「开始/停止」二态）走脚本，不能用单条 macctl 命令。
        var script: String = ""
        var scriptArgs: [String] = []
        /// 这一格走 wblaunch（开场动画启动器）而不是 macctl。
        /// ⚠ 目前只有 WorkBuddy 用：用户拍板「闪控启动（非唤醒）WorkBuddy 时
        ///   先播开场动画，动画放完 WorkBuddy 才登场」——顺序由 wblaunch 保证。
        var viaWblaunch: Bool = false
        /// 这一格是「打开某个 App」。
        /// ⚠ 这类动作点完必须让面板收起 —— 面板是 .floating 层级，
        ///   它在屏幕上就永远压着目标 App，用户看到的是「点了没反应」。
        var isAppLaunch: Bool { cmd.first == "launch" || viaWblaunch }
        /// 这个格子要打开哪个 App（用于取**它自己的图标**）。
        /// 用户 2026-10-24 要求：常用操作的图标要贴合对应 App 的原图标，
        /// 而不是拿一个近似含义的 SF Symbol 凑数（"微信"配信封图标谁认得出来）。
        var appName: String? {
            if viaWblaunch { return "WorkBuddy" }
            if cmd.count >= 3, cmd[0] == "launch", cmd[1] == "--name" { return cmd[2] }
            return nil
        }
        /// 固定在末尾（不参与使用频率排序）。
        /// 用途：末行通栏那条必须**始终**是同一个动作，否则今天通栏是酷狗、
        /// 明天通栏是抖音 —— 视觉位置天天变，用户找不到，也就不"美观"了。
        var pinnedLast: Bool = false
    }

    /// 按钮使用次数（`重排` 的依据）。
    ///
    /// 用户 2026-10-23 的原话：「快不是动画快，是**少找一个按钮**」。
    /// 所以按钮顺序不写死，按**真实使用次数**排：用得多的自动往前挪，
    /// 前 4 格长期覆盖 80% 的操作。计数落盘，重启不丢。
    private static var usageCache: [String: Int] = [:]
    private static var usageLoaded = false

    static func usagePath() -> String { scriptsDir() + "/../logs/usage.json" }

    static func loadUsage() {
        guard !usageLoaded else { return }
        usageLoaded = true
        if let d = try? Data(contentsOf: URL(fileURLWithPath: usagePath())),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Int] {
            usageCache = m
        }
    }

    static func bumpUsage(_ title: String) {
        loadUsage()
        usageCache[title, default: 0] += 1
        if let d = try? JSONSerialization.data(withJSONObject: usageCache, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: usagePath()))
        }
    }

    /// 按使用次数稳定排序（同次数保持原顺序，避免每次开面板顺序乱跳）
    func sortedByUsage(_ list: [Action]) -> [Action] {
        Panel.loadUsage()
        let u = Panel.usageCache
        // 固定末位的动作不参与排序，排完再追加 —— 保证通栏格的位置恒定
        let pinned = list.filter { $0.pinnedLast }
        let free = list.filter { !$0.pinnedLast }
        let sorted = free.enumerated().sorted { a, b in
            let ua = u[a.element.title] ?? 0, ub = u[b.element.title] ?? 0
            if ua != ub { return ua > ub }
            return a.offset < b.offset
        }.map { $0.element }
        return sorted + pinned
    }

    func actions() -> [Action] {
        // ⚠ 应用类一律走 `macctl launch --name <名称>`，不走 `raise --app <bundleid>`：
        //   launch 内部能处理「装了但没运行」（自动拉起）、中文名↔英文名映射。
        //   D-022 的根因就是这个：面板按钮写死bundle id，用户说「打开WPS」就没法用了。
        //
        // ⚠ 录屏是**有状态**的（开始/停止），所以走脚本而不是单条 macctl 命令。
        //
        // ⚠ 第 12 格：按用户要求，桌面 → iKuuuVPN（macctl 别名表已含 vpn/加速器/飞机）。
        return sortedByUsage([
            // 截图：改用**交互框选**（微信式）。面板会先藏起来，拍不到自己。
            Action(title: "截图",   symbol: "camera.viewfinder", cmd: ["shot", "--interactive"], done: "已截图（框选区域）"),
            /* 2026-10-25 用户要求「两种模式」：同一套框选流程，区别只在
               **面板在不在画面里**。带 `--keep-panel` 的那格全程不调
               hide()/show() —— 用户要的正是"把我这个面板也拍进去"
               （做教程图 / 截图面板本身时，藏起来就永远拍不到自己）。
               两格在**源码里**紧邻，但网格是按使用次数排的（见 sortedByUsage）——
               新加的那格用完之前会排在后面，这是既有规则，不为了"看着挨着"
               去破坏它：位置跟着真实使用走，是这个面板的核心约定。 */
            Action(title: "截图·含窗口", symbol: "rectangle.dashed.badge.record", cmd: ["shot", "--interactive", "--keep-panel"], done: "已截图（含面板）"),
            Action(title: "录屏",   symbol: "record.circle", cmd: [], done: "录屏已切换（再按一次停止）", script: "screen_rec.sh", scriptArgs: ["--toggle"]),
            Action(title: "计算器", symbol: "plus.forwardslash.minus", cmd: ["launch", "--name", "计算器"], done: "已打开计算器"),
            Action(title: "WPS 文档", symbol: "doc.richtext", cmd: ["launch", "--name", "WPS"], done: "已打开 WPS"),
            Action(title: "微信",   symbol: "message", cmd: ["launch", "--name", "微信"], done: "已打开微信"),
            Action(title: "豆包",   symbol: "sparkles", cmd: ["launch", "--name", "豆包"], done: "已打开豆包"),
            // WorkBuddy：普通启动，不播开场动画（2026-10-25 用户拍板）
            //   动画只在开机由 run-at-login.sh 播一次；面板点一下不该整屏动画。
            //   原实现走 wblaunch play，现已废弃（viaWblaunch 字段保留未用）。
            Action(title: "WorkBuddy", symbol: "brain.head.profile",
                   cmd: ["launch", "--name", "WorkBuddy"], done: "已打开 WorkBuddy"),
            // 末行格：DeepSeek Harness 属「开发者工具」，与上面那排日常 App 不是一类，
            // 固定排在最后（pinnedLast），好让「工具」和「应用」在视觉上分层。
            // ⚠ 2026-10-25 加了第 14 格之后，末行是「抖音 + DeepSeek Harness」两格，
            //   两格均分整行宽度（见 buildIfNeeded 里的 stretchW），不再是独占通栏。
            Action(title: "DeepSeek Harness", symbol: "chevron.left.forwardslash.chevron.right",
                   cmd: ["launch", "--name", "DeepSeek Harness"],
                   done: "已启动 DeepSeek Harness", pinnedLast: true),
            Action(title: "iKuuuVPN", symbol: "network.badge.shield.half.filled", cmd: ["launch", "--name", "iKuuuVPN"], done: "已打开 iKuuuVPN"),
            Action(title: "浏览器", symbol: "safari", cmd: ["launch", "--name", "浏览器"], done: "已打开浏览器"),
            Action(title: "访达",   symbol: "folder.fill", cmd: ["launch", "--name", "访达"], done: "已打开访达"),
            Action(title: "酷狗音乐", symbol: "music.note", cmd: ["launch", "--name", "酷狗"], done: "已打开酷狗"),
            Action(title: "抖音",   symbol: "play.rectangle.fill", cmd: ["launch", "--name", "抖音"], done: "已打开抖音"),
        ])
    }

    // ── 构建 ─────────────────────────────────────────────────

    /// 只建不显示（给 --layout-check 用：不显示也能验证几何）
    @discardableResult
    /// 预热：把窗口和视图**先建好但不显示**。
    ///
    /// ⚠⚠ 为什么要预热：`buildIfNeeded()` 要建 780×618 的视图树（含地球、
    ///   12 个按钮、自检栏、输入框），首次调用实测 0.8~1.2 秒。这期间面板
    ///   还没拿到键盘，用户按下热键后立刻打字，**头几个字会丢到别的 App 里**。
    ///   实测：热键后 1.3s 内输入会丢第一轮（2026-10-23 复现）。
    ///   预热后首次唤起只需 60~120ms，跟后续几次一致。
    func warmUp() {
        _ = buildIfNeeded()
        window?.orderOut(nil)     // 建好但绝不显示
    }

    func buildIfNeeded() -> Panel {
        if built { return self }
        built = true

        let W = Layout.W, H = Layout.H, PAD = Layout.pad, CW = Layout.CW
        let rect = NSRect(x: 0, y: 0, width: W, height: H)

        window = NSPanel(contentRect: rect,
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        window.title = "灵台智枢"
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isFloatingPanel = true
        // ⚠ 关掉出现动画：默认的"淡入/缩放"会占掉约 200ms，这期间窗口还没
        //   成为 key window，用户按完热键立刻打的头一两个字会落到别的 App 里。
        //   实测：有动画时 0.5s 内输入必丢，关掉后明显改善（2026-10-23）。
        window.animationBehavior = .none
        window.level = .floating
        window.hidesOnDeactivate = false
        window.backgroundColor = .clear
        window.isOpaque = false
        // ⚠ 固定深色外观：v2~v4 跟随系统，实测同一套布局在浅色下卡片糊成一片
        //   （半透明白底 + 浅色底板 = 没有对比）。深色是这套视觉语言的前提。
        window.appearance = NSAppearance(named: .darkAqua)

        // ── 底板：档案纸（近黑 + 细网格 + 角标）────────────────
        let v = ArchiveBackground(frame: rect)
        v.wantsLayer = true

        // ── 标题区 ────────────────────────────────────────────
        /* 标识 28 → 34：折面星的明暗关系要到这个尺寸才读得出来，
           28pt 上那 15 个面会糊成一块灰。页头高 46，34 正好居中（+6）。 */
        let mark = BrandMark(frame: NSRect(x: PAD, y: Layout.headerY + 6, width: 34, height: 34))
        v.addSubview(mark)

        // 标题：16 → 17，字重降到 semibold。
        //   参考稿的标题不是"最黑的那一行"，而是靠字距和大小撑住的；
        //   bold 在近黑底上会糊边（浅色字被抗锯齿向外扩）。
        let title = makeLabel("灵台智枢", size: 15, weight: .semibold, color: Palette.title)
        title.frame = NSRect(x: PAD + 44, y: Layout.headerY + 21, width: 240, height: 20)
        v.addSubview(title)
        titleLabel = title
        // 扫描线层：盖在所有内容之上、但不吃点击（hitTest 返回 nil）
        let sweep = ScanlineView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        sweep.autoresizingMask = [.width, .height]
        v.addSubview(sweep)
        scanline = sweep

        // 档案编号（等宽小字）—— 工业档案风的关键细节：
        //   给界面一个"编号"，它就不再是个浮层，而是"一份被调阅的档案"。
        let code = makeMonoLabel("LINGTAI APEX / LOCAL-CTRL / V5.11", size: 8.5,
                                 weight: .regular, color: Palette.faint)
        code.frame = NSRect(x: PAD + 44, y: Layout.headerY + 7, width: 240, height: 12)
        v.addSubview(code)

        let hot = makeMonoLabel("⌃⌥SPACE 唤起 · ESC 关闭", size: 9.5,
                                weight: .medium, color: Palette.dim, align: .right)
        hot.frame = NSRect(x: W - PAD - 240, y: Layout.headerY + 14, width: 240, height: 14)
        v.addSubview(hot)

        // 顶栏细分隔线
        Palette.hairSoft.setStroke()
        let hRule = NSBezierPath()
        hRule.move(to: NSPoint(x: PAD, y: Layout.headerY - 2.5))
        hRule.line(to: NSPoint(x: W - PAD, y: Layout.headerY - 2.5))
        hRule.lineWidth = 1
        hRule.stroke()

        // ── 卡 1：常用操作（3 列 × 5 行；末行那条通栏）──────────
        let gridCard = ArchiveCard(frame: NSRect(x: PAD, y: Layout.gridY,
                                                 width: Layout.mainW, height: Layout.gridH))
        gridCard.stamp = "01 / COMMON"
        // ⚠ 打标记：--layout-check 靠它精确数「常用区按钮」，
        //   否则输入行那两个（执行/转交）也会被算进来 → 断言恒红。
        gridCard.identifier = NSUserInterfaceItemIdentifier("grid")
        v.addSubview(gridCard)

        let gTitle = makeLabel("常用操作", size: 11.5, weight: .semibold,
                               color: Palette.title, kern: 0.9)
        gTitle.frame = NSRect(x: Layout.cardPad, y: Layout.gridH - 25, width: 120, height: 15)
        gridCard.addSubview(gTitle)

        let gHint = makeMonoLabel("CLICK TO EXECUTE", size: 8.5,
                                  weight: .regular, color: Palette.faint, align: .right)
        gHint.frame = NSRect(x: Layout.mainW - Layout.cardPad - 160, y: Layout.gridH - 24,
                             width: 160, height: 12)
        gridCard.addSubview(gHint)

        let list = actions()
        let gridTop = Layout.gridH - Layout.gridTitleH
        /* 末行不满时的横向分配。
           2026-10-25：动作 13 → 14（新增「截图·含窗口」），末行从「1 格通栏」
           变成「2 格」。原来那条 `count % cols == 1 才通栏` 的规则在 14 格时失效：
           若仍按单元格宽度排，右侧会空出一整格 —— 那不是留白，是漏排。
           所以规则改成通用的：**末行有几格，就把整行宽度均分给这几格**。
           1 格 == 原来的通栏；2 格 == 两个半宽；3 格 == 与上面各行一致。 */
        let lastRowIndex = (list.count - 1) / Layout.cols
        let lastRowCount = list.count - lastRowIndex * Layout.cols
        let stretchW = (Layout.mainW - Layout.cardPad * 2 - CGFloat(lastRowCount - 1) * Layout.gap)
            / CGFloat(lastRowCount)
        for (i, a) in list.enumerated() {
            let r = i / Layout.cols, c = i % Layout.cols
            let inLastRow = (r == lastRowIndex)
            let tw = inLastRow ? stretchW : Layout.tileW
            let b = TileButton(frame: NSRect(
                x: Layout.cardPad + CGFloat(c) * (tw + Layout.gap),
                y: gridTop - CGFloat(r + 1) * Layout.tileH - CGFloat(r) * Layout.gap,
                width: tw, height: Layout.tileH))
            b.kind = .tile
            b.title = a.title
            b.symbol = a.symbol
            b.target = self
            b.action = #selector(quickAction(_:))
            b.identifier = NSUserInterfaceItemIdentifier(a.title)
            b.toolTip = a.done
            // 应用类格子用 App 原图标；功能区（截图/录屏）继续用 SF Symbol
            if let n = a.appName { b.appIcon = appIconImage(for: n) }
            gridCard.addSubview(b)
        }

        // ── 卡 2：唯一输入框（智能识别，简单直做 / 复杂转交）────
        let inCard = ArchiveCard(frame: NSRect(x: PAD, y: Layout.inputY,
                                               width: Layout.mainW, height: Layout.inputH))
        inCard.stamp = "02 / COMMAND"
        v.addSubview(inCard)

        hintLabel = makeLabel("写下来就行 · 简单的直接做，复杂的自动分流给天公/豆包/WorkBuddy",
                              size: 10.5, weight: .regular, color: Palette.dim)
        hintLabel.frame = NSRect(x: Layout.cardPad, y: Layout.inputH - 25,
                                 width: Layout.mainW - 200, height: 14)
        inCard.addSubview(hintLabel)

        // 输入行几何：外壳 + 两个按钮，三者右对齐且互不重叠
        let ibW: CGFloat = 46, ibGap: CGFloat = 8, rowY: CGFloat = 16, rowH: CGFloat = 42
        let innerRight = Layout.mainW - Layout.cardPad
        let wbX = innerRight - ibW
        let goX = wbX - ibGap - ibW
        let shellX = Layout.cardPad
        let shellW = goX - ibGap - shellX

        fieldShell = GlassCard(frame: NSRect(x: shellX, y: rowY, width: shellW, height: rowH))
        fieldShell.radius = 8
        inCard.addSubview(fieldShell)

        // ⚠⚠ 子视图坐标必须是**相对 fieldShell 的**，不是相对窗口的。
        //   踩过：下面三行一开始写的是 shellX + 12 / shellX + 32，
        //   而 shellX 已经是 fieldShell 自己的位置 → 整个输入框向右平移了
        //   一遍，右边 34pt 直接跑出卡片外（--layout-check 抓出来的）。
        let inIcon = NSTextField(labelWithString: "⌘")
        inIcon.font = uiFont(size: 13, weight: .medium)
        inIcon.textColor = Palette.faint
        inIcon.frame = NSRect(x: 12, y: 12, width: 18, height: 18)
        fieldShell.addSubview(inIcon)

        freeInput = NSTextField(frame: NSRect(x: 32, y: 11,
                                             width: shellW - 32 - 14, height: 20))
        freeInput.placeholderString = "打开微信 / 截图 / 录屏 / 打开iKuuuVPN / 帮我写年度总结…"
        freeInput.font = uiFont(size: 13, weight: .regular)
        freeInput.target = self
        freeInput.action = #selector(submitFree(_:))
        freeInput.isBezeled = false
        freeInput.drawsBackground = false
        freeInput.focusRingType = .none
        freeInput.delegate = self
        freeInput.lineBreakMode = .byTruncatingTail
        fieldShell.addSubview(freeInput)

        let go = TileButton(frame: NSRect(x: goX, y: rowY, width: ibW, height: rowH))
        go.kind = .accent
        go.title = "↑"
        go.symbol = "arrow.up"
        go.font = uiFont(size: 15, weight: .bold)
        go.target = self
        go.action = #selector(submitFree(_:))
        go.keyEquivalent = "\r"
        go.keyEquivalentModifierMask = [.command]
        go.toolTip = "执行（回车 / ⌘↵）"
        inCard.addSubview(go)

        // 「转到 WorkBuddy」：不是第二个输入框，只是转交时的快捷跳转
        wbButton = TileButton(frame: NSRect(x: wbX, y: rowY, width: ibW, height: rowH))
        wbButton.kind = .ghost
        wbButton.title = "→"
        wbButton.symbol = "arrow.turn.up.right"
        wbButton.font = uiFont(size: 14, weight: .medium)
        wbButton.target = self
        wbButton.action = #selector(openWorkBuddy(_:))
        wbButton.toolTip = "转到 WorkBuddy"
        wbButton.isEnabled = false
        inCard.addSubview(wbButton)

        // ── 卡 3：启动动画设置（单行版）──────────────────────
        //   原来是「标题 / 两个输入 / 两个按钮」三行、96pt 高，
        //   比放 12 个常用操作的网格还占地方 —— 而这些值一年改两次。
        //   压成一行之后，三张卡的高度比例回到 4:2:1，
        //   视线先落在常用操作，再是命令，最后才是设置。
        let bootCard = ArchiveCard(frame: NSRect(x: PAD, y: Layout.startY,
                                                 width: Layout.mainW, height: Layout.startH))
        bootCard.stamp = "03 / STARTUP"
        bootCard.identifier = NSUserInterfaceItemIdentifier("bootcfg")
        v.addSubview(bootCard)

        let bTitle = makeLabel("启动动画", size: 11.5, weight: .semibold,
                               color: Palette.title, kern: 0.9)
        bTitle.frame = NSRect(x: Layout.cardPad, y: Layout.startH - 21, width: 120, height: 13)
        bootCard.addSubview(bTitle)

        bootNote = makeMonoLabel("bootanim.config.json", size: 8,
                                 weight: .regular, color: Palette.faint, align: .right)
        bootNote?.frame = NSRect(x: Layout.mainW - Layout.cardPad - 240,
                                 y: Layout.startH - 20, width: 240, height: 11)
        if let n = bootNote { bootCard.addSubview(n) }

        // 一行四件：身份名称 / 用户编号 / 主题 / 写入
        let ctlY: CGFloat = 11, ctlH: CGFloat = 28
        let innerW = Layout.mainW - Layout.cardPad * 2
        let btnThemeW: CGFloat = 100, btnApplyW: CGFloat = 104, gapC: CGFloat = 8
        let fieldW = (innerW - btnThemeW - btnApplyW - gapC * 3) / 2

        func bootField(x: CGFloat, key: String, fallback: String, tip: String) -> NSTextField {
            let shell = GlassCard(frame: NSRect(x: x, y: ctlY, width: fieldW, height: ctlH))
            shell.radius = 3                      // 圆角收到 3：输入框属于"刻进去的槽"，不是胶囊
            bootCard.addSubview(shell)
            let f = NSTextField(frame: NSRect(x: 9, y: 6, width: fieldW - 18, height: 16))
            let vv = (BootCfg.current[key] as? String) ?? fallback
            f.stringValue = vv
            f.placeholderString = tip
            f.font = monoFont(size: 11.5, weight: .regular)
            f.textColor = Palette.title
            f.isBezeled = false
            f.drawsBackground = false
            f.focusRingType = .none
            shell.addSubview(f)
            return f
        }
        bootName = bootField(x: Layout.cardPad, key: "identity", fallback: "温昼", tip: "身份名称")
        bootCode = bootField(x: Layout.cardPad + fieldW + gapC, key: "identityId",
                             fallback: "LS-WZ-0961-01", tip: "用户编号")

        bootTheme = (BootCfg.current["theme"] as? String) ?? "dark"

        let thX = Layout.cardPad + (fieldW + gapC) * 2
        let thBtn = TileButton(frame: NSRect(x: thX, y: ctlY, width: btnThemeW, height: ctlH))
        thBtn.kind = .ghost
        thBtn.title = "主题 · 深色"
        thBtn.symbol = "moon"
        thBtn.font = uiFont(size: 11, weight: .medium)
        thBtn.radius = 3
        thBtn.target = self
        thBtn.action = #selector(toggleBootTheme(_:))
        thBtn.toolTip = "点击切换深色 / 浅色（立即写入）"
        bootCard.addSubview(thBtn)
        bootThemeBtn = thBtn
        refreshBootThemeBtn()

        let apBtn = TileButton(frame: NSRect(x: thX + btnThemeW + gapC, y: ctlY,
                                            width: btnApplyW, height: ctlH))
        // 全屏只留一个主色按钮（02 的 ↑）。写入是一次性动作，
        // 和"执行"抢同一个绿，主次就没了 —— 降成 ghost，靠位置和图标区分。
        apBtn.kind = .ghost
        apBtn.title = "写入并同步"
        apBtn.symbol = "arrow.down.doc"
        apBtn.font = uiFont(size: 11, weight: .semibold)
        apBtn.radius = 3
        apBtn.target = self
        apBtn.action = #selector(applyBootConfig(_:))
        apBtn.toolTip = "写入 bootanim.config.json，下次启动生效"
        bootCard.addSubview(apBtn)

        // ── 卡 4：右侧三维自转地球 ──────────────────────────
        //   ⚠ 地球与自检栏必须**分区**，不能叠在一起。
        //     叠在一起时地球的外缘会压住自检项的文字，
        //     两层都看不清 —— 这是"装饰压过信息"的典型翻车。
        //   现在：地球独占顶部一块，自检块在下方，两者不重叠。
        /* 宽度跟右栏对齐（sideW），高度才用 globeSize。
           之前是 190×190 居中，结果地球卡比下面的自检卡窄 18pt ——
           右栏两块不同宽，整条竖边就断了。球体本身在框内居中，
           半径由 min(w,h) 决定，所以球不会因为变宽而变形。 */
        globe = GlobeView(frame: NSRect(x: Layout.sideX,
                                       y: Layout.sideY - Layout.globeSize,
                                       width: Layout.sideW, height: Layout.globeSize))
        v.addSubview(globe)

        // 地球下方的状态字（等宽）
        let retTag = makeMonoLabel("DRAG · ORBIT", size: 8.5, weight: .medium,
                                   color: Palette.faint, align: .center)
        retTag.frame = NSRect(x: Layout.sideX, y: Layout.sideY - Layout.globeSize - 11,
                              width: Layout.sideW, height: 11)
        v.addSubview(retTag)

        // ── 卡 4：右侧实时自检栏 ───────────────────────────────
        selfCheck = SelfCheckBar(frame: NSRect(x: Layout.sideX, y: Layout.sideSplitY - Layout.sideCheckH,
                                               width: Layout.sideW, height: Layout.sideCheckH))
        v.addSubview(selfCheck)

        // ── 状态行 ────────────────────────────────────────────
        statusLabel = makeLabel("就绪", size: 11, weight: .medium, color: Palette.body)
        statusLabel.frame = NSRect(x: PAD, y: Layout.statusY + 4, width: CW - 300, height: 16)
        v.addSubview(statusLabel)

        // 常驻告诉用户文件去哪 —— 用户原话「我不清楚会放在哪个位置」
        // P10：截图按 年/月 归档，所以这里带出**当前**年月（不是写死的示例）
        let media = makeMonoLabel(Palette.mediaHint, size: 9,
                                  weight: .regular, color: Palette.faint, align: .right)
        media.frame = NSRect(x: W - PAD - 260, y: Layout.statusY + 5, width: 260, height: 14)
        media.toolTip = "\(Palette.mediaDir)/截图（图） / 录屏（视频）"
        v.addSubview(media)

        window.contentView = v
        window.center()
        return self
    }

    /// 主题按钮的标题跟着当前值走 —— 按钮本身就是"状态显示"，
    /// 不另做一行说明文字（面板里每一行都要有活干）。
    private func refreshBootThemeBtn() {
        bootThemeBtn?.title = bootTheme == "dark" ? "主题 · 深色" : "主题 · 浅色"
        bootThemeBtn?.symbol = bootTheme == "dark" ? "moon" : "sun.max"
        bootThemeBtn?.needsDisplay = true
    }

    @objc func toggleBootTheme(_ sender: Any?) {
        bootTheme = (bootTheme == "dark") ? "light" : "dark"
        refreshBootThemeBtn()
        // 单选型设置点了就该生效，不该再让用户去点"写入"
        applyBootConfig(sender)
    }

    @objc func applyBootConfig(_ sender: Any?) {
        var d = BootCfg.current
        d["identity"] = (bootName?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        d["identityId"] = (bootCode?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        if (d["identity"] as? String ?? "").isEmpty { d["identity"] = "温昼" }
        if (d["identityId"] as? String ?? "").isEmpty { d["identityId"] = "LS-WZ-0961-01" }
        d["theme"] = bootTheme
        d["sceneGate"] = (d["sceneGate"] as? Bool) ?? true
        d["gateTimeoutMs"] = (d["gateTimeoutMs"] as? Int) ?? 3000

        let ok = BootCfg.write(d)
        bootNote?.stringValue = ok ? "已写入 · 下次启动生效" : "写入失败：目录不可写"
        bootNote?.textColor = ok ? Palette.accent : Palette.bad
        statusLabel.stringValue = ok ? "启动动画设置已同步" : "启动动画设置写入失败"
    }

    @objc func openWorkBuddy(_ sender: Any?) {
        // 工件B：这个按钮以前只负责「播动画 + 打开 WorkBuddy」，
        // 剩下的新建任务/粘贴/发送全靠用户。现在整条链路在 flash 里跑完。
        // ⚠ 没有待转交原文时退化成「只打开」（用户可能只是想开 WorkBuddy）。
        guard let text = pendingHandoff ?? NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusLabel.stringValue = "没有待转交的内容"
            statusLabel.textColor = Palette.dim
            return
        }
        if let target = pendingTarget, target != "workbuddy" {
            if target == "ambiguous" {
                statusLabel.textColor = Palette.warn
                statusLabel.stringValue = "选项已复制；补一句目标，或选 A/B/C"
                return
            }
            let name = target == "doubao" ? "豆包" : "天公"
            logUsage(target)
            lowerPanelForApp()
            openTargetApp(target)
            if let text = pendingHandoff {
                pasteIntoTarget(text, target: target)
            } else {
                statusLabel.textColor = Palette.warn
                statusLabel.stringValue = "已复制给 \(name) · 在 \(name) 里 ⌘V 发送"
            }
            return
        }
        performHandoff(text)
    }

    /// W6：给豆包/天公的提示词只复制 + 打开目标 App，不自动按键。
    /// v1 不赌目标 App 的输入框焦点；用户按一次 ⌘V，比点错安全。
    func stageForTarget(_ text: String, target: String) {
        pendingHandoff = text
        pendingTarget = target
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if target == "ambiguous" {
            setHandoff("不确定：天公/豆包/WorkBuddy · 已复制选项，补一句目标或选 A/B/C")
            return
        }
        let name = target == "doubao" ? "豆包" : (target == "tiangong" ? "天公" : "WorkBuddy")
        setHandoff("已优化给 \(name) · 点 → 打开并粘贴")
    }

    func decodeB64(_ text: String) -> String? {
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func openTargetApp(_ target: String) {
        let bundle = target == "doubao" ? "com.bot.neotix.doubao" : "com.deepseek.dsh"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    func logUsage(_ target: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tiangong/usage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        let ts = formatter.string(from: Date())
        let line = "{\"ts\":\"\(ts)\",\"target\":\"\(target)\",\"action\":\"handoff\"}\n"
        let path = dir.appendingPathComponent("events.jsonl").path
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    func runProcess(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// W6 v1：打开目标 App 后自动粘贴；不自动回车，用户检查后发送。
    func pasteIntoTarget(_ text: String, target: String) {
        let bundle = target == "doubao" ? "com.bot.neotix.doubao" : "com.deepseek.dsh"
        let name = target == "doubao" ? "豆包" : "天公"
        let macctl = scriptsDir() + "/macctl"
        statusLabel.textColor = Palette.dim
        statusLabel.stringValue = "打开 \(name) 并粘贴…"
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        _ = runProcess(macctl, ["front", "--app", bundle])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if target == "doubao" {
            // 豆包可能停在订阅记录/菜单；先 Esc，再开新对话，输入框才稳定
            // ⚠ 每个发事件的调用都要带 --require-front <bundle>（ERR-0024：
            //   没校验前台就把字打进了微信。macctl 侧现在无 --app 就拒发，
            //   这里显式声明"要校验的就是刚置前的那个 App"）。
            _ = runProcess(macctl, ["key", "--key", "esc", "--require-front", bundle])
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            _ = runProcess(macctl, ["tap-text", "--text", "新对话", "--require-front", bundle])
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        if target == "tiangong" {
            // DSH 激活后输入框不一定有焦点；先点一下「发消息」占位
            _ = runProcess(macctl, ["tap-text", "--text", "发消息", "--require-front", bundle])
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        let code = runProcess(macctl, ["type", "--text", text, "--require-front", bundle])
        statusLabel.textColor = code == 0 ? Palette.ok : Palette.warn
        statusLabel.stringValue = code == 0
            ? "已粘贴到 \(name) · 检查后发送"
            : "已复制 · 在 \(name) 里 ⌘V 发送"
    }

    func undoHandoff() {
        pendingHandoff = nil
        pendingTarget = nil
        clearHandoff()
        statusLabel.stringValue = "已撤销分流"
        statusLabel.textColor = Palette.dim
    }

    func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isKeyWindow == true else { return event }
            let cmd = event.modifierFlags.contains(.command)
            if cmd && (event.keyCode == 36 || event.keyCode == 76) {
                self.submitFree(nil)
                return nil
            }
            if cmd, event.charactersIgnoringModifiers?.lowercased() == "z", self.pendingHandoff != nil {
                self.undoHandoff()
                return nil
            }
            return event
        }
    }

    func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// 转交全链路（工件B）。
    ///
    /// ⚠ 面板先**降层**再转交：AX 点击和 ⌘V 都要落在 WorkBuddy 上，
    ///   面板若还压在顶层，粘贴会打进面板自己的输入框。
    /// - Parameter skill: 默认挂 mac-control；自检传 nil ——
    ///   ⚠ 挂了技能，被转交过去的那一端会真的开始操作桌面（实测它打开「下载」、
    ///   列目录、弹确认框），反过来干扰自检里所有计时敏感的像素判据。
    func performHandoff(_ text: String, skill: String? = "mac-control") {
        statusLabel.textColor = Palette.dim
        statusLabel.stringValue = "转交中 · 新建任务 → 粘贴 → 发送…"
        lowerPanelForApp()
        var r = handoffToWorkBuddy(text, skill: skill)
        // ⚠ 转交是真按键 + 真 AX 点击，天然有抖动（实测 10 次里偶发 1 次卡在某步）。
        //   失败一次就放弃太脆 —— 立刻重试一遍（会重新新建任务/清空输入框），
        //   成功率从 ~90% 提到接近 100%。
        if !r.ok {
            hdDebug("[handoff] 第一次失败（\(r.step)），重试一次")
            // 界面保持安静（用户选的），但复盘要看得见：写审计，不弹提示。
            let dfh = DateFormatter(); dfh.dateFormat = "yyyy-MM-dd"
            let tfh = DateFormatter(); tfh.dateFormat = "HH:mm:ss"
            let ap = scriptsDir() + "/../logs/" + dfh.string(from: Date()) + ".jsonl"
            let ln = "{\"t\":\"\(tfh.string(from: Date()))\",\"intent\":\"handoff_retry\",\"result\":\"info\",\"evidence\":\"首次卡在 \(r.step)，已重试\"}\n"
            if let h = FileHandle(forWritingAtPath: ap) {
                h.seekToEndOfFile(); h.write(ln.data(using: .utf8)!); h.closeFile()
            } else { try? ln.write(toFile: ap, atomically: true, encoding: .utf8) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            r = handoffToWorkBuddy(text, skill: skill)
        }
        if r.ok {
            statusLabel.textColor = Palette.ok
            statusLabel.stringValue = "✅ 已转交 WorkBuddy · \(r.ms)ms"
            pendingHandoff = nil
            pendingTarget = nil
            logUsage("workbuddy")
        } else {
            // 自动转交失败必须回到用户眼前 + 说清停在哪一步，
            // 否则就是最糟的形态：面板让开了，桌面什么也没发生。
            show()
            statusLabel.textColor = Palette.bad
            statusLabel.stringValue = "⚠️ 自动转交停在「\(r.step)」：原文已复制，点 → 后 ⌘V 发送"
            setHandoff("自动转交未完成（\(r.step)）· 原文已复制，手动 ⌘V 即可")
        }
    }

    // ── 显示 / 隐藏 ──────────────────────────────────────────

    // ── 空闲时不抢鼠标：失去 key 就降到普通层 ──────────────────
    // 用户明确：有任务/项目时可以用鼠标键盘；没指令时不得抢。
    // NSPanel + .floating + hidesOnDeactivate=false 会一直压在其他窗口上，
    // 鼠标划过/点击面板区域时会先落到面板，这就是“轻微抢鼠标”的来源。
    func windowDidBecomeKey(_ notification: Notification) {
        window?.level = .floating
        startGlobe()
        startSelfCheckTimer()
        writeHotKeyState(note: "panel key -> floating")
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !busy else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self = self, self.window?.isKeyWindow == false else { return }
            self.window?.level = .normal
            self.stopGlobe()
            // 自检继续跑：面板可能可见但不在前台；doctor 已改被动，不会抢鼠标。
            writeHotKeyState(note: "panel resign -> normal")
        }
    }

    func show() {
        // ⚠⚠ 顺序不能反：以前是「异步 activate + 立刻 makeKey」。
        //   面板能出现在屏幕上，但 App 还没真正激活 → 窗口不是 key →
        //   键盘事件仍然发给下面那个 App。用户看到的就是「面板出来了，
        //   打字没反应」。现在：同步激活 → 再 makeKey → 激活后再补一次焦点。
        NSApp.activate(ignoringOtherApps: true)
        if let app = NSRunningApplication.current as NSRunningApplication? {
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
        buildIfNeeded()
        // 降层后回来必须恢复置顶层级，否则面板会被普通窗口永久压住
        window.level = .floating
        /* 入场：先透明再淡入 + 8pt 上浮。
           ⚠ 只做透明度与位移，不做缩放 —— NSPanel 的 window 缩放做不了，
             硬做会把坐标算错（面板里所有子视图都是绝对坐标布局）。
           0.16s 是"能感觉到但不会等"的临界值。 */
        if window.alphaValue == 1 {
            window.alphaValue = 0
            let from = window.frame
            window.setFrame(from.offsetBy(dx: 0, dy: -8), display: false)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
                window.animator().setFrame(from, display: true)
            }
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(freeInput)
        refreshSelfCheck()
        startAmbientEffects()
        if watermark == nil { installWatermark() }
        if noiseLayer == nil { installNoise() }
        startSelfCheckTimer()
        installKeyMonitor()
        startGlobe()
        // ⚠ 用户报的「面板出来了但打字没反应」，就是这一段的状态没对：
        //   窗口可见 ≠ 窗口能接键盘。可见但 key=false（或 App 未激活）时，
        //   敲键盘全落到下面的 App 里，用户看到的就是「打字没反应」。
        //   把这个状态写进 /tmp/flash.hotkey，坏了能自证，不用靠猜。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            // 激活是异步落地的，等它落地再补一次焦点，否则第一次点击会「吃掉」一次按键
            self?.window?.makeKey()
            self?.window?.makeFirstResponder(self?.freeInput)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let w = self?.window else { return }
            let fr = w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            writeHotKeyState(note: "show key=\(w.isKeyWindow ? 1 : 0) "
                             + "active=\(NSApp.isActive ? 1 : 0) fr=\(fr)")
        }
    }

    func hide() {
        window?.orderOut(nil)
        stopGlobe()
        stopSelfCheckTimer()
        removeKeyMonitor()
        stopAmbientEffects()
    }

    /// 让位：把面板收起来并把激活权交还系统。
    ///
    /// ⚠⚠ 这一步是「点了 App 快捷键，目标 App 没到最上层」的**直接根因**：
    ///   面板是 `NSPanel` + `level = .floating`。只要它还在屏幕上，
    ///   它就**永远压在普通 App 上面** —— 这跟目标 App 有没有置前是两件事。
    ///   所以「点了按钮看不到目标 App 上来」的体感，实际是
    ///   目标 App 已经到前台了，只是被面板挡着看不见。
    ///
    ///   必须先收面板再置前，顺序反了就会出现
    ///   「面板消失了但App 没上来」的中间态。
    func yieldForFrontmost() {
        hide()
        // 让 AppKit 把这次「放弃激活」真正落到 WindowServer，
        // 否则紧接着的 open -b 可能与面板的 orderOut 抢同一次激活权。
        NSApp.activate(ignoringOtherApps: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// 面板降层（用户拍板 Q5-c：**留在原地**，降到不挡 App 的层级）。
    ///
    /// ⚠ 与 yieldForFrontmost 的区别：那个是「收起来」，这个是「让开」。
    ///   用户的原话是「成功后面板别消失，我要还在原处能找到它」——
    ///   于是 .floating → .normal：目标 App 的窗口一激活就盖在它上面，
    ///   但面板仍在原位，点一下 Dock 上的闪控（或 ⌥Space）就能回到最上层。
    func lowerPanelForApp() {
        guard let w = window else { return }
        w.level = .normal
        stopGlobe()
        // 保留 selfCheckTimer：让位不等于停止刷新；hide() 才停。
        // 把激活权交还给系统：不这样做，紧跟着的目标 App 激活会和
        // 「面板还占着 key 窗口」抢同一次激活（Q4 偶发失败的成因之一）。
        NSApp.activate(ignoringOtherApps: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
    }

    // ── 实时自检 ──────────────────────────────────────────────

    /// 采集真实状态并刷新自检栏。
    /// ⚠ 采集要跑子进程（doctor / 目录列举），**不能**在 draw 里做 ——
    ///   那会让每次重绘都 fork 进程，面板直接卡死。
    ///   所以：显示时采一次，之后每 4 秒在后台线程采，主线程只负责贴数据。
    func refreshSelfCheck() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = Probe.collect()
            let items = Probe.items(from: snap)
            let okCount = items.filter { $0.ok }.count
            let summary = snap.panelSummary.isEmpty ? "\(okCount)/\(items.count) CHECKS PASSED" : snap.panelSummary
            DispatchQueue.main.async {
                guard let self = self, let bar = self.selfCheck else { return }
                bar.items = items
                bar.summary = summary
                bar.needsDisplay = true
            }
        }
    }

    /// 地球自转。相位推进用 0.06s 的定时器而不是 rAF ——
    /// 面板是 NSPanel，后台时 rAF 会被节流，定时器反而更稳。
    /// ⚠ 频率比旧准星高：准星是 2D 刻度环，0.12s 一帧够；
    ///   地球是三维投影，线框密集，帧率低会看出「一跳一跳」。
    private var globeTimer: Timer?
    private var selfCheckTimer: Timer?
    // ── 字效 / 扫描线（借鉴 ai-workstation 的 letter-glitch + GSAP 节奏）────
    //   目的不是炫技：面板是每天开合十几次的东西，静止画面看久了会"没反应"。
    //   每隔几秒让标题抖一下，等于告诉用户"我活着"，成本几乎为零。
    //   ⚠ 只在面板可见时跑；自检模式（--selftest-confirm）不启用，
    //     否则 selftest 抓标题文案会偶发失败。
    weak var titleLabel: NSTextField?
    private weak var scanline: ScanlineView?
    private var glitchTimer: Timer?
    private var glitchTicks = 0
    private let glitchGlyphs = Array("方寸山矩阵终端灵枢智台日月星辰爻卜")
    private let titleText = "灵台智枢"

    /// 装地球水印：垫在最底层、点击穿透、极慢转动。
    ///   用户要求「可作背景，但不能看不清面板、不能吃掉交互」——
    ///   三条都靠这里保证：alphaValue 0.10 / hitTest nil（见 GlobeWatermark）/
    ///   phase 每 5 帧才推进一次。
    func installWatermark() {
        guard let cv = window?.contentView else { return }
        let wm = GlobeWatermark(frame: NSRect(x: Layout.W - 520, y: -90, width: 560, height: 560))
        wm.phase = 120
        wm.alphaValue = 0.10
        cv.addSubview(wm, positioned: .below, relativeTo: nil)
        watermark = wm
    }

    /// 装颗粒层：盖在最上层、点击穿透。
    ///   ⚠ 必须在内容构建完之后加，否则会压在地球/卡片下面看不到。
    func installNoise() {
        /* 2026-10-25 01:30 重做后重新打开（ERR-0015 的修复版）。
           上一版用 `NSColor(patternImage:).setFill() + bounds.fill()` 平铺 ——
           图案填充用的是**瓦片像素自身的 alpha**（0.5~0.85），外层没有旋钮，
           于是整块面板变成白噪点雪花屏。
           现在：瓦片像素只有「纯白 / 全透明」两种，浓度**只**由
           `NSImage.draw(in:from:operation:fraction:)` 的 fraction 给（0.025）。
           ⚠ 改浓度就只动 NoiseView.grain 这一个数，别再去碰瓦片像素。 */
        guard let cv = window?.contentView else { return }
        let n = NoiseView(frame: cv.bounds)
        n.autoresizingMask = [.width, .height]
        cv.addSubview(n, positioned: .above, relativeTo: nil)
        noiseLayer = n
    }

    func startAmbientEffects() {
        guard !CommandLine.arguments.contains("--selftest-confirm") else { return }
        glitchTimer?.invalidate()
        // 6~11 秒随机一次，避免形成"节拍"（有节拍就像加载动画，不像仪表）
        glitchTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 6...11),
                                           repeats: false) { [weak self] _ in
            self?.runGlitchBurst()
        }
        scanline?.start()
    }

    func stopAmbientEffects() {
        glitchTimer?.invalidate()
        glitchTimer = nil
        glitchTicks = 0
        titleLabel?.stringValue = titleText
        scanline?.stop()
    }

    /// 一次抖动：3 帧、每帧把 1~2 个字符换成同字宽的字形，然后复原
    private func runGlitchBurst() {
        guard let label = titleLabel, window?.isVisible == true else { return }
        glitchTicks = 3
        func frame() {
            guard glitchTicks > 0 else {
                label.stringValue = titleText
                startAmbientEffects()
                return
            }
            glitchTicks -= 1
            var chars = Array(titleText)
            for _ in 0..<Int.random(in: 1...2) {
                let i = Int.random(in: 0..<chars.count)
                chars[i] = glitchGlyphs.randomElement() ?? chars[i]
            }
            label.stringValue = String(chars)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(70)) { frame() }
        }
        frame()
    }

    func startGlobe() {
        stopGlobe()
        globeTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) {
            [weak self] _ in
            guard let self = self, let g = self.globe else { return }
            // 忙碌时快一点、闲时慢一点 —— 用「有任务在跑」的直觉代替进度条。
            self.globePhase += self.busy ? 3.2 : 1.1
            g.phase = self.globePhase
            g.needsDisplay = true
            // 水印每 5 帧推进一次（≈0.3s 一帧）：慢到几乎察觉不到，但"活着"
            self.watermarkTick += 1
            if self.watermarkTick % 5 == 0, let wm = self.watermark {
                wm.phase += self.busy ? 0.9 : 0.22
                wm.needsDisplay = true
            }
        }
    }

    func stopGlobe() {
        globeTimer?.invalidate()
        globeTimer = nil
    }

    /// 自检栏定时刷新：额度/项目/锁都要活着，不能只在唤起时采一次。
    /// 8 秒一次：panel-status 是本机脚本，不碰网络；刷新太快只会浪费 fork。
    func startSelfCheckTimer() {
        stopSelfCheckTimer()
        selfCheckTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            try? "\(Date())\n".write(toFile: "/tmp/flash.selfcheck", atomically: true, encoding: .utf8)
            self.refreshSelfCheck()
        }
    }

    func stopSelfCheckTimer() {
        selfCheckTimer?.invalidate()
        selfCheckTimer = nil
    }

    // ── 转交提示（一行文字，不是独立卡片/输入栏）──────────────
    //
    // ⚠ 面板上**只有一个输入框**（用户明确要求）。
    //   路由判定全部交给 route.sh，面板只负责把结果讲清楚：
    //     · 能直接做 → 报「✅ 已做」
    //     · 是复杂任务 → 原文进剪贴板 + 这一行变橙 + → 按钮亮起

    /// 把待转交的文本写进剪贴板，供用户直接 ⌘V 给 WorkBuddy
    func stageForWorkBuddy(_ text: String) {
        pendingHandoff = text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func setHandoff(_ msg: String) {
        hintLabel.stringValue = msg
        hintLabel.textColor = Palette.warn
        wbButton.isEnabled = true
        wbButton.needsDisplay = true
    }

    func clearHandoff() {
        pendingTarget = nil
        hintLabel.stringValue = "写下来就行 · 简单的直接做，复杂的自动分流给天公/豆包/WorkBuddy"
        hintLabel.textColor = Palette.dim
        wbButton.isEnabled = false
        wbButton.needsDisplay = true
    }

    // ── 速记动作 ─────────────────────────────────────────────

    @objc func quickAction(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let a = actions().first(where: { $0.title == key }) else { return }
        Panel.bumpUsage(a.title)      // 用一次记一次，下次开面板它自己往前挪
        statusLabel.textColor = Palette.dim
        statusLabel.stringValue = "执行中…"

        // ⚠⚠ 「打开 App」这类动作分两步走，顺序不能反：
        //   ① 面板**降层**（.floating → .normal），不收起 —— 用户拍板 Q5-c：
        //      「留在原地，降到不挡 App 的层级」。原来直接 orderOut，
        //      结果用户点完就找不到面板了。
        //   ② 置前**由 flash 自己做**（raiseAppInProcess），不外包给 macctl 子进程。
        //      CLI 子进程里调 NSRunningApplication.activate 是空操作 ——
        //      这正是用户复现的 Q4（微信已开着，点了却排到后面）。
        let handsOver = a.isAppLaunch
        if handsOver { lowerPanelForApp() }

        // 有状态动作（录屏）走脚本，WorkBuddy 走 wblaunch（开场动画），
        // 其余「打开 App」走进程内置前引擎，剩下的是单条 macctl 命令。
        var s = ""
        /* 2026-10-25：原来这里有一条「运行期播开场动画」的分支（viaWblaunch）。
           用户拍板「开场动画只在开机播」之后，没有任何 Action 会把它设成 true →
           已成死代码，且自检会把它当成「面板仍在运行期触发动画」判红。
           保留启动器函数本身（万一以后要做手动预览），只摘掉运行期调用。
           ⚠ 注释里不要写那句调用的字面量 —— 自检按代码 grep，会被注释误命中。 */
        if handsOver {
            let r = raiseAppInProcess(a.title)
            if r.ok {
                // 成功：什么都不用做。面板已降层，目标 App 就在它上面。
                statusLabel.textColor = Palette.ok
                statusLabel.stringValue = "✅ \(a.done) · \(r.how) \(r.ms)ms"
                return
            }
            s = "{\"ok\":false,\"error\":\"RAISE_FAILED\",\"evidence\":\"\(r.how)：\(r.detail)\"}"
        } else if a.cmd.first == "shot" {
            /* 截图走 **mediacap**（launchd job），不再依赖本 App 的「屏幕录制」授权。
               ⚠ 2026-10-25 破局点：换 bundle id 后 TCC 授权变成僵尸条目，用户勾了也不生效；
                 实测同一条 `/usr/sbin/screencapture` 由 launchd 拉起时**不受该限制**。
               流程：写请求 → kickstart → 轮询结果文件 → 报路径。
               面板默认照旧先藏起来（拍不到自己）；带 `--keep-panel` 的那格
               **全程不 hide()/show()** —— 其余流程逐行相同，只差"面板在不在画面里"。 */
            let mode = a.cmd.contains("--interactive") ? "region" : "shot"
            /* 「截图·含窗口」与「截图」的唯一差别就在这里。
               为什么不做成两个分支各写一遍：两条流程只要有一处不同步，
               早晚会出现"含窗口版本少了超时处理"这类漂移 —— 同一段代码、
               一个开关，是这个需求最省心的形状。 */
            let keepPanel = a.cmd.contains("--keep-panel")
            let req = NSHomeDirectory() + "/.tiangong/mediacap.request"
            let res = NSHomeDirectory() + "/.tiangong/mediacap.result"
            try? "mode=\(mode)\n".write(toFile: req, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: res)

            let wasVisible = window?.isVisible ?? false
            if !keepPanel {
                hide()
                RunLoop.current.run(until: Date().addingTimeInterval(0.18))
            }
            let kick = Process()
            kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            kick.arguments = ["kickstart", "-k", "gui/\(getuid())/com.lingtai.mediacap"]
            kick.standardOutput = Pipe(); kick.standardError = Pipe()
            try? kick.run(); kick.waitUntilExit()

            // 框选可能等很久（用户还在拖），给 180 秒
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline, !FileManager.default.fileExists(atPath: res) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            }
            let r = (try? String(contentsOfFile: res, encoding: .utf8)) ?? "ERR 超时（mediacap 没回结果）"
            // 含窗口模式从没藏过，自然也不需要升回来（show() 会抢焦点，多余）
            if wasVisible && !keepPanel { show() }
            let line = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("OK ") {
                s = "✅ 已保存 " + String(line.dropFirst(3))
            } else if line == "CANCELLED" {
                s = "已取消（没有选区）"
            } else {
                s = "❌ " + line
            }
        } else if a.script.isEmpty {
            s = runMacctl(a.cmd)
        } else {
            s = runScript(a.script, a.scriptArgs)
        }
        // ⚠ 判据：这些脚本/macctl 成功时输出的是**含 ok:true 的 JSON 行**，
        //   失败是 ok:false + 原因。所以按 JSON 判，不要按「有没有输出」——
        //   后者会把「命令没执行」显示成「已完成」（D-020 的恒真 bug）。
        // ⚠ 空输出 = 命令没跑起来，必须算失败。原来按"有没有 ok:false"判，
        //   空串既不含 ok:false 也不含 ❌ → 界面显示"✅ 已截图"而文件根本没生成。
        let failed = s.contains("\"ok\":false") || s.contains("❌")
            || s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // 已降层但**没成功**：面板必须升回来，否则用户什么反馈都收不到，
        //   只能对着一个「什么都没发生」的桌面发呆。
        if failed {
            // 「安静失败」：不吼红字，只平静地说没成 + 一句原因，并落盘待复盘
            logFailure(action: a.title, input: "", reason: firstLine(s), code: "action")
        }
        if handsOver && failed {
            show()
            statusLabel.textColor = Palette.dim
            statusLabel.stringValue = "没成：\(a.title) · \(firstLine(s).prefix(56))"
            return
        }
        if failed {
            statusLabel.textColor = Palette.dim
            statusLabel.stringValue = "没成：\(firstLine(s).prefix(64))"
            return
        }
        // 成功且已让位：不再打扰 —— 目标 App 就在最上层，
        //   再弹回面板会把它重新挡住，那等于把问题又造了一遍。
        if handsOver { return }

        statusLabel.textColor = Palette.ok
        // ⚠ 截图/录屏必须回显真实落盘路径，否则用户还是不知道文件在哪
        if let p = mediaPathFrom(s) {
            statusLabel.stringValue = "✅ \(a.done) · \(p)"
        } else {
            statusLabel.stringValue = "✅ \(a.done)"
        }
    }

    func firstLine(_ s: String) -> String {
        s.split(separator: "\n").first.map(String.init) ?? s
    }

    // ── 唯一输入框：自动识别复杂度 ───────────────────────────

    @objc func submitFree(_ sender: Any?) {
        guard !busy else { return }
        let text = freeInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        statusLabel.textColor = Palette.dim
        statusLabel.stringValue = "识别中…"
        freeInput.isEnabled = false
        clearHandoff()

        DispatchQueue.global(qos: .userInitiated).async {
            let out = runScript("route.sh", [text])
            DispatchQueue.main.async {
                self.freeInput.isEnabled = true
                self.freeInput.stringValue = ""
                // 多候选：弹面板内的选择框，选完自动带名字重发（不用人回对话框）
                if out.contains("AMBIGUOUS") {
                    let names = self.parseCandidates(out)
                    let msg = self.jsonField(out, "msg") ?? text
                    self.busy = false
                    if names.count >= 2 {
                        self.pickRecipient(names, msg: msg, original: text)
                        return
                    }
                }
                let r = self.summarize(out)
                if let target = r.target {
                    let b64 = self.jsonField(out, "prompt_b64") ?? ""
                    let prompt = self.decodeB64(b64) ?? text
                    self.stageForTarget(prompt, target: target)
                    self.statusLabel.textColor = Palette.warn
                    self.statusLabel.stringValue = r.message
                    self.busy = false
                    return
                }
                if r.handoff {
                    // 工件B：复杂任务不再只「复制好等用户 ⌘V」，直接全自动转交。
                    // 失败时 performHandoff 自己会把面板收回来并提示手动路径。
                    self.stageForWorkBuddy(text)
                    self.performHandoff(text)
                    self.statusLabel.stringValue = r.message
                    self.busy = false
                    return
                } else {
                    // 「安静失败」：不吼红字；失败一定要落盘，等复盘时归类修掉
                    let good = r.message.hasPrefix("✅")
                    if !good {
                        logFailure(action: "输入", input: text,
                                   reason: r.message, code: "input")
                    }
                    self.statusLabel.textColor = good ? Palette.ok : Palette.dim
                }
                self.statusLabel.stringValue = r.message
                self.busy = false
            }
        }
    }

    /// 面板上要显示的一句话 + 是否需要转交。
    struct Reply {
        let message: String
        let handoff: Bool
        var target: String? = nil
    }

    /// 把route.sh 输出压成一行人话。
    /// ⚠ 不把 JSON 糊到界面上 —— 用户要的是结果，不是数据。
    ///
    /// ⚠ `need_confirm` 与「听不懂」都归为「这条闪控搞不定 → 转 WorkBuddy」。
    ///   理由：需要确认的任务全都是复杂任务，复杂任务属于 WorkBuddy，
    ///   闪控不做确认闸（见 setHandoff 上方注释）。
    func summarize(_ raw: String) -> Reply {
        let lines = raw.split(separator: "\n").map(String.init)
        let first = lines.first ?? ""
        if first.contains("\"need_confirm\":true") {
            return Reply(message: "⚠️ 这条要动到外部账号 → 转给 WorkBuddy", handoff: true)
        }
        // 需要「闪控这层做不到、但 agent 用视觉能做」的任务 → 直接转交
        if first.contains("NEED_HANDOFF") {
            return Reply(message: "这条要视觉操作 → 已转给 WorkBuddy", handoff: true)
        }
        if first.contains("AMBIGUOUS") {
            let names = parseCandidates(first)
            return Reply(message: "匹配到 \(names.count) 个联系人：\(names.prefix(3).joined(separator: "、"))\n—— 说全名，或点弹窗选",
                         handoff: false)
        }
        if first.contains("\"ok\":false") {
            // ⚠⚠ 必须区分「**没听懂**」和「**执行失败**」—— 两者都带 ELEMENT_NOT_FOUND，
            //   但处置完全相反：
            //     · 没听懂（未命中路由表）→ 这是**复杂任务**，转给 WorkBuddy
            //     · 执行失败（元素找不到/权限被拒）→ 这是**真故障**，
            //       转交只是把问题挪个地方，用户下次还会遇到同样的错
            //
            //   原来只要看到 ELEMENT_NOT_FOUND 就一律转交，于是「打开微信失败」
            //   也会显示成「这是复杂任务，闪控接不住」—— **诊断信息全丢**。
            if first.contains("ELEMENT_NOT_FOUND") {
                // W6：复杂任务先看 chain；豆包/天公不自动转 WorkBuddy
                let chain = jsonField(first, "chain") ?? ""
                let target = jsonField(first, "handoff_target") ?? ""
                if chain == "ambiguous" {
                    return Reply(message: "不确定：天公/豆包/WorkBuddy；已给选项 → 点 → 复制", handoff: false, target: "ambiguous")
                }
                if chain == "doubao" || chain == "tiangong" {
                    return Reply(message: "建议：\(target)；已优化提示词 → 点 → 打开并复制", handoff: false, target: chain)
                }
                // 「未命中路由表」是 route.sh 特有的文案，只有它才代表复杂任务
                if first.contains("未命中路由表") || first.contains("action\\\":\\\"route") {
                    return Reply(message: "这是复杂任务，闪控接不住 → 已复制，⌘V 或点 →", handoff: true)
                }
                // 其余 ELEMENT_NOT_FOUND = 执行过程中找不到目标元素 → 真故障
                if let ev = jsonField(first, "evidence") {
                    return Reply(message: "❌ " + ev, handoff: false)
                }
                return Reply(message: "❌ 执行失败（目标元素不存在）", handoff: false)
            }
            if first.contains("PERMISSION_DENIED") {
                return Reply(message: "❌ 权限被系统拒绝（去「系统设置 → 隐私与安全性」授权）", handoff: false)
            }
            // ⚠ 失败时 evidence 常常还是**动作名**（如"截图完成"），真正的原因在
            //   output 里（route.sh 把子命令输出原样塞进 output）。不读 output，
            //   界面就会显示"❌ 截图完成"——既说失败又说完成，用户完全无从下手。
            if let out = jsonField(first, "output"), !out.isEmpty {
                var msg = out.replacingOccurrences(of: "\n", with: " ")
                while msg.hasPrefix("❌") || msg.hasPrefix(" ") { msg.removeFirst() }
                if !msg.isEmpty { return Reply(message: "❌ " + msg.prefix(80), handoff: false) }
            }
            if let ev = jsonField(first, "evidence") {
                return Reply(message: "❌ " + ev, handoff: false)
            }
            return Reply(message: "❌ 执行失败 → 已复制，点 → 转给 WorkBuddy", handoff: true)
        }
        if first.contains("\"ok\":true") {
            if let ev = jsonField(first, "intent") { return Reply(message: "✅ " + ev, handoff: false) }
            return Reply(message: "✅ 已完成", handoff: false)
        }
        // ⚠⚠ 走到这里 = 首行既不是 ok:true 也不是 ok:false —— **不能报「完成」**。
        //
        //   原来这里写 `return Reply(message: lines.last ?? "完成", handoff: false)`，
        //   空输出时 lines.last 是 nil → 显示「完成」→ **假成功**。
        //   用户看到「完成」但事情根本没做 —— 这比报错更坏：
        //   报错会让人去查，假成功会让人以为系统坏了而放弃使用。
        //
        //   D-024 的教训：静默失败 + 假成功 = 故障被完全掩盖。
        //   现在按「不确定」处理：诚实说明 + 转交 WorkBuddy（原文已在剪贴板）。
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Reply(message: "❓ 闪控没拿到结果（脚本无输出）→ 已复制，点 → 转给 WorkBuddy", handoff: true)
        }
        // 有输出但首行不是 JSON：多半是脚本抛了错或格式变了。
        // 把原文尾巴露出来，让人能判断发生了什么，同时仍给一条转交路径。
        let tail = lines.last.map { "（" + $0.prefix(60) + "）" } ?? ""
        return Reply(message: "❓ 闪控看不懂这个结果\(tail) → 已复制，点 → 转给 WorkBuddy", handoff: true)
    }

    /// 解析 `"candidates":["甲","乙"]`（route 返回的多候选）
    func parseCandidates(_ line: String) -> [String] {
        guard let r = line.range(of: "\"candidates\":[") else { return [] }
        let rest = line[r.upperBound...]
        guard let e = rest.firstIndex(of: "]") else { return [] }
        return String(rest[rest.startIndex..<e])
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .filter { !$0.isEmpty }
    }

    /// 面板内的「发给谁」选择框（用户拍板：直接弹窗点选，不要让人回对话框）。
    /// 选完立刻带着选择重发同一句话 —— 用户只点一下，不用重打指令。
    func pickRecipient(_ names: [String], msg: String, original: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "发给哪一个？"
        a.informativeText = "「\(original.prefix(24))」\n匹配到 \(names.count) 个联系人，内容：「\(msg.prefix(30))」"
        for n in names.prefix(4) { a.addButton(withTitle: n) }
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let resp = a.runModal()
        let idx = resp.rawValue - 1000
        guard idx >= 0, idx < min(names.count, 4) else {
            statusLabel.stringValue = "已取消发送"
            return
        }
        let chosen = names[idx]
        freeInput.stringValue = "给\(chosen)发微信:\(msg)"
        submitFree(nil)
    }

    func jsonField(_ line: String, _ key: String) -> String? {
        let pat = "\"\(key)\":\""
        guard let r = line.range(of: pat) else { return nil }
        let rest = line[r.upperBound...]
        guard let e = rest.firstIndex(of: "\"") else { return nil }
        let v = String(rest[rest.startIndex..<e])
        return v.isEmpty ? nil : v
    }

    // ── 聚焦 / Esc ───────────────────────────────────────────

    func controlTextDidBeginEditing(_ obj: Notification) {
        fieldShell.needsDisplay = true
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        fieldShell.needsDisplay = true
    }

    func control(_ c: NSControl, textView: NSTextView?, doCommandBy selector: Selector) -> Bool {
        if selector == Selector(("undo:")) {
            if pendingHandoff != nil {
                undoHandoff()
                return true
            }
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if pendingHandoff != nil {
                undoHandoff()
            } else {
                hide()
            }
            return true
        }
        return false
    }
}

// MARK: - 布局自检
//
// ⚠⚠ 这是「排版超格」这个 bug 的**根治装置**，不是可有可无的调试代码。
//   v2~v4 的超格之所以能一路发布到用户面前，是因为**没有任何东西检查几何**：
//   窗口高度是手写常数，内容是累加的，两者不一致时没人会发现。
//   有了 --layout-check，任何「子视图跑出父视图」「控件跑出窗口」
//   「按钮文字放不下」都会在构建期直接红。
//
//   它是纯计算，不依赖运行中的 App 状态，可以在自检脚本里无条件跑。

/// 递归检查：每个子视图的 frame 必须完整落在父视图内。
func validateLayout(_ v: NSView, path: String, report: inout [String]) -> Bool {
    var ok = true
    let b = v.bounds
    for s in v.subviews {
        let name = "\(path)/\(type(of: s))"
        // 允许 0.75pt 容差：macOS 的半像素描边会让 insetBy(0.5) 差一点点
        let slack: CGFloat = 0.75
        if s.frame.minX < b.minX - slack || s.frame.minY < b.minY - slack
            || s.frame.maxX > b.maxX + slack || s.frame.maxY > b.maxY + slack {
            report.append("OUT_OF_BOUNDS \(name) frame=\(s.frame) parent=\(b)")
            ok = false
        }
        if let btn = s as? TileButton, !btn.title.isEmpty {
            let maxW = btn.bounds.width - 24
            let need = btn.fitAttributes(maxWidth: .greatestFiniteMagnitude).size().width
            if need > maxW {
                report.append("TEXT_OVERFLOW \(name) 「\(btn.title)」需要 \(Int(need))pt > 可用 \(Int(maxW))pt")
                ok = false
            }
        }
        if !validateLayout(s, path: name, report: &report) { ok = false }
    }
    return ok
}

func runLayoutCheck() -> Int {
    let p = Panel.shared.buildIfNeeded()
    guard let root = p.window.contentView else {
        print("LAYOUT_FAIL: 没有 contentView")
        return 1
    }
    var report: [String] = []
    let inside = validateLayout(root, path: "root", report: &report)

    // 窗口级检查：所有区块加起来必须正好等于窗口高（不能多也不能少）
    let stack = Layout.topInset + Layout.headerH + Layout.gap1 + Layout.gridH + Layout.gap2
              + Layout.inputH + Layout.gap3 + Layout.startH + Layout.gap3
              + Layout.statusH + Layout.bottom
    if abs(stack - Layout.H) > 0.01 {
        report.append("HEIGHT_MISMATCH 算式=\(stack) vs H=\(Layout.H)")
    }
    if Layout.statusY < Layout.bottom - 0.01 {
        report.append("STATUS_BELOW_BOTTOM statusY=\(Layout.statusY) bottom=\(Layout.bottom)")
    }
    // 网格必须"装得下且不溢出"（只数 grid 卡片里的，输入行的两个按钮不算）
    //
    // ⚠ 2026-10-24 放宽断言：原来是 tiles == cols*rows 的硬等式，13 个动作
    //   （末行通栏）会被判失败。但那个等式本来只是"防溢出"的手段，不是目的。
    //   现在的规则更贴近真实约束：
    //     ① 数量不能超过 cols*rows（超了才真会溢出，这才是要拦的）
    //     ② 末行只剩 1 个时，它必须通栏 —— 否则视觉上孤零零一格，正是"突兀"
    let gridCard = root.subviews.first { $0.identifier?.rawValue == "grid" }
    let tileViews = (gridCard?.subviews ?? []).compactMap { $0 as? TileButton }
    let tiles = tileViews.count
    if gridCard == nil {
        report.append("GRID_CARD_NOT_FOUND 网格卡片没打上 identifier=grid")
    } else if tiles > Layout.cols * Layout.rows {
        report.append("TILE_OVERFLOW 最多 \(Layout.cols * Layout.rows) 格，实际 \(tiles)")
    } else if let lowest = tileViews.map({ $0.frame.minY }).min() {
        /* 末行必须把整行宽度**用满**。
           ⚠ 2026-10-25 换掉了原来那条「只剩 1 格时必须通栏」：
             14 个动作时末行是 2 格，旧断言（只看 %3==1）直接放行 ——
             右侧那个一格宽的空洞就再也没人体检。
             现在按「末行所有格 + 间距 == 内容宽」验，1 格/2 格/3 格都管。 */
        let lastRow = tileViews.filter { abs($0.frame.minY - lowest) < 0.5 }
        let used = lastRow.reduce(CGFloat(0)) { $0 + $1.frame.width }
                 + CGFloat(max(lastRow.count - 1, 0)) * Layout.gap
        let want = Layout.mainW - Layout.cardPad * 2
        if abs(used - want) > 1 {
            report.append("LAST_ROW_NOT_FILLED 末行 \(lastRow.count) 格共 \(Int(used))pt，应为 \(Int(want))pt")
        }
    }

    if report.isEmpty && inside {
        print("LAYOUT_OK \(Int(Layout.W))x\(Int(Layout.H)) · \(Layout.cols)x\(Layout.rows) 网格 · \(tiles) 个按钮全部在框内、文字未溢出")
        return 0
    }
    print("LAYOUT_FAIL \(report.count) 处问题：")
    report.forEach { print("  ✗ \($0)") }
    return 1
}

/// 字体自检：把「用的是哪套字」变成可打印的事实。
///
/// 为什么不能只看截图：字体没注册时 uiFont 会**静默回退**到 Avenir Next，
/// 面板照样画得出来，截图上两者都是"没有衬线的字"，肉眼很难判。
/// 所以这里直接验证三件事：
///   ① 字体文件在不在、注册成不成功；
///   ② `NSFont(name:)` 能不能解析到 PS 名；
///   ③ 每个方块按钮在 12.5pt 下要多宽 —— 换字体最直接的后果就在这里。
func runFontCheck() -> Int {
    var bad = 0
    print("FONT_DIR \(BundledFonts.dir)")
    for f in BundledFonts.files {
        let registered = BundledFonts.ready.contains(f.ps)
        let resolved = NSFont(name: f.ps, size: 12)?.fontName ?? "nil"
        if !registered || resolved == "nil" { bad += 1 }
        print("  \(registered && resolved != "nil" ? "✅" : "❌") \(f.file).ttf → PS \(f.ps) → 解析 \(resolved)")
    }
    print("uiFont(12.5,.medium)   = \(uiFont(size: 12.5, weight: .medium).fontName)")
    print("uiFont(11,.semibold)   = \(uiFont(size: 11, weight: .semibold).fontName)")
    print("monoFont(9.5,.regular) = \(monoFont(size: 9.5, weight: .regular).fontName)")

    // 方块按钮的实测宽度：同一个"需求宽度"，三个字体横向对照
    let p = Panel.shared.buildIfNeeded()
    guard let root = p.window.contentView else {
        print("FONT_FAIL 没有 contentView")
        return 1
    }
    var tiles: [TileButton] = []
    func walk(_ v: NSView) {
        for s in v.subviews {
            if let b = s as? TileButton, !b.title.isEmpty, b.kind == .tile { tiles.append(b) }
            walk(s)
        }
    }
    walk(root)

    let inter = uiFont(size: 12.5, weight: .medium)
    let avenir = NSFont(name: "AvenirNext-DemiBold", size: 12.5)
        ?? NSFont.systemFont(ofSize: 12.5, weight: .medium)
    print("TILES \(tiles.count) 个（需求宽度 = 12.5pt 下的文字宽；可用 = 按钮宽 - 24）")
    for b in tiles {
        let avail = b.bounds.width - 24
        let wInter = (b.title as NSString).size(withAttributes: [.font: inter]).width
        let wAve = (b.title as NSString).size(withAttributes: [.font: avenir]).width
        let mark = wInter <= avail ? "OK " : "✗  "
        print(String(format: "  %@「%@」 Inter %5.1f / Avenir %5.1f / 可用 %5.1f  Δ%+.1f",
                     mark, b.title, wInter, wAve, avail, wInter - wAve))
        if wInter > avail { bad += 1 }
    }
    if bad == 0 {
        print("FONT_OK \(tiles.count) 个按钮在 Inter 12.5pt 下均未超出可用宽度")
    }

    // SELF-CHECK 栏：每行是「标签 …… 值」两段右左夹逼，行距是算出来的。
    // 换字体后行高没变，但**字变宽了**，所以这里只验横向会不会撞车：
    // 两段之间的空隙小于 6pt 就已经算不上"有空隙"，引导线也画不出来。
    let snap = Probe.collect()
    let rows = Probe.items(from: snap)
    p.selfCheck.items = rows
    let barW = p.selfCheck.bounds.width
    let labelF = monoFont(size: 9.5, weight: .regular)
    let valueF = monoFont(size: 9.5, weight: .medium)
    print("SELFCHECK \(rows.count) 行 · 栏宽 \(Int(barW))pt")
    for it in rows {
        let lw = (it.label as NSString).size(withAttributes: [.font: labelF]).width
        let vw = (it.value as NSString).size(withAttributes: [.font: valueF]).width
        let gap = (barW - 12 - vw) - (22 + lw)
        if gap < 6 { bad += 1 }
        print(String(format: "  %@ %@ … %@ 空隙 %5.1fpt", gap >= 6 ? "OK " : "✗  ",
                     it.label, it.value, gap))
    }

    if bad == 0 {
        print("FONT_OK \(tiles.count) 个按钮 + \(rows.count) 行自检均未溢出")
        return 0
    }
    print("FONT_FAIL \(bad) 处问题")
    return 1
}

// MARK: - 入口

func hotKeyFromArgs() -> (UInt32, UInt32) {
    var kc = DEFAULT_KEY
    var mods = DEFAULT_MODS
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        let a = args[i]
        if a == "--key", i + 1 < args.count, let v = Int(args[i + 1]) { kc = UInt32(v); i += 2 }
        else if a == "--keyname", i + 1 < args.count { if let v = namedKey(args[i+1]) { kc = v }; i += 2 }
        else if a == "--mods", i + 1 < args.count { if let v = namedMods(args[i+1]) { mods = v }; i += 2 }
        else { i += 1 }
    }
    return (kc, mods)
}

func namedKey(_ s: String) -> UInt32? {
    if let n = Int(s) { return UInt32(n) }
    switch s.lowercased() {
    case "space": return UInt32(kVK_Space)
    case "return", "enter": return UInt32(kVK_Return)
    case "a": return UInt32(kVK_ANSI_A)
    case "f5": return 96
    case "f12": return 111
    default: return nil
    }
}

func namedMods(_ s: String) -> UInt32? {
    var m: UInt32 = 0
    for p in s.lowercased().split(separator: "+") {
        switch p {
        case "ctrl", "control": m |= UInt32(controlKey)
        case "alt", "option", "opt": m |= UInt32(optionKey)
        case "shift": m |= UInt32(shiftKey)
        case "cmd", "command", "super": m |= UInt32(cmdKey)
        default: return nil
        }
    }
    return m == 0 ? nil : m
}

func printHelp() {
    print("""
闪控 · flash — 指令面板（v5）

用法：
  flash                     常驻监听 ⌃⌥Space，唤起面板
  flash --keyname f5 --mods ctrl+alt改热键组合
  flash --once              立刻显示一次面板后退出（验证用）
  flash --status            打印状态后退出
  flash --layout-check      几何自检：控件越界 / 文字溢出 / 区块高度不吻合
  flash --help              本帮助

队列管理（供脚本调用）：
  flash queue list       列出待确认项
  flash queue stat       队列统计（诊断卡住的问题）
  flash queue add --id X --title T --detail D --script S --risk R
  flash queue check --id X     查是否已被回答
  flash queue consume --id X   执行完清理

面板：
  · 12 个常用操作，点一下即执行（不打字、不选模式）
  · 唯一一个输入框：简单任务直接做，复杂任务自动转交 WorkBuddy
  · 截图 → 桌面/灵台智枢/截图/年/月/，录屏 → 桌面/灵台智枢/录屏/年/月/，文件名按年月日时分秒
""")
}

func runMain() {
    let argv = CommandLine.arguments
    if argv.contains("--help") || argv.contains("-h") { printHelp(); exit(0) }

    // ⚠ 字体必须**最先**注册：uiFont / monoFont 都查 BundledFonts.ready，
    //   晚一步注册，第一批控件就已经用系统字体画完了。
    BundledFonts.register()

    // ── 队列子命令（先于 UI 分支处理）──
    if let qi = argv.firstIndex(of: "queue"), qi + 1 < argv.count {
        let sub = argv[qi + 1]
        let a = Args(["flash"] + Array(argv.dropFirst(qi + 2)))
        switch sub {
        case "add": queueAdd(a)
        case "check": queueCheck(a)
        case "list": queueList(a)
        case "consume": queueConsume(a)
        case "stat": queueStat()
        default:
            print("未知队列子命令: \(sub)")
            exit(2)
        }
        exit(0)
    }

    // ── 工件B 自检：走**真实面板路径**（建面板 → show → 降层 → 转交）
    // ⚠ 与 --handoff 的区别：那个是 CLI 直调，置前只能到 T2/T3；
    //   这里和用户点「→」时一样，先拿到激活权再降层，链路才一致。
    if let i = argv.firstIndex(of: "--selftest-handoff") {
        let text = i + 1 < argv.count ? argv[i + 1] : "闪控自检 · 转交链路"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = Panel.shared
        panel.buildIfNeeded()
        panel.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        panel.performHandoff(text, skill: nil)   // 自检不挂技能（见 performHandoff 注释）
        print(panel.statusLabel.stringValue)
        exit(0)
    }

    // ── 工件B 转交链路（也是它唯一的可自动化测试入口）──────────
    // ⚠ 转交的每一步都是真按键、真 AX 点击，没法在单元测试里断言。
    //   所以必须有一个「在脚本里跑一遍真实链路」的入口，
    //   否则自检只能断言源码里有没有那几行字符串（恒真，等于没测）。
    //   --dry：粘贴后不发送，用来人工核对 + dump 结构。
    if let i = argv.firstIndex(of: "--handoff") {
        let text = i + 1 < argv.count ? argv[i + 1] : ""
        guard !text.isEmpty else { print("HANDOFF_FAIL 缺文本"); exit(2) }
        let dry = argv.contains("--dry")
        var skill: String? = nil
        if let si = argv.firstIndex(of: "--skill"), si + 1 < argv.count { skill = argv[si + 1] }
        let r = handoffToWorkBuddy(text, skill: skill, submit: !dry,
                                   dumpPath: "/tmp/handoff_tree.txt")
        print(r.json)
        exit(r.ok ? 0 : 1)
    }

    // ── B1 探针：dump 目标 App 的 AX 结构（定死转交链路的定位规则）──
    // ⚠ 探针和正式转交链路共用 flash_handoff.swift 里的同一套 helper，
    //   否则「探出来能找、跑起来找不到」，等于白探。
    if let i = argv.firstIndex(of: "--ax-probe") {
        let name = i + 1 < argv.count ? argv[i + 1] : "WorkBuddy"
        print(axProbeDump(name))
        exit(0)
    }

    // ── 无UI 自检：置前引擎走真实面板路径 ────────────────────
    //
    // ⚠ 为什么自检要起一个**真的窗口**：置前之所以在子进程里失败，
    //   根因是「非前台进程没有改变全局激活权的资格」。所以在无窗口的
    //   进程里跑 raiseAppInProcess 只能测到 T2（open -b），
    //   T1（进程内 activate）永远测不到 —— 那样自检就是假通过。
    //   这里按面板真实路径来：建面板 → show()（拿激活权）→ 降层 → 置前。
    //   用完 exit，窗口随进程消失，不留痕迹。
    if let i = argv.firstIndex(of: "--selftest-raise"), i + 1 < argv.count {
        let target = argv[i + 1]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = Panel.shared
        panel.buildIfNeeded()
        panel.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        panel.lowerPanelForApp()
        let r = raiseAppInProcess(target)
        print(r.json)
        exit(r.ok ? 0 : 1)
    }

    // ── 无UI 自检：验证「入队 → 确认 → 真的执行」全链路 ──────
    // ⚠ 这条链路曾经是断的（只删文件不执行），而断的时候没有任何报错。
    //   界面上的点按钮没法进 CI，所以必须有一个能在脚本里跑的验证入口。
    if argv.contains("--selftest-confirm") {
        let job = "/tmp/flash_selftest_job.sh"
        // ⚠ 生成脚本时用双引号包 JSON，不要用单引号 ——
        //   Swift 多行字符串里嵌单引号 bash 会被截断，脚本语法错误。
        let script = "#!/bin/bash\necho \"{\\\"ok\\\":true,\\\"action\\\":\\\"selftest\\\",\\\"evidence\\\":\\\"SELFTEST_EXECUTED\\\"}\"\n"
        try? script.write(toFile: job, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: job)

        let a = Args(["flash", "--id", "st_\(Int(Date().timeIntervalSince1970))",
                      "--script", job, "--args", "--x,--y"])
        queueAdd(a)
        let items = loadPending()
        guard let target = items.last else { print("SELFTEST_FAIL: 没能入队"); exit(1) }
        guard let taken = takePendingForTest(target.id) else { print("SELFTEST_FAIL: 取不出任务"); exit(1) }
        answer(target.id, approve: true)
        let out = runScript(taken.script, taken.args + ["--confirmed"])
        try? FileManager.default.removeItem(atPath: job)
        if out.contains("SELFTEST_EXECUTED") {
            print("SELFTEST_PASS: 确认后确实执行了（参数 \(taken.args.joined(separator: ","))）")
            exit(0)
        } else {
            print("SELFTEST_FAIL: 确认后没有执行，输出=[\(out)]")
            exit(1)
        }
    }

    // ── 几何自检（不需要显示窗口，自检脚本会跑）─────────────
    if argv.contains("--layout-check") {
        exit(Int32(runLayoutCheck()))
    }

    // ── 字体自检：证明「换的字确实生效了」，而不是静默退回系统字体 ──
    //   为什么需要单独一条：字体缺失时面板照样能画出来（走回退），
    //   光看截图分不清"Inter"和"回退后的 Avenir" —— 这条会把
    //   目录、注册结果、实际解析到的 PS 名全部打出来。
    if argv.contains("--font-check") {
        exit(Int32(runFontCheck()))
    }

    // ── 面板出图（视觉核对用）──────────────────────────────
    //⚠ 为什么需要它：几何自检只能证明「没有越界」，
    //   证明不了「好不好看」。线框地球这种纯绘制的东西，
    //   纬线间距、背面透明度、自转标记点位置，
    //   全部要**用眼睛看**才知道对不对 ——
    //   数值断言只能证明它在画，不能证明画出来是地球。
    //
    //   用法：flash --snapshot [路径] [--phase <角度>]
    if argv.contains("--snapshot") {
        let outPath: String
        if let i = argv.firstIndex(of: "--snapshot"), i + 1 < argv.count,
           !argv[i + 1].hasPrefix("--") {
            outPath = argv[i + 1]
        } else {
            outPath = NSTemporaryDirectory() + "flash-panel.png"
        }
        var phase: CGFloat = 28     // 默认给一个能看到明显自转的相位
        if let i = argv.firstIndex(of: "--phase"), i + 1 < argv.count,
           let v = Double(argv[i + 1]) { phase = CGFloat(v) }
        /// 只出地球那一个区块（放大看细节用）。
        /// ⚠ 为什么需要：整图出图时地球只有 96pt，
        ///   纬线疏密、极点毛刺、光晕强弱在那个尺寸下根本看不清 ——
        ///   而这几个恰恰是「像不像地球」的全部依据。
        ///   只出这一块可以放大到 4 倍看，一眼就能判断。
        let globeOnly = argv.contains("--globe-only")
        /// 放大倍数（配合 --globe-only）
        var zoom: CGFloat = 4
        if let i = argv.firstIndex(of: "--zoom"), i + 1 < argv.count,
           let v = Double(argv[i + 1]) { zoom = CGFloat(v) }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = Panel.shared
        panel.buildIfNeeded()
        panel.globe.phase = phase
        panel.globe.needsDisplay = true

        /* 快照模式把探针同步跑一遍。
           异步那条路是给运行时用的，出图时它还没回来 ——
           截出来永远是一张空表，看不出自检栏到底排得对不对。
           只影响 --snapshot 这条调试路径，运行时行为不变。 */
        if !globeOnly {
            let snap = Probe.collect()
            let items = Probe.items(from: snap)
            panel.selfCheck.items = items
            panel.selfCheck.summary = snap.panelSummary.isEmpty ? "\(items.filter { $0.ok }.count)/\(items.count) CHECKS PASSED" : snap.panelSummary
            panel.selfCheck.needsDisplay = true
        }

        let target: NSView
        if globeOnly {
            // ⚠⚠ 放大必须**按倍数重画**，不能拉伸位图、也不能缩放图层。
            //   位图拉伸会把 0.9pt 的线糊成 3.6pt 的粗线 ——
            //   而这里要看的恰恰就是「线有多细」，糊了就完全失去意义。
            //   CATransform3D 缩放也试过：坐标系对不上，内容跑到角落。
            //   最稳的做法是换一个更大的 GlobeView 重画一遍（GlobeInspector），
            //   线宽按倍数反向缩小，放大后看起来与实际面板一致。
            let g = panel.globe!
            target = NSView(frame: NSRect(x: 0, y: 0,
                                           width: g.bounds.width * zoom,
                                           height: g.bounds.height * zoom))
            let insp = GlobeInspector(frame: target.bounds, zoom: zoom)
            insp.phase = phase
            target.addSubview(insp)
        } else {
            panel.globe.phase = phase
            panel.globe.needsDisplay = true
            guard let cv = panel.window.contentView else {
                FileHandle.standardError.write("snapshot: 没有 contentView\n".data(using: .utf8)!)
                exit(2)
            }
            target = cv
        }

        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            FileHandle.standardError.write("snapshot: 无法创建 bitmap\n".data(using: .utf8)!)
            exit(2)
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("snapshot: PNG 编码失败\n".data(using: .utf8)!)
            exit(2)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outPath))
            print("SNAPSHOT_OK \(outPath) \(Int(target.bounds.width))x\(Int(target.bounds.height)) phase=\(phase)")
            exit(0)
        } catch {
            FileHandle.standardError.write("snapshot: 写文件失败 \(error.localizedDescription)\n"
                .data(using: .utf8)!)
            exit(2)
        }
    }

    /* ── 地球拖拽自检（--globe-drag-test）─────────────────────────────
       直接调用 mouseDown/Dragged/Up 三个入口，跑一遍**真实的事件处理路径**，
       再把前后的位图逐字节比对。
       为什么不用肉眼验收：拖拽失效的典型症状是"画面还在转"——
       因为自转定时器一直在推进，用户以为拖拽生效了，其实没有。
       只有"拖完之后的画面与拖之前不同，且不是自转那一格"才证明拖拽进了事件。
       这里断言的是：拖完之后 dragLon 确实变了（通过图像差异体现）。 */
    if argv.contains("--globe-drag-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let side: CGFloat = 220
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        let g = GlobeView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        g.zoom = 1
        win.contentView = g
        win.orderFrontRegardless()

        func shot() -> Data {
            guard let rep = g.bitmapImageRepForCachingDisplay(in: g.bounds) else { return Data() }
            g.cacheDisplay(in: g.bounds, to: rep)
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }
        func ev(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: win.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        let before = shot()
        g.mouseDown(with: ev(.leftMouseDown, side / 2, side / 2))
        for k in 1...6 {
            g.mouseDragged(with: ev(.leftMouseDragged, side / 2 + CGFloat(k) * 10, side / 2))
        }
        g.mouseUp(with: ev(.leftMouseUp, side / 2 + 60, side / 2))
        let after = shot()
        if before == after || before.isEmpty {
            print("DRAG_FAIL 画面未变 —— 拖拽没有进入事件路径")
            exit(1)
        }
        print("DRAG_OK 拖拽改变了画面（\(before.count) → \(after.count) bytes）")
        exit(0)
    }

    let (kc, mods) = hotKeyFromArgs()
    let keyName = (kc == DEFAULT_KEY && mods == DEFAULT_MODS) ? "⌃⌥Space" : "自定义(键码 \(kc))"
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // ⚠⚠ 这两行是「热键时好时坏」的另一个真凶：常驻的辅助类 app 在**闲置**时
    //   会被系统的自动终止 / 突然终止机制回收（没有窗口、没有前台活动）。
    //   实测：启动一分多钟后进程凭空消失、没有崩溃报告、pgrep 找不到，
    //   用户按热键当然毫无反应。禁掉这两个机制后进程才能长期活着。
    ProcessInfo.processInfo.disableAutomaticTermination("常驻热键监听")
    ProcessInfo.processInfo.disableSuddenTermination()

    if argv.contains("--status") {
        print("flash v5 · 状态检查")
        print("  脚本目录: \(scriptsDir())")
        print("  目标热键: \(keyName)")
        let ok = registerHotKey(keyCode: kc, mods: mods)
        print("  Carbon 注册: \(ok ? "✅ 可用" : "❌ 失败（被其他 App 占用）")")
        if ok { UnregisterEventHotKey(gHotKey!) }
        // 没 AX 授权时**不要装事件监听**：CGEvent.tapCreate 失败会让 macOS 弹
        // 「灵台智枢 想使用辅助功能」——每次启动都弹，纯骚扰（2026-10-25 用户报）。
        let tapOK = AXIsProcessTrusted() ? installKeyTap(keyCode: kc, mods: mods) : false
        print("  事件监听: \(tapOK ? "✅ 可用（合成按键也认）" : "❌ 不可用（缺辅助功能授权？）")")
        if let st = try? String(contentsOfFile: "/tmp/flash.hotkey", encoding: .utf8) {
            print("  运行中实例: \(st.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            print("  运行中实例: ❌ 没有常驻进程在跑（自启未注册）")
        }
        for f in ["macctl", "route.sh", "screen_rec.sh"] {
            let p = scriptsDir() + "/" + f
            print("  \(f): \(FileManager.default.isReadableFile(atPath: p) ? "✅" : "❌ 缺失")")
        }
        print("  辅助功能: \(AXIsProcessTrusted() ? "✅ 已授权" : "❌ 未授权（面板打字/鼠标会静默失效）")")
        // 录屏授权（P13）：截图不需要授权，但 `screencapture -v` 必须有这一项。
        //   只读不申请 —— 想修就跑 `flashctl.sh rec`（或桌面「修复屏幕录制授权.command」）。
        print("  屏幕录制: \(CGPreflightScreenCaptureAccess() ? "✅ 已授权（录屏可用）" : "❌ 未授权（录屏会失败；跑 flashctl.sh rec 修）")")
        print("  队列目录: \(queueDir())")
        print("  待确认项: \(loadPending().count)")
        print("  媒体目录: \(Palette.mediaDir)")
        exit(ok ? 0 : 1)
    }

    // ── 面板焦点探针：回答「热键唤起后，键盘到底落在谁身上」 ──────
    // 用户报「按热键没反应」时，有两种完全不同的故障：窗口没出现，
    // 或者窗口出现了但没拿到 key（打字全打到底下的 App 里）。
    if argv.contains("--panel-probe") {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = Panel.shared
        panel.buildIfNeeded()
        panel.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let w = panel.window
            print("visible=\(w?.isVisible ?? false) key=\(w?.isKeyWindow ?? false) "
                  + "main=\(w?.isMainWindow ?? false) active=\(NSApp.isActive) "
                  + "level=\(w?.level.rawValue ?? -1) frame=\(w?.frame ?? .zero)")
            let fr = w?.firstResponder
            print("firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil")")
            if let tf = panel.freeInput {
                print("field=[\(tf.stringValue)] editable=\(tf.isEditable) "
                      + "bezel=\(tf.window != nil)")
            }
            exit(0)
        }
        app.run()
        exit(0)
    }

    if argv.contains("--once") {
        DispatchQueue.main.async { Panel.shared.show() }
        app.run()
        exit(0)
    }

    installHandler()
    // ⚠ 哨兵必须常驻：面板关着时也要能提示有待确认项
    MenuBarSentinel.shared.install()
    MenuBarSentinel.shared.onClick = { Panel.shared.show() }
    // ── 辅助功能授权：**绝对不要自动弹系统授权框** ──────────────────
    // ⚠⚠ 这里曾经调 AXIsProcessTrustedWithOptions(prompt: true)，结果用户每次
    //   启动都被「"flash" 想使用辅助功能来控制这台电脑」糊一脸 —— 而他明明
    //   已经授权过。根因是 ad-hoc 签名：每次重编译 cdhash 都变，TCC 授权
    //   跟着作废 → AXIsProcessTrusted() 恒为 false → 每次都弹。
    //   弹窗解决不了这个问题，只会制造骚扰。所以：
    //     · 默认**静默**——授权缺失只降级（事件监听装不上），不打扰用户；
    //     · 需要授权时由人主动触发：`flashctl.sh ax`（显式要求才弹一次）；
    //     · 想固化授权：`flashctl.sh sign`（用自签证书签名，重编译不作废）。
    if ProcessInfo.processInfo.environment["SHANKONG_AX_PROMPT"] == "1", !AXIsProcessTrusted() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    // ── 屏幕录制授权：**同样绝不自动弹**，只在显式要求时申请一次 ──────
    // ⚠ 背景：截图已彻底免授权（走 launchd 的 mediacap，ERR-0022），但
    //   `screencapture -v`（录屏）从 launchd 会被拒（capture error「这项操作无法完成」）
    //   → 视频**必须**有一次「屏幕录制」勾选。这一步做成一键：`flashctl.sh rec`
    //   （桌面「修复屏幕录制授权.command」也调它）给 LaunchAgent 临时注入
    //   LINGTAI_REC_PROMPT=1 → 由 **launchd 拉起**本进程申请一次 → 用户勾 → 撤变量。
    //   TCC 记的才是「灵台智枢.app」而不是终端。
    // ⚠ 平时（变量不存在）**一行都不许执行** —— 自动弹窗已经被投诉过（ERR-0023）。
    //   已授权时也不申请：CGRequestScreenCaptureAccess 在已授权时虽会静默返回 true，
    //   但"不执行"比"执行了刚好没弹"更容易审计，所以先 preflight 再决定。
    if ProcessInfo.processInfo.environment["LINGTAI_REC_PROMPT"] == "1",
       !CGPreflightScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()   // 只在显式要求时弹一次
    }

    // ── 单实例锁 ────────────────────────────────────────────────
    // ⚠ 现在有两条自启路径（LaunchAgent + 登录项），可能同时拉起两个实例。
    //   全局热键是独占的：第二个实例注册会失败，然后它会去抢状态文件、
    //   干扰诊断，用户看到的就是"有时灵有时不灵"。所以第二个必须直接退出。
    let lockPath = "/tmp/flash.instance"
    if let s = try? String(contentsOfFile: lockPath, encoding: .utf8),
       let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
       pid != getpid(), kill(pid, 0) == 0 {
        print("闪控已在运行（pid \(pid)），本实例退出")
        exit(0)
    }
    try? "\(getpid())".write(toFile: lockPath, atomically: true, encoding: .utf8)

    // ── 把自己注册成「登录项」（macOS 13+ 的 SMAppService）──────────
    // ⚠ 这是「用户不需要手动启动」的正解：LaunchAgent 的 bootstrap 在受限
    //   环境里会被拦（I/O error），而 app 自己调 SMAppService.register()
    //   走的是系统登录项机制，登录时由 launchd 直接拉起，不依赖任何终端命令。
    //   ⚠ 只对 /Applications 下的 app 生效（Apple 的硬性要求），
    //   所以 flashctl.sh 会先把 app 复制到 /Applications 再启动。
    // ⚠ 2026-10-25 改：默认**不再**自我注册为登录项。
    //   原因：开机顺序由 bootanim/run-at-login.sh 接管（动画先播，再依次拉起面板/
    //   DSH/Cherry）。面板若把自己塞回登录项，就会和动画并行启动，
    //   "动画是全机第一个东西"这条就不再成立。
    //   想恢复旧行为：`touch ~/.tiangong/flash.loginItem`。
    let allowSelfLoginItem = FileManager.default.fileExists(
        atPath: NSHomeDirectory() + "/.tiangong/flash.loginItem")
    if allowSelfLoginItem, Bundle.main.bundlePath.hasPrefix("/Applications/") {
        if #available(macOS 13.0, *) {
            let svc = SMAppService.mainApp
            if svc.status != .enabled {
                do { try svc.register(); print("已注册为登录项（开机自动运行）") }
                catch { print("登录项注册失败：\(error.localizedDescription)（不影响本次运行）") }
            }
        }
    }

    /* 2026-10-25 晚：**这段已经被删掉了，别再写回来。**
       我曾在这里加"缺 AX 就 prompt:true 申请一次"，本意是帮用户重建 TCC 绑定，
       实际效果是：用户明明已经授权，面板因为 cdhash 变了仍认为没授权 →
       **每次启动都弹一次「灵台智枢想使用辅助功能」**，一天弹十几次，纯骚扰。

       结论：**授权缺失只能静默降级，绝不能自动弹框。**
       真要授权，由人显式触发：`flashctl.sh ax`（只在那一刻弹一次）。
       想根治重签丢失授权：证书已设为受信任，指定要求是 identifier+certificate root。
    */

    gStateEnabled = true      // 从这一行起才算"常驻实例"，才写状态文件
    // kc==0 是纯修饰键模式：Carbon 注册不了"没有字母键"的组合，直接跳过
    let carbonOK = (kc == 0) ? false : registerHotKey(keyCode: kc, mods: mods)
    // 同上：缺授权时不装 tap，避免系统弹框。Carbon 热键不受影响，面板照样能唤起。
    let tapOK = AXIsProcessTrusted() ? installKeyTap(keyCode: kc, mods: mods) : false
    writeHotKeyState(note: "start")
    // 两条都失败才算真失败：Carbon 只认物理按键，tap 认合成事件，互补
    if !carbonOK && !tapOK && kc != 0 {
        let msg = "闪控无法注册热键 \(keyName)，可能被其他 App 占用。\n换个组合：flash --keyname f5 --mods ctrl+alt"
        let w = NSTextField(wrappingLabelWithString: msg)
        w.frame = NSRect(x: 0, y: 0, width: 420, height: 60)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "闪控 · 启动失败"
        p.contentView = w
        p.center()
        p.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
        exit(1)
    }

    print("闪控 v5 已就绪—— 按 \(keyName) 唤起面板（mode=\(kc == 0 ? "纯修饰键" : "键+修饰键") carbon=\(carbonOK ? 1 : 0) tap=\(tapOK ? 1 : 0)）")

    // 预热面板（见 Panel.warmUp 注释）：让第一次热键也不会吞掉开头的字
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Panel.shared.warmUp() }
    fflush(stdout)
    app.run()
}

runMain()