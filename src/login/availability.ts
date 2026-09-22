import { accessSync, constants } from "node:fs";
import { delimiter, join } from "node:path";
import type { AIProvider } from "../models/provider.js";

/**
 * Is the vendor CLI actually here?
 *
 * This exists because of a real outage: the container was built with a build pack that
 * was not the project Dockerfile, so neither CLI was installed. The only symptom was
 * `[claude] notAuthenticated` on repeat — which reads exactly like "no token yet" — and
 * then a crash the moment anyone pressed Connect. "Not signed in" and "the binary is not
 * here" are different problems and must look different.
 *
 * Resolved by walking PATH rather than spawning `which`: no subprocess, no shell, and
 * nothing to go wrong on a minimal Alpine image that may not ship `which` at all.
 */

export const CLI_COMMANDS: Readonly<Record<AIProvider, string>> = {
  claude: "claude",
  codex: "codex",
};

export function resolveExecutable(name: string, path = process.env["PATH"]): string | null {
  if (!path) return null;
  for (const dir of path.split(delimiter)) {
    if (dir === "") continue;
    const candidate = join(dir, name);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Not here, or not executable. Keep looking.
    }
  }
  return null;
}

export function resolveCLI(provider: AIProvider): string | null {
  return resolveExecutable(CLI_COMMANDS[provider]);
}

/**
 * Why the CLI is missing, in terms a person can act on. The likeliest cause by far is a
 * deployment that did not use the project Dockerfile, so say that rather than leaving
 * someone to work out what ENOENT means.
 */
export function missingCLIHint(provider: AIProvider): string {
  return (
    `the \`${CLI_COMMANDS[provider]}\` CLI is not on PATH in this container. ` +
    `The project Dockerfile installs it, so this usually means the deployment was built ` +
    `with a different build pack (Coolify defaults to Nixpacks unless you pick Dockerfile).`
  );
}
