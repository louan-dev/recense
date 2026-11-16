// FEAT-08 · the Matter menu: every crossing of a passage reachable from one plain list, the same place on
// Mac, iPhone and iPad (decision 2026-11-16). A small "Matter" pill appears by a selection after a short
// rest; tapping it, or right-click / long-press on the selection, opens the list. Items are named by what
// you get (src/matter.js LABELS). The radial menu and squeeze (UI-04, lane draftpad-ink) are shortcuts that
// place the same list (matterActions); this file draws no radial UI.

export const PILL_DELAY_MS = 450;

export function createMatterMenu({ mount, view, getMenu, onRun, doc = typeof document !== 'undefined' ? document : null }) {
  if (!mount || !view || !doc) return { selectionChanged() {}, open() {}, close() {}, isOpen: () => false };

  const pill = doc.createElement('button');
  pill.type = 'button';
  pill.className = 'rc-matter-pill';
  pill.textContent = 'Matter';
  pill.hidden = true;
  pill.setAttribute('aria-label', 'Matter: change this passage into another form');

  const list = doc.createElement('div');
  list.className = 'rc-matter-menu';
  list.setAttribute('role', 'menu');
  list.hidden = true;

  mount.appendChild(pill);
  mount.appendChild(list);

  let timer = null;
  let range = null;

  const sel = () => {
    const r = view.state.selection.main;
    return r.empty ? null : { from: r.from, to: r.to };
  };

  function placeAt(el, x, y) {
    const box = mount.getBoundingClientRect ? mount.getBoundingClientRect() : { left: 0, top: 0, width: 800 };
    const left = Math.max(8, Math.min((box.width || 800) - 180, x - box.left));
    el.style.left = `${left}px`;
    el.style.top = `${Math.max(8, y - box.top)}px`;
  }

  function hidePill() {
    clearTimeout(timer);
    pill.hidden = true;
  }

  function close() {
    list.hidden = true;
    list.innerHTML = '';
  }

  function open(r = sel(), x = null, y = null) {
    if (!r) return false;
    const menu = getMenu(r.from, r.to);
    if (!menu || !menu.actions.length) return false;
    range = r;
    list.innerHTML = '';
    for (const a of menu.actions) {
      const b = doc.createElement('button');
      b.type = 'button';
      b.className = 'rc-matter-item';
      b.setAttribute('role', 'menuitem');
      b.dataset.id = a.id;
      b.textContent = a.label;
      b.addEventListener('click', e => {
        e.preventDefault();
        e.stopPropagation();
        const res = onRun(a, range);
        if (res && res.ok === false) {
          const note = doc.createElement('div');
          note.className = 'rc-matter-note';
          note.textContent = res.error || 'Not done';
          list.appendChild(note);
          setTimeout(close, 2400);
        } else close();
      });
      list.appendChild(b);
    }
    if (x == null) {
      const c = view.coordsAtPos ? view.coordsAtPos(r.to) : null;
      if (c) { x = c.left; y = c.bottom + 6; }
    }
    if (x != null) placeAt(list, x, y);
    hidePill();
    list.hidden = false;
    const first = list.querySelector('button');
    if (first && first.focus) first.focus();
    return true;
  }

  function selectionChanged() {
    hidePill();
    if (!list.hidden) close();
    const r = sel();
    if (!r) return;
    timer = setTimeout(() => {
      const now = sel();
      if (!now || now.from !== r.from || now.to !== r.to) return;
      const menu = getMenu(r.from, r.to);
      if (!menu || !menu.actions.length) return;
      const c = view.coordsAtPos ? view.coordsAtPos(r.to) : null;
      if (!c) return;
      placeAt(pill, c.left, c.bottom + 6);
      pill.hidden = false;
    }, PILL_DELAY_MS);
  }

  pill.addEventListener('pointerdown', e => e.preventDefault());   // keep the selection
  pill.addEventListener('click', e => {
    e.preventDefault();
    e.stopPropagation();
    open();
  });
  // Right-click on the Mac; long-press where the WebView sends contextmenu.
  view.dom.addEventListener('contextmenu', e => {
    if (!sel()) return;
    if (open(sel(), e.clientX, e.clientY)) e.preventDefault();
  });
  doc.addEventListener('keydown', e => { if (e.key === 'Escape' && !list.hidden) close(); });
  doc.addEventListener('pointerdown', e => {
    if (!list.hidden && !list.contains(e.target)) close();
  });

  return { selectionChanged, open, close, isOpen: () => !list.hidden, pill, list };
}
