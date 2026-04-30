#!/usr/bin/env bash
# Aegis installer.
# Performs only out-of-plugin setup. Hook + slash command registration is
# handled automatically by the Claude Code plugin format (.claude-plugin/plugin.json).

set -e
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Determine plugin install path. Prefer ~/Sync/.claude/plugins for synced setups.
if [ -d "$HOME/Sync/.claude" ]; then
  PLUGIN_BASE="$HOME/Sync/.claude/plugins"
else
  PLUGIN_BASE="$HOME/.claude/plugins"
fi
mkdir -p "$PLUGIN_BASE"

# 2. Copy or symlink the plugin tree.
if [ -L "$PLUGIN_BASE/aegis" ] || [ -d "$PLUGIN_BASE/aegis" ]; then
  echo "aegis plugin already installed at $PLUGIN_BASE/aegis"
else
  ln -s "$DIR" "$PLUGIN_BASE/aegis"
  echo "Linked plugin: $PLUGIN_BASE/aegis -> $DIR"
fi

# 3. Vendor a fresh rule snapshot.
if [ ! -s "$DIR/rules/snapshot.json" ]; then
  echo "Fetching initial rule snapshot..."
  "$DIR/bin/aegis" refresh-rules || echo "warning: refresh-rules failed; proceeding with empty snapshot"
fi

# 4. Symlink the CLI into ~/.local/bin if that dir exists.
if [ -d "$HOME/.local/bin" ]; then
  if [ ! -L "$HOME/.local/bin/aegis" ]; then
    ln -s "$DIR/bin/aegis" "$HOME/.local/bin/aegis"
    echo "Linked CLI: $HOME/.local/bin/aegis -> $DIR/bin/aegis"
  fi
else
  echo "note: ~/.local/bin doesn't exist; add $DIR/bin to PATH yourself or 'mkdir ~/.local/bin && rerun'"
fi

# 5. Write a starter config if missing.
CONFIG_DIR="$HOME/.config/aegis"
if [ ! -f "$CONFIG_DIR/aegis.toml" ]; then
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/aegis.toml" << 'EOF'
[classifier]
chain = [
  { provider = "gemini", model = "gemini-3.1-flash-lite-preview", retries = 2, timeout_s = 8 },
  { provider = "gemini", model = "gemini-3-flash-preview",        retries = 1, timeout_s = 8 },
  { provider = "claude", model = "claude-haiku-4-5",              retries = 1, timeout_s = 8 },
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
trusted_orgs    = ["ONLAYER", "Onlayer"]
trusted_domains = ["onlayer.com", "*.onlayer.com", "atlassian.net", "hubapi.com"]
trusted_buckets = []
trusted_services = ["FGT_001_CLAUDE", "VICAR", "STORMTREE", "CORPSEFIRE"]

[logging]
diag_path = "~/.cache/aegis/decisions.jsonl"
level = "info"
EOF
  echo "Wrote starter config: $CONFIG_DIR/aegis.toml"
else
  echo "Config already present: $CONFIG_DIR/aegis.toml"
fi

echo
echo "Aegis installed."
echo "Restart Claude Code to load the plugin."
