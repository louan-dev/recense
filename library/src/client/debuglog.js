// Derived from Spec: PLAN-1118 §11b · the debug channel, JS twin of shared/ShowsKit/Sources/ShowsKit/DebugChannel.swift.
//
// RecenseDebugLog.event(feature, event, fields)   one line: {"t":ISO,"feature","event","fields":{sorted string values}}
// RecenseDebugLog.line(feature, event, fields, atMs) → the line, or null when refused (same rule and bytes as Swift)
// RecenseDebugLog.setSink(fn)   fn(feature, line) appends it to ~/Recense/logs/<feature>.jsonl; the host app provides it
//                               (Mac: the localhost server; iOS: a WKScriptMessageHandler). With none, lines wait in a ring of 200.
// RecenseDebugLog.dump(feature) → the waiting lines. Never throws, never blocks, never leaves the device by itself.
// Log ids, counts, states and error text, never what the person wrote or said.
const RecenseDebugLog = (() => {
  const RING = 200;
  const ring = [];
  let sink = null;

  const line = (feature, event, fields, atMs) => {
    fields = fields || {};
    if (!/^[a-z][a-z0-9-]*$/.test(feature) || !String(event).startsWith(feature + ".") || !/^[a-z][a-z0-9._-]*$/.test(event)) return null;
    const keys = Object.keys(fields).sort();
    if (!keys.every((k) => /^[a-z][A-Za-z0-9_]*$/.test(k))) return null;
    const t = new Date(atMs === undefined ? Date.now() : atMs).toISOString();
    const body = keys.map((k) => JSON.stringify(k) + ":" + JSON.stringify(String(fields[k]))).join(",");
    return '{"t":' + JSON.stringify(t) + ',"feature":' + JSON.stringify(feature) + ',"event":' + JSON.stringify(event) + ',"fields":{' + body + "}}";
  };

  const event = (feature, name, fields) => {
    try {
      const l = line(feature, name, fields);
      if (l === null) return;
      if (sink) { sink(feature, l); return; }
      ring.push([feature, l]);
      if (ring.length > RING) ring.shift();
    } catch (_) { /* a diagnostic is never worth a failure */ }
  };

  const setSink = (fn) => {
    sink = fn || null;
    if (sink) { while (ring.length) { const [f, l] = ring.shift(); try { sink(f, l); } catch (_) {} } }
  };

  const dump = (feature) => ring.filter(([f]) => !feature || f === feature).map(([, l]) => l);

  return { line, event, setSink, dump };
})();
