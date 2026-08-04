'use strict';

const fs = require('fs');
const path = require('path');

const [, , csvFile, mode, target] = process.argv;

if (!csvFile || !mode || !target) {
  process.stderr.write('Usage: package_inventory.js <packages.csv> <mode> <path>\n');
  process.exit(2);
}

function loadAffected(file) {
  const affected = new Set();
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);

  for (const line of lines.slice(1)) {
    if (!line.trim()) continue;
    const comma = line.indexOf(',');
    if (comma === -1) continue;

    const packageName = line.slice(0, comma).trim();
    const versions = line.slice(comma + 1);
    for (const match of versions.matchAll(/==\s*([^|,\s]+)/g)) {
      affected.add(`${packageName}\0${match[1]}`);
    }
  }

  return affected;
}

const affected = loadAffected(csvFile);
const findings = new Set();

function record(packageName, version) {
  if (typeof packageName !== 'string' || typeof version !== 'string') return;
  const key = `${packageName}\0${version}`;
  if (affected.has(key)) findings.add(key);
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    // Cache stores can contain arbitrary JSON-like project files. A malformed
    // unrelated file must not make the package scan incomplete.
    if (error instanceof SyntaxError) return null;
    throw new Error(`cannot read ${file}: ${error.message}`);
  }
}

function realDirectory(directory) {
  try {
    const realPath = fs.realpathSync(directory);
    return fs.statSync(realPath).isDirectory() ? realPath : null;
  } catch {
    return null;
  }
}

function scanNodeModules(directory, visited = new Set()) {
  const realPath = realDirectory(directory);
  if (!realPath || visited.has(realPath)) return;
  visited.add(realPath);

  let entries;
  try {
    entries = fs.readdirSync(realPath, { withFileTypes: true });
  } catch (error) {
    throw new Error(`cannot read ${directory}: ${error.message}`);
  }

  for (const entry of entries) {
    if (entry.name === '.bin') continue;
    const entryPath = path.join(realPath, entry.name);

    if (entry.name === '.pnpm') {
      scanPnpmVirtualStore(entryPath, visited);
    } else if (entry.name.startsWith('@')) {
      scanScope(entryPath, visited);
    } else {
      scanPackage(entryPath, visited);
    }
  }
}

function scanScope(directory, visited) {
  const realPath = realDirectory(directory);
  if (!realPath) return;

  let entries;
  try {
    entries = fs.readdirSync(realPath, { withFileTypes: true });
  } catch (error) {
    throw new Error(`cannot read ${directory}: ${error.message}`);
  }

  for (const entry of entries) {
    scanPackage(path.join(realPath, entry.name), visited);
  }
}

function scanPackage(directory, visited) {
  const realPath = realDirectory(directory);
  if (!realPath) return;

  const manifest = readJson(path.join(realPath, 'package.json'));
  if (manifest) record(manifest.name, manifest.version);
  scanNodeModules(path.join(realPath, 'node_modules'), visited);
}

function scanPnpmVirtualStore(directory, visited) {
  const realPath = realDirectory(directory);
  if (!realPath || visited.has(realPath)) return;
  visited.add(realPath);

  let entries;
  try {
    entries = fs.readdirSync(realPath, { withFileTypes: true });
  } catch (error) {
    throw new Error(`cannot read ${directory}: ${error.message}`);
  }

  for (const entry of entries) {
    scanNodeModules(path.join(realPath, entry.name, 'node_modules'), visited);
  }
}

function scanPackageTree(directory) {
  const root = realDirectory(directory);
  if (!root) return;

  const stack = [root];
  const visited = new Set();
  while (stack.length) {
    const current = stack.pop();
    const realPath = realDirectory(current);
    if (!realPath || visited.has(realPath)) continue;
    visited.add(realPath);

    const manifest = readJson(path.join(realPath, 'package.json'));
    if (manifest) record(manifest.name, manifest.version);

    let entries;
    try {
      entries = fs.readdirSync(realPath, { withFileTypes: true });
    } catch (error) {
      throw new Error(`cannot read ${current}: ${error.message}`);
    }
    for (const entry of entries) {
      if (entry.isDirectory() || entry.isSymbolicLink()) {
        stack.push(path.join(realPath, entry.name));
      }
    }
  }
}

function scanNpmCache(file) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    let decoded = line;
    try {
      decoded = decodeURIComponent(line);
    } catch {
      // Keep the original cache key when it is not URL encoded.
    }

    const match = decoded.match(/\/(?:registry\.npmjs\.org\/)?(@[^/]+\/[^/]+|[^/]+)\/-\/([^/?#]+)\.tgz(?:[?#]|$)/);
    if (!match) continue;

    const packageName = match[1];
    const baseName = packageName.slice(packageName.lastIndexOf('/') + 1);
    const prefix = `${baseName}-`;
    if (match[2].startsWith(prefix)) {
      record(packageName, match[2].slice(prefix.length));
    }
  }
}

function inspectMetadata(value, seen = new Set()) {
  if (!value || typeof value !== 'object' || seen.has(value)) return;
  seen.add(value);
  record(value.name, value.version);
  for (const child of Object.values(value)) inspectMetadata(child, seen);
}

function walkFiles(directory, visitor) {
  const root = realDirectory(directory);
  if (!root) return;

  const stack = [root];
  const visited = new Set();
  while (stack.length) {
    const current = stack.pop();
    const realPath = realDirectory(current);
    if (!realPath || visited.has(realPath)) continue;
    visited.add(realPath);

    let entries;
    try {
      entries = fs.readdirSync(realPath, { withFileTypes: true });
    } catch (error) {
      throw new Error(`cannot read ${current}: ${error.message}`);
    }

    for (const entry of entries) {
      const entryPath = path.join(realPath, entry.name);
      if (entry.isDirectory() || entry.isSymbolicLink()) stack.push(entryPath);
      else visitor(entryPath, entry.name);
    }
  }
}

function scanPnpmStore(directory) {
  walkFiles(directory, (file, name) => {
    if (!name.endsWith('.json')) return;
    const metadata = readJson(file);
    if (metadata) inspectMetadata(metadata);

    for (const key of affected) {
      const [packageName, version] = key.split('\0');
      const storeName = packageName.replace('/', '+');
      if (name.endsWith(`-${storeName}@${version}.json`)) {
        record(packageName, version);
      }
    }
  });
}

function scanYarnCache(directory) {
  walkFiles(directory, (file, name) => {
    if (name === 'package.json') {
      const manifest = readJson(file);
      if (manifest) record(manifest.name, manifest.version);
      return;
    }

    if (!name.endsWith('.zip')) return;
    for (const key of affected) {
      const [packageName, version] = key.split('\0');
      const archivePrefix = `${packageName.replace('/', '-')}-npm-${version}-`;
      if (name.startsWith(archivePrefix)) record(packageName, version);
    }
  });
}

try {
  switch (mode) {
    case 'node-modules':
      scanNodeModules(target);
      break;
    case 'package-tree':
      scanPackageTree(target);
      break;
    case 'npm-cache':
      scanNpmCache(target);
      break;
    case 'pnpm-store':
      scanPnpmStore(target);
      break;
    case 'yarn-cache':
      scanYarnCache(target);
      break;
    default:
      throw new Error(`unknown scan mode: ${mode}`);
  }

  for (const key of [...findings].sort()) {
    process.stdout.write(`${key.replace('\0', '\t')}\n`);
  }
} catch (error) {
  process.stderr.write(`Inventory error: ${error.message}\n`);
  process.exit(2);
}
