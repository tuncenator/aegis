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
# value of each setting (ask_mode="prompt", defer_scope="classifier").
#
# ONE PARSER. These settings used to be resolved TWICE: by an awk line matcher
# in this file for the deterministic shell layers, and by tomllib in
# classifier/rules.py for the classifier and `aegis status`. Because
# orchestrator.sh exports its answer and rules.py lets the environment
# override its own, the awk reader silently won end to end -- so the shell's
# reading of the config was the one that mattered, and a hand-rolled matcher
# diverges from a real TOML parser. On one and the same file:
#
#     defer_scope = false # "all"    awk: all         tomllib: classifier
#     [behavior] # note              awk: classifier  tomllib: all
#     # """  (a bare comment)        awk: classifier  tomllib: all
#     defer_scope = 'all'            awk: classifier  tomllib: all
#
# The first is the dangerous one: awk pulled "all" out of a COMMENT on a line
# whose actual value is a boolean, disarming every deterministic tripwire
# while `aegis status` still reported them active. The rest made the shell
# stricter than Python, which is safe but still a lie about what the file says.
#
# So there is now exactly one parser. This file shells out to
# classifier.rules.load_config -- the same tomllib loader the classifier and
# `aegis status` use, which already implements the layering, the project
# ratchet and the type checks. Divergence is structurally impossible rather
# than something a test has to keep chasing.
#
# FAIL SAFE. If that resolution fails for any reason (no python3, an import
# error, a truncated read, an output shape we do not recognise) the resolver
# returns the STRICTER value of each setting: prompt/classifier. Guessing
# defer/all on error would disarm the tripwires exactly when Aegis is least
# sure of itself, which is the failure mode this file exists to prevent.
#
# AEGIS_ASK_MODE / AEGIS_DEFER_SCOPE in the environment win over both files.
# They are operator- and test-controlled (a repo cannot set them), and the
# orchestrator resolves once and exports so sub-processes inherit the answer.
#
# Usage:  . "$LIB/ask-mode.sh"
#         pair=$(aegis_resolve_behavior "$CWD")
#         mode=${pair%%$'\t'*}
#         scope=${pair#*$'\t'}

# Absolute path of the aegis root, derived from THIS file rather than from the
# caller's $0, so the resolver works whoever sources it (orchestrator.sh,
# bin/aegis, the test suites). readlink -f follows the plugin symlink chain
# the same way orchestrator.sh does.
AEGIS__LIB_SRC="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
AEGIS__ROOT="$(cd "$(dirname "$AEGIS__LIB_SRC")/.." 2>/dev/null && pwd)"

# The one parser. Prints "<ask_mode>\t<defer_scope>" for $1 = cwd, or nothing
# at all if anything goes wrong; callers treat "nothing" as the strict default.
#
# -P is load bearing. Without it CPython puts the process's current directory
# at the FRONT of sys.path for -c, ahead of PYTHONPATH, and the hook's cwd is
# the repository the agent has open -- so a repo shipping its own
# classifier/rules.py would be imported here in place of Aegis's and could
# return defer/all for itself. -P suppresses that entry. It needs CPython
# 3.11+, which classifier/rules.py already requires for tomllib.
aegis__resolve_via_tomllib() {
  local cwd="$1" py="python3"
  [ -x "$AEGIS__ROOT/.venv/bin/python3" ] && py="$AEGIS__ROOT/.venv/bin/python3"
  env PYTHONPATH="$AEGIS__ROOT" "$py" -P -c '
import sys
from classifier import rules
cfg = rules.load_config(sys.argv[1] or None)
sys.stdout.write(cfg.ask_mode + "\t" + cfg.defer_scope + "\n")
' "$cwd" 2>/dev/null
}

# Resolve BOTH [behavior] keys from ONE read of the config layers and print
# them as "<ask_mode>\t<defer_scope>". $1 = cwd (may be empty).
#
# Resolving them together is the point: two separate resolutions can straddle
# a config edit and combine the ask_mode of one version of the file with the
# defer_scope of another, synthesizing a defer/all pair that never existed on
# disk. One process, one read per layer, one answer.
aegis_resolve_behavior() {
  local cwd="${1:-}" env_mode="" env_scope="" out="" mode="" scope=""

  # Environment first, and validated the same way rules.py validates it: only
  # a value the loader recognises counts, so a typo falls through to the files
  # instead of silently meaning "default".
  case "${AEGIS_ASK_MODE:-}"    in prompt|defer)   env_mode="$AEGIS_ASK_MODE" ;;   esac
  case "${AEGIS_DEFER_SCOPE:-}" in classifier|all) env_scope="$AEGIS_DEFER_SCOPE" ;; esac

  # Nothing on disk means nothing to parse: tomllib on a missing file yields
  # the built-in defaults, which is what the tail of this function returns
  # anyway. Skipping the spawn in that case cannot diverge from the one
  # parser -- there is no file for the two to disagree about -- and it keeps
  # the hook's per-tool-call cost unchanged for anyone who never wrote a
  # config. Aegis runs on EVERY tool call, so the spawn is worth avoiding
  # whenever it provably cannot change the answer.
  if [ -f "${HOME:-}/.config/aegis/aegis.toml" ] ||
     { [ -n "$cwd" ] && [ -f "$cwd/.aegis/aegis.toml" ]; }; then
    out=$(aegis__resolve_via_tomllib "$cwd")
  fi

  # Accept only the four shapes the resolver can legitimately produce. A
  # partial write, a warning on stdout or a missing tab is not "half an
  # answer" to be salvaged, it is an unusable one: drop it and take the
  # strict default below.
  case "$out" in
    prompt$'\t'classifier|prompt$'\t'all|defer$'\t'classifier|defer$'\t'all)
      mode=${out%%$'\t'*}
      scope=${out#*$'\t'}
      ;;
  esac

  # The environment layer is applied again here rather than trusted to the
  # python side alone, because the no-config fast path above never asks it.
  # Same precedence either way: env beats project beats global.
  [ -n "$env_mode" ]  && mode="$env_mode"
  [ -n "$env_scope" ] && scope="$env_scope"

  printf '%s\t%s\n' "${mode:-prompt}" "${scope:-classifier}"
}

# Single-key convenience wrappers.
#
# Each one runs its OWN resolution, so a caller that needs both values must
# use aegis_resolve_behavior instead -- see the torn-pair note there. These
# exist for callers that genuinely want one key (diagnostics, `aegis status`
# style reporting) and for readability at call sites that only branch on one.
aegis_resolve_ask_mode() {
  local pair; pair=$(aegis_resolve_behavior "${1:-}")
  printf '%s\n' "${pair%%$'\t'*}"
}

aegis_resolve_defer_scope() {
  local pair; pair=$(aegis_resolve_behavior "${1:-}")
  printf '%s\n' "${pair#*$'\t'}"
}
