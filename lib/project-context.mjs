import fs from "node:fs";
import path from "node:path";

const MAX_READ_BYTES = 2048;

const safeReadHead = (filePath, maxBytes = MAX_READ_BYTES) => {
  try {
    const fd = fs.openSync(filePath, "r");
    const buf = Buffer.alloc(maxBytes);
    const bytesRead = fs.readSync(fd, buf, 0, maxBytes, 0);
    fs.closeSync(fd);
    return buf.subarray(0, bytesRead).toString("utf8");
  } catch {
    return "";
  }
};

const extractJsonScripts = (filePath) => {
  const content = safeReadHead(filePath, 4096);
  if (!content) return [];
  try {
    const pkg = JSON.parse(content);
    if (pkg.scripts && typeof pkg.scripts === "object") {
      return Object.keys(pkg.scripts).slice(0, 20);
    }
  } catch {
    // Partial JSON — try regex extraction
    const match = content.match(/"scripts"\s*:\s*\{([^}]+)\}/);
    if (match) {
      const keys = [...match[1].matchAll(/"([^"]+)"\s*:/g)].map((m) => m[1]);
      return keys.slice(0, 20);
    }
  }
  return [];
};

const extractMakefileTargets = (filePath) => {
  const content = safeReadHead(filePath);
  if (!content) return [];
  const targets = [];
  for (const line of content.split("\n")) {
    const match = line.match(/^([a-zA-Z_][\w-]*)\s*:/);
    if (match && !match[1].startsWith("_")) {
      targets.push(match[1]);
    }
  }
  return [...new Set(targets)].slice(0, 20);
};

const extractCargoInfo = (filePath) => {
  const content = safeReadHead(filePath);
  if (!content) return null;
  const nameMatch = content.match(/name\s*=\s*"([^"]+)"/);
  return { lang: "rust", name: nameMatch?.[1] || "unknown" };
};

const extractPyprojectInfo = (filePath) => {
  const content = safeReadHead(filePath);
  if (!content) return null;
  const nameMatch = content.match(/name\s*=\s*"([^"]+)"/);
  const hasPytest = content.includes("pytest");
  return {
    lang: "python",
    name: nameMatch?.[1] || "unknown",
    testRunner: hasPytest ? "pytest" : null,
  };
};

const extractGoModInfo = (filePath) => {
  const content = safeReadHead(filePath);
  if (!content) return null;
  const moduleMatch = content.match(/module\s+(\S+)/);
  return { lang: "go", module: moduleMatch?.[1] || "unknown" };
};

const detectToolchain = (cwd) => {
  const indicators = [];
  const check = (name) => fs.existsSync(path.join(cwd, name));

  if (check(".mise.toml") || check(".mise/config.toml")) indicators.push("mise");
  if (check(".tool-versions")) indicators.push("asdf/mise");
  if (check(".envrc")) indicators.push("direnv");
  if (check(".nvmrc")) indicators.push("nvm");
  if (check(".python-version")) indicators.push("pyenv");
  if (check(".ruby-version")) indicators.push("rbenv");

  return indicators;
};

// Per-session cache keyed by cwd
const cache = new Map();

export const sniffProjectContext = (cwd) => {
  if (!cwd || typeof cwd !== "string") return null;

  const cached = cache.get(cwd);
  if (cached) return cached;

  const result = { signals: [] };

  // package.json
  const pkgPath = path.join(cwd, "package.json");
  if (fs.existsSync(pkgPath)) {
    const scripts = extractJsonScripts(pkgPath);
    if (scripts.length > 0) {
      result.scripts = scripts;
      result.signals.push("node/npm");
    }
  }

  // Makefile / Justfile
  for (const name of ["Makefile", "GNUmakefile", "makefile"]) {
    const makePath = path.join(cwd, name);
    if (fs.existsSync(makePath)) {
      const targets = extractMakefileTargets(makePath);
      if (targets.length > 0) {
        result.makeTargets = targets;
        result.signals.push("make");
      }
      break;
    }
  }

  const justPath = path.join(cwd, "Justfile");
  if (!result.makeTargets && fs.existsSync(justPath)) {
    const targets = extractMakefileTargets(justPath);
    if (targets.length > 0) {
      result.makeTargets = targets;
      result.signals.push("just");
    }
  }

  // Cargo.toml
  const cargoPath = path.join(cwd, "Cargo.toml");
  if (fs.existsSync(cargoPath)) {
    result.cargo = extractCargoInfo(cargoPath);
    result.signals.push("rust/cargo");
  }

  // pyproject.toml
  const pyprojectPath = path.join(cwd, "pyproject.toml");
  if (fs.existsSync(pyprojectPath)) {
    result.pyproject = extractPyprojectInfo(pyprojectPath);
    result.signals.push("python");
  }

  // go.mod
  const goModPath = path.join(cwd, "go.mod");
  if (fs.existsSync(goModPath)) {
    result.goMod = extractGoModInfo(goModPath);
    result.signals.push("go");
  }

  // Docker
  if (fs.existsSync(path.join(cwd, "Dockerfile")) || fs.existsSync(path.join(cwd, "docker-compose.yml")) || fs.existsSync(path.join(cwd, "compose.yml"))) {
    result.signals.push("docker");
  }

  // Toolchain
  const toolchain = detectToolchain(cwd);
  if (toolchain.length > 0) {
    result.toolchain = toolchain;
  }

  if (result.signals.length === 0) {
    cache.set(cwd, null);
    return null;
  }

  cache.set(cwd, result);
  return result;
};

export const buildProjectBlock = (ctx) => {
  if (!ctx || ctx.signals.length === 0) return "";

  const parts = [`PROJECT TYPE: ${ctx.signals.join(", ")}`];

  if (ctx.scripts) {
    parts.push(`NPM SCRIPTS: ${ctx.scripts.join(", ")}`);
  }
  if (ctx.makeTargets) {
    parts.push(`MAKE TARGETS: ${ctx.makeTargets.join(", ")}`);
  }
  if (ctx.cargo) {
    parts.push(`CARGO PROJECT: ${ctx.cargo.name}`);
  }
  if (ctx.pyproject) {
    let line = `PYTHON PROJECT: ${ctx.pyproject.name}`;
    if (ctx.pyproject.testRunner) line += ` (test: ${ctx.pyproject.testRunner})`;
    parts.push(line);
  }
  if (ctx.goMod) {
    parts.push(`GO MODULE: ${ctx.goMod.module}`);
  }
  if (ctx.toolchain) {
    parts.push(`TOOLCHAIN: ${ctx.toolchain.join(", ")}`);
  }

  return `\nPROJECT:\n${parts.join("\n")}`;
};

export const clearCache = () => cache.clear();
