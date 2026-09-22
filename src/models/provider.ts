/** The two providers QuotaPets tracks. Closed on purpose — the brief rules out everything else. */
export const PROVIDERS = ["claude", "codex"] as const;
export type AIProvider = (typeof PROVIDERS)[number];

export const DISPLAY_NAME: Record<AIProvider, string> = {
  claude: "Claude",
  codex: "Codex",
};

/** The two quota windows. Both providers expose exactly these. */
export type UsageWindowKind = "fiveHour" | "weekly";

/**
 * Canonical window durations in minutes. These are the same constants the Codex
 * classifier matches against (see codexWindowClassifier.ts).
 */
export const CANONICAL_MINUTES: Record<UsageWindowKind, number> = {
  fiveHour: 300,
  weekly: 10_080,
};

export const SHORT_LABEL: Record<UsageWindowKind, string> = {
  fiveHour: "5H",
  weekly: "WEEK",
};
