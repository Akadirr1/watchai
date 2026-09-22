import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { PROVIDERS, type AIProvider } from "../models/provider.js";
import { JsonLineChannel, findString } from "./jsonLines.js";
import { idleSession, LOGIN_TIMEOUT_MS, type LoginSession } from "./session.js";

const URL_KEYS = ["manualUrl", "manual_url", "verificationUrl", "verification_url"] as const;
const CODE_KEYS = ["userCode", "user_code"] as const;

interface ActiveLogin {
  child: ChildProcessWithoutNullStreams;
  channel: JsonLineChannel;
  timer: NodeJS.Timeout;
}

/**
 * Drives the vendor CLIs' own login flows.
 *
 * QuotaPets implements no OAuth. It starts the real `claude` / `codex` binary, relays the
 * URL (and for Codex the device code) that the binary produces, hands back whatever the
 * user pastes, and lets the CLI write its own credential file. The consent screen the
 * user sees is honest: it really is Claude Code / Codex asking.
 *
 * Both flows are stdio-JSON and need no TTY, which is why there is no PTY machinery here.
 *
 * ⚠️ The Claude control-protocol subtypes used below are marked `@internal` in the
 * vendor SDK. They work and are what the first-party desktop clients use, but they carry
 * no stability guarantee. If a future release breaks them, the documented fallback is a
 * one-off `docker exec <container> claude auth login`; the credential lands in the same
 * directory and everything else keeps working.
 */
export class LoginManager {
  private readonly sessions = new Map<AIProvider, LoginSession>();
  private readonly active = new Map<AIProvider, ActiveLogin>();

  constructor(private readonly dirs: { claude: string; codex: string }) {
    for (const provider of PROVIDERS) this.sessions.set(provider, idleSession(provider));
  }

  session(provider: AIProvider): LoginSession {
    return this.sessions.get(provider) ?? idleSession(provider);
  }

  isBusy(provider: AIProvider): boolean {
    return this.active.has(provider);
  }

  async start(provider: AIProvider): Promise<LoginSession> {
    this.cancel(provider);

    // Both CLIs error out if their config directory does not already exist — neither
    // creates it recursively, and the resulting failure is silent.
    const dir = provider === "claude" ? this.dirs.claude : this.dirs.codex;
    await mkdir(dir, { recursive: true });

    const session: LoginSession = {
      ...idleSession(provider),
      phase: "waiting",
      startedAt: Date.now(),
    };
    this.sessions.set(provider, session);

    const child =
      provider === "claude"
        ? spawn("claude", ["-p", "--input-format", "stream-json", "--output-format", "stream-json"], {
            env: { ...process.env, CLAUDE_CONFIG_DIR: this.dirs.claude },
            stdio: ["pipe", "pipe", "pipe"],
          })
        : spawn("codex", ["app-server", "--listen", "stdio://"], {
            env: { ...process.env, CODEX_HOME: this.dirs.codex },
            stdio: ["pipe", "pipe", "pipe"],
          });

    const channel = new JsonLineChannel(child as ChildProcessWithoutNullStreams);
    const timer = setTimeout(() => this.expire(provider), LOGIN_TIMEOUT_MS);
    this.active.set(provider, { child: child as ChildProcessWithoutNullStreams, channel, timer });

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      // Never log the child's stdout (it can carry account data); stderr is progress text.
      const text = chunk.trim();
      if (text) console.log(`[${provider} login] ${text.slice(0, 200)}`);
    });
    child.on("exit", (code) => this.onExit(provider, code));

    channel.onMessage((message) => this.onMessage(provider, message));

    if (provider === "claude") {
      channel.send({
        type: "control_request",
        request_id: "qp-init",
        request: { subtype: "initialize" },
      });
      channel.send({
        type: "control_request",
        request_id: "qp-auth",
        request: { subtype: "claude_authenticate", loginWithClaudeAi: true },
      });
    } else {
      channel.send({
        jsonrpc: "2.0",
        id: 1,
        method: "account/login/start",
        params: { type: "chatgptDeviceCode" },
      });
    }

    return session;
  }

  /** Claude only: hand back the `<code>#<state>` string the user pasted. */
  complete(provider: AIProvider, pasted: string): LoginSession {
    const session = this.session(provider);
    const active = this.active.get(provider);
    if (!active || session.phase !== "waiting") {
      return this.mark(provider, "failed", "no login is in progress");
    }

    const [authorizationCode, state] = pasted.trim().split("#");
    if (!authorizationCode || !state) {
      // The CLI's own validation message, for the same reason: both halves are required.
      return this.mark(provider, "waiting", "Invalid code. Make sure the full code was copied.");
    }

    active.channel.send({
      type: "control_request",
      request_id: "qp-callback",
      request: { subtype: "claude_oauth_callback", authorizationCode, state },
    });
    return this.session(provider);
  }

  cancel(provider: AIProvider): void {
    const active = this.active.get(provider);
    if (!active) return;
    clearTimeout(active.timer);
    active.child.kill("SIGTERM");
    this.active.delete(provider);
  }

  private onMessage(provider: AIProvider, message: Record<string, unknown>): void {
    const session = this.sessions.get(provider);
    if (!session || session.phase !== "waiting") return;

    const url = findString(message, URL_KEYS);
    if (url && !session.url) {
      session.url = url;
      session.userCode = findString(message, CODE_KEYS);
    }

    // Codex pushes a completion notification; Claude resolves the callback request.
    const method = message["method"];
    if (method === "account/login/completed") {
      const params = message["params"];
      const success =
        typeof params === "object" && params !== null
          ? (params as Record<string, unknown>)["success"] === true
          : false;
      this.finish(provider, success, findString(message, ["error", "message"]));
      return;
    }

    if (message["type"] === "control_response" && session.url) {
      const account = findString(message, ["email", "subscriptionType", "organization"]);
      const error = findString(message, ["error", "message"]);
      if (account) this.finish(provider, true, null);
      else if (error && message["request_id"] === "qp-callback") this.finish(provider, false, error);
    }
  }

  private onExit(provider: AIProvider, code: number | null): void {
    const session = this.sessions.get(provider);
    this.active.delete(provider);
    if (!session || session.phase !== "waiting") return;
    // Codex's CLI exits 0 once the device flow completes and the credential is written.
    this.finish(provider, code === 0, code === 0 ? null : `login process exited with ${code}`);
  }

  private expire(provider: AIProvider): void {
    this.cancel(provider);
    this.mark(provider, "expired", "the login window expired — start again");
  }

  private finish(provider: AIProvider, success: boolean, error: string | null): void {
    this.cancel(provider);
    this.mark(provider, success ? "completed" : "failed", success ? null : error);
  }

  private mark(provider: AIProvider, phase: LoginSession["phase"], error: string | null): LoginSession {
    const session = { ...this.session(provider), phase, error };
    this.sessions.set(provider, session);
    return session;
  }
}
