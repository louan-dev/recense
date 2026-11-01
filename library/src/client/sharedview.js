// The Shared section (/main/shared; the Worker's shared.js). Three views on one page, by hash:
//   ""                 Shared: every live share link as a square album tile
//   "#activity"        Activity: uploads, likes and comments in the shares, newest first, thumbnails on the right
//   "#s/<kind>/<id>"   one share: all its files, Copy Link (public links), Delete (expires the link now)
// Personal goes back to Main. Controls are plain blue (ui/README §1.1): no glass, no red.
(() => {
  const S = window.SHARED || {};
  const app = document.getElementById("app");
  const H = { "x-gallery": "1" };
  let shares = null;

  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  };
  const svg = (d, fill) => {
    const s = '<svg viewBox="0 0 24 24" fill="' + (fill ? "currentColor" : "none") + '" stroke="' + (fill ? "none" : "currentColor") + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' + d + "</svg>";
    const t = document.createElement("template");
    t.innerHTML = s;
    return t.content.firstChild;
  };
  const I = {
    back: '<path d="M15 18l-6-6 6-6"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    more: '<circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/>',
    people: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><circle cx="17" cy="9" r="2.5"/><path d="M16 14a5 5 0 0 1 6 5"/>',
    link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
    trash: '<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6"/>',
    reload: '<path d="M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5"/>',
    doc: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6"/>',
    wave: '<path d="M3 12h2M7 8v8M11 5v14M15 9v6M19 11v2"/>',
    film: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M10 9l5 3-5 3z"/>',
  };

  const initials = (n) => String(n || "").trim().split(/\s+/).slice(0, 2).map((w) => w[0] || "").join("").toUpperCase() || "?";
  const day = (t) => new Date(t).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  const ago = (t) => {
    const s = Math.max(0, (Date.now() - t) / 1000);
    if (s < 60) return "Just now";
    if (s < 3600) return Math.floor(s / 60) + "m ago";
    if (s < 86400) return Math.floor(s / 3600) + "h ago";
    if (s < 7 * 86400) return Math.floor(s / 86400) + "d ago";
    return day(t);
  };
  const expiry = (t) => (!t ? "Never expires" : t - Date.now() < 86400e3 ? "Expires today" : "Expires " + day(t));
  const items = (n) => n + (n === 1 ? " item" : " items");

  let toastT;
  const toast = (msg) => {
    let t = document.querySelector(".toast");
    if (!t) document.body.appendChild((t = el("div", "toast")));
    t.textContent = msg;
    t.classList.add("on");
    clearTimeout(toastT);
    toastT = setTimeout(() => t.classList.remove("on"), 2200);
  };

  const api = async (path, init = {}) => {
    const r = await fetch(path, { ...init, headers: { ...H, ...(init.headers || {}) } });
    if (!r.ok) throw new Error((await r.text()) || "Gallery isn’t answering");
    return r.json();
  };

  // a picture for a file: its cover or the image, a video's first frame, else a glyph
  const media = (f, cls) => {
    if (f && f.thumb) {
      const i = el("img");
      i.loading = "lazy";
      i.decoding = "async";
      i.alt = "";
      i.src = f.thumb;
      return i;
    }
    if (f && f.video && f.src) {
      const v = el("video");
      v.muted = true;
      v.playsInline = true;
      v.preload = "metadata";
      v.src = f.src + "#t=0.1";
      return v;
    }
    const g = el("div", cls || "g");
    const t = f ? f.type || "" : "";
    g.appendChild(svg(t.startsWith("audio/") ? I.wave : t.startsWith("video/") ? I.film : I.doc));
    return g;
  };

  // ---------- chrome ----------

  function top(title, left, right) {
    const bar = el("header", "top");
    const l = el("div", "l");
    const r = el("div", "r");
    if (left) l.appendChild(left);
    if (right) right.forEach((b) => r.appendChild(b));
    bar.append(l, el("h1", "", title), r);
    return bar;
  }

  function seg(on) {
    const s = el("div", "seg");
    s.setAttribute("role", "tablist");
    for (const [name, go] of [["Personal", () => (location.href = "/main/")], ["Shared", () => nav("")], ["Activity", () => nav("#activity")]]) {
      const b = el("button", "", name);
      b.type = "button";
      b.setAttribute("role", "tab");
      b.setAttribute("aria-selected", String(name === on));
      b.onclick = go;
      s.appendChild(b);
    }
    return s;
  }

  function iconBtn(d, label, onclick, fill) {
    const b = el("button", "ic");
    b.type = "button";
    b.setAttribute("aria-label", label);
    b.appendChild(svg(d, fill));
    b.onclick = onclick;
    return b;
  }

  function feedTop(on) {
    const back = el("a", "circ");
    back.href = "/main/";
    back.setAttribute("aria-label", "Back");
    back.appendChild(svg(I.back));
    const plus = iconBtn(I.plus, "Create Share Link", () => (location.href = "/main/share"));
    const more = iconBtn(I.more, "More", () => menu(), true);
    return [top("Shared", back, [plus, more]), seg(on)];
  }

  function overlay(build) {
    const scrim = el("div", "scrim");
    const close = () => {
      scrim.remove();
      box.remove();
      removeEventListener("keydown", esc);
    };
    const esc = (e) => e.key === "Escape" && close();
    const box = build(close);
    scrim.onclick = close;
    addEventListener("keydown", esc);
    document.body.append(scrim, box);
    return close;
  }

  function menu() {
    overlay((close) => {
      const m = el("div", "menu");
      m.setAttribute("role", "menu");
      const a = el("a");
      a.href = "/main/share";
      a.append(svg(I.link), "Create Share Link");
      const r = el("button");
      r.type = "button";
      r.append(svg(I.reload), "Refresh");
      r.onclick = () => {
        close();
        shares = null;
        route();
      };
      m.append(a, r);
      return m;
    });
  }

  function confirmSheet(title, body, yes, act) {
    overlay((close) => {
      const s = el("div", "sheet");
      s.setAttribute("role", "dialog");
      const ok = el("button", "lnk", yes);
      const no = el("button", "lnk", "Cancel");
      ok.type = no.type = "button";
      ok.onclick = () => {
        close();
        act();
      };
      no.onclick = close;
      s.append(el("p", "", title), el("p", "mut", body), ok, no);
      return s;
    });
  }

  // ---------- Shared: the tiles ----------

  async function load() {
    shares = (await api("/main/api/shares")).shares;
    return shares;
  }

  function card(s) {
    const c = el("a", "card");
    c.href = "#s/" + s.kind + "/" + s.id;
    c.dataset.id = s.id;
    if (s.cover) c.appendChild(media({ thumb: s.coverVideo ? null : s.cover, src: s.cover, video: s.coverVideo }));
    else {
      const ph = el("div", "ph");
      ph.appendChild(svg(I.people));
      c.appendChild(ph);
    }
    const badge = el("span", "badge");
    if (s.who) badge.textContent = initials(s.who);
    else badge.appendChild(svg(s.type === "folder" ? I.link : I.people));
    badge.title = s.who ? "Shared with " + s.who : "Anyone with the link";
    const t = el("span", "t", s.title);
    t.appendChild(el("small", "", items(s.count) + " · " + expiry(s.exp)));
    c.append(badge, t);
    return c;
  }

  async function sharedView() {
    app.replaceChildren(...feedTop("Shared"));
    const list = await load();
    if (!list.length) {
      app.appendChild(el("p", "empty", "No share links are live. Make one with + or from a folder’s Share."));
      return;
    }
    const g = el("div", "grid");
    list.forEach((s) => g.appendChild(card(s)));
    app.appendChild(g);
  }

  // ---------- one share ----------

  async function detailView(kind, id) {
    const back = el("a", "back");
    back.href = "#";
    back.append(svg(I.back), "Shared");
    const del = el("button", "lnk", "Delete");
    del.type = "button";
    app.replaceChildren(top("", back, [del]));

    let s;
    try {
      s = (await api("/main/api/shares/" + kind + "/" + id)).share;
    } catch (e) {
      app.appendChild(el("p", "empty", "This share link isn’t live any more."));
      del.disabled = true;
      return;
    }

    del.onclick = () =>
      confirmSheet(
        "Delete “" + s.title + "”?",
        s.kind === "invite" ? s.who + " loses access now." : "The link stops working now for everyone who has it.",
        "Delete Share Link",
        async () => {
          del.disabled = true;
          try {
            await api("/main/api/shares/" + kind + "/" + id, { method: "DELETE" });
            if (shares) shares = shares.filter((x) => !(x.kind === kind && x.id === id));
            toast("Share link deleted");
            nav("");
          } catch (e) {
            del.disabled = false;
            toast(e.message);
          }
        }
      );

    const head = el("div", "dhead");
    const meta = [items(s.count), expiry(s.exp), s.who ? "With " + s.who : "Anyone with the link"].join(" · ");
    head.append(el("h2", "", s.title), el("div", "m", meta));
    if (s.url) {
      const acts = el("div", "acts");
      const copy = el("button", "lnk", "Copy Link");
      copy.type = "button";
      copy.onclick = async () => {
        try {
          await navigator.clipboard.writeText((S.origin || location.origin) + s.url);
          toast("Link copied");
        } catch (e) {
          toast((S.origin || location.origin) + s.url);
        }
      };
      const open = el("a", "lnk", "Open");
      open.href = s.url;
      open.target = "_blank";
      open.rel = "noopener";
      open.style.textDecoration = "none";
      acts.append(copy, open);
      head.appendChild(acts);
    }
    app.appendChild(head);
    if (s.perms) app.appendChild(permsBox(s));

    if (!s.items.length) {
      app.appendChild(el("p", "empty", "No files in this link."));
      return;
    }
    const g = el("div", "files");
    s.items.forEach((f, i) => {
      const t = el("button", "tile");
      t.type = "button";
      t.setAttribute("aria-label", f.name);
      t.appendChild(media(f));
      if (!f.thumb && !f.video) t.appendChild(el("span", "nm", f.pending ? "Uploading…" : f.name));
      if (f.by) t.appendChild(el("span", "who", initials(f.by)));
      if (f.comments || f.likes) t.appendChild(el("span", "k", (f.likes ? "♥ " + f.likes + " " : "") + (f.comments ? "💬 " + f.comments : "")));
      t.onclick = () => !f.pending && viewer(s.items.filter((x) => !x.pending), s.items.filter((x) => !x.pending).indexOf(f));
      g.appendChild(t);
    });
    app.appendChild(g);
  }

  // What the people with this share can do besides view, like and comment: the owner's overrides (shared.js PATCH).
  // Archive shares start view-and-comment only; a room (an invite to some files) never takes uploads.
  function permsBox(s) {
    const box = el("div", "perms");
    const row = (label, key, note, off) => {
      const r = el("label", "sw");
      const c = el("input");
      c.type = "checkbox";
      c.setAttribute("role", "switch");
      c.checked = !!s.perms[key];
      c.disabled = !!off;
      c.onchange = async () => {
        c.disabled = true;
        try {
          s.perms = { ...s.perms, ...(await api("/main/api/shares/" + s.kind + "/" + s.id, { method: "PATCH", body: JSON.stringify({ [key]: c.checked }) })).perms };
          toast(label + (c.checked ? " on" : " off"));
        } catch (e) {
          c.checked = !c.checked;
          toast(e.message);
        }
        c.disabled = false;
      };
      const t = el("span", "t");
      t.append(el("b", "", label), el("small", "", note));
      r.append(t, c, el("i"));
      return r;
    };
    const room = s.perms.room;
    if (!(s.kind === "link" && s.type === "folder")) {
      box.appendChild(row("Subscribers Can Post", "upload", room ? "Only for a whole folder" : s.kind === "link" ? "Their files expire with the link" : "Their files stay until you delete them", room));
    }
    box.appendChild(row("Allow Downloads", "download", s.perms.archive ? "From the archive: view and comment only until you allow more" : "Save files and Save All"));
    return box;
  }

  // a plain viewer for the share's files; arrows and swipes move through them
  function viewer(list, at) {
    if (!list.length) return;
    const v = el("div", "view");
    v.setAttribute("role", "dialog");
    const vt = el("div", "vt");
    const done = el("button", "lnk", "Done");
    const title = el("b");
    const count = el("span", "lnk");
    count.style.color = "var(--text-2)";
    vt.append(done, title, count);
    const vm = el("div", "vm");
    const vb = el("div", "vb");
    const prev = el("button", "lnk", "Previous");
    const next = el("button", "lnk", "Next");
    vb.append(prev, next);
    v.append(vt, vm, vb);

    const show = () => {
      const f = list[at];
      title.textContent = f.name;
      count.textContent = at + 1 + " of " + list.length;
      prev.disabled = at === 0;
      next.disabled = at === list.length - 1;
      let m;
      if (f.type.startsWith("image/")) {
        m = el("img");
        m.src = f.src;
        m.alt = f.name;
      } else if (f.type.startsWith("video/")) {
        m = el("video");
        m.src = f.src;
        m.controls = m.playsInline = true;
      } else if (f.type.startsWith("audio/")) {
        m = el("div");
        m.style.display = "grid";
        m.style.justifyItems = "center";
        m.style.gap = "16px";
        if (f.thumb) {
          const i = el("img");
          i.src = f.thumb;
          i.style.maxHeight = "50vh";
          m.appendChild(i);
        }
        const a = el("audio");
        a.src = f.src;
        a.controls = true;
        m.appendChild(a);
      } else {
        m = el("a", "lnk", "Open " + f.name);
        m.href = f.src;
        m.target = "_blank";
        m.rel = "noopener";
      }
      vm.replaceChildren(m);
    };
    const go = (d) => {
      const n = at + d;
      if (n >= 0 && n < list.length) {
        at = n;
        show();
      }
    };
    const key = (e) => {
      if (e.key === "Escape") close();
      else if (e.key === "ArrowLeft") go(-1);
      else if (e.key === "ArrowRight") go(1);
    };
    const close = () => {
      v.remove();
      removeEventListener("keydown", key);
    };
    let x0 = null;
    vm.addEventListener("touchstart", (e) => (x0 = e.touches[0].clientX), { passive: true });
    vm.addEventListener("touchend", (e) => {
      if (x0 == null) return;
      const dx = e.changedTouches[0].clientX - x0;
      x0 = null;
      if (Math.abs(dx) > 50) go(dx < 0 ? 1 : -1);
    });
    done.onclick = close;
    prev.onclick = () => go(-1);
    next.onclick = () => go(1);
    addEventListener("keydown", key);
    document.body.appendChild(v);
    show();
  }

  // ---------- Activity ----------

  function said(e) {
    const who = el("b", "", e.mine ? "You" : e.by);
    const x = el("span");
    x.appendChild(who);
    // someone who opened a share link: the name they gave, and a short tag that tells two guests of one name apart
    if (e.guest) {
      x.append(" ");
      const g = el("span", "guest", "Guest");
      g.title = "Commented from the share link · visitor " + e.guest;
      x.appendChild(g);
    }
    const what = (n, noun) => (n === 1 ? "a " + noun : n + " " + noun + "s");
    const kind = (f) => (f && f.type ? (f.type.startsWith("video/") ? "video" : f.type.startsWith("audio/") ? "recording" : f.type.startsWith("image/") ? "photo" : "file") : "item");
    if (e.type === "comment") {
      x.append(" commented: ");
      x.appendChild(el("q", "", e.text));
    } else if (e.type === "like") x.append(" liked " + what(1, kind(e.items[0])));
    else if (e.type === "upload") x.append(" added " + what(e.count, e.count === 1 ? kind(e.items[0]) : "item"));
    else x.append(" shared " + what(e.count, "item") + (e.who ? " with " + e.who : ""));
    return x;
  }

  async function activityView() {
    app.replaceChildren(...feedTop("Activity"));
    const { events } = await api("/main/api/activity");
    if (!events.length) {
      app.appendChild(el("p", "empty", "No activity yet. Uploads, likes and comments in your share links show here."));
      return;
    }
    const ul = el("ul", "feed");
    for (const e of events) {
      const li = el("li");
      const row = el("a", "ev");
      row.href = "#s/" + e.share.kind + "/" + e.share.id;
      row.style.color = "inherit";
      row.style.textDecoration = "none";
      const av = el("span", "av", initials(e.mine ? S.owner : e.by));
      const x = el("span", "x");
      x.appendChild(said(e));
      const s = el("span", "s");
      s.append(el("span", "hl", e.share.title), " · " + ago(e.at));
      x.appendChild(s);
      const th = el("span", "th");
      const shown = e.items.slice(0, e.count > e.items.length ? 2 : 3);
      shown.forEach((f) => {
        const b = el("span");
        b.appendChild(media(f));
        th.appendChild(b);
      });
      if (e.count > shown.length && shown.length) th.appendChild(el("span", "more", "+" + (e.count - shown.length)));
      row.append(av, x, th);
      li.appendChild(row);
      ul.appendChild(li);
    }
    app.appendChild(ul);
  }

  // ---------- routing ----------

  function nav(h) {
    if (location.hash === h || (!h && !location.hash)) route();
    else location.hash = h;
  }

  async function route() {
    const h = location.hash.replace(/^#/, "");
    const m = h.match(/^s\/(link|invite)\/([A-Za-z0-9]+)$/);
    scrollTo(0, 0);
    try {
      if (m) await detailView(m[1], m[2]);
      else if (h === "activity") await activityView();
      else await sharedView();
    } catch (e) {
      app.appendChild(el("p", "empty", e.message || "Gallery isn’t answering right now."));
    }
  }

  addEventListener("hashchange", route);
  route();
})();
