import { assert, it } from "@effect/vitest";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as ConfigProvider from "effect/ConfigProvider";
import * as Effect from "effect/Effect";

import { createBuildConfig } from "./build-desktop-artifact.ts";

it.effect("uses an explicitly enabled personal GitHub update feed", () =>
  Effect.gen(function* () {
    const config = yield* createBuildConfig(
      "mac",
      "zip",
      "0.1.9",
      true,
      false,
      undefined,
      undefined,
    ).pipe(
      Effect.provide(
        ConfigProvider.layer(
          ConfigProvider.fromEnv({
            env: {
              GOAT_DESKTOP_UPDATE_FEED_ENABLED: "true",
              GOAT_DESKTOP_PERSONAL_UPDATE_FEED: "true",
              GOAT_DESKTOP_UPDATE_REPOSITORY: "minerva32/goat",
            },
          }),
        ),
      ),
    );
    assert.deepEqual(config.publish, [
      { provider: "github", owner: "minerva32", repo: "goat", releaseType: "release" },
    ]);
  }).pipe(Effect.provide(NodeServices.layer)),
);
