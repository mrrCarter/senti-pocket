import fs from "node:fs";
import path from "node:path";

const KEYWORD_REGEX =
  /(token|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|authorization)/i;
const KEY_VALUE_REGEX =
  /(token|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|authorization)[^\\n]{0,40}[:=]\\s*['"]?([A-Za-z0-9/+_.-]{16,})/i;
const JWT_REGEX = /eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}/;
const CANDIDATE_REGEX = /[A-Za-z0-9/+_.-]{32,}/g;

const DEFAULT_MAX_BYTES = 512 * 1024;

function parseArgs() {
  const args = process.argv.slice(2);
  const result = { dir: "omar-artifacts", report: "omar-artifacts/secret-scan.json" };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--path") {
      result.dir = args[i + 1];
      i += 1;
    } else if (arg === "--report") {
      result.report = args[i + 1];
      i += 1;
    } else if (arg === "--max-bytes") {
      result.maxBytes = Number(args[i + 1]);
      i += 1;
    }
  }
  result.maxBytes = Number.isFinite(result.maxBytes) ? result.maxBytes : DEFAULT_MAX_BYTES;
  return result;
}

function listFiles(root) {
  const files = [];
  const queue = [root];
  while (queue.length) {
    const current = queue.pop();
    if (!current || !fs.existsSync(current)) {
      continue;
    }
    const stats = fs.statSync(current);
    if (stats.isDirectory()) {
      const entries = fs.readdirSync(current);
      for (const entry of entries) {
        queue.push(path.join(current, entry));
      }
      continue;
    }
    if (stats.isFile()) {
      files.push(current);
    }
  }
  return files;
}

function shannonEntropy(value) {
  if (!value) return 0;
  const counts = new Map();
  for (const char of value) {
    counts.set(char, (counts.get(char) || 0) + 1);
  }
  let entropy = 0;
  for (const count of counts.values()) {
    const p = count / value.length;
    entropy -= p * Math.log2(p);
  }
  return entropy;
}

function scanContent(content, filePath) {
  const findings = [];
  const lines = content.split(/\r?\n/);
  lines.forEach((line, index) => {
    const lineNumber = index + 1;
    const jwtMatch = line.match(JWT_REGEX);
    if (jwtMatch) {
      findings.push({ file: filePath, line: lineNumber, type: "jwt", match: jwtMatch[0] });
    }
    const kvMatch = line.match(KEY_VALUE_REGEX);
    if (kvMatch) {
      findings.push({ file: filePath, line: lineNumber, type: "key_value", match: kvMatch[0] });
    }
    const candidates = line.match(CANDIDATE_REGEX) || [];
    for (const candidate of candidates) {
      if (!KEYWORD_REGEX.test(line)) {
        continue;
      }
      const entropy = shannonEntropy(candidate);
      if (entropy >= 4.2) {
        findings.push({ file: filePath, line: lineNumber, type: "entropy", match: candidate });
      }
    }
  });
  return findings;
}

function main() {
  const { dir, report, maxBytes } = parseArgs();
  if (!fs.existsSync(dir)) {
    process.exit(0);
  }
  const files = listFiles(dir);
  const findings = [];
  for (const filePath of files) {
    const stats = fs.statSync(filePath);
    if (!stats.isFile()) continue;
    if (stats.size > maxBytes) {
      continue;
    }
    const content = fs.readFileSync(filePath, "utf8");
    findings.push(...scanContent(content, filePath));
  }
  fs.mkdirSync(path.dirname(report), { recursive: true });
  fs.writeFileSync(report, JSON.stringify(findings, null, 2));
  if (findings.length > 0) {
    process.exit(2);
  }
}

main();
