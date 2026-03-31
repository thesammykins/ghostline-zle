import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

// Use a temp directory for tests
const testDir = path.join(os.tmpdir(), `copilot-zle-flight-test-${process.pid}`);
process.env.COPILOT_ZLE_DATA_DIR = testDir;

const { recordGeneration, markExecuted, queryRelevant, queryFollowUps, buildFewShotBlock, getLogPath } = await import("./flight-log.mjs");

const cleanup = () => {
  try { fs.rmSync(testDir, { recursive: true, force: true }); } catch {}
};

// Clean start
cleanup();

// ── getLogPath ─────────────────────────────────────────────────────
assert.ok(getLogPath().includes("flight-log.jsonl"));

// ── recordGeneration ───────────────────────────────────────────────
recordGeneration({
  prompt: "list large files in downloads",
  command: "fd -t f -S +10m . ~/Downloads",
  mode: "generate",
  cwd: "/Users/test/Downloads",
  durationMs: 800,
});

assert.ok(fs.existsSync(getLogPath()), "log file should exist");
const lines1 = fs.readFileSync(getLogPath(), "utf8").trim().split("\n");
assert.equal(lines1.length, 1);
const entry1 = JSON.parse(lines1[0]);
assert.equal(entry1.prompt, "list large files in downloads");
assert.equal(entry1.command, "fd -t f -S +10m . ~/Downloads");
assert.equal(entry1.executed, false);
assert.equal(entry1.exit_code, null);
assert.equal(entry1.mode, "generate");

// ── markExecuted ───────────────────────────────────────────────────
markExecuted("fd -t f -S +10m . ~/Downloads", 0);
const lines2 = fs.readFileSync(getLogPath(), "utf8").trim().split("\n");
const entry2 = JSON.parse(lines2[0]);
assert.equal(entry2.executed, true);
assert.equal(entry2.exit_code, 0);

// ── markExecuted for non-existent command (no-op) ──────────────────
markExecuted("some-other-command", 1);
const lines3 = fs.readFileSync(getLogPath(), "utf8").trim().split("\n");
assert.equal(lines3.length, 1);

// ── queryRelevant ──────────────────────────────────────────────────
// Add more entries for querying
recordGeneration({ prompt: "find python files", command: "fd -e py", mode: "generate", cwd: "/Users/test/project" });
markExecuted("fd -e py", 0);

recordGeneration({ prompt: "search for TODO", command: "rg TODO", mode: "generate", cwd: "/Users/test/project" });
markExecuted("rg TODO", 0);

recordGeneration({ prompt: "build project", command: "npm run build", mode: "generate", cwd: "/Users/test/project" });
// Not executed — should not appear in relevant results

const relevant = queryRelevant({ prompt: "find python files here", cwd: "/Users/test/project", limit: 5 });
assert.ok(relevant.length >= 1, "should find relevant entries");
assert.ok(relevant.some((e) => e.command === "fd -e py"), "should find fd -e py");
// Unexecuted entries should not appear
assert.ok(!relevant.some((e) => e.command === "npm run build"), "unexecuted should not appear");

// ── queryFollowUps ─────────────────────────────────────────────────
// Simulate a sequence: after "fd -e py", user generates "rg TODO"
const followUps = queryFollowUps({ command: "fd -t f -S +10m . ~/Downloads" });
// The entry after the downloads command is "fd -e py" (but fd -e py is also executed)
assert.ok(Array.isArray(followUps), "should return array");

// ── buildFewShotBlock ──────────────────────────────────────────────
const block = buildFewShotBlock([
  { prompt: "list files", command: "ls -la" },
  { prompt: "find todos", command: "rg TODO" },
]);
assert.ok(block.includes("PATTERN MEMORY"));
assert.ok(block.includes("User: list files"));
assert.ok(block.includes("Command: ls -la"));

const emptyBlock = buildFewShotBlock([]);
assert.equal(emptyBlock, "");

const nullBlock = buildFewShotBlock(null);
assert.equal(nullBlock, "");

// ── rotation ───────────────────────────────────────────────────────
// Fill beyond maxEntries and verify rotation
for (let i = 0; i < 15; i++) {
  recordGeneration({
    prompt: `test prompt ${i}`,
    command: `echo ${i}`,
    mode: "generate",
    cwd: "/tmp",
    maxEntries: 10,
  });
}
const rotatedLines = fs.readFileSync(getLogPath(), "utf8").trim().split("\n");
assert.ok(rotatedLines.length <= 12, `should have rotated, got ${rotatedLines.length}`);

// ── empty prompt/command rejected ──────────────────────────────────
const countBefore = fs.readFileSync(getLogPath(), "utf8").trim().split("\n").length;
recordGeneration({ prompt: "", command: "ls" });
recordGeneration({ prompt: "test", command: "" });
const countAfter = fs.readFileSync(getLogPath(), "utf8").trim().split("\n").length;
assert.equal(countBefore, countAfter, "empty prompt/command should not be recorded");

// Cleanup
cleanup();

console.log("flight-log tests passed");
