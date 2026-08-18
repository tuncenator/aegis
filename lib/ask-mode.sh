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
#                       lib/protected-paths.sh, the gatekeeper's one ASK exit)
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
# Layering mirrors classifier/rules.py load_config: project
# <cwd>/.aegis/aegis.toml overrides global ~/.config/aegis/aegis.toml.
# An AEGIS_ASK_MODE / AEGIS_DEFER_SCOPE already present in the environment
# wins over both, so the orchestrator resolves once and sub-processes
# inherit it, and tests can force a mode without writing a config file.
#
# Usage:  . "$LIB/ask-mode.sh"
#         mode=$(aegis_resolve_ask_mode "$CWD")
#         scope=$(aegis_resolve_defer_scope "$CWD")

# Print the value of KEY inside the [behavior] table of a TOML file, or
# nothing. Section-scoped so a same-named key under another table cannot be
# picked up by accident.
aegis_toml_behavior() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    /^[[:space:]]*\[/ { in_behavior = ($0 ~ /^[[:space:]]*\[behavior\][[:space:]]*$/); next }
    in_behavior && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (match($0, /"[^"]*"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  ' "$file" 2>/dev/null
}

# Backwards-compatible alias; some older call sites use this name.
aegis_toml_ask_mode() { aegis_toml_behavior "$1" ask_mode; }

# Resolve one [behavior] string key through env > project > global.
# $1 cwd, $2 toml key, $3 env var name
aegis__resolve_behavior() {
  local cwd="${1:-}" key="$2" envvar="$3" value="" proj=""

  eval "value=\${$envvar:-}"
  if [ -z "$value" ]; then
    value=$(aegis_toml_behavior "$HOME/.config/aegis/aegis.toml" "$key")
    if [ -n "$cwd" ]; then
      proj=$(aegis_toml_behavior "$cwd/.aegis/aegis.toml" "$key")
      [ -n "$proj" ] && value="$proj"
    fi
  fi
  echo "$value"
}

aegis_resolve_ask_mode() {
  case "$(aegis__resolve_behavior "${1:-}" ask_mode AEGIS_ASK_MODE)" in
    defer) echo defer ;;
    *)     echo prompt ;;
  esac
}

aegis_resolve_defer_scope() {
  case "$(aegis__resolve_behavior "${1:-}" defer_scope AEGIS_DEFER_SCOPE)" in
    all) echo all ;;
    *)   echo classifier ;;
  esac
}
