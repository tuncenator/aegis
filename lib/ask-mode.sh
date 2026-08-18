#!/usr/bin/env bash
# Shared resolver for the [behavior] settings that decide what an ASK does.
#
# ask_mode
#   prompt (default) -- an ASK verdict is emitted as permissionDecision:ask
#                       and Claude Code prompts the user.
#   defer            -- an ASK verdict is emitted as NOTHING (exit 0, empty
#                       stdout). That is the only hook result that falls
#                       through to Claude Code's own permission pipeline, so
#                       its native auto-mode classifier takes the ambiguous
#                       middle instead of interrupting the user. A hook that
#                       returns "allow" or "ask" short-circuits that pipeline.
#
# defer_scope -- WHICH asks defer when ask_mode = "defer". Ignored otherwise.
#   classifier (default) -- only the LLM classifier's own ASK verdicts defer.
#                       Aegis's deterministic tripwires (lib/bash-hard-ask.sh,
#                       lib/protected-paths.sh, the gatekeeper's ASK exit)
#                       still prompt. These are curated, low-volume, and cover
#                       ground the native classifier does not: writes to /etc,
#                       /usr/bin, ~/.ssh, .git, .claude, force pushes. The
#                       auto-mode rule snapshot has no system-path rules at
#                       all, so deferring them drops the check entirely.
#   all              -- every ASK defers, deterministic layers included.
#                       Fewest interruptions, and Aegis keeps only its
#                       hard-deny (exit 2) teeth.
#
# Hard denies (exit 2) and allows are unaffected by either setting.
#
# TRUST: the global file ~/.config/aegis/aegis.toml is the operator's and is
# honoured in full. The project file <cwd>/.aegis/aegis.toml lives inside
# whatever repository the agent has open, so it is attacker-controlled in any
# repo the operator did not write; it may only RATCHET toward the stricter
# value of each setting (ask_mode="prompt", defer_scope="classifier"). Without
# that, any repo could check in defer_scope="all" and drop every deterministic
# tripwire. This mirrors classifier/rules.py PROJECT_RATCHETS exactly -- the
# two resolvers must agree, because orchestrator.sh exports its answer and the
# classifier reads it from the environment.
#
# AEGIS_ASK_MODE / AEGIS_DEFER_SCOPE in the environment win over both files.
# They are operator- and test-controlled (a repo cannot set them), and the
# orchestrator resolves once and exports so sub-processes inherit the answer.
#
# Usage:  . "$LIB/ask-mode.sh"
#         mode=$(aegis_resolve_ask_mode "$CWD")
#         scope=$(aegis_resolve_defer_scope "$CWD")

# Print "<key>\t<value>" for each [behavior] key found in a TOML file.
#
# This is a targeted reader, not a TOML parser, but it must not be fooled into
# reading configuration out of string CONTENT. A file like
#
#     [behavior]
#     note = """
#     defer_scope = "all"
#     """
#
# is valid TOML in which defer_scope is never set; a naive line matcher reads
# it as "all" while Python's tomllib reads the default, and the two halves of
# Aegis then disagree about what is gated. Multi-line basic (""") and literal
# (''') strings are therefore tracked and skipped, as are section headers that
# appear inside them.
aegis_toml_behavior_all() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    function occurrences(line, pat,   n, i, rest) {
      n = 0; rest = line
      while ((i = index(rest, pat)) > 0) { n++; rest = substr(rest, i + length(pat)) }
      return n
    }
    {
      if (ml != "") {                       # inside a multi-line string
        if (occurrences($0, ml) % 2 == 1) ml = ""
        next
      }
      if ($0 ~ /^[[:space:]]*\[/) {         # section header
        in_behavior = ($0 ~ /^[[:space:]]*\[behavior\][[:space:]]*$/)
      } else if (in_behavior) {
        for (k in want) {
          if ($0 ~ ("^[[:space:]]*" k "[[:space:]]*=") && !(k in seen)) {
            if (match($0, /"[^"]*"/)) {
              print k "\t" substr($0, RSTART + 1, RLENGTH - 2)
              seen[k] = 1
            }
          }
        }
      }
      if (occurrences($0, "\"\"\"") % 2 == 1) ml = "\"\"\""
      else if (occurrences($0, "'"'"''"'"''"'"'") % 2 == 1) ml = "'"'"''"'"''"'"'"
    }
    BEGIN { want["ask_mode"] = 1; want["defer_scope"] = 1 }
  ' "$file" 2>/dev/null
}

# Print the value of one [behavior] key in a file, or nothing.
aegis_toml_behavior() {
  aegis_toml_behavior_all "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2; exit }'
}

# Backwards-compatible alias; some older call sites use this name.
aegis_toml_ask_mode() { aegis_toml_behavior "$1" ask_mode; }

# Resolve one [behavior] string key through env > project > global, applying
# the project ratchet. $1 cwd, $2 key, $3 env var name, $4 ratchet value.
aegis__resolve_behavior() {
  local cwd="${1:-}" key="$2" envvar="$3" ratchet="$4" value="" proj=""

  eval "value=\${$envvar:-}"
  if [ -n "$value" ]; then
    echo "$value"
    return 0
  fi

  value=$(aegis_toml_behavior "$HOME/.config/aegis/aegis.toml" "$key")
  if [ -n "$cwd" ]; then
    proj=$(aegis_toml_behavior "$cwd/.aegis/aegis.toml" "$key")
    # Untrusted layer: honoured only when it tightens.
    [ "$proj" = "$ratchet" ] && value="$proj"
  fi
  echo "$value"
}

aegis_resolve_ask_mode() {
  case "$(aegis__resolve_behavior "${1:-}" ask_mode AEGIS_ASK_MODE prompt)" in
    defer) echo defer ;;
    *)     echo prompt ;;
  esac
}

aegis_resolve_defer_scope() {
  case "$(aegis__resolve_behavior "${1:-}" defer_scope AEGIS_DEFER_SCOPE classifier)" in
    all) echo all ;;
    *)   echo classifier ;;
  esac
}
