import { mkdir } from "node:fs/promises";
import { config, credentialDirs } from "./config.js";
import { SnapshotStore } from "./poll/snapshotStore.js";
import { Poller } from "./poll/poller.js";
import { LoginManager } from "./login/manager.js";
import { PairingStore } from "./pair/index.js";
import { buildServer } from "./http/server.js";
import { CLI_COMMANDS, resolveCLI } from "./login/availability.js";
import { PROVIDERS } from "./models/provider.js";

async function main(): Promise<void> {
  // Both CLIs fail if their config directory does not already exist, and neither creates
  // it recursively. Do it once, up front.
  await Promise.all([
    mkdir(config.dataDir, { recursive: true }),
    mkdir(config.claudeConfigDir, { recursive: true }),
    mkdir(config.codexHome, { recursive: true }),
  ]);

  const store = new SnapshotStore(config.dataDir);
  await store.load();

  const poller = new Poller(
    store,
    credentialDirs,
    config.pollIntervalSec * 1000,
    config.codexStaggerSec * 1000,
  );
  const logins = new LoginManager(credentialDirs);
  const pairing = new PairingStore(config.dataDir);
  await pairing.load();

  const app = buildServer({ store, poller, logins, pairing, authToken: config.authToken });
  await app.listen({ port: config.port, host: config.host });
  poller.start();
  console.log(`quotapets listening on ${config.host}:${config.port}`);
  reportTools();

  const shutdown = async (signal: string): Promise<void> => {
    console.log(`${signal} received, shutting down`);
    poller.stop();
    await app.close();
    process.exit(0);
  };
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  process.on("SIGINT", () => void shutdown("SIGINT"));
}

/**
 * Said once, at startup, because the alternative is what actually happened in production:
 * an endless `notAuthenticated` — which reads as "sign in" — while the real problem was
 * that the CLI was never installed, and pressing Connect took the process down.
 */
function reportTools(): void {
  for (const provider of PROVIDERS) {
    const path = resolveCLI(provider);
    console.log(
      path
        ? `[${provider}] cli: ${path}`
        : `[${provider}] cli: ${CLI_COMMANDS[provider]} NOT FOUND on PATH — sign-in will fail. ` +
          `The project Dockerfile installs it; check this deployment's build pack.`,
    );
  }
}

void main().catch((error: unknown) => {
  console.error("fatal:", error);
  process.exit(1);
});
