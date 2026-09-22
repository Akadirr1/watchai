/**
 * The only HTML this server serves, and only for first-time setup.
 *
 * The usage surface is deliberately JSON-only — the watch does the drawing. This page
 * exists purely so connecting an account never requires a terminal.
 */
export const SETUP_PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>QuotaPets setup</title>
<style>
  :root { color-scheme: light dark; --fg:#14171c; --muted:#667085; --edge:#dde1e7; --bg:#f4f5f7; --card:#fff; }
  @media (prefers-color-scheme: dark) { :root { --fg:#e9ebee; --muted:#8b94a3; --edge:#262a31; --bg:#0d0f12; --card:#16191e; } }
  * { box-sizing:border-box }
  body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 ui-sans-serif,system-ui,sans-serif; }
  main { max-width:560px; margin:0 auto; padding:32px 20px 64px }
  h1 { font-size:24px; margin:0 0 4px }
  p.sub { color:var(--muted); margin:0 0 24px }
  section { background:var(--card); border:1px solid var(--edge); border-radius:12px; padding:18px; margin-bottom:16px }
  h2 { font-size:16px; margin:0 0 4px }
  .state { font:12px ui-monospace,monospace; color:var(--muted); margin-bottom:12px }
  button { font:inherit; padding:8px 14px; border-radius:8px; border:1px solid var(--edge);
           background:var(--fg); color:var(--bg); cursor:pointer }
  button.secondary { background:transparent; color:var(--fg) }
  button:disabled { opacity:.5; cursor:default }
  a { color:inherit }
  .step { margin-top:14px; padding-top:14px; border-top:1px solid var(--edge); display:none }
  .step.on { display:block }
  code.url { display:block; word-break:break-all; font:12px ui-monospace,monospace;
             background:var(--bg); border:1px solid var(--edge); border-radius:8px; padding:10px; margin:8px 0 }
  .code { font:600 22px ui-monospace,monospace; letter-spacing:.12em; margin:8px 0 }
  input { width:100%; font:13px ui-monospace,monospace; padding:9px 10px; border-radius:8px;
          border:1px solid var(--edge); background:var(--bg); color:var(--fg) }
  .err { color:#c4692f; font-size:13px; margin-top:8px }
  .row { display:flex; align-items:center; justify-content:space-between; gap:10px;
         padding:8px 0; border-bottom:1px solid var(--edge) }
  .row:last-child { border-bottom:0 }
  .row span { font:12px ui-monospace,monospace; color:var(--muted) }
</style></head><body><main>
<h1>QuotaPets</h1>
<p class="sub">Connect your accounts. Sign-in runs the real Claude and Codex CLIs inside this
container &mdash; QuotaPets never sees your password and never runs prompts.</p>
<div id="providers"></div>

<section>
  <h2>Paired watches</h2>
  <div class="state">Open the app on your watch, point your iPhone camera at the QR it shows,
  and tap the notification &mdash; you are already signed in here, so that finishes the pairing.
  If the camera will not read it, type the eight characters shown under the QR instead.</div>
  <div id="device-list" class="state">loading&hellip;</div>
  <p><input id="pair-code" placeholder="WATCH CODE" maxlength="8" autocapitalize="characters"
     autocorrect="off" autocomplete="off" spellcheck="false"></p>
  <p><button class="secondary" id="pair-go">Pair this code</button></p>
  <div class="err" id="pair-err"></div>
</section>

<script>
const PROVIDERS = [["claude","Claude"],["codex","Codex"]];
const root = document.getElementById("providers");

function render(p, label) {
  const el = document.createElement("section");
  el.innerHTML = \`<h2>\${label}</h2><div class="state" id="s-\${p}">checking…</div>
    <button id="b-\${p}">Connect</button>
    <div class="step" id="step-\${p}">
      <p>1. Open this link and sign in:</p><code class="url" id="u-\${p}"></code>
      <div id="dc-\${p}"></div>
      <div id="paste-\${p}"></div>
      <div class="err" id="e-\${p}"></div>
    </div>\`;
  root.appendChild(el);
  document.getElementById("b-"+p).onclick = () => start(p);
}

async function api(path, opts) {
  const r = await fetch(path, { credentials: "same-origin", ...opts });
  if (!r.ok) throw new Error("request failed: " + r.status);
  return r.json();
}

async function start(p) {
  const btn = document.getElementById("b-"+p);
  btn.disabled = true; btn.textContent = "Starting…";
  try {
    await api("/api/login/"+p+"/start", { method:"POST" });
    document.getElementById("step-"+p).classList.add("on");
    poll(p);
  } catch (e) { document.getElementById("e-"+p).textContent = e.message; btn.disabled = false; }
}

async function poll(p) {
  let s;
  try { s = await api("/api/login/"+p+"/status"); } catch { return; }
  document.getElementById("s-"+p).textContent = s.phase + (s.error ? " — " + s.error : "");
  if (s.url) document.getElementById("u-"+p).textContent = s.url;
  if (s.userCode) document.getElementById("dc-"+p).innerHTML =
    "<p>2. Enter this code:</p><div class=\\"code\\">" + s.userCode + "</div>";
  if (s.needsCodePaste && s.url && !document.getElementById("i-"+p)) {
    document.getElementById("paste-"+p).innerHTML =
      "<p>2. Paste the code shown after sign-in:</p><input id=\\"i-"+p+"\\" placeholder=\\"code#state\\">" +
      "<p><button class=\\"secondary\\" id=\\"sb-"+p+"\\">Submit</button></p>";
    document.getElementById("sb-"+p).onclick = async () => {
      const v = document.getElementById("i-"+p).value;
      try { await api("/api/login/"+p+"/complete", {
        method:"POST", headers:{"content-type":"application/json"}, body: JSON.stringify({ code: v }) });
      } catch (e) { document.getElementById("e-"+p).textContent = e.message; }
    };
  }
  if (s.phase === "waiting") return void setTimeout(() => poll(p), 2000);
  const btn = document.getElementById("b-"+p);
  btn.disabled = false;
  btn.textContent = s.phase === "completed" ? "Reconnect" : "Try again";
  if (s.phase === "completed") document.getElementById("step-"+p).classList.remove("on");
  refreshStates();
}

async function refreshStates() {
  try {
    const h = await api("/api/heartbeat");
    for (const [p] of PROVIDERS) {
      const st = h.providers[p];
      const el = document.getElementById("s-"+p);
      if (el && st) el.textContent = st.state + (st.lastError ? " — " + st.lastError.hint : "");
    }
  } catch {}
}

// --- Paired watches ---------------------------------------------------------
// Revoking here is what makes a lost watch a small problem: each watch holds its own
// device token, so removing one never means rotating AUTH_TOKEN.

const deviceList = document.getElementById("device-list");

function ago(ms) {
  if (ms === null || ms === undefined) return "never";
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.round(s / 60) + "m ago";
  if (s < 86400) return Math.round(s / 3600) + "h ago";
  return Math.round(s / 86400) + "d ago";
}

async function refreshDevices() {
  let d;
  try { d = await api("/api/devices"); } catch { return; }
  if (!d.devices.length) { deviceList.textContent = "No watch paired yet."; return; }
  deviceList.textContent = "";
  for (const dev of d.devices) {
    const row = document.createElement("div");
    row.className = "row";
    const label = document.createElement("span");
    // textContent, not innerHTML: these values come off disk and are never markup.
    label.textContent = dev.id.slice(0, 8) + " \u00b7 paired " + ago(dev.createdAt) +
                        " \u00b7 seen " + ago(dev.lastSeenAt);
    const btn = document.createElement("button");
    btn.className = "secondary";
    btn.textContent = "Revoke";
    btn.onclick = async () => {
      btn.disabled = true;
      try { await api("/api/devices/" + encodeURIComponent(dev.id), { method: "DELETE" }); }
      catch {}
      refreshDevices();
    };
    row.append(label, btn);
    deviceList.appendChild(row);
  }
}

document.getElementById("pair-go").onclick = () => {
  const err = document.getElementById("pair-err");
  const c = document.getElementById("pair-code").value.trim().toUpperCase();
  // Same alphabet the server mints from — no 0/O or 1/I/l, which is the point of
  // offering a typed fallback at all.
  if (!/^[A-Z2-9]{8}$/.test(c)) { err.textContent = "That is not an eight-character watch code."; return; }
  err.textContent = "";
  location.href = "/pair?c=" + encodeURIComponent(c);
};

for (const [p, label] of PROVIDERS) render(p, label);
refreshStates();
refreshDevices();
setInterval(refreshStates, 15000);
setInterval(refreshDevices, 15000);
</script></main></body></html>`;
