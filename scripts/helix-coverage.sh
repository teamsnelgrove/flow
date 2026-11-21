#!/usr/bin/env bash
#
# helix-coverage.sh — build a DuckDB database describing how Helix's command
# surface maps onto Flow's.
#
# Deps: duckdb, jq, ripgrep (rg), curl (only when no local helix clone is used).
#       If duckdb is not on PATH the script falls back to `nix run nixpkgs#duckdb --`.
#
# Inputs
#   Helix (pinned ref, see HELIX_REF):
#     book/src/generated/static-cmd.md   313 static commands  (name | desc | default keybinds)
#     book/src/generated/typable-cmd.md  100 typable commands (":name, :alias" | doc)
#     helix-term/src/commands*.rs        rust impls, for file:line lookups
#   Flow (this repo):
#     src/**                             `pub const <name>_meta` decls enumerate every command
#     src/keybind/builtin/helix.json     Flow's hand-authored helix keymap
#
# Output (default scripts/.out/helix-coverage.duckdb; see -o):
#   tables  helix_static, helix_typable, flow_commands, flow_helix_bindings,
#           helix_impl_locations
#   views   flow_commands_distinct, coverage
#
# Usage
#   scripts/helix-coverage.sh [-r <helix-ref>] [-c <helix-clone-dir>] [-o <db-path>]
#
# Idempotent: the output database is rebuilt from scratch on every run.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Pinned helix ref. Everything fetched from GitHub uses this exact commit so
# runs are reproducible; a local clone is only used when it is at this ref.
HELIX_REF="${HELIX_REF:-079a789e8cb08ead67f19e1971a1b7438b37354b}"
HELIX_CLONE="${HELIX_CLONE:-}"
OUT_DB=""

while getopts ":r:c:o:h" opt; do
  case "$opt" in
    r) HELIX_REF="$OPTARG" ;;
    c) HELIX_CLONE="$OPTARG" ;;
    o) OUT_DB="$OPTARG" ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "usage: $0 [-r ref] [-c helix-clone] [-o db-path]" >&2; exit 2 ;;
  esac
done

# Run from the repo root regardless of the caller's cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

[[ -f src/keybind/builtin/helix.json ]] ||
  { echo "error: $REPO_ROOT does not look like the flow repo (no src/keybind/builtin/helix.json)" >&2; exit 1; }

OUT_DB="${OUT_DB:-$REPO_ROOT/scripts/.out/helix-coverage.duckdb}"
mkdir -p "$(dirname "$OUT_DB")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/helix-coverage.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

for tool in jq rg; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing dependency: $tool" >&2; exit 1; }
done

if command -v duckdb >/dev/null 2>&1; then
  duck() { duckdb "$@"; }
elif command -v nix >/dev/null 2>&1; then
  echo "note: duckdb not on PATH, using nix run nixpkgs#duckdb" >&2
  duck() { nix run nixpkgs#duckdb -- "$@"; }
else
  echo "error: missing dependency: duckdb (and no nix to fall back on)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Helix command tables (markdown)
# ---------------------------------------------------------------------------

fetch_doc() { # $1 = basename under book/src/generated
  local name="$1" dest="$WORK/$1"
  if [[ -n "$HELIX_CLONE" && -f "$HELIX_CLONE/book/src/generated/$name" ]]; then
    cp "$HELIX_CLONE/book/src/generated/$name" "$dest"
  else
    command -v curl >/dev/null 2>&1 || { echo "error: need curl to fetch $name" >&2; exit 1; }
    curl -fsSL "https://raw.githubusercontent.com/helix-editor/helix/$HELIX_REF/book/src/generated/$name" -o "$dest"
  fi
  echo "$dest"
}

# GFM table -> jsonl, one {row_index, cells: [...]} object per data row.
# Each generated file contains exactly one table: line 1 of it is the header,
# line 2 the separator, the rest data. Cells may contain GFM-escaped '\|';
# those are protected with a control byte around the split and restored to a
# literal '|'.
md_table_to_jsonl() { # $1 = md file, stdout = jsonl
  awk '
    /^\|/ {
      n++
      if (n <= 2) next
      SEP = sprintf("%c", 1)
      line = $0
      gsub(/\\\|/, SEP, line)
      sub(/^\|/, "", line)
      sub(/\|[ \t]*$/, "", line)
      cnt = split(line, cells, /\|/)
      out = ""
      for (i = 1; i <= cnt; i++) {
        c = cells[i]
        gsub(SEP, "|", c)
        gsub(/^[ \t]+/, "", c); gsub(/[ \t]+$/, "", c)
        gsub(/\\/, "\\\\", c)
        gsub(/"/, "\\\"", c)
        out = out (i > 1 ? "," : "") "\"" c "\""
      }
      printf "{\"row_index\":%d,\"cells\":[%s]}\n", n - 3, out
    }
  ' "$1"
}

if [[ -n "$HELIX_CLONE" ]]; then
  [[ -d "$HELIX_CLONE" ]] || { echo "error: helix clone not found: $HELIX_CLONE" >&2; exit 1; }
  echo "helix docs: local clone $HELIX_CLONE" >&2
else
  echo "helix docs: fetching from github at $HELIX_REF" >&2
fi

md_table_to_jsonl "$(fetch_doc static-cmd.md)" > "$WORK/helix_static.jsonl"
md_table_to_jsonl "$(fetch_doc typable-cmd.md)" > "$WORK/helix_typable.jsonl"

# ---------------------------------------------------------------------------
# 2. Flow command enumeration
# ---------------------------------------------------------------------------

# Every flow command has a mandatory sibling `pub const <name>_meta` decl, so
# this grep is a sound enumeration. A name declared in >1 file yields >1 row;
# the flow_commands_distinct view dedupes.
grep -rnoE 'pub const [a-zA-Z0-9_]+_meta' src/ \
  | jq -R -c 'capture("^(?<file>[^:]+):(?<line>[0-9]+):pub const (?<name>[A-Za-z0-9_]+)_meta$")
              | {name, file, line: (.line | tonumber)}' \
  > "$WORK/flow_commands.jsonl"

# ---------------------------------------------------------------------------
# 3. Flow's helix keymap
# ---------------------------------------------------------------------------

# Bindings are [key, ...] under <mode>.press. Two shapes:
#   ["a", "command", arg...]                  -> single command
#   ["I", ["cmd1", arg...], ["cmd2", ...]]    -> command sequence
jq -c '
  to_entries[]
  | select(.key != "settings")
  | .key as $mode
  | (.value.press // [])[]
  | . as $b
  | ($b[0]) as $key
  | (if ($b[1] | type) == "string"
     then [$b[1]]
     else [$b[1:][] | select(type == "array") | .[0]]
     end) as $cmds
  | range(0; ($cmds | length)) as $i
  | {mode: $mode, key: $key, command: $cmds[$i], seq_index: $i}
' src/keybind/builtin/helix.json > "$WORK/flow_helix_bindings.jsonl"

# ---------------------------------------------------------------------------
# 4. Helix rust impl locations
# ---------------------------------------------------------------------------

: > "$WORK/helix_impls.jsonl"
if [[ -n "$HELIX_CLONE" && -d "$HELIX_CLONE/helix-term/src" ]]; then
  ( cd "$HELIX_CLONE"
    # -H is required: rg omits the filename when handed a single file, which
    # would leave the jq capture below matching nothing (and silently so).
    # static commands: fn <name>(cx: &mut Context)
    rg -nH --no-heading -o -r '$1' '^\s*fn ([a-z0-9_]+)\(cx: &mut Context\)' \
       helix-term/src/commands.rs helix-term/src/commands/ 2>/dev/null \
      | jq -R -c 'capture("^(?<file>[^:]+):(?<line>[0-9]+):(?<name>.+)$")
                  | {name, file, line: (.line | tonumber), kind: "static"}'
    # typable commands: plain fns in typed.rs
    rg -nH --no-heading -o -r '$1' '^\s*fn ([a-z0-9_]+)\(' \
       helix-term/src/commands/typed.rs 2>/dev/null \
      | jq -R -c 'capture("^(?<file>[^:]+):(?<line>[0-9]+):(?<name>.+)$")
                  | {name, file, line: (.line | tonumber), kind: "typable"}'
  ) > "$WORK/helix_impls.jsonl"
else
  echo "note: no local helix clone, helix_impl_locations will be empty" >&2
fi

# ---------------------------------------------------------------------------
# 5. Build the database
# ---------------------------------------------------------------------------

rm -f "$OUT_DB"

duck "$OUT_DB" <<SQL
CREATE TABLE helix_static AS
SELECT
  row_index,
  trim(cells[1], '\`') AS name,
  cells[2]             AS doc,
  cells[3]             AS default_keys
FROM read_json_auto('$WORK/helix_static.jsonl', format = 'newline_delimited',
                    columns = {row_index: 'BIGINT', cells: 'VARCHAR[]'})
ORDER BY row_index;

-- Typable rows list a command plus aliases: "\`:exit\`, \`:x\`, \`:xit\`".
CREATE TABLE helix_typable AS
WITH pivoted AS (
  SELECT row_index, cells[1] AS names_raw, cells[2] AS doc
  FROM read_json_auto('$WORK/helix_typable.jsonl', format = 'newline_delimited',
                      columns = {row_index: 'BIGINT', cells: 'VARCHAR[]'})
), split AS (
  -- names are backticked and comma separated and never contain spaces, so
  -- stripping backticks/spaces before splitting avoids a per-element lambda
  SELECT row_index, doc, names_raw,
         str_split(replace(replace(names_raw, '\`', ''), ' ', ''), ',') AS names
  FROM pivoted
)
SELECT
  row_index,
  names[1]                                    AS name,       -- e.g. ':exit'
  ltrim(names[1], ':')                        AS name_bare,  -- e.g. 'exit'
  names[2:]                                   AS aliases,
  doc
FROM split
ORDER BY row_index;

CREATE TABLE flow_commands AS
  SELECT * FROM read_json_auto('$WORK/flow_commands.jsonl', format = 'newline_delimited');

CREATE VIEW flow_commands_distinct AS
  SELECT name, count(*) AS decl_count, min(file || ':' || line) AS first_decl
  FROM flow_commands GROUP BY name;

CREATE TABLE flow_helix_bindings AS
  SELECT * FROM read_json_auto('$WORK/flow_helix_bindings.jsonl', format = 'newline_delimited');

CREATE TABLE helix_impl_locations AS
  SELECT * FROM read_json_auto(
    '$WORK/helix_impls.jsonl', format = 'newline_delimited',
    columns = {name: 'VARCHAR', file: 'VARCHAR', line: 'BIGINT', kind: 'VARCHAR'});

-- One row per helix command (static + typable) with flow coverage flags.
CREATE VIEW coverage AS
WITH cmds AS (
  SELECT 'static' AS kind, name, name AS lookup_name, doc, default_keys FROM helix_static
  UNION ALL
  SELECT 'typable', name, name_bare, doc, NULL FROM helix_typable
)
SELECT
  c.kind,
  c.name,
  c.doc,
  c.default_keys,
  coalesce(c.default_keys, '') <> ''                AS bound_in_helix_default,
  f.name IS NOT NULL                                AS exists_in_flow,
  b.command IS NOT NULL                             AS bound_in_flow_helix_json,
  b.binding_count,
  b.modes                                           AS flow_bound_modes,
  f.first_decl                                      AS flow_decl,
  i.file || ':' || i.line                           AS helix_impl
FROM cmds c
LEFT JOIN flow_commands_distinct f ON f.name = c.lookup_name
LEFT JOIN (
  SELECT command, count(*) AS binding_count, list_sort(list_distinct(list(mode))) AS modes
  FROM flow_helix_bindings GROUP BY command
) b ON b.command = c.lookup_name
LEFT JOIN (
  SELECT kind, name, min(file) AS file, min(line) AS line
  FROM helix_impl_locations GROUP BY kind, name
) i ON i.name = c.lookup_name AND i.kind = c.kind;
SQL

echo "built $OUT_DB (helix ref $HELIX_REF)" >&2

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------

duck -readonly "$OUT_DB" <<'SQL'
.mode box
SELECT 'helix_static' AS table_name, count(*) AS rows FROM helix_static
UNION ALL SELECT 'helix_typable', count(*) FROM helix_typable
UNION ALL SELECT 'flow_commands (decls)', count(*) FROM flow_commands
UNION ALL SELECT 'flow_commands (distinct)', count(*) FROM flow_commands_distinct
UNION ALL SELECT 'flow_helix_bindings', count(*) FROM flow_helix_bindings
UNION ALL SELECT 'helix_impl_locations', count(*) FROM helix_impl_locations
UNION ALL SELECT 'helix.json cmds missing from flow',
  (SELECT count(DISTINCT b.command) FROM flow_helix_bindings b
   LEFT JOIN flow_commands_distinct f ON f.name = b.command WHERE f.name IS NULL)
UNION ALL SELECT 'static cmds missing from flow',
  (SELECT count(*) FROM coverage WHERE kind = 'static' AND NOT exists_in_flow);
SQL
