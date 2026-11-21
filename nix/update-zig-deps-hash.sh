#!/usr/bin/env bash
#
# Refresh nix/zig-deps.hash, the hash of the zig dependencies default.nix
# builds against. Run after build.zig.zon changes. Does nothing when the
# hash is already current, so it is safe to run after every rebase.

set -euo pipefail

cd "$(dirname "$0")/.."
hash_file=nix/zig-deps.hash

if log=$(nix-build -A zigDeps --no-out-link 2>&1); then
    echo "zig deps hash is up to date"
    exit 0
fi

got=$(sed -n 's/^ *got: *//p' <<<"$log" | tail -n 1)
if [[ -z "$got" ]]; then
    echo "$log" >&2
    echo "fetching zig deps failed for a reason other than a hash mismatch" >&2
    exit 1
fi

echo "$got" >"$hash_file"
echo "zig deps hash updated to $got"
