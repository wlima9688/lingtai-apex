/* ============================================================================
 * dsh-startup-screen — 启动动画运行时（浏览器端，零依赖）
 * ----------------------------------------------------------------------------
 * 由 Host 半侧注入到 index.html，在 React 应用挂载之前接管首屏：
 *
 *   第一幕  黑幕 + 五角星主标识／"方寸山矩阵终端"／"macOS"（字距收紧 + 扫光）
 *   过场    过曝洗白（黑 → 灰 → 暖白底板），对应参考片的硬切洗白
 *   第二幕  暖白"技术档案"底板：左上品牌块左→右擦出、右下 POWERED BY、进度条
 *   序列    需要访问许可 → 身份资料确认 → 接收访问需求 → 读取完毕 → 验证通过
 *           → 欢迎 <身份名称> 访问；每步中文大字 + 英文等宽字幕 + 底部长句日志
 *   交互    第 1、2 步等待用户确认（按钮 / Enter / 空格 / 点击），可跳过
 *   终幕    WELCOME TO / [WORKBUDDY HARNESS] / 机芯标识，青红色散故障后揭幕
 *
 * 配置来自 window.__DSH_STARTUP__（Host 侧注入），也可用
 * window.__DSH_STARTUP_API__.replay() 重播。
 * ========================================================================== */
(function () {
  'use strict'

  if (window.__DSH_STARTUP_LOADED__) return
  window.__DSH_STARTUP_LOADED__ = true

  var ROOT_ID = 'dsh-startup-root'

  /* ── 品牌标识路径（见 brand.js）────────────────────────────────────── */
  /* WorkBuddy 标识路径在 brand.js 中定义（独立文件，便于单独预览与替换）。
   ⚠ 这里只做引用，路径本身不内联 —— 68KB 的鲸鱼路径换成 4 行品牌路径，
     这个文件才读得下去。 */
  var WHALE_PATH = window.__WB_BRAND_PATH__ || WB_PATH

  /* ── 五角星几何（第一幕主标识，2026-10-22 用户指定）──────────────────
     viewBox 0 0 60 60：圆心 (30,30)，外接圆 R=25.5，凹点半径 R×0.382≈9.74，
     外顶点自正上方起顺时针 -90°/-18°/54°/126°/198°，凹点与外顶点错开 36°。
     R 的演进：20 太小 → 23.2（金色折面版）→ 25.5（2026-10-22 用户要求
     "比例大一点"）：星径占画布 85%，与外环 r=29.0 留 3.5 单位 HUD 紧配缝隙。
     2026-10-22 深夜改版：用户参考图要求立体折面；再往后用户要求
     **黑灰配色**（"符合整个板块的设计"—— 面板是近黑 #0b0b0c + 发丝线的
     工业档案风，金色那种珠宝感不合群，石墨灰才是一家人）。 */
  var STAR = (function () {
    var R = 25.5, r = R * 0.382
    var outer = [], inner = []
    for (var i = 0; i < 5; i++) {
      var ao = (-90 + i * 72) * Math.PI / 180
      var ai = (-54 + i * 72) * Math.PI / 180
      outer.push([30 + R * Math.cos(ao), 30 + R * Math.sin(ao)])
      inner.push([30 + r * Math.cos(ai), 30 + r * Math.sin(ai)])
    }
    function pt(p) { return p[0].toFixed(2) + ',' + p[1].toFixed(2) }
    /* 整星轮廓：外尖与凹点交替（挤出层 / 裁切 / 旧引用共用） */
    var d = 'M ' + pt(outer[0])
    for (var j = 0; j < 5; j++) d += ' L ' + pt(inner[j]) + ' L ' + pt(outer[(j + 1) % 5])
    /* 第 i 臂扇面：外顶点 + 左右凹点（分面着色的基本单元） */
    function arm(i) {
      return 'M ' + pt(outer[i]) + ' L ' + pt(inner[i]) + ' L ' + pt(inner[(i + 4) % 5]) + ' Z'
    }
    /* 中心五边形：五个凹点（立体星的"芯舱"底板） */
    var core = 'M ' + pt(inner[0])
    for (var k = 1; k < 5; k++) core += ' L ' + pt(inner[k])
    return { R: R, outer: outer, inner: inner, path: d + ' Z', arm: arm, core: core + ' Z' }
  })()
  /* 兼容名：整星轮廓路径（预览页与自检脚本按这个名字引用） */
  var STAR_PATH = STAR.path

  /* ── 默认配置（与 Host 侧 lib/index.js 的 DEFAULTS 保持一致）──────────── */
  var DEFAULTS = {
    enabled: true,
    mode: 'session',            // always | session | daily
    theme: 'light',             // light | dark
    speed: 1,
    requireInteraction: true,   // 第 1、2 步等待用户确认
    // ⚠⚠ 2026-10-22 用户拍板：每个场景之间都要等 Space/Enter 才进下一幕，
    //   「不是自己立刻动；但如果 3 秒内没有人交互，自动进入下一个界面」。
    //   这两个值就是那条交互模型的开关与超时，wblaunch.swift 侧同名单射注入。
    sceneGate: true,
    /* ⚠⚠ 这三条原来**根本没定义**。`bgm.base()` 里 clamp01(undefined,0,1) 返回 0，
       于是 on() 恒为 false —— 整条配乐轨从来没被创建过，而且完全不报错。
       接入配乐时最容易背锅的就是这里。 */
    bgm: true,
    /* ── 混音比例：用户给的 5 : 3 : 2（人声 : 配乐 : 音效）─────────────
       ⚠ 这是**感知权重**，不是线性振幅比。直接按 5:3 摆，音乐会压住人声：
         音乐是连续宽频的，同样响度下比人声"占地方"得多。
       实测过一遍，换算到 dBFS 之后取这一组：
           人声 峰值 -8 dBFS ｜ 配乐 RMS -28 dBFS ｜ 音效 峰值 -19 dBFS
         人声比配乐高约 7dB（不是 4.4dB），音效比人声低 11dB。
         要整体加减，只改下面这三个权重。 */
    mix: { voice: 5, bgm: 3, sfx: 2 },
    /* ⚠ 0.11 → 0.16 → 0.19 → 0.26：前三版第一幕都被反馈"听不见"。
       配合两件事一起才成立：
         · 文件层：开头 10 秒已做 +4.2dB 抬升（曲子开头本来就比中段低 3dB）；
         · 闪避层：0.38 → 0.28，抬得多、压得也深 —— **闪避后的绝对电平不变**，
           所以人声清晰度不受影响，只是"没人声的时候配乐更靠前"。
       -8.2dBFS(文件) -11.7dB(0.26) ≈ -20dBFS；闪避后 ×0.28 ≈ -31dBFS。 */
    bgmVolume: 0.26,
    bgmDuck: true,      /* 人声进来压到 28%（约 -11dB）。
                           配乐整体抬高之后，闪避同步加深 —— 闪避后的**绝对电平**保持不变，
                           所以人声清晰度不会被这次抬升吃掉。 */
    gateTimeoutMs: 5333,   /* 90 BPM × 2 小节 = 5333ms：让每一幕切换都落在小节线上 */
    allowSkip: true,
    sound: true,                // 界面音效（WebAudio 合成，无音频文件）
    soundVolume: 0.5,
    voice: true,                // 女声播报
    voiceLang: 'en',            // en | zh | both
    voiceName: '',              // '' = 自动挑女声（见 FEMALE_HINTS）
    voiceRate: 0.88,            // 电影旁白档：比朗读慢，字与字之间才有重量
    voicePitch: 0.85,           // 压低音调，深沉的 AI 女声
    voiceVolume: 0.9,
    voiceCue: true,             // 念台词前的一声轻提示
    sfx: 'audio',               // audio=真素材（用户音频里抠的音效）/ synth=现场合成
    voiceSource: 'asset',       // asset=优先用真声素材 / tts=全部 TTS 合成
    voiceLead: 240,             // 提示音之后留一小段空白再开口
    identity: '温昼',           // ← 设置页可改的"身份名称"（用户名）
    identityId: 'LS-WZ-0961-01', // 用户编号：横杠是格式的一部分，清洗规则不得去掉
    accessLevel: '3',
    brand1: 'MacOS',
    brand2: 'BUILT ON APPLE SILICON',
    brand3a: 'SYSTEM',
    brand3b: 'ASSISTANT',
    orgZh: '方寸山矩阵终端',
    orgEn: 'MacOS',
    orgSub: 'APPLE SYSTEM ASSISTANT',
    welcomeBox: 'MacOS',
    footer: 'DESIGNED BY APPLE IN CALIFORNIA',
    accent: '#ff7500',
    glitchA: '#ff3b30',
    glitchB: '#2971b8'
  }

  /* ── 序列脚本：中文主字 + 英文等宽字幕 + 底部日志 ───────────────────────
     `say` 是专门给语音播报用的自然语句（照着参考片里女声念状态行的节奏，
     正好卡在各自文字出现的时间点上）。 */
  /* ── 序列脚本 ──────────────────────────────────────────────────────────
     文字与真声素材一一对应（来自你给的音频）：
       line-1.mp3 = V1 需要访问许可
       line-2.mp3 = V2 身份资料确认
       line-3.mp3 = V4 接收访问需求
       line-4.mp3 = V5 开始读取权限
       line-5.mp3 = V6 读取完毕 · 核验通过
     V3 是用户名字独白，按你的要求不用。
     `say` 是素材拿不到时的 TTS 兜底文本；`audio` 是素材文件名（不含扩展名）。 */
  var STEPS = [
    {
      zh: '需要访问许可',
      en: 'ACCESS PERMISSION REQUIRED',
      say: 'Access permission required.',
      audio: 'line-1',
      log: '等待用户授权…',
      logEn: 'AWAITING OPERATOR CONSENT',
      badge: 'AUTHORIZATION',
      action: 'grant',
      btnZh: '授予访问权限',
      btnEn: 'GRANT ACCESS',
      hold: 900,
      progress: 0.34
    },
    {
      zh: '身份资料确认',
      en: 'IDENTITY VERIFICATION',
      say: 'Identity verification.',
      audio: 'line-2',
      log: '核对身份资料…',
      logEn: 'MATCHING OPERATOR RECORD',
      badge: 'IDENTITY',
      action: 'confirm',
      btnZh: '确认身份',
      btnEn: 'CONFIRM IDENTITY',
      hold: 700,
      progress: 0.5
    },
    {
      zh: '接收访问需求',
      en: 'ACCESS REQUEST RECEIVED',
      say: 'Access request received.',
      audio: 'line-3',
      log: '接收访问需求，建立会话通道…',
      logEn: 'HANDSHAKE ESTABLISHED',
      badge: 'REQUEST',
      action: 'auto',
      hold: 1200,
      progress: 0.66,
      assembleLogo: true
    },
    {
      zh: '开始读取权限',
      en: 'PERMISSION READ STARTED',
      say: 'Beginning permission read.',
      audio: 'line-4',
      log: '开始读取权限，索引工作区与会话…',
      logEn: 'READING PERMISSION SET',
      badge: 'READ',
      action: 'auto',
      hold: 1200,
      progress: 0.8,
      hex: true
    },
    {
      zh: '读取完毕 · 核验通过',
      en: 'READ COMPLETE · VERIFIED',
      say: 'Read complete. Verification passed.',
      audio: 'line-5',
      log: '读取完毕，核验通过，权限已授予',
      logEn: 'PERMISSION AUTHORIZED',
      badge: 'VERIFY',
      action: 'auto',
      hold: 1600,
      progress: 0.93,
      reticle: true
    }
  ]

  function cfg() {
    /* ⚠ 移植改动：原来是 window.__DSH_STARTUP__（DSH 插件宿主注入）。
       现在由独立的 macOS 启动器注入 window.__WB_BOOT_CONFIG__。
       ⚠⚠ 两处必须**同时**改 —— 只改三元表达式的真值分支而忘了条件判断，
       会变成「条件检查旧变量、取值用新变量」→ raw 恒为 {} →
       **所有配置静默退回 DEFAULTS**（theme 退回 light）→ 深色底上出现黑字，
       整屏看起来像"没渲染"。这类半截替换最难查，因为它不报错。 */
    var src = (typeof window.__WB_BOOT_CONFIG__ === 'object' && window.__WB_BOOT_CONFIG__)
      || (typeof window.__DSH_STARTUP__ === 'object' && window.__DSH_STARTUP__)
      || {}
    var raw = src
    var out = {}
    for (var k in DEFAULTS) if (Object.prototype.hasOwnProperty.call(DEFAULTS, k)) out[k] = DEFAULTS[k]
    for (var k2 in raw) {
      if (Object.prototype.hasOwnProperty.call(raw, k2) && raw[k2] !== undefined && raw[k2] !== null) {
        out[k2] = raw[k2]
      }
    }
    out.speed = Math.min(3, Math.max(0.35, Number(out.speed) || 1))
    out.identity = String(out.identity || DEFAULTS.identity).slice(0, 48)
    /* 用户编号保留横杠（LS-WZ-0961-01 的横杠是格式的一部分，洗掉就不对了）；
       长度上限放到 24 —— 13 字符的编号原来的 slice(0,12) 会拦腰截断。
       其余非字母数字字符仍然剥掉（防配置里带进奇怪字符）。 */
    out.identityId = String(out.identityId || out.identity).toUpperCase().replace(/[^A-Z0-9-]/g, '').slice(0, 24)
    if (!out.identityId) out.identityId = 'OPERATOR'
    return out
  }

  var C = cfg()

  /* 宿主采来的**真实事实**（批次 3）。取不到就整块空对象，界面显示 "—" ——
     不假装有数据，也不会因为某个服务缺失而报错。 */
  var F = (C.facts && typeof C.facts === 'object') ? C.facts : {}
  function factText(v) {
    return (v === null || v === undefined || v === '') ? '—' : String(v)
  }
  /** 短指纹：宿主给的那个；没有就一串破折号，绝不留空 */
  function factHash() { return F.hash ? String(F.hash) : '--------' }

  /** 重播：把运行时脚本重新挂一次（配置/身份名称改动后 preview 用它）。 */
  function injectSelf() {
    /* 重播（设置页「立即预览」/ 改完配置重放）：先把**这一轮**的声源收掉。
       脚本被重新注入后是一份全新的模块实例，BGM 的 audio 元素挂在旧闭包里，
       不在这里叫停就会和新实例的那一轨叠着放。
       bgm / voice 都是 var 提升的同一作用域变量，这里是运行期调用，不会是 undefined；
       仍然包 try 是因为重播路径绝不允许抛。 */
    try { bgm.stop(0) } catch (e) { /* 重播不许抛 */ }
    try { voice.stop() } catch (e) { /* 同上 */ }
    try { stopField() } catch (e) { /* 同上 */ }
    try { if (ui.traceTimer) { clearInterval(ui.traceTimer); ui.traceTimer = null } } catch (e) { /* 同上 */ }
    window.__DSH_STARTUP_LOADED__ = false
    var old = document.getElementById(ROOT_ID)
    if (old && old.parentNode) old.parentNode.removeChild(old)
    window.__DSH_STARTUP_SKIP__ = false
    var s = document.createElement('script')
    /* 正式运行时由 Host 路由提供（加时间戳绕开缓存）；
       离线预览页会把相对路径写进 __DSH_STARTUP_SCRIPT_URL__，file:// 下不加查询串。 */
    if (window.__WB_BOOT_SCRIPT_URL__) {
      s.src = window.__WB_BOOT_SCRIPT_URL__
    } else {
      s.src = 'splash.js?t=' + Date.now()
    }
    document.head.appendChild(s)
  }

  /* Host 侧的首屏兜底脚本已经判定"这次不播"（未启用 / 本会话已播 / 今日已播）：
     这里不再建 DOM，但仍然暴露 API，方便设置页按需重播。 */
  if (window.__DSH_STARTUP_SKIP__ === true) {
    window.__DSH_STARTUP_API__ = {
      replay: injectSelf,
      skip: function () {},
      finish: function () {},
      config: C
    }
    return
  }

  /* 最后一道保险：无论前面哪一步抛异常，都不许把用户留在黑幕里 */
  setTimeout(function () {
    try {
      var r = document.getElementById(ROOT_ID)
      if (r && r.classList && r.classList.contains('dsu-boot')) {
        if (r.parentNode) r.parentNode.removeChild(r)
        document.documentElement.classList.remove('dsu-lock')
        if (document.body) document.body.style.overflow = ''
        window.__DSH_STARTUP_FAILED__ = true
      }
    } catch (e) { /* 兜底本身不许再抛 */ }
  }, 9000)

  /* ── 小工具 ───────────────────────────────────────────────────────────── */
  function el(tag, cls, text) {
    var n = document.createElement(tag)
    if (cls) n.className = cls
    if (text != null) n.textContent = text
    return n
  }

  /* hex 颜色按比例压暗（折面星的各面沿光向微变就靠它，省一半色板）。
     入参只接受 '#rrggbb'；返回 rgb() 字符串（SVG stop-color 认）。 */
  function shade(hex, k) {
    var n = parseInt(hex.slice(1), 16)
    return 'rgb(' + Math.round(((n >> 16) & 255) * k) + ',' +
                   Math.round(((n >> 8) & 255) * k) + ',' +
                   Math.round((n & 255) * k) + ')'
  }

  /* 每个 svgShape 实例都要一个独立的渐变 id，否则同页多个 SVG 会互相引用错 */
  var metalSeq = 0

  /* 金属质感标识：实心底 + 同形状渐变高光。
     ⚠ 2026-10-22 起五角星**不再**走这条路 —— 它有自己的"挤出 + 分面"
     立体处理（见 svgStar），只有鲸鱼（第二幕 / 终幕 logo）还用这一套。 */
  function svgShape(d, cls) {
    var ns = 'http://www.w3.org/2000/svg'
    var svg = document.createElementNS(ns, 'svg')
    svg.setAttribute('viewBox', '0 0 50 50')
    svg.setAttribute('aria-hidden', 'true')
    if (cls) svg.setAttribute('class', cls)

    /* 金属感靠「实心底 + 一层白/黑渐变高光」叠出来，**不能**把整个形状调半透明。
       第一版用 stop-opacity 给 currentColor 做深浅，实机截图证明那是"图标褪色"：
       浅色主题下深色形状被调淡就是发灰、无神，完全不像金属。
       所以：本体路径保持 currentColor 实心，再叠一条同形状的渐变层做镜面反光。 */
    var gid = 'dsu-metal-' + (++metalSeq)
    var defs = document.createElementNS(ns, 'defs')
    var lg = document.createElementNS(ns, 'linearGradient')
    lg.setAttribute('id', gid)
    lg.setAttribute('x1', '0.10'); lg.setAttribute('y1', '0')
    lg.setAttribute('x2', '0.62'); lg.setAttribute('y2', '1')
    var stops = [
      [0, '#ffffff', '0.24'],      /* 左上打高光（0.4 在浅色主题下太抢，会盖掉剪影） */
      [0.40, '#ffffff', '0'],
      [0.62, '#000000', '0'],
      [1, '#000000', '0.20']       /* 右下压阴影 */
    ]
    for (var i = 0; i < stops.length; i++) {
      var st = document.createElementNS(ns, 'stop')
      st.setAttribute('offset', String(stops[i][0]))
      st.setAttribute('stop-color', stops[i][1])
      st.setAttribute('stop-opacity', stops[i][2])
      lg.appendChild(st)
    }
    defs.appendChild(lg)
    svg.appendChild(defs)

    var p = document.createElementNS(ns, 'path')
    p.setAttribute('d', d)
    p.setAttribute('fill-rule', 'nonzero')
    svg.appendChild(p)   /* 实心底：颜色由 CSS 的 fill: currentColor 继承 */

    var shine = document.createElementNS(ns, 'path')
    shine.setAttribute('d', d)
    shine.setAttribute('fill-rule', 'nonzero')
    shine.style.fill = 'url(#' + gid + ')'
    svg.appendChild(shine)
    return svg
  }

  function svgWhale(cls) { return svgShape(WHALE_PATH, cls) }

  /* 五角星标识：第一幕黑幕主 logo（方寸山矩阵终端）。
     2026-10-22 深夜两连改：① 用户发来参考图（金色折面五角星）——
     "你的立体不是我想要的"。参考图的语言是 **折面宝石**，不是渐变贴图：
       ⑤ 旋转层  外环虚线 + 一道亮弧扫过 + 内环细逆时针（HUD 雷达感）
       ④ 准星层  四角 L 型标记，把画面"锁定"在取景框里
       ③ 折面层  每个臂是一条"帐篷棱"：沿 尖角→圆心 的棱线折起，左右
                  两个半面一明一暗；整星拆成 15 个平面（10 个臂半面 +
                  5 个谷面），每面平涂渐变（沿光向只微变 12%）
       ② 棱线层  尖角→圆心 5 道亮描线（帐篷棱受光），外轮廓一道
                  上亮下隐的镀边
       ① 核心层  谷底中心一点亮核（星的心脏）+ 斜切高光
     ② 用户再要求 **黑灰配色**："符合整个板块的设计" —— 闪控面板是
     近黑 #0b0b0c + 发丝线的工业档案风，金色折面的珠宝感在这套语言里
     是外来户；石墨灰（冷调，b 略大于 r）才和白色 HUD、发丝线是一家人。
     受光面到暗面的跨度仍然拉开（折面的立体感靠明暗差，不靠色相），
     谷面压最沉代表"凹下去"。光源统一左上 45°。
     整体挂在 .dsu-star-body 上，CSS 做极缓慢的 rotateY 倾斜；
     HUD 双环保持正圆锁死 —— 环是"全息取景框"，星是悬浮在框前的实体徽章。
     ⚠ transform-box: fill-box 必须写在 CSS 里：SVG 子元素的 transform-origin
       默认是 SVG 画布原点，不修正的话环会绕左上角公转而不是自转。
     ⚠ 渐变 / 裁切 id 必须带序号：同页多个 SVG 实例会互相引用错。 */
  /* 三种变体共用同一套 STAR 几何（R=25.5 的 60×60 画布）、同一个光源方向，
     只是"画法"不同 —— 这样三幕的标识是同一颗星的三副样子，不是三个图标：
       'gem'    折面 + 亮棱线（第一幕，122px，黑幕上要当主体）
       'wire'   只画结构线（中段，84px，压在暖白底板上，面一多就糊）
       'emboss' 折面但不要棱线、镀边加厚（终幕，76px，读作一枚压铸徽章） */
  function svgStar(cls, variant) {
    var style = variant || 'gem'
    var ns = 'http://www.w3.org/2000/svg'
    var svg = document.createElementNS(ns, 'svg')
    svg.setAttribute('viewBox', '0 0 60 60')
    svg.setAttribute('aria-hidden', 'true')
    if (cls) svg.setAttribute('class', cls)

    function P(d, extra) {
      var p = document.createElementNS(ns, 'path')
      p.setAttribute('d', d)
      for (var k in extra) if (Object.prototype.hasOwnProperty.call(extra, k)) {
        if (k === 'style') p.style[k] = extra[k]
        else p.setAttribute(k, extra[k])
      }
      return p
    }
    function C(cx, cy, r, extra) {
      var c = document.createElementNS(ns, 'circle')
      c.setAttribute('cx', String(cx)); c.setAttribute('cy', String(cy))
      c.setAttribute('r', String(r))
      for (var k in extra) if (Object.prototype.hasOwnProperty.call(extra, k)) {
        if (k === 'style') c.style[k] = extra[k]
        else c.setAttribute(k, extra[k])
      }
      return c
    }
    var seq = ++metalSeq
    var gid = 0
    function nid() { return 'dsu-st' + seq + '-' + (++gid) }
    /* STAR 的顶点数组是 [x,y]，拼 path 时统一走这里（两位小数够用，
       ViewBox 才 60 单位，多给的小数位只会让路径字符串变长）*/
    function pt(p) { return p[0].toFixed(2) + ',' + p[1].toFixed(2) }
    /* 把既有石墨色板的明度阶梯换算成"同一支墨"的浓淡。
       emboss 变体不用写死的灰，全走 currentColor + fill-opacity：
       中段/终幕的标识压在暖白底板上（墨是深的），第一幕压在黑幕上（墨是浅的），
       写死 #c9d2db 这类中间灰，两套底里必有一套要糊。 */
    function inkOp(hex) {
      var r = parseInt(hex.slice(1, 3), 16) / 255
      var g = parseInt(hex.slice(3, 5), 16) / 255
      var b = parseInt(hex.slice(5, 7), 16) / 255
      var L = 0.2126 * r + 0.7152 * g + 0.0722 * b
      return Math.round(Math.max(0.26, Math.min(0.98, 0.16 + L * 0.86)) * 100) / 100
    }
    /* 线性渐变（用户空间坐标）*/
    function LG(x1, y1, x2, y2, stops) {
      var g = document.createElementNS(ns, 'linearGradient')
      g.setAttribute('id', nid())
      g.setAttribute('gradientUnits', 'userSpaceOnUse')
      g.setAttribute('x1', String(x1)); g.setAttribute('y1', String(y1))
      g.setAttribute('x2', String(x2)); g.setAttribute('y2', String(y2))
      for (var i = 0; i < stops.length; i++) {
        var st = document.createElementNS(ns, 'stop')
        st.setAttribute('offset', String(stops[i][0]))
        st.setAttribute('stop-color', stops[i][1])
        if (stops[i][2] != null) st.setAttribute('stop-opacity', String(stops[i][2]))
        g.appendChild(st)
      }
      return g
    }
    /* 径向渐变（用户空间坐标）*/
    function RG(cx, cy, r, stops) {
      var g = document.createElementNS(ns, 'radialGradient')
      g.setAttribute('id', nid())
      g.setAttribute('gradientUnits', 'userSpaceOnUse')
      g.setAttribute('cx', String(cx)); g.setAttribute('cy', String(cy))
      g.setAttribute('r', String(r))
      for (var i = 0; i < stops.length; i++) {
        var st = document.createElementNS(ns, 'stop')
        st.setAttribute('offset', String(stops[i][0]))
        st.setAttribute('stop-color', stops[i][1])
        if (stops[i][2] != null) st.setAttribute('stop-opacity', String(stops[i][2]))
        g.appendChild(st)
      }
      return g
    }
    var defs = document.createElementNS(ns, 'defs')
    svg.appendChild(defs)
    function def(g) { defs.appendChild(g); return g }

    /* ── ⓪ 静态辉光（2026-10-22 性能改版：drop-shadow filter → 渐变圆）──
       原来辉光是 CSS filter: drop-shadow(14px+38px 两层模糊)。实测它是
       第一帧率杀手：星体在 .dsu-star-body 上做 rotateY 倾斜，filter 输入
       每帧变，WebKit 每帧重新光栅化两层高斯模糊 —— 与全屏 canvas 粒子场
       叠加时互相抢光栅资源，整页从 60fps 掉到 55fps（p95 28ms）。
       改成 SVG 内的静态 radialGradient 圆：光栅一次后缓存，星体倾斜/
       双环旋转都不触碰它（辉光在 .dsu-star-body 外层，只画一次）。
       alpha 是实测校准的：0.10/0.055 那版截图里几乎看不见（太淡），
       0.17/0.10 接近原 filter 的柔和光晕又不抢戏。 */
    var glowG = def(RG(30, 30, 29.0, [
      [0, '#becddc', '0.17'],
      [0.45, '#8fa3ba', '0.10'],
      [1, '#8fa3ba', '0']
    ]))
    svg.appendChild(C(30, 30, 29.0, { fill: 'url(#' + glowG.getAttribute('id') + ')' }))

    /* ── ⑤ 旋转双环（保留；半径随星体放大外扩，给挤出角让位）── */
    svg.appendChild(C(30, 30, 29.0, {
      fill: 'none', stroke: '#ffffff', 'stroke-opacity': '0.50',
      'stroke-width': '0.6', 'stroke-dasharray': '3 2.4',
      'class': 'dsu-orbit'
    }))
    /* 亮弧：同环上一道短 dash，跟外环同速同向 —— 雷达扫描的光点。
       dasharray '7 175'：7+175=182 ≈ 2π×29.0，一圈恰好一道弧。 */
    svg.appendChild(C(30, 30, 29.0, {
      fill: 'none', stroke: '#ffffff', 'stroke-opacity': '0.95',
      'stroke-width': '1.2', 'stroke-dasharray': '7 175',
      'stroke-linecap': 'round', 'class': 'dsu-orbit'
    }))
    /* 内环：更细更淡，反向转（双环异向 = 精密仪器感）*/
    svg.appendChild(C(30, 30, 26.3, {
      fill: 'none', stroke: '#ffffff', 'stroke-opacity': '0.26',
      'stroke-width': '0.4', 'stroke-dasharray': '0.7 3.6',
      'class': 'dsu-orbit dsu-orbit-rev'
    }))

    /* ③ 四角 L 型准星：对角线方向距中心 31，臂长 3.4（45° 方位）*/
    var t = 21.92, arm = 3.4
    var corners = [[1, 1], [1, -1], [-1, 1], [-1, -1]]
    for (var i = 0; i < corners.length; i++) {
      var sx = corners[i][0], sy = corners[i][1]
      var ox = 30 + sx * t, oy = 30 + sy * t
      svg.appendChild(P('M ' + ox + ' ' + (oy - sy * arm) +
                        ' L ' + ox + ' ' + oy +
                        ' L ' + (ox - sx * arm) + ' ' + oy, {
        fill: 'none', stroke: '#ffffff', 'stroke-opacity': '0.55',
        'stroke-width': '0.7', 'stroke-linecap': 'square'
      }))
    }

    /* ── ③ 折面层：15 个平面搭出"帐篷棱"星体 ──────────────────────────
       参考图语言：每个臂沿 尖角→圆心 的棱线折起，左右半面一明一暗；
       中心是凹陷的星形谷底。于是把整星拆成：
         · 10 个臂半面：(O_i, I_i, C) 与 (O_i, I_{i-1}, C)
         · 5 个谷面：  (C, I_i, I_{i+1}) —— 中心五边形拆成的三角
       每个面一个平涂渐变（沿光向只微变 12%）—— 低多边形宝石的标准语言，
       "每个面是平的"正是立体感的来源，渐变给大了就回到平面贴图。
       明度由半面外缘朝向与光源（左上 45°，单位向量 (-0.707,-0.707)）
       的点积定档（点积 = -0.707×(cosθ+sinθ)，θ = 外缘中点方向角）：
         臂4右 +0.99 > 臂0左 +0.89 > 臂4左 +0.71 > 臂0右 +0.45
         > 臂3右 +0.16 > 臂1左 -0.16 > 臂3左 -0.45 > 臂1右 -0.71
         > 臂2右 -0.89 > 臂2左 -0.99
       谷面整体压暗一档（凹下去的底面受光少），只做朝向微调。 */
    var body = document.createElementNS(ns, 'g')
    body.setAttribute('class', 'dsu-star-body')
    var O = STAR.outer, I = STAR.inner

    /* ── 变体 wire：只画结构，不画面 ──────────────────────────────
       外轮廓 + 凹点五边形 + 5 道棱线 + 中心点。
       中段标识只有 84px，15 个折面在这个尺寸会揉成一团灰 ——
       线框反而保留了"星"的识别度，也和第一幕的实体折面形成对位。 */
    if (style === 'wire') {
      body.appendChild(P(STAR.path, {
        fill: 'none', stroke: 'currentColor', 'stroke-opacity': '0.80',
        'stroke-width': '0.7', 'stroke-linejoin': 'round'
      }))
      body.appendChild(P(STAR.core, {
        fill: 'none', stroke: 'currentColor', 'stroke-opacity': '0.34',
        'stroke-width': '0.45'
      }))
      for (var w = 0; w < 5; w++) {
        body.appendChild(P('M ' + pt(O[w]) + ' L 30,30', {
          fill: 'none', stroke: 'currentColor', 'stroke-opacity': '0.52',
          'stroke-width': '0.42', 'stroke-linecap': 'round'
        }))
      }
      var wg = def(RG(30, 30, 3.0, [[0, 'currentColor', '0.85'], [1, 'currentColor', '0']]))
      body.appendChild(C(30, 30, 3.0, { fill: 'url(#' + wg.getAttribute('id') + ')' }))
      body.appendChild(C(30, 30, 0.95, { fill: 'currentColor' }))
      svg.appendChild(body)
      return svg
    }

    /* 底面厚度：整星轮廓下沉一档（0.8,1.0）的近黑石墨底沿 —— 只露右下一丝边，
       让悬浮的星有"实体件"的份量感。偏移再大就会变成"两颗星叠着"》
       （(2.8,3.4) 那版实测翻车，见 git 历史）。 */
    body.appendChild(P(STAR.path, { transform: 'translate(0.8,1.0)', fill: '#1c2126' }))

    /* 谷面：中心五边形拆 5 三角，最深的一族石墨（下标按 I_i→I_{i+1}）。
       2026-10-22 黑灰改版：谷面代表"凹下去的底面"，必须比最暗的臂半面
       （#555e68）还要沉一档，但仍在黑幕上读得出来（最暗 #383f47）。
       金色版在这里栽过一次：暗面压成黑棕就丢了材质。 */
    var VALLEY = ['#4a525b', '#383f47', '#41484f', '#545c66', '#4e565f']
    for (var v = 0; v < 5; v++) {
      if (style === 'emboss') {
        body.appendChild(P('M 30,30 L ' + pt(I[v]) + ' L ' + pt(I[(v + 1) % 5]) + ' Z', {
          fill: 'currentColor', 'fill-opacity': String(inkOp(VALLEY[v]) * 0.85)
        }))
        continue
      }
      var vg = def(LG(26, 24, 34, 36, [
        [0, VALLEY[v]], [1, shade(VALLEY[v], 0.8)]
      ]))
      body.appendChild(P('M 30,30 L ' + pt(I[v]) + ' L ' + pt(I[(v + 1) % 5]) + ' Z', {
        fill: 'url(#' + vg.getAttribute('id') + ')'
      }))
    }

    /* 臂半面：PLANE_L 含 I_{i-1}（臂的逆时针半面），PLANE_R 含 I_i。
       2026-10-22 黑灰改版：整套石墨灰，冷调（b 略大于 r）—— 和白色
       HUD、发丝线、面板近黑底 #0b0b0c 是一家人。明度严格按点积链排：
       臂4右 > 臂0左 > 臂4左 > 臂0右 > 臂3右 > 臂1左 > 臂3左 > 臂1右
       > 臂2右 > 臂2左（立体感全靠这条明暗阶，色相不参与）。 */
    var PLANE_L = ['#c9d2db', '#909aa5', '#555e68', '#808a95', '#bfc9d2']
    var PLANE_R = ['#b0bac3', '#707a85', '#626c77', '#a0aab4', '#d3dbe4']
    for (var a2 = 0; a2 < 5; a2++) {
      if (style === 'emboss') {
        body.appendChild(P('M ' + pt(O[a2]) + ' L ' + pt(I[(a2 + 4) % 5]) + ' L 30,30 Z', {
          fill: 'currentColor', 'fill-opacity': String(inkOp(PLANE_L[a2]))
        }))
        body.appendChild(P('M ' + pt(O[a2]) + ' L ' + pt(I[a2]) + ' L 30,30 Z', {
          fill: 'currentColor', 'fill-opacity': String(inkOp(PLANE_R[a2]))
        }))
        continue
      }
      var lg2 = def(LG(20, 14, 40, 42, [
        [0, PLANE_L[a2]], [1, shade(PLANE_L[a2], 0.80)]
      ]))
      body.appendChild(P('M ' + pt(O[a2]) + ' L ' + pt(I[(a2 + 4) % 5]) + ' L 30,30 Z', {
        fill: 'url(#' + lg2.getAttribute('id') + ')'
      }))
      var rg2 = def(LG(20, 14, 40, 42, [
        [0, PLANE_R[a2]], [1, shade(PLANE_R[a2], 0.80)]
      ]))
      body.appendChild(P('M ' + pt(O[a2]) + ' L ' + pt(I[a2]) + ' L 30,30 Z', {
        fill: 'url(#' + rg2.getAttribute('id') + ')'
      }))
    }

    /* ── ② 棱线层：帐篷棱受光，尖角→圆心 5 道亮描线 ──
       参考图里最抢眼的就是这 5 道从尖角汇到中心的亮线。黑灰版用冷白，
       和 HUD 环同色系 —— 棱是"受光的金属边"，不是另一种材料。 */
    if (style !== 'emboss') {
      for (var r2 = 0; r2 < 5; r2++) {
        body.appendChild(P('M ' + pt(O[r2]) + ' L 30,30', {
          fill: 'none', stroke: '#eef2f6', 'stroke-opacity': '0.95',
          'stroke-width': '0.55', 'stroke-linecap': 'round'
        }))
      }
    }

    /* 外轮廓镀边：上亮下隐的冷灰渐变描边（只有受光的一半亮）*/
    if (style === 'emboss') {
      body.appendChild(P(STAR.path, {
        fill: 'none', stroke: 'currentColor', 'stroke-opacity': '0.62',
        'stroke-width': '0.75', 'stroke-linejoin': 'round'
      }))
    } else {
      var rimG = def(LG(8, 6, 48, 50, [
        [0, '#f4f7fa', '0.95'], [0.3, '#b0bac3', '0.55'], [0.65, '#b0bac3', '0']
      ]))
      body.appendChild(P(STAR.path, {
        fill: 'none', stroke: 'url(#' + rimG.getAttribute('id') + ')',
        'stroke-width': '0.55', 'stroke-linejoin': 'round'
      }))
    }

    /* ── ① 核心层：谷底亮核 + 斜切高光 ── */
    if (style === 'emboss') {
      var haloE = def(RG(30, 30, 5.2, [[0, 'currentColor', '0.30'], [1, 'currentColor', '0']]))
      body.appendChild(C(30, 30, 5.2, { fill: 'url(#' + haloE.getAttribute('id') + ')' }))
      body.appendChild(C(30, 30, 1.15, { fill: 'currentColor' }))
    } else {
      var haloG = def(RG(30, 30, 3.6, [[0, '#eef2f6', '0.5'], [1, '#eef2f6', '0']]))
      body.appendChild(C(30, 30, 3.6, { fill: 'url(#' + haloG.getAttribute('id') + ')' }))
      body.appendChild(C(30, 30, 0.85, { fill: '#f4f7fa' }))
    }

    /* 斜切高光：一道斜扛过左上两臂，整星轮廓裁切，极淡 */
    var clipId = nid()
    var clip = document.createElementNS(ns, 'clipPath')
    clip.setAttribute('id', clipId)
    var clipPath = document.createElementNS(ns, 'path')
    clipPath.setAttribute('d', STAR.path)
    clipPath.setAttribute('fill-rule', 'nonzero')
    clip.appendChild(clipPath)
    defs.appendChild(clip)
    var specG = def(LG(16, 12, 40, 36, [
      [0, '#f4f8fc', '0.22'], [0.5, '#e8eef4', '0.06'], [1, '#e8eef4', '0']
    ]))
    var spec = document.createElementNS(ns, 'ellipse')
    spec.setAttribute('cx', '24'); spec.setAttribute('cy', '18')
    spec.setAttribute('rx', '13'); spec.setAttribute('ry', '4.5')
    spec.setAttribute('transform', 'rotate(-40 24 18)')
    spec.setAttribute('fill', 'url(#' + specG.getAttribute('id') + ')')
    spec.setAttribute('clip-path', 'url(#' + clipId + ')')
    body.appendChild(spec)

    svg.appendChild(body)
    return svg
  }

  /** 逐字写入。两种模式：
   *   'fade'   —— 逐字淡入 + 上移（原行为，给底部小字日志用）
   *   'decode' —— 逐字"解码"：先落一个随机字形，再跳几帧锁定成真字。
   *               终端/AI 题材的经典语汇，也是"机械感"最省的来源。
   *  两种模式都靠 CSS 过渡收尾，解码结束后不需要再补动画。
   *
   *  替身字形**必须和目标字等宽**：作者当初刻意用不透明度而非截断，
   *  就是为了居中排版不左右抖动；用半角 hex 去替全角汉字会把这个优点丢掉。
   *  所以中文走全角片假名、拉丁走半角 hex。
   *  @returns 解码槽位数组（'fade' 模式返回空数组） */
  function typeIn(host, text, stagger, mode) {
    host.textContent = ''
    var frag = document.createDocumentFragment()
    var slots = []
    var n = 0
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i)
      if (ch === ' ') {
        frag.appendChild(document.createTextNode('\u00a0'))
        continue
      }
      var decode = mode === 'decode'
      /* 分隔圆点单独着色：整句有一个强调锚，读起来不再是平均的一排字。 */
      var s = el('span', ch === '·' ? 'dsu-ch dsu-sep' : 'dsu-ch', decode ? glyphFor(ch) : ch)
      s.style.transitionDelay = Math.round(n * stagger) + 'ms'
      if (decode) slots.push({ node: s, text: ch, delay: Math.round(n * stagger) })
      frag.appendChild(s)
      n++
    }
    host.appendChild(frag)
    return slots
  }

  /* 全角片假名（1em 宽）+ 半角 hex —— 两组都和目标字同宽 */
  var GLYPH_WIDE = '\u30a2\u30a4\u30a6\u30a8\u30aa\u30ab\u30ad\u30af\u30b1\u30b3' +
    '\u30b5\u30b7\u30b9\u30bb\u30bd\u30bf\u30c1\u30c4\u30c6\u30c8\u30ca\u30cb\u30cc\u30cd\u30ce'
  var GLYPH_NARROW = '0123456789ABCDEF'
  /** 目标字是不是全角（CJK / 全角标点）—— 决定用哪一组替身字形 */
  function glyphFor(ch) {
    var wide = ch.charCodeAt(0) > 0x2e7f
    var pool = wide ? GLYPH_WIDE : GLYPH_NARROW
    return pool.charAt(Math.floor(Math.random() * pool.length))
  }

  /* 解码调度：所有字共用一个 55ms 的 interval，而不是每个字一个 timer
     （一句中文 8 个字 + 一行英文字幕 20 多个字符，逐字开 timer 会很难看）。
     每个字在自己的入场延迟之后再多抖 100–280ms 才锁定。 */
  var decodeTimer = null
  var decodePending = []
  var DECODE_TICK = 55

  function startDecode(slots) {
    stopDecode()
    if (!slots || !slots.length) return
    decodePending = []
    for (var i = 0; i < slots.length; i++) {
      var s = slots[i]
      decodePending.push({
        node: s.node, text: s.text,
        lockAt: s.delay + 100 + Math.random() * 180
      })
    }
    var t0 = Date.now()
    decodeTimer = setInterval(function () {
      var now = Date.now() - t0
      var rest = []
      for (var j = 0; j < decodePending.length; j++) {
        var d = decodePending[j]
        if (now >= d.lockAt) d.node.textContent = d.text
        else { d.node.textContent = glyphFor(d.text); rest.push(d) }
      }
      decodePending = rest
      if (!decodePending.length) stopDecode()
    }, DECODE_TICK)
  }

  /** 停掉解码并把所有还没锁定的字强制锁成真字（跳过 / 揭幕时必须调） */
  function stopDecode() {
    if (decodeTimer) { clearInterval(decodeTimer); decodeTimer = null }
    for (var i = 0; i < decodePending.length; i++) {
      decodePending[i].node.textContent = decodePending[i].text
    }
    decodePending = []
  }

  function setIn(node, on, cls) {
    if (!node) return
    node.classList.toggle(cls || 'dsu-in', !!on)
  }

  /* ── DOM 搭建 ─────────────────────────────────────────────────────────── */
  var root = document.getElementById(ROOT_ID)
  if (!root) {
    root = el('div')
    root.id = ROOT_ID
    root.className = 'dsu-root'
    document.body.appendChild(root)
  }
  root.classList.toggle('dsu-dark', C.theme === 'dark')
  root.style.setProperty('--dsu-speed', String(C.speed))
  root.style.setProperty('--dsu-accent', C.accent)
  root.style.setProperty('--dsu-glitch-a', C.glitchA)
  root.style.setProperty('--dsu-glitch-b', C.glitchB)

  var ui = {}
  var clockTimer = null
  var html =
    '<div class="dsu-atmo"></div>' +
    '<canvas class="dsu-field" aria-hidden="true"></canvas>' +
    '<div class="dsu-beams"></div>' +
    '<div class="dsu-floor"></div>' +
    '<div class="dsu-plate"></div>' +
    '<div class="dsu-vignette"></div>' +
    '<div class="dsu-watermark"></div>' +
    '<div class="dsu-grain"></div>' +
    '<div class="dsu-black">' +
      '<div class="dsu-black-inner"></div>' +
      '<div class="dsu-sweep"></div>' +
    '</div>' +
    '<div class="dsu-wash"></div>' +
    '<div class="dsu-sheen"></div>' +
    '<header class="dsu-brand">' +
      '<div class="dsu-brand-1"></div><div class="dsu-brand-2"></div>' +
      '<div class="dsu-brand-3"><b></b><span></span></div>' +
    '</header>' +
    '<div class="dsu-stepcount">[ 00 / 06 ] INIT</div>' +
    '<div class="dsu-center">' +
      '<div class="dsu-status"><span class="dsu-status-zh"></span><i class="dsu-caret"></i></div>' +
      '<div class="dsu-sub-en"></div>' +
      '<div class="dsu-rule"></div>' +
      '<div class="dsu-logo"></div>' +
      '<div class="dsu-dots" hidden></div>' +
    '</div>' +
    '<div class="dsu-idline"></div>' +
    '<div class="dsu-facts dsu-facts-1"></div>' +
    '<div class="dsu-facts dsu-facts-2"></div>' +
    '<div class="dsu-reticle"></div>' +
    '<div class="dsu-hex"></div>' +
    '<div class="dsu-trace"></div>' +
    '<div class="dsu-welcome">' +
      '<div class="dsu-w1">WELCOME TO</div>' +
      '<div class="dsu-w2"></div>' +
      '<div class="dsu-w3"></div>' +
      '<div class="dsu-w4"></div>' +
    '</div>' +
    '<div class="dsu-action">' +
      '<div class="dsu-card" hidden></div>' +
      '<button class="dsu-btn" type="button">' +
        '<span class="dsu-btn-zh"></span><span class="dsu-btn-en"></span>' +
      '</button>' +
      '<div class="dsu-hint"></div>' +
    '</div>' +
    '<div class="dsu-gate"><span class="dsu-gate-txt"></span><i class="dsu-gate-bar"></i></div>' +
    '<div class="dsu-frame">' +
      '<i class="dsu-corner dsu-c-tl"></i><i class="dsu-corner dsu-c-tr"></i>' +
      '<i class="dsu-corner dsu-c-bl"></i><i class="dsu-corner dsu-c-br"></i>' +
      '<div class="dsu-scanline"></div>' +
    '</div>' +
    '<div class="dsu-slats"></div>' +
    '<div class="dsu-voice"><i></i><i></i><i></i><i></i><i></i></div>' +
    '<div class="dsu-meta"><span class="dsu-meta-1"></span><span class="dsu-meta-2"></span></div>' +
    '<div class="dsu-checks"></div>' +
    '<div class="dsu-skip">SKIP ▸</div>' +
    '<footer class="dsu-foot"><span></span><i></i></footer>' +
    '<div class="dsu-subtitle">' +
      '<span class="dsu-sub-zh"></span><span class="dsu-sub-en2"></span>' +
    '</div>' +
    '<div class="dsu-progress"><i></i></div>' +
    '<div class="dsu-bloom"></div>' +
    '<div class="dsu-streak"></div>' +
    '<div class="dsu-tear"></div>' +
    '<div class="dsu-flash"></div>'

  root.innerHTML = html

  function q(sel) { return root.querySelector(sel) }
  ui.plate = q('.dsu-plate')
  ui.watermark = q('.dsu-watermark')
  ui.black = q('.dsu-black')
  ui.blackInner = q('.dsu-black-inner')
  ui.sweep = q('.dsu-sweep')
  ui.wash = q('.dsu-wash')
  ui.sheen = q('.dsu-sheen')
  ui.flash = q('.dsu-flash')
  ui.bloom = q('.dsu-bloom')
  ui.streak = q('.dsu-streak')
  ui.tear = q('.dsu-tear')
  ui.vignette = q('.dsu-vignette')
  ui.brand = q('.dsu-brand')
  ui.center = q('.dsu-center')
  ui.brand1 = q('.dsu-brand-1')
  ui.brand2 = q('.dsu-brand-2')
  ui.brand3b = q('.dsu-brand-3 b')
  ui.brand3s = q('.dsu-brand-3 span')
  ui.stepcount = q('.dsu-stepcount')
  ui.status = q('.dsu-status')
  ui.statusZh = q('.dsu-status-zh')
  ui.caret = q('.dsu-caret')
  ui.subEn = q('.dsu-sub-en')
  ui.rule = q('.dsu-rule')
  ui.logo = q('.dsu-logo')
  ui.dots = q('.dsu-dots')
  ui.idline = q('.dsu-idline')
  ui.fact1 = q('.dsu-facts-1')
  ui.fact2 = q('.dsu-facts-2')
  ui.reticle = q('.dsu-reticle')
  ui.hex = q('.dsu-hex')
  ui.trace = q('.dsu-trace')
  ui.welcome = q('.dsu-welcome')
  ui.w1 = q('.dsu-w1')
  ui.w2 = q('.dsu-w2')
  ui.w3 = q('.dsu-w3')
  ui.w4 = q('.dsu-w4')
  ui.action = q('.dsu-action')
  ui.card = q('.dsu-card')
  ui.btn = q('.dsu-btn')
  ui.btnZh = q('.dsu-btn-zh')
  ui.btnEn = q('.dsu-btn-en')
  ui.hint = q('.dsu-hint')
  ui.gate = q('.dsu-gate')
  ui.gateTxt = q('.dsu-gate-txt')
  ui.gateBar = q('.dsu-gate-bar')
  ui.skip = q('.dsu-skip')
  ui.foot = q('.dsu-foot')
  ui.footText = q('.dsu-foot span')
  ui.subZh = q('.dsu-sub-zh')
  ui.subEn2 = q('.dsu-sub-en2')
  ui.progress = q('.dsu-progress')
  ui.bar = q('.dsu-progress i')
  ui.frame = q('.dsu-frame')
  ui.scanline = q('.dsu-scanline')
  ui.slats = q('.dsu-slats')
  ui.voice = q('.dsu-voice')
  ui.meta = q('.dsu-meta')
  ui.meta1 = q('.dsu-meta-1')
  ui.meta2 = q('.dsu-meta-2')
  ui.atmo = q('.dsu-atmo')
  ui.field = q('.dsu-field')
  ui.beams = q('.dsu-beams')
  ui.floor = q('.dsu-floor')
  ui.checks = q('.dsu-checks')

  /* 内容填充 */
  ui.brand1.textContent = C.brand1
  ui.brand2.textContent = C.brand2
  ui.brand3b.textContent = C.brand3a
  ui.brand3s.textContent = C.brand3b
  ui.footText.textContent = C.footer
  ui.w2.textContent = C.welcomeBox
  ui.w4.textContent = '欢迎 ' + C.identity + ' 访问'
  /* ID 那行挂到左上信息栏，和 REV / 阶段格成组（1.2.2 之前在屏幕中央偏右，
     会压在中英状态行上）。编号单独用 <b> 包起来走强调色，其余保持 muted。
     用 el() 建节点而不是 createTextNode —— 预览与测试用的最小 DOM stub 只保证
     createElement 这一条路径。 */
  ui.idline.textContent = ''
  ui.idline.appendChild(el('span', null, '· ID CONFIRMED : '))
  ui.idline.appendChild(el('b', null, C.identityId))

  ;(function blackStage() {
    var inner = ui.blackInner
    /* 第一幕主标识：五角星（2026-10-22 用户指定，替代鲸鱼）。
       class 沿用 dsu-whale —— CSS 的 122px / currentColor / 入场都在这个
       class 上，换形状不动构图。 */
    /* 第一幕主标识：立体折面五角星（2026-10-23 用户拍板换回这一版）。
       class 沿用 dsu-whale —— CSS 的 200px / currentColor / 入场都挂在这个
       class 上，换形状不动构图。 */
    var star = svgStar('dsu-whale')
    inner.appendChild(star)
    inner.appendChild(el('div', 'dsu-black-zh', C.orgZh))
    var en = el('div', 'dsu-black-en', C.orgEn)
    inner.appendChild(en)
    inner.appendChild(el('div', 'dsu-black-sub', C.orgSub))
    ui.blackEn = en
  })()

  ;(function logoStage() {
    ui.logo.appendChild(svgStar(null, 'wire'))
    ui.logo.appendChild(el('div', 'dsu-logolabel', 'MacOS'))
  })()

  ;(function welcomeLogo() {
    ui.w3.appendChild(svgStar(null, 'emboss'))
    ui.w3.appendChild(el('span', 'dsu-w3label', 'APPLE  ·  SYSTEM ASSISTANT'))
  })()

  ;(function watermark() {
    var boxes = [
      [0.60, 0.02, 0.16, 0.96], [0.78, 0.02, 0.16, 0.96], [0.96, 0.02, 0.16, 0.96],
      [0.05, 0.02, 0.10, 0.5]
    ]
    for (var i = 0; i < boxes.length; i++) {
      var b = boxes[i]
      var depth = i < 1 ? ' dsu-wm-far' : i < 3 ? ' dsu-wm-mid' : ' dsu-wm-near'
      var n = el('div', 'dsu-wm' + depth)
      n.style.left = (b[0] * 100) + '%'
      n.style.top = (b[1] * 100) + '%'
      n.style.width = (b[2] * 100) + '%'
      n.style.height = (b[3] * 100) + '%'
      ui.watermark.appendChild(n)
    }
  })()

  /* 左侧六格阶段柱 + 品牌块下方的小字数据行 + 实时时钟 */
  ;(function slatsAndMeta() {
    for (var i = 0; i < STEPS.length + 1; i++) ui.slats.appendChild(el('i', 'dsu-slat'))
    /* REV 那行现在显示**真实版本与 profile**，不再写死 "REV 0.1.0 · WEB PROFILE" */
    ui.meta1.textContent = 'REV ' + factText(F.version) + ' · ' + factText(F.profile) + ' PROFILE'
    /* 两行真实自检读数：模型 / 沙箱模式 / 插件数 —— 全部来自宿主 ctx，不是装饰 */
    ui.fact1.textContent = ''
    ui.fact1.appendChild(el('span', null, '· MODEL : '))
    ui.fact1.appendChild(el('b', null, factText(F.model)))
    ui.fact2.textContent = ''
    ui.fact2.appendChild(el('span', null, '· SANDBOX : '))
    ui.fact2.appendChild(el('b', null, factText(F.sandbox)))
    ui.fact2.appendChild(el('span', null, ' · BUNDLES : '))
    /* 用 bundle 数（装了哪些包）而不是 plugin entry 数（配置树里的 191 行）：
       后者是内部条目，标成 "PLUGINS : 191" 会让人误以为装了 191 个用户插件。 */
    ui.fact2.appendChild(el('b', null, factText(F.bundleCount)))
    paintClock()
    clockTimer = setInterval(paintClock, 1000)
  })()

  /* 右侧自检清单：五项全部来自 collectFacts() 的真事实。
     取不到的项由 factText() 写成 "—"，不补假值。 */
  /* 底部信号轨迹：一条由 facts.hash 决定相位的低频波形 + 一条循环扫描游标。
     它不是装饰，换机器/换 profile 波形会变，读起来像这台机器自己的信号。 */
  ;(function trace() {
    var ns = 'http://www.w3.org/2000/svg'
    var svg = document.createElementNS(ns, 'svg')
    svg.setAttribute('viewBox', '0 0 520 46')
    var base = document.createElementNS(ns, 'line')
    base.setAttribute('x1', '0'); base.setAttribute('y1', '23')
    base.setAttribute('x2', '520'); base.setAttribute('y2', '23')
    base.setAttribute('class', 'dsu-trace-base')
    svg.appendChild(base)
    for (var i = 0; i <= 20; i++) {
      var tick = document.createElementNS(ns, 'line')
      var tx = i * 26
      tick.setAttribute('x1', String(tx)); tick.setAttribute('y1', '19')
      tick.setAttribute('x2', String(tx)); tick.setAttribute('y2', '27')
      tick.setAttribute('class', 'dsu-trace-tick')
      svg.appendChild(tick)
    }
    var seed = String(F.hash || 'DSHBOOT')
    var h = 2166136261
    for (var k = 0; k < seed.length; k++) {
      h ^= seed.charCodeAt(k)
      h = Math.imul(h, 16777619) >>> 0
    }
    var phase = (h % 628) / 100
    /* 1.6.0：波形不再是冻结的装饰，按相位缓慢推进。
       90ms 一跳足够顺，且比逐帧重算路径省得多；低频漂移不会抢中央读数。 */
    function tracePathAt(now) {
      var drift = now * 0.00034
      var d = 'M0 23'
      for (var x = 0; x <= 520; x += 8) {
        var env = Math.sin((x / 520) * Math.PI)
        var amp = (Math.sin(x * 0.035 + phase + drift) * 5 +
          Math.sin(x * 0.011 + phase * 1.7 - drift * 0.62) * 3) * env
        d += ' L' + x + ' ' + (23 + amp).toFixed(1)
      }
      return d
    }
    var path = document.createElementNS(ns, 'path')
    path.setAttribute('d', tracePathAt(0))
    path.setAttribute('class', 'dsu-trace-line')
    svg.appendChild(path)
    var cursor = document.createElementNS(ns, 'line')
    cursor.setAttribute('x1', '0'); cursor.setAttribute('y1', '2')
    cursor.setAttribute('x2', '0'); cursor.setAttribute('y2', '44')
    cursor.setAttribute('class', 'dsu-trace-cursor')
    svg.appendChild(cursor)
    ui.trace.appendChild(svg)
    ui.tracePath = path
    ui.traceTimer = setInterval(function () { path.setAttribute('d', tracePathAt(Date.now())) }, 90)
  })()

  ;(function checks() {
    var rows = [
      ['PROFILE', F.profile],
      ['BUNDLES', F.bundleCount],
      ['MODEL', F.model],
      ['SANDBOX', F.sandbox],
      ['SESSIONS', F.sessions]
    ]
    var checksHead = el('div', 'dsu-checks-h', 'SELF-CHECK / ')
    checksHead.appendChild(el('span', 'dsu-live', 'LIVE'))
    ui.checks.appendChild(checksHead)
    for (var i = 0; i < rows.length; i++) {
      var row = el('div', 'dsu-check')
      row.appendChild(el('span', 'dsu-check-k', rows[i][0]))
      row.appendChild(el('span', 'dsu-check-v', factText(rows[i][1])))
      row.appendChild(el('i'))
      ui.checks.appendChild(row)
    }
  })()

  ;(function reticle() {
    var ns = 'http://www.w3.org/2000/svg'
    var svg = document.createElementNS(ns, 'svg')
    svg.setAttribute('viewBox', '0 0 400 400')
    function arc(cx, cy, r, a0, a1, cls, cap) {
      var rad = function (d) { return (d - 90) * Math.PI / 180 }
      var x0 = cx + r * Math.cos(rad(a0)), y0 = cy + r * Math.sin(rad(a0))
      var x1 = cx + r * Math.cos(rad(a1)), y1 = cy + r * Math.sin(rad(a1))
      var large = (a1 - a0) > 180 ? 1 : 0
      var p = document.createElementNS(ns, 'path')
      p.setAttribute('d', 'M' + x0.toFixed(2) + ' ' + y0.toFixed(2) +
        ' A' + r + ' ' + r + ' 0 ' + large + ' 1 ' + x1.toFixed(2) + ' ' + y1.toFixed(2))
      p.setAttribute('class', cls)
      if (cap) p.setAttribute('stroke-linecap', cap)
      return { node: p, x: x1, y: y1, x0: x0, y0: y0 }
    }
    var gA = document.createElementNS(ns, 'g')
    gA.setAttribute('class', 'dsu-ret-rot-a')
    /* 300° 弧，缺口留在正下方 6 点钟方向：底部字幕永远不会被压到，
       弧末端圆点落在 5 点钟位置，和原片一致。 */
    var a = arc(200, 200, 150, 215, 505, 'dsu-ring-a', 'round')
    gA.appendChild(a.node)
    var da = document.createElementNS(ns, 'circle')
    da.setAttribute('class', 'dsu-dot-a')
    da.setAttribute('cx', a.x.toFixed(2)); da.setAttribute('cy', a.y.toFixed(2)); da.setAttribute('r', '7')
    gA.appendChild(da)
    svg.appendChild(gA)

    var gB = document.createElementNS(ns, 'g')
    gB.setAttribute('class', 'dsu-ret-rot-b')
    var b = arc(200, 200, 104, 200, 490, 'dsu-ring-b', 'round')
    gB.appendChild(b.node)
    var db = document.createElementNS(ns, 'circle')
    db.setAttribute('class', 'dsu-dot-b')
    db.setAttribute('cx', b.x0.toFixed(2)); db.setAttribute('cy', b.y0.toFixed(2)); db.setAttribute('r', '4')
    gB.appendChild(db)
    svg.appendChild(gB)

    var gC = document.createElementNS(ns, 'g')
    var bl = arc(200, 200, 62, 118, 242, 'dsu-bracket', 'round')
    var br = arc(200, 200, 62, 298, 62, 'dsu-bracket', 'round')
    gC.appendChild(bl.node); gC.appendChild(br.node)
    svg.appendChild(gC)

    var pts = [[152, 132], [252, 268], [278, 150]]
    for (var i = 0; i < pts.length; i++) {
      var c = document.createElementNS(ns, 'circle')
      c.setAttribute('class', 'dsu-dot-o')
      c.setAttribute('cx', pts[i][0]); c.setAttribute('cy', pts[i][1]); c.setAttribute('r', '2.8')
      svg.appendChild(c)
    }

    /* 刻度环：48 格，落在外环内侧（r 132→141）。
       每格带一个递增的 animation-delay —— 准星出现时像仪表自检一样沿环逐格点亮，
       一圈约 1.5 秒，读完就停在暗态，不会一直闪。 */
    var gT = document.createElementNS(ns, 'g')
    gT.setAttribute('class', 'dsu-ret-ticks')
    var TICKS = 48
    for (var t = 0; t < TICKS; t++) {
      var deg = (t / TICKS) * 360 - 90
      var rad = deg * Math.PI / 180
      var long = t % 4 === 0
      var r0 = 133
      var r1 = long ? 143 : 138
      var line = document.createElementNS(ns, 'line')
      line.setAttribute('class', 'dsu-tick' + (long ? ' dsu-tick-major' : ''))
      line.setAttribute('x1', (200 + r0 * Math.cos(rad)).toFixed(2))
      line.setAttribute('y1', (200 + r0 * Math.sin(rad)).toFixed(2))
      line.setAttribute('x2', (200 + r1 * Math.cos(rad)).toFixed(2))
      line.setAttribute('y2', (200 + r1 * Math.sin(rad)).toFixed(2))
      line.style.animationDelay = Math.round(t * 32) + 'ms'
      gT.appendChild(line)
    }
    svg.appendChild(gT)

    /* 数据环：按 bundleCount 点亮对应格数（取不到就 12 格）。
       这一圈不是装饰，而是把"宿主真实装了哪些 bundle"变成可读刻度。 */
    var gD = document.createElementNS(ns, 'g')
    gD.setAttribute('class', 'dsu-ret-data')
    var DATA_TICKS = 40
    var lit = Math.max(6, Math.min(DATA_TICKS, Number(F.bundleCount) || 12))
    for (var d = 0; d < DATA_TICKS; d++) {
      var degD = (d / DATA_TICKS) * 360 - 90
      var radD = degD * Math.PI / 180
      var rD0 = 112
      var rD1 = d < lit ? 120 : 116
      var lineD = document.createElementNS(ns, 'line')
      lineD.setAttribute('class', 'dsu-tick-data' + (d < lit ? ' dsu-lit' : ''))
      lineD.setAttribute('x1', (200 + rD0 * Math.cos(radD)).toFixed(2))
      lineD.setAttribute('y1', (200 + rD0 * Math.sin(radD)).toFixed(2))
      lineD.setAttribute('x2', (200 + rD1 * Math.cos(radD)).toFixed(2))
      lineD.setAttribute('y2', (200 + rD1 * Math.sin(radD)).toFixed(2))
      lineD.style.animationDelay = Math.round(d * 26) + 'ms'
      gD.appendChild(lineD)
    }
    svg.appendChild(gD)

    /* 彗星弧：8% 周长的一段弧，绕环匀速扫过，给静态刻度一个"读取头" */
    var comet = document.createElementNS(ns, 'circle')
    comet.setAttribute('class', 'dsu-ret-comet')
    comet.setAttribute('cx', '200')
    comet.setAttribute('cy', '200')
    comet.setAttribute('r', '150')
    comet.setAttribute('pathLength', '100')
    comet.setAttribute('stroke-dasharray', '8 92')
    svg.appendChild(comet)

    /* 锁定冲击波：只在外环外扩，不穿过中央文字 */
    var ping = document.createElementNS(ns, 'circle')
    ping.setAttribute('class', 'dsu-ping')
    ping.setAttribute('cx', '200')
    ping.setAttribute('cy', '200')
    ping.setAttribute('r', '150')
    svg.appendChild(ping)

    ui.reticle.appendChild(svg)

    /* 雷达扫描扇区：conic 渐变 + 环形遮罩，只在中环那一圈扫。
       用 DOM 叠加层而不是 SVG 渐变 —— 角度渐变在 SVG 里要写 <foreignObject> 或大量小扇面，
       性价比太低。 */
    ui.reticleScan = el('div', 'dsu-ret-scan')
    ui.reticle.appendChild(ui.reticleScan)
  })()

  /* 光场句柄必须**在调用 startField() 之前**声明。
     ⚠ 上游 dsh-startup-screen 把 `startField()` 放在第 838 行、`var fieldHandle = null`
       放在第 1004 行 —— 靠函数声明提升能调到函数，但那时 fieldHandle 还是 undefined；
       随后第 1004 行的 `= null` 执行，把 startField 内部刚赋好的对象重新抹掉。
       结果：frame() 第一行 `if (!fieldHandle) return` 永远命中，光场只画 1 帧就死。
       症状极隐蔽 —— 无异常、无报错、画面也只是"背景不动"，极易被当成性能问题。 */
  var fieldHandle = null

  /* ⚠ 不在这里起：第一幕整屏是黑幕 + 五角星，光场被完全盖住，
     但全屏 canvas 的 rAF 照样在跑（2880×1800），和入场动画抢主线程 ——
     这是"第一幕卡顿"的直接原因。改到第二幕（档案底板出现）再启动。 */
  /* 光场延后到第二幕启动，见下方 run() 里 startField() 的注释 */

  /* ── 时间线引擎 ───────────────────────────────────────────────────────── */
  var timers = []
  var waiters = []
  var skipped = false
  var finished = false
  var hexTimer = null

  function ms(base) { return Math.round(base / C.speed) }

  function wait(base) {
    return new Promise(function (resolve) {
      if (skipped) return resolve()
      var done = false
      function fin() {
        if (done) return
        done = true
        var i = waiters.indexOf(fin)
        if (i >= 0) waiters.splice(i, 1)
        resolve()
      }
      var t = setTimeout(fin, Math.max(0, ms(base)))
      timers.push(t)
      waiters.push(fin)
    })
  }

  /* ── 场景闸门（2026-10-22 用户拍板的交互模型）──────────────────────────
     用户原话：「得我点击了空格或者enter才进入下一个动画的界面，不是自己立刻动
     （但是如果3秒内没有人交互，自动进入下一个动画的界面）」。
     所以每一幕之间不是定时器到点就切，而是三条路谁先到算谁：
       ① Space / Enter（或点一下闸门提示）→ 立刻进下一幕
       ② 3 秒没有任何交互 → 自动进下一幕
       ③ Esc / SKIP → 整场跳过（releaseAll 会把闸门一并放行）
     闸门期间显示一行小提示 + 一根流空的细线，让"可以按、也会自动走"是可见的。
     ⚠ 本函数取代了旧版 waitAction（步骤内确认按钮）：确认按钮步骤传
       { button: true }，点按钮与按键等价；其余场景不传，任意点击即继续。 */
  function gateScene(opts) {
    opts = opts || {}
    return new Promise(function (resolve) {
      if (skipped || finished || C.sceneGate === false) return resolve()
      var done = false
      var timer = null
      /* 闸门开门时刻。用来吃掉「刚开门就来的那一下输入」——
         实测抓到过：闸门 open 后 200~800ms 内必定收到一次 manual 放行，
         而当时没有任何人碰键鼠（自检截图均值直接跳到 119，判据全红）。
         给 350ms 静默窗口：真人按键不可能卡在动画刚切换的那一帧上，
         而系统/输入法/残留事件正好都落在这个窗口里。 */
      var armedAt = Date.now()
      function fin(manual) {
        if (done) return
        if (manual && Date.now() - armedAt < 350) {
          try { (window.__WB_GATE_LOG__ = window.__WB_GATE_LOG__ || []).push('IGNORED@' + (Date.now() - armedAt)) } catch (e) {}
          return
        }
        done = true
        /* 调试：记录每道闸门的开门/放行时刻与原因（自检用 evaluateJavaScript 读） */
        try {
          (window.__WB_GATE_LOG__ = window.__WB_GATE_LOG__ || []).push(
            'close@' + (Date.now() % 100000) + ' manual=' + (manual ? 1 : 0) +
            ' ms=' + clampGateMs(C.gateTimeoutMs))
        } catch (e) { /* 调试通道不许抛 */ }
        cleanup()
        hideGate()
        /* 手动推进给一声轻提示——没有反馈的按键像没按一样 */
        if (manual) { try { audio.tap() } catch (e) { /* 闸门音效不许抛 */ } }
        resolve()
      }
      function onKey(e) {
        /* 只认**真实**输入：脚本合成的 keydown/pointerdown 一律当噪声 */
        if (e.isTrusted === false) return
        if (e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar') {
          try { (window.__WB_GATE_LOG__ = window.__WB_GATE_LOG__ || []).push('KEY:' + e.key) } catch (err) {}
          e.preventDefault(); fin(true)
        }
      }
      function onClick(e) {
        if (e.isTrusted === false) return
        if (opts.button) {
          /* 确认步骤：只有点在按钮/动作区上才算，别让误触跳过身份确认 */
          if (e.target === ui.btn || ui.btn.contains(e.target) ||
              e.target === ui.action || ui.action.contains(e.target)) { fin(true) }
        } else {
          try {
            (window.__WB_GATE_LOG__ = window.__WB_GATE_LOG__ || []).push(
              'PTR:' + (e.target && e.target.className ? String(e.target.className).slice(0, 24) : '?') +
              ' type=' + e.type)
          } catch (err) {}
          fin(true)
        }
      }
      function cleanup() {
        if (timer) { clearTimeout(timer); timer = null }
        document.removeEventListener('keydown', onKey)
        document.removeEventListener('pointerdown', onClick, true)
        var i = waiters.indexOf(fin)
        if (i >= 0) waiters.splice(i, 1)
      }
      try {
        (window.__WB_GATE_LOG__ = window.__WB_GATE_LOG__ || []).push(
          'open@' + (Date.now() % 100000) + ' skipped=' + (skipped ? 1 : 0) +
          ' finished=' + (finished ? 1 : 0) + ' gate=' + (C.sceneGate === false ? 'off' : 'on'))
      } catch (e) { /* 调试通道不许抛 */ }
      document.addEventListener('keydown', onKey)
      document.addEventListener('pointerdown', onClick, true)
      waiters.push(fin)
      /* 确认步骤（button:true）不显示闸门提示 —— 动作区那句
         「按 Enter / Space，或点击按钮继续」已经在说同一件事，
         两行提示并排是噪音（2026-10-22 实测截图发现）。 */
      if (opts.button) { hideGate() } else { showGate() }
      timer = setTimeout(function () { fin(false) }, clampGateMs(C.gateTimeoutMs))
    })
  }

  /* 闸门超时兜底：配置缺失/越界时退回 6000，且夹在 500ms~30s 之间 ——
     夹上限是因为这是开机动画，单幕等 30 秒以上用户会以为系统卡死。 */
  function clampGateMs(v) {
    var n = Number(v)
    if (!isFinite(n) || n <= 0) n = 6000
    return Math.max(500, Math.min(30000, n))
  }

  function showGate() {
    if (!ui.gate) return
    ui.gateTxt.innerHTML = '按 <kbd>Space</kbd> / <kbd>Enter</kbd> 继续'
    ui.gate.classList.add('dsu-in')
    /* 流空线：先复位再触发 transition（和 sweep() 同一招，不强制重排不播）。
       ⚠ 必须用 transform: scaleX 排水，不能改 width —— width:'100%' 会把
       72px 的固定线拉成通栏直线（2026-10-22 实测踩过，截图里一条横贯全屏的线）。
       transform 不走布局，还比宽度过渡滑。 */
    if (ui.gateBar) {
      ui.gateBar.style.transition = 'none'
      ui.gateBar.style.transform = 'scaleX(1)'
      void ui.gateBar.offsetWidth
      ui.gateBar.style.transition = 'transform ' + clampGateMs(C.gateTimeoutMs) + 'ms linear'
      ui.gateBar.style.transform = 'scaleX(0)'
    }
  }

  function hideGate() {
    if (ui.gate) ui.gate.classList.remove('dsu-in')
  }

  function releaseAll() {
    for (var i = 0; i < timers.length; i++) clearTimeout(timers[i])
    timers.length = 0
    stopDecode()   /* 跳过 / 揭幕时把还没锁定的替身字形强制锁成真字 */
    var list = waiters.slice()
    waiters.length = 0
    for (var j = 0; j < list.length; j++) { try { list[j]() } catch (err) { /* noop */ } }
  }

  function setProgress(p) {
    var pct = Math.max(0, Math.min(1, p))
    ui.bar.style.width = Math.round(pct * 100) + '%'
  }

  /** 六格阶段柱：走过的压暗、当前的拉满并点亮主题橙 */
  function setSlats(active) {
    var items = ui.slats.children
    for (var i = 0; i < items.length; i++) {
      var idx = i + 1
      items[i].classList.toggle('dsu-on', idx === active)
      items[i].classList.toggle('dsu-past', idx < active)
    }
  }

  /** 右侧自检清单：第 n 步点亮第 n 项，前面的转成冷色已读态 */
  function setChecks(active) {
    if (!ui.checks) return
    var items = ui.checks.querySelectorAll('.dsu-check')
    for (var i = 0; i < items.length; i++) {
      var idx = i + 1
      items[i].classList.toggle('dsu-on', idx === active)
      items[i].classList.toggle('dsu-past', idx < active)
    }
  }

  /** 扫描线自上而下扫一遍（底板洗白后一次，验准时再一次） */
  function sweep() {
    if (!ui.scanline) return
    ui.scanline.classList.remove('dsu-go')
    void ui.scanline.offsetWidth
    ui.scanline.classList.add('dsu-go')
  }

  function paintClock() {
    var d = new Date()
    var pad = function (n) { return (n < 10 ? '0' : '') + n }
    ui.meta2.textContent = pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds())
  }

  function setSubtitle(zh, en) {
    ui.subZh.classList.remove('dsu-in')
    ui.subEn2.classList.remove('dsu-in')
    setTimeout(function () {
      ui.subZh.textContent = zh || ''
      ui.subEn2.textContent = en || ''
      ui.subZh.classList.add('dsu-in')
      if (en) ui.subEn2.classList.add('dsu-in')
    }, ms(140))
  }

  function setStepCount(i, code) {
    var totalSteps = STEPS.length + 1
    ui.stepcount.textContent = '[ ' + String(i).padStart(2, '0') + ' / ' +
      String(totalSteps).padStart(2, '0') + ' ] ' + code
  }

  function startHex() {
    var lines = 12
    /* 种子来自真实 facts：同一台机器每次启动的"数据流"稳定，
       换 profile / 模型 / bundle 数就会变 —— 读起来像在读这台机器，而不是随机噪声。 */
    var seed = String(F.hash || 'DSHBOOT') + '|' + String(F.model || '') + '|' + String(F.bundleCount || '')
    var h = 2166136261
    for (var k = 0; k < seed.length; k++) {
      h ^= seed.charCodeAt(k)
      h = Math.imul(h, 16777619) >>> 0
    }
    var tick = 0
    function line() {
      var s = ''
      for (var i = 0; i < 26; i++) {
        h = (Math.imul(h, 1664525) + 1013904223 + (tick++)) >>> 0
        s += '0123456789ABCDEF'.charAt(h >>> 28)
        if (i % 2 === 1) s += ' '
      }
      return s
    }
    function paint() {
      var out = []
      for (var i = 0; i < lines; i++) out.push(line())
      ui.hex.innerHTML = out.join('<br>')
    }
    paint()
    ui.hex.classList.add('dsu-in')
    audio.tickRun()
    hexTimer = setInterval(paint, 110)
  }
  function stopHex() {
    if (hexTimer) { clearInterval(hexTimer); hexTimer = null }
    ui.hex.classList.remove('dsu-in')
  }

  /* ── 活体光场（1.6.0）──────────────────────────────────────────────────
   * 背景不再只有两团缓慢移动的 CSS 光斑，而是一层低分辨率的 Canvas：
   *   · 星尘：三层不同景深，中心区域自动降亮，不压文字；
   *   · 流光：四条横向贝塞尔光带，相位互相错开，像设备内部的数据流；
   *   · 边缘数据雨：只落在左右 18% 的留白里，极低亮度；
   *   · 底部水线：三条低频正弦，和底部信号轨迹接成一个系统。
   * Canvas 以 devicePixelRatio（上限 1.5）渲染，但所有图形都刻意保持低对比，
   * 既让画面持续有生命，又不会变成屏保。减少动态效果时只画一帧静态构图。
   * ⚠ 上限 1.75→1.5（2026-10-22 性能改版）：全屏 canvas（2240×1400）与
   *   SVG filter 叠加时光栅单元互相争抢，实测整页掉到 55fps。1.5 时
   *   1920×1200 面积 -26%，背景元素全是低对比柔光，视觉无损。
   * ========================================================================== */
  /* fieldHandle 已在调用点之前声明（见"活体光场"调用处），此处不再重复 var。 */

  function stopField() {
    if (!fieldHandle) return
    fieldHandle.stop()
    fieldHandle = null
  }

  function startField() {
    var cv = ui.field
    if (!cv || typeof cv.getContext !== 'function') return
    var ctx = null
    try { ctx = cv.getContext('2d') } catch (e) { return }
    if (!ctx) return

    var reduced = false
    try {
      reduced = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches)
    } catch (e) { /* 老 WebView 没有 matchMedia，按正常动效处理 */ }

    var dpr = Math.min(1.5, Math.max(1, Number(window.devicePixelRatio) || 1))
    var W = 0
    var H = 0
    var raf = 0
    var frames = 0
    var startedAt = Date.now()
    function fieldNow() { return Math.max(0, Date.now() - startedAt) }
    var palette = C.theme === 'dark'
      ? { cool: '111,211,232', warm: '255,177,102', dim: '224,241,246' }
      : { cool: '38,108,122', warm: '164,91,38', dim: '48,64,66' }

    /* 同一台机器、同一份 facts，光场构图一致 —— 不是每次刷新都换一张随机壁纸。 */
    var state = 2166136261
    var seed = String(F.hash || 'DSHBOOT') + '|' + String(F.profile || '') + '|' + String(F.bundleCount || '')
    for (var k = 0; k < seed.length; k++) {
      state ^= seed.charCodeAt(k)
      state = Math.imul(state, 16777619) >>> 0
    }
    function rand() {
      state = (Math.imul(state, 1664525) + 1013904223) >>> 0
      return state / 4294967296
    }

    var motes = []
    var ribbons = []
    var columns = []

    function resize() {
      W = Math.max(1, Number(cv.clientWidth) || Number(root.clientWidth) || Number(window.innerWidth) || 1600)
      H = Math.max(1, Number(cv.clientHeight) || Number(root.clientHeight) || Number(window.innerHeight) || 1020)
      cv.width = Math.round(W * dpr)
      cv.height = Math.round(H * dpr)
      if (cv.style) {
        cv.style.width = '100%'
        cv.style.height = '100%'
      }
      if (typeof ctx.setTransform === 'function') ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      spawn()
    }

    function spawn() {
      motes.length = 0
      ribbons.length = 0
      columns.length = 0
      var count = Math.round(Math.min(150, Math.max(74, (W * H) / 13500)))
      for (var i = 0; i < count; i++) {
        motes.push({
          x: rand() * W,
          y: rand() * H,
          z: 0.24 + rand() * 0.76,
          r: 0.35 + rand() * 1.35,
          ax: 10 + rand() * 54,
          ay: 7 + rand() * 38,
          sp: 0.000025 + rand() * 0.000075,
          ph: rand() * Math.PI * 2,
          tw: 0.00028 + rand() * 0.00066,
          warm: rand() < 0.24
        })
      }
      for (var r = 0; r < 4; r++) {
        ribbons.push({
          y: 0.20 + r * 0.18 + rand() * 0.055,
          amp: 0.028 + rand() * 0.042,
          sp: 0.000022 + rand() * 0.000026,
          ph: rand() * Math.PI * 2,
          wide: 5 + rand() * 8,
          warm: r === 1
        })
      }
      for (var c = 0; c < 12; c++) {
        columns.push({
          side: c % 2,
          x: c < 6 ? (0.025 + rand() * 0.12) : (0.855 + rand() * 0.12),
          y: rand(),
          len: 24 + rand() * 86,
          sp: 0.000006 + rand() * 0.000012
        })
      }
    }

    function drawRibbon(r, now) {
      var drift = now * r.sp
      var x0 = -W * 0.12
      var x1 = W * 1.12
      var y0 = H * (r.y + Math.sin(drift + r.ph) * r.amp)
      var y1 = H * (r.y + Math.cos(drift * 0.82 + r.ph) * r.amp * 1.25)
      var c1 = H * (r.y + Math.sin(drift * 0.64 + r.ph) * r.amp * 2.1)
      var c2 = H * (r.y + Math.cos(drift * 0.57 + r.ph * 1.4) * r.amp * 2.4)
      var rgb = r.warm ? palette.warm : palette.cool
      var grad = ctx.createLinearGradient(0, 0, W, 0)
      grad.addColorStop(0, 'rgba(' + rgb + ',0)')
      grad.addColorStop(0.22, 'rgba(' + rgb + ',' + (C.theme === 'dark' ? 0.055 : 0.045) + ')')
      grad.addColorStop(0.50, 'rgba(' + rgb + ',' + (C.theme === 'dark' ? 0.14 : 0.085) + ')')
      grad.addColorStop(0.78, 'rgba(' + rgb + ',' + (C.theme === 'dark' ? 0.050 : 0.040) + ')')
      grad.addColorStop(1, 'rgba(' + rgb + ',0)')
      ctx.strokeStyle = grad
      ctx.lineCap = 'round'
      ctx.beginPath()
      ctx.moveTo(x0, y0)
      ctx.bezierCurveTo(W * 0.28, c1, W * 0.70, c2, x1, y1)
      /* ⚠ 2026-10-22 性能改版：原先是"粗线 alpha 0.16 + 细线 alpha 0.72"
         两次全宽 bezier stroke。合成一次：线宽不变，alpha 取 0.5 ——
         双描边叠加的视觉（宽而淡的带 + 较亮的芯）与单描边中等 alpha
         几乎无差，但每帧全宽 bezier 光栅量直接减半（4 条光带 ×2 → ×1）。 */
      ctx.lineWidth = r.wide
      ctx.globalAlpha = 0.5
      ctx.stroke()

      /* 光带上的读取头：沿同一条贝塞尔曲线移动的小光点。
         这是背景"活着"最直接的证据 —— 静止截图里仍能看到它留下的亮部。 */
      var u = ((now * 0.000034 + r.ph / (Math.PI * 2)) % 1 + 1) % 1
      var v = 1 - u
      var px = v * v * v * x0 + 3 * v * v * u * (W * 0.28) +
        3 * v * u * u * (W * 0.70) + u * u * u * x1
      var py = v * v * v * y0 + 3 * v * v * u * c1 +
        3 * v * u * u * c2 + u * u * u * y1
      var cdx = (px / W - 0.5) * 2
      var cdy = (py / H - 0.45) * 2
      var cometFade = Math.min(1, Math.max(0.16, Math.sqrt(cdx * cdx + cdy * cdy) * 1.4))
      ctx.beginPath()
      ctx.fillStyle = 'rgba(' + rgb + ',' + (0.11 * cometFade).toFixed(3) + ')'
      ctx.arc(px, py, r.wide * 2.4, 0, Math.PI * 2)
      ctx.fill()
      ctx.beginPath()
      ctx.fillStyle = 'rgba(' + rgb + ',' + (0.72 * cometFade).toFixed(3) + ')'
      ctx.arc(px, py, r.warm ? 1.25 : 1.05, 0, Math.PI * 2)
      ctx.fill()
      ctx.globalAlpha = 1
    }

    function draw(now, still) {
      ctx.clearRect(0, 0, W, H)
      ctx.globalCompositeOperation = C.theme === 'dark' ? 'lighter' : 'source-over'

      /* 一条极慢的垂直光带，像扫描仪走过整张底板。 */
      var sx = ((now * 0.012) % (W + 260)) - 130
      var sweep = ctx.createLinearGradient(sx - 150, 0, sx + 150, 0)
      sweep.addColorStop(0, 'rgba(' + palette.cool + ',0)')
      sweep.addColorStop(0.5, 'rgba(' + palette.cool + ',' + (C.theme === 'dark' ? 0.028 : 0.018) + ')')
      sweep.addColorStop(1, 'rgba(' + palette.cool + ',0)')
      ctx.fillStyle = sweep
      ctx.fillRect(sx - 150, 0, 300, H)

      for (var r = 0; r < ribbons.length; r++) drawRibbon(ribbons[r], now)

      /* 底部三条低频水线：把画面下半部从"空"变成"深"。 */
      for (var w = 0; w < 3; w++) {
        ctx.beginPath()
        for (var x = 0; x <= W; x += 26) {
          var wy = H * (0.745 + w * 0.052) +
            Math.sin(x * 0.0062 + now * 0.00022 + w * 1.7) * (3 + w * 1.4) +
            Math.sin(x * 0.013 - now * 0.00014 + w) * 1.6
          if (x === 0) ctx.moveTo(x, wy)
          else ctx.lineTo(x, wy)
        }
        ctx.strokeStyle = 'rgba(' + (w === 1 ? palette.warm : palette.cool) + ',' +
          (C.theme === 'dark' ? 0.050 : 0.032) + ')'
        ctx.lineWidth = 0.8
        ctx.stroke()
      }

      /* 边缘数据雨：只在左右留白里，中心永远干净。 */
      for (var c = 0; c < columns.length; c++) {
        var col = columns[c]
        var cy = ((col.y + now * col.sp) % 1.2) * H - col.len
        ctx.fillStyle = 'rgba(' + palette.dim + ',' + (C.theme === 'dark' ? 0.035 : 0.022) + ')'
        ctx.fillRect(Math.round(col.x * W), cy, 1, col.len)
      }

      /* 星尘：近层大而亮、远层小而暗；中心 30% 半径内降亮到 18%。 */
      for (var m = 0; m < motes.length; m++) {
        var dot = motes[m]
        var mx = dot.x + Math.sin(now * dot.sp + dot.ph) * dot.ax
        var my = dot.y + Math.cos(now * dot.sp * 0.83 + dot.ph) * dot.ay
        if (still) { mx = dot.x; my = dot.y }
        var nx = (mx / W - 0.5) * 2
        var ny = (my / H - 0.45) * 2
        var dist = Math.sqrt(nx * nx * 1.18 + ny * ny)
        var centerFade = Math.min(1, Math.max(0.18, dist * 1.32))
        var twinkle = 0.62 + 0.38 * Math.sin(now * dot.tw + dot.ph)
        var alpha = (0.045 + dot.z * 0.16) * centerFade * twinkle
        var rgbDot = dot.warm ? palette.warm : palette.cool
        ctx.beginPath()
        ctx.fillStyle = 'rgba(' + rgbDot + ',' + alpha.toFixed(3) + ')'
        ctx.arc(mx, my, dot.r * dot.z, 0, Math.PI * 2)
        ctx.fill()
        /* ⚠ 2026-10-22 删掉大半径光晕圆（r×4.2、alpha≈0.0054）：实测
           视觉贡献为零，却让每帧 arc 调用量接近翻倍 —— 150 个粒子时
           光栅开销白涨 40%。星尘就是星尘，不需要每个都带雾。 */
      }
      ctx.globalAlpha = 1
      ctx.globalCompositeOperation = 'source-over'
    }

    function frame() {
      if (!fieldHandle) return
      draw(fieldNow(), false)
      frames++
      if (fieldHandle) fieldHandle.frames = frames
      raf = window.requestAnimationFrame(frame)
    }

    function onResize() {
      resize()
      draw(fieldNow(), true)
    }
    function onVisibility() {
      if (document.hidden) {
        if (raf) { window.cancelAnimationFrame(raf); raf = 0 }
      } else if (!reduced && !raf) {
        raf = window.requestAnimationFrame(frame)
      }
    }

    fieldHandle = {
      frames: 0,
      width: function () { return W },
      height: function () { return H },
      draw: function (ms, still) { draw(ms || 0, !!still) },
      stop: function () {
        if (raf) { window.cancelAnimationFrame(raf); raf = 0 }
        window.removeEventListener('resize', onResize)
        document.removeEventListener('visibilitychange', onVisibility)
      }
    }
    window.__DSH_STARTUP_FIELD__ = fieldHandle
    window.addEventListener('resize', onResize)
    document.addEventListener('visibilitychange', onVisibility)
    resize()
    draw(0, true)
    if (!reduced) raf = window.requestAnimationFrame(frame)
  }

  /* ── 声音 ──────────────────────────────────────────────────────────────
   * 两条独立的通道，都不依赖任何音频文件：
   *   audio —— 界面音效，WebAudio 现场合成（咔哒 / 双音确认 / 噪声扫频 / 和声钟）
   *   voice —— 女声播报，Web Speech API 念每一行的英文（照参考片的女声节奏：
   *            7.3-9.3s 念状态行、19.6-21.2s 念 PERMISSION AUTHORIZED）
   * 浏览器策略要求"先有用户手势"，所以第一次点击/按键会补一次解锁 + 补播。 */
  function clamp01(v, lo, hi) {
    var n = Number(v)
    return isFinite(n) ? Math.min(hi, Math.max(lo, n)) : lo
  }

  /* 素材由 Host 路由下发，并带 24h 强缓存（见 lib/index.js 的 Cache-Control）。
     换过素材文件后浏览器仍会拿旧的那份，所以 URL 必须挂版本串破缓存；
     查询串在 Host 侧「取 basename 之前」就被剥掉，不影响白名单校验。
     audio（音效 / 台词素材）与下面的 bgm 共用这一个构造器。 */
  /* ⚠ 移植改动（DSH → 独立 macOS 启动器）：
     原来是 DSH 的 HTTP 路由 `/dsh-startup/asset/<name>.mp3`，
     现在是 WKWebView 里 file:// 加载的本地资源 → 直接用同目录相对路径。
     素材缺失时 audio 层会自动回落到 WebAudio 合成音，**不影响动画播放**。 */
  var ASSET_V = String(window.__WB_BOOT_VERSION__ || '1')
  function assetUrl(name, ext) { return name + '.' + (ext || 'm4a') + '?v=' + ASSET_V }

  var audio = (function () {
    var ctx = null
    function ac(force) {
      /* 语音素材要独立于「界面音效」开关：force=true 时无视 C.sound */
      if (!C.sound && !force) return null
      try {
        var AC = window.AudioContext || window.webkitAudioContext
        if (!AC) return null
        if (!ctx) ctx = new AC()
        if (ctx.state === 'suspended' && typeof ctx.resume === 'function') ctx.resume()
        return ctx
      } catch (e) { return null }
    }
    /* ── 自动播放被拦时的自救 ──────────────────────────────────────────
       浏览器（以及默认配置下的 WKWebView）在没有用户手势时会把 AudioContext
       钉在 suspended：`src.start()` 不抛错、也**一点声音都没有**，日志干干净净。
       这里把"该响没响的那一句"记下来，等第一次点击/按键再补播。 */
    var pendingVoice = null
    var gestureArmed = false
    var warnedAutoplay = false
    function armGesture() {
      if (gestureArmed) return
      gestureArmed = true
      var kick = function () {
        try { if (ctx && ctx.state !== 'running' && ctx.resume) ctx.resume() } catch (e) {}
        var n = pendingVoice
        pendingVoice = null
        if (n) setTimeout(function () { try { playAssetAndWait(n, 0.85) } catch (e) {} }, 80)
        window.removeEventListener('pointerdown', kick, true)
        window.removeEventListener('keydown', kick, true)
      }
      window.addEventListener('pointerdown', kick, true)
      window.addEventListener('keydown', kick, true)
    }

    function vol(gain) { return Math.max(0.0002, (gain == null ? 0.05 : gain) * clamp01(C.soundVolume, 0, 1) * 2) }
    function tone(freq, dur, type, gain, delay, glideTo) {
      var c = ac(); if (!c) return
      try {
        var t0 = c.currentTime + (delay || 0)
        var o = c.createOscillator(), g = c.createGain()
        o.type = type || 'sine'
        o.frequency.setValueAtTime(freq, t0)
        if (glideTo) o.frequency.exponentialRampToValueAtTime(glideTo, t0 + dur)
        g.gain.setValueAtTime(0.0001, t0)
        g.gain.exponentialRampToValueAtTime(vol(gain), t0 + Math.min(0.02, dur * 0.3))
        g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur)
        o.connect(g); g.connect(c.destination)
        o.start(t0); o.stop(t0 + dur + 0.03)
      } catch (e) { /* 静默降级 */ }
    }
    function noise(dur, gain) {
      var c = ac(); if (!c) return
      try {
        var n = Math.floor(c.sampleRate * dur)
        var buf = c.createBuffer(1, n, c.sampleRate)
        var d = buf.getChannelData(0)
        for (var i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / n)
        var src = c.createBufferSource(); src.buffer = buf
        var f = c.createBiquadFilter(); f.type = 'bandpass'
        f.frequency.value = 1500; f.Q.value = 0.6
        var g = c.createGain(); g.gain.value = vol(gain)
        src.connect(f); f.connect(g); g.connect(c.destination)
        src.start()
      } catch (e) { /* 静默降级 */ }
    }
    /* ── 金属音：合成，不用素材 ───────────────────────────────────────
       参考视频里的交互声是"金属片被轻碰"，不是电子哔。三层叠出来：
         ① 4–8ms 的噪声爆，过带通（带 Q）→ 那一下"碰"的硬度；
         ② 三个**非谐波**分音（1 : 2.76 : 5.40）→ 金属的"片"感。
            谐波整数倍的泛音听起来像乐音，非谐波才像金属；
         ③ 可选 70→46Hz 的 sub → 只给"揭幕"这种大节点加，做重量。
       优点：0 KB 素材、延迟 <10ms、可按档位只改 2 个参数。 */
    function metal(o) {
      var c = ac(); if (!c) return
      o = o || {}
      var t0 = c.currentTime + (o.delay || 0)
      var dur = o.dur || 0.26
      var center = o.freq || 2100
      var g0 = Math.max(0.0002, (o.gain == null ? 0.06 : o.gain) * clamp01(C.soundVolume, 0, 1) * 2)

      var n = Math.floor(c.sampleRate * 0.008)
      var buf = c.createBuffer(1, n, c.sampleRate)
      var d = buf.getChannelData(0)
      for (var i = 0; i < n; i++) {
        var k = 1 - i / n
        d[i] = (Math.random() * 2 - 1) * k * k * k
      }
      var src = c.createBufferSource(); src.buffer = buf
      var bp = c.createBiquadFilter(); bp.type = 'bandpass'
      bp.frequency.value = center; bp.Q.value = (o.q == null ? 2.2 : o.q)
      var g = c.createGain(); g.gain.value = g0
      src.connect(bp); bp.connect(g); g.connect(c.destination)
      src.start(t0)

      /* ② 本体：200–800Hz 的短促共鸣。
         参考视频里瞬态的频谱重心只有 216–833Hz —— 机械声的"重量"全在这一层；
         只做高频就会变成"电子哔"，这也是第一版听着不对的真正原因。 */
      if (o.body) {
        var bo = c.createOscillator(); bo.type = 'triangle'
        /* o.chirp：起音后整体上扬（>1）—— 这一下是"信息感"的来源：
           上扬 = 被识别/被接收，下垂 = 拒绝/失效。悬停用上扬。 */
        var up = o.chirp || 1
        bo.frequency.setValueAtTime(o.body * 1.45, t0)
        bo.frequency.exponentialRampToValueAtTime(o.body * up, t0 + 0.030)
        var bg = c.createGain()
        bg.gain.setValueAtTime(0.0001, t0)
        bg.gain.exponentialRampToValueAtTime(Math.max(0.0002, g0 * 1.9), t0 + 0.005)
        bg.gain.exponentialRampToValueAtTime(0.0001, t0 + dur * 0.85)
        bo.connect(bg); bg.connect(c.destination)
        bo.start(t0); bo.stop(t0 + dur + 0.06)
      }

      var parts = o.partials || [1, 2.76, 5.4]
      for (var j = 0; j < parts.length; j++) {
        var osc = c.createOscillator(); osc.type = 'sine'
        osc.frequency.setValueAtTime(center * 0.62 * parts[j], t0)
        var gg = c.createGain()
        gg.gain.setValueAtTime(0.0001, t0)
        gg.gain.exponentialRampToValueAtTime(Math.max(0.0002, g0 * (0.55 / (j + 1))), t0 + 0.004)
        gg.gain.exponentialRampToValueAtTime(0.0001, t0 + dur * (1 - j * 0.18))
        osc.connect(gg); gg.connect(c.destination)
        osc.start(t0); osc.stop(t0 + dur + 0.06)
      }

      if (o.sub) {
        var so = c.createOscillator(); so.type = 'sine'
        so.frequency.setValueAtTime(70, t0)
        so.frequency.exponentialRampToValueAtTime(46, t0 + 0.18)
        var sg = c.createGain()
        sg.gain.setValueAtTime(0.0001, t0)
        sg.gain.exponentialRampToValueAtTime(Math.max(0.0002, g0 * 2.4), t0 + 0.012)
        sg.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.42)
        so.connect(sg); sg.connect(c.destination)
        so.start(t0); so.stop(t0 + 0.5)
      }
    }

    /* 从 /dsh-startup/asset/ 拉真素材（用户音频里抠出来的"哒"）并解码缓存；
       拿不到就自动回落到下面合成的音，功能不依赖网络/素材存在与否。 */
    var buffers = {}
    var fetching = {}
    /* ── 素材诊断出口 ─────────────────────────────────────────────────
       原来 loadAsset 的 catch 是**空的**：素材加载失败就悄悄回落合成音，
       现场只觉得"有点电子味"，查不到根因。这类静默失败这一轮已经咬了两次
       （bgmVolume 未定义、loadAsset 从没被调用）。
       现在把状态挂到 window.__WB_AUDIO_STATUS__，并且每个素材只 warn 一次。 */
    var diag = (typeof window !== 'undefined')
      ? (window.__WB_AUDIO_STATUS__ = window.__WB_AUDIO_STATUS__ || { ok: [], failed: [], synth: [] })
      : { ok: [], failed: [], synth: [] }
    function note(kind, name) {
      try {
        if (!diag[kind]) return
        if (diag[kind].indexOf(name) < 0) diag[kind].push(name)
        if (kind === 'failed' && window.console && console.warn) {
          console.warn('[audio] 素材加载失败，回落合成音：' + name)
        }
      } catch (e) {}
    }

    function loadAsset(name) {
      if (C.sfx === 'synth') return
      if (buffers[name] || fetching[name]) return
      fetching[name] = true
      try {
        fetch(assetUrl(name))
          .then(function (r) { return r.ok ? r.arrayBuffer() : null })
          .then(function (ab) { return ab ? ac().decodeAudioData(ab) : null })
          .then(function (buf) {
            if (buf) { buffers[name] = buf; note('ok', name) } else { note('failed', name) }
          })
          .catch(function () { note('failed', name) })
      } catch (e) { note('failed', name) }
    }
    /* 素材预加载：fetch + decodeAudioData 不需要用户手势，所以加载时就拉，
       这样第一步就能用真声，而不用等用户第一次点击。 */
    var pending = {}
    /* ⚠ fetch 在 file:// 下会被直接拦掉（没有同源可谈），
       开机动画正是 file:// —— 于是 decodeAudioData 这条路整个失效，
       而且失败是**静默**的：resolve(false)、时间线照走，只是没人声。
       所以留一条退路：fetch 拿不到就退回 <audio> 元素流式播放。 */
    var mediaEl = {}
    function ensureAsset(name) {
      if (buffers[name] || mediaEl[name]) return Promise.resolve(true)
      if (pending[name]) return pending[name]
      if (C.voiceSource === 'tts') return Promise.resolve(false)
      pending[name] = new Promise(function (resolve) {
        var settled = false
        function done(ok) { if (settled) return; settled = true; resolve(ok) }
        function fallbackToElement() {
          try {
            var el = document.createElement('audio')
            el.src = assetUrl(name)
            el.preload = 'auto'
            el.addEventListener('canplaythrough', function () { mediaEl[name] = el; done(true) }, false)
            el.addEventListener('error', function () { note('failed', name); done(false) }, false)
            el.load()
          } catch (e) { done(false) }
        }
        try {
          fetch(assetUrl(name))
            .then(function (r) { return r.ok ? r.arrayBuffer() : null })
            .then(function (ab) {
              if (!ab) { fallbackToElement(); return null }
              var c = ac(true)
              if (!c) { fallbackToElement(); return null }
              return c.decodeAudioData(ab).catch(function () { fallbackToElement(); return null })
            })
            .then(function (buf) { if (buf) { buffers[name] = buf; done(true) } })
            .catch(function () { fallbackToElement() })
        } catch (e) { fallbackToElement() }
      })
      return pending[name]
    }

    /** 播素材并等它播完，resolve 实际时长(ms)。拿不到素材 resolve 0。 */
    function playAssetAndWait(name, gain) {
      return new Promise(function (resolve) {
        /* 元素退路优先：file:// 下只有它能出声 */
        var el = mediaEl[name]
        if (el) {
          try {
            el.currentTime = 0
            el.volume = Math.max(0, Math.min(1, (gain == null ? 0.85 : gain) * clamp01(C.voiceVolume, 0, 1)))
            var onEnd = function () {
              el.removeEventListener('ended', onEnd)
              resolve(Math.round((el.duration || 0) * 1000))
            }
            el.addEventListener('ended', onEnd, false)
            var pr = el.play()
            if (pr && pr.catch) pr.catch(function () { el.removeEventListener('ended', onEnd); resolve(0) })
            return
          } catch (e) { resolve(0); return }
        }
        var c = ac(true)
        var buf = buffers[name]
        if (!c || !buf) { resolve(0); return }
        /* 上下文没在跑 = 被自动播放策略拦住了：记下来、等手势补播，别静默失败 */
        if (c.state !== 'running') {
          pendingVoice = name
          armGesture()
          if (!warnedAutoplay && window.console && console.warn) {
            warnedAutoplay = true
            console.warn('[audio] 自动播放被拦截（state=' + c.state + '），等第一次点击/按键后补播')
          }
          resolve(0); return
        }
        try {
          var src = c.createBufferSource()
          src.buffer = buf
          var g = c.createGain()
          /* 人声增益由 mix.voice 推导：5/10 = 0.5 → 峰值落在 -8dBFS 附近。
             原来那个 1.6 会把人声推到 -1.5dBFS（比配乐高 20dB），是"跳出来"的根源。 */
          var mixV = (C.mix && C.mix.voice ? C.mix.voice : 5) / 10
          g.gain.value = Math.min(1, (gain == null ? 0.85 : gain) * clamp01(C.voiceVolume, 0, 1) * mixV)
          src.connect(g); g.connect(c.destination)
          src.onended = function () { resolve(Math.round(buf.duration * 1000)) }
          src.start()
        } catch (e) { resolve(0) }
      })
    }

    function playAsset(name, gain) {
      var c = ac(); if (!c) return false
      var buf = buffers[name]
      if (!buf) { loadAsset(name); return false }
      try {
        var src = c.createBufferSource()
        src.buffer = buf
        var g = c.createGain()
        g.gain.value = Math.min(1, (gain == null ? 0.55 : gain) * clamp01(C.soundVolume, 0, 1) * 2)
        src.connect(g); g.connect(c.destination)
        src.start()
        return true
      } catch (e) { return false }
    }

    return {
      resume: function () {
        ac(); loadAsset('sfx-tick'); loadAsset('sfx-ticks-run')
        /* 交互三件套已改回合成，不再加载素材 */
      },
      preload: function () {
        loadAsset('sfx-tick'); loadAsset('sfx-ticks-run')
      },
      ensureAsset: ensureAsset,
      playAssetAndWait: playAssetAndWait,
      /* 文字渐显 / 阶段推进 / 按钮确认 —— 优先用真素材 */
      tick: function () { if (!playAsset('sfx-tick', 0.45)) tone(1760, 0.035, 'square', 0.022) },
      tickRun: function () { playAsset('sfx-ticks-run', 0.5) },
      step: function () { if (!playAsset('sfx-tick', 0.6)) { tone(880, 0.05, 'sine', 0.05); tone(1320, 0.07, 'sine', 0.028, 0.045) } },
      /* ── 交互三件套：**合成**，不从音乐里切 ────────────────────────────
         用户要的两件事：
           · 悬停 = "识别到鼠标"：一个**上扬**的短音（上扬读作"收到/确认"，
             下垂读作"拒绝"），所以 body 给了 chirp 1.9；
           · 点击 = 机械落位：接触噪声 + 低中频本体 + 一段短金属余响。
         三档的电平是按 dBFS 排过的（见下面的 gain 注释），和配乐 -22dB、
         人声 -6.5dB 摆在一起不会有人某一层"跳出来"。 */
      /* -33 dBFS：只够"手指划过"，不抢任何东西 */
      hover: function () { metal({ freq: 2900, body: 640, chirp: 1.9, dur: 0.055, gain: 0.022, q: 3.8 }) },
      /* -19 dBFS：比人声低 11dB（= 2/5），但明显高于配乐 —— 点下去必须听到 */
      tap: function () { metal({ freq: 1600, body: 400, dur: 0.16, gain: 0.112, q: 2.2 }) },
      /* -12 dBFS：只出现一次（揭幕），允许比音效档更响 */
      reveal: function () { metal({ freq: 950, body: 200, dur: 0.62, gain: 0.20, q: 1.5, sub: true }) },
      confirm: function () { metal({ freq: 1200, body: 320, dur: 0.42, gain: 0.060, q: 1.8 }) },
      sweep: function () { noise(0.75, 0.035) },
      /* 念台词之前的两声轻提示：这一笔让 TTS 从"浏览器念字"变成"系统播报" */
      cue: function () { tone(1046.5, 0.05, 'sine', 0.028); tone(1568, 0.06, 'sine', 0.02, 0.075) },
      rise: function () { tone(220, 1.1, 'sine', 0.032, 0, 990) },
      chime: function () {
        tone(659.25, 0.9, 'sine', 0.055)
        tone(830.61, 0.9, 'sine', 0.04, 0.09)
        tone(987.77, 1.3, 'sine', 0.045, 0.18)
      }
    }
  })()

  /* ── 背景音乐 ──────────────────────────────────────────────────────────
   * 单独一条轨，走 HTMLAudio 元素而不是 WebAudio 解码，两个理由：
   *   1) 素材 2 分半 / 3.6 MB，decodeAudioData 要占 ~57 MB 内存；元素流式播放
   *      只占几百 KB，而且自带 loop —— 用户在第几步磨蹭多久都不会断。
   *   2) 音量用 30ms 小步手动走斜坡。闪避只要 200ms 级就够，不值得为它引入
   *      MediaElementSource —— 那条路一旦接错就是静音，远程很难查。
   * 起播策略：**立即尝试**。桌面端 Electron 的 webPreferences.autoplayPolicy 默认
   * 就是 no-user-gesture-required（Electron 官方文档原文），DSH 也没覆盖它，
   * 所以黑幕第一帧就能有音乐；web profile 走浏览器默认的
   * document-user-activation-required，会被拦下，那时 start() 自己复位，
   * 退回 unlock() 的第一次用户手势再起 —— 两条路都不需要人工判断宿主。 */
  var bgm = (function () {
    var el = null
    var started = false
    var failed = false
    var stopping = false
    var timer = null
    var level = 0        /* 当前音量 0..1 */
    var want = 0         /* 目标音量 */

    function base() { return clamp01(C.bgmVolume, 0, 1) }
    function on() { return C.bgm !== false && base() > 0 }
    /* 三档电平（用户拍板）：
         底 -22 dB → 人声进来 -28 dB（×0.5）→ 转场 -18 dB（×1.585）。
       0.35 那档是 -31dB，压得比用户要的更低，人声会显得"浮"在音乐上。 */
    /* 闪避深度 0.32 ≈ -10dB。原来 0.5（-6dB）在人声偏闷的时候不够，
       现在人声已经做过清晰度处理，再压深一点，两条轨道的分离就出来了。 */
    function target(ducked) { return ducked && C.bgmDuck !== false ? base() * 0.28 : base() }
    function targetLift(lifted) { return lifted ? base() * 1.585 : base() }

    /* 这里的守卫**不能用全局 finished**：finish() 会先把 finished 置真，
       斜坡会被自己的标志当场掐断，揭幕的淡出就变成硬切 —— 1.2.1 实机就是这个
       症状（音乐秒断）。所以用 bgm 自己的 stopping：只有"要往上抬"才拒绝。 */
    function ramp(to, ms) {
      want = Math.max(0, Math.min(1, to))
      if (timer || !el) return
      var step = Math.max(0.01, Math.abs(want - level) / Math.max(1, ms / 30))
      timer = setInterval(function () {
        if (!el || (stopping && want > 0)) { clearInterval(timer); timer = null; return }
        var d = want - level
        if (Math.abs(d) <= step) { level = want; clearInterval(timer); timer = null }
        else level += d > 0 ? step : -step
        try { el.volume = Math.max(0, Math.min(1, level)) } catch (e) {}
      }, 30)
    }

    /* ── 循环策略：**默认不循环** ────────────────────────────────────────
       这首曲子有完整的起承转合（63.4s），而整段动画约 63s —— 本来就该
       "一遍走完"，硬 loop 会在揭幕前突然跳回前奏，那一下最出戏。
       所以：正常情况一遍到底；只有动画拖得比曲子长（机器慢/用户磨蹭）时，
       才在 ended 之后补一条，并从 0.73s 的 downbeat 淡入 1.5s —— 那时已经
       在揭幕的和声里了，补一条不会被察觉。 */
    var restarting = false
    /* ── "真正出声"回调 ────────────────────────────────────────────────
       el.play() 只是**发起**播放；m4a 在 WKWebView 里要解码+缓冲，
       真正出声可能晚 300–800ms。第一幕的"人声晚 1 秒"如果从调 play() 起算，
       就会变成"人声比音乐先响" —— 用户听到的正是这个。
       这里改用 currentTime 真正在走的那一刻作为起点。 */
    var startedCbs = []
    var watchTimer = null
    function watchStart() {
      if (watchTimer) return
      watchTimer = setInterval(function () {
        if (!el) return
        if (el.currentTime > 0.02 && !el.paused) {
          var list = startedCbs.slice()
          startedCbs.length = 0
          clearInterval(watchTimer); watchTimer = null
          for (var i = 0; i < list.length; i++) { try { list[i]() } catch (e) {} }
        }
      }, 30)
    }

    function onTrackEnded() {
      if (restarting || finished || stopping || !started) return
      restarting = true
      try {
        var neu = document.createElement('audio')
        neu.src = el.src
        neu.preload = 'auto'
        neu.loop = false
        neu.volume = 0
        try { neu.currentTime = 0.73 } catch (e) {}
        var p2 = neu.play()
        if (p2 && p2.catch) p2.catch(function () { restarting = false })
        var t0 = Date.now(), D = 1500
        var t = setInterval(function () {
          var k = Math.min(1, (Date.now() - t0) / D)
          try { neu.volume = Math.max(0, Math.min(1, level * k)) } catch (e) {}
          if (k >= 1) {
            clearInterval(t)
            try { el.pause() } catch (e) {}
            el = neu
            restarting = false
          }
        }, 40)
      } catch (e) { restarting = false }
    }

    function prepare() {
      if (el || failed || !on()) return
      try {
        el = document.createElement('audio')
        /* 用 m4a（AAC 96k）而不是原始 mp3：体积从 1.6MB 降到 750KB，
           而且 afconvert 出来的包在 WKWebView 里解得更稳。 */
        el.src = assetUrl('bgm', 'm4a')
        /* ⚠ 不用 el.loop = true：HTMLAudio 的硬 loop 是"播完立刻从头开始"，
           接缝处一刀切，听感就是"这首曲子又从头来了一遍"。
           改成结尾前 2.4 秒起第二条轨、交叉淡化 —— 接缝被抹平。 */
        el.loop = false
        el.preload = 'auto'
        el.volume = 0
      } catch (e) { failed = true }
    }

    return {
      /** 提前建元素把文件缓冲起来，用户一点就能出声 */
      prepare: prepare,
      start: function () {
        if (started || failed || !on()) return
        if (!el) prepare()
        if (!el) return
        started = true
        try {
          /* 从 0 起：bgm.m4a 已经重新裁过——切点对齐到一个强拍（88.30s 处），
             首尾都做过淡入淡出，所以文件本身第一帧就是 downbeat。
             （上一版是从原曲 0.73s 起，因为那首前面有 0.7s 弱起。） */
          try { el.currentTime = 0 } catch (e0) {}
          try { el.addEventListener('ended', onTrackEnded) } catch (e) {}
          var p = el.play()
          watchStart()
          /* 被自动播放策略拦下（web profile 的浏览器默认）：复位，等 unlock() 再起。
             桌面端 Electron 默认宽松，这句通常不会执行。 */
          if (p && typeof p.catch === 'function') {
            p.catch(function () {
              started = false
              if (timer) { clearInterval(timer); timer = null }
              level = 0
              try { el.volume = 0; el.pause() } catch (e) {}
            })
          }
          ramp(target(false), 320)
        } catch (e) { started = false }
      },
      /** 台词通道开合时调用；把闪避关掉就直接抬回原音量 */
      duck: function (ducked) {
        if (!started || failed || !el || finished || stopping) return
        ramp(target(ducked), ducked ? 120 : 520)
      },
      /* ── 场景对齐（交互加速时的配乐策略）─────────────────────────────
         三种情况分开处理，不是一套逻辑通吃：
           ① 不交互：时间线 ~63s、音乐 65.2s，天然同步，**永远不跳**；
           ② 轻度交互（跳 1–2 幕，偏差 ≤ tol）：**不追**。音乐没有语义，
              慢两三秒没人听得出来；追得越勤，接缝越容易被听到；
           ③ 重度交互（连跳，偏差 > tol）：在**幕的边界**上一次性软跳回，
              而不是每次跳一点 —— 前者落在段落上，后者会变成每 3 秒一跳很碎。
         软跳 = 120ms 压到 0 → seek → 260ms 抬回，避免 seek 的咔哒。 */
      align: function (t, tol) {
        if (!started || failed || !el || stopping || restarting) return
        var cur = el.currentTime
        if (Math.abs(cur - t) <= (tol == null ? 2.5 : tol)) return
        var restore = want > 0 ? want : base()
        var target = Math.max(0, t)
        ramp(0, 120)
        setTimeout(function () {
          try {
            var d = el.duration
            if (d && isFinite(d)) target = Math.min(target, d - 0.25)
            el.currentTime = Math.max(0, target)
          } catch (e) {}
          ramp(restore, 260)
        }, 160)
      },
      /** 配乐真正出声之后才回调；已经在出声就立刻回调 */
      whenStarted: function (cb) {
        try {
          if (el && el.currentTime > 0.02 && !el.paused) { cb(); return }
          startedCbs.push(cb)
          watchStart()
        } catch (e) {}
      },
      /** 转场抬升：洗白/换幕时把音乐抬到 -18dB，落地后再收回来 */
      lift: function (lifted) {
        if (!started || failed || !el || finished || stopping) return
        ramp(targetLift(lifted), lifted ? 240 : 520)
      },
      /** 揭幕：淡出后停掉，避免和主界面抢声。重复调用只认第一次的时长。 */
      stop: function (ms) {
        if (!started || !el || stopping) return
        stopping = true
        var node = el
        var wait = ms == null ? 900 : ms
        ramp(0, wait)
        setTimeout(function () {
          if (timer) { clearInterval(timer); timer = null }
          try { node.pause() } catch (e) {}
        }, wait + 160)
      }
    }
  })()

  var voice = (function () {
    var supported = typeof window !== 'undefined' && !!window.speechSynthesis &&
      typeof window.SpeechSynthesisUtterance === 'function'
    var voices = []
    var picked = { en: null, zh: null }
    var meter = null
    var saidOnce = false
    var pending = { en: '', zh: '' }

    /* 想让它听起来像"AI 播报"，音色本身比什么都重要。
       同一台机器上，"Microsoft Zira Desktop" 是上世纪拼接合成，念长句塑料味很重；
       Edge 的 "... Online (Natural)"、Chrome 的 "Google ..."、macOS 的 Siri 才是神经网络音色。
       所以这里按分数挑，而不是挨个名字第一个命中。 */
    var NATURAL_HINTS = ['natural', 'neural', 'online', 'premium', 'enhanced', 'siri', 'google']
    var FEMALE_HINTS = [
      'aria', 'jenny', 'michelle', 'emma', 'ava', 'libby', 'sonia', 'maisie',
      'zira', 'samantha', 'karen', 'moira', 'tessa', 'victoria', 'serena', 'allison',
      'susan', 'fiona', 'hazel', 'female', 'woman',
      'xiaoxiao', 'xiaoyi', 'xiaomo', 'huihui', 'yaoyao', '晓晓', '晓伊', '女声'
    ]
    var MALE_HINTS = ['david', 'mark', 'guy', 'ryan', 'george', 'daniel', 'alex', 'fred',
      'male', 'yunxi', 'yunjian', 'kangkang']

    /** 给一个音色打分：神经网络 > 女声 > 语种吻合 > 本地 */
    function score(v, want) {
      var name = String(v.name || '').toLowerCase()
      var lang = String(v.lang || '').toLowerCase()
      var sc = 0
      for (var i = 0; i < NATURAL_HINTS.length; i++) {
        if (name.indexOf(NATURAL_HINTS[i]) !== -1) { sc += 60; break }
      }
      for (var j = 0; j < FEMALE_HINTS.length; j++) {
        if (name.indexOf(FEMALE_HINTS[j]) !== -1) { sc += 40; break }
      }
      for (var k = 0; k < MALE_HINTS.length; k++) {
        if (name.indexOf(MALE_HINTS[k]) !== -1) { sc -= 45; break }
      }
      if (lang.indexOf(want) === 0) sc += 25
      if (v.localService) sc += 4          /* 本地音色起播快，不会先卡半秒 */
      if (v.default) sc += 3
      return sc
    }

    /** 挑某语种最合适的一个音色（want 传 'en' / 'zh' 这样的两字母前缀） */
    function bestFor(want) {
      if (!voices.length) return null
      if (C.voiceName) {
        for (var i = 0; i < voices.length; i++) {
          var v = voices[i]
          if (v.name === C.voiceName && String(v.lang || '').toLowerCase().indexOf(want) === 0) return v
        }
      }
      var pool = []
      for (var j = 0; j < voices.length; j++) {
        if (String(voices[j].lang || '').toLowerCase().indexOf(want) === 0) pool.push(voices[j])
      }
      if (!pool.length) pool = voices.slice()
      var best = null
      var bs = -1e9
      for (var n = 0; n < pool.length; n++) {
        var sc = score(pool[n], want)
        if (sc > bs) { bs = sc; best = pool[n] }
      }
      return best
    }

    function setMeter(on) { if (meter) meter.classList.toggle('dsu-on', !!on) }

    function load() {
      if (!supported) return
      try { voices = window.speechSynthesis.getVoices() || [] } catch (e) { voices = [] }
      picked.en = bestFor('en')
      picked.zh = bestFor('zh')
    }

    /** 全大写名字有些引擎会一个字母一个字母念，转成 Title Case 更像在叫名字 */
    function spokenName(name) {
      return String(name || '').replace(/\S+/g, function (w) {
        return (/^[A-Z0-9.\-]+$/.test(w) && w.length > 1) ? w.charAt(0) + w.slice(1).toLowerCase() : w
      })
    }

    function utter(text, lang) {
      try {
        var u = new window.SpeechSynthesisUtterance(text)
        var v = lang.indexOf('zh') === 0 ? picked.zh : picked.en
        if (v) { u.voice = v; u.lang = v.lang || lang } else u.lang = lang
        /* 神经网络音色在 .95 / 1.02 这个档位最像"系统在播报"：
           再快就赶，再慢就假；音调略抬一点显得干净利落 */
        u.rate = clamp01(C.voiceRate, 0.5, 2)
        u.pitch = clamp01(C.voicePitch, 0, 2)
        u.volume = clamp01(C.voiceVolume, 0, 1)
        u.onstart = function () { setMeter(true) }
        u.onend = function () { setMeter(false) }
        u.onerror = function () { setMeter(false) }
        window.speechSynthesis.speak(u)
        return true
      } catch (e) { return false }
    }

    /** 一句话的时长估算（个别引擎不触发 onend 时兜底；中文按字、英文按字符） */
    function estimateMs(items) {
      var chars = 0
      var rate = clamp01(C.voiceRate, 0.5, 2) || 1
      for (var i = 0; i < items.length; i++) {
        var t = String(items[i].t || '')
        chars += /[\u4e00-\u9fa5]/.test(t) ? t.length * 1.7 : t.length
      }
      return Math.round((chars / 13) * 1000 / rate) + 460
    }

    function buildUtter(text, lang) {
      var u = new window.SpeechSynthesisUtterance(text)
      var v = lang.indexOf('zh') === 0 ? picked.zh : picked.en
      if (v) { u.voice = v; u.lang = v.lang || lang } else u.lang = lang
      u.rate = clamp01(C.voiceRate, 0.5, 2)
      u.pitch = clamp01(C.voicePitch, 0, 2)
      u.volume = clamp01(C.voiceVolume, 0, 1)
      return u
    }

    return {
      supported: supported,
      load: load,
      attach: function (node) { meter = node },

      /**
       * 念一行，返回"这一行实际花了多久(ms)"的 Promise。
       *
       * 三个关键决定：
       *  - **不 cancel 上一句**。原来每步都 cancel，用户点快一点、或者
       *    hold 短于台词长度，语音就被硬生生掐断 —— 那正是要避免的。
       *    speechSynthesis 本身是队列，不 cancel 就是顺序播报。
       *  - 提示音响过之后留 `voiceLead` 的空白再开口，这是旁白的呼吸感。
       *  - 等 `onend` 才 resolve，动画据此决定这一步停多久；个别引擎不触发
       *    onend 时按估算兜底，绝不把动画卡死。
       */
      line: function (en, zh, asset) {
        /* 有真声素材就优先用素材（音色就是你给的那个）；拿不到再回落 TTS */
        if (asset && C.voice && C.voiceSource !== 'tts' && !finished) {
          return audio.ensureAsset(asset).then(function (ok) {
            if (!ok || finished) return 0
            if (C.voiceCue !== false) audio.cue()
            bgm.duck(true)
            return audio.playAssetAndWait(asset, 0.85).then(function (ms) {
              bgm.duck(false)
              if (ms > 0) setMeter(true)
              return ms
            })
          }).then(function (ms) {
            if (ms > 0) { saidOnce = true; return ms }
            /* 素材拿不到，这一句改走 TTS；闪避由 ttsLine 自己收尾 */
            bgm.duck(true)
            return ttsLine(en, zh)
          })
        }
        return ttsLine(en, zh)
      },

      /** TTS 路径：素材缺失 / voiceSource=tts / 终幕那条动态名字 */
      tts: function (en, zh) { return ttsLine(en, zh) },

      /** 不等待的版本：设置页试听 / 任何"念完就行"的场合 */
      say: function (en, zh) { return this.line(en, zh) },

      /** 浏览器要求"先有用户手势"才放声：第一次点击/按键解锁 + 补播当前行 */
      unlock: function () {
        try { if (supported) window.speechSynthesis.resume() } catch (e) {}
        audio.resume()
        /* 预热：先无声念一个空格，把引擎唤醒，避免第一句被吃掉开头半个字 */
        if (supported && !saidOnce) {
          try {
            var w = new window.SpeechSynthesisUtterance(' ')
            w.volume = 0
            var v = picked.en || picked.zh
            if (v) { w.voice = v; w.lang = v.lang }
            window.speechSynthesis.speak(w)
          } catch (e) { /* noop */ }
        }
        if (!saidOnce && C.voice && (pending.en || pending.zh)) this.say(pending.en, pending.zh)
      },
      speakName: spokenName,
      current: function () {
        var a = picked.en ? picked.en.name : ''
        var b = picked.zh ? picked.zh.name : ''
        return a === b ? a : (a + (b ? '  /  ' + b : ''))
      },
      listVoices: function () { return voices.slice() },
      /** 只有这里才真的掐断语音（跳过 / 揭幕） */
      stop: function () { try { if (supported) window.speechSynthesis.cancel() } catch (e) {} setMeter(false) }
    }

    /** TTS 合成并等它念完，resolve 实际时长(ms)；拿不到引擎时 resolve 0。 */
    function ttsLine(en, zh) {
      return new Promise(function (resolve) {
        if (!supported || !C.voice || finished) { resolve(0); return }
        pending = { en: en || '', zh: zh || '' }
        var items = []
        var mode = C.voiceLang
        if (mode === 'zh') { if (zh) items.push({ t: zh, l: 'zh-CN' }) }
        else if (mode === 'both') {
          if (zh) items.push({ t: zh, l: 'zh-CN' })
          if (en) items.push({ t: en, l: 'en-US' })
        } else if (en) { items.push({ t: en, l: 'en-US' }) }
        if (!items.length) { resolve(0); return }

        saidOnce = true
        bgm.duck(true)
        if (C.voiceCue !== false) audio.cue()

        var startedAt = Date.now()
        var est = estimateMs(items)
        var lead = clamp01(C.voiceLead, 0, 1200)
        var settled = false
        var watchdog = null

        function settle() {
          if (settled) return
          settled = true
          if (watchdog) clearTimeout(watchdog)
          bgm.duck(false)
          setMeter(false)
          resolve(Math.max(0, Date.now() - startedAt))
        }

        setTimeout(function () {
          if (finished) { settle(); return }
          var last = items.length - 1
          for (var i = 0; i <= last; i++) {
            var u = buildUtter(items[i].t, items[i].l)
            if (i === last) {
              u.onstart = function () { setMeter(true) }
              u.onend = settle
              u.onerror = settle
            }
            try { window.speechSynthesis.speak(u) } catch (e) { if (i === last) settle() }
          }
          watchdog = setTimeout(settle, est + 900)
        }, lead)
      })
    }
  })()

  /* 语音/音效接线：声卡要等用户手势才能出声，这里挂一次性解锁 */
  voice.attach(q('.dsu-voice'))
  ;(function preloadVoices() {
    if (C.voiceSource === 'tts') return
    for (var i = 0; i < STEPS.length; i++) if (STEPS[i].audio) audio.ensureAsset(STEPS[i].audio)
    audio.ensureAsset('line-6')   /* 终幕欢迎语 */
    audio.ensureAsset('line-0')   /* 第一幕开场播报 */
    audio.ensureAsset('line-a2')  /* 第二幕自检播报 */
  })()
  /* 背景音乐：建好元素并**立即起播**，不等任何点击。
     桌面端 Electron 的 autoplayPolicy 默认宽松，所以黑幕一上来就有音乐；
     web profile 的浏览器默认策略会拦下来，start() 会自己复位，退回
     unlock() 的第一次手势 —— 同一份代码，两种宿主都不用特判。 */
  /* ── 雷达盘预热 ──────────────────────────────────────────────────────
     这块是全场最大的图层，它只在最后一步出现。第一次显示时浏览器才去
     栅格化 + 上传纹理（2360×2360），那一下就是"刚进这一幕卡一秒"。
     这里在启动阶段先以 0.006 的不可见透明度画它 400ms：
     图层被建好、纹理已上传，之后切到 opacity:1 只是改一个属性。 */
  setTimeout(function () {
    try {
      if (!ui.reticle) return
      ui.reticle.style.opacity = '0.006'
      setTimeout(function () {
        try { ui.reticle.style.opacity = '' } catch (e) {}
      }, 400)
    } catch (e) {}
  }, 120)
  bgm.prepare()
  /* ⚠ 不在这里 start：加载即起播会比第一幕的画面早 0.8 秒，
     听感是"音乐先来了，画面才跟上"。改到第一幕入场那一帧起播。 */
  /* ⚠⚠ 音效素材必须在这里就预加载。
     原来 `loadAsset` 只在"首次手势"那条 unlock 路径里被调用 ——
     也就是说**开机动画从头到尾都没有真正加载过 sfx-tick / 交互三件套**，
     一直在用合成兜底，而且完全不报错（听感上只是"有点电子味"）。
     解码本身不需要音频上下文处于 running，所以先 load 没问题。 */
  try { audio.preload() } catch (e) {}
  /* 预加载结束后打一张总账：哪些素材成功、哪些回落合成。 */
  setTimeout(function () {
    try {
      var st = window.__WB_AUDIO_STATUS__
      if (st && window.console && console.info) {
        console.info('[audio] 素材状态 ok=' + (st.ok || []).length +
                     ' failed=' + (st.failed || []).length +
                     ' 名单=' + JSON.stringify(st.failed || []))
      }
    } catch (e) {}
  }, 2200)
  ;(function wireSound() {
    voice.load()
    if (voice.supported && typeof window.speechSynthesis.addEventListener === 'function') {
      try { window.speechSynthesis.addEventListener('voiceschanged', function () { voice.load() }) } catch (e) {}
    }
    var unlocked = false
    function unlock() {
      if (unlocked) return
      unlocked = true
      voice.unlock()
      bgm.start()
      document.removeEventListener('pointerdown', unlock, true)
      document.removeEventListener('keydown', unlock, true)
      document.removeEventListener('touchstart', unlock, true)
    }
    document.addEventListener('pointerdown', unlock, true)
    document.addEventListener('keydown', unlock, true)
    document.addEventListener('touchstart', unlock, true)
  })()

  /* ── 时间线 ───────────────────────────────────────────────────────────── */
  /* ── 性能探针（只在 ?perf=1 时启用）────────────────────────────────
     用 rAF 的帧间隔量"每一秒里最差的一帧"，结束时把结果写进 document.title，
     外面用 AppleScript 读标题即可 —— 不需要开调试端口，也不需要改产品行为。
     判据：d > 34ms 记为掉帧（60fps 一帧 16.7ms，两帧以上就是可感知的顿）。 */
  function startPerfProbe() {
    if (!/[?&]perf=1/.test(location.search)) return
    var last = performance.now()
    var t0 = last
    var secWorst = {}
    var totalFrames = 0, slowFrames = 0, worst = 0
    function tick(t) {
      var d = t - last
      last = t
      totalFrames++
      var sec = Math.floor((t - t0) / 1000)
      if (!secWorst[sec] || d > secWorst[sec]) secWorst[sec] = d
      if (d > 34) slowFrames++
      if (d > worst) worst = d
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
    window.addEventListener('dsh-startup:done', function () {
      var parts = []
      Object.keys(secWorst).forEach(function (k) { parts.push(k + ':' + Math.round(secWorst[k])) })
      var line = 'worst=' + Math.round(worst) + 'ms slow=' + slowFrames +
        '/' + totalFrames + ' | ' + parts.join(' ')
      document.title = 'PERF ' + line
      /* 同时丢回本地服务器：http.server 会把请求路径打进日志，
         外面读日志就能拿到结果（AppleScript 读不了 Chrome 的标题）。 */
      try { fetch('/perf-report/' + encodeURIComponent(line), { cache: 'no-store' }) } catch (e) {}
    })
  }

  function run() {
    try { startPerfProbe() } catch (e) {}
    return Promise.resolve()
      /* 第一幕：黑幕 --> WorkBuddy 标识 */
      .then(function () { return wait(820) })
      .then(function () {
        ui.blackInner.classList.add('dsu-in')
        /* 配乐与画面同一帧起播 —— 用户要求"跟动画一起进"。
           只在还没起播时调用，unlock 路径重复调用是幂等的。 */
        try { bgm.start() } catch (e0) {}
        audio.rise()
        /* 第一幕开场播报。素材 line-0.m4a 是按用户给的参考音频重录的：
           参考里是 "DSH startup sequence initiated"，DSH 是旧项目（harness）的代号
           的代号，已换成 "Mac OS startup sequence initiated"（Samantha，2.83s）。
           延迟 260ms：让星形先成形，人声再进来；不 await，不拖慢时间线。 */
        if (C.voice !== false) {
          /* ⚠ 不用固定延迟：等配乐**真正出声**之后再等 500ms。
             固定 1000ms 那版，用户仍然先听到人声 —— 因为 m4a 解码/缓冲
             让音乐晚了 300–800ms 才真的响。 */
          var speak = function () {
            try {
              bgm.duck(true)
              audio.playAssetAndWait('line-0', 1.0).then(function () { bgm.duck(false) })
            } catch (e) { bgm.duck(false) }
          }
          bgm.whenStarted(function () { setTimeout(speak, 500) })
        }
        /* 人声延迟 500ms：用户明确要求配乐先起、人声晚半秒进。
           配乐与画面同一帧起播（见上面 bgm.start()），所以这 500ms
           就是从配乐第一个音算起的间隔。 */
        return wait(240)
      })
      .then(function () {
        ui.blackEn.classList.add('dsu-tighten')
        return wait(880)
      })
      .then(function () {
        ui.sweep.classList.add('dsu-go')
        return wait(760)
      })
      /* 场景闸门①：黑幕品牌 → 过场洗白 */
      .then(function () { return gateScene() })
      /* 过场：过曝洗白 */
      .then(function () {
        ui.blackInner.classList.add('dsu-out')
        audio.sweep()
        /* 转场抬升：洗白是全片最亮的一刻，音乐推到 -18dB 才托得住；
           底板落定后收回 -22dB。 */
        try { bgm.lift(true) } catch (e) {}
        ui.wash.style.transition = 'opacity ' + ms(220) + 'ms linear'
        ui.wash.style.opacity = '1'
        return wait(260)
      })
      .then(function () {
        ui.plate.style.transition = 'opacity ' + ms(900) + 'ms ease'
        ui.plate.style.opacity = '1'
        ui.watermark.style.transition = 'opacity ' + ms(1100) + 'ms ease'
        ui.watermark.style.opacity = '1'
        ui.wash.style.transition = 'opacity ' + ms(720) + 'ms cubic-bezier(.2,.9,.2,1)'
        ui.wash.style.opacity = '0'
        ui.black.style.transition = 'opacity ' + ms(720) + 'ms ease'
        ui.black.style.opacity = '0'
        /* 底板正在被"洗"出来的时候，让一道掠光横掠过去 —— 金属面被灯扫过的读法。
           和洗白错的只差一点，观众会把它当成同一次曝光的一部分。 */
        ui.sheen.classList.add('dsu-go')
        try { bgm.lift(false) } catch (e) {}
        return wait(760)
      })
      /* 第二幕：品牌块 / 页脚 / 进度条 */
      .then(function () {
        /* ⚠ 17 个元素同一帧加 dsu-in → 17 条 transition 同时启动，
           合成器在那一帧要同时栅格化十几个图层，就是"进这一幕掉一下"。
           改成 35ms 阶梯：总时长 0.6s，视觉上还是一条快速级联，
           但每帧只启动一条，尖峰被摊平。 */
        ;[ui.brand, ui.foot, ui.stepcount, ui.idline, ui.fact1, ui.fact2,
          ui.frame, ui.slats, ui.meta, ui.vignette, ui.voice, ui.atmo,
          ui.field, ui.beams, ui.floor, ui.checks, ui.trace].forEach(function (node, k) {
          if (!node) return
          setTimeout(function () { try { node.classList.add('dsu-in') } catch (e) {} }, k * 35)
        })
        root.classList.add('dsu-cam')
        /* ⚠ 光场不能在这一刻启动：这一幕正好是"底板 + 右侧 SESSIONS 读数区"
           一起入场的时候（dsu-cam 机位 + 十几种元素同时 transition），
           再叠一个全屏 canvas 的 rAF，掉帧就发生在这一帧。
           推迟到这一幕落定之后（约 1.2s，正好进闸门那段静止期）再起。 */
        setTimeout(function () {
          try { if (!fieldHandle) startField() } catch (e3) {}
        }, 1200)
        /* ⚠ 光场只在前半段点亮：它是一层全屏 canvas（2880×1800@1.5dpr），
           和后面每一幕的入场、雷达盘、终幕特效抢同一份合成预算。
           自检序列开始后画面信息密度已经很高，这层"氛围"可有可无 ——
           在第四步收掉，后半程只留静态背景。 */
        setTimeout(function () {
          try { stopField() } catch (e4) {}
        }, 1200 + 9000)
        /* 锚点一：第二幕 = 曲子的 drop（10.67s）。
           如果用户把第一幕跳快了，音乐在这里一次性跳回 drop ——
           画面刚换幕、正好是"砸下来"的位置，跳得最不露痕迹。 */
        try { bgm.align(10.67, 2.5) } catch (e) {}
        setChecks(0)
        setProgress(0.12)
        setStepCount(0, 'BOOT')
        setSlats(0)
        /* 自检行用真实数字：插件条目数 / 活跃数 / 会话数，全部来自宿主 ctx */
        setSubtitle(
          '系统自检中… 插件 ' + factText(F.plugins) + ' · 活跃 ' + factText(F.activePlugins) + ' · 会话 ' + factText(F.sessions),
          'SYSTEM SELF-CHECK · ' + factText(F.activePlugins) + '/' + factText(F.plugins) + ' ACTIVE'
        )
        if (C.allowSkip) ui.skip.classList.add('dsu-in')
        /* 第二幕播报：这一幕原来只有环境音、没有人声 —— 用户的规矩是
           "每一幕都要有自己的音频"。素材 line-a2 = "System self check in progress."
           和屏幕上的"系统自检中…"是同一件事，不 await。 */
        if (C.voice !== false) {
          setTimeout(function () {
            try {
              bgm.duck(true)
              audio.playAssetAndWait('line-a2', 1.0).then(function () { bgm.duck(false) })
            } catch (e) { bgm.duck(false) }
          }, 420)
        }
        return wait(700)
      })
      /* 场景闸门②：档案底板就绪 → 进入自检序列 */
      .then(function () { return gateScene() })
      .then(function () { ui.black.style.display = 'none'; sweep() })
      /* 六个阶段 */
      .then(function () { return stepLoop() })
      /* 终幕 */
      .then(function () { return finale() })
      .catch(function (err) {
        try { console.warn('[dsh-startup-screen] 动画异常，直接揭幕：', err) } catch (e2) {}
        return finish()
      })
  }

  function stepLoop() {
    var stepIndex = 0
    var chain = Promise.resolve()
    STEPS.forEach(function (step, i) {
      chain = chain.then(function () {
        if (finished) return
        var n = i + 1
        setStepCount(n, step.badge)
        setSlats(n)
        setChecks(n)
        setProgress(step.progress)
        setSubtitle(step.log, step.logEn)
        audio.step()
        /* 语音在这里起头，但**不阻塞**下面的文字渐显 —— 两者同时发生 */
        var spoke = voice.line(step.say, step.zh, step.audio)

        ui.status.classList.toggle('dsu-zhline', true)
        /* 先摘掉 dsu-in 并强制一次样式计算，新的逐字 span 才会重新走渐显动画 */
        ui.status.classList.remove('dsu-in')
        ui.subEn.classList.remove('dsu-in')
        void ui.status.offsetWidth
        /* 主字与英文字幕都走"解码"：先落同宽的替身字形，再逐位锁定成真字 */
        var slots = typeIn(ui.statusZh, step.zh, 46, 'decode')
        slots = slots.concat(typeIn(ui.subEn, step.en, 13, 'decode'))
        startDecode(slots)
        ui.caret.classList.toggle('dsu-on', !!step.action && step.action !== 'auto')
        requestAnimationFrame(function () {
          if (finished) return
          ui.status.classList.add('dsu-in')
          ui.subEn.classList.add('dsu-in')
        })
        ui.rule.classList.add('dsu-in')

        if (step.assembleLogo) assembleLogo()
        if (step.reticle) {
          /* 照原片：准星出现时中央只留状态字，标识和虚线收掉，别挤成一团 */
          ui.logo.classList.remove('dsu-in')
          ui.dots.hidden = true
          ui.reticle.classList.add('dsu-in')
          /* 咬合：先摘掉再加，强制一次样式计算才能重放动画 */
          ui.reticle.classList.remove('dsu-lock')
          void ui.reticle.offsetWidth
          ui.reticle.classList.add('dsu-lock')
          sweep()
        }
        if (step.hex) startHex()

        /* 这一步停多久 = max(视觉基准, 实际播报时长 + 收尾留白) —— 台词长就多停，
           台词短也不会干等。用户点得快时同样等这一句念完，不掐断。 */
        /* 倒数第二幕（第 5 步）开始把光场停掉：那一步的 checks/trace 动画最密，
           全屏 canvas 再叠上去就掉帧。停掉后画面由特效本身撑住，看不出差别。 */
        if (i >= STEPS.length - 2) { try { stopField() } catch (e4) {} }
        function holdFor(spoken) {
          var target = Math.max(ms(step.hold), (spoken || 0) + ms(240))
          return wait(Math.max(0, target - (spoken || 0)))
        }

        if (step.action === 'grant' || step.action === 'confirm') {
          showAction(step)
          /* 确认步骤：闸门带 button 选项 —— 点按钮 / Space / Enter / 3 秒，四者等价 */
          return wait(520).then(function () { return gateScene({ button: true }) }).then(function () {
            hideAction()
            audio.confirm()
            ui.caret.classList.remove('dsu-on')
            return spoke
          }).then(function () { return wait(ms(320)) })
        }
        if (step.hex) {
          return spoke.then(holdFor).then(function () { return gateScene() }).then(function () { stopHex() })
        }
        /* 普通步骤：内容与语音演完 → 闸门（按键立刻走 / 3 秒自动走） */
        return spoke.then(holdFor).then(function () { return gateScene() })
      })
    })
    return chain
  }

  function assembleLogo() {
    ui.logo.classList.add('dsu-in')
    ui.dots.hidden = false
    var path = ui.logo.querySelector('path')
    if (path && typeof path.getTotalLength === 'function') {
      try {
        var len = path.getTotalLength()
        path.style.fill = 'none'
        path.style.stroke = 'currentColor'
        path.style.strokeWidth = '1.1'
        path.style.strokeDasharray = len
        path.style.strokeDashoffset = len
        /* 参考片的"一笔画成"：先勾线，再落墨成面 */
        path.animate(
          [{ strokeDashoffset: len }, { strokeDashoffset: 0 }],
          { duration: ms(1400), easing: 'cubic-bezier(.55,.06,.24,1)', fill: 'forwards' }
        )
        setTimeout(function () {
          path.style.transition = 'fill ' + ms(420) + 'ms ease, stroke-width ' + ms(420) + 'ms ease'
          path.style.fill = ''
          path.style.strokeWidth = '0'
        }, ms(1450))
      } catch (err) { /* Web Animations 不可用时直接落墨 */ }
    }
    return wait(300)
  }

  function showAction(step) {
    ui.btnZh.textContent = step.btnZh
    ui.btnEn.textContent = step.btnEn
    ui.card.hidden = step.action !== 'confirm'
    if (step.action === 'confirm') {
      ui.card.innerHTML = ''
      /* 纯中文标签 + 数字/名称，去掉英文双写与主机行，别堆信息 */
      var rows = [
        ['身份名称', C.identity, true],
        ['身份编号', C.identityId, false],
        ['权限等级', C.accessLevel, false]
      ]
      rows.forEach(function (r) {
        var row = el('div', 'dsu-card-row')
        row.appendChild(el('span', null, r[0]))
        row.appendChild(el('b', r[2] ? 'dsu-zhname' : null, r[1]))
        ui.card.appendChild(row)
      })
    }
    ui.hint.innerHTML = '按 <kbd>Enter</kbd> / <kbd>Space</kbd>，或点击按钮继续'
    ui.action.classList.add('dsu-in')
    ui.btn.classList.add('dsu-pulse')
  }

  function hideAction() {
    ui.action.classList.remove('dsu-in')
    ui.btn.classList.remove('dsu-pulse')
  }

  function finale() {
    if (finished) return Promise.resolve()
    setStepCount(6, 'WELCOME')
    setSlats(6)
    setProgress(1)
    /* 底部日志和终幕里的「欢迎 xxx 访问」区分开，避免同一句出现两遍 */
    /* 首尾呼应：这里的短指纹和开机自检读的是同一批事实 —— 换机器就变，同一台机器稳定 */
    setSubtitle('身份验证完成，会话已建立', 'IDENTITY VERIFIED · SESSION ' + factHash())
    /* 锚点二：终幕 = 曲子尾奏（55.0s）。
       连跳之后音乐可能落后十几秒，在这里一次性拉回来，让收束对上揭幕。 */
    try { bgm.align(55.0, 3.5) } catch (e) {}
    /* 揭幕：最重的那一记 —— 金属片 + 一层 70→46Hz 的 sub。
       先响金属（有 attack），chime 的和声在后面铺开。 */
    try { audio.reveal() } catch (e) {}
    audio.chime()
    /* 终幕欢迎语：用从 Video Project 3 截出来的真声素材（line-6）。
       素材缺失 / voiceSource=tts / voice 关闭时自动静音，不会退回 TTS 念白 ——
       因为这条素材是「欢迎访问」整句，和动态身份名称无关。 */
    var welcome = voice.line(null, null, 'line-6')

    ui.status.classList.remove('dsu-in')
    ui.subEn.classList.remove('dsu-in')
    ui.rule.classList.remove('dsu-in')
    ui.reticle.classList.remove('dsu-in')
    stopHex()
    /* 中央区（状态行/分隔线/标识/虚线）整体退场：不清掉会和 WELCOME 版式叠字 */
    ui.center.classList.add('dsu-off')
    ui.dots.hidden = true

    return wait(360)
      .then(function () {
        ui.welcome.classList.add('dsu-in')
        ui.idline.classList.remove('dsu-in')
        ui.fact1.classList.remove('dsu-in')
        ui.fact2.classList.remove('dsu-in')
        ui.checks.classList.remove('dsu-in')
        ui.trace.classList.remove('dsu-in')
        return wait(420)
      })
      .then(function () {
        /* ⚠ 终幕这一下同时叠了：文字色散（多层 text-shadow + 混合模式）、
           全屏撕裂带、bloom、streak、flash —— 再叠着全屏粒子场的 rAF，
           2880×1800 上会明显掉帧。
           粒子场此刻已经被特效盖住，先停掉：省下的主线程预算给色散和 bloom。 */
        try { stopField() } catch (e2) {}
        /* 结尾色散故障：分片位移 + 0.5px 模糊 + 混合模式，读起来像镜头色散 */
        var targets = [ui.w1, ui.w2, ui.w4]
        targets.forEach(function (t) {
          t.classList.add('dsu-glitch')
          t.setAttribute('data-text', t.textContent)
        })
        ui.w2.classList.add('dsu-glitch-box')   /* 黑底白字那块换加色混合 */
        void ui.welcome.offsetWidth
        targets.forEach(function (t) { t.classList.add('dsu-on') })
        /* 同一下里补一条撕裂带扫过全屏：色散层做"字在抖"，这层做"画面在撕" */
        ui.tear.classList.add('dsu-go')
        return wait(640)
      })
      /* 光晕从中心炸开 + 变形光条横扫 + 文字青色 halation */
      .then(function () {
        root.classList.add('dsu-peak')
        setTimeout(function () { root.classList.remove('dsu-peak') }, Math.max(600, ms(1200)))
        ui.bloom.classList.add('dsu-go')
        ui.streak.classList.add('dsu-go')
        return wait(430)
      })
      /* 光晕最亮那一下补一记极短高光（是"眨一下"，不是长时间糊白） */
      .then(function () {
        ui.flash.style.transition = 'opacity ' + ms(70) + 'ms linear'
        ui.flash.style.opacity = '0.32'
        return wait(90)
      })
      .then(function () {
        ui.flash.style.transition = 'opacity ' + ms(340) + 'ms cubic-bezier(0.4, 0, 0.2, 1)'
        ui.flash.style.opacity = '0'
        return wait(320)
      })
      /* 欢迎语没播完就不揭幕（素材缺失时这个 Promise 立刻 resolve，不影响节奏） */
      .then(function () { return welcome })
      /* 场景闸门⑨：终幕就绪 → 用户按键（或等 3 秒）才揭幕，WorkBuddy 随后登场 */
      .then(function () { return gateScene() })
      /* 揭幕：整个机位后撤 + 轻微失焦，比单纯淡出更有镜头感 */
      .then(function () {
        root.classList.add('dsu-handoff')
        /* 音乐从"镜头后撤"这一刻就开始退，而不是等 finish()。
           要盖住 780ms 的后撤 + 900ms 的整体移出，1700ms 才收得住；
           只放在 finish() 里就只剩 900ms，且那时画面已经在淡出，听着还是断。 */
        bgm.stop(1700)
        return wait(780)
      })
      .then(function () { return finish() })
  }

  function finish() {
    if (finished) return
    finished = true
    releaseAll()
    stopHex()
    voice.stop()
    /* 跳过（Esc / SKIP）走的是这条路，没有上面的 1700ms 前摇，这里兜 900ms；
       正常揭幕时前面已经 stop 过，这一句会被幂等忽略。 */
    bgm.stop(900)
    if (clockTimer) { clearInterval(clockTimer); clockTimer = null }
    if (ui.traceTimer) { clearInterval(ui.traceTimer); ui.traceTimer = null }
    stopField()
    try {
      if (C.mode === 'session') window.sessionStorage.setItem('dsh-startup-screen:shown', '1')
      if (C.mode === 'daily') {
        window.localStorage.setItem('dsh-startup-screen:day', new Date().toISOString().slice(0, 10))
      }
    } catch (err) { /* 隐私模式下不可写，忽略 */ }
    /* 解锁：Host 注入的关键样式用 html.dsu-lock 锁滚动，这里必须一并摘掉，
       否则揭幕后主界面会永远滚不动。 */
    document.documentElement.classList.remove('dsu-lock')
    document.documentElement.style.overflow = ''
    if (document.body) document.body.style.overflow = ''
    root.classList.remove('dsu-boot')
    root.classList.add('dsu-gone')
    setTimeout(function () {
      if (root && root.parentNode) root.parentNode.removeChild(root)
      try { window.dispatchEvent(new CustomEvent('dsh-startup:done')) } catch (err) { /* noop */ }
    }, ms(900))
  }

  function requestSkip() {
    if (skipped || finished) return
    skipped = true
    releaseAll()
    finish()
  }

  if (C.allowSkip && ui.skip) {
    ui.skip.hidden = false
    ui.skip.addEventListener('click', function (e) { e.stopPropagation(); try { audio.tap() } catch (e2) {} requestSkip() })

    /* 交互音：悬停 ①（干、短）、点击 ②（有金属尾音）。
       用 pointerenter 而不是 mouseenter —— 触控板/鼠标都能覆盖，
       而且不会因为"划过子元素"重复触发（.dsu-btn 里有两个 span）。 */
    ;[ui.btn, ui.skip].forEach(function (elx) {
      if (!elx) return
      elx.addEventListener('pointerenter', function () { try { audio.hover() } catch (e3) {} })
    })
    if (ui.btn) ui.btn.addEventListener('click', function () { try { audio.tap() } catch (e4) {} })
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') requestSkip()
    })
  } else if (ui.skip) {
    ui.skip.hidden = true
  }

  /* 对外 API：settings 面板里的"立即预览"按钮和重播都走它 */
  window.__DSH_STARTUP_API__ = {
    /* 设置页试听与冒烟测试用：直接念一行 */
    speak: function (en, zh) { voice.say(en, zh) },
    speakName: function (n) { return voice.speakName(n) },
    get voice() { return voice.current() },
    replay: injectSelf,
    skip: requestSkip,
    finish: finish,
    config: C
  }

  /* 锁滚动，动画期间不露出下面的应用 */
  document.documentElement.classList.add('dsu-lock')
  document.documentElement.style.overflow = 'hidden'
  if (document.body) document.body.style.overflow = 'hidden'
  setProgress(0.05)
  root.classList.remove('dsu-boot')

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { run() })
  } else {
    run()
  }
})()
