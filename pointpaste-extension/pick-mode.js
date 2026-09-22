/**
 * PointPaste — click an element, optionally climb parents, add a note, copy a pack for Grok Bot.
 * Paste into Grok Bot chat. Works on any page (Breakdance ids included when present).
 */
(function () {
  /* CSS.escape polyfill */
  if (typeof CSS === "undefined") window.CSS = {};
  if (!CSS.escape) {
    CSS.escape = function (s) {
      return String(s).replace(/[^a-zA-Z0-9_-]/g, function (c) {
        return "\\" + c;
      });
    };
  }

  if (window.__nvGrokPick && window.__nvGrokPick.active) {
    window.__nvGrokPick.teardown();
    return;
  }

  const BD_RE = /^bde-([a-z0-9]+(?:-[a-z0-9]+)*)-(\d+)-(\d+)$/i;

  function cssPath(el) {
    if (!(el instanceof Element)) return "";
    const parts = [];
    while (el && el.nodeType === 1 && parts.length < 8) {
      let part = el.tagName.toLowerCase();
      if (el.id) {
        part += "#" + CSS.escape(el.id);
        parts.unshift(part);
        break;
      }
      const cls = [...el.classList].filter((c) => !c.startsWith("breakdance-")).slice(0, 3);
      if (cls.length) part += "." + cls.map((c) => CSS.escape(c)).join(".");
      const parent = el.parentElement;
      if (parent) {
        const siblings = [...parent.children].filter((n) => n.tagName === el.tagName);
        if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(el) + 1})`;
      }
      parts.unshift(part);
      el = parent;
    }
    return parts.join(" > ");
  }

  function breakdanceHits(el) {
    const hits = [];
    for (const c of el.classList || []) {
      const m = c.match(BD_RE);
      if (m) hits.push({ className: c, element: m[1], postId: m[2], nodeId: m[3] });
    }
    return hits;
  }

  function summarize(el) {
    const bd = breakdanceHits(el);
    const rect = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    const html = el.outerHTML.replace(/\s+/g, " ").trim();
    return {
      tag: el.tagName.toLowerCase(),
      id: el.id || null,
      classes: [...(el.classList || [])].slice(0, 40),
      breakdance: bd,
      cssPath: cssPath(el),
      text: (el.innerText || "").replace(/\s+/g, " ").trim().slice(0, 240),
      box: {
        w: Math.round(rect.width),
        h: Math.round(rect.height),
      },
      layout: {
        display: cs.display,
        flexDirection: cs.flexDirection,
        flexWrap: cs.flexWrap,
        gap: cs.gap,
        width: cs.width,
        maxWidth: cs.maxWidth,
      },
      href: location.href,
      htmlPreview: html.slice(0, 1200) + (html.length > 1200 ? "…" : ""),
    };
  }

  function parentChain(el, max = 12) {
    const chain = [];
    let cur = el;
    for (let i = 0; i < max && cur && cur !== document.documentElement; i++) {
      const bd = breakdanceHits(cur);
      const label =
        cur.tagName.toLowerCase() +
        (cur.id ? "#" + cur.id : "") +
        (bd[0] ? " · " + bd[0].className : "") +
        (cur.classList.contains("bde-columns") ? " [Columns]" : "") +
        (cur.classList.contains("bde-column") ? " [Column]" : "") +
        (cur.classList.contains("bde-section") ? " [Section]" : "");
      chain.push({ el: cur, label, depth: i });
      cur = cur.parentElement;
    }
    return chain;
  }

  function packMarkdown(summary, note, depthLabel) {
    const bdLines =
      summary.breakdance.length === 0
        ? "_none_"
        : summary.breakdance
            .map(
              (b) =>
                `- \`${b.className}\` → Breakdance **${b.element}** post \`${b.postId}\` node \`${b.nodeId}\``
            )
            .join("\n");
    return [
      "### Element pack for Norvado",
      note ? `**Ask:** ${note}` : "**Ask:** _(none — inspect / fix as needed)_",
      `**Page:** ${summary.href}`,
      `**Depth:** ${depthLabel}`,
      `**Target:** \`${summary.tag}${summary.id ? "#" + summary.id : ""}\``,
      `**CSS path:** \`${summary.cssPath}\``,
      `**Box:** ${summary.box.w}×${summary.box.h} · display \`${summary.layout.display}\` · flex \`${summary.layout.flexDirection}\` / wrap \`${summary.layout.flexWrap}\``,
      `**Text:** ${summary.text || "_(empty)_"}`,
      "**Breakdance:**",
      bdLines,
      "**Classes:**",
      "```",
      summary.classes.join(" "),
      "```",
      "**HTML (truncated):**",
      "```html",
      summary.htmlPreview,
      "```",
    ].join("\n");
  }

  const ui = document.createElement("div");
  ui.id = "nv-grok-pick";
  Object.assign(ui.style, {
    position: "fixed",
    zIndex: "2147483646",
    right: "16px",
    bottom: "16px",
    width: "min(420px, calc(100vw - 32px))",
    maxHeight: "70vh",
    overflow: "auto",
    background: "#0f3a37",
    color: "#f3f3ec",
    font: "13px/1.4 system-ui, sans-serif",
    borderRadius: "12px",
    boxShadow: "0 12px 40px rgba(0,0,0,.35)",
    padding: "14px 14px 12px",
  });
  ui.innerHTML = `
    <div style="font-weight:600;margin-bottom:6px">PointPaste → Grok Bot</div>
    <div style="opacity:.85;margin-bottom:10px">Click any element. Pick a parent if needed. Add a note, then copy and paste into chat.</div>
    <label style="display:block;margin:0 0 4px;opacity:.8">Target</label>
    <select id="nv-grok-depth" style="width:100%;margin-bottom:8px;padding:6px;border-radius:8px;border:0"></select>
    <label style="display:block;margin:0 0 4px;opacity:.8">Note (optional)</label>
    <textarea id="nv-grok-note" rows="3" placeholder="e.g. stack these at tablet; gap too wide on mobile"
      style="width:100%;box-sizing:border-box;margin-bottom:8px;padding:8px;border-radius:8px;border:0;resize:vertical"></textarea>
    <div style="display:flex;gap:8px;flex-wrap:wrap">
      <button id="nv-grok-copy" type="button" style="flex:1;padding:8px 10px;border:0;border-radius:8px;background:#93d500;color:#111614;font-weight:600;cursor:pointer">Copy for Grok Bot</button>
      <button id="nv-grok-cancel" type="button" style="padding:8px 10px;border:0;border-radius:8px;background:#1a4f4a;color:#f3f3ec;cursor:pointer">Esc</button>
    </div>
    <div id="nv-grok-status" style="margin-top:8px;opacity:.85;min-height:1.2em"></div>
  `;

  const highlight = document.createElement("div");
  Object.assign(highlight.style, {
    position: "fixed",
    pointerEvents: "none",
    zIndex: "2147483645",
    border: "2px solid #93d500",
    background: "rgba(147,213,0,.12)",
    display: "none",
  });

  let chain = [];
  let selected = null;

  function paintHighlight(el) {
    if (!el) {
      highlight.style.display = "none";
      return;
    }
    const r = el.getBoundingClientRect();
    Object.assign(highlight.style, {
      display: "block",
      left: r.left + "px",
      top: r.top + "px",
      width: r.width + "px",
      height: r.height + "px",
    });
  }

  function fillDepth() {
    const sel = ui.querySelector("#nv-grok-depth");
    sel.innerHTML = "";
    chain.forEach((item, i) => {
      const opt = document.createElement("option");
      opt.value = String(i);
      opt.textContent = (i === 0 ? "● " : "↑ ".repeat(Math.min(i, 3))) + item.label;
      sel.appendChild(opt);
    });
    sel.onchange = () => {
      selected = chain[Number(sel.value)]?.el || null;
      paintHighlight(selected);
    };
  }

  function onClick(e) {
    if (ui.contains(e.target)) return;
    e.preventDefault();
    e.stopPropagation();
    const el = e.target;
    if (!(el instanceof Element)) return;
    chain = parentChain(el);
    selected = el;
    fillDepth();
    paintHighlight(el);
    ui.querySelector("#nv-grok-status").textContent = "Selected. Climb parents in the list if you want a wrapper.";
    ui.querySelector("#nv-grok-note").focus();
  }

  function onMove(e) {
    if (ui.contains(e.target) || selected) return;
    const el = e.target;
    if (el instanceof Element) paintHighlight(el);
  }

  async function copyPack() {
    if (!selected) {
      ui.querySelector("#nv-grok-status").textContent = "Click an element first.";
      return;
    }
    const depth = Number(ui.querySelector("#nv-grok-depth").value) || 0;
    const item = chain[depth];
    const note = ui.querySelector("#nv-grok-note").value.trim();
    const md = packMarkdown(summarize(item.el), note, item.label);
    try {
      await navigator.clipboard.writeText(md);
      ui.querySelector("#nv-grok-status").textContent = "Copied. Paste into Grok Bot (⌘V).";
    } catch (err) {
      // fallback
      const ta = document.createElement("textarea");
      ta.value = md;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
      ui.querySelector("#nv-grok-status").textContent = "Copied (fallback). Paste into Grok Bot (⌘V).";
    }
  }

  function teardown() {
    document.removeEventListener("click", onClick, true);
    document.removeEventListener("mousemove", onMove, true);
    document.removeEventListener("keydown", onKey, true);
    ui.remove();
    highlight.remove();
    window.__nvGrokPick = null;
  }

  function onKey(e) {
    if (e.key === "Escape") {
      e.preventDefault();
      teardown();
    }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "enter") {
      e.preventDefault();
      copyPack();
    }
  }

  document.documentElement.appendChild(highlight);
  document.documentElement.appendChild(ui);
  document.addEventListener("click", onClick, true);
  document.addEventListener("mousemove", onMove, true);
  document.addEventListener("keydown", onKey, true);
  ui.querySelector("#nv-grok-copy").onclick = copyPack;
  ui.querySelector("#nv-grok-cancel").onclick = teardown;

  window.__nvGrokPick = { active: true, teardown };
})();
