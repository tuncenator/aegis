#!/usr/bin/env bash
# Shared resolver for the [behavior] ask_mode setting.
#
#   prompt (default) -- an ASK verdict is emitted as permissionDecision:ask
#                       and Claude Code prompts the user.
#   defer            -- an ASK verdict is emitted as NOTHING (exit 0, empty
#                       stdout). That is the only hook result that falls
#                       through to Claude Code's own permission pipeline, so
#                       its native auto-mode classifier takes the ambiguous
#                       middle instead of interrupting the user. A hook that
#                       returns "allow" or "ask" short-circuits that pipeline.
#
# Hard denies (exit 2) and allows are unaffected in either mode.
#
# Layering mirrors classifier/rules.py load_config: project
# <cwd>/.aegis/aegis.toml overrides global ~/.config/aegis/aegis.toml.
# An AEGIS_ASK_MODE already present in the environment wins over both, so
# the orchestrator resolves once and sub-processes inherit it, and tests can
# force a mode without writing a config file.
#
# Usage:  . "$LIB/ask-mode.sh"; mode=$(aegis_resolve_ask_mode "$CWD")

# Print the value of ask_mode inside the [behavior] table of a TOML file,
# or nothing. Section-scoped so an ask_mode key under another table cannot
# be picked up by accident.
aegis_toml_ask_mode() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /^[[:space:]]*\[/ { in_behavior = ($0 ~ /^[[:space:]]*\[behavior\][[:space:]]*$/); next }
    in_behavior && /^[[:space:]]*ask_mode[[:space:]]*=/ {
      if (match($0, /"[^"]*"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  ' "$file" 2>/dev/null
}

aegis_resolve_ask_mode() {
  local cwd="${1:-}" mode=""

  if [ -n "${AEGIS_ASK_MODE:-}" ]; then
    mode="$AEGIS_ASK_MODE"
  else
    mode=$(aegis_toml_ask_mode "$HOME/.config/aegis/aegis.toml")
    if [ -n "$cwd" ]; then
      local proj
      proj=$(aegis_toml_ask_mode "$cwd/.aegis/aegis.toml")
      [ -n "$proj" ] && mode="$proj"
    fi
  fi

  case "$mode" in
    defer) echo defer ;;
    *)     echo prompt ;;
  esac
}
