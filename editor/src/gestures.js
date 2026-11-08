import { postHaptic } from './bridge.js';

export const HAPTIC_ZONES = Object.freeze({
  top: 44,
  edge: 32,
  dwellMs: 280
});

/**
 * Returns pure dot glyphs (`● ○ ○` for <= 8 windows, or a sliding/grouped pure
 * dot representation for > 8 windows) with zero words or digits at rest.
 */
export function formatDotIndicator(index, total) {
  const safeTotal = Math.max(1, Number(total) || 1);
  const safeIndex = Math.max(0, Math.min(safeTotal - 1, Number(index) || 0));

  if (safeTotal <= 8) {
    const dots = [];
    for (let i = 0; i < safeTotal; i++) {
      dots.push(i === safeIndex ? '●' : '○');
    }
    return dots.join(' ');
  }

  // For > 8 windows: grouped/sliding pure dot representation with zero words or digits
  const windowSize = 8;
  const start = Math.max(0, Math.min(safeTotal - windowSize, safeIndex - Math.floor(windowSize / 2)));
  const dots = [];
  for (let i = start; i < start + windowSize; i++) {
    dots.push(i === safeIndex ? '●' : '○');
  }
  return dots.join(' ');
}

/**
 * Hand-neutral, ambidextrous zone detector returning 'top' | 'left' | 'right' | null.
 * Symmetric left and right edge widths so left-handed and right-handed users
 * have identical targets.
 */
export function detectHapticZone(x, y, width, height, zones = HAPTIC_ZONES) {
  if (typeof x !== 'number' || typeof y !== 'number') return null;
  const w = Number(width) || 0;
  const h = Number(height) || 0;
  if (x < 0 || y < 0 || x > w || y > h) return null;

  const topZone = Number(zones?.top ?? HAPTIC_ZONES.top);
  const edgeZone = Number(zones?.edge ?? HAPTIC_ZONES.edge);

  if (y <= topZone) return 'top';
  if (x <= edgeZone) return 'left';
  if (x >= w - edgeZone) return 'right';
  return null;
}

/**
 * Attaches pointer/touch/Pencil hover and dwell listeners for haptic zone feedback
 * and progressive disclosure.
 */
export function attachHapticZones(container, {
  onZoneEnter = null,
  onZoneDwell = null,
  onZoneLeave = null,
  zones = HAPTIC_ZONES,
  globalObj = typeof window !== 'undefined' ? window : null
} = {}) {
  if (!container || typeof container.addEventListener !== 'function') {
    return () => {};
  }

  const activeZones = {
    top: Number(zones?.top ?? HAPTIC_ZONES.top),
    edge: Number(zones?.edge ?? HAPTIC_ZONES.edge),
    dwellMs: Number(zones?.dwellMs ?? HAPTIC_ZONES.dwellMs)
  };

  let currentZone = null;
  let dwellTimer = null;
  let startX = 0;
  let startY = 0;
  let dragged = false;

  function clearDwellTimer() {
    if (dwellTimer !== null) {
      clearTimeout(dwellTimer);
      dwellTimer = null;
    }
  }

  function getCoords(e) {
    let cx = e.clientX;
    let cy = e.clientY;
    if (e.touches && e.touches.length > 0) {
      cx = e.touches[0].clientX;
      cy = e.touches[0].clientY;
    } else if (e.changedTouches && e.changedTouches.length > 0) {
      cx = e.changedTouches[0].clientX;
      cy = e.changedTouches[0].clientY;
    }
    if (typeof cx !== 'number' || typeof cy !== 'number') {
      return null;
    }

    const rect = typeof container.getBoundingClientRect === 'function'
      ? container.getBoundingClientRect()
      : null;
    const left = rect ? rect.left : 0;
    const top = rect ? rect.top : 0;
    const width = rect && rect.width ? rect.width : (container.clientWidth || 800);
    const height = rect && rect.height ? rect.height : (container.clientHeight || 600);

    return {
      x: cx - left,
      y: cy - top,
      width,
      height
    };
  }

  function updateZone(relX, relY, width, height) {
    const newZone = detectHapticZone(relX, relY, width, height, activeZones);

    if (newZone !== currentZone) {
      const prevZone = currentZone;
      clearDwellTimer();
      dragged = false;

      if (prevZone) {
        if (container.classList && typeof container.classList.remove === 'function') {
          container.classList.remove(`rc-zone-active-${prevZone}`);
        }
        if (typeof onZoneLeave === 'function') {
          onZoneLeave(prevZone);
        }
      }

      currentZone = newZone;

      if (newZone) {
        if (container.classList && typeof container.classList.add === 'function') {
          container.classList.add(`rc-zone-active-${newZone}`);
        }
        postHaptic('snap', globalObj);
        if (typeof onZoneEnter === 'function') {
          onZoneEnter(newZone);
        }

        if (newZone === 'left' || newZone === 'right') {
          startX = relX;
          startY = relY;
          dragged = false;
          dwellTimer = setTimeout(() => {
            dwellTimer = null;
            if (!dragged && currentZone === newZone) {
              if (typeof onZoneDwell === 'function') {
                onZoneDwell(newZone);
              }
            }
          }, activeZones.dwellMs);
        }
      }
    } else if (currentZone === 'left' || currentZone === 'right') {
      const dist = Math.hypot(relX - startX, relY - startY);
      if (dist > 10) {
        dragged = true;
        clearDwellTimer();
      }
    }
  }

  function handlePointerMove(e) {
    const coords = getCoords(e);
    if (!coords) return;
    updateZone(coords.x, coords.y, coords.width, coords.height);
  }

  function handlePointerDown(e) {
    const coords = getCoords(e);
    if (!coords) return;
    startX = coords.x;
    startY = coords.y;
    dragged = false;
    updateZone(coords.x, coords.y, coords.width, coords.height);
  }

  function handleLeave() {
    clearDwellTimer();
    dragged = false;
    if (currentZone) {
      const prevZone = currentZone;
      currentZone = null;
      if (container.classList && typeof container.classList.remove === 'function') {
        container.classList.remove(`rc-zone-active-${prevZone}`);
      }
      if (typeof onZoneLeave === 'function') {
        onZoneLeave(prevZone);
      }
    }
  }

  container.addEventListener('pointermove', handlePointerMove);
  container.addEventListener('pointerdown', handlePointerDown);
  container.addEventListener('touchstart', handlePointerDown, { passive: true });
  container.addEventListener('touchmove', handlePointerMove, { passive: true });
  container.addEventListener('touchend', handleLeave);
  container.addEventListener('touchcancel', handleLeave);
  container.addEventListener('pointerleave', handleLeave);
  container.addEventListener('pointerup', handleLeave);

  function destroy() {
    clearDwellTimer();
    handleLeave();
    container.removeEventListener('pointermove', handlePointerMove);
    container.removeEventListener('pointerdown', handlePointerDown);
    container.removeEventListener('touchstart', handlePointerDown);
    container.removeEventListener('touchmove', handlePointerMove);
    container.removeEventListener('touchend', handleLeave);
    container.removeEventListener('touchcancel', handleLeave);
    container.removeEventListener('pointerleave', handleLeave);
    container.removeEventListener('pointerup', handleLeave);
  }

  destroy.destroy = destroy;
  return destroy;
}

/**
 * Normalizes spoken phrases (English & multilingual equivalents) and dispatches
 * the exact same moves as touch and Pencil.
 */
export function executeVoiceMove(commandStr, handlers = {}) {
  if (typeof commandStr !== 'string') {
    return { matched: false, action: null };
  }

  const raw = commandStr
    .trim()
    .toLowerCase()
    .replace(/[.,!?;:'"()[\]{}]/g, '')
    .replace(/\s+/g, ' ');

  if (!raw) {
    return { matched: false, action: null };
  }

  // 1. Swipe Left-to-Right (New topic/window/page on left)
  const leftToRightPhrases = [
    'new topic',
    'new window',
    'new page',
    'swipe right',
    'left',
    'nouveau',
    'nouvelle page',
    'nouveau sujet',
    'mới',
    'trang mới',
    'chủ đề mới'
  ];
  if (leftToRightPhrases.includes(raw)) {
    if (typeof handlers.swipeLeftToRight === 'function') {
      handlers.swipeLeftToRight();
    }
    return { matched: true, action: 'swipeLeftToRight' };
  }

  // 2. Swipe Right-to-Left (Next / older topic to right)
  const rightToLeftPhrases = [
    'next topic',
    'next window',
    'next page',
    'older',
    'older page',
    'swipe left',
    'right',
    'suivant',
    'suivante',
    'page suivante',
    'tiếp',
    'trang tiếp',
    'tiếp tục'
  ];
  if (rightToLeftPhrases.includes(raw)) {
    if (typeof handlers.swipeRightToLeft === 'function') {
      handlers.swipeRightToLeft();
    }
    return { matched: true, action: 'swipeRightToLeft' };
  }

  // 3. Delete empty window
  const deletePhrases = [
    'delete',
    'delete window',
    'delete page',
    'remove empty',
    'supprimer',
    'supprimer la page',
    'xóa',
    'xóa trang',
    'xóa cửa sổ'
  ];
  if (deletePhrases.includes(raw)) {
    if (typeof handlers.deleteEmptyWindow === 'function') {
      handlers.deleteEmptyWindow();
    }
    return { matched: true, action: 'deleteEmptyWindow' };
  }

  // 4. Outline toggle
  const outlinePhrases = [
    'outline',
    'topics',
    'mục lục',
    'sommaire'
  ];
  if (outlinePhrases.includes(raw)) {
    if (typeof handlers.toggleOutline === 'function') {
      handlers.toggleOutline();
    }
    return { matched: true, action: 'toggleOutline' };
  }

  // 5. Find / Search
  const findPhrases = [
    'find',
    'search',
    'tìm',
    'tìm kiếm',
    'rechercher'
  ];
  if (findPhrases.includes(raw)) {
    if (typeof handlers.openFind === 'function') {
      handlers.openFind();
    }
    return { matched: true, action: 'openFind' };
  }

  // 6. Ink tools
  const inkToolMap = {
    'pen': 'pen',
    'bút': 'pen',
    'stylo': 'pen',
    'highlighter': 'highlighter',
    'bút dạ': 'highlighter',
    'surligneur': 'highlighter',
    'underline': 'underline',
    'gạch chân': 'underline',
    'souligner': 'underline',
    'circle': 'circle',
    'khoanh tròn': 'circle',
    'entourer': 'circle',
    'eraser': 'eraser',
    'tẩy': 'eraser',
    'gôm': 'eraser',
    'gomme': 'eraser',
    'whole eraser': 'whole eraser',
    'tẩy toàn bộ': 'whole eraser',
    'gomme entière': 'whole eraser',
    'partial eraser': 'partial eraser',
    'tẩy một phần': 'partial eraser',
    'gomme partielle': 'partial eraser'
  };
  if (inkToolMap[raw]) {
    const toolName = inkToolMap[raw];
    if (typeof handlers.setInkTool === 'function') {
      handlers.setInkTool(toolName);
    }
    return { matched: true, action: 'setInkTool', tool: toolName };
  }

  // 7. Audio summary
  const summaryPhrases = [
    'summarize',
    'summary',
    'audio summary',
    'tóm tắt',
    'tóm tắt âm thanh',
    'résumer',
    'résumé'
  ];
  if (summaryPhrases.includes(raw)) {
    if (typeof handlers.summarizeSection === 'function') {
      handlers.summarizeSection();
    }
    return { matched: true, action: 'summarizeSection' };
  }

  // 8. Bookmark audio
  const bookmarkPhrases = [
    'bookmark',
    'annotate',
    'đánh dấu',
    'chú thích',
    'signet',
    'annoter'
  ];
  if (bookmarkPhrases.includes(raw)) {
    if (typeof handlers.bookmarkAudio === 'function') {
      handlers.bookmarkAudio();
    }
    return { matched: true, action: 'bookmarkAudio' };
  }

  return { matched: false, action: null };
}
