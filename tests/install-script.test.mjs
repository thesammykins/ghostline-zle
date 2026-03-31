import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const testDir = path.dirname(fileURLToPath(import.meta.url));
const repoDir = path.resolve(testDir, "..");
const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), "ghostline-install-test-"));
const zshrcPath = path.join(homeDir, ".zshrc");

const runInstaller = () =>
  spawnSync("bash", ["./scripts/install.sh", "--skip-npm", "--write-zshrc"], {
    cwd: repoDir,
    env: { ...process.env, HOME: homeDir, ZDOTDIR: homeDir },
    encoding: "utf8",
  });

const first = runInstaller();
assert.equal(first.status, 0, first.stderr || first.stdout);
assert.ok(fs.existsSync(zshrcPath), "installer should create .zshrc");

const firstContent = fs.readFileSync(zshrcPath, "utf8");
assert.match(firstContent, /# >>> ghostline-zle \(ghostty\) >>>/);
assert.match(firstContent, /source ".*\/ghostline-zle\.zsh"/);

const second = runInstaller();
assert.equal(second.status, 0, second.stderr || second.stdout);

const secondContent = fs.readFileSync(zshrcPath, "utf8");
const matchCount = (secondContent.match(/# >>> ghostline-zle \(ghostty\) >>>/g) || []).length;
assert.equal(matchCount, 1, "installer should not duplicate the zshrc block");

fs.rmSync(homeDir, { recursive: true, force: true });

console.log("install script tests passed");
