/**
 * The base stylesheet shared by the pages a person actually looks at (`/setup` and the
 * sign-in screen). Kept in one place so a second page cannot quietly grow a second design
 * language; page-specific rules stay with their page.
 */
export const BASE_STYLE = `
  :root { color-scheme: light dark; --fg:#14171c; --muted:#667085; --edge:#dde1e7; --bg:#f4f5f7; --card:#fff; }
  @media (prefers-color-scheme: dark) { :root { --fg:#e9ebee; --muted:#8b94a3; --edge:#262a31; --bg:#0d0f12; --card:#16191e; } }
  * { box-sizing:border-box }
  body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 ui-sans-serif,system-ui,sans-serif; }
  main { max-width:560px; margin:0 auto; padding:32px 20px 64px }
  h1 { font-size:24px; margin:0 0 4px }
  p.sub { color:var(--muted); margin:0 0 24px }
  section { background:var(--card); border:1px solid var(--edge); border-radius:12px; padding:18px; margin-bottom:16px }
  h2 { font-size:16px; margin:0 0 4px }
  button { font:inherit; padding:8px 14px; border-radius:8px; border:1px solid var(--edge);
           background:var(--fg); color:var(--bg); cursor:pointer }
  button.secondary { background:transparent; color:var(--fg) }
  button:disabled { opacity:.5; cursor:default }
  input { width:100%; font:13px ui-monospace,monospace; padding:9px 10px; border-radius:8px;
          border:1px solid var(--edge); background:var(--bg); color:var(--fg) }
  a { color:inherit }
  .err { color:#c4692f; font-size:13px; margin-top:8px }
`;
