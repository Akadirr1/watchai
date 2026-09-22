import { describe, expect, it } from "vitest";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

async function sourceFiles(dir = "src"): Promise<string[]> {
  const out: string[] = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await sourceFiles(path)));
    else if (entry.name.endsWith(".ts")) out.push(path);
  }
  return out;
}

/**
 * These are the mechanical guarantee behind "QuotaPets never runs prompts". Prose in a
 * README cannot be enforced; a failing test can.
 */
describe("network surface", () => {
  const ALLOWED = new Set([
    "api.anthropic.com",    // Claude usage
    "chatgpt.com",          // Codex usage
    "platform.claude.com",  // Claude token refresh (our own grant)
    "auth.openai.com",      // Codex token refresh (our own grant)
    "anthropic.com",        // appears only inside a documentation comment
  ]);

  it("reaches no host outside the documented inventory", async () => {
    const found = new Map<string, string>();
    for (const file of await sourceFiles()) {
      const text = await readFile(file, "utf8");
      for (const match of text.matchAll(/https?:\/\/([a-z0-9.-]+)/gi)) {
        found.set(match[1]!.toLowerCase(), file);
      }
    }
    const unexpected = [...found.entries()].filter(([host]) => !ALLOWED.has(host));
    expect(unexpected).toEqual([]);
  });

  it("mentions no inference endpoint anywhere in the source", async () => {
    const FORBIDDEN = ["/v1/messages", "/responses", "/v1/chat/completions", "/v1/completions"];
    const offenders: string[] = [];
    for (const file of await sourceFiles()) {
      const text = await readFile(file, "utf8");
      for (const needle of FORBIDDEN) if (text.includes(needle)) offenders.push(`${file}: ${needle}`);
    }
    expect(offenders).toEqual([]);
  });

  it("issues only GET requests to provider usage endpoints", async () => {
    const poller = await readFile("src/poll/poller.ts", "utf8");
    // fetch() with no method defaults to GET; assert no method override sneaks in.
    expect(poller).not.toMatch(/method:\s*["'](POST|PUT|PATCH|DELETE)["']/);
  });
});
