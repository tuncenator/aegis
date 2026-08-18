#!/usr/bin/env bash
# Aegis installer.
# Performs only out-of-plugin setup. Hook + slash command registration is
# handled automatically by the Claude Code plugin format (.claude-plugin/plugin.json).

set -e
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reconcile a symlink with the desired target.
# Cases handled:
#   - link missing                    -> create
#   - link present, correct target    -> noop
#   - link present, wrong/stale target -> remove and recreate
#   - path exists as real file/dir     -> leave alone, warn
ensure_symlink() {
  local target="$1" link="$2" name="$3"
  if [ -L "$link" ]; then
    local current
    current=$(readlink "$link")
    if [ "$current" = "$target" ]; then
      echo "$name already linked: $link -> $target"
      return 0
    fi
    echo "Replacing stale $name link: $current -> $target"
    rm "$link"
  elif [ -e "$link" ]; then
    echo "warning: $link exists and is not a symlink; leaving alone"
    return 0
  fi
  ln -s "$target" "$link"
  echo "Linked $name: $link -> $target"
}

# 1. Clean up legacy plugin-tree symlinks. Earlier installs symlinked the repo
# into ~/.claude/plugins/aegis or ~/Sync/.claude/plugins/aegis, but Claude Code
# now discovers plugins only via marketplaces under .claude/plugins/marketplaces/.
# The plugin is loaded through the directory marketplace registered below.
for legacy in "$HOME/Sync/.claude/plugins/aegis" "$HOME/.claude/plugins/aegis"; do
  if [ -L "$legacy" ]; then
    echo "Removing legacy plugin symlink: $legacy"
    rm "$legacy"
  fi
done

# 2. Ensure Gemini API key is accessible to non-interactive subprocesses.
# Claude Code hooks don't inherit shell profile env vars (.bashrc/.zshrc),
# so GEMINI_API_KEY set there won't reach the classifier. The Gemini CLI
# loads ~/.gemini/.env before checking the env var, making it the reliable
# place for subprocess use.
GEMINI_ENV="$HOME/.gemini/.env"
if [ -n "${GEMINI_API_KEY:-}" ]; then
  if [ ! -f "$GEMINI_ENV" ] || ! grep -q "GEMINI_API_KEY" "$GEMINI_ENV" 2>/dev/null; then
    mkdir -p "$HOME/.gemini"
    echo "GEMINI_API_KEY=$GEMINI_API_KEY" >> "$GEMINI_ENV"
    echo "Wrote GEMINI_API_KEY to $GEMINI_ENV (for non-interactive subprocess access)"
  else
    echo "Gemini API key already in $GEMINI_ENV"
  fi
elif [ -f "$GEMINI_ENV" ] && grep -q "GEMINI_API_KEY" "$GEMINI_ENV" 2>/dev/null; then
  echo "Gemini API key found in $GEMINI_ENV"
else
  echo "warning: GEMINI_API_KEY not found in environment or $GEMINI_ENV"
  echo "  The default classifier chain uses Gemini as the primary provider."
  echo "  Without the key, Gemini calls will fail and the chain will fall through"
  echo "  to slower providers or exhaust entirely."
  echo "  Fix: export GEMINI_API_KEY=<key> and rerun, or add it to $GEMINI_ENV:"
  echo "    echo 'GEMINI_API_KEY=<key>' >> $GEMINI_ENV"
fi

# 3. Vendor a fresh rule snapshot.
if [ ! -s "$DIR/rules/snapshot.json" ]; then
  echo "Fetching initial rule snapshot..."
  "$DIR/bin/aegis" refresh-rules || echo "warning: refresh-rules failed; proceeding with empty snapshot"
fi

# 4. Symlink the CLI into ~/.local/bin if that dir exists.
if [ -d "$HOME/.local/bin" ]; then
  ensure_symlink "$DIR/bin/aegis" "$HOME/.local/bin/aegis" "CLI"
else
  echo "note: ~/.local/bin doesn't exist; add $DIR/bin to PATH yourself or 'mkdir ~/.local/bin && rerun'"
fi

# 4b. OpenCode adapter, only when OpenCode is actually installed. Creating
# ~/.config/opencode on a machine that has never run OpenCode is litter, and
# the Claude Code path does not need any of it.
if command -v opencode >/dev/null 2>&1 || [ -d "$HOME/.config/opencode" ]; then
  OPENCODE_PLUGIN_DIR="$HOME/.config/opencode/plugins"
  mkdir -p "$OPENCODE_PLUGIN_DIR"
  ensure_symlink "$DIR/.opencode/plugins/aegis.js" "$OPENCODE_PLUGIN_DIR/aegis.js" "OpenCode plugin"
  OPENCODE_COMMAND_DIR="$HOME/.config/opencode/commands"
  mkdir -p "$OPENCODE_COMMAND_DIR"
  ensure_symlink "$DIR/.opencode/commands/aegis-status.md" "$OPENCODE_COMMAND_DIR/aegis-status.md" "OpenCode status command"
  ensure_symlink "$DIR/.opencode/commands/aegis-on.md" "$OPENCODE_COMMAND_DIR/aegis-on.md" "OpenCode on command"
  ensure_symlink "$DIR/.opencode/commands/aegis-off.md" "$OPENCODE_COMMAND_DIR/aegis-off.md" "OpenCode off command"
  OPENCODE_INSTALLED=1
else
  OPENCODE_INSTALLED=0
fi

# 5. Write a starter config if missing.
CONFIG_DIR="$HOME/.config/aegis"
if [ ! -f "$CONFIG_DIR/aegis.toml" ]; then
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/aegis.toml" << 'EOF'
[classifier]
chain = [
  { provider = "gemini", model = "gemini-3.1-flash-lite-preview", retries = 2, timeout_s = 15 },
  { provider = "gemini", model = "gemini-3-flash-preview",        retries = 1, timeout_s = 15 },
  { provider = "claude", model = "claude-haiku-4-5",              retries = 1, timeout_s = 12 },
]
on_exhaustion = "ask"

[counters]
consecutive_deny_limit = 3
total_deny_limit = 20

[rules]
snapshot_ttl_days = 14

[context]
last_user_messages = 10
include_claude_md = true
claude_md_max_tokens = 4000

[environment]
trusted_orgs    = []
trusted_domains = []
trusted_buckets = []
trusted_services = []

[logging]
diag_path = "~/.cache/aegis/decisions.jsonl"
level = "info"

[behavior]
# What happens on an ASK verdict.
#   "prompt" -- surface it, Claude Code prompts you.
#   "defer"  -- emit nothing, so Claude Code's own auto-mode classifier
#               decides instead of interrupting you. Hard denies and
#               allows behave the same in both modes.
ask_mode = "prompt"
# What a classifier DENY verdict does (the snapshot's hard_deny section,
# Data Exfiltration, arrives as a deny). A deny is never deferred.
#   "prompt" -- downgrade to ASK and always surface it, you decide.
#   "block"  -- exit 2, a real hard block with no override.
hard_deny_action = "prompt"
EOF
  echo "Wrote starter config: $CONFIG_DIR/aegis.toml"
else
  echo "Config already present: $CONFIG_DIR/aegis.toml"
fi

# 6. Optional: add "Bash" to permissions.allow in user settings.
# Required for aegis to fully drive Bash gating. Without it, Claude Code's
# default-mode prompt fires for any Bash command not in its built-in safe
# list, regardless of what the hook returns -- per the docs at
# https://code.claude.com/docs/en/hooks-guide:
#   "Returning 'allow' skips the interactive prompt but does not override
#    permission rules. ... If an ask rule matches, the user is still prompted."
# Documented workaround at https://code.claude.com/docs/en/permissions:
#   "To run all Bash commands without prompts except for a few you want
#    blocked, add 'Bash' to your allow list and register a PreToolUse hook
#    that rejects those specific commands."
SETTINGS="$HOME/.claude/settings.json"

cat <<'WARN'

----------------------------------------------------------------------
Optional: add "Bash" to permissions.allow in ~/.claude/settings.json
----------------------------------------------------------------------

WHY: Claude Code's default mode prompts for any Bash command not in its
built-in safe list. A PreToolUse hook returning "allow" does NOT
override that prompt (per Claude Code docs). The documented pattern is
to add "Bash" to permissions.allow and let the hook handle deny/ask.

EFFECT: aegis becomes the sole gatekeeper for Bash:
  - aegis allow  -> command runs silently
  - aegis ask    -> Claude Code prompts with aegis's reason
  - aegis deny   -> surfaced as ask with reason (override path preserved)
  - bash-denylist (exit 2) -> hard block regardless

RISK: if aegis is disabled (/aegis off), uninstalled, or the hook fails
to load, this rule still applies, so Bash commands run WITHOUT prompts.
To revert: remove "Bash" from permissions.allow in the settings file.
----------------------------------------------------------------------

WARN

skip_allow_rule() {
  echo "Skipped. To add later, run:"
  echo "  jq '.permissions.allow = ((.permissions.allow // []) + [\"Bash\"])' \"$SETTINGS\" > /tmp/aegis-settings.json && mv /tmp/aegis-settings.json \"$SETTINGS\""
}

apply_allow_rule() {
  local tmp
  if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo '{"permissions":{"allow":["Bash"]}}' | jq . > "$SETTINGS"
    echo "Created $SETTINGS with Bash allow rule"
    return 0
  fi
  if jq -e '(.permissions.allow // []) | index("Bash")' "$SETTINGS" >/dev/null 2>&1; then
    echo "'Bash' already in permissions.allow in $SETTINGS"
    return 0
  fi
  tmp=$(mktemp)
  if ! jq '.permissions.allow = ((.permissions.allow // []) + ["Bash"])' "$SETTINGS" > "$tmp"; then
    echo "warning: failed to update $SETTINGS (malformed JSON?)"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$SETTINGS"
  echo "Added 'Bash' to permissions.allow in $SETTINGS"
}

if [ "${AEGIS_INSTALL_BASH_ALLOW:-}" = "0" ]; then
  echo "AEGIS_INSTALL_BASH_ALLOW=0 -- not modifying $SETTINGS."
  skip_allow_rule
elif [ "${AEGIS_INSTALL_BASH_ALLOW:-}" = "1" ]; then
  echo "AEGIS_INSTALL_BASH_ALLOW=1 -- applying rule without prompting."
  apply_allow_rule || true
elif [ -t 0 ]; then
  read -r -p "Add 'Bash' to permissions.allow now? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) apply_allow_rule || true ;;
    *) skip_allow_rule ;;
  esac
else
  echo "Non-interactive install (no TTY) -- not modifying $SETTINGS."
  skip_allow_rule
fi

echo
echo "Aegis files installed."
echo
echo "Next, register the plugin with Claude Code (one-time):"
echo "  /plugin marketplace add $DIR"
echo "  /plugin install aegis@aegis"
echo
echo "Then restart Claude Code so the PreToolUse hook activates."
if [ "${OPENCODE_INSTALLED:-0}" = 1 ]; then
  echo "For OpenCode, restart opencode so ~/.config/opencode/plugins/aegis.js loads."
fi
