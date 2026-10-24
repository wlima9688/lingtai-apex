// probehtml.swift — 可见窗口 + 时间序列采样，用于诊断**运行中**的动画
//
// ⚠ 为什么不能用 tools/shothtml 做时序诊断：
//   shothtml 用 setActivationPolicy(.prohibited) + 无可见窗口，WebKit 会把页面当不可见，
//   对 timer 施加节流。实测：空白页 + 纯 CSS（零 JS）的心跳也会从 0ms 退化到 6s。
//   **无头环境的时序数据全是假的。** 涉及"卡住/不推进"的判断必须在可见窗口里做。
//
// 用法: probehtml <html路径> <每0.5s采样次数> [宽] [高] [注入JS]
// 注入JS：atDocumentStart 注入的调试脚本（实验开关用，如 "document.body.className='nofilter'"）
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: probehtml <html路径> <采样次数> [宽] [高] [注入JS]\n".data(using: .utf8)!)
    exit(2)
}
let htmlPath = args[1]
let samples = max(1, Int(args[2]) ?? 10)
let w = args.count > 3 ? (Int(args[3]) ?? 1225) : 1225
let h = args.count > 4 ? (Int(args[4]) ?? 780) : 780
let extraJS = args.count > 5 ? args[5] : ""

let bridge = """
(function () {
  window.__LOGS__ = [];
  var push = function (s) { try { window.__LOGS__.push(String(s)); } catch (e) {} };
  ['log','warn','error','info'].forEach(function (k) {
    var orig = console[k];
    console[k] = function () {
      var a = [];
      for (var i = 0; i < arguments.length; i++) {
        var x = arguments[i];
        try { a.push(typeof x === 'string' ? x : JSON.stringify(x)); } catch (e) { a.push(String(x)); }
      }
      push(k.toUpperCase() + ': ' + a.join(' '));
      try { orig.apply(console, arguments); } catch (e) {}
    };
  });
  window.addEventListener('error', function (e) {
    push('ERROR: ' + (e.message || '') + ' @' + (e.filename || '') + ':' + (e.lineno || ''));
  });
  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason; push('REJECT: ' + (r && (r.message || r)));
  });
})();
"""

let sampleJS = """
(function(){
  var f = window.__DSH_STARTUP_FIELD__;
  var hb = window.__HB__ || [];
  var sc = document.querySelector('.dsu-stepcount');
  var st = document.querySelector('.dsu-status-zh');
  var cv = document.querySelector('.dsu-field');
  var M = window.__M__ || {};
  return JSON.stringify({
    t: Date.now() - (window.__T0__ || (window.__T0__ = Date.now())),
    hbN: hb.length,
    lastGap: hb.length > 1 ? hb[hb.length-1] - hb[hb.length-2] : -1,
    raf: M.raf|0,
    fieldFrames: f ? (f.frames|0) : -1,
    canvas: cv ? (cv.width + 'x' + cv.height) : '-',
    step: sc ? sc.textContent : '?',
    status: st ? st.textContent.slice(0,24) : '?',
    done: !!document.querySelector('.dsu-gone') || !document.getElementById('dsh-startup-root')
  });
})()
"""

final class Probe: NSObject, WKNavigationDelegate {
    var web: WKWebView
    var win: NSWindow!
    var remaining = 0
    var samples: [String] = []
    var total = 0

    init(w: Int, h: Int, samples: Int, extraJS: String) {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addUserScript(
            WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if !extraJS.isEmpty {
            cfg.userContentController.addUserScript(
                WKUserScript(source: extraJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        self.web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: cfg)
        self.total = samples
        super.init()
        web.navigationDelegate = self

        let r = NSRect(x: 0, y: 0, width: w, height: h)
        win = NSWindow(contentRect: r, styleMask: [.borderless],
                       backing: .buffered, defer: false)
        win.contentView = web
        win.setFrameOrigin(NSPoint(x: 60, y: 60))
        win.orderFrontRegardless()
    }

    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        web.evaluateJavaScript("window.__T0__=Date.now()") { _, _ in }
        remaining = total
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.tick() }
    }

    func tick() {
        guard remaining > 0 else { finish(); return }
        remaining -= 1
        let n = remaining
        web.evaluateJavaScript(sampleJS) { res, err in
            if let s = res as? String {
                var line = s
                if let d = s.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    let t = o["t"] ?? "?", gap = o["lastGap"] ?? "?", raf = o["raf"] ?? "?",
                         ff = o["fieldFrames"] ?? "?", step = o["step"] ?? "?",
                         stat = o["status"] ?? "?", cv = o["canvas"] ?? "?", dn = o["done"] ?? "?"
                    line = String(format: "t=%5@ms gap=%4@ms raf=%-4@ field=%-4@ %@ | %@ | %@",
                                  "\(t)", "\(gap)", "\(raf)", "\(ff)", "\(cv)", "\(step)", "\(stat)")
                    if (dn as? Bool) == true { line += "  [ROOT REMOVED = 动画已结束]" }
                }
                self.samples.append(line)
            } else if let e = err {
                self.samples.append("EVAL ERR: \(e.localizedDescription)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.tick() }
            _ = n
        }
    }

    func finish() {
        print("=== 时间序列（每 0.5s）===")
        for (i, s) in samples.enumerated() { print(String(format: "%2d", i), s) }
        let js = "JSON.stringify({logs: window.__LOGS__ || [], probe: window.__PROBE__ || []})"
        web.evaluateJavaScript(js) { res, _ in
            if let s = res as? String, let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for p in (obj["probe"] as? [String]) ?? [] { print("[probe] \(p)") }
                for l in (obj["logs"] as? [String]) ?? [] { print("[console] \(l)") }
            }
            let snap = WKSnapshotConfiguration()
            snap.rect = self.web.bounds
            self.web.takeSnapshot(with: snap) { image, _ in
                if let image = image, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/probehtml.png"))
                    print("[screenshot] /tmp/probehtml.png")
                }
                exit(0)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let p = Probe(w: w, h: h, samples: samples, extraJS: extraJS)
let url = URL(fileURLWithPath: htmlPath)
p.web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + Double(samples) * 0.5 + 12.0) {
    p.finish()
}
app.run()