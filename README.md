# Keyv Supply-Chain Package Scanner

This repository contains a Bash script for checking whether affected versions
from the `keyv` and `cacheable` npm supply-chain compromise are present in a
local JavaScript development environment.

The package and version list is maintained in [`packages.csv`](packages.csv).
The list is based on Socket's ongoing incident report:

<https://socket.dev/blog/popular-npm-packages-in-the-keyv-and-cacheable-namespaces-compromised-in-active-supply-chain>

## Run the scan

Requirements:

- Bash
- Node.js
- Any package manager you want to check: npm, pnpm, or Yarn

From this directory, run:

```bash
./check_packages.sh
```

An alternate CSV file can be supplied as the first argument:

```bash
./check_packages.sh /path/to/packages.csv
```

The script does not install, update, or remove packages.

## What it checks

The scanner checks exact package name and version pairs from `packages.csv`.

- npm dependencies in the current directory
- Globally installed npm dependencies
- The npm cache
- pnpm dependencies in the current directory
- Globally installed pnpm dependencies
- The pnpm content-addressable store
- The Yarn cache

The current project is determined by the directory from which the script is
run. Run it from each project directory that needs checking. The script does
not search the entire filesystem or inspect every lockfile directly.

Package-manager checks are optional. If npm, pnpm, or Yarn is not installed,
that manager's checks are skipped. Node.js is required because the script uses
it to parse dependency-tree JSON output.

## Results and exit codes

Example clean result:

```text
Checking affected npm packages from .../packages.csv
No affected packages found.
```

Findings identify the source where a matching version was found:

```text
FOUND  project  keyv@6.0.0
FOUND  cache    cacheable@2.5.1
FOUND  pnpm-store @cacheable/net@2.1.1
```

Exit codes:

- `0`: no affected package was found
- `1`: one or more affected packages were found
- `2`: the scan could not start, for example because the CSV or Node.js is missing

## Incident summary

According to Socket's report, compromised package releases contained a
malicious npm `preinstall` hook. The reported payload used `setup.mjs` to
download a Bun runtime and execute a second stage. Reported capabilities
included:

- Collecting AWS, GCP, Azure, Vault, Kubernetes, GitHub, npm, CI, and local secrets
- Republishing trojanized packages using stolen npm credentials
- Exfiltrating collected data through GitHub repositories and DNS-resolved destinations
- Installing persistence on affected hosts
- Planting `.claude` and `.vscode` startup hooks in some repository variants

The affected packages can be indirect dependencies. A project may therefore
contain a vulnerable package even when it was never listed as a direct
dependency.

The incident was active when Socket published its report, and the affected
package list may change. Keep [`packages.csv`](packages.csv) synchronized with
the latest authoritative incident information before relying on a scan.

## If a match is found

Treat a matching installation as a potential compromise, especially if npm
install scripts ran on the machine or CI runner.

1. Stop using the affected machine or runner for sensitive work and preserve relevant evidence.
2. Do not assume that deleting `node_modules` alone is sufficient.
3. Check for the reported loader and payload, including `setup.mjs`, `Math_Symbol.js`, `math_init.js`, and `bun-dl-*` temporary directories.
4. Check for unexpected `.claude` and `.vscode` startup hooks and reported GitHub token-monitor persistence.
5. Revoke and rotate credentials that may have been accessible from the host, including npm, GitHub, cloud, Vault, Kubernetes, and CI credentials.
6. Audit npm accounts, GitHub repositories, CI jobs, package publications, and registry activity for unauthorized changes.
7. Rebuild dependencies from trusted versions and verify lockfile integrity before returning the machine or runner to service.

Consult the Socket report for the current indicators of compromise and the
latest affected-version list. This script is a package-presence check, not a
malware-removal or full forensic investigation tool.

## Files

- [`check_packages.sh`](check_packages.sh): Bash scanner
- [`packages.csv`](packages.csv): package names and affected exact versions

## Source

Incident details and indicators are sourced from Socket Research Team,
"Popular npm Packages in the keyv and Cacheable Namespaces Compromised in
Active Supply Chain Attack," published August 4, 2026:

<https://socket.dev/blog/popular-npm-packages-in-the-keyv-and-cacheable-namespaces-compromised-in-active-supply-chain>
