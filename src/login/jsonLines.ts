import type { ChildProcessWithoutNullStreams } from "node:child_process";

/**
 * Newline-delimited JSON over a child's stdio.
 *
 * Both vendor CLIs speak a line-oriented JSON protocol on stdin/stdout when driven
 * programmatically, so neither needs a PTY. Non-JSON lines (banners, warnings) are
 * ignored rather than treated as errors — they are common and harmless.
 */
export class JsonLineChannel {
  private buffer = "";
  private readonly handlers: Array<(message: Record<string, unknown>) => void> = [];

  constructor(private readonly child: ChildProcessWithoutNullStreams) {
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.ingest(chunk));
    // A stream 'error' with no listener is thrown, same as on the process itself. Writing
    // to a child that never started, or has already exited, raises EPIPE here — and that
    // must not be able to take the server down.
    child.stdin.on("error", () => {});
    child.stdout.on("error", () => {});
  }

  private ingest(chunk: string): void {
    this.buffer += chunk;
    let index: number;
    while ((index = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      if (line === "") continue;
      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch {
        continue; // not JSON; ignore
      }
      if (typeof parsed === "object" && parsed !== null) {
        for (const handler of this.handlers) handler(parsed as Record<string, unknown>);
      }
    }
  }

  onMessage(handler: (message: Record<string, unknown>) => void): void {
    this.handlers.push(handler);
  }

  /** A no-op once the child is gone: there is nobody left to read it. */
  send(message: unknown): void {
    const { stdin } = this.child;
    if (!stdin.writable || stdin.destroyed) return;
    stdin.write(`${JSON.stringify(message)}\n`);
  }
}

/**
 * Recursively searches a decoded message for the first string value under any of the
 * given keys.
 *
 * Deliberately lenient about envelope shape: the CLIs' control/RPC wrappers are
 * undocumented and have changed between versions, but the payload field names
 * (`verification_url`, `manualUrl`, …) are stable. Matching on the leaf rather than the
 * path means a wrapper change does not break login.
 */
export function findString(
  value: unknown,
  keys: readonly string[],
  depth = 0,
): string | null {
  if (depth > 8 || typeof value !== "object" || value === null) return null;
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findString(item, keys, depth + 1);
      if (found) return found;
    }
    return null;
  }
  const record = value as Record<string, unknown>;
  for (const key of keys) {
    const candidate = record[key];
    if (typeof candidate === "string" && candidate !== "") return candidate;
  }
  for (const nested of Object.values(record)) {
    const found = findString(nested, keys, depth + 1);
    if (found) return found;
  }
  return null;
}
