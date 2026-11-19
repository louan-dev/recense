// Derived from Spec: FEAT-23 (Debug channel) · FEAT-08 (Debug channel)
// One small door for the specs' debug events: the page posts { event, ...fields, at } to its host's `debug` handler,
// and the host writes the line (ShowsKit DebugChannel, Stream B's skills branch). With no handler it does nothing:
// no second JSONL writer lives here. Fields are ids, counts, states, times and error text, never what was written.

export function logEvent(name, fields = {}, globalObj = typeof window !== 'undefined' ? window : null) {
  const h = globalObj && globalObj.webkit && globalObj.webkit.messageHandlers && globalObj.webkit.messageHandlers.debug;
  if (!h || typeof h.postMessage !== 'function') return false;
  try {
    h.postMessage({ event: String(name), ...fields, at: Date.now() });
    return true;
  } catch {
    return false;
  }
}
