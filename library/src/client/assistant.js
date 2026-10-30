// The assistant's sidebar on the owner's pages (/main and /main/archive). Inlined only when the page is the owner's
// (page/gallery.js, live.main): a participant's or the public page never contains it. The server checks again anyway
// (/main gate + sameSite in worker.js). Talks to /main/api/ai/… (src/ai.js).
(() => {
  "use strict";
  const live = typeof G !== "undefined" ? G : {};          // the page's data (page/gallery.js: const G=…)
  const btn = document.getElementById("aibtn"), panel = document.getElementById("aip");
  if (!btn || !panel) return;
  const $ = (s) => panel.querySelector(s);
  const list = $("#aim"), form = $("#aif"), box = $("#aiq"), send = $("#aisend"), stat = $("#aistat"), memo = $("#aimem");
  const root = live.id === "archive" ? "archive" : "main", dir = String(live.dir || "");
  const H = { "x-gallery": "1" };
  let scope = "here", history = [], busy = false;

  try { history = JSON.parse(sessionStorage.getItem("ai.history") || "[]"); } catch { history = []; }
  const keep = () => { try { sessionStorage.setItem("ai.history", JSON.stringify(history.slice(-12))); } catch { /* private mode */ } };

  // ---------- open / close ----------
  const open = () => {
    panel.hidden = false; document.body.classList.add("aiopen"); btn.setAttribute("aria-expanded", "true");
    setTimeout(() => box.focus(), 50); refreshStatus();
    if (!list.children.length) for (const m of history) render(m.role, m.content, m.sources || []);
  };
  const close = () => { panel.hidden = true; document.body.classList.remove("aiopen"); btn.setAttribute("aria-expanded", "false"); };
  btn.addEventListener("click", () => (panel.hidden ? open() : close()));
  $("#aidone").addEventListener("click", close);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !panel.hidden) close(); });

  // ---------- scope: what is open, or everything ----------
  const here = $("#aihere"), all = $("#aiall");
  const where = dir ? dir.split("/").pop() : root === "archive" ? "Archive" : "Main";
  here.textContent = "This folder";
  here.title = (root === "archive" ? "Archive" : "Main") + (dir ? " / " + dir : "");
  const setScope = (s) => { scope = s; here.classList.toggle("on", s === "here"); all.classList.toggle("on", s === "all"); here.setAttribute("aria-pressed", s === "here"); all.setAttribute("aria-pressed", s === "all"); };
  here.addEventListener("click", () => setScope("here")); all.addEventListener("click", () => setScope("all"));
  setScope("here");
  box.placeholder = `Ask about ${where}, your calendar, or anything…`;

  // ---------- rendering ----------
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  /** A small, safe markdown: escapes first, then bold, code, links to sources [n], lists, tables, paragraphs. */
  function md(text, nSources) {
    const lines = esc(text).split("\n"), out = [];
    let inList = false, table = [];
    const inline = (s) => s
      .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\[(\d{1,2})\]/g, (m, n) => (+n >= 1 && +n <= nSources ? `<a class="aicite" href="#" data-n="${n}">[${n}]</a>` : m))
      .replace(/(https:\/\/[^\s<]+\/c\/[0-9a-f]{32}\.ics)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>');
    const flushTable = () => {
      if (!table.length) return;
      const rows = table.filter((r) => !/^\|?\s*:?-{2,}/.test(r)).map((r) => r.replace(/^\||\|$/g, "").split("|").map((c) => inline(c.trim())));
      out.push("<table>" + rows.map((r, i) => "<tr>" + r.map((c) => (i ? `<td>${c}</td>` : `<th>${c}</th>`)).join("") + "</tr>").join("") + "</table>");
      table = [];
    };
    for (const l of lines) {
      if (/^\s*\|.*\|\s*$/.test(l)) { if (inList) { out.push("</ul>"); inList = false; } table.push(l.trim()); continue; }
      flushTable();
      const li = /^\s*(?:[-*•]|\d+[.)])\s+(.*)$/.exec(l);
      if (li) { if (!inList) { out.push("<ul>"); inList = true; } out.push(`<li>${inline(li[1])}</li>`); continue; }
      if (inList) { out.push("</ul>"); inList = false; }
      if (/^#{1,4}\s/.test(l)) { out.push(`<p><b>${inline(l.replace(/^#+\s*/, ""))}</b></p>`); continue; }
      out.push(l.trim() ? `<p>${inline(l)}</p>` : "");
    }
    flushTable(); if (inList) out.push("</ul>");
    return out.join("");
  }

  const AUTH = { reference: "published", personal: "personal", transcript: "recording", name: "file name" };
  const fmt = (t) => { const s = Math.max(0, Math.floor(t)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; };
  const folderHref = (src) => {
    const d = src.path.split("/").slice(0, -1).join("/");
    return (src.root === "archive" ? "/main/archive" : "/main/") + (d ? "?p=" + encodeURIComponent(d) : "");
  };

  function render(role, text, sources = []) {
    const el = document.createElement("div");
    el.className = "aimsg " + (role === "user" ? "aiuser" : "aibot");
    if (role === "user") el.textContent = text;
    else {
      el.innerHTML = `<div class="aitext">${md(text, sources.length)}</div>`;
      if (sources.length) {
        const ol = document.createElement("ol"); ol.className = "aisrc";
        for (const s of sources) {
          const li = document.createElement("li");
          li.id = "";
          li.innerHTML = `<span class="ain">[${s.n}]</span> <span class="aip">${esc((s.root === "archive" ? "Archive / " : "Main / ") + s.path)}${s.t != null ? " · " + fmt(s.t) : ""}</span> <span class="aia">${esc(AUTH[s.auth] || "")}</span> <a class="lnk aiopen" href="${esc(folderHref(s))}">Open</a>`;
          ol.appendChild(li);
        }
        el.appendChild(ol);
        el.addEventListener("click", (e) => {
          const a = e.target.closest(".aicite"); if (!a) return;
          e.preventDefault();
          const li = ol.children[+a.dataset.n - 1]; if (li) { li.scrollIntoView({ block: "nearest", behavior: "smooth" }); li.classList.add("aiflash"); setTimeout(() => li.classList.remove("aiflash"), 900); }
        });
      }
    }
    list.appendChild(el);
    list.scrollTop = list.scrollHeight;
    return el;
  }

  // ---------- asking ----------
  const TOOL = { list_events: "Checking your calendar…", create_event: "Adding the event…", update_event: "Changing the event…", add_invitee: "Adding the invitee…" };
  async function ask(q) {
    busy = true; send.disabled = true; box.disabled = true;
    render("user", q);
    const el = render("assistant", ""), textEl = el.querySelector(".aitext");
    textEl.innerHTML = '<p class="aiwait">Thinking…</p>';
    let text = "", sources = [], failed = null;
    try {
      const r = await fetch("/main/api/ai/ask", {
        method: "POST", headers: { ...H, "content-type": "application/json" },
        body: JSON.stringify({ q, scope: scope === "all" ? { root: "all" } : { root, path: dir }, history: history.slice(-6).map(({ role, content }) => ({ role, content })) }),
      });
      if (!r.ok || !r.body) throw new Error(r.status === 503 ? "The assistant isn't set up yet." : "The assistant didn't answer (" + r.status + ").");
      const reader = r.body.pipeThrough(new TextDecoderStream()).getReader();
      let buf = "";
      for (;;) {
        const { value, done } = await reader.read(); if (done) break;
        buf += value;
        let i;
        while ((i = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
          if (!line) continue;
          let o; try { o = JSON.parse(line); } catch { continue; }
          if (o.sources) sources = o.sources;
          if (o.tool) textEl.innerHTML = `<p class="aiwait">${esc(TOOL[o.tool] || "Working…")}</p>`;
          if (o.t) { text += o.t; textEl.innerHTML = md(text, sources.length); list.scrollTop = list.scrollHeight; }
          if (o.error) failed = o.error;
        }
      }
    } catch (e) { failed = e && e.message ? e.message : "Something went wrong."; }
    el.remove();
    if (failed && !text) text = failed;
    render("assistant", text || "No answer came back. Please try again.", sources);
    history.push({ role: "user", content: q }, { role: "assistant", content: text, sources });
    keep();
    busy = false; send.disabled = false; box.disabled = false; box.focus();
    refreshStatus();
  }

  form.addEventListener("submit", (e) => { e.preventDefault(); const q = box.value.trim(); if (!q || busy) return; box.value = ""; grow(); ask(q); });
  box.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); form.requestSubmit(); } });
  const grow = () => { box.style.height = "auto"; box.style.height = Math.min(160, box.scrollHeight) + "px"; };
  box.addEventListener("input", grow);
  $("#ainew").addEventListener("click", () => { history = []; keep(); list.textContent = ""; box.focus(); });

  // ---------- status: how far indexing has got ----------
  async function refreshStatus() {
    try {
      const s = await (await fetch("/main/api/ai/status", { headers: H, cache: "no-store" })).json();
      if (!s.ready) { stat.textContent = "The assistant isn't set up yet."; stat.hidden = false; return; }
      if (s.pending > 0 || s.listing !== "done") {
        stat.textContent = `Reading your files: ${s.files.toLocaleString()} indexed${s.pending ? ", " + s.pending.toLocaleString() + " waiting" : ""}${s.listing !== "done" ? ", still listing" : ""}. Answers may miss what isn't read yet.`;
        stat.hidden = false;
      } else stat.hidden = true;
    } catch { stat.hidden = true; }
  }

  // ---------- memories ----------
  $("#aimems").addEventListener("click", async () => {
    if (!memo.hidden) { memo.hidden = true; return; }
    memo.hidden = false; memo.innerHTML = '<p class="aiwait">Loading…</p>';
    try {
      const { memories = [] } = await (await fetch("/main/api/ai/memory", { headers: H, cache: "no-store" })).json();
      memo.innerHTML = memories.length ? "" : '<p class="aiwait">Nothing yet. Tell me about your preferences and I’ll remember them.</p>';
      for (const m of memories.slice().reverse()) {
        const row = document.createElement("div"); row.className = "aimemrow";
        row.innerHTML = `<span>${esc(m.text)}</span>`;
        const b = document.createElement("button"); b.type = "button"; b.className = "lnk"; b.textContent = "Forget";
        b.addEventListener("click", async () => {
          b.disabled = true;
          const r = await fetch("/main/api/ai/memory?id=" + encodeURIComponent(m.id), { method: "DELETE", headers: H });
          if (r.ok) row.remove(); else b.disabled = false;
        });
        row.appendChild(b); memo.appendChild(row);
      }
    } catch { memo.innerHTML = '<p class="aiwait">Couldn’t load memories.</p>'; }
  });
})();
