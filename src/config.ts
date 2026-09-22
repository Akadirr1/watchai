function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    // Fail closed. A quota dashboard that starts without auth is a quota dashboard that
    // gets indexed. There is no "open mode" and no generated-token fallback.
    console.error(`FATAL: ${name} is not set. Generate one with: openssl rand -hex 32`);
    process.exit(1);
  }
  return value;
}

const authToken = required("AUTH_TOKEN");
if (authToken.length < 32) {
  console.error("FATAL: AUTH_TOKEN must be at least 32 characters.");
  process.exit(1);
}

export const config = {
  port: Number(process.env["PORT"] ?? 3000),
  host: process.env["HOST"] ?? "0.0.0.0",
  authToken,
  dataDir: process.env["DATA_DIR"] ?? "/data",
  claudeConfigDir: process.env["CLAUDE_CONFIG_DIR"] ?? "/data/claude",
  codexHome: process.env["CODEX_HOME"] ?? "/data/codex",
  pollIntervalSec: Number(process.env["POLL_INTERVAL_SEC"] ?? 60),
  /** Codex fires half an interval after Claude so the two never coincide, forever. */
  codexStaggerSec: Number(process.env["CODEX_STAGGER_SEC"] ?? 30),
} as const;

export const credentialDirs = {
  claude: config.claudeConfigDir,
  codex: config.codexHome,
} as const;
