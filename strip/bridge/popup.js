const s = document.getElementById("s");
fetch("http://127.0.0.1:47123/ping", { method: "POST", body: "{}" })
  .then(() => (s.textContent = "Mac app connected."))
  .catch(() => (s.textContent = "Mac app not running — open Recense.app."));
document.getElementById("t").onclick = async () => {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  try {
    const r = await browser.tabs.sendMessage(tab.id, { cmd: "toggle" });
    s.textContent = r.running ? "Sending this tab to the overlay." : "Paused for this tab.";
  } catch (e) { s.textContent = "Reload the page, then retry."; }
};
