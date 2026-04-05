# Copilot SDK Alignment

This note captures the runtime contract Ghostline expects from `@github/copilot-sdk` and the places where we intentionally diverge.

## Goals

- keep command generation aligned with the SDK's session lifecycle
- keep session setup identical across helper and daemon paths
- keep tool exposure deny-by-default and allowlist-driven
- avoid deprecated session cleanup paths

## Current decisions

- Use `session.disconnect()` for cleanup.
- Keep the post-install SDK patch for Node compatibility, but only for affected `0.1.x` SDK builds.
- Use one shared session-config builder for helper and daemon paths so `availableTools`, `tools`, and `hooks` stay in sync.
- Keep custom idle waiting for main command generation.
  This is an intentional product choice: generate/fix/refine/chain should wait for a real Copilot result or `session.error`, not fail only because the model is slow.
- Keep `suggest` and `explain` on SDK-native `sendAndWait()` with bounded timeouts.
- Populate the model cache from `client.listModels()` after startup so explicit model rejection works and explain-mode does not fail on an empty cache.

## Non-goals

- We are not trying to mirror every SDK option.
- We are not using resume/infinite-session features for command generation.
- We are not exposing tools unless explicitly allowlisted.

## Practical rules

1. Any session option change must be applied through the shared runtime helper.
2. Helper and daemon paths must produce the same tool visibility for the same config.
3. Main command generation may be slow, but should only fail on real SDK/session errors.
4. Timeout-based failures are acceptable for suggest/explain, not for the main generate path.
