// Read-aloud with the word being spoken reported back, for the Recensed view and playlists.
// In the apps the host speaks (shared/readaloud.swift: the best installed voice for each part's language, on device)
// and calls window.speechProgress(id, part, from, length) / window.speechDone(id). In a plain browser the Web Speech
// API stands in. Nothing leaves the device either way.

let seq = 0;
const live = new Map();   // id → { onWord, onDone }

export function createSpeaker(globalObj = typeof window !== 'undefined' ? window : null) {
  const host = () => globalObj?.webkit?.messageHandlers?.ui;
  let current = null;

  if (globalObj && !globalObj.__rcSpeechHooks) {
    globalObj.__rcSpeechHooks = true;
    globalObj.speechProgress = (id, part, from, len) => live.get(id)?.onWord?.(part, from, len);
    globalObj.speechDone = id => { const h = live.get(id); live.delete(id); h?.onDone?.(); };
  }

  /** Speaks `parts` in order; onWord(partIndex, from, length) as each word starts; onDone() at the end or on stop. */
  function speak(parts, { onWord, onDone, lang } = {}) {
    stop();
    const id = `say-${++seq}`;
    current = id;
    live.set(id, { onWord, onDone });
    const h = host();
    if (h && typeof h.postMessage === 'function') {
      h.postMessage({ speakParts: { id, parts, lang: lang || null } });
      return id;
    }
    const synth = globalObj?.speechSynthesis;
    const Utter = globalObj?.SpeechSynthesisUtterance;
    if (!synth || !Utter) { setTimeout(() => globalObj?.speechDone?.(id), 0); return id; }
    let k = 0;
    const next = () => {
      if (current !== id) return;
      if (k >= parts.length) { globalObj.speechDone(id); return; }
      const i = k++;
      const u = new Utter(parts[i]);
      if (lang) u.lang = lang;
      u.onboundary = e => { if (e.name === 'word' || e.name === undefined) globalObj.speechProgress(id, i, e.charIndex, e.charLength || 0); };
      u.onend = next;
      u.onerror = next;
      synth.speak(u);
    };
    next();
    return id;
  }

  function stop() {
    if (!current) return;
    const id = current;
    current = null;
    const h = host();
    if (h && typeof h.postMessage === 'function') h.postMessage({ speakStop: true });
    else globalObj?.speechSynthesis?.cancel?.();
    const handlers = live.get(id);
    live.delete(id);
    handlers?.onDone?.();
  }

  return { speak, stop, isSpeaking: () => current !== null };
}
