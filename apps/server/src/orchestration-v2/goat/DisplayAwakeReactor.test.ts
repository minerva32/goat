import { assert, it } from "@effect/vitest";
import {
  RunId,
  ThreadId,
  type OrchestrationV2Run,
  type OrchestrationV2StoredEvent,
} from "@goat/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Queue from "effect/Queue";
import * as Stream from "effect/Stream";

import * as ProcessRunner from "../../processRunner.ts";
import * as EventSink from "../EventSink.ts";
import * as Orchestrator from "../Orchestrator.ts";
import type { ShellSnapshotRead } from "../ProjectionStore.ts";
import * as DisplayAwakeReactor from "./DisplayAwakeReactor.ts";

const runId = RunId.make("run:display-awake-test");
const threadId = ThreadId.make("thread:display-awake-test");
const running = { id: runId, threadId, status: "running" } as OrchestrationV2Run;

it.effect("holds the display for a recovered GOAT run and releases it when the run completes", () =>
  Effect.gen(function* () {
    const created = yield* Queue.unbounded<OrchestrationV2StoredEvent>();
    const updated = yield* Queue.unbounded<OrchestrationV2StoredEvent>();
    const calls = yield* Queue.unbounded<ReadonlyArray<string>>();
    const runner = Layer.mock(ProcessRunner.ProcessRunner)({
      run: ({ args }) =>
        Effect.gen(function* () {
          yield* Queue.offer(calls, args);
          return {
            stdout: args[0] === "hold" ? "hold:test123\n" : "",
            stderr: "",
            code: 0 as ProcessRunner.ProcessRunOutput["code"],
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false,
            stdoutInvalidUtf8: false,
            stderrInvalidUtf8: false,
          };
        }),
    });
    const sink = Layer.mock(EventSink.EventSinkV2)({
      latestSequence: () => Effect.succeed(0),
      stream: (input) =>
        Stream.fromEffect(input?.onSubscribed ?? Effect.void).pipe(
          Stream.flatMap(() =>
            Stream.fromQueue(input?.eventType === "run.created" ? created : updated),
          ),
        ),
    });
    const orchestrator = Layer.mock(Orchestrator.OrchestratorV2)({
      getShellSnapshot: () =>
        Effect.succeed({
          threads: [{ id: threadId, activeRunId: runId }],
          archivedThreads: [],
        } as unknown as ShellSnapshotRead),
      getThreadRecords: (() =>
        Effect.succeed({
          runs: [running],
        })) as Orchestrator.OrchestratorV2["Service"]["getThreadRecords"],
    });
    const reactor = yield* DisplayAwakeReactor.make.pipe(
      Effect.provide(Layer.mergeAll(runner, sink, orchestrator)),
    );
    yield* reactor.start;
    const hold = yield* Queue.take(calls);
    assert.equal(hold[0], "hold");
    assert.include(hold, "--display");
    assert.include(hold, String(process.pid));

    yield* Queue.offer(updated, {
      event: { type: "run.updated", payload: { ...running, status: "completed" } },
    } as OrchestrationV2StoredEvent);
    const release = yield* Queue.take(calls);
    assert.deepEqual(release, ["release", "hold:test123"]);
  }).pipe(Effect.scoped),
);
