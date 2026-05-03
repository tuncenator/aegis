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

# 2. Vendor a fresh rule snapshot.
if [ ! -s "$DIR/rules/snapshot.json" ]; then
  echo "Fetching initial rule snapshot..."
  "$DIR/bin/aegis" refresh-rules || echo "warning: refresh-rules failed; proceeding with empty snapshot"
fi

# 3. Symlink the CLI into ~/.local/bin if that dir exists.
if [ -d "$HOME/.local/bin" ]; then
  ensure_symlink "$DIR/bin/aegis" "$HOME/.local/bin/aegis" "CLI"
else
  echo "note: ~/.local/bin doesn't exist; add $DIR/bin to PATH yourself or 'mkdir ~/.local/bin && rerun'"
fi

# 4. Write a starter config if missing.
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
echo "Aegis files installed."
echo
echo "Next, register the plugin with Claude Code (one-time):"
echo "  /plugin marketplace add $DIR"
echo "  /plugin install aegis@aegis"
echo
echo "Then restart Claude Code so the PreToolUse hook activates."
