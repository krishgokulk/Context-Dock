// PreviewWebContent.swift
// Context-Dock
//
// The page the user is looking at, as markdown.
//
// A web preview could show a page and know nothing about it: the assistant beside it
// was given a URL and had to guess from the address. Reading the live WKWebView rather
// than re-fetching the URL is what makes this work on pages behind a login, and on the
// ones that render themselves in JavaScript — a second fetch would get a shell.
//
// Markdown rather than raw text or HTML: headings and links survive, and the same page
// costs a fraction of what its HTML would.

import Foundation
import WebKit

@MainActor
final class PreviewWebContent {
    static let shared = PreviewWebContent()
    private init() {}

    private var views: [String: WKWebView] = [:]

    func register(_ view: WKWebView, for url: URL) {
        views[url.absoluteString] = view
    }

    func unregister(for url: URL) {
        views[url.absoluteString] = nil
    }

    func markdown(for url: URL) async -> String? {
        guard let view = views[url.absoluteString] else { return nil }
        let result = try? await view.evaluateJavaScript(Self.extractor)
        guard let text = result as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Walks the rendered DOM and emits markdown. Chrome that carries no meaning —
    /// script, style, nav, header, footer, aside — is dropped before anything is read,
    /// because a site's menu repeated on every page is the least useful thing a model
    /// could be charged for.
    private static let extractor = """
    (function () {
      const LIMIT = 12000;
      const skip = new Set(['SCRIPT','STYLE','NOSCRIPT','NAV','HEADER','FOOTER','ASIDE','FORM','SVG']);
      const root = document.querySelector('article, main, [role="main"]') || document.body;
      const out = [];
      let size = 0;

      function push(line) {
        if (size >= LIMIT) return;
        const trimmed = line.replace(/\\s+/g, ' ').trim();
        if (!trimmed) return;
        out.push(trimmed);
        size += trimmed.length;
      }

      function walk(node) {
        if (size >= LIMIT || !node) return;
        if (node.nodeType === 3) return;
        if (node.nodeType !== 1) return;
        if (skip.has(node.tagName)) return;
        const style = window.getComputedStyle(node);
        if (style && (style.display === 'none' || style.visibility === 'hidden')) return;

        const tag = node.tagName;
        if (/^H[1-6]$/.test(tag)) {
          push('#'.repeat(Number(tag[1])) + ' ' + node.innerText);
          return;
        }
        if (tag === 'LI') { push('- ' + node.innerText); return; }
        if (tag === 'PRE') { push('```\\n' + node.innerText + '\\n```'); return; }
        if (tag === 'A' && node.innerText.trim() && node.href) {
          push('[' + node.innerText.trim() + '](' + node.href + ')');
          return;
        }
        if (tag === 'P' || tag === 'BLOCKQUOTE') {
          push((tag === 'BLOCKQUOTE' ? '> ' : '') + node.innerText);
          return;
        }
        for (const child of node.children) walk(child);
        if (!node.children.length && node.innerText) push(node.innerText);
      }

      walk(root);
      const head = '# ' + document.title + '\\n' + location.href + '\\n';
      let body = out.join('\\n\\n');
      if (body.length > LIMIT) body = body.slice(0, LIMIT) + '\\n\\n*(truncated)*';
      return head + '\\n' + body;
    })();
    """
}
