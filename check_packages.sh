#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(dirname -- "$0")
SCRIPT_DIR=$(cd -- "$SCRIPT_DIR" && pwd -P)
CSV_FILE=${1:-"$SCRIPT_DIR/packages.csv"}
INVENTORY_SCRIPT="$SCRIPT_DIR/package_inventory.js"

if [[ ! -r "$CSV_FILE" ]]; then
	printf 'Error: cannot read package list: %s\n' "$CSV_FILE" >&2
	exit 2
fi

if [[ ! -r "$INVENTORY_SCRIPT" ]]; then
	printf 'Error: cannot read inventory helper: %s\n' "$INVENTORY_SCRIPT" >&2
	exit 2
fi

if ! command -v node >/dev/null 2>&1; then
	printf 'Error: node is required but was not found in PATH.\n' >&2
	exit 2
fi

TEMP_DIR=$(mktemp -d) || {
	printf 'Error: could not create a temporary directory.\n' >&2
	exit 2
}
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

FINDINGS_FILE="$TEMP_DIR/findings.tsv"
: >"$FINDINGS_FILE"
scan_failures=0
manager_count=0

warn_scan_failed() {
	printf 'Warning: %s could not be checked; results are incomplete.\n' "$1" >&2
	scan_failures=$((scan_failures + 1))
}

scan_path() {
	local source=$1 kind=$2 mode=$3 path=$4 output_file
	output_file="$TEMP_DIR/output.tsv"

	if ! node "$INVENTORY_SCRIPT" "$CSV_FILE" "$mode" "$path" >"$output_file"; then
		warn_scan_failed "$source"
		return
	fi

	while IFS=$'\t' read -r package version; do
		[[ -n "$package" && -n "$version" ]] || continue
		printf '%s\t%s\t%s\t%s\n' "$kind" "$source" "$package" "$version" >>"$FINDINGS_FILE"
	done <"$output_file"
}

capture_command() {
	local description=$1 output_file=$2
	shift 2
	if ! "$@" >"$output_file" 2>/dev/null; then
		warn_scan_failed "$description"
		return 1
	fi
}

scan_command_path() {
	local description=$1 source=$2 kind=$3 mode=$4
	shift 4
	local path_file="$TEMP_DIR/path.txt" path

	if ! capture_command "$description" "$path_file" "$@"; then
		return
	fi

	path=$(node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1], "utf8").trim().split(/\r?\n/);
const value = lines.at(-1) || "";
try { process.stdout.write(JSON.parse(value)); }
catch { process.stdout.write(value); }
' "$path_file")

	if [[ -z "$path" ]]; then
		warn_scan_failed "$description"
		return
	fi

	scan_path "$source" "$kind" "$mode" "$path"
}

printf 'Checking affected npm packages from %s\n' "$CSV_FILE"

# This catches npm, pnpm, and node_modules-based Yarn installations without
# relying on a package manager's dependency-tree output.
scan_path project installed node-modules "$PWD/node_modules"
scan_path yarn-unplugged installed package-tree "$PWD/.yarn/unplugged"

# A lockfile pins exact versions whether or not anything is installed yet, so a
# project can be clean on disk and still resolve to an affected release on its
# next install.
scan_path project-lockfiles pinned lockfiles "$PWD"

if command -v npm >/dev/null 2>&1; then
	manager_count=$((manager_count + 1))
	scan_command_path "npm global dependencies" npm-global installed node-modules npm root --global

	if capture_command "npm cache" "$TEMP_DIR/npm-cache.txt" npm cache ls; then
		scan_path npm-cache cached npm-cache "$TEMP_DIR/npm-cache.txt"
	fi
fi

if command -v pnpm >/dev/null 2>&1; then
	manager_count=$((manager_count + 1))
	# pnpm can be installed without a configured global package directory.
	# That is a normal skip, not an incomplete scan.
	pnpm_global_root=$(pnpm root --global 2>/dev/null || true)
	if [[ -n "$pnpm_global_root" && -d "$pnpm_global_root" ]]; then
		scan_path pnpm-global installed node-modules "$pnpm_global_root"
	fi
	scan_command_path "pnpm store" pnpm-store cached pnpm-store pnpm store path
fi

if command -v yarn >/dev/null 2>&1; then
	manager_count=$((manager_count + 1))
	if capture_command "Yarn version" "$TEMP_DIR/yarn-version.txt" yarn --version; then
		yarn_version=$(node -e 'process.stdout.write(require("fs").readFileSync(process.argv[1], "utf8").trim())' "$TEMP_DIR/yarn-version.txt")
		yarn_major=${yarn_version%%.*}
		if [[ "$yarn_major" == "1" ]]; then
			scan_command_path "Yarn global dependencies" yarn-global installed package-tree yarn global dir --silent
			scan_command_path "Yarn cache" yarn-cache cached yarn-cache yarn cache dir --silent
		else
			scan_command_path "Yarn cache" yarn-cache cached yarn-cache yarn config get cacheFolder
		fi
	fi

	# Yarn Berry normally keeps cached archives inside the project. Scanning
	# this path is harmless when it does not exist.
	scan_path yarn-project-cache cached yarn-cache "$PWD/.yarn/cache"
fi

if ((manager_count == 0)); then
	warn_scan_failed "npm, pnpm, and Yarn package-manager stores"
fi

sort -u "$FINDINGS_FILE" >"$TEMP_DIR/unique-findings.tsv"
matches=0
installed_matches=0
cached_matches=0
pinned_matches=0

while IFS=$'\t' read -r kind source package version; do
	[[ -n "$kind" ]] || continue
	printf 'FOUND  %-9s %-18s %s@%s\n' "$kind" "$source" "$package" "$version"
	matches=$((matches + 1))
	case "$kind" in
	installed) installed_matches=$((installed_matches + 1)) ;;
	pinned) pinned_matches=$((pinned_matches + 1)) ;;
	*) cached_matches=$((cached_matches + 1)) ;;
	esac
done <"$TEMP_DIR/unique-findings.tsv"

if ((matches > 0)); then
	printf '%d installed, %d cached, and %d pinned affected package entr%s found.\n' \
		"$installed_matches" "$cached_matches" "$pinned_matches" \
		"$([[ $matches -eq 1 ]] && printf y || printf ies)"
fi

if ((scan_failures > 0)); then
	printf 'Scan incomplete: %d check%s failed.\n' \
		"$scan_failures" "$([[ $scan_failures -eq 1 ]] || printf s)" >&2
	exit 2
fi

if ((matches > 0)); then
	exit 1
fi

printf 'No affected packages found.\n'
exit 0
