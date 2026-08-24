import { describe, expect, it, vi } from "vitest";

import { backoffFor, startLoop } from "../src/loop.js";
import type { PipelineDeps, RunResult } from "../src/pipeline.js";

// The loop's only job is scheduling; `runOnce` is exercised on its own elsewhere. Stubbing it
// keeps these tests about the property that matters here: a tick that throws must not end the
// process.
const runOnce = vi.hoisted(() => vi.fn());
vi.mock("../src/pipeline.js", () => ({ runOnce }));

describe("backoff", () => {
  it("uses the plain interval while ticks succeed", () => {
    expect(backoffFor(1_000, 0, 300_000)).toBe(1_000);
  });

  it("doubles per consecutive failure and stops at the cap", () => {
    expect(backoffFor(1_000, 1, 300_000)).toBe(2_000);
    expect(backoffFor(1_000, 3, 300_000)).toBe(8_000);
    expect(backoffFor(1_000, 100, 300_000)).toBe(300_000);
  });

  /**
   * A long outage would otherwise raise 2 to a few hundred before `Math.min` ever ran, and
   * `Infinity` as a delay silently ends the loop rather than backing it off.
   */
  it("stays finite through an outage long enough to overflow a naive exponent", () => {
    const delay = backoffFor(1_000, 5_000, 300_000);
    expect(Number.isFinite(delay)).toBe(true);
    expect(delay).toBe(300_000);
  });
});

describe("the loop", () => {
  const deps = {} as PipelineDeps;

  it("keeps running after a tick throws", async () => {
    const errors: unknown[] = [];
    const ticks: RunResult[] = [];
    let calls = 0;

    runOnce.mockImplementation(() => {
      calls++;
      if (calls === 1) throw new Error("RPC exploded");
      return Promise.resolve({ outcome: "nothing-to-do" } as RunResult);
    });

    const handle = startLoop(deps, () => [], {
      intervalMs: 1,
      maxTicks: 3,
      onTick: (r) => ticks.push(r),
      onError: (e) => errors.push(e),
    });
    await handle.done;

    // One failure recorded, and the loop went on to run the remaining ticks anyway. The moment
    // the RPC is flaky is the moment positions most need watching.
    expect(errors).toHaveLength(1);
    expect(ticks).toHaveLength(2);
    expect(calls).toBe(3);
  });

  it("wakes immediately on stop rather than waiting out the interval", async () => {
    runOnce.mockResolvedValue({ outcome: "nothing-to-do" } as RunResult);
    const handle = startLoop(deps, () => [], { intervalMs: 60_000, maxTicks: 100 });

    const started = Date.now();
    // Let the first tick land, then stop mid-sleep.
    await new Promise((r) => setTimeout(r, 10));
    handle.stop();
    await handle.done;

    expect(Date.now() - started).toBeLessThan(1_000);
  });
});
