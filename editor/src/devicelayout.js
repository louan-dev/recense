// Derived from Spec: UI-07 · the editor box per device and orientation, not the Mac's box scaled.
// Pure: (viewport width, height in CSS px, touch?) → the box, or null to keep the Mac's box.

const ROWS = {
  phone:  { portrait: [18, 44, 16, 20, 96],  landscape: [18, 52, 24, 8, 48] },  // iPhone 12 Pro Max 428×926
  pad11:  { portrait: [20, 58, 32, 32, 120], landscape: [20, 62, 48, 24, 96] }, // fallback band: 11-inch iPads, split view
  pad13:  { portrait: [21, 60, 40, 36, 120], landscape: [21, 64, 56, 28, 96] }  // iPad Air M2 13-inch 1024×1366 (owner's iPad)
};

export function deviceClass(width, height) {
  const short = Math.min(width, height);
  return short < 500 ? 'phone' : short < 900 ? 'pad11' : 'pad13';
}

export function deviceLayout(width, height, touch) {
  if (!touch || !(width > 0) || !(height > 0)) return null;
  const device = deviceClass(width, height);
  const orientation = width > height ? 'landscape' : 'portrait';
  const [fontSize, columnCh, padX, padTop, padBottom] = ROWS[device][orientation];
  return { device, orientation, fontSize, columnCh, padX, padTop, padBottom };
}

// The CSS variables theme.js reads for .cm-content; null clears them back to the Mac's box.
export function layoutVars(layout) {
  if (!layout) return { '--rc-col': null, '--rc-pad-x': null, '--rc-pad-top': null, '--rc-pad-bottom': null };
  return {
    '--rc-col': `${layout.columnCh}ch`,
    '--rc-pad-x': `max(${layout.padX}px, env(safe-area-inset-left), env(safe-area-inset-right))`,
    '--rc-pad-top': `${layout.padTop}px`,
    '--rc-pad-bottom': `max(${layout.padBottom}px, env(safe-area-inset-bottom))`
  };
}
