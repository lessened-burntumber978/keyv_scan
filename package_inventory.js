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

function walkFiles(directory, visitor, skipDirectory) {
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
      if (entry.isDirectory() || entry.isSymbolicLink()) {
        if (!skipDirectory || !skipDirectory(entry.name)) stack.push(entryPath);
      } else visitor(entryPath, entry.name);
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

// Lockfiles pin exact versions, so an affected release can be recorded in a
// project that has not installed its dependencies yet. Nothing is present on
// disk to find, but the next install resolves to the affected version.
function scanNpmLockfile(file) {
  const lockfile = readJson(file);
  if (!lockfile) return;

  // lockfileVersion 2 and 3 key every package by its install path.
  for (const [installPath, meta] of Object.entries(lockfile.packages || {})) {
    if (!meta || typeof meta !== 'object' || typeof meta.version !== 'string') continue;
    const marker = 'node_modules/';
    const index = installPath.lastIndexOf(marker);
    const name = meta.name || (index === -1 ? '' : installPath.slice(index + marker.length));
    record(name, meta.version);
  }

  // lockfileVersion 1 nests dependencies instead.
  (function walkDependencies(dependencies) {
    for (const [name, meta] of Object.entries(dependencies || {})) {
      if (!meta || typeof meta !== 'object') continue;
      record(name, meta.version);
      walkDependencies(meta.dependencies);
    }
  })(lockfile.dependencies);
}

// Accepts every pnpm and Yarn Berry descriptor shape seen in the wild:
// name@1.2.3, @scope/name@1.2.3, /name/1.2.3, /@scope/name/1.2.3, and any of
// those carrying a (peer@1.0.0) suffix or an npm: protocol prefix.
function parseDescriptor(descriptor) {
  let token = descriptor.trim().replace(/\(.*$/, '');
  if (token.startsWith('/')) token = token.slice(1);
  token = token.replace(/@npm(?::|%3A)/i, '@');

  const at = token.lastIndexOf('@');
  if (at > 0) {
    const version = token.slice(at + 1);
    if (/^\d/.test(version)) return [token.slice(0, at), version];
  }

  const slash = token.lastIndexOf('/');
  if (slash > 0 && /^\d/.test(token.slice(slash + 1))) {
    return [token.slice(0, slash), token.slice(slash + 1)];
  }

  return null;
}

function scanPnpmLockfile(file) {
  const text = fs.readFileSync(file, 'utf8');
  // Entry keys are the only indented, colon-terminated lines that carry a
  // version, across lockfile versions 5 through 9.
  for (const [, descriptor] of text.matchAll(/^\s{2,}'?([^'\s#][^'\n]*?)'?:\s*$/gm)) {
    const parsed = parseDescriptor(descriptor);
    if (parsed) record(parsed[0], parsed[1]);
  }
}

function scanYarnLockfile(file) {
  const text = fs.readFileSync(file, 'utf8');
  let names = [];

  for (const line of text.split(/\r?\n/)) {
    if (!line.trim() || line.trimStart().startsWith('#')) continue;

    // A descriptor header is unindented; one header can list several ranges.
    if (!/^\s/.test(line) && line.trimEnd().endsWith(':')) {
      names = line
        .trimEnd()
        .slice(0, -1)
        .split(',')
        .map((entry) => {
          const token = entry.trim().replace(/^"|"$/g, '');
          const at = token.lastIndexOf('@');
          return at > 0 ? token.slice(0, at) : token;
        })
        .filter(Boolean);
      continue;
    }

    // Yarn Classic quotes the version, Yarn Berry does not.
    const match = line.match(/^\s+version:?\s+"?([^"\s]+)"?\s*$/);
    if (match) for (const name of names) record(name, match[1]);
  }
}

function scanLockfiles(directory) {
  walkFiles(
    directory,
    (file, name) => {
      if (name === 'package-lock.json' || name === 'npm-shrinkwrap.json') scanNpmLockfile(file);
      else if (name === 'pnpm-lock.yaml') scanPnpmLockfile(file);
      else if (name === 'yarn.lock') scanYarnLockfile(file);
    },
    // Lockfiles vendored inside a dependency describe that dependency's own
    // development tree, not what this project installs. The installed tree is
    // already covered by the node-modules mode.
    (name) => name === 'node_modules' || name === '.git'
  );
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
    case 'lockfiles':
      scanLockfiles(target);
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
