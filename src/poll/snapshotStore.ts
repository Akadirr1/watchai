import { readFile, writeFile, rename, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { EMPTY_SNAPSHOT, type UsageSnapshot } from "../models/snapshot.js";

/**
 * Persists the latest snapshot so a redeploy doesn't serve a blank page.
 *
 * Coolify recreates the container on every push, and "no data" is indistinguishable from
 * "the app is broken" — the one message a status surface must never send by accident. A
 * restored snapshot is never presented as fresh; freshness is computed from its own
 * timestamp, so anything older than the threshold renders as stale.
 */
export class SnapshotStore {
  private snapshot: UsageSnapshot = EMPTY_SNAPSHOT;
  private restoredFromDisk = false;
  private readonly path: string;

  constructor(dataDir: string) {
    this.path = join(dataDir, "snapshot.json");
  }

  async load(): Promise<void> {
    try {
      const parsed = JSON.parse(await readFile(this.path, "utf8")) as UsageSnapshot;
      if (parsed && typeof parsed.generatedAt === "number") {
        this.snapshot = parsed;
        this.restoredFromDisk = true;
      }
    } catch {
      // Absent or corrupt: start empty. Never fatal.
    }
  }

  current(): UsageSnapshot {
    return this.snapshot;
  }

  wasRestored(): boolean {
    return this.restoredFromDisk;
  }

  async set(snapshot: UsageSnapshot): Promise<void> {
    this.snapshot = snapshot;
    this.restoredFromDisk = false;
    try {
      await mkdir(dirname(this.path), { recursive: true });
      const tmp = `${this.path}.tmp`;
      await writeFile(tmp, JSON.stringify(snapshot), "utf8");
      await rename(tmp, this.path); // atomic
    } catch (error) {
      console.error("snapshot persist failed:", (error as Error).message);
    }
  }
}
