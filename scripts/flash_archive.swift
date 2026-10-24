import AppKit
import ApplicationServices

// MARK: - 工业档案画风的视图组件
//
// ⚠ 这些视图是**闪控面板改造（色板 + 结构）**的核心资产。
//   之前的面板是"深色玻璃卡片"：圆角、半透明白、柔和辉光。
//   那是 2020 年代初的 macOS 毛玻璃审美，放到今天显得"又一个半透明面板"。
//   工业档案画风（对齐开场动画 dsh-startup-screen 的语言）是：
//     · 近黑纸底 + 发丝级细线（不是亮边框）
//     · 方角为主，圆角只在极少数地方
//     · 单一青绿主色，其余全是灰阶
//     · 数据/编号一律等宽字体，正文用窄体（档案感的关键）
//     · 角标、刻度、编号 —— 让人一眼看出"这是仪表盘，不是聊天窗口"
//
//   单独成文件而不是塞进 flash.swift：
//   flash.swift 已经 1200+ 行，再往里塞会让"面板逻辑"和"绘制细节"缠死。

// MARK: - 档案纸底板
//
// 底板做三件事：
//   ① 近黑的双级渐变（几乎不可见，但避免死板的纯色）
//   ② 极淡的网格 —— 10pt 一格，只在 0.04 透明度，
//      远看是"有肌理的纸"，近看是"刻度"
//   ③ 上下两条发丝线 + 角标，划出"档案封面"的框
final class ArchiveBackground: NSView {
    override var isFlipped: Bool { false }

    /// 网格间距（pt）
    private let cell: CGFloat = 20

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSGradient(starting: Palette.bgTop, ending: Palette.bgBottom)?
            .draw(in: r, angle: -90)

        // ── 网格 ──────────────────────────────────────────────
        // 透明度压到 0.035：它只能"被感觉到"，不能"被看到"。
        // 一旦提高到 0.08 就会变成 Excel 表格的观感 —— 那是另一个方向。
        NSColor.white.withAlphaComponent(0.035).setStroke()
        let gp = NSBezierPath()
        gp.lineWidth = 1
        var x = r.minX
        while x <= r.maxX {
            gp.move(to: NSPoint(x: x, y: r.minY))
            gp.line(to: NSPoint(x: x, y: r.maxY))
            x += cell
        }
        /* ⚠ 只画竖线，不画横线。
           20pt 一格的横向网格线会正好落在两张卡片之间的空隙里（12pt 的缝），
           在近黑底上它就是"一条横贯面板的细线" —— 用户会以为那里有一条
           多余的分隔线。竖线不会：它穿过的每一处都被卡片挡着，只在
           左右留白里露头，读作纸纹而不是分隔。 */
        gp.stroke()

        // ── 顶部发丝线 ─────────────────────────────────────────
        Palette.hair.setStroke()
        let top = NSBezierPath()
        top.move(to: NSPoint(x: r.minX, y: r.maxY - 0.5))
        top.line(to: NSPoint(x: r.maxX, y: r.maxY - 0.5))
        top.lineWidth = 1
        top.stroke()

        // ── 四角角标 ───────────────────────────────────────────
        // 档案封面的"L 形"角标。长度 18pt，1px 线，0.35 透明度。
        drawCornerMarks(in: r)

        // ── 右侧一道极淡的青绿光带 ─────────────────────────────
        // 给"仪器在通电"的感觉，位置压在右侧自检栏后面。
        if let g = NSGradient(starting: Palette.accent.withAlphaComponent(0.055),
                             ending: Palette.accent.withAlphaComponent(0)) {
            g.draw(fromCenter: NSPoint(x: r.maxX, y: r.midY),
                   radius: r.width * 0.42,
                   toCenter: NSPoint(x: r.maxX, y: r.midY),
                   radius: 0, options: [])
        }
    }

    private func drawCornerMarks(in r: NSRect) {
        let L: CGFloat = 18
        Palette.hair.withAlphaComponent(0.55).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1

        let corners: [(NSPoint, NSPoint, NSPoint)] = [
            // 左上：→ ↓
            (NSPoint(x: r.minX + 10, y: r.maxY - 10),
             NSPoint(x: r.minX + 10 + L, y: r.maxY - 10),
             NSPoint(x: r.minX + 10, y: r.maxY - 10 - L)),
            // 右上：← ↓
            (NSPoint(x: r.maxX - 10, y: r.maxY - 10),
             NSPoint(x: r.maxX - 10 - L, y: r.maxY - 10),
             NSPoint(x: r.maxX - 10, y: r.maxY - 10 - L)),
            // 左下：→ ↑
            (NSPoint(x: r.minX + 10, y: r.minY + 10),
             NSPoint(x: r.minX + 10 + L, y: r.minY + 10),
             NSPoint(x: r.minX + 10, y: r.minY + 10 + L)),
            // 右下：← ↑
            (NSPoint(x: r.maxX - 10, y: r.minY + 10),
             NSPoint(x: r.maxX - 10 - L, y: r.minY + 10),
             NSPoint(x: r.maxX - 10, y: r.minY + 10 + L)),
        ]
        for (o, a, b) in corners {
            p.move(to: a); p.line(to: o); p.line(to: b)
        }
        p.stroke()
    }
}

// MARK: - 档案卡片
//
// 与 GlassCard 的区别（这是"结构"层面的改造，不是换个边框）：
//   GlassCard：圆角 18 + 半透明白 + 顶部内高光 = 毛玻璃
//   ArchiveCard：方角 + 不透明纸底 + 发丝描边 + 右上角编号块 = 档案页
// 卡片标题用等宽大写字 + 细分割线 —— 这是档案风最强的信号。
final class ArchiveCard: NSView {
    /// 右上角的编号（如 "01 / COMMON"）。空则不画。
    /// ⚠ 不能叫 tag —— NSView 已有 `tag: Int`（用于 view tag 查询），
    ///   同名覆盖会编译失败。
    var stamp: String = ""
    /// 标题下方的分割线
    var showRule: Bool = true

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)

        // 纸底
        Palette.cardBg.setFill()
        NSBezierPath(rect: r).fill()

        // 发丝描边：整框降到 0.5pt（更"纸"），四角另画括号（更"仪表"）。
        Palette.hair.setStroke()
        let p = NSBezierPath(rect: r)
        p.lineWidth = 0.5
        p.stroke()

        /* 四角括号：借鉴参考项目的仪表构图 —— 一个完整的细框读起来像"卡片"，
           只留四个角的短折线才像"仪表盘上的取景框"。
           长度 9pt、离角 0、和细框同色但更亮一档，眼睛会先看到角、再看到框。
           ⚠ 只画四个角，不画整框：整框 + 括号会变成双线，更糊。 */
        Palette.accent.withAlphaComponent(0.55).setStroke()
        let c: CGFloat = 9
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: r.minX, y: r.maxY - c), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + c, y: r.maxY)),
            (CGPoint(x: r.maxX - c, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY - c)),
            (CGPoint(x: r.minX, y: r.minY + c), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + c, y: r.minY)),
            (CGPoint(x: r.maxX - c, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + c)),
        ]
        for (a, m, b) in corners {
            let path = NSBezierPath()
            path.move(to: a); path.line(to: m); path.line(to: b)
            path.lineWidth = 1.2
            path.stroke()
        }

        /* 左上角一道 42pt 的橙色短线（参考稿 .dsu-checks::before 的做法）。
           它是这套版式里最便宜也最有效的"档案"信号：
           卡片不再是四个边等值的框，而是"被裁下来的一页" ——
           眼睛会沿着这道线开始读，标题和编号自然落在同一根轴上。 */
        Palette.accent.setFill()
        NSRect(x: r.minX, y: r.maxY - 1.6, width: min(42, r.width * 0.34), height: 1.6).fill()

        // 栏线：把卡片分成"标题条"和"内容区"
        //   ⚠ 编号和标题必须在**栏线的两侧**：编号在栏线上方（贴卡片顶边），
        //   标题在栏线下方。早期版本两者都在右上角，结果编号直接压在标题上，
        //   "01 / COMMON" 和 "常用操作" 叠成一团糊字。
        if showRule {
            Palette.hairSoft.setStroke()
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: r.minX + 12, y: r.maxY - 30.5))
            rule.line(to: NSPoint(x: r.maxX - 12, y: r.maxY - 30.5))
            rule.lineWidth = 0.5
            rule.stroke()
        }

        // 右上角编号块（贴在栏线上方）
        if !stamp.isEmpty {
            drawTag(stamp, in: r)
        }
    }

    /// 编号：等宽字体、字距拉开、青绿色
    private func drawTag(_ text: String, in r: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Palette.accent.withAlphaComponent(0.75),
            .kern: 1.2,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        // 贴在卡片顶边内侧（栏线之上）
        let origin = NSPoint(x: r.maxX - 12 - size.width, y: r.maxY - 13)
        s.draw(at: origin, withAttributes: attrs)
    }
}

// MARK: - 三维自转线框地球
//
//⚠ 为什么不是"贴一张地球图片"：
//   ① 视觉语言不允许。整块面板是近黑纸底 + 发丝线 + 单一青绿，
//      塞一张位图会立刻破功 —— 它是 2020 年代前的地球贴图质感，
//      和"工业档案"不是同一个年代的东西。
//   ② 位图缩放会糊。96pt 的框在Retina 上要画 192px，
//      位图得准备 @1x/@2x 两套，仓库里多一个二进制资源要分发。
//   ③ 真三维能对极轴倾斜，而位图只能平面旋转 —— "转起来像地球"
//      和"它就是��个球"在余光里有区别，用户说不出来但能感觉到。
//
// 画法：球面坐标 → 绕极轴自转 → 绕横轴倾斜 → 正交投影 → 按 z 分级透明度。
// 只画**子午线与纬线**（经纬网），不画球体外壳 —— 线框才像"测绘/档案"，
// 实心球会变成普通 3D 图标。
class GlobeView: NSView {
    /// 自动自转角度（度）。由 Panel 的定时器推进。
    /// ⚠ 拖拽**不改**这个值，而是改 `dragLon` 叠加在它上面 ——
    ///   这样松手之后自转立刻"接着走"，不需要任何"恢复计时"的逻辑。
    var phase: CGFloat = 0
    /// 忙碌时加速自转（由外部设置）
    var spinning = false
    /// 出图放大倍数（1 = 面板实际尺寸）。
    /// ⚠ 所有线宽与光晕半径都按它**反向缩小**，
    ///   这样放大出图看到的线粗细与面板上完全一致。
    var zoom: CGFloat = 1
    private func lw(_ w: CGFloat) -> CGFloat { w / zoom }

    override var isFlipped: Bool { false }

    // ── 相机 ───────────────────────────────────────────────────────────
    /// 相机纬度：垂直拖拽改它，松手后保持（不弹回）。
    private var camLat: CGFloat = 30
    /// 水平拖拽的经度偏移：叠加在 phase 上，与自转共用同一个自由度。
    private var dragLon: CGFloat = 0

    // ── 交互状态 ───────────────────────────────────────────────────────
    private var dragging = false
    private var hovering = false
    private var lastDrag: NSPoint = .zero
    private var velLon: CGFloat = 0
    private var velLat: CGFloat = 0
    private var glide: Timer?
    private var trackArea: NSTrackingArea?

    /// 球的半径。留 8pt 给边缘辉光 —— 辉光画在球外面，
    /// 按 R 卡边的话它会被视图边界切掉，变成"四个方向各缺一块"。
    private func earthRadius() -> CGFloat { min(bounds.width, bounds.height) / 2 - 11 }

    // ── 全息色板（取自参考片：深蓝球芯 / 青色边缘 / 白色数据点）───────
    private static let coreColor = NSColor(srgbRed: 0.039, green: 0.114, blue: 0.196, alpha: 1)
    private static let edgeColor = NSColor(srgbRed: 0.004, green: 0.016, blue: 0.031, alpha: 1)
    private static let cyan      = NSColor(srgbRed: 0.235, green: 0.706, blue: 1.000, alpha: 1)
    private static let cyanSoft  = NSColor(srgbRed: 0.416, green: 0.816, blue: 1.000, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        // 卡片底 + 发丝边 + 左上角主色短线：与 01/02/03 三张卡**同一套**框架。
        //   参考片里的球是悬在纯黑里的，但面板里每一块都有框 ——
        //   少一个框，这一块就会读成"贴上去的图"，不是"面板的一部分"。
        let card = bounds.insetBy(dx: 0.5, dy: 0.5)
        Palette.cardBg.setFill()
        NSBezierPath(rect: card).fill()
        Palette.hair.setStroke()
        let border = NSBezierPath(rect: card)
        border.lineWidth = lw(1)
        border.stroke()
        Palette.accent.withAlphaComponent(0.9).setFill()
        NSRect(x: 0, y: bounds.maxY - 1.6, width: 42, height: 1.6).fill()

        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let R = earthRadius()
        guard R > 8 else { return }

        let rad = max(-72, min(72, camLat)) * .pi / 180
        // 与旧版同一套相位约定：phase = 108 时中国正对镜头
        let spin = (phase + dragLon - 108) * .pi / 180

        // ① 球芯：径向渐变，中心偏右上一点，边缘沉到近黑。
        //    参考片里球是"半透明玻璃壳"，内圈有微光、外圈几乎黑 ——
        //    纯色填充会变成一个实心圆盘，那是 3D 图标，不是全息球。
        let disk = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R,
                                               width: R * 2, height: R * 2))
        NSGradient(starting: GlobeView.coreColor, ending: GlobeView.edgeColor)?
            .draw(in: disk, relativeCenterPosition: NSPoint(x: 0.12, y: 0.18))

        // ② 边缘辉光：三层递减。这是参考片最强的特征 ——
        //    球体靠"边缘在发光"被看成球，而不是靠中间画得多细。
        for (dr, w, a) in [(CGFloat(4.6), CGFloat(6.0), CGFloat(0.050)),
                           (2.4, 3.4, 0.095),
                           (1.0, 2.0, 0.180)] {
            GlobeView.cyan.withAlphaComponent(a).setStroke()
            let g = NSBezierPath(ovalIn: NSRect(x: c.x - R - dr, y: c.y - R - dr,
                                                width: (R + dr) * 2, height: (R + dr) * 2))
            g.lineWidth = lw(w)
            g.stroke()
        }
        // ③ 硬边：一条 0.9pt 的亮环，把辉光"收"在球体轮廓上
        GlobeView.cyan.withAlphaComponent(0.72).setStroke()
        let rim = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R,
                                              width: R * 2, height: R * 2))
        rim.lineWidth = lw(0.9)
        rim.stroke()

        // ③b 内缘薄辉：壳的厚度。参考片的球是"玻璃壳"不是"实心球"，
        //     边缘内侧比球心亮一档 —— 少这一层，球就是一坨深蓝。
        GlobeView.cyan.withAlphaComponent(0.05).setStroke()
        let inner = NSBezierPath(ovalIn: NSRect(x: c.x - R + 3, y: c.y - R + 3,
                                                width: (R - 3) * 2, height: (R - 3) * 2))
        inner.lineWidth = lw(6)
        inner.stroke()

        // ④ 经纬网：后画正面、先画背面 —— 顺序本身就在表达"这是球"
        var front = NSBezierPath()
        var back = NSBezierPath()

        var lat = -60
        while lat <= 60 {
            if abs(lat - Int(camLat)) > 1 {
                appendParallel(front: &front, back: &back, center: c, R: R,
                               latDeg: CGFloat(lat), tiltRad: rad, spinRad: spin)
            }
            lat += 30
        }
        var lon = -180
        while lon < 180 {
            appendMeridian(front: &front, back: &back, center: c, R: R,
                           lonDeg: CGFloat(lon), tiltRad: rad, spinRad: spin)
            lon += 30
        }
        // 赤道：参考片里基准面会亮一档，作为"纬度参照"存在
        appendEquatorSamples(front: &front, back: &back, center: c, R: R,
                             tiltRad: rad, spinRad: spin)

        GlobeView.cyan.withAlphaComponent(0.07).setStroke()
        back.lineWidth = lw(0.55)
        back.stroke()

        GlobeView.cyan.withAlphaComponent(0.17).setStroke()
        front.lineWidth = lw(0.6)
        front.stroke()

        // ④.5 赤道：基准面**单独亮一档**。
        //   ⚠ 2026-10-23 上一版重写时把它并进了普通经纬网，赤道和别的纬线一样淡，
        //     "球心的基准面"这个视觉锚点就没了。这里单独补一条更亮的同色弧线：
        //     同色相、透明度 0.55（经纬网正面才 0.17），一眼可辨但不抢大陆。
        drawEquator(center: c, R: R, tiltRad: rad, spinRad: spin)

        // ⑤ 大陆：只画海岸线（两层：柔光 + 实线），不填色。
        //    ⚠ 填色这条路试过两次都撤回：跨球缘的环（欧亚、南极）闭合后
        //      会在球心拉出弦，填出来是"半个球被涂满"。
        //      参考片的陆地本来也是"边缘亮、内部暗"，靠数据点标出体块。
        drawLand(front: false, center: c, R: R, tiltRad: rad, spinRad: spin)
        drawLand(front: true, center: c, R: R, tiltRad: rad, spinRad: spin)

        // ⑥ 数据点：陆地上的白色光点。这是参考片最抓眼的一层 ——
        //    它同时表达了"这里有陆地"和"这里有人在用"，比填色高级。
        drawCityLights(center: c, R: R, tiltRad: rad, spinRad: spin)

        // ⑦ 悬停提示：一圈虚线 + 四个角标，只回答一个问题 —— "这个能拖吗"
        if hovering || dragging {
            GlobeView.cyan.withAlphaComponent(dragging ? 0.34 : 0.20).setStroke()
            let ringR = R + 9
            let ringPath = NSBezierPath(ovalIn: NSRect(x: c.x - ringR, y: c.y - ringR,
                                                       width: ringR * 2, height: ringR * 2))
            ringPath.lineWidth = lw(1)
            ringPath.setLineDash([2, 5], count: 2, phase: 0)
            ringPath.stroke()
        }
    }

    // MARK: 大陆与数据点

    /// 大陆轮廓（Natural Earth 110m，数据见 flash_earth_data.swift）。
    ///
    /// ⚠ 长边必须补采样（≤2° 一步）：110m 数据里一条边最长跨几十度，
    ///   直接投影成两点连线会**穿过球体内部**，画出一条横切球的弦。
    /// ⚠ 跨日界线（±180°）的边要先折算到 ±180 以内再插值。
    private func drawLand(front isFront: Bool, center c: CGPoint, R: CGFloat,
                          tiltRad: CGFloat, spinRad: CGFloat) {
        var frontPath = NSBezierPath()
        var backPath = NSBezierPath()

        for ring in earthLandRings {
            var samples: [(NSPoint, CGFloat)] = []
            for i in 0..<ring.count {
                let a = ring[i]
                let b = ring[(i + 1) % ring.count]
                let dLat = b.lat - a.lat
                var dLon = b.lon - a.lon
                if dLon > 180 { dLon -= 360 }
                if dLon < -180 { dLon += 360 }
                let steps = max(1, Int(ceil(max(abs(dLat), abs(dLon)) / 2)))
                for k in 0..<steps {
                    let t = CGFloat(k) / CGFloat(steps)
                    samples.append(project(latDeg: a.lat + dLat * t,
                                           lonDeg: a.lon + dLon * t,
                                           center: c, R: R,
                                           tiltRad: tiltRad, spinRad: spinRad))
                }
            }
            appendCurve(samples, front: &frontPath, back: &backPath)
        }

        if isFront {
            // 柔光层：给海岸线一点"发光"的厚度，代替填色
            GlobeView.cyan.withAlphaComponent(0.13).setStroke()
            frontPath.lineWidth = lw(2.6)
            frontPath.stroke()

            GlobeView.cyanSoft.withAlphaComponent(0.88).setStroke()
            frontPath.lineWidth = lw(0.85)
            frontPath.stroke()
        } else {
            GlobeView.cyan.withAlphaComponent(0.10).setStroke()
            backPath.lineWidth = lw(0.5)
            backPath.stroke()
        }
    }

    private struct CityPoint {
        let lat: CGFloat
        let lon: CGFloat
        /// 亮度权重（0…1），由坐标哈希得出 —— 同一台机器每次启动点的位置一致。
        let glow: CGFloat
    }

    /// 陆地上的"数据点"。一次性算出，之后只做投影。
    ///
    /// 为什么不用随机数：随机每次启动都不一样，用户会察觉"昨天那颗球不长这样"。
    /// 用坐标哈希是确定性的，而且天然分布均匀。
    private static let cityPoints: [CityPoint] = {
        var out: [CityPoint] = []
        var lat: CGFloat = -56
        while lat <= 78 {
            var lon: CGFloat = -180
            while lon < 180 {
                if landContains(lat: lat, lon: lon) {
                    let h = sin(Double(lat) * 12.9898 + Double(lon) * 78.233) * 43758.5453
                    let r = CGFloat(h - floor(h))
                    // 0.66 这个阈值决定了"疏密"：太低整片糊成网格，
                    // 太高陆地就只剩下轮廓、没有"在用"的感觉。
                    if r > 0.80 {
                        /* ⚠⚠ 必须抖动。
                           按经纬格点直接取点，球面上会排成一行行等距的"波点"——
                           那是点阵屏，不是城市。抖动量取 ±0.85°（不到半个格距），
                           既打散规则性，又不会让陆地上的点跑到海里。 */
                        let j1 = sin(Double(lat) * 4.123 + Double(lon) * 1.771) * 12345.678
                        let j2 = sin(Double(lon) * 7.913 - Double(lat) * 2.351) * 54321.098
                        let q1 = CGFloat(j1 - floor(j1)) - 0.5
                        let q2 = CGFloat(j2 - floor(j2)) - 0.5
                        out.append(CityPoint(lat: lat + q1 * 1.7,
                                             lon: lon + q2 * 1.7,
                                             glow: r))
                    }
                }
                lon += 1.9
            }
            lat += 1.9
        }
        return out
    }()

    /// 射线法判断点是否在任一大陆环内（31 个环 / 652 个顶点，一次算完只几毫秒）
    private static func landContains(lat: CGFloat, lon: CGFloat) -> Bool {
        for ring in earthLandRings {
            var inside = false
            var j = ring.count - 1
            for i in 0..<ring.count {
                let yi = ring[i].lat, xi = ring[i].lon
                let yj = ring[j].lat, xj = ring[j].lon
                if (yi > lat) != (yj > lat) {
                    let t = (lat - yi) / (yj - yi)
                    if lon < xi + t * (xj - xi) { inside = !inside }
                }
                j = i
            }
            if inside { return true }
        }
        return false
    }

    private func drawCityLights(center c: CGPoint, R: CGFloat,
                                tiltRad: CGFloat, spinRad: CGFloat) {
        // 按深度分两档批量收集，避免每个点单独 setFill（800 次状态切换会掉帧）
        let bright = NSBezierPath()
        let dim = NSBezierPath()
        let k = max(0.75, R / 87)

        for p in GlobeView.cityPoints {
            let (pt, z) = project(latDeg: p.lat, lonDeg: p.lon,
                                  center: c, R: R,
                                  tiltRad: tiltRad, spinRad: spinRad)
            guard z > 0.03 else { continue }
            let r = (0.24 + p.glow * p.glow * p.glow * 0.70) * k
            let box = NSRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            // z² 做衰减：越靠球缘越暗，模拟"表面斜对观察者"
            if z * z > 0.22 { bright.appendOval(in: box) } else { dim.appendOval(in: box) }
        }

        NSColor.white.withAlphaComponent(0.90).setFill()
        bright.fill()
        GlobeView.cyanSoft.withAlphaComponent(0.34).setFill()
        dim.fill()
    }

    // MARK: 投影

    /// 球面坐标 → 屏幕坐标 + 深度。
    ///
    /// ⚠⚠ 背面点**不镜像、不特殊处理**，直接按正交投影落位。
    ///    镜像之后赤道远侧弧会翻到 y≈0 变成一条横穿球的直线 ——
    ///    这正是之前「球被劈成两半」那个 bug 的成因。
    /// 深度 z1：> 0 面向观察者，< 0 背向。只用于分级透明度与绘制顺序。
    private func project(latDeg: CGFloat, lonDeg: CGFloat,
                         center c: CGPoint, R: CGFloat,
                         tiltRad: CGFloat, spinRad: CGFloat) -> (NSPoint, CGFloat) {
        let lat = latDeg * .pi / 180
        let lon = lonDeg * .pi / 180 + spinRad
        // 标准球面坐标：+Z 朝观察者，+Y 朝屏幕上方，+X 朝右
        let x = cos(lat) * sin(lon)
        let y = sin(lat)
        let z = cos(lat) * cos(lon)
        // 相机纬度：等价于整颗球绕 X 轴回转 -camLat
        let a = tiltRad
        let sy = y * cos(a) - z * sin(a)
        let sz = y * sin(a) + z * cos(a)
        return (NSPoint(x: c.x + x * R, y: c.y + sy * R), sz)
    }

    /// 按正/背面切成**连续子路径**：每次换边都 move 而不是 line，
    /// 否则会在球面上拉出一条横穿的直线。
    private func appendCurve(_ samples: [(NSPoint, CGFloat)],
                             front: inout NSBezierPath,
                             back: inout NSBezierPath) {
        var side: Int? = nil   // 1 = 正面，0 = 背面；nil = 未开始
        for (p, z) in samples {
            let s = z >= 0 ? 1 : 0
            if s != side {
                if s == 1 { front.move(to: p) } else { back.move(to: p) }
                side = s
            } else {
                if s == 1 { front.line(to: p) } else { back.line(to: p) }
            }
        }
    }

    /// 一条纬线（纬线圈）。
    private func appendParallel(front: inout NSBezierPath, back: inout NSBezierPath,
                                center c: CGPoint, R: CGFloat,
                                latDeg: CGFloat, tiltRad: CGFloat, spinRad: CGFloat) {
        var samples: [(NSPoint, CGFloat)] = []
        samples.reserveCapacity(73)
        for step in 0...72 {
            let lon = CGFloat(step) * 5 - 180
            samples.append(project(latDeg: latDeg, lonDeg: lon, center: c, R: R,
                                   tiltRad: tiltRad, spinRad: spinRad))
        }
        appendCurve(samples, front: &front, back: &back)
    }

    /// 一条子午线（经线圈，从北到南）。
    /// ⚠ 纬度只取 ±72°：极点是所有经线的汇聚点，画出来是一个被十几条线
    ///   戳穿的黑点 —— 看着像渲染 bug，不像地球。
    private func appendMeridian(front: inout NSBezierPath, back: inout NSBezierPath,
                                center c: CGPoint, R: CGFloat,
                                lonDeg: CGFloat, tiltRad: CGFloat, spinRad: CGFloat) {
        var samples: [(NSPoint, CGFloat)] = []
        for step in 0...24 {
            let lat = 72 - CGFloat(step) * 6
            samples.append(project(latDeg: lat, lonDeg: lonDeg, center: c, R: R,
                                   tiltRad: tiltRad, spinRad: spinRad))
        }
        appendCurve(samples, front: &front, back: &back)
    }

    /// 赤道高亮通道。⚠ 分段起点必须 move：自转相位会把正面那半圈切到采样数组
    /// 两端，段与段之间硬连会画出一条**横贯球的水平直线**（2026-10-22 踩过）。
    private func drawEquator(center c: CGPoint, R: CGFloat,
                             tiltRad: CGFloat, spinRad: CGFloat) {
        var path = NSBezierPath()
        var wasFront = false
        for step in 0...180 {
            let lon = CGFloat(step) * 2 - 180
            let (p, z) = project(latDeg: 0, lonDeg: lon, center: c, R: R,
                                 tiltRad: tiltRad, spinRad: spinRad)
            if z >= 0 {
                if wasFront { path.line(to: p) } else { path.move(to: p) }
                wasFront = true
            } else {
                wasFront = false
            }
        }
        GlobeView.cyan.withAlphaComponent(0.55).setStroke()
        path.lineWidth = lw(0.9)
        path.stroke()
    }

    private func appendEquatorSamples(front: inout NSBezierPath, back: inout NSBezierPath,
                                      center c: CGPoint, R: CGFloat,
                                      tiltRad: CGFloat, spinRad: CGFloat) {
        var samples: [(NSPoint, CGFloat)] = []
        for step in 0...72 {
            let lon = CGFloat(step) * 5 - 180
            samples.append(project(latDeg: 0, lonDeg: lon, center: c, R: R,
                                   tiltRad: tiltRad, spinRad: spinRad))
        }
        appendCurve(samples, front: &front, back: &back)
    }

    // MARK: 交互
    // 地球只做装饰性自转 + 拖拽；不设置 NSCursor，不抢光标形状。
    // acceptsFirstMouse 仅在面板已是 key 时接受，避免第一次点击“抢鼠标”。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        window?.isKeyWindow == true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        dragging = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard window?.isKeyWindow == true else { return }
        dragging = true
        stopGlide()
        lastDrag = convert(event.locationInWindow, from: nil)
        velLon = 0
        velLat = 0
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - lastDrag.x
        let dy = p.y - lastDrag.y
        lastDrag = p
        let kLon: CGFloat = 0.42
        let kLat: CGFloat = 0.30
        dragLon += dx * kLon
        velLon = dx * kLon
        camLat = max(-72, min(72, camLat - dy * kLat))
        velLat = -dy * kLat
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        startGlide()
        needsDisplay = true
    }

    /// 松手后的惯性：速度按 0.92 衰减，低于阈值就停。
    /// 停掉之后交给 Panel 的自转定时器 —— 两者互不干涉，
    /// 所以"手不碰它的时候继续自转"是结构保证的，不需要状态机。
    private func startGlide() {
        guard abs(velLon) > 0.06 || abs(velLat) > 0.06 else { return }
        stopGlide()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.dragLon += self.velLon
            self.camLat = max(-72, min(72, self.camLat + self.velLat))
            self.velLon *= 0.92
            self.velLat *= 0.92
            self.needsDisplay = true
            if abs(self.velLon) < 0.03 && abs(self.velLat) < 0.03 {
                timer.invalidate()
                self.glide = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        glide = t
    }

    private func stopGlide() {
        glide?.invalidate()
        glide = nil
    }

    deinit { glide?.invalidate() }
}

final class GlobeInspector: GlobeView {
    init(frame: NSRect, zoom: CGFloat) {
        super.init(frame: frame)
        self.zoom = zoom
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

// MARK: - 等宽标签
//
// 档案风的编号/数据一律等宽。用系统字体做正文、这里做等宽，
// 两者并置才出"技术文档"的味。
func makeMonoLabel(_ text: String, size: CGFloat = 9.5,
                   weight: NSFont.Weight = .regular,
                   color: NSColor = Palette.dim,
                   align: NSTextAlignment = .left) -> NSTextField {
    let t = NSTextField(labelWithString: text)
    t.font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    t.textColor = color
    t.alignment = align
    t.lineBreakMode = .byTruncatingTail
    t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return t
}

// MARK: - 右侧实时自检栏
//
// ⚠ 这里的每一条都必须是**真实读出来的状态**，不是写死的装饰文本。
//   写死的假数据比没有这一栏更糟 —— 用户会以为它是真的，
//   看到「12 项就绪」结果系统其实坏了，那是在制造错觉。
//   架构上：采集在 Probe 上（一次性取回），显示在自检栏（纯渲染）。
//   采集失败就显示 FAIL + 原因，绝不显示假的 OK。
final class SelfCheckBar: NSView {
    /// 一条自检项
    struct Item {
        let key: String
        let label: String
        let value: String
        let ok: Bool
    }

    var items: [Item] = []
    /// 顶部标题（如 "SELF-CHECK"）
    var heading: String = "SELF-CHECK"
    /// 底部一行摘要
    var summary: String = ""

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        // 纸底 + 发丝边
        Palette.cardBg.setFill()
        NSBezierPath(rect: r).fill()
        Palette.hair.setStroke()
        let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()

        // 标题
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: Palette.accent,
            .kern: 1.8,
        ]
        (heading as NSString).draw(at: NSPoint(x: 12, y: r.maxY - 18), withAttributes: titleAttrs)

        /* 标题右端一个 4pt 的橙点（参考稿 .dsu-checks-h::after）。
           静态点而不是闪烁：这一栏每 2 秒被探针刷新，点本身会跟着重绘 ——
           再加 CSS 那种 blink 只会让"刷新"和"闪烁"两个节奏打架。 */
        let hs = (heading as NSString).size(withAttributes: titleAttrs).width
        Palette.accent.withAlphaComponent(0.9).setFill()
        NSRect(x: 12 + hs + 7, y: r.maxY - 14.5, width: 3.5, height: 3.5).fill()

        // 标题下的细线
        Palette.hairSoft.setStroke()
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: 12, y: r.maxY - 25.5))
        rule.line(to: NSPoint(x: r.maxX - 12, y: r.maxY - 25.5))
        rule.lineWidth = 1
        rule.stroke()

        // 各项：等宽、键左值右
        //   起始高度按卡片实际高度自适应 —— 自检块高度会随主区高度变，
        //   写死 42 会在卡片变矮时把第一项顶到标题上。
        /* 行距按可用高度均分，而不是写死 17pt。
           右侧自检块的高度由左栏总高决定（跟着常用操作+输入+启动动画走），
           固定行距会让 5 条数据挤在顶部，下面空出 200pt —— 那不是留白，是没排。
           上限 44 防止条目很少时散成坐标轴，下限 17 保住不重叠。 */
        let topY = r.maxY - 42
        let bottomY = r.minY + (summary.isEmpty ? 20 : 52)
        let slots = max(items.count, 1)
        /* ⚠ 分母是 slots-1，不是 slots：5 行只有 4 段间隔。
           之前除以 5，等于在表格底部凭空多留一整段行距 ——
           那就是"最后一行与页脚之间那条空带"的来源。 */
        let pitch = min(38, max(17, (topY - bottomY) / CGFloat(max(slots - 1, 1))))
        var y = topY

        /* 空态：探针还没回来（或某次命令失败）时，别留一块纯空的黑框 ——
           按同样的行距画 5 条虚线占位，节奏在、也知道"在等数据"。
           这不是装饰：面板一打开就是空框，看起来像坏了。 */
        if items.isEmpty {
            Palette.hair.withAlphaComponent(0.12).setStroke()
            for k in 0..<5 {
                let ry = topY - CGFloat(k) * pitch
                let dash = NSBezierPath()
                dash.move(to: NSPoint(x: 12, y: ry + 4))
                dash.line(to: NSPoint(x: r.maxX - 12, y: ry + 4))
                dash.lineWidth = 1
                dash.setLineDash([2, 4], count: 2, phase: 0)
                dash.stroke()
            }
            let waitAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular),
                .foregroundColor: Palette.faint,
                .kern: 0.8,
            ]
            /* 标注必须夹在卡内 —— 5 行虚线几乎吃到卡底，
               直接按 topY - 5*pitch 落字会掉到框外，看起来像排版漏了。 */
            let waitY = max(r.minY + 10, topY - 5 * pitch - 14)
            ("PROBING…" as NSString).draw(at: NSPoint(x: 12, y: waitY),
                                          withAttributes: waitAttrs)
        }

        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: Palette.dim,
        ]
        for it in items {
            /* 指示块：正常是橙（"在跑"），异常是红。
               不再用圆点 —— 4pt 的圆在 1x 屏上被抗锯齿抹成灰团，
               方点才有"指示灯"的硬边。 */
            (it.ok ? Palette.accent : Palette.bad).setFill()
            NSRect(x: 12, y: y + 2, width: 3.5, height: 3.5).fill()

            let ls = it.label as NSString
            ls.draw(at: NSPoint(x: 22, y: y), withAttributes: keyAttrs)
            let lw = ls.size(withAttributes: keyAttrs).width

            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.5,
                                                   weight: it.ok ? .medium : .bold),
                // 正常值走墨色：参考稿里"一切正常"是沉默的，彩色只留给异常
                .foregroundColor: it.ok ? Palette.title : Palette.bad,
            ]
            let vs = it.value as NSString
            let vw = vs.size(withAttributes: valAttrs).width
            let vx = r.maxX - 12 - vw
            vs.draw(at: NSPoint(x: vx, y: y), withAttributes: valAttrs)

            /* 引导线：标签与数值之间一条发丝虚线。
               没有它，一行是"两段漂浮的字"；有了它，它是**一行表格** ——
               这是参考稿的检查行最核心的一件事，不是装饰。 */
            let lx0 = 22 + lw + 6, lx1 = vx - 6
            if lx1 > lx0 + 8 {
                Palette.hair.withAlphaComponent(0.32).setStroke()
                let lead = NSBezierPath()
                lead.move(to: NSPoint(x: lx0, y: y + 4))
                lead.line(to: NSPoint(x: lx1, y: y + 4))
                lead.lineWidth = 1
                lead.setLineDash([1, 3], count: 2, phase: 0)
                lead.stroke()
            }

            y -= pitch
        }

        /* 底部摘要：钉在卡片下沿，不跟着最后一行漂。
           相对最后一行画的话，卡片比内容高时会留下一条"谁都不属于"的空带 ——
           那看起来像漏排了一行，而不是留白。钉底之后，多出来的高度
           只会变成"最后一行到页脚"的一段呼吸空间，那是正常的期刊版式。 */
        if !summary.isEmpty {
            let footY = r.minY + 30
            Palette.hairSoft.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 12, y: footY + 12))
            line.line(to: NSPoint(x: r.maxX - 12, y: footY + 12))
            line.lineWidth = 1
            line.stroke()

            let sAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular),
                .foregroundColor: Palette.faint,
                .kern: 0.6,
            ]
            (summary as NSString).draw(at: NSPoint(x: 12, y: footY), withAttributes: sAttrs)
        }
    }
}

// MARK: - 自检数据采集
//
// 一次性把所有真实状态取回来。**不**在 draw 里同步跑进程 ——
// 那会让每次重绘都 fork 几个子进程，面板会卡住。
enum Probe {
    /// 采集结果
    struct Snapshot {
        var doctorOK: Bool = false
        var doctorNote: String = "—"
        var mediaCount: Int = 0
        var appCount: Int = 0
        var bootAnimReady: Bool = false
        var flashRunning: Bool = false
        // 额度 / 项目 / 控制锁（来自 ~/.tiangong/bin/panel-status）
        var dsQuota = "?"
        var dsQuotaOK = false
        var wbQuota = "?"
        var wbQuotaOK = false
        var dbQuota = "?"
        var dbQuotaOK = false
        var wbLive = "?"
        var wbLiveOK = false
        var projectLine = "NO PROJECT"
        var projectOK = false
        var divisionLine = "—"
        var lockLine = "LOCK ?"
        var lockOK = false
        var panelSummary = ""
    }

    /// 跑一条命令，返回 (ok, 首行摘要)
    private static func probe(_ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scriptsDir() + "/macctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (false, "EXEC") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: d, encoding: .utf8) ?? ""
        let first = out.split(separator: "\n").first.map(String.init) ?? ""
        return (p.terminationStatus == 0 && !out.isEmpty, first)
    }

    /// 跑面板数据源（额度 / 项目 / 锁）。失败返回 nil，绝不编造。
    private static func panelStatus() -> [String: Any]? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tiangong/bin/panel-status").path
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj
    }

    /// 采集全部自检项
    static func collect() -> Snapshot {
        var s = Snapshot()

        // ① 环境自检（被动，不移动鼠标、不跑 doctor）
        //    doctor 会移动光标做输入探测；面板自检不能用有副作用的诊断。
        s.doctorOK = AXIsProcessTrusted()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        s.doctorNote = (s.doctorOK ? "CLEAR" : "NO AX") + " · " + fmt.string(from: Date())

        // ② 媒体目录：**启动时绝不读它**
        //
        // ⚠⚠ 这里原来会列 ~/Desktop/闪控 里的文件数。而 ~/Desktop 是 macOS 的
        //   TCC 保护目录（桌面/文稿/下载），面板每次唤起都跑一次自检 → 每次都
        //   触发「"闪控"想要访问你的"桌面"文件夹」的授权框 —— 用户明明点过
        //   "允许"，下次启动照样弹（2026-10-23 用户投诉的原话）。
        //   根因不是授权没记住，而是**启动路径根本不该碰受保护目录**。
        //   现在：启动时不访问，数量由用户真正打开目录时再算（-1 = 未知）。
        s.mediaCount = -1

        // ③ 已安装应用数（LaunchServices 数据库）
        s.appCount = NSWorkspace.shared.runningApplications.count

        // ④ 开场动画资源是否就位
        let webDir = scriptsDir() + "/bootanim/web"
        let need = ["splash.js", "splash.css", "brand.js", "index.html"]
        s.bootAnimReady = need.allSatisfy {
            FileManager.default.fileExists(atPath: webDir + "/" + $0)
        }

        // ⑤ 闪控自身进程
        s.flashRunning = true   // 面板能显示出来本身就说明闪控在跑

        // ⑥ 额度 / 当前项目 / 分工 / 控制锁
        if let st = panelStatus() {
            if let quotas = st["quotas"] as? [String: Any] {
                func quota(_ key: String) -> (String, Bool) {
                    guard let item = quotas[key] as? [String: Any] else { return ("?", false) }
                    return (item["value"] as? String ?? "?", item["ok"] as? Bool ?? false)
                }
                let ds = quota("deepseek"); s.dsQuota = ds.0; s.dsQuotaOK = ds.1
                let wb = quota("workbuddy"); s.wbQuota = wb.0; s.wbQuotaOK = wb.1
                let db = quota("doubao"); s.dbQuota = db.0; s.dbQuotaOK = db.1
            }
            if let wb = st["wb_live"] as? [String: Any] {
                s.wbLive = wb["value"] as? String ?? "?"
                s.wbLiveOK = wb["ok"] as? Bool ?? false
            }
            if let project = st["project"] as? [String: Any] {
                let label = project["label"] as? String ?? "?"
                let value = project["value"] as? String ?? ""
                s.projectLine = "\(label) \(value)"
                s.projectOK = project["ok"] as? Bool ?? false
            }
            s.divisionLine = st["division"] as? String ?? "—"
            if let lock = st["lock"] as? [String: Any] {
                s.lockLine = lock["value"] as? String ?? "?"
                s.lockOK = lock["ok"] as? Bool ?? false
            }
            s.panelSummary = st["summary"] as? String ?? ""
        } else {
            s.panelSummary = "NO STATUS"
        }

        return s
    }

    /// 采集结果 → 自检栏的行
    static func items(from s: Snapshot) -> [SelfCheckBar.Item] {
        [
            .init(key: "ds", label: "DEEPSEEK", value: s.dsQuota, ok: s.dsQuotaOK),
            .init(key: "wb", label: "WORKBUDDY", value: s.wbQuota, ok: s.wbQuotaOK),
            .init(key: "wblive", label: "WB LIVE", value: s.wbLive, ok: s.wbLiveOK),
            .init(key: "db", label: "DOUBAO", value: s.dbQuota, ok: s.dbQuotaOK),
            .init(key: "project", label: "PROJECT", value: s.projectLine, ok: s.projectOK),
            .init(key: "division", label: "DIVISION", value: s.divisionLine, ok: true),
            .init(key: "lock", label: "CTRL LOCK", value: s.lockLine, ok: s.lockOK),
            .init(key: "env", label: "ENV", value: s.doctorNote, ok: s.doctorOK),
        ]
    }
}


/// 地球水印：铺在面板最底层的一枚超淡地球，纯装饰。
///
/// 用户 2026-10-25 的要求：「地球可以作背景水印，但不能看不清面板、不能吃掉交互」。
/// 三条设计：
///   ① `hitTest` 永远返回 nil —— 它盖在最底层，但**绝不**参与命中；
///      右侧那张可拖拽的地球卡完全不受影响，拖拽/惯性照旧。
///   ② 透明度 0.10 —— 只在卡片之间的缝隙里隐约见到，压在卡片下面读不出来。
///   ③ 转动极慢（主地球的 1/5 速率）—— 背景动了会抢注意力，几乎静止才对。
final class GlobeWatermark: GlobeView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
