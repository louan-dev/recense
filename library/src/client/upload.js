
(() => {
  const $ = (id) => document.getElementById(id);

  const drop = $("drop");
  const input = $("input");
  const list = $("list");
  const go = $("go");
  const msg = $("msg");
  const result = $("result");
  const signin = $("signin");

  let files = [];

  // Only the owner can make links. Signing in to Main signs in here too.
  fetch("/main/api/whoami", { redirect: "manual", cache: "no-store" })
    .then((r) => {
      signin.hidden = r.ok;
      drop.hidden = !r.ok;
    })
    .catch(() => (signin.hidden = false));

  const sz = (b) =>
    b < 1048576
      ? Math.max(1, Math.round(b / 1024)) + " KB"
      : (b / 1048576).toFixed(1) + " MB";

  function render() {
    list.replaceChildren(
      ...files.map((f, i) => {
        const row = document.createElement("div");
        row.className = "row";

        const t = document.createElement("span");
        t.textContent = f.name + " (" + sz(f.size) + ")";

        const x = document.createElement("button");
        x.textContent = "×";
        x.setAttribute("aria-label", "Remove " + f.name);

        x.onclick = () => {
          files.splice(i, 1);
          render();
        };

        row.append(t, x);
        return row;
      })
    );

    go.disabled = !files.length;
  }

  const add = (fl) => {
    files = files.concat(Array.from(fl));
    render();
  };

  input.addEventListener("change", () => {
    add(input.files);
    input.value = "";
  });

  ["dragenter", "dragover"].forEach((ev) => {
    drop.addEventListener(ev, (e) => {
      e.preventDefault();
      drop.classList.add("on");
    });
  });

  ["dragleave", "drop"].forEach((ev) => {
    drop.addEventListener(ev, (e) => {
      e.preventDefault();
      drop.classList.remove("on");

      if (ev === "drop" && e.dataTransfer) add(e.dataTransfer.files);
    });
  });

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // Cloudflare rejects any single request body over 100 MB on the Free and Pro
  // plans, so anything over ~90 MB goes up in 32 MiB parts.
  const BIG = 90e6;
  const PART = 32 * 1024 * 1024;

  const failed = (r, what) =>
    new Error(r.status === 404 || r.type === "opaqueredirect" ? "Sign in first" : what + " (" + r.status + ")");

  // The gallery exists the moment this returns, before any file is uploaded.
  const registerLink = async (days, selected) => {
    const body = selected
      .map((f) =>
        [
          f.size,
          f.lastModified || Date.now(),
          encodeURIComponent(f.type || "application/octet-stream"),
          encodeURIComponent(f.name),
        ].join("\t")
      )
      .join("\n");

    const r = await fetch("/main/api/link?" + new URLSearchParams({ action: "start", days }), {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body,
      redirect: "manual",
    });

    if (!r.ok) throw failed(r, "Could not create the link");

    return (await r.json()).id;
  };

  const cancelLink = (id) =>
    fetch("/main/api/link?" + new URLSearchParams({ action: "cancel", id }), {
      method: "POST",
    }).catch(() => {});

  const bigUpload = async (f, id, i, days, taken, label) => {
    const total = Math.ceil(f.size / PART);

    const start = new URLSearchParams({
      action: "start",
      id,
      i: String(i),
      name: f.name,
      days,
      t: String(taken),
      hasArt: "0",
      total: String(total),
      type: f.type || "application/octet-stream",
    });

    let r = await fetch("/main/api/upload?" + start, { method: "POST", redirect: "manual" });

    if (!r.ok) throw failed(r, "Upload failed");

    const uploadId = (await r.text()).trim();
    const parts = [];

    const call = (action, extra, init) =>
      fetch(
        "/main/api/upload?" +
          new URLSearchParams(
            Object.assign({ action, id, i: String(i), uploadId, total: String(total) }, extra)
          ),
        init
      );

    try {
      for (let n = 1; n <= total; n++) {
        msg.textContent = label + ", part " + n + " of " + total + "...";

        const chunk = f.slice((n - 1) * PART, n * PART);
        let etag = null;

        for (let tries = 1; tries <= 4 && etag === null; tries++) {
          try {
            const pr = await call("part", { part: String(n) }, { method: "PUT", body: chunk });

            if (pr.ok) etag = (await pr.text()).trim();
          } catch (e) {}

          if (etag === null) await sleep(1500 * tries);
        }

        if (etag === null) throw new Error("Upload failed at part " + n + " of " + total);

        parts.push({ partNumber: n, etag });
      }

      r = await call(
        "complete",
        {},
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(parts),
        }
      );

      if (!r.ok) throw new Error("Upload failed (" + r.status + ")");
    } catch (e) {
      call("abort", {}, { method: "POST" }).catch(() => {});
      throw e;
    }
  };

  go.onclick = async () => {
    go.disabled = true;
    result.replaceChildren();

    const selected = files.slice();
    const days = document.querySelector('input[name="d"]:checked').value;

    let galleryWindow = null;
    let id = null;

    // Open the viewer straight from the click so popup blockers allow it.
    try {
      galleryWindow = window.open("about:blank", "_blank");
    } catch (e) {
      galleryWindow = null;
    }

    try {
      msg.textContent = "Preparing live gallery...";

      id = await registerLink(days, selected);

      const link = location.origin + "/s/" + id;
      const a = document.createElement("a");

      a.href = link;
      a.textContent = link;
      result.replaceChildren(a);

      try {
        await navigator.clipboard.writeText(link);
      } catch (e) {}

      if (galleryWindow && !galleryWindow.closed) galleryWindow.location = link;

      msg.textContent = "Link ready. Uploading...";

      // Smallest first: a photo is viewable at once while a big video is still going up.
      const order = selected.map((f, i) => i).sort((a, b) => selected[a].size - selected[b].size);

      for (let k = 0; k < order.length; k++) {
        const i = order[k];
        const f = selected[i];
        const taken = f.lastModified || Date.now();
        const label = "Uploading " + f.name + " (" + (k + 1) + " of " + selected.length + ")";

        msg.textContent = label + "...";

        if (f.size > BIG) {
          await bigUpload(f, id, i, days, taken, label);
        } else {
          const q = new URLSearchParams({
            id,
            i: String(i),
            name: f.name,
            days,
            t: String(taken),
            hasArt: "0",
          });

          const r = await fetch("/main/api/upload?" + q, {
            method: "PUT",
            headers: { "content-type": f.type || "application/octet-stream" },
            body: f,
            redirect: "manual",
          });

          if (!r.ok) throw failed(r, "Upload failed");
        }
      }

      msg.textContent = "All uploads complete";
    } catch (e) {
      msg.textContent = e.message;
      go.disabled = false;

      if (id) cancelLink(id);
      else if (galleryWindow && !galleryWindow.closed) galleryWindow.close();

      return;
    }

    files = [];
    render();
  };
})();