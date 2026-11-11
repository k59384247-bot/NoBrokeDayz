import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const destination = resolve(root, "docs/phase-4-source-manifest.sha256");
const excluded = new Set([
  "docs/phase-4-evidence.md",
  "docs/phase-4-source-manifest.sha256",
]);
const ignoredDirectories = new Set([
  ".git",
  ".supabase-home",
  ".wrangler",
  "coverage",
  "dist",
  "node_modules",
]);
const includedRoots = [
  ".env.example",
  ".gitignore",
  ".nvmrc",
  "AGENTS.md",
  "README.md",
  ".github",
  "app",
  "cloudflare.config.ts",
  "docs",
  "lib",
  "package-lock.json",
  "package.json",
  "public",
  "scripts",
  "spec.md",
  "supabase",
  "tests",
  "tsconfig.json",
  "vite.config.ts",
];

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function collect(path, files) {
  if (path.split("/").at(-1) === ".DS_Store") return;
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) return;
  if (stat.isDirectory()) {
    if (ignoredDirectories.has(relative(root, path).split("/").at(-1))) return;
    for (const name of readdirSync(path).sort()) {
      if (
        name === ".env" ||
        (name.startsWith(".env.") && name !== ".env.example")
      )
        continue;
      collect(join(path, name), files);
    }
    return;
  }
  const name = relative(root, path).split("\\").join("/");
  if (
    excluded.has(name) ||
    name.endsWith(".log") ||
    name.endsWith(".tsbuildinfo")
  )
    return;
  files.push(name);
}

const files = [];
for (const entry of includedRoots) collect(resolve(root, entry), files);
files.sort();
const rows = files.map(
  (name) => `${sha256(readFileSync(resolve(root, name)))}  ${name}`,
);
const contents = `${rows.join("\n")}\n`;
const digest = sha256(contents);
writeFileSync(destination, `# Manifest SHA-256 ${digest}\n${contents}`);
console.log(`Source manifest files: ${files.length}`);
console.log(`Source manifest SHA-256: ${digest}`);
