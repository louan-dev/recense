import css from "../client/upload.css";
import js from "../client/upload.js";

// GET /   the owner's page for making a new public link from files on this device.
export function uploadPage() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#1c1c1e">
<meta name="color-scheme" content="dark">
<meta name="robots" content="noindex">
<title>Gallery</title>
<style>${css}</style>
</head>

<body>

<main>

  <h1>New link</h1>

  <p id="signin" hidden><a href="/main">Sign in</a> to make a link.</p>

  <div class="f">Link lasts</div>

  <div class="seg" role="radiogroup">
    <label><input type="radio" name="d" value="1"><span>1 day</span></label>
    <label><input type="radio" name="d" value="7" checked><span>7 days</span></label>
    <label><input type="radio" name="d" value="30"><span>30 days</span></label>
  </div>

  <label id="drop" for="input">Choose files, or drop them here</label>
  <input id="input" type="file" multiple hidden>

  <div id="list"></div>

  <button id="go" class="btn" disabled>Create link</button>

  <p id="msg" role="status"></p>
  <p id="result"></p>

</main>

<script>
${js}
</script>

</body>
</html>`;
}

// ---------- upload CSS ----------

