// shothtml.swift — 把本地 HTML 渲染成 PNG（用于无头视觉核对）
//
// 用途：改动画/改面板时，必须用**真实渲染**核对，不能靠想象。
// ⚠ macOS 上没有 wkhtmltoimage，qlmanage 不渲染 HTML —— 只有 WKWebView 可用。
//
// ⚠⚠⚠ 三条血泪教训（都写在这里，别再踩）：
//  ① 必须回收 console 输出。改动画最常见的失败是「脚本抛错 → 画面全黑」，
//     而黑屏**看起来**像"动画还没播"。不打印 console 就永远查不到真因。
//  ② 必须用 WKUserScript 在 **atDocumentStart** 注入。
//     早期版本先 load 一个 bridge 页再 load 目标页 —— 第二次 load 会换掉整个
//     JS 上下文，捕获全部丢失，于是"探针没输出"被误读成"没问题"。
//     **工具自己有 bug 时，它会骗你说目标有问题，或骗你说目标没问题。**
//  ③ 页面自带的 __PROBE__ 数组要一起读回。排查 DOM 状态比读 console 更直接。
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: shothtml <html路径> <输出png> [宽 高] [等待秒]\n".data(using: .utf8)!)
    exit(2)
}
let htmlPath = args[1]
let outPath = args[2]
let w = args.count > 3 ? (Int(args[3]) ?? 1200) : 1200
let h = args.count > 4 ? (Int(args[4]) ?? 800) : 800
let wait = args.count > 5 ? (Double(args[5]) ?? 1.5) : 1.5

/// 注入脚本：捕获 console + 暴露 __LOGS__
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

final class Shooter: NSObject, WKNavigationDelegate {
    var web: WKWebView
    let out: String
    let wait: Double
    var logs: [String] = []
    var probe: [String] = []

    init(w: Int, h: Int, out: String, wait: Double) {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addUserScript(
            WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        self.web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: cfg)
        self.out = out
        self.wait = wait
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {}

    func collect() {
        let js = "JSON.stringify({logs: window.__LOGS__ || [], probe: window.__PROBE__ || []})"
        web.evaluateJavaScript(js) { res, _ in
            if let s = res as? String, let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.logs = (obj["logs"] as? [String]) ?? []
                self.probe = (obj["probe"] as? [String]) ?? []
            }
        }
    }

    func snap() {
        collect()
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        web.takeSnapshot(with: cfg) { image, _ in
            if let image = image,
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: self.out))
                print("✅ \(self.out)")
            } else {
                print("❌ 快照失败")
            }
            for l in self.probe { print("   [probe] \(l)") }
            for l in self.logs { print("   [console] \(l)") }
            if self.probe.isEmpty && self.logs.isEmpty {
                print("   （无 console / 探针输出）")
            }
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let shooter = Shooter(w: w, h: h, out: outPath, wait: wait)
let url = URL(fileURLWithPath: htmlPath)
shooter.web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

DispatchQueue.main.asyncAfter(deadline: .now() + wait) { shooter.snap() }
app.run()
