import assert from "node:assert/strict";
import { parseAliasContext } from "../lib/logic.mjs";
import { resolvePatternCommand } from "../lib/patterns.mjs";

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

// ── patterns resolve deterministic file-list prompts ─────────────────
{
  assert.equal(
    resolvePatternCommand({
      prompt: "show me all files in ~/.dotfiles",
      mode: "generate",
      home: "/Users/sammykins",
      dotfiles: "/Users/sammykins/.dotfiles",
      cwd: "/Users/sammykins/Development/copilot-zle",
    }),
    'command find "/Users/sammykins/.dotfiles" -type f -print | sed "s:^$HOME:~:" | sort'
  );
}

// ── patterns resolve simple local file list here ─────────────────────
{
  assert.equal(
    resolvePatternCommand({
      prompt: "list all files here",
      mode: "generate",
      home: "/Users/sammykins",
      dotfiles: "/Users/sammykins/.dotfiles",
      cwd: "/Users/sammykins/Development/copilot-zle",
    }),
    'command find "/Users/sammykins/Development/copilot-zle" -type f -print | sed "s:^$HOME:~:" | sort'
  );
}
