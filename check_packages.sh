#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(dirname -- "$0")
SCRIPT_DIR=$(cd -- "$SCRIPT_DIR" && pwd -P)
CSV_FILE=${1:-"$SCRIPT_DIR/packages.csv"}

if [[ ! -r "$CSV_FILE" ]]; then
	printf 'Error: cannot read package list: %s\n' "$CSV_FILE" >&2
	exit 2
fi

if ! command -v npm >/dev/null 2>&1; then
	printf 'Error: npm is required but was not found in PATH.\n' >&2
	exit 2
fi

declare -A AFFECTED
declare -A REPORTED

# Read package names and turn the version alternatives into exact lookups.
while IFS=, read -r package versions; do
	[[ "$package" == "Package" || -z "$package" ]] && continue

	while [[ "$versions" == *'=='* ]]; do
		version=${versions#*==}
		if [[ "$version" == *'||'* ]]; then
			version=${version%%'||'*}
			versions=${versions#*'||'}
		else
			versions=
		fi
		version=${version//[[:space:]]/}
		[[ -n "$version" ]] && AFFECTED["$package|$version"]=1
	done
done <"$CSV_FILE"

matches=0

report() {
	local location=$1 package=$2 version=$3
	local key="$location|$package|$version"
	[[ ${REPORTED[$key]+yes} ]] && return
	REPORTED[$key]=1
	printf 'FOUND  %-8s %s@%s\n' "$location" "$package" "$version"
	matches=$((matches + 1))
}

scan_npm_tree() {
	local location=$1 global_flag=$2 prefix=$3 json_file
	json_file=$(mktemp)

	# npm ls returns non-zero when dependencies are missing or invalid; its
	# JSON output is still useful for this scan.
	if [[ "$global_flag" == "global" ]]; then
		npm ls --global --all --json --prefix "$prefix" >"$json_file" 2>/dev/null || true
	else
		npm ls --all --json --prefix "$prefix" >"$json_file" 2>/dev/null || true
	fi

	while IFS=$'\t' read -r package version; do
		[[ -n "$package" && -n "$version" ]] || continue
		[[ ${AFFECTED["$package|$version"]+yes} ]] && report "$location" "$package" "$version"
	done < <(
		node - "$json_file" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
let root;
try {
  root = JSON.parse(fs.readFileSync(file, 'utf8'));
} catch {
  process.exit(0);
}

const seen = new Set();
function walk(node, fallbackName) {
  if (!node || typeof node !== 'object') return;
  const name = node.name || fallbackName;
  if (name && node.version) {
    const key = `${name}|${node.version}`;
    if (!seen.has(key)) {
      seen.add(key);
      process.stdout.write(`${name}\t${node.version}\n`);
    }
  }
  for (const [dependencyName, dependency] of Object.entries(node.dependencies || {})) {
    walk(dependency, dependencyName);
  }
}
walk(root, root.name);
NODE
	)
	rm -f "$json_file"
}

scan_cache() {
	local package version cache_listing key key_file
	cache_listing=$(npm cache ls 2>/dev/null || true)
	key_file=$(mktemp)
	for key in "${!AFFECTED[@]}"; do
		printf '%s\n' "$key"
	done >"$key_file"

	while IFS='|' read -r package version; do
		report cache "$package" "$version"
	done < <(awk -F'|' '
        NR == FNR { package[NR] = $1; version[NR] = $2; count = NR; next }
        {
            for (i = 1; i <= count; i++) {
                if (index($0, package[i]) && index($0, "-" version[i] ".tgz")) {
                    print package[i] "|" version[i]
                }
            }
        }
    ' "$key_file" <(printf '%s\n' "$cache_listing") | sort -u)
	rm -f "$key_file"
}

printf 'Checking affected npm packages from %s\n' "$CSV_FILE"
scan_npm_tree project local "$PWD"

global_prefix=$(npm prefix --global 2>/dev/null || true)
if [[ -n "$global_prefix" ]]; then
	scan_npm_tree global global "$global_prefix"
fi

scan_cache

if ((matches == 0)); then
	printf 'No affected packages found.\n'
	exit 0
fi

printf '%d affected package installation/cache entr%s found.\n' "$matches" "$([[ $matches -eq 1 ]] && printf y || printf ies)"
exit 1
