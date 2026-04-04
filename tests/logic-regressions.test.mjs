import assert from "node:assert/strict";
import { parseAliasContext } from "../lib/logic.mjs";

// ── alias parsing accepts shell alias output ────────────────────────
{
  const aliases = [
    "alias ls='eza --group-directories-first'",
    "alias grep='rg'",
    "alias du='dust'",
  ].join("\n");

  assert.deepEqual(parseAliasContext(aliases), {
    ls: "eza --group-directories-first",
    grep: "rg",
    du: "dust",
  });
}

// ── alias parsing still accepts legacy semicolon format ─────────────
{
  const aliases = "ls=eza --icons;grep=rg";
  assert.deepEqual(parseAliasContext(aliases), {
    ls: "eza --icons",
    grep: "rg",
  });
}

console.log("logic regression tests passed");
