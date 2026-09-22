import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { PROVIDERS, type AIProvider } from "../models/provider.js";
import { JsonLineChannel, findString } from "./jsonLines.js";
import { idleSession, LOGIN_TIMEOUT_MS, type LoginSession } from "./session.js";
import { missingCLIHint, resolveCLI } from "./availability.js";

/** Opt-in, because the vendor CLI's output can contain the verification URL and code. */
const DEBUG_LOGIN = process.env["DEBUG_LOGIN"] === "1";

/**
 * `--verbose` is not optional: the CLI refuses to start without it here, with
 * `When using --print, --output-format=stream-json requires --verbose` and exit 1. It
 * does not make the child noisier for us — its output is JSON either way, and we never
 * log the child's own words.
 */
const CLAUDE_ARGS = [
  "-p",
  "--verbose",
  "--input-format",
  "stream-json",
  "--output-format",
  "stream-json",
] as const;

/** Only shapes the user-agent string the app-server builds for itself. */
const CODEX_CLIENT_INFO = { name: "quotapets", title: "QuotaPets", version: "1.0.0" } as const;

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

  /**
   * `resolve` is injectable so the spawn-failure path can be exercised by a test: point it
   * at an absolute path that is not there and the child fails exactly the way a missing
   * CLI does in production.
   */
  constructor(
    private readonly dirs: { claude: string; codex: string },
    private readonly resolve: (provider: AIProvider) => string | null = resolveCLI,
  ) {
    for (const provider of PROVIDERS) this.sessions.set(provider, idleSession(provider));
  }

  session(provider: AIProvider): LoginSession {
    return this.sessions.get(provider) ?? idleSession(provider);
  }

  isBusy(provider: AIProvider): boolean {
    return this.active.has(provider);
  }

  /** Whether the vendor binary this provider needs is actually installed. */
  cliAvailable(provider: AIProvider): boolean {
    return this.resolve(provider) !== null;
  }

  async start(provider: AIProvider): Promise<LoginSession> {
    this.cancel(provider);

    // Resolved before spawning, so the failure reads as a diagnosis rather than an ENOENT.
    // The route answers 503 on this too; having it here as well keeps `start()` safe to
    // call directly.
    const command = this.resolve(provider);
    if (command === null) {
      return this.mark(provider, "failed", missingCLIHint(provider));
    }

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

    // The resolved absolute path, not the bare name: the same file that was just checked
    // for is the one that runs.
    const child =
      provider === "claude"
        ? spawn(command, CLAUDE_ARGS, {
            env: { ...process.env, CLAUDE_CONFIG_DIR: this.dirs.claude },
            stdio: ["pipe", "pipe", "pipe"],
          })
        : spawn(command, ["app-server", "--listen", "stdio://"], {
            env: { ...process.env, CODEX_HOME: this.dirs.codex },
            stdio: ["pipe", "pipe", "pipe"],
          });

    const channel = new JsonLineChannel(child as ChildProcessWithoutNullStreams);
    const timer = setTimeout(() => this.expire(provider), LOGIN_TIMEOUT_MS);
    this.active.set(provider, { child: child as ChildProcessWithoutNullStreams, channel, timer });

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      // The child's output is NOT logged by default, on either stream. stdout can carry
      // account data, and stderr is where device-flow progress text goes — which is
      // exactly where the verification URL and user code appear. Neither is under our
      // control: it comes from an external CLI whose output changes between versions.
      if (!DEBUG_LOGIN) return;
      const text = chunk.trim();
      if (text) console.log(`[${provider} login:debug] ${text.slice(0, 200)}`);
    });
    // Load-bearing. A ChildProcess that fails to spawn emits 'error', and an 'error'
    // event with no listener is thrown — which took the whole server down, repeatedly,
    // the first time this ran somewhere the CLI was not installed. A missing binary must
    // fail one login, not the API.
    child.on("error", (error) => this.onSpawnError(provider, error));
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
      // The app-server is LSP-shaped: every other method answers
      // `{"code":-32600,"message":"Not initialized"}` until this handshake lands. Sent
      // back to back rather than awaited — stdin is processed in order, so the server
      // has handled `initialize` before it reads the login request.
      channel.send({
        jsonrpc: "2.0",
        id: 0,
        method: "initialize",
        params: { clientInfo: CODEX_CLIENT_INFO },
      });
      channel.send({ jsonrpc: "2.0", method: "initialized", params: {} });
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

  private onSpawnError(provider: AIProvider, error: Error): void {
    const code = (error as NodeJS.ErrnoException).code;
    console.error(`[${provider} login] could not start the CLI (${code ?? "unknown"})`);
    this.cancel(provider);
    this.mark(
      provider,
      "failed",
      code === "ENOENT" ? missingCLIHint(provider) : `could not start the CLI (${code ?? "unknown error"})`,
    );
  }

  private onExit(provider: AIProvider, code: number | null): void {
    // Fixed status only — never the child's own words.
    console.log(`[${provider} login] process exited (${code ?? "signal"})`);
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
