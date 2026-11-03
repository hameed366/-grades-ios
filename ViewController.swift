import UIKit
import WebKit

/// يخدم ملفات مجلد www من داخل التطبيق عبر العنوان app://localhost/
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let base = Bundle.main.resourceURL!.appendingPathComponent("www")

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        var rel = url.path
        if rel.isEmpty || rel == "/" { rel = "/index.html" }
        let file = base.appendingPathComponent(String(rel.dropFirst()))
        guard file.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path),
              let data = try? Data(contentsOf: file) else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            urlSchemeTask.didReceive(r)
            urlSchemeTask.didFinish()
            return
        }
        let mime: String
        switch file.pathExtension.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "js": mime = "application/javascript"
        case "css": mime = "text/css"
        case "json", "webmanifest": mime = "application/json"
        case "png": mime = "image/png"
        case "svg": mime = "image/svg+xml"
        default: mime = "application/octet-stream"
        }
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        urlSchemeTask.didReceive(r)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class ViewController: UIViewController, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    private var web: WKWebView!

    private let bridgeJS = """
    (function(){
      var post=function(m){window.webkit.messageHandlers.native.postMessage(m)};
      window.print=function(){window.dispatchEvent(new Event('beforeprint'));post({type:'print'})};
      var b64=function(blob){return new Promise(function(res,rej){var r=new FileReader();r.onload=function(){res(String(r.result).split(',')[1]||'')};r.onerror=rej;r.readAsDataURL(blob)})};
      window.claude={use:function(n){
        if(n!=='downloads')return Promise.resolve(null);
        return Promise.resolve({save:function(o){return b64(o.data).then(function(d){post({type:'save',filename:o.filename,b64:d});return true})}});
      }};
      var open0=window.open;
      window.open=function(u,t){
        if(u&&/^(https?|mailto|tel):/.test(String(u))){post({type:'open',url:String(u)});return null}
        return open0?open0.apply(window,arguments):null;
      };
    })();
    """

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: "app")
        let uc = WKUserContentController()
        uc.add(self, name: "native")
        uc.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = uc
        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = false
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        web.load(URLRequest(url: URL(string: "app://localhost/index.html")!))
    }

    // MARK: - رسائل من الصفحة
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "print":
            printPage()
        case "save":
            guard let name = m["filename"] as? String,
                  let b64 = m["b64"] as? String,
                  let data = Data(base64Encoded: b64) else { return }
            let safe = name.replacingOccurrences(of: "/", with: "_")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
            do { try data.write(to: url) } catch { return }
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = view
            vc.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(vc, animated: true)
        case "open":
            if let s = m["url"] as? String, let u = URL(string: s) {
                UIApplication.shared.open(u)
            }
        default:
            break
        }
    }

    private func printPage() {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "طباعة"
        let pc = UIPrintInteractionController.shared
        pc.printInfo = info
        pc.printFormatter = web.viewPrintFormatter()
        pc.present(animated: true) { [weak self] _, _, _ in
            self?.web.evaluateJavaScript("window.dispatchEvent(new Event('afterprint'))", completionHandler: nil)
        }
    }

    // MARK: - نوافذ alert / confirm / prompt
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "حسنًا", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "موافق", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "موافق", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }

    // MARK: - الروابط الخارجية
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, let s = u.scheme,
           ["http", "https", "mailto", "tel"].contains(s),
           navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url, let s = u.scheme, ["http", "https"].contains(s) {
            UIApplication.shared.open(u)
        }
        return nil
    }
}
