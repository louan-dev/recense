// Relays content-script reports to the Recense Mac app on localhost.
const APP = "http://127.0.0.1:47123";

async function post(path, body, contentType = "application/json") {
  const res = await fetch(APP + path, { method: "POST", headers: { "Content-Type": contentType }, body });
  return res.json();
}

browser.runtime.onMessage.addListener(async (msg) => {
  try {
    if (msg.cmd === "app") return await post(msg.path, JSON.stringify(msg.body));
    if (msg.cmd === "bytes") {
      const q = `?url=${encodeURIComponent(msg.url)}&type=${encodeURIComponent(msg.type || "")}`;
      return await post("/bytes" + q, msg.buffer, "application/octet-stream");
    }
  } catch (e) {
    return null;   // app not running
  }
});

// Ticks for the pages: their own timers are throttled in background tabs, these aren't.
const ports = new Set();
browser.runtime.onConnect.addListener((p) => {
  if (p.name !== "tick") return;
  ports.add(p);
  p.onDisconnect.addListener(() => ports.delete(p));
});
setInterval(() => { for (const p of ports) p.postMessage(0); }, 50);
