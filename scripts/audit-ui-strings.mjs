import fs from "node:fs";
import path from "node:path";

const projectRoot = path.resolve(import.meta.dirname, "..");
const sourceRoot = path.join(projectRoot, "boringNotch");
const catalogPath = path.join(sourceRoot, "Localizable.xcstrings");
const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
const localizedKeys = new Set(Object.keys(catalog.strings ?? {}));

const patterns = [
  /\b(?:Text|Label|Button|Toggle|Picker|Section|GroupBox|Link)\s*\(\s*"((?:\\.|[^"\\])*)"/g,
  /\.(?:navigationTitle|help|accessibilityLabel|alert|confirmationDialog)\s*\(\s*"((?:\\.|[^"\\])*)"/g,
  /\bNSMenuItem\s*\(\s*title:\s*"((?:\\.|[^"\\])*)"/g,
  /\b(?:messageText|informativeText|title|prompt|nameFieldLabel|nameFieldStringValue)\s*=\s*"((?:\\.|[^"\\])*)"/g,
  /\b(?:showErrorAlert|showAlert)\s*\(\s*title:\s*"((?:\\.|[^"\\])*)"/g,
];

function walk(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const itemPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return walk(itemPath);
    return entry.isFile() && entry.name.endsWith(".swift") ? [itemPath] : [];
  });
}

function lineNumber(text, index) {
  return text.slice(0, index).split("\n").length;
}

const findings = [];
for (const file of walk(sourceRoot)) {
  const text = fs.readFileSync(file, "utf8");
  for (const pattern of patterns) {
    pattern.lastIndex = 0;
    for (const match of text.matchAll(pattern)) {
      const value = match[1];
      const before = text.slice(Math.max(0, match.index - 160), match.index);
      if (before.split("\n").at(-1)?.trimStart().startsWith("//")) continue;
      if (!/[A-Za-z]/.test(value)) continue;
      if (localizedKeys.has(value)) continue;
      if (/^(https?:|[a-z0-9_.-]+\.[a-z]{2,}|[a-z0-9_.-]+)$/i.test(value)) continue;
      if (/^[a-z0-9_.-]+$/i.test(value) && !value.includes(" ")) continue;
      findings.push({
        file: path.relative(projectRoot, file),
        line: lineNumber(text, match.index),
        value,
      });
    }
  }
}

const unique = [...new Map(findings.map((item) => [`${item.file}:${item.line}:${item.value}`, item])).values()];
for (const item of unique) {
  console.log(`${item.file}:${item.line}\t${item.value}`);
}
console.error(`Missing catalog or direct Chinese coverage: ${unique.length}`);
