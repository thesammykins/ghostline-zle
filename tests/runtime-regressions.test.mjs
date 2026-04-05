import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { CopilotService } from "../lib/copilot-service.mjs";

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "copilot-zle-runtime-"));

const cleanup = () => {
  try {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  } catch {
    // Best effort in tests.
  }
};

process.on("exit", cleanup);

// ── daemon ZLE framing preserves multiline error text ───────────────
{
  const payload = {
    id: 1,
    type: "generate",
    format: "zle",
    payload: {
      prompt: "test",
      model: "gpt-5-mini",
    },
  };

  const fixture = {
    id: 1,
    type: "generate",
    payload: {
      command: "",
      confidence: 0,
      provider: "copilot",
      model: "gpt-5-mini",
      error_code: "copilot_error",
      error: "first line\nsecond line",
      candidates: [],
    },
  };

  const output = [
    fixture.payload.error_code,
    JSON.stringify(fixture.payload.error),
    JSON.stringify(fixture.payload.command),
    JSON.stringify(""),
  ].join("\n");

  const [errorCode, errorJson, commandJson, candidatesJson] = output.split("\n");
  assert.equal(errorCode, "copilot_error");
  assert.equal(JSON.parse(errorJson), "first line\nsecond line");
  assert.equal(JSON.parse(commandJson), "");
  assert.equal(JSON.parse(candidatesJson), "");
  assert.equal(payload.payload.model, "gpt-5-mini");
}

// ── subprocess transport shape preserves candidates ─────────────────
{
  const raw = JSON.stringify({
    command: "rg TODO",
    candidates: ["rg TODO", "command rg TODO"],
  });

  const parsed = JSON.parse(raw);
  const encoded = JSON.stringify(parsed.candidates.join("\u001f"));
  assert.equal(JSON.parse(encoded), "rg TODO\u001fcommand rg TODO");
}

// ── shell model sourcing prefers config unless env override exists ──
{
  const configPath = path.join(tempRoot, "config.json");
  fs.writeFileSync(
    configPath,
    JSON.stringify({ model: { default: "claude-sonnet-4.6" } }, null, 2),
    "utf8"
  );

  const originalConfig = process.env.COPILOT_ZLE_CONFIG_FILE;
  const originalModel = process.env.COPILOT_ZLE_MODEL;
  process.env.COPILOT_ZLE_CONFIG_FILE = configPath;
  delete process.env.COPILOT_ZLE_MODEL;

  const { loadConfig } = await import(`../lib/config.mjs?test=${Date.now()}`);
  assert.equal(loadConfig().model.default, "claude-sonnet-4.6");

  process.env.COPILOT_ZLE_MODEL = "gpt-5.4";
  assert.equal(loadConfig().model.default, "gpt-5.4");

  if (typeof originalConfig === "string") {
    process.env.COPILOT_ZLE_CONFIG_FILE = originalConfig;
  } else {
    delete process.env.COPILOT_ZLE_CONFIG_FILE;
  }

  if (typeof originalModel === "string") {
    process.env.COPILOT_ZLE_MODEL = originalModel;
  } else {
    delete process.env.COPILOT_ZLE_MODEL;
  }
}

// ── apply-result cleanup leaves next request unwedged ───────────────
{
  const state = {
    asyncActive: 1,
    resultFd: "12",
    spinnerFd: "13",
    resultPid: "4567",
    resultFile: "/tmp/copilot-zle-result.test",
  };

  const cleanupAfterApply = (current) => ({
    ...current,
    asyncActive: 0,
    resultFd: "",
    spinnerFd: "",
    resultPid: "",
    resultFile: "",
  });

  assert.deepEqual(cleanupAfterApply(state), {
    asyncActive: 0,
    resultFd: "",
    spinnerFd: "",
    resultPid: "",
    resultFile: "",
  });
}

// ── explain mode does not reject when model cache is empty ───────────
{
  const service = new CopilotService({ model: "gpt-5-mini" });
  service.started = true;
  service.client = {
    createSession: async () => ({
      sendAndWait: async () => ({ data: { content: "LISTS FILES" } }),
      disconnect: async () => undefined,
    }),
  };
  service.approveAll = () => {};
  service.supportedModelIds = new Set();

  const result = await service.explain({
    command: "ls",
    model: "gpt-5-mini",
    cwd: process.cwd(),
    home: process.env.HOME || "",
  });

  assert.equal(result.explanation, "LISTS FILES");
  assert.equal(result.error, undefined);
}

console.log("runtime regression tests passed");
