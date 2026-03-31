import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { sniffProjectContext, buildProjectBlock, clearCache } from "../lib/project-context.mjs";

const testDir = path.join(os.tmpdir(), `copilot-zle-project-test-${process.pid}`);

const cleanup = () => {
  clearCache();
  try { fs.rmSync(testDir, { recursive: true, force: true }); } catch {}
};

const setup = () => {
  cleanup();
  fs.mkdirSync(testDir, { recursive: true });
};

// ── Node project ───────────────────────────────────────────────────
setup();
fs.writeFileSync(path.join(testDir, "package.json"), JSON.stringify({
  name: "test-project",
  scripts: { build: "tsc", test: "vitest", dev: "next dev", lint: "eslint ." },
}));

const nodeCtx = sniffProjectContext(testDir);
assert.ok(nodeCtx, "should detect node project");
assert.ok(nodeCtx.signals.includes("node/npm"));
assert.deepEqual(nodeCtx.scripts, ["build", "test", "dev", "lint"]);

const nodeBlock = buildProjectBlock(nodeCtx);
assert.ok(nodeBlock.includes("PROJECT TYPE: node/npm"));
assert.ok(nodeBlock.includes("NPM SCRIPTS: build, test, dev, lint"));

// ── Makefile project ───────────────────────────────────────────────
setup();
fs.writeFileSync(path.join(testDir, "Makefile"), `
build:
\tgo build ./...
test:
\tgo test ./...
lint:
\tgolangci-lint run
`);

clearCache();
const makeCtx = sniffProjectContext(testDir);
assert.ok(makeCtx, "should detect Makefile project");
assert.ok(makeCtx.signals.includes("make"));
assert.ok(makeCtx.makeTargets.includes("build"));
assert.ok(makeCtx.makeTargets.includes("test"));

// ── Rust project ───────────────────────────────────────────────────
setup();
fs.writeFileSync(path.join(testDir, "Cargo.toml"), `
[package]
name = "my-cli"
version = "0.1.0"
`);

clearCache();
const rustCtx = sniffProjectContext(testDir);
assert.ok(rustCtx, "should detect Rust project");
assert.ok(rustCtx.signals.includes("rust/cargo"));
assert.equal(rustCtx.cargo.name, "my-cli");

// ── Python project ─────────────────────────────────────────────────
setup();
fs.writeFileSync(path.join(testDir, "pyproject.toml"), `
[project]
name = "my-api"

[tool.pytest]
testpaths = ["tests"]
`);

clearCache();
const pyCtx = sniffProjectContext(testDir);
assert.ok(pyCtx, "should detect Python project");
assert.ok(pyCtx.signals.includes("python"));
assert.equal(pyCtx.pyproject.name, "my-api");
assert.equal(pyCtx.pyproject.testRunner, "pytest");

// ── Go project ─────────────────────────────────────────────────────
setup();
fs.writeFileSync(path.join(testDir, "go.mod"), `module github.com/user/myapp

go 1.22
`);

clearCache();
const goCtx = sniffProjectContext(testDir);
assert.ok(goCtx, "should detect Go project");
assert.ok(goCtx.signals.includes("go"));
assert.equal(goCtx.goMod.module, "github.com/user/myapp");

// ── Docker project ─────────────────────────────────────────────────
setup();
fs.writeFileSync(path.join(testDir, "Dockerfile"), "FROM node:20\n");

clearCache();
const dockerCtx = sniffProjectContext(testDir);
assert.ok(dockerCtx, "should detect Docker project");
assert.ok(dockerCtx.signals.includes("docker"));

// ── Toolchain detection ────────────────────────────────────────────
setup();
fs.writeFileSync(path.join(testDir, ".mise.toml"), "[tools]\nnode = '20'\n");
fs.writeFileSync(path.join(testDir, ".envrc"), "use mise\n");
fs.writeFileSync(path.join(testDir, "package.json"), '{"scripts":{"start":"node ."}}');

clearCache();
const toolchainCtx = sniffProjectContext(testDir);
assert.ok(toolchainCtx.toolchain.includes("mise"));
assert.ok(toolchainCtx.toolchain.includes("direnv"));

// ── Empty directory ────────────────────────────────────────────────
setup();
clearCache();
const emptyCtx = sniffProjectContext(testDir);
assert.equal(emptyCtx, null, "empty directory should return null");

// ── buildProjectBlock with null ────────────────────────────────────
assert.equal(buildProjectBlock(null), "");
assert.equal(buildProjectBlock({ signals: [] }), "");

// ── Cache works ────────────────────────────────────────────────────
setup();
fs.writeFileSync(path.join(testDir, "package.json"), '{"scripts":{"dev":"next dev"}}');
clearCache();
const first = sniffProjectContext(testDir);
// Remove the file — cache should still return same result
fs.unlinkSync(path.join(testDir, "package.json"));
const second = sniffProjectContext(testDir);
assert.deepEqual(first, second, "cache should return same result");

// Cleanup
cleanup();

console.log("project-context tests passed");
