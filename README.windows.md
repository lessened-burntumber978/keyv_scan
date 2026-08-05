# Keyv Supply-Chain Package Scanner for Windows

This is a **native Windows port** of the [keyv_scan](https://github.com/AlextheYounga/keyv_scan) repository. It provides the same functionality for checking whether affected versions from the `keyv` and `cacheable` npm supply-chain compromise (August 4, 2026) are present in a local JavaScript development environment, but runs entirely on Windows using **PowerShell** — no Bash, WSL, or Unix tools required.

## Quick Start

1. **Download/clone** this repository to a local folder
2. **Open PowerShell** and change into the JavaScript project you want to inspect
3. **Run the scanner** using its path:

```powershell
# Using the batch wrapper (recommended - handles execution policy)
C:\path\to\keyv_scan_windows\check_packages.bat

# Or directly with PowerShell
powershell -ExecutionPolicy Bypass -File C:\path\to\keyv_scan_windows\check_packages.ps1
```

An alternate CSV file can be supplied as the first argument:

```powershell
check_packages.bat C:\path\to\custom_packages.csv
```

## Requirements

- **PowerShell 5.1+** (built into Windows 10/11) or **PowerShell 7+**
- **Node.js** (required for package inventory scanning)
- Any package manager you want to check: **npm**, **pnpm**, or **Yarn**

## What It Checks

The scanner checks exact package name and version pairs from `packages.csv`:

| Source | Type | Description |
|--------|------|-------------|
| `node_modules` (current project) | installed | Project dependencies including transitive and pnpm virtual-store packages |
| `.yarn/unplugged` | installed | Yarn Berry unplugged packages |
| npm global dependencies | installed | Globally installed npm packages |
| npm cache | cached | Cached npm package tarballs |
| pnpm global dependencies | installed | Globally installed pnpm packages |
| pnpm store | cached | pnpm content-addressable store |
| Yarn Classic global dependencies | installed | Yarn v1 global packages |
| Yarn Classic cache | cached | Yarn v1 cache |
| Yarn Berry cache | cached | Yarn Berry configured cache directory |
| `.yarn/cache` (current project) | cached | Yarn Berry project cache |

**Note:** The current project is determined by the directory from which the script is run. Run it from each project directory that needs checking. The script does not search the entire filesystem or inspect lockfiles directly.

Package-manager checks are optional. If npm, pnpm, or Yarn is not installed, that manager's checks are skipped. Node.js is required because the script uses it to read package metadata and cache indexes. Missing or failed checks are reported as incomplete rather than as a clean result.

## Results and Exit Codes

**Example clean result:**

```text
Checking affected npm packages from C:\path\to\packages.csv
No affected packages found.
```

**Findings identify the source where a matching version was found:**

```text
FOUND  installed project            keyv@6.0.0
FOUND  cached    pnpm-store         @cacheable/net@2.1.1
```

- `installed` — package metadata was found in an installed dependency tree
- `cached` — an affected artifact remains in a package-manager cache or store; it does not prove that its install lifecycle scripts executed

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | No affected package was found |
| `1` | One or more affected packages were found |
| `2` | The scan could not start, or one or more checks failed and the result is incomplete |

## Incident Summary

According to [Socket's report](https://socket.dev/blog/popular-npm-packages-in-the-keyv-and-cacheable-namespaces-compromised-in-active-supply-chain), compromised package releases contained a malicious npm `preinstall` hook. The reported payload used `setup.mjs` to download a Bun runtime and execute a second stage. Reported capabilities included:

- Collecting AWS, GCP, Azure, Vault, Kubernetes, GitHub, npm, CI, and local secrets
- Republishing trojanized packages using stolen npm credentials
- Exfiltrating collected data through GitHub repositories and DNS-resolved destinations
- Installing persistence on affected hosts
- Planting `.claude` and `.vscode` startup hooks in some repository variants

The affected packages can be **indirect dependencies**. A project may therefore contain a vulnerable package even when it was never listed as a direct dependency.

## If a Match Is Found

Treat a matching installation as a potential compromise, especially if npm install scripts ran on the machine or CI runner.

1. **Stop using** the affected machine or runner for sensitive work and preserve relevant evidence.
2. **Do not assume** that deleting `node_modules` alone is sufficient.
3. **Check for** the reported loader and payload, including `setup.mjs`, `Math_Symbol.js`, `math_init.js`, and `bun-dl-*` temporary directories.
4. **Check for** unexpected `.claude` and `.vscode` startup hooks and reported GitHub token-monitor persistence.
5. **Revoke and rotate** credentials that may have been accessible from the host, including npm, GitHub, cloud, Vault, Kubernetes, and CI credentials.
6. **Audit** npm accounts, GitHub repositories, CI jobs, package publications, and registry activity for unauthorized changes.
7. **Rebuild** dependencies from trusted versions and verify lockfile integrity before returning the machine or runner to service.

Consult the [Socket report](https://socket.dev/blog/popular-npm-packages-in-the-keyv-and-cacheable-namespaces-compromised-in-active-supply-chain) for the current indicators of compromise and the latest affected-version list. This script is a package-presence check, not a malware-removal or full forensic investigation tool.

## Files

| File | Description |
|------|-------------|
| `check_packages.ps1` | PowerShell scanner (main entry point) |
| `check_packages.bat` | Batch wrapper for easy execution from cmd/PowerShell |
| `package_inventory.js` | Exact package metadata and cache scanner (Node.js) |
| `packages.csv` | Package names and affected exact versions |

## Source

The package and version list is sourced from Wiz Research's [`keyv-packages.csv`](https://github.com/wiz-sec-public/wiz-research-iocs/blob/main/reports%2Fkeyv-packages.csv).

Incident details and technical analysis are sourced from Socket Research Team, "Popular npm Packages in the keyv and Cacheable Namespaces Compromised in Active Supply Chain Attack," published August 4, 2026:

<https://socket.dev/blog/popular-npm-packages-in-the-keyv-and-cacheable-namespaces-compromised-in-active-supply-chain>

## Keeping the IOC List Updated

The incident was active when these reports were published, and the affected package list may change. Keep `packages.csv` synchronized with the latest Wiz Research IOC list before relying on a scan:

```powershell
# Download latest from Wiz Research
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/wiz-sec-public/wiz-research-iocs/main/reports/keyv-packages.csv" -OutFile "packages.csv"
```

## Differences from Original (Bash) Version

| Aspect | Original (Bash) | Windows Port (PowerShell) |
|--------|-----------------|---------------------------|
| Shell | Bash 3.2+ | PowerShell 5.1+ / 7+ |
| Temp dir | `mktemp -d` | `[System.IO.Path]::GetTempFileName()` |
| Cleanup | `trap` on EXIT | `Register-EngineEvent PowerShell.Exiting` |
| JSON parsing | `node -e '...'` | `ConvertFrom-Json` |
| Output formatting | `printf` | `Write-Host` with format strings |
| File ops | POSIX utilities | .NET Framework / PowerShell cmdlets |
| Path separators | `/` | `\` (handled automatically) |

The core scanning logic in `package_inventory.js` is **identical** — it's the same Node.js script used by both versions.