import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoDir = path.dirname(scriptDir);
const sessionFile = path.join(repoDir, "node_modules/@github/copilot-sdk/dist/session.js");
const brokenImport = 'from "vscode-jsonrpc/node"';
const fixedImport = 'from "vscode-jsonrpc/node.js"';

if (!fs.existsSync(sessionFile)) {
  console.log("copilot-sdk session.js not present; skipping patch");
  process.exit(0);
}

const source = fs.readFileSync(sessionFile, "utf8");
if (!source.includes(brokenImport)) {
  console.log("copilot-sdk import already patched");
  process.exit(0);
}

fs.writeFileSync(sessionFile, source.replace(brokenImport, fixedImport));
console.log("patched copilot-sdk vscode-jsonrpc import");
