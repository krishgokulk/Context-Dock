// extract-article-and-links.js
// Packs/Safari.doraxpack/page_scripts
//
// Runs in the page's isolated world via SafariExtensionCommandBridge.
// Extracts headings, markdown tables, code blocks, and page links from the active tab.
// Result is JSON — the host parses it and fences it as UntrustedContent before prompting.

(function () {
  "use strict";

  var HEADING_LIMIT = 30;
  var CODE_LIMIT = 5;
  var TABLE_LIMIT = 5;
  var LINK_LIMIT = 60;
  var CODE_TEXT_LIMIT = 800;
  var TABLE_CELL_LIMIT = 120;

  // --- Headings ---

  function extractHeadings() {
    var nodes = document.querySelectorAll("h1, h2, h3, h4");
    var seen = new Set();
    var result = [];
    for (var i = 0; i < nodes.length && result.length < HEADING_LIMIT; i++) {
      var text = (nodes[i].innerText || "").replace(/\s+/g, " ").trim();
      if (text && !seen.has(text)) {
        seen.add(text);
        result.push({ level: parseInt(nodes[i].tagName[1], 10), text: text });
      }
    }
    return result;
  }

  // --- Markdown tables ---

  function tableToMarkdown(table) {
    var rows = table.querySelectorAll("tr");
    if (!rows.length) return null;
    var lines = [];
    var headerDone = false;
    for (var r = 0; r < rows.length; r++) {
      var cells = rows[r].querySelectorAll("td, th");
      if (!cells.length) continue;
      var row = [];
      for (var c = 0; c < cells.length; c++) {
        var cell = (cells[c].innerText || "")
          .replace(/\s+/g, " ").trim()
          .replace(/\|/g, "\\|")
          .slice(0, TABLE_CELL_LIMIT);
        row.push(cell);
      }
      lines.push("| " + row.join(" | ") + " |");
      if (!headerDone && rows[r].querySelector("th")) {
        lines.push("| " + row.map(function () { return "---"; }).join(" | ") + " |");
        headerDone = true;
      }
    }
    return lines.length > 1 ? lines.join("\n") : null;
  }

  function extractTables() {
    var tables = document.querySelectorAll("table");
    var result = [];
    for (var i = 0; i < tables.length && result.length < TABLE_LIMIT; i++) {
      var md = tableToMarkdown(tables[i]);
      if (md) result.push(md);
    }
    return result;
  }

  // --- Code blocks ---

  function extractCodeBlocks() {
    var nodes = document.querySelectorAll("pre code, pre");
    var seen = new Set();
    var result = [];
    for (var i = 0; i < nodes.length && result.length < CODE_LIMIT; i++) {
      var text = (nodes[i].innerText || "").trim().slice(0, CODE_TEXT_LIMIT);
      if (text && !seen.has(text)) {
        seen.add(text);
        result.push(text);
      }
    }
    return result;
  }

  // --- Page links (action-shaped first) ---

  var ACTION_PATTERN =
    /download|install|get\s|get$|releases?|docs?|documentation|guide|repo|github|source|pricing|buy|sign\s?up|sign\s?in|log\s?in|start|try/i;

  function extractLinks() {
    var seen = new Set();
    var primary = [];
    var rest = [];
    var anchors = document.querySelectorAll("a[href]");
    for (var i = 0; i < anchors.length; i++) {
      var href = "";
      try {
        href = new URL(anchors[i].getAttribute("href"), location.href).href;
      } catch (e) {
        continue;
      }
      if (!/^https?:/i.test(href)) continue;
      if (href.replace(/#.*$/, "") === location.href.replace(/#.*$/, "")) continue;
      if (seen.has(href)) continue;
      seen.add(href);

      var imgAlt = anchors[i].querySelector("img")
        ? (anchors[i].querySelector("img").getAttribute("alt") || "")
        : "";
      var text = ((anchors[i].innerText || anchors[i].getAttribute("aria-label") ||
                   anchors[i].title || imgAlt || "")
        .replace(/\s+/g, " ").trim().slice(0, 80));
      if (!text) {
        try { text = new URL(href).hostname; } catch (e) { text = href.slice(0, 60); }
      }

      var entry = { url: href, text: text };
      if (ACTION_PATTERN.test(text) || ACTION_PATTERN.test(href)) {
        primary.push(entry);
      } else {
        rest.push(entry);
      }
      if (primary.length + rest.length >= LINK_LIMIT * 2) break;
    }

    return primary.concat(rest).slice(0, LINK_LIMIT);
  }

  // --- Assemble result ---

  var result = {
    url:        location.href,
    title:      document.title || "",
    headings:   extractHeadings(),
    tables:     extractTables(),
    codeBlocks: extractCodeBlocks(),
    links:      extractLinks(),
  };

  return JSON.stringify(result);
})();
