# Keyv Supply-Chain Package Scanner

This repository contains a Bash script for checking whether affected versions
from the `keyv` and `cacheable` npm supply-chain compromise are present in a
local JavaScript development environment.

The package and version list in [`packages.csv`](packages.csv) is a local copy
of Wiz Research's published IOC list:

<https://github.com/wiz-sec-public/wiz-research-iocs/blob/main/reports%2Fkeyv-packages.csv>

Incident background and technical analysis are documented in Socket's ongoing
incident report:

<https://socket.dev/blog/popular-npm-packages-in-the-keyv-and-cacheable-namespaces-compromised-in-active-supply-chain>

## Quick Start

1. Clone or download this repository.
2. Change into the JavaScript project you want to inspect.
3. Run the scanner using its path:

```bash
/path/to/keyv_scan/check_packages.sh
```

The script uses the repository's `packages.csv` by default. A clean scan ends
with `No affected packages found.` and exit code `0`. A matching package exits
with code `1`; an incomplete scan exits with code `2`.

## Run the scan

Requirements:

- Bash
- Node.js
- Any package manager you want to check: npm, pnpm, or Yarn

The script uses Bash features available in Bash 3.2 and later.

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

- Packages installed under `node_modules` in the current directory, including
  transitive and pnpm virtual-store packages
- Globally installed npm dependencies
- The npm cache
- Packages in the current `.yarn/unplugged` directory
- Globally installed pnpm dependencies
- The pnpm content-addressable store
- Globally installed Yarn Classic dependencies
- Yarn Classic's cache
- Yarn Berry's configured cache directory
- The current project's `.yarn/cache` directory
- Lockfiles in the current project: `package-lock.json`, `npm-shrinkwrap.json`,
  `pnpm-lock.yaml`, and `yarn.lock`

The current project is determined by the directory from which the script is
run. Run it from each project directory that needs checking. The script does
not search the entire filesystem.

Lockfiles are scanned because they pin exact versions whether or not anything
is installed. A checkout that has never run an install has nothing on disk to
find, but resolves to the affected release the next time it does. This matters
most on CI runners and freshly cloned repositories. Lockfiles vendored inside
`node_modules` are skipped: they describe a dependency's own development tree
rather than what this project installs.

Package-manager checks are optional. If npm, pnpm, or Yarn is not installed,
that manager's checks are skipped. Node.js is required because the script uses
it to read package metadata and cache indexes. Missing or failed checks are
reported as incomplete rather than as a clean result.

## Results and exit codes

Example clean result:

```text
Checking affected npm packages from .../packages.csv
No affected packages found.
```

Findings identify the source where a matching version was found:

```text
FOUND  installed project            keyv@6.0.0
FOUND  cached    pnpm-store         @cacheable/net@2.1.1
FOUND  pinned    project-lockfiles  keyv@6.0.0
```

`installed` means package metadata was found in an installed dependency tree.
`cached` means an affected artifact remains in a package-manager cache or
store; it does not prove that its install lifecycle scripts executed.
`pinned` means a lockfile resolves to an affected version; the package may
never have been installed, but an install from this lockfile would fetch it.

Exit codes:

- `0`: no affected package was found
- `1`: one or more affected packages were found
- `2`: the scan could not start, or one or more checks failed and the result is incomplete

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

The incident was active when these reports were published, and the affected
package list may change. Keep [`packages.csv`](packages.csv) synchronized with
the latest Wiz Research IOC list before relying on a scan.

## If a match is found

Treat a matching installation as a potential compromise, especially if npm
install scripts ran on the machine or CI runner.

A `pinned` finding with no matching `installed` or `cached` entry is different:
the affected version was never fetched on this machine, so the steps below do
not apply. Update the lockfile off the affected version before installing from
it again, and check any CI runner that may already have installed it.

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
- [`package_inventory.js`](package_inventory.js): exact package metadata, cache, and lockfile scanner
- [`packages.csv`](packages.csv): package names and affected exact versions
- [`test_lockfiles.sh`](test_lockfiles.sh): fixture tests for the lockfile parsers

Run the tests with `./test_lockfiles.sh`. They use their own fixture package
list, so they neither depend on nor validate the live `packages.csv`.

## Source

The package and version list is sourced from Wiz Research's
[`keyv-packages.csv`](https://github.com/wiz-sec-public/wiz-research-iocs/blob/main/reports%2Fkeyv-packages.csv).

Incident details and technical analysis are sourced from Socket Research Team,
"Popular npm Packages in the keyv and Cacheable Namespaces Compromised in
Active Supply Chain Attack," published August 4, 2026:

<https://socket.dev/blog/popular-npm-packages-in-the-keyv-and-cacheable-namespaces-compromised-in-active-supply-chain>
