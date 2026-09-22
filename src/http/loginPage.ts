import { BASE_STYLE } from "./pageStyle.js";

/**
 * The sign-in screen.
 *
 * `/setup` had exactly one way in: know to append `?t=<AUTH_TOKEN>` by hand. Anyone who
 * simply opened the site got `{"error":"unauthorized"}` and no way forward — correct
 * behaviour, unusable product.
 *
 * The security property is unchanged: this page is served on the same 401 as before, the
 * failure limiter still counts every attempt, and nothing here distinguishes an absent
 * token from a wrong one.
 *
 * `next` is where to go after signing in. It matters most for pairing — a phone that
 * scans the watch's QR lands on `/pair?c=CODE` without a session, and before this that
 * was a dead end. It is validated server-side to a same-site path; the escaping here is
 * the second layer, not the first.
 */
export function LOGIN_PAGE(next: string, reason: "unauthorized" | "too_many_attempts"): string {
  const message =
    reason === "too_many_attempts"
      ? "Too many attempts. Wait a minute and try again."
      : "";
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>QuotaPets sign in</title>
<style>${BASE_STYLE}
  p.hint { color:var(--muted); font-size:12px; margin:14px 0 0 }
  code { font:12px ui-monospace,monospace }
</style></head><body data-next="${escapeAttribute(next)}"><main>
<h1>QuotaPets</h1>
<p class="sub">Sign in to manage this server.</p>
<section>
  <form id="f">
    <input id="t" type="password" autocomplete="current-password" spellcheck="false"
           placeholder="AUTH_TOKEN" autofocus>
    <p><button type="submit" id="b">Sign in</button></p>
  </form>
  <div class="err" id="e">${escapeText(message)}</div>
  <p class="hint">This is the <code>AUTH_TOKEN</code> the server was started with. It is kept
  in a cookie on this device and goes nowhere else. Your watch never uses it &mdash; it gets
  its own device token by scanning a QR.</p>
</section>
<script>
const next = document.body.dataset.next || "/setup";
const err = document.getElementById("e");
document.getElementById("f").onsubmit = async (ev) => {
  ev.preventDefault();
  const btn = document.getElementById("b");
  btn.disabled = true; err.textContent = "";
  try {
    const r = await fetch("/api/session", {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: document.getElementById("t").value }),
    });
    if (r.ok) { location.href = next; return; }
    err.textContent = r.status === 429
      ? "Too many attempts. Wait a minute and try again."
      : "That token was not accepted.";
  } catch {
    err.textContent = "Could not reach the server.";
  }
  btn.disabled = false;
};
</script>
</main></body></html>`;
}

function escapeAttribute(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function escapeText(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
