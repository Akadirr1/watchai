import { mkdir } from "node:fs/promises";
import { config, credentialDirs } from "./config.js";
import { SnapshotStore } from "./poll/snapshotStore.js";
import { Poller } from "./poll/poller.js";
import { LoginManager } from "./login/manager.js";
import { buildServer } from "./http/server.js";

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

  const app = buildServer({ store, poller, logins, authToken: config.authToken });
  await app.listen({ port: config.port, host: config.host });
  poller.start();
  console.log(`quotapets listening on ${config.host}:${config.port}`);

  const shutdown = async (signal: string): Promise<void> => {
    console.log(`${signal} received, shutting down`);
    poller.stop();
    await app.close();
    process.exit(0);
  };
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  process.on("SIGINT", () => void shutdown("SIGINT"));
}

void main().catch((error: unknown) => {
  console.error("fatal:", error);
  process.exit(1);
});
