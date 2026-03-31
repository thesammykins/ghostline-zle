import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { rankCommandCandidates } from "../logic.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const casesPath = path.join(__dirname, "golden-cases.json");

const raw = fs.readFileSync(casesPath, "utf8");
const cases = JSON.parse(raw);

let failed = 0;

for (const testCase of cases) {
  const result = rankCommandCandidates({
    rawCommand: testCase.rawCommand,
    aliasContext: testCase.aliasContext,
    intentMode: testCase.intentMode,
    userPrompt: testCase.prompt,
  });

  if (result.command !== testCase.expectedTop) {
    failed += 1;
    process.stderr.write(
      `[FAIL] ${testCase.name}: expected '${testCase.expectedTop}', got '${result.command}'\n`
    );
  } else {
    process.stdout.write(`[PASS] ${testCase.name}\n`);
  }
}

if (failed > 0) {
  process.stderr.write(`Golden tests failed: ${failed}\n`);
  process.exit(1);
}

process.stdout.write("Golden tests passed.\n");
