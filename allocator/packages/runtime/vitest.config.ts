import { readFileSync } from "node:fs";
import { defineConfig } from "vitest/config";

/**
 * Loads the repo's own `.env`, the same file Foundry reads.
 *
 * The fork test needs ARBITRUM_RPC_URL and the key lives there, gitignored. Without this the
 * test would skip silently on a machine that is perfectly capable of running it, which is the
 * worst of both outcomes.
 */
function loadRepoEnv(): void {
  try {
    const raw = readFileSync(new URL("../../../.env", import.meta.url), "utf8");
    for (const line of raw.split("\n")) {
      const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
      if (!match) continue;
      const [, key, value] = match;
      if (key && process.env[key] === undefined) {
        process.env[key] = value?.replace(/^["']|["']$/g, "") ?? "";
      }
    }
  } catch {
    // No .env is normal in CI, where secrets arrive as real environment variables.
  }
}

loadRepoEnv();

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    // A real RPC round trip is slower than the 5s default, and the fork tests make several.
    testTimeout: 30_000,
  },
});
