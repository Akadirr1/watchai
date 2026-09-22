import { describe, expect, it } from "vitest";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LoginManager } from "../src/login/manager.js";

/**
 * How QuotaPets talks to the two vendor CLIs.
 *
 * Both rules below were found the hard way, in production, against the real binaries —
 * and both failed silently in a way that looked like "not signed in yet":
 *
 *   claude: `When using --print, --output-format=stream-json requires --verbose`, exit 1
 *   codex:  `{"error":{"code":-32600,"message":"Not initialized"}}`, and then nothing
 *
 * These are undocumented, unversioned interfaces. A test that pins the invocation is the
 * only thing that turns the next such change into a red build instead of a silent one.
 */

/** A stand-in CLI that records its argv and everything written to its stdin. */
async function recordingCLI(): Promise<{ command: string; transcript: () => Promise<string[]> }> {
  const dir = await mkdtemp(join(tmpdir(), "qp-cli-"));
  const command = join(dir, "fake-cli.cjs");
  await writeFile(
    command,
    `#!/usr/bin/env node
const fs = require("node:fs");
const log = __filename + ".log";
fs.writeFileSync(log, JSON.stringify(process.argv.slice(2)) + "\\n");
process.stdin.on("data", (chunk) => fs.appendFileSync(log, chunk));
// Stay alive so the parent sees a running child rather than an early exit.
setTimeout(() => process.exit(0), 5000);
`,
    { mode: 0o755 },
  );
  return {
    command,
    transcript: async () =>
      (await readFile(`${command}.log`, "utf8")).split("\n").filter((line) => line !== ""),
  };
}

async function runLogin(provider: "claude" | "codex"): Promise<string[]> {
  const { command, transcript } = await recordingCLI();
  const dir = await mkdtemp(join(tmpdir(), "qp-login-"));
  const logins = new LoginManager({ claude: dir, codex: dir }, () => command);
  await logins.start(provider);
  await new Promise((resolve) => setTimeout(resolve, 400));
  logins.cancel(provider);
  return transcript();
}

describe("the Claude invocation", () => {
  it("passes --verbose, which the CLI refuses to start without", async () => {
    const [argv] = await runLogin("claude");
    expect(JSON.parse(argv!)).toEqual([
      "-p",
      "--verbose",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
    ]);
  });

  it("initializes the control protocol before asking to authenticate", async () => {
    const lines = await runLogin("claude");
    const messages = lines.slice(1).map((line) => JSON.parse(line));
    expect(messages[0].request.subtype).toBe("initialize");
    expect(messages[1].request.subtype).toBe("claude_authenticate");
  });
});

describe("the Codex invocation", () => {
  it("runs the app-server over stdio", async () => {
    const [argv] = await runLogin("codex");
    expect(JSON.parse(argv!)).toEqual(["app-server", "--listen", "stdio://"]);
  });

  // Without this handshake every other method answers -32600 "Not initialized" and the
  // login simply never produces a URL.
  it("completes the LSP-shaped handshake before starting the login", async () => {
    const lines = await runLogin("codex");
    const messages = lines.slice(1).map((line) => JSON.parse(line));
    expect(messages.map((m) => m.method)).toEqual([
      "initialize",
      "initialized",
      "account/login/start",
    ]);
    expect(messages[2].params).toEqual({ type: "chatgptDeviceCode" });
  });
});
