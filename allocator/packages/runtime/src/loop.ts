/**
 * A thin wrapper around `runOnce`. Deliberately thin.
 *
 * The one-shot pipeline is where all the logic lives and where all the tests point. Everything
 * this adds is scheduling and the discipline to keep running: a tick that throws must not take
 * the process down, because the situation where the allocator is most needed is the one where
 * the RPC is flaky and positions are moving.
 *
 * What it does NOT do is retry a failed tick immediately. A rejection from the planner or a
 * failed simulation is almost always a state condition rather than a transient, and hammering
 * an aggregator to be told the same thing is how an API key gets rate limited. Backoff applies
 * to failures; success returns to the base interval.
 */

import type { Intent } from "@morphoagg/planner";

import { runOnce, type PipelineDeps, type RunOptions, type RunResult } from "./pipeline.js";

export interface LoopOptions extends RunOptions {
  intervalMs: number;
  /** Ceiling on the exponential backoff after consecutive failures. */
  maxBackoffMs?: number;
  /** Stop after this many ticks. Used by tests; unset runs until signalled. */
  maxTicks?: number;
  onTick?: (result: RunResult, tick: number) => void;
  onError?: (error: unknown, tick: number) => void;
}

const DEFAULTS = {
  maxBackoffMs: 300_000,
} as const;

export interface LoopHandle {
  /** Resolves once the loop has finished the tick it is on and stopped. */
  stop(): void;
  done: Promise<void>;
}

/**
 * @param intents - a function, not an array. Tier 4's `Strategy` is exactly this shape, so the
 *   loop does not change when the intent source stops being a static file.
 */
export function startLoop(
  deps: PipelineDeps,
  intents: () => Intent[] | Promise<Intent[]>,
  options: LoopOptions,
): LoopHandle {
  const maxBackoffMs = options.maxBackoffMs ?? DEFAULTS.maxBackoffMs;
  let stopped = false;
  let wake: (() => void) | null = null;

  function stop(): void {
    stopped = true;
    wake?.();
  }

  /** Sleeps, but wakes immediately on stop so shutdown does not wait out a full interval. */
  function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(finish, ms);
      wake = finish;
      function finish(): void {
        clearTimeout(timer);
        wake = null;
        resolve();
      }
    });
  }

  const done = (async () => {
    let consecutiveFailures = 0;

    for (let tick = 0; !stopped && (options.maxTicks === undefined || tick < options.maxTicks); tick++) {
      try {
        const result = await runOnce(deps, await intents(), options);
        consecutiveFailures = 0;
        options.onTick?.(result, tick);
      } catch (error) {
        consecutiveFailures++;
        options.onError?.(error, tick);
      }

      if (stopped) break;
      await sleep(backoffFor(options.intervalMs, consecutiveFailures, maxBackoffMs));
    }
  })();

  return { stop, done };
}

/** Doubles per consecutive failure, capped. Zero failures is the plain interval. */
export function backoffFor(intervalMs: number, consecutiveFailures: number, maxBackoffMs: number): number {
  if (consecutiveFailures === 0) return intervalMs;
  // Cap the exponent before shifting: a long outage would otherwise overflow the multiplier
  // long before the Math.min could clamp it.
  const exponent = Math.min(consecutiveFailures, 20);
  return Math.min(intervalMs * 2 ** exponent, maxBackoffMs);
}

/** Wires SIGINT and SIGTERM to a graceful stop. */
export function stopOnSignals(handle: LoopHandle): void {
  const stop = (): void => handle.stop();
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
}
