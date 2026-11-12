/** Keeps the local Mac display awake while GOAT runs are active, when Adrafinil is installed. */
// @effect-diagnostics nodeBuiltinImport:off - the optional CLI is detected synchronously before the reactor starts.
import * as NodeFS from "node:fs";
import type { OrchestrationV2Run, RunId } from "@goat/contracts";
import * as HostProcess from "@goat/shared/HostProcess";
import * as Context from "effect/Context";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";

import * as ProcessRunner from "../../processRunner.ts";
import { forkParked } from "../../serverActivation.ts";
import * as EventSink from "../EventSink.ts";
import * as Orchestrator from "../Orchestrator.ts";

const command = "/Applications/Adrafinil.app/Contents/Helpers/adrafinil";
const activeStatuses = new Set<OrchestrationV2Run["status"]>([
  "preparing",
  "starting",
  "running",
  "waiting",
]);

export const make = Effect.gen(function* () {
  const runner = yield* ProcessRunner.ProcessRunner;
  const sink = yield* EventSink.EventSinkV2;
  const orchestrator = yield* Orchestrator.OrchestratorV2;
  const holds = new Map<RunId, string>();

  const invoke = (args: ReadonlyArray<string>) =>
    runner.run({ command, args, timeout: "5 seconds", maxOutputBytes: 4096 });

  const releaseId = Effect.fn("DisplayAwakeReactor.releaseId")(
    function* (runId: RunId, holdId: string) {
      const result = yield* invoke(["release", holdId]);
      if (result.code !== 0) {
        yield* Effect.logWarning("Could not release GOAT display hold", {
          runId,
          stderr: result.stderr.trim(),
        });
      }
    },
    (effect, runId) =>
      effect.pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("Could not release GOAT display hold", { runId, cause }),
        ),
      ),
  );

  const release = Effect.fn("DisplayAwakeReactor.release")(function* (runId: RunId) {
    const holdId = holds.get(runId);
    if (holdId === undefined) return;
    holds.delete(runId);
    yield* releaseId(runId, holdId);
  });

  const acquire = Effect.fn("DisplayAwakeReactor.acquire")(
    function* (runId: RunId) {
      const result = yield* invoke([
        "hold",
        "--pid",
        String(process.pid),
        "--for",
        "2h",
        "--tool",
        "goat",
        "--reason",
        `GOAT run ${runId}`,
        "--display",
      ]);
      const holdId = result.stdout.trim();
      if (result.code !== 0 || !/^hold:[a-zA-Z0-9-]+$/.test(holdId)) {
        yield* Effect.logWarning("Could not keep the display awake for GOAT run", {
          runId,
          stderr: result.stderr.trim(),
        });
        return undefined;
      }
      return holdId;
    },
    (effect, runId) =>
      effect.pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("Could not keep the display awake for GOAT run", {
            runId,
            cause,
          }).pipe(Effect.as(undefined)),
        ),
      ),
  );

  const observe = Effect.fn("DisplayAwakeReactor.observe")(function* (run: OrchestrationV2Run) {
    if (!activeStatuses.has(run.status)) {
      yield* release(run.id);
      return;
    }
    if (holds.has(run.id)) return;
    const holdId = yield* acquire(run.id);
    if (holdId !== undefined) holds.set(run.id, holdId);
  });

  // Adrafinil holds are time-limited, so renew before the two-hour limit.
  const renew = Effect.suspend(() =>
    Effect.forEach(
      [...holds],
      ([runId, oldHoldId]) =>
        Effect.gen(function* () {
          const newHoldId = yield* acquire(runId);
          if (newHoldId === undefined) return;
          holds.set(runId, newHoldId);
          yield* releaseId(runId, oldHoldId);
        }),
      { discard: true },
    ),
  );

  const reconcile = Effect.gen(function* () {
    const snapshot = yield* orchestrator.getShellSnapshot({ unsettledOnly: true });
    for (const shell of [...snapshot.threads, ...snapshot.archivedThreads]) {
      if (shell.activeRunId === null) continue;
      const { runs } = yield* orchestrator.getThreadRecords(shell.id, ["runs"], {
        runIds: [shell.activeRunId],
      });
      for (const run of runs) yield* observe(run);
    }
  }).pipe(
    Effect.catchCause((cause) =>
      Effect.logWarning("Could not restore GOAT display holds", { cause }),
    ),
  );

  const start = Effect.gen(function* () {
    yield* Effect.addFinalizer(() => Effect.forEach([...holds.keys()], release, { discard: true }));
    const cursor = yield* sink.latestSequence();
    const created = yield* Deferred.make<void>();
    const updated = yield* Deferred.make<void>();
    const reconciled = yield* Deferred.make<void>();
    const follow = (eventType: "run.created" | "run.updated", ready: Deferred.Deferred<void>) =>
      sink.stream({
        afterSequence: cursor,
        eventType,
        onSubscribed: Deferred.succeed(ready, undefined).pipe(Effect.asVoid),
      });
    const events = Stream.merge(
      follow("run.created", created),
      follow("run.updated", updated),
    ).pipe(Stream.map((stored) => ({ kind: "event" as const, stored })));
    const renewals = Stream.tick("1 hour").pipe(
      Stream.drop(1),
      Stream.map(() => ({ kind: "renew" as const })),
    );
    yield* Stream.merge(events, renewals).pipe(
      Stream.runForEach((item) =>
        Deferred.await(reconciled).pipe(
          Effect.andThen(
            item.kind === "renew"
              ? renew
              : item.stored.event.type === "run.created" || item.stored.event.type === "run.updated"
                ? observe(item.stored.event.payload)
                : Effect.void,
          ),
        ),
      ),
      Effect.catchCause((cause) =>
        Effect.logWarning("Stopped following GOAT runs for display holds", { cause }),
      ),
      Effect.forkScoped,
    );
    yield* Deferred.await(created);
    yield* Deferred.await(updated);
    yield* reconcile;
    yield* Deferred.succeed(reconciled, undefined);
  });
  return { start };
});

class DisplayAwakeReactor extends Context.Service<DisplayAwakeReactor, object>()(
  "goat/orchestration-v2/goat/DisplayAwakeReactor",
) {}

export const layer = Layer.effect(
  DisplayAwakeReactor,
  Effect.gen(function* () {
    if ((yield* HostProcess.Platform) !== "darwin" || !NodeFS.existsSync(command)) return {};
    const reactor = yield* make;
    yield* forkParked(Effect.scoped(reactor.start.pipe(Effect.andThen(Effect.never))));
    return {};
  }),
);
