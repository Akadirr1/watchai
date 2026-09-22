/** The page the phone lands on after its camera scans the watch's QR. */
export function PAIR_RESULT_PAGE(ok: boolean, message: string): string {
  const title = ok ? "Watch paired" : "Pairing failed";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>
  :root { color-scheme: light dark }
  body { margin:0; min-height:100vh; display:grid; place-items:center;
         font:16px/1.5 ui-sans-serif,system-ui,sans-serif; background:#f4f5f7; color:#14171c }
  @media (prefers-color-scheme: dark) { body { background:#0d0f12; color:#e9ebee } }
  .card { text-align:center; padding:32px 24px; max-width:360px }
  .mark { font-size:44px; line-height:1 }
  h1 { font-size:20px; margin:14px 0 6px }
  p { margin:0; opacity:.7 }
  a { display:inline-block; margin-top:22px; color:inherit }
</style></head><body><div class="card">
<div class="mark">${ok ? "✓" : "✕"}</div>
<h1>${title}</h1>
<p>${message}</p>
<a href="/setup">Back to setup</a>
</div></body></html>`;
}
