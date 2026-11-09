import SwiftUI
import WebKit
import AppKit
import SwiftData

// MARK: - PagewritReaderWebView

/// WKWebView that reports trackpad pinch to the reader instead of ignoring
/// it, so pinch changes the text size in steps like the A-/A+ buttons do.
final class PagewritReaderWebView: WKWebView {
    var onMagnify: ((CGFloat, NSEvent.Phase) -> Void)?

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification, event.phase)
    }
}

// MARK: - ScrollRequest

/// A one-shot "scroll to this fraction of the chapter" command. The id makes
/// repeated requests for the same fraction distinct.
struct ScrollRequest: Equatable {
    let id = UUID()
    let fraction: Double
}

// MARK: - EPUBPageView

/// Replacement for the old private `EPUBWebViewRepresented`.
///
/// What changed, and why the reader should feel less "undefined":
/// - The stylesheet is injected at document start, so there is no flash of
///   the publisher's white page before the theme lands (bad in Night).
/// - Changing text size or theme keeps the reading position (it used to
///   stay at the same pixel offset, so the text jumped).
/// - Scroll position inside the chapter is reported up (for a real progress
///   bar) and restored on reopen.
/// - The end of every chapter carries Previous / Next links, so a chapter
///   ends with a clear next step instead of just stopping.
/// - Pinch changes text size in detents; page-level magnification stays off.
/// - Web links open in the browser instead of replacing the chapter.
/// Lets the reader view talk to the chapter's web view for read-aloud:
/// collects the chapter text, finds where reading should start (the user's
/// selection, else the top of the visible page) and highlights the word
/// currently being spoken.
final class EPUBWebBridge {
    weak var webView: WKWebView?
    var matchCase = false
    var wholeWord = false

    func prepareSpeech(completion: @escaping (_ text: String, _ start: Int) -> Void, fallback: @escaping () -> Void) {
        guard let webView else { fallback(); return }
        let js = """
        (function(){
          var nodes=[],text='';
          var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{acceptNode:function(n){
            var p=n.parentElement; if(!p) return NodeFilter.FILTER_REJECT;
            var t=p.tagName; if(t==='SCRIPT'||t==='STYLE'||t==='NOSCRIPT') return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_ACCEPT;}});
          var n; while((n=w.nextNode())){nodes.push({n:n,s:text.length});text+=n.data;}
          window.__pwSpeech={nodes:nodes,text:text};
          function offsetOf(node,off){for(var i=0;i<nodes.length;i++){if(nodes[i].n===node)return nodes[i].s+off;}return -1;}
          var start=-1,sel=window.getSelection();
          if(sel&&sel.rangeCount&&!sel.isCollapsed){var r=sel.getRangeAt(0);start=offsetOf(r.startContainer,r.startOffset);}
          if(start<0&&document.caretRangeFromPoint){var c=document.caretRangeFromPoint(window.innerWidth/2,70);if(c){start=offsetOf(c.startContainer,c.startOffset);}}
          if(start<0)start=0;
          if(!document.getElementById('pw-speak-style')){var st=document.createElement('style');st.id='pw-speak-style';
            st.textContent='::highlight(pw-speak){background-color:rgba(190,70,105,0.38);color:inherit;}';document.head.appendChild(st);}
          return JSON.stringify({text:text,start:start});
        })()
        """
        webView.evaluateJavaScript(js) { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { fallback(); return }
            completion(text, (obj["start"] as? Int) ?? 0)
        }
    }

    func highlightSpeech(location: Int, length: Int) {
        let js = """
        (function(o,l){var s=window.__pwSpeech;if(!s)return;var nodes=s.nodes,a=null,b=null,end=o+l;
          for(var i=0;i<nodes.length;i++){var st=nodes[i].s,len=nodes[i].n.data.length;
            if(!a&&o<st+len){a=[nodes[i].n,Math.max(0,o-st)];}
            if(a&&end<=st+len){b=[nodes[i].n,Math.max(0,end-st)];break;}}
          if(!a)return; if(!b){var ln=nodes[nodes.length-1].n;b=[ln,ln.data.length];}
          var r=document.createRange();r.setStart(a[0],a[1]);r.setEnd(b[0],b[1]);
          if(window.CSS&&CSS.highlights&&window.Highlight){CSS.highlights.set('pw-speak',new Highlight(r));}
          else{var sel=window.getSelection();sel.removeAllRanges();sel.addRange(r);}
          var rc=r.getBoundingClientRect();
          if(rc.top<90||rc.bottom>window.innerHeight-110){window.scrollBy({top:rc.top-window.innerHeight*0.35,behavior:'smooth'});}
        })(\(location),\(length))
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func clearSpeechHighlight() {
        let js = "(function(){if(window.CSS&&CSS.highlights){CSS.highlights.delete('pw-speak');}window.__pwSpeech=null;})()"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// A selection inside a chapter, as character offsets into its text.
struct EPUBSelection {
    let start: Int
    let length: Int
    let text: String
}

/// One-shot "select and scroll to this passage" command.
struct EPUBRevealRequest: Equatable {
    let id = UUID()
    let chapterIndex: Int
    let start: Int
    let length: Int
}

extension EPUBWebBridge {
    /// Reads the current selection as chapter-text offsets (nil if none).
    func captureSelection(completion: @escaping (EPUBSelection?) -> Void) {
        guard let webView else { completion(nil); return }
        let js = #"""
        (function(){
          if(!window.__pwNodes) return null;
          var sel=window.getSelection();
          if(sel&&sel.rangeCount&&!sel.isCollapsed){
            var r=sel.getRangeAt(0), info=window.__pwNodes();
            var a=window.__pwOffset(r.startContainer,r.startOffset,info);
            var b=window.__pwOffset(r.endContainer,r.endOffset,info);
            if(b>a) return JSON.stringify({s:a,l:b-a,t:sel.toString()});
          }
          // The live selection can be gone once a toolbar button takes focus.
          if(window.__pwLastSel) return JSON.stringify(window.__pwLastSel);
          return null;
        })()
        """#
        webView.evaluateJavaScript(js) { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let start = obj["s"] as? Int, let length = obj["l"] as? Int,
                  let text = obj["t"] as? String else { completion(nil); return }
            let quoted = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
            completion(quoted.isEmpty ? nil : EPUBSelection(start: start, length: length, text: quoted))
        }
    }

    func clearSelection() {
        webView?.evaluateJavaScript("window.__pwLastSel=null;window.getSelection().removeAllRanges();", completionHandler: nil)
    }
}

struct EPUBPageView: NSViewRepresentable {
    let chapterURL: URL
    let contentDirectory: URL?
    let css: String
    let pageBackground: NSColor
    let highlightQuery: String?
    let highlightOccurrence: Int
    let restoreFraction: Double
    let scrollRequest: ScrollRequest?
    let hasPrevious: Bool
    let hasNext: Bool
    let onScroll: (Double) -> Void
    let onNavigate: (Int) -> Void
    let onMagnify: (CGFloat, NSEvent.Phase) -> Void
    var bridge: EPUBWebBridge? = nil
    var chapterIndex: Int = 0
    var highlights: [Highlight] = []
    var revealRequest: EPUBRevealRequest? = nil
    var onSelectionChange: (Bool) -> Void = { _ in }
    var onTapHighlight: (PersistentIdentifier) -> Void = { _ in }

    func makeNSView(context: Context) -> PagewritReaderWebView {
        let config = WKWebViewConfiguration()
        // A weak proxy, so the web view's controller never keeps the
        // coordinator (and through it the whole reader) alive.
        config.userContentController.add(WeakScriptHandler(context.coordinator), name: "stoa")
        // Block scripts shipped inside the book and every remote load, so a
        // book cannot run code or phone home. Pagewrit's own scripts are
        // injected by the app and are not affected.
        if let rules = EPUBContentRules.compiled {
            config.userContentController.add(rules)
        }

        let webView = PagewritReaderWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        bridge?.webView = webView
        if EPUBContentRules.compiled == nil {
            EPUBContentRules.compile { [weak webView] list in
                guard let webView, let list else { return }
                webView.configuration.userContentController.add(list)
                webView.reload()
            }
        }
        webView.underPageBackgroundColor = pageBackground
        webView.onMagnify = { [weak coordinator = context.coordinator] magnification, phase in
            coordinator?.parent.onMagnify(magnification, phase)
        }
        return webView
    }

    func updateNSView(_ webView: PagewritReaderWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        webView.underPageBackgroundColor = pageBackground

        if c.lastLoadedURL != chapterURL {
            c.lastLoadedURL = chapterURL
            c.lastCSS = css
            c.lastHighlightQuery = highlightQuery
            c.pendingHighlightQuery = highlightQuery
            c.pendingHighlightOccurrence = highlightOccurrence
            c.lastHighlightOccurrence = highlightOccurrence
            var requested: Double?
            if let request = scrollRequest, request.id != c.lastScrollRequestID {
                c.lastScrollRequestID = request.id
                requested = request.fraction
            }
            c.pendingRestore = highlightQuery == nil ? (requested ?? restoreFraction) : 0
            c.lastReportedScroll = -1
            c.isLoaded = false
            c.paintedSignature = ""
            if let reveal = revealRequest, reveal.id != c.lastRevealID, reveal.chapterIndex == chapterIndex {
                c.lastRevealID = reveal.id
                c.pendingReveal = reveal
                c.pendingRestore = 0
            }
            c.installUserScripts(in: webView)
            webView.loadFileURL(
                chapterURL,
                allowingReadAccessTo: contentDirectory ?? chapterURL.deletingLastPathComponent()
            )
            return
        }

        if let request = scrollRequest, request.id != c.lastScrollRequestID {
            c.lastScrollRequestID = request.id
            c.scroll(to: request.fraction, in: webView)
        }

        c.syncHighlights(in: webView)
        if let reveal = revealRequest, reveal.id != c.lastRevealID, reveal.chapterIndex == chapterIndex {
            c.lastRevealID = reveal.id
            c.reveal(reveal, in: webView)
        }

        if css != c.lastCSS {
            c.lastCSS = css
            c.installUserScripts(in: webView)
            c.applyLive(css: css, to: webView)
        }

        if let highlightQuery {
            if highlightQuery != c.lastHighlightQuery || highlightOccurrence != c.lastHighlightOccurrence {
                c.lastHighlightQuery = highlightQuery
                c.lastHighlightOccurrence = highlightOccurrence
                c.highlight(query: highlightQuery, occurrence: highlightOccurrence, in: webView)
            }
        } else {
            // Reset so stepping to another hit for the same text works.
            c.lastHighlightQuery = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ webView: PagewritReaderWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "stoa")
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: EPUBPageView
        var lastLoadedURL: URL?
        var lastCSS: String = ""
        var pendingHighlightQuery: String?
        var lastHighlightQuery: String?
        var pendingHighlightOccurrence: Int = 0
        var lastHighlightOccurrence: Int = 0
        var pendingRestore: Double = 0
        var lastReportedScroll: Double = -1
        var lastScrollRequestID: UUID?
        var isLoaded = false
        var paintedSignature = ""
        var paintedIDs: [PersistentIdentifier] = []
        var lastRevealID: UUID?
        var pendingReveal: EPUBRevealRequest?

        init(_ parent: EPUBPageView) {
            self.parent = parent
        }

        // MARK: Scripts

        func installUserScripts(in webView: WKWebView) {
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(
                source: styleScript(css: parent.css),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            controller.addUserScript(WKUserScript(
                source: bridgeScript(hasPrevious: parent.hasPrevious, hasNext: parent.hasNext),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }

        private func styleScript(css: String) -> String {
            #"""
            (function(){
              var s = document.createElement('style');
              s.id = 'stoa-style-override';
              s.textContent = \#(jsLiteral(css));
              (document.head || document.documentElement).appendChild(s);
            })();
            """#
        }

        private func bridgeScript(hasPrevious: Bool, hasNext: Bool) -> String {
            #"""
            (function(){
              var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.stoa;
              if (!h) return;
              function frac(){
                var d = document.documentElement;
                var m = d.scrollHeight - window.innerHeight;
                return m > 0 ? Math.min(1, Math.max(0, window.scrollY / m)) : 1;
              }
              var queued = false;
              window.addEventListener('scroll', function(){
                if (queued) return;
                queued = true;
                requestAnimationFrame(function(){ queued = false; h.postMessage({t:'scroll', f:frac()}); });
              }, {passive:true});

              window.__pwNodes = function(){
                var nodes=[], pos=0;
                var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{acceptNode:function(n){
                  var p=n.parentElement; if(!p) return NodeFilter.FILTER_REJECT;
                  var t=p.tagName; if(t==='SCRIPT'||t==='STYLE'||t==='NOSCRIPT') return NodeFilter.FILTER_REJECT;
                  if(p.closest && p.closest('#stoa-nav')) return NodeFilter.FILTER_REJECT;
                  return NodeFilter.FILTER_ACCEPT;}});
                var n; while((n=w.nextNode())){nodes.push({n:n,s:pos});pos+=n.data.length;}
                return {nodes:nodes,total:pos};
              };
              window.__pwOffset = function(node,off,info){
                info = info || window.__pwNodes();
                var nodes = info.nodes;
                if (node.nodeType === 3) {
                  for (var i=0;i<nodes.length;i++){ if(nodes[i].n===node) return nodes[i].s+off; }
                  return -1;
                }
                var rr=document.createRange(); rr.setStart(node,off); rr.collapse(true);
                for (var j=0;j<nodes.length;j++){ if(rr.comparePoint(nodes[j].n,0)>=0) return nodes[j].s; }
                return info.total;
              };
              var selQueued = false, hadSel = false;
              document.addEventListener('selectionchange', function(){
                if (selQueued) return;
                selQueued = true;
                setTimeout(function(){
                  selQueued = false;
                  var s = window.getSelection();
                  var has = !!(s && !s.isCollapsed && s.toString().trim().length);
                  if (has) {
                    try {
                      var r = s.getRangeAt(0), info = window.__pwNodes();
                      var a = window.__pwOffset(r.startContainer, r.startOffset, info);
                      var b = window.__pwOffset(r.endContainer, r.endOffset, info);
                      if (b > a) window.__pwLastSel = {s:a, l:b-a, t:s.toString()};
                    } catch(e) {}
                  }
                  if (has !== hadSel) { hadSel = has; h.postMessage({t:'sel', has:has}); }
                }, 80);
              });
              document.addEventListener('click', function(e){
                var s = window.getSelection();
                if ((s && !s.isCollapsed) || !window.__pwHL || !window.__pwHL.length || !document.caretRangeFromPoint) return;
                var r = document.caretRangeFromPoint(e.clientX, e.clientY);
                if (!r) return;
                var off = window.__pwOffset(r.startContainer, r.startOffset);
                for (var i=0;i<window.__pwHL.length;i++){
                  var it = window.__pwHL[i];
                  if (off >= it.s && off < it.s + it.l) { h.postMessage({t:'hl', i:i}); break; }
                }
              });

              var nav = document.createElement('div');
              nav.id = 'stoa-nav';
              function btn(label, d){
                var b = document.createElement('button');
                b.textContent = label;
                b.onclick = function(){ h.postMessage({t:'nav', d:d}); };
                return b;
              }
              nav.appendChild(\#(hasPrevious) ? btn('← Previous chapter', -1) : document.createElement('span'));
              nav.appendChild(\#(hasNext) ? btn('Next chapter →', 1) : document.createElement('span'));
              document.body.appendChild(nav);
              h.postMessage({t:'scroll', f:frac()});
            })();
            """#
        }

        /// Re-styles the page already on screen without reloading it, and
        /// keeps the reader at the same place in the text (not the same
        /// pixel offset) while the text reflows.
        func applyLive(css: String, to webView: WKWebView) {
            let js = #"""
            (function(){
              var d = document.documentElement;
              var before = Math.max(1, d.scrollHeight - window.innerHeight);
              var f = window.scrollY / before;
              var s = document.getElementById('stoa-style-override');
              if (!s) {
                s = document.createElement('style');
                s.id = 'stoa-style-override';
                (document.head || d).appendChild(s);
              }
              s.textContent = \#(jsLiteral(css));
              var after = Math.max(0, d.scrollHeight - window.innerHeight);
              window.scrollTo(0, f * after);
            })();
            """#
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func scroll(to fraction: Double, in webView: WKWebView) {
            let js = #"""
            (function(f){
              var d = document.documentElement;
              window.scrollTo({ top: f * Math.max(0, d.scrollHeight - window.innerHeight), behavior: 'smooth' });
            })(\#(fraction));
            """#
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func restore(fraction: Double, in webView: WKWebView) {
            let js = #"""
            (function(f){
              function go(){
                var d = document.documentElement;
                window.scrollTo(0, f * Math.max(0, d.scrollHeight - window.innerHeight));
              }
              go(); setTimeout(go, 250);
            })(\#(fraction));
            """#
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Selects and scrolls to the Nth (0-based) occurrence of `query`
        /// from the top of the chapter.
        func highlight(query: String, occurrence: Int, in webView: WKWebView) {
            guard !query.isEmpty else { return }
            let js = #"""
            (function(q, n){
              var sel = window.getSelection();
              sel.removeAllRanges();
              window.scrollTo(0, 0);
              var ok = true;
              for (var i = 0; i <= n && ok; i++) {
                ok = window.find(q, \#(parent.bridge?.matchCase == true), false, false, \#(parent.bridge?.wholeWord == true), false, false);
              }
            })(\#(jsLiteral(query)), \#(max(0, occurrence)));
            """#
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: Highlights

        /// Paints this chapter's saved highlights using the CSS Custom
        /// Highlight API, so the book's own markup is never modified.
        func syncHighlights(in webView: WKWebView) {
            guard isLoaded else { return }
            let mine = parent.highlights.filter { $0.pageIndex == parent.chapterIndex }
            let signature = mine.map {
                "\($0.persistentModelID.hashValue):\($0.rangeStart):\($0.rangeLength):\($0.colorRaw)"
            }.joined(separator: ",")
            guard signature != paintedSignature else { return }
            paintedSignature = signature
            paintedIDs = mine.map(\.persistentModelID)

            let items: [[String: Any]] = mine.map {
                ["s": $0.rangeStart, "l": $0.rangeLength, "c": $0.colorRaw]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: items),
                  let json = String(data: data, encoding: .utf8) else { return }
            let rules = HighlightColor.allCases.map {
                "::highlight(pw-hl-\($0.rawValue)){background-color:\($0.css);color:inherit;}"
            }.joined()
            let js = #"""
            (function(list, css){
              window.__pwHL = list;
              if(!(window.CSS && CSS.highlights && window.Highlight && window.__pwNodes)) return;
              var info = window.__pwNodes(), nodes = info.nodes;
              function locate(o, isEnd){
                for (var i=0;i<nodes.length;i++){
                  var st=nodes[i].s, len=nodes[i].n.data.length;
                  if (isEnd ? o<=st+len : o<st+len) return [nodes[i].n, Math.max(0,o-st)];
                }
                return null;
              }
              ['yellow','green','blue','pink','purple'].forEach(function(c){ CSS.highlights.delete('pw-hl-'+c); });
              var st = document.getElementById('pw-hl-style');
              if (!st){ st = document.createElement('style'); st.id='pw-hl-style'; (document.head||document.documentElement).appendChild(st); }
              st.textContent = css;
              var groups = {};
              list.forEach(function(it){
                var a = locate(it.s,false), b = locate(it.s+it.l,true);
                if (!a || !b) return;
                var r = document.createRange();
                try { r.setStart(a[0],a[1]); r.setEnd(b[0],b[1]); } catch(e){ return; }
                (groups[it.c] = groups[it.c] || []).push(r);
              });
              for (var c in groups){ var hl = new Highlight(); groups[c].forEach(function(r){ hl.add(r); }); CSS.highlights.set('pw-hl-'+c, hl); }
            })(\#(json), \#(jsLiteral(rules)));
            """#
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Selects a saved passage and scrolls it to the middle of the page.
        func reveal(_ request: EPUBRevealRequest, in webView: WKWebView) {
            let js = #"""
            (function(o, l){
              if(!window.__pwNodes) return;
              var info = window.__pwNodes(), nodes = info.nodes;
              function locate(p, isEnd){
                for (var i=0;i<nodes.length;i++){
                  var st=nodes[i].s, len=nodes[i].n.data.length;
                  if (isEnd ? p<=st+len : p<st+len) return [nodes[i].n, Math.max(0,p-st)];
                }
                return null;
              }
              var a = locate(o,false), b = locate(o+l,true);
              if (!a || !b) return;
              var r = document.createRange();
              try { r.setStart(a[0],a[1]); r.setEnd(b[0],b[1]); } catch(e){ return; }
              var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
              var rc = r.getBoundingClientRect();
              window.scrollBy({ top: rc.top - window.innerHeight*0.35, behavior: 'smooth' });
            })(\#(request.start), \#(request.length));
            """#
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            paintedSignature = ""
            syncHighlights(in: webView)
            if let reveal = pendingReveal {
                pendingReveal = nil
                pendingRestore = 0
                self.reveal(reveal, in: webView)
            } else if let query = pendingHighlightQuery {
                pendingHighlightQuery = nil
                highlight(query: query, occurrence: pendingHighlightOccurrence, in: webView)
            } else if pendingRestore > 0.001 {
                let fraction = pendingRestore
                pendingRestore = 0
                restore(fraction: fraction, in: webView)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               !url.isFileURL {
                // A book can contain any link. Only hand ordinary web and
                // mail links to the system, never custom or local schemes.
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["t"] as? String else { return }
            switch type {
            case "scroll":
                guard let f = (body["f"] as? NSNumber)?.doubleValue else { return }
                // Quantized so SwiftUI isn't re-rendered on every scroll frame
                // (the whole reader redraws each time this fires).
                if abs(f - lastReportedScroll) >= 0.02 || f <= 0 || f >= 1 {
                    lastReportedScroll = f
                    parent.onScroll(f)
                }
            case "nav":
                if let d = (body["d"] as? NSNumber)?.intValue {
                    parent.onNavigate(d)
                }
            case "sel":
                if let has = body["has"] as? Bool { parent.onSelectionChange(has) }
            case "hl":
                if let i = (body["i"] as? NSNumber)?.intValue, paintedIDs.indices.contains(i) {
                    parent.onTapHighlight(paintedIDs[i])
                }
            default:
                break
            }
        }
    }
}

// MARK: - Helpers

/// A string as a safely escaped JavaScript string literal.
private func jsLiteral(_ string: String) -> String {
    guard let data = try? JSONEncoder().encode(string),
          let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
    return literal
}


// MARK: - Content safety

/// Rules that keep a book inside its own box: no scripts from the book, and
/// nothing fetched from the internet (tracking pixels, remote fonts, ads).
enum EPUBContentRules {
    private(set) static var compiled: WKContentRuleList?

    private static let json = """
    [
      {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": ".*", "resource-type": ["script"]}, "action": {"type": "block"}}
    ]
    """

    /// Call once at launch so the rules are ready before the first book opens.
    static func warmUp() { compile { _ in } }

    static func compile(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { done(compiled); return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "pagewrit.epub.safety", encodedContentRuleList: json
        ) { list, error in
            DispatchQueue.main.async {
                if let error { print("Pagewrit: content rules failed: \(error)") }
                compiled = list
                done(list)
            }
        }
    }
}

/// Forwards script messages without holding the real handler strongly.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
