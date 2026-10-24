// wblaunch.swift — WorkBuddy 开场动画启动器（macOS 原生壳）
//
// ── 为什么要有这个壳 ──────────────────────────────────────────────────────
// WorkBuddy 是 Electron 应用，但没有插件宿主（DSH 那种 cordis 注入）。
// 想让它播动画，只有三条路：
//   ① 改 app.asar 往 index.html 里注入脚本 → 破坏 Tencent 的 Developer ID 签名
//      （hardened runtime 打开着），而且每次自动更新都被覆盖回去。✗
//   ② 做成 WorkBuddy 插件 → 没有插件系统，无解。✗
//   ③ **独立启动器**：自己开一个无边框全屏 WKWebView 播动画，播完再 open WorkBuddy。
//      签名零影响、更新免疫、可独立迭代。✓ 本文件就是第 ③ 条。
//
// ── 播放时机（用户拍板的口径）──────────────────────────────────────────
//   播：① 开机自启动时  ② 闪控启动 WorkBuddy 且 WorkBuddy 此前**没在运行**
//   不播：③ 闪控识别复杂任务跳转、WorkBuddy 已在运行  ④ 用户手动双击直接打开
//   「手动双击不播 / 开机自启要播」是唯一能实现的组合：手动双击走 LaunchServices，
//   从外部拦不住；开机自启走 LaunchAgent，可以在 launchd 侧接管。
//
// ── 用法 ──────────────────────────────────────────────────────────────────
//   wblaunch play              播动画，然后拉起 WorkBuddy（拉起前再查一次是否已在跑）
//   wblaunch play --no-launch  只播动画，不拉起（调试用）
//   wblaunch play --force      强制播一次，跳过"已在运行"判定（**仅供自检**）
//   wblaunch probe             只打印判断结果与注入配置，不开窗（给自检用）
//   wblaunch --emit-config     输出注入用的 __WB_BOOT_CONFIG__ JSON（给预览页复用）
// 环境变量：
//   WB_LAUNCH_REASON   启动原因，写进 facts.reason（boot / flash / manual）
//   WB_LAUNCH_DEBUG=1 往 stderr 打窗口与判定日志
import AppKit
import WebKit

let FM = FileManager.default

// ── 资源定位：web/ 目录跟着二进制走（脚本目录内），不依赖 cwd ────────────────
func scriptDir() -> String {
    let p = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return p.deletingLastPathComponent().path
}

/// ⚠ 必须做URL 规范化，不能直接拼 ".."。
/// WKWebView 的 loadFileURL 对**含 `..` 的 file URL 会静默拒绝加载** ——
/// 不抛错、不触发 didFail、导航委托一个回调都不来。
/// 而脚本目录（scripts/bootanim/tools）到 web/ 天然要往上走一级，
/// 所以这个坑几乎必然踩到。症状：窗口弹出来了但永远是黑的，
/// 而所有"加载失败"的信号（didFail / KVO / console）全部沉默。
func webDir() -> String {
    return URL(fileURLWithPath: scriptDir() + "/../web")
        .standardizedFileURL.resolvingSymlinksInPath().path
}

// ⚠ 路径与 bundle id 允许用环境变量覆盖 —— 只为自检。
//   真实路径硬编码是安全的，但这样就**没法在不关掉正在跑的 WorkBuddy 的前提下**
//   验证「未运行 → 播动画」这条路径（那正是最需要被测的一条）。
let WB_APP = ProcessInfo.processInfo.environment["WB_APP_PATH"] ?? "/Applications/WorkBuddy.app"
let WB_BUNDLE = ProcessInfo.processInfo.environment["WB_BUNDLE_ID"] ?? "com.tencent.workbuddy.mac"

// ── WorkBuddy 是否已在运行 ────────────────────────────────────────────────
// 只用 LaunchServices 判定，不做 pgrep 兜底。
// 理由：Electron 的辅助进程名不固定（Helper Renderer / GPU Process），
// pgrep 既会漏（可执行名不等于 bundle 名）也会误判（刚退出时残留 1-2 秒）；
// 而 NSRunningApplication 走的是 LaunchServices 数据库，与 Dock/访达看到的是同一份事实。
// 拿不到 bundle id 时就返回 false —— 代价是多播一次动画（用户可点击跳过），
// 比"该播不播"要好得多。
func isWorkBuddyRunning() -> Bool {
    return !NSRunningApplication.runningApplications(withBundleIdentifier: WB_BUNDLE).isEmpty
}

// ── 注入配置 ──────────────────────────────────────────────────────────────
func versionString() -> String {
    let p = WB_APP + "/Contents/Info.plist"
    guard let d = FM.contents(atPath: p),
          let plist = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil),
          let dict = plist as? [String: Any] else { return "" }
    let short = (dict["CFBundleShortVersionString"] as? String) ?? ""
    let build = (dict["CFBundleVersion"] as? String) ?? ""
    if short.isEmpty { return build }
    return build.isEmpty ? short : "\(short)·\(build)"
}

func makeConfig(reason: String) -> [String: Any] {
    var facts: [String: Any] = [:]
    facts["ready"] = true
    facts["profile"] = "MacOS"
    facts["version"] = versionString()
    facts["model"] = "APPLE SILICON"
    facts["sandbox"] = "LOCAL"
    facts["plugins"] = 4
    facts["bundleCount"] = 12
    facts["workspace"] = "mac-control"
    // 光场构图用这个 seed —— 同一台机器、同一份 facts，每次启动的背景完全一致
    facts["hash"] = "wb-" + (versionString().isEmpty ? "dev" : versionString())
    // 启动原因写进 facts：调试时一眼看出这次是开机自启还是闪控拉起
    facts["reason"] = reason

    var cfg: [String: Any] = [
        "enabled": true,
        "mode": "always",
        "theme": "dark",              // 深色底 + 青绿，与标识同色系
        "speed": 1.0,
        "requireInteraction": false,  // 旧的"步骤内确认按钮"已由场景闸门统一接管（见 splash.js gateScene）
        // ⚠⚠ 2026-10-22 用户拍板：每个场景之间等 Space/Enter，3 秒无交互自动继续。
        //   splash.js 侧的字段名必须与这里一致（sceneGate / gateTimeoutMs）。
        "sceneGate": true,
        "gateTimeoutMs": gateTimeoutMs(),
        "allowSkip": true,            // 但允许点击/按键跳过
        "sound": ProcessInfo.processInfo.environment["WB_LAUNCH_MUTE"] == nil,  // WebAudio 现场合成，零素材依赖；WB_LAUNCH_MUTE=1 静音（自检用）
        "soundVolume": 0.45,
        "voice": true,                // 人声素材已换成 macOS 版录音（line-1..6），开机播报要能听到；WB_LAUNCH_MUTE=1 可静音
        "voiceLang": "en",
        "identity": "温昼",
        "identityId": "LS-WZ-0961-01",
        "accessLevel": "3",
        "brand1": "MacOS",
        "brand2": "BUILT ON APPLE SILICON",
        "brand3a": "SYSTEM",
        "brand3b": "ASSISTANT",
        "orgZh": "方寸山矩阵终端",
        "orgEn": "MacOS",
        "orgSub": "APPLE SYSTEM ASSISTANT",
        "welcomeBox": "MacOS",
        "footer": "DESIGNED BY APPLE IN CALIFORNIA",
        "facts": facts
    ]

    /* 闪控面板「启动动画」里改的几项存在 bootanim.config.json，这里最后合进来。
       ⚠ 只认白名单键：这个文件是给人手改的，写错一个键名不该把整份配置带偏；
         品牌文案不进白名单 —— 它属于"设计"，不属于"设置"。 */
    // ⚠⚠ 环境变量必须**压过**用户配置：自检用 WB_LAUNCH_GATE_MS 把场景"按住"
    //   （比如 8000ms）才拍得到画面。而 bootanim.config.json 里写着 6000，
    //   原来无条件覆盖，于是自检传的环境变量永远不生效 —— 闸门测了等于白测。
    let envGateOverride = ProcessInfo.processInfo.environment["WB_LAUNCH_GATE_MS"] != nil
    let envMute = ProcessInfo.processInfo.environment["WB_LAUNCH_MUTE"] != nil
    for (k, v) in userBootConfig() {
        guard BOOT_TUNABLE.contains(k) else { continue }
        if k == "gateTimeoutMs" && envGateOverride { continue }
        if (k == "sound" || k == "voice") && envMute { continue }
        cfg[k] = v
    }
    return cfg
}

/// 允许从 bootanim.config.json 覆盖的键（其余一律忽略）
let BOOT_TUNABLE: Set<String> = [
    "identity", "identityId", "accessLevel",
    "theme", "speed", "sceneGate", "gateTimeoutMs", "allowSkip",
    "sound", "soundVolume", "voice"
]

/// 读 ~/.workbuddy/skills/mac-control/scripts/bootanim/bootanim.config.json
/// 文件不在就返回空字典 —— 启动动画必须能在"没有配置文件"的机器上照常播。
func userBootConfig() -> [String: Any] {
    let p = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()      // tools/
        .deletingLastPathComponent()      // bootanim/
        .appendingPathComponent("bootanim.config.json").path
    guard let d = FileManager.default.contents(atPath: p),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    else { return [:] }
    return o
}

func jsonOf(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

/// 场景闸门超时（毫秒）。默认 6000；WB_LAUNCH_GATE_MS 可覆盖 ——
/// 2026-10-23 用户拍板从 3 秒改 6 秒：3 秒不够看完一个场景的编排，
/// 常常还没读完整行字就被推走了。自检仍可传更大的值把场景"按住"。
func gateTimeoutMs() -> Int {
    if let s = ProcessInfo.processInfo.environment["WB_LAUNCH_GATE_MS"],
       let v = Int(s), v >= 500, v <= 30000 { return v }
    /* ⚠ 5333 不是随手取的：配乐 90 BPM，两小节 = 5333.3ms。
       闸门取这个值，每一幕切换都落在小节线上。
       改这个数之前先确认 bgm.m4a 的 BPM —— 两者必须配套。 */
    return 5333
}

// ── 窗口 ──────────────────────────────────────────────────────────────────
/// .borderless NSWindow 默认 canBecomeKey=false，且命令行二进制的
/// NSApp.activate 是空操作（2026-10-22 实测 active=false，Space/Enter
/// 闸门收不到键事件，交互全失效）。解法是 NSPanel + .nonactivatingPanel：
/// 非激活面板**允许 app 非前台时成为 key window**（输入法候选窗同款机制），
/// 键事件直接路由进 WebView —— 不需要 activate，不闪 Dock 图标。
final class KeyWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Splash: NSObject, WKNavigationDelegate {
    var web: WKWebView
    var win: KeyWindow
    var fullFrame: NSRect   // 目标屏整幅 frame（全屏钉死用，见 show()）
    var onDone: (() -> Void)?
    var gateLogTimer: Timer?
    var lastGateCount = -1
    var fired = false

    init(screen: NSScreen, configJSON: String) {
        let cfg = WKWebViewConfiguration()
        /* 2026-10-25 试过加 allowUniversalAccessFromFileURLs：macOS 15 上
           该 key 不存在，setValue 直接抛 NSUnknownKeyException 让进程崩溃。
           已回滚。白屏问题仍未解决，见知识库 ERR-0013。
           注意：allowFileAccessFromFileURLs 本来就已设置（见下），不是缺它。 */
        // ⚠ 注入必须 atDocumentStart：splash.js 是同步 IIFE，
        //   等 didStart 再注入就晚了，配置会被静默忽略并退回 DEFAULTS
        //   （DEFAULTS.requireInteraction=true → 动画卡在第 1 步等按键，永不揭幕）。
        cfg.userContentController.addUserScript(WKUserScript(source: """
        (function () {
          try {
            window.__WB_BOOT_CONFIG__ = \(configJSON);
            window.__WB_BOOT_VERSION__ = '1';
            window.__WB_DONE__ = 0;
            document.addEventListener('dsh-startup:done', function () { window.__WB_DONE__ = 1; });
          } catch (e) {}
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // ⚠ 2026-10-22 移除：原来这里注入一段「任意点击/按键 → skip()」的脚本。
        //   用户拍板的交互模型是「Space/Enter 进下一幕、3 秒自动继续」——
        //   任意键跳过和它**直接冲突**（按一下空格会把整场动画掐掉）。
        //   跳过只保留 Esc 与 SKIP 按钮两条路，两者都在 splash.js 内部绑定
        //   （C.allowSkip 分支），不需要外层注入。
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        /* ⚠⚠ 放开自动播放 —— 这是"开机动画没有声音"的根因。
           WKWebView 默认 mediaTypesRequiringUserActionForPlayback = [.audio]，
           意思是"没有用户手势就不许出声"。而开机动画是**无人值守**自动播的：
           没有人点过这个窗口，于是 WebAudio 的 AudioContext 一直停在 suspended，
           `src.start()` 不报错、也不出声 —— 日志干净，现场就是没声音。
           给空集合 = 允许自动播放。 */
        cfg.mediaTypesRequiringUserActionForPlayback = []

        // ⚠⚠ 2026-10-22 用户拍板：动画**默认全屏**（WorkBuddy 自己不需要全屏）。
        //   早期版本是「可见区域的 92%×86%」—— 菜单栏与四边桌面露在外面，
        //   层级还是 .floating（压不住菜单栏），观感是「贴在桌上的网页」
        //   而不是开机动画。现在：整幅 screen.frame + .screenSaver 层级。
        let fr = screen.frame
        web = WKWebView(frame: fr, configuration: cfg)
        /* ── 让 Safari 的 Web Inspector 能连进来 ────────────────────────
           macOS 13.3+ 才有 isInspectable。默认关（生产环境不该带调试口），
           WB_LAUNCH_INSPECT=1 或 WB_LAUNCH_DEBUG=1 时打开。
           打开后：Safari → 开发 → 选「wblaunch」→ 就能看 Timeline / 帧时序，
           这是唯一能量出"合成器到底掉没掉帧"的手段。 */
        if #available(macOS 13.3, *) {
            let env = ProcessInfo.processInfo.environment
            if env["WB_LAUNCH_INSPECT"] != nil || env["WB_LAUNCH_DEBUG"] != nil {
                web.isInspectable = true
            }
        }
        win = KeyWindow(contentRect: fr, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        fullFrame = fr
        super.init()
        web.navigationDelegate = self
        /* ⚠⚠⚠ 白屏真因（2026-10-25 01:10 终于定位对）：
           `win.contentView = web` 意味着 **WebView 自己就是内容视图**。
           WKWebView 在首绘之前会绘制**自身底色（白）**，此时窗口底色
           （win.backgroundColor）根本露不出来 —— 所以上一版改窗口底色无效，
           用户重启后照样"闪一下白"。
           正确做法：窗口内容换成一个**近黑容器**，WebView 以 alpha=0 叠在上面，
           页面 didFinish 之后再淡入。首绘前用户看到的是容器底色（近黑），
           页面背景本身也是 #08090a，淡入时没有任何色阶跳变。 */
        let container = NSView(frame: fr)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1).cgColor
        web.frame = container.bounds
        web.alphaValue = 0
        container.addSubview(web)
        win.contentView = container
        win.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1)
        win.isOpaque = true
        win.hasShadow = false       // 全屏窗口的阴影永远不可见，省一次合成
        win.level = .screenSaver    // 1000 > 菜单栏(~25)/Dock：这才是真全屏
        /* ⚠⚠ 2026-10-25 修「一闪的白屏」：
           WKWebView 在页面首次绘制之前显示的是**自身底色**，默认白。
           窗口又是全屏 .screenSaver 层级，于是开机第一帧是整屏白光，
           然后才切成页面自己的 #08090a 深色底 —— 用户看到的就是"闪一下白"。
           三道一起压：窗口底色、WebView 不透明、underPageBackgroundColor。 */
        win.isOpaque = true
        win.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1)
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1)
        }
        // ⚠ WKWebView.isOpaque 是 get-only，不能赋值；底色靠上面两处已经压住。
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// 页面已就绪 → 把 WebView 淡入（首绘前的近黑容器正好接住这一帧）
    private func revealWeb(after delay: Double = 0.15) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.web.alphaValue < 1 else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.web.animator().alphaValue = 1
            }
        }
    }

    func webView(_ v: WKWebView, didFinish n: WKNavigation!) {
        revealWeb()
        // 调试：确认页面**真的**收到了注入配置（宿主自己 dict 里有不等于页面有）
        if ProcessInfo.processInfo.environment["WB_LAUNCH_DEBUG"] != nil {
            let js = "(function(){var c=window.__WB_BOOT_CONFIG__;" +
                     "return c? String(c.gateTimeoutMs)+'/'+String(c.sceneGate) : 'MISSING';})()"
            web.evaluateJavaScript(js) { r, _ in
                let v = (r as? String) ?? "ERR"
                let line = "[wblaunch] page gate=" + v + "\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
        }
        // 自检探针：WB_LAUNCH_PROBE_MS=6000 时，第 6 秒把「闸门还在不在 + 日志」
        // 打成一行 JSON。像素截图会被「当时桌面上有什么」干扰（实测同一条断言
        // 时而绿时而红），而闸门状态是页面内部事实，不受前台应用影响。
        if let probeMs = ProcessInfo.processInfo.environment["WB_LAUNCH_PROBE_MS"],
           let ms = Double(probeMs), ms > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000.0) { [weak self] in
                guard let self = self else { return }
                let js = "(function(){var g=document.querySelector('.dsu-gate');" +
                         "var lab=document.querySelector('.dsu-scene-label,.dsu-label');" +
                         "return JSON.stringify({gate: !!(g && g.classList.contains('dsu-in'))," +
                         "logT: typeof window.__WB_GATE_LOG__," +
                         "n: (window.__WB_GATE_LOG__||[]).length," +
                         "lab: (lab && lab.textContent || '').trim().slice(0,20)});})()"
                self.web.evaluateJavaScript(js) { r, _ in
                    let v = (r as? String) ?? "ERR"
                    FileHandle.standardError.write(("[wblaunch] probe " + v + "\n").data(using: .utf8)!)
                }
            }
        }
        // 调试：每秒把闸门日志打一行（动画 4 秒就播完时，6 秒定时器永远等不到）
        if ProcessInfo.processInfo.environment["WB_LAUNCH_DEBUG"] != nil {
            gateLogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                self.web.evaluateJavaScript("(window.__WB_GATE_LOG__||[]).length") { r, _ in
                    let n = (r as? Int) ?? -1
                    guard n != self.lastGateCount else { return }
                    self.lastGateCount = n
                    self.web.evaluateJavaScript("(window.__WB_GATE_LOG__||[]).join(' | ')") { r2, _ in
                        let v = (r2 as? String) ?? "ERR"
                        FileHandle.standardError.write(("[wblaunch] gate log " + v + "\n").data(using: .utf8)!)
                    }
                }
            }
        }
        poll()
    }

    /// 揭幕判定：__WB_DONE__ 由 atDocumentStart 注入的监听器维护，
    /// 事件在 finish() 移除 root 的同一刻派发 —— 盯 root 是否消失会平白多等 900ms
    /// （finish() 里先addClass('dsu-gone') 再延时 removeChild）。
    /// 双保险还看root 存不存在，两条路任一命中即放行。
    func poll() {
        /* ⚠⚠⚠ 2026-10-25 修：这里的判据原来把三个状态压成了一个字符串：
             (__WB_DONE__|0) + (root 存在 ? 0 : 1)
             0 = 没完成且 root 在   → 继续等
             1 = **没完成但 root 不在**  ← 页面刚加载、splash.js 还没建 DOM 时就是 1
             1 = **已完成但 root 还在**  ← 与上一行撞车
             2 = 已完成且 root 已移除
           于是页面一 didFinish，根元素还没建出来，第一次 poll 就拿到 "1"，
           被当成"揭幕完成"→ close() + onDone() → 整个动画 3 秒收工。
           症状极具欺骗性：窗口全屏、visible/key/firstResp 全 true、日志零报错，
           屏幕上是一片白（首帧都没画）。用户看到的就是"开机白屏 3 秒"。
           实测代价：ERR-0013 里我先怀疑了 file:// 读权限和 loadFileURL，全是错的方向。

           现在：两个状态分开返回，且"root 不在"必须熬过 5 秒宽限才认，
           避免把"还没开始"误判成"已经结束"。 */
        let started = Date()
        var sawRoot = false          // 见过 root 就算"页面真的起来了"
        func tick() {
            let js = "(function(){return String(window.__WB_DONE__|0) + ':' + " +
                     "(document.getElementById('dsh-startup-root') ? 1 : 0);})()"
            web.evaluateJavaScript(js) { res, err in
                guard !self.fired else { return }
                let state = (res as? String) ?? "?"
                let parts = state.split(separator: ":")
                let done = Int(parts.first ?? "0") ?? 0
                let rootPresent = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
                let elapsed = Date().timeIntervalSince(started)

                if ProcessInfo.processInfo.environment["WB_LAUNCH_DEBUG"] != nil, Int(elapsed) % 5 == 0 {
                    FileHandle.standardError.write(
                        "[wblaunch] poll done=\(done) root=\(rootPresent) t=\(Int(elapsed))s err=\(err == nil ? "no" : "yes")\n"
                            .data(using: .utf8)!)
                }

                if rootPresent == 1 { sawRoot = true }

                // ① 明确完成（__WB_DONE__ 由页面 finish() 派发）
                if done == 1 {
                    self.fired = true; self.close(); self.onDone?(); return
                }
                // ② 见过 root 之后又消失 —— 正常收尾（页面自己移除 DOM）
                if sawRoot && rootPresent == 0 {
                    self.fired = true; self.close(); self.onDone?(); return
                }
                // ③ 兜底：从没建出 root 且已等 8 秒，认定脚本失败，放行
                if !sawRoot && elapsed > 8.0 {
                    FileHandle.standardError.write(
                        "[wblaunch] ⚠️ 8 秒内页面没建出 root（脚本可能失败），放行\n".data(using: .utf8)!)
                    self.fired = true; self.close(); self.onDone?(); return
                }
                _ = err
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { tick() }
            }
        }
        tick()
    }


    /// 兜底：动画脚本万一抛错，poll 永远等不到移除 —— 到点无论如何放行。
    func armTimeout(_ sec: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
            if !self.fired { self.fired = true; self.close(); self.onDone?() }
        }
    }

    func close() {
        win.orderOut(nil)
        web.stopLoading()
    }

    func show() {
        // ⚠ 全屏窗口**不能**用 center()：center() 按主屏中心重排，
        //   多屏不同分辨率时会把窗口挪出目标屏。钉死目标屏整幅 frame。
        win.setFrame(fullFrame, display: true)
        // ⚠ activate 必须先于 makeKeyAndOrderFront：.accessory app 不是前台
        //   app 时，系统把键事件发给别的 app，窗口成了 key 也收不到键盘。
        //   （canBecomeKey 管"窗口能不能当 key"，activate 管"app 是不是前台"，
        //     两条都满足 Space/Enter 才进得了 WebKit —— 2026-10-22 实测。）
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        // 显式把键盘焦点钉到 WebView：borderless 窗口的 responder 链
        // 偶尔不会自动落到 contentView，不钉的话键事件到窗口就断了。
        win.makeFirstResponder(web)
        win.displayIfNeeded()
        if ProcessInfo.processInfo.environment["WB_LAUNCH_DEBUG"] != nil {
            let f = win.frame
            // key 状态变更要走一轮 run loop，同步查会读到 false 假阴性 ——
            // 延后 0.6s 再看，那才是用户实际面对的状态。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                FileHandle.standardError.write("""
                [wblaunch] window \(Int(f.width))x\(Int(f.height)) visible=\(self.win.isVisible) \
                key=\(self.win.isKeyWindow) firstResp=\(self.win.firstResponder === self.web) \
                active=\(NSApp.isActive) \
                policy=\(NSApp.activationPolicy().rawValue) screen=\(Int(NSScreen.main?.frame.width ?? -1))x\(Int(NSScreen.main?.frame.height ?? -1))\n
                """.data(using: .utf8)!)
            }
        }
    }
}

// ── 拉起 WorkBuddy ────────────────────────────────────────────────────────
func launchWorkBuddy() {
    if isWorkBuddyRunning() { return }
    // ⚠⚠ 路径不存在时**绝不能**调 openApplication(at:)：
    //   NSWorkspace 会弹一个**系统级**「应用程序启动失败」模态框。
    //   那个弹窗会卡住用户的桌面，而且对用户毫无意义（他们不知道是什么 app 失败）。
    //   这是自检时用假路径验证「未运行 → 播动画」路径必然踩到的坑。
    guard FM.fileExists(atPath: WB_APP) else {
        if ProcessInfo.processInfo.environment["WB_LAUNCH_DEBUG"] != nil {
            FileHandle.standardError.write(
                "[wblaunch] 应用不存在，跳过拉起（不弹系统错误框）：\(WB_APP)\n"
                    .data(using: .utf8)!)
        }
        return
    }
    // ⚠⚠ 这里用 `/usr/bin/open -b <bundleid>` 而不是 NSWorkspace.openApplication(at:):
    //   openApplication **失败时会弹系统级模态框**（CoreServicesUIAgent
    //   「应用程序无法打开」），用户关不掉、还会挡住桌面。
    //   2026-10-22 实测：cryptex 路径的应用走 openApplication 必然 -600 → 必然弹窗。
    //   `open` CLI 走同一条 LaunchServices 链路，失败**只写 stderr**，绝不弹窗。
    //
    // ⚠ 按 bundle id 而不是按路径：cryptex 应用按路径 open 一定失败，
    //   但 `open -b` 是成功的（系统自己认得 cryptex 路径）。
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-b", WB_BUNDLE]
    let errPipe = Pipe()
    p.standardOutput = Pipe()
    p.standardError = errPipe
    guard (try? p.run()) != nil else {
        FileHandle.standardError.write(
            "[wblaunch] 无法执行 open，跳过拉起\n".data(using: .utf8)!)
        return
    }
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        FileHandle.standardError.write(
            "[wblaunch] 拉起失败：\(msg)\n".data(using: .utf8)!)
    }
}

/// 把已在运行的 WorkBuddy 置前（不重新启动它）
func activateWorkBuddyIfRunning() {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: WB_BUNDLE)
    for a in apps {
        a.activate(options: [])
    }
}

// ── main ──────────────────────────────────────────────────────────────────
let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "play"

if cmd == "--emit-config" || cmd == "emit-config" {
    print(jsonOf(makeConfig(reason: "emit")))
    exit(0)
}

if cmd == "probe" {
    let running = isWorkBuddyRunning()
    let cfg = makeConfig(reason: "probe")
    let out: [String: Any] = [
        "bundle": WB_BUNDLE,
        "appExists": FM.fileExists(atPath: WB_APP),
        "workbuddyRunning": running,
        "decision": running ? "skip" : "play",
        "reason": running ? "WorkBuddy 已在运行 → 不播（用户已明确要求）" : "WorkBuddy 未运行 → 播",
        "webDir": webDir(),
        "webExists": FM.fileExists(atPath: webDir() + "/splash.js"),
        "config": cfg
    ]
    print(jsonOf(out))
    exit(0)
}

// ── boot 模式：开机自启动场景 ──────────────────────────────────────────────
// 场景：launchd 在用户登录时同时拉起两个东西 ——
//   ① WorkBuddy 自己（它用 SMAppService 注册的登录项，系统直接放行，拦不住）
//   ② 我们的 wblaunch（LaunchAgent com.lingtai.bootanim）
// 两者赛跑：谁先起来是不确定的。
//   - 如果 WorkBuddy 先起来 → 我们的动画**仍然要播**（用户明确要求开机时播），
//     只是不能再重复拉起 WorkBuddy。
//   - 如果我们先起来 → 播动画，动画播完再拉起 WorkBuddy。
// 所以 boot 模式不看"是否在运行"来决定播不播，只决定"播完要不要拉起"。
// ⚠ 而「手动双击打开」走的是完全不同的路径（LaunchServices / Dock），
//   根本不经过 wblaunch —— 所以用户要求的"手动打开不播"天然成立。
let isBoot = cmd == "boot"
let shouldPlay = argv.first == "play" || isBoot
guard shouldPlay else {
    FileHandle.standardError.write(
        "用法: wblaunch play [--no-launch] | boot [--no-launch] | probe | --emit-config\n"
            .data(using: .utf8)!)
    exit(2)
}
let doLaunch = !argv.contains("--no-launch")
let force = argv.contains("--force")   // 仅供自检：跳过"已在运行"判定，强制播一次
let reason = (ProcessInfo.processInfo.environment["WB_LAUNCH_REASON"]
              ?? (isBoot ? "boot" : "manual"))

// 判定：已在运行就不播，直接拉起
// ⚠ boot 模式例外：开机时 WorkBuddy 极可能已被系统拉起（它自己有登录项），
//   但用户要求"开机自启动时播动画" —— 所以 boot 模式一律播，只是不重复拉起。
if isWorkBuddyRunning() && !force && !isBoot {
    if ProcessInfo.processInfo.environment["WB_LAUNCH_DEBUG"] != nil {
        FileHandle.standardError.write("[wblaunch] WorkBuddy running → skip\n".data(using: .utf8)!)
    }
    // 已在运行 → 不播动画（用户明确要求），但**必须置前**：
    // 「点了没反应」的体感比不播动画更糟。activate 由这个 GUI 进程执行
    // （纯 CLI 子进程调 activate 无效 —— 2026-10-22 实证，工件 A 会把它收回面板进程）。
    if doLaunch { activateWorkBuddyIfRunning() }
    exit(0)
}

// 资源缺失 → 跳过动画，别让用户盯一个空窗
let webRoot = webDir()
guard ["splash.js", "splash.css", "brand.js", "index.html"].allSatisfy({
    FM.fileExists(atPath: webRoot + "/" + $0)
}) else {
    FileHandle.standardError.write("wblaunch: 资源缺失（\(webRoot)），跳过动画\n".data(using: .utf8)!)
    if doLaunch { launchWorkBuddy() }
    exit(0)
}

let app = NSApplication.shared
// .accessory：不占 Dock 图标、不抢菜单栏。
//⚠ 但纯 .accessory 下 window 可能无法置前（尤其是从别的 App 调起时），
//   所以 show() 里的 makeKeyAndOrderFront 是必须的，不是可选的。
// ⚠⚠ 键盘焦点不靠 activate：wblaunch 是无 bundle 的命令行二进制，
//   NSApp.activate 对它无效（2026-10-22 实测 active=false）。改用
//   NSPanel + .nonactivatingPanel（见 KeyWindow 注释）—— 非激活面板
//   允许 app 非前台时成为 key window，键事件直接进 WebView。
app.setActivationPolicy(.accessory)

// ── 锁屏检测 ──────────────────────────────────────────────────────────────
// ⚠ 开机自启时，用户很可能还没解锁屏幕。锁屏状态下窗口根本看不见 ——
//   动画会对着锁屏背板播 15 秒，用户解锁后只剩残影。
//   CGSessionCopyCurrentDictionary 能读到 kCGSessionOnConsoleKey /
//   kCGSSessionScreenIsLockedKey，锁屏时返回 0。
func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return false
    }
    // 首选明确判据：CGSSessionScreenIsLocked
    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    // ⚠ 不能用 `!onConsole` 当锁屏判据：
    //   onConsole=false 也出现在「根本没有 GUI 会话」的场景（SSH / headless），
    //   那样 boot 模式会白等 90 秒然后什么也不播。
    //   正确的组合判据：onConsole=false **且** 拿得到屏幕 → 是锁屏；
    //   拿不到屏幕说明压根没有 GUI 会话 → 直接放行（让后面的屏幕就绪等待去处理）。
    if let onConsole = dict["kCGSSessionOnConsoleKey"] as? Bool, !onConsole {
        return !NSScreen.screens.isEmpty
    }
    return false
}

/// 开机场景等锁屏解除（最多 90 秒）；非开机场景直接返回。
func waitForUnlockIfBoot() {
    guard isBoot else { return }
    var waited = 0.0
    while isScreenLocked() && waited < 90 {
        Thread.sleep(forTimeInterval: 0.5)
        waited += 0.5
    }
}

// ── 等屏幕就绪 ────────────────────────────────────────────────────────────
// ⚠⚠ 开机自启场景的致命细节：LaunchAgent 在登录时启动的那一刻，
//   GUI session 往往还没完全就绪 —— NSScreen.main 会是 nil。
//   早期版本在这里直接 exit(0)，结果就是「开机该播的动画被静默跳过」，
//   而日志里什么都看不到（因为 exit 前什么都没打印）。
//   现在改成轮询等待，最长 12 秒；拿不到屏幕才放弃。
waitForUnlockIfBoot()
var screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first
if screen == nil {
    for _ in 0..<60 {
        Thread.sleep(forTimeInterval: 0.2)
        if let s = NSScreen.main ?? NSScreen.screens.first {
            screen = s
            break
        }
    }
}
guard let screen = screen else {
    FileHandle.standardError.write(
        "wblaunch: 12 秒内拿不到屏幕（GUI session 未就绪），跳过动画\n"
            .data(using: .utf8)!)
    if doLaunch { launchWorkBuddy() }
    exit(0)
}

let splash = Splash(screen: screen, configJSON: jsonOf(makeConfig(reason: reason)))
if ProcessInfo.processInfo.environment["WB_LAUNCH_DEBUG"] != nil {
    let cfg = makeConfig(reason: reason)
    let line = "[wblaunch] gate sceneGate=\(cfg["sceneGate"] ?? "?") timeoutMs=\(gateTimeoutMs())\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}
splash.onDone = {
    if doLaunch {
        if isBoot {
            // boot 模式：WorkBuddy 极可能已经被系统拉起来了。
            // 重复 openApplication 不会开第二个实例（LaunchServices 会复用），
            // 但会**抢焦点把用户正在做的事打断** —— 开机那一刻用户往往在等。
            // 所以：已在跑就只置前（甚至不置前），不在跑才拉起。
            activateWorkBuddyIfRunning()
            if !isWorkBuddyRunning() { launchWorkBuddy() }
        } else {
            launchWorkBuddy()
        }
    }
    exit(0)
}
// ⚠ 90 秒不是拍脑袋：场景闸门上线后最坏情况 = 9 道闸 × 3 秒 + 各幕内容与语音
//   ≈ 50 秒。原来 20 秒的兜底会把动画拦腰掐断（闸门等待中就被判死）。
splash.armTimeout(90)

let url = URL(fileURLWithPath: webRoot + "/index.html")
/* ⚠⚠⚠ 必须 loadFileURL + allowingReadAccessTo（2026-10-25 修）
   故障实录：原来为绕开 file:// 缓存，在 URL 上挂了 ?v=<ms> 查询串，并用
   load(URLRequest)。结果 **index.html 能加载、子资源全被拦掉**：
   splash.css / brand.js / splash.js / 音频 / 贴图都没读权限 → 整页纯白。
   而 didFinish 照常回调、注入的 gate 配置也读得到（那是 WKUserScript 注入的），
   所以日志里零报错、debug 里 visible/key/firstResp 全 true ——
   看起来"在播"，其实播的是白屏，3 秒后 onDone 就 exit(0)。
   缓存不靠查询串解决：websiteDataStore = .nonPersistent()，
   每次 wblaunch 都是新进程 + 空缓存，本来就没有跨次缓存。 */
splash.web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: webRoot))

// ⚠⚠ show() 必须排在 app.run() 之后：NSApp.activate(ignoringOtherApps:)
//   在 app 完成 launch 之前调用是**空操作**（实测 key=false，键盘焦点
//   拿不到，Space/Enter 闸门全线失效）。排进 main queue，run loop 一启动
//   就执行，此时 app 已 finishing launching，activate 才真正生效。
DispatchQueue.main.async { splash.show() }

app.run()