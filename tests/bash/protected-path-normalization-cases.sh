#!/usr/bin/env bash
# Path-shape regressions for the non-Bash protected-path layer.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../../lib"
AEGIS_ROOT="$(cd "$DIR/../.." && pwd)"

[ -x "$LIB/protected-paths.sh" ] || {
  echo "ERROR: missing executable $LIB/protected-paths.sh" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }

TEST_TMP=$(mktemp -d /tmp/aegis-protected-paths.XXXXXX)
cleanup() {
  case "$TEST_TMP" in
    /tmp/aegis-protected-paths.*) rm -r -- "$TEST_TMP" ;;
  esac
}
trap cleanup EXIT

mkdir -p "$TEST_TMP/safe/project"
mkdir -p "$TEST_TMP/project-policy"
mkdir -p "$TEST_TMP/protected"
ln -s "$AEGIS_ROOT" "$TEST_TMP/aegis-alias"
ln -s "$AEGIS_ROOT/lib/NOSUCHFILE.sh" "$TEST_TMP/aegis-file-alias"
ln -s "$TEST_TMP/safe" "$TEST_TMP/safe-alias"
ln -s "$TEST_TMP/safe" "$TEST_TMP/protected/.aegis"
ln -s "$TEST_TMP/project-policy" "$TEST_TMP/safe/project/.aegis"

PASS=0
FAIL=0
FAILS=()

check() { # $1 want, $2 tool, $3 input key, $4 path, $5 payload cwd, $6 label
  local want="$1" tool="$2" key="$3" path="$4" cwd="$5" label="$6"
  local out got
  out=$(cd "$TEST_TMP/safe" && jq -nc \
      --arg t "$tool" --arg k "$key" --arg p "$path" --arg c "$cwd" \
      '{cwd:$c,tool_name:$t,tool_input:{($k):$p}}' \
    | "$LIB/protected-paths.sh" 2>/dev/null)
  if [ -n "$out" ]; then got=ASK; else got=NONE; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILS+=("want=$want got=$got : $label")
  fi
}

AEGIS_PARENT=${AEGIS_ROOT%/*}
AEGIS_NAME=${AEGIS_ROOT##*/}

# Lexical normalization closes alternate spellings of the install tree.
check ASK Edit file_path \
  "$AEGIS_ROOT/lib/./NOSUCHFILE.sh" "$TEST_TMP/safe/project" "dot component"
check ASK Write file_path \
  "$AEGIS_PARENT/${AEGIS_NAME}-missing/../$AEGIS_NAME/lib/NOSUCHFILE.sh" \
  "$TEST_TMP/safe/project" "dotdot component"
check ASK NotebookEdit notebook_path \
  "$AEGIS_PARENT//$AEGIS_NAME/lib/NOSUCHFILE.ipynb" \
  "$TEST_TMP/safe/project" "duplicate slash"

# Relative targets are interpreted from the cwd in the hook payload, not the
# cwd inherited by this test process.
check ASK Edit file_path "lib/NOSUCHFILE.sh" "$AEGIS_ROOT" "relative install path"
check ASK Write file_path "../rules/NOSUCHFILE.json" "$AEGIS_ROOT/lib" \
  "relative install path with dotdot"
check ASK NotebookEdit notebook_path ".aegis/NOSUCHFILE.ipynb" "$TEST_TMP/safe/project" \
  "relative project Aegis config"
check ASK Edit file_path "$TEST_TMP/project-policy/NOSUCHFILE.toml" \
  "$TEST_TMP/safe/project" "resolved project Aegis config target"
check ASK Write file_path "/proc/self/cwd/lib/NOSUCHFILE.sh" "$AEGIS_ROOT" \
  "proc self cwd uses payload cwd"
check ASK NotebookEdit notebook_path "/proc/thread-self/cwd/lib/NOSUCHFILE.ipynb" \
  "$AEGIS_ROOT" "proc thread-self cwd uses payload cwd"
check ASK Write file_path "$AEGIS_ROOT" "$TEST_TMP/safe/project" "exact install root"
check ASK Write file_path "$HOME/.config/aegis" "$TEST_TMP/safe/project" \
  "exact global config directory"
check ASK Write file_path "$HOME/.ssh" "$TEST_TMP/safe/project" "exact SSH directory"

# Resolve aliases only when the filesystem provides them. Keep the lexical
# candidate too, so a symlink from a protected tree to elsewhere cannot make
# a protected spelling fall through.
check ASK Edit file_path "$TEST_TMP/aegis-alias/lib/NOSUCHFILE.sh" \
  "$TEST_TMP/safe/project" "existing directory symlink alias"
check ASK Write file_path "$TEST_TMP/aegis-file-alias" \
  "$TEST_TMP/safe/project" "existing file symlink alias"
check ASK NotebookEdit notebook_path "lib/NOSUCHFILE.ipynb" "$TEST_TMP/aegis-alias" \
  "symlinked payload cwd"
check ASK Write file_path "$TEST_TMP/aegis-alias" "$TEST_TMP/safe/project" \
  "exact install-root symlink alias"
check ASK Edit file_path "$TEST_TMP/protected/.aegis/project/NOSUCHFILE.txt" \
  "$TEST_TMP/safe/project" "protected spelling through outward symlink"

# Normalization must not turn safe paths or similarly prefixed siblings into
# protected paths.
check NONE Edit file_path "$TEST_TMP/safe-alias/project/NOSUCHFILE.txt" \
  "$TEST_TMP/safe/project" "safe symlink alias"
check NONE Write file_path "$AEGIS_ROOT-copy/NOSUCHFILE.txt" \
  "$TEST_TMP/safe/project" "install-root sibling prefix"
check NONE NotebookEdit notebook_path "notes/NOSUCHFILE.ipynb" "$TEST_TMP/safe/project" \
  "safe relative notebook"
check NONE Read file_path "$TEST_TMP/aegis-alias/lib/NOSUCHFILE.sh" \
  "$TEST_TMP/safe/project" "non-writing tool"

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf '  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
