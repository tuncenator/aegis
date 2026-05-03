# Execution Plan: project-initiation

**Created**: 2026-04-30
**Mode**: Conductor
**Total Phases**: 9
**Total Batches**: 8

---

## Model Configuration

The conductor dispatches every subagent by `subagent_type`. Each subagent file under `~/.claude/agents/` pins its own model in frontmatter, so the conductor never passes a `model` parameter and version drift is impossible.

| Role | Subagent | Pinned model | Context | Notes |
|------|----------|--------------|---------|-------|
| Orchestrator | (slash command, not a subagent) | inherits user session model | -- | Runs as `/spark-conductor`. Not pinned; subagents pin their own. |
| Hard phases | `spark-coder-hard` | `claude-opus-4-6` | 1M | Routed when phase Difficulty = hard. Phase 7 only. |
| Easy/Medium phases | `spark-coder-easy` | `claude-sonnet-4-6` | 1M | Routed when phase Difficulty = easy or medium. Phases 1, 2, 3, 4, 5, 6, 8, 9. |
| Checkpoint | `spark-checkpoint` | `claude-opus-4-6` | 1M | Merge, test, local verify, inline fix (up to 3 attempts). Does NOT push or deploy (deploy is disabled for this feature). |
| Code review | `spark-code-reviewer` | `claude-opus-4-6` | 1M | Reviews batch diff after a successful checkpoint. |
| Deploy-verify | `spark-deploy-verify` | `claude-opus-4-6` | 1M | Not used (deploy disabled). |
| Dedicated fix | `spark-fix` | `claude-opus-4-6` | 1M | Fresh-context fix after a checkpoint or review failure. |
| Phase planner | `spark-planner` | `claude-opus-4-7` | 1M | Already ran during `/spark-setup` step 7.5. |

---

## Cache Strategy

**Shared Prefix** (identical across all coding agents in a batch -- cached after the first agent):
- CODEBASE_CONTEXT.md (~12k tokens)
- Cross-cutting concerns from PROJECT_PLAN.md (~3k tokens)
- Previous checkpoint summary (~2k tokens after Batch 1; smaller for Batch 1)
- Universal agent instructions / QUICKSTART.md essentials (~5k tokens)
- **Estimated shared prefix**: ~22k tokens

**Per-Agent Suffix** (unique to each coding agent):
- Phase plan from PHASE_XX.md (~6-12k tokens depending on phase)
- Phase-specific instructions / brief expansion in conductor prompt (~1k tokens)
- **Estimated per-agent suffix**: ~7-13k tokens

**Note**: All agents in a parallel batch are spawned in a single message to maximize prompt cache hits. The shared prefix must be byte-identical across all agent prompts -- same content, same ordering, same whitespace. The only parallel batch in this plan is Batch 5 (Phase 5 + Phase 6).

---

## File Contention Analysis

> Phases that touch the same files must NOT be in the same parallel batch.

| File / Directory | Phases That Touch It | Risk | Mitigation |
|-----------------|---------------------|------|------------|
| `orchestrator.sh` | Phase 3 (creates), Phase 7 (modifies -- adds diag_emit) | NONE -- different batches | Phase 3 creates the file; Phase 7 modifies it after Phase 3 completes (Batch 3 -> Batch 6, with batches 4 and 5 in between). Cross-batch sequential modification is fine; the checkpoint merge handles the diff. |
| `README.md` | Phase 1 (skeleton, ~5 lines), Phase 9 (full replacement) | NONE -- different batches | Phase 9 deliberately replaces Phase 1's skeleton wholesale. Sequential, cross-batch. |
| `classifier/__main__.py` | Phase 3 (placeholder), Phase 7 (full implementation, replaces placeholder) | NONE -- different batches | Sequential replacement; cross-batch. |
| `classifier/rules.py` | Phase 4 (creates) | NONE | Phases 5 and 6 (parallel batch 5) only IMPORT from rules.py -- read-only access. |
| `classifier/state.py` | Phase 4 (creates) | NONE | Phase 7 imports/uses, Phase 8 imports/uses. Sequential, read-only access from later phases. |
| `tests/python/conftest.py` | Phase 3 (creates) | NONE | All later phases use this conftest unchanged. |
| `tests/bash/run.sh` | Phase 2 (creates) | NONE | No later phase modifies. |
| `lib/bash-gatekeeper.sh`, `lib/bash-denylist.sh` | Phase 1 (vendors verbatim) | NONE | No later phase modifies. |
| `pyproject.toml`, `.gitignore`, `.claude-plugin/plugin.json` | Phase 1 (creates) | NONE | No later phase modifies. |
| `tests/fixtures/transcript.*.jsonl` | Phase 5 (creates) | NONE | Phase 6 does not touch fixtures. |

**Parallel Batch 5 (Phase 5 + Phase 6) file ownership:**

- Phase 5: `classifier/{transcript, prompt, decision}.py`, `tests/python/{test_transcript, test_prompt, test_decision}.py`, `tests/fixtures/transcript.*.jsonl`
- Phase 6: `classifier/providers/{__init__, base, gemini, claude}.py`, `tests/python/test_providers.py`

**Result**: zero file overlap. Phase 5's classifier/ files and Phase 6's classifier/providers/ files live in different directories. Test files have different names. Both depend on `classifier/rules.py` (Phase 4 deliverable) read-only. Safe to parallelize.

---

## Runtime Contention Analysis

> Worktree isolation covers the filesystem only. Parallel agents share running services, databases, external APIs, and system state.

| Resource | Type | Phases That Use It | Mitigation |
|----------|------|--------------------|------------|
| pytest cache (`.pytest_cache/`, `__pycache__/`) | system-state | Batch 5 -- Phase 5 + Phase 6 both run pytest | None needed -- worktree isolation places each phase's `.pytest_cache/` and `__pycache__/` in its own worktree filesystem. No cross-contamination. |
| `~/.cache/aegis/sessions/` | system-state | Phase 4, 7, 8 (state file r/w) | None needed in parallel batch 5. Phase 5 and Phase 6 don't touch state files. Phases 4, 7, 8 are sequential. All Python tests use `tmp_path` + monkeypatch -- never touching the user's real `~/.cache/aegis/`. |
| `~/.cache/aegis/decisions.jsonl` | system-state | Phase 7, Phase 9 smoke | None needed in parallel batch. Phases 7 and 9 are sequential. All tests use `tmp_path`. |
| `gemini` / `claude` CLIs | external-api | Phase 6 (subprocess wrappers, mocked in tests), Phase 7 (chain orchestration, mocked), Phase 9 (live smoke, gated by `AEGIS_TEST_LIVE=1`) | None needed in parallel batch 5. Phase 5 doesn't touch CLIs. Phase 6's tests mock subprocess.run via monkeypatch -- no real CLI calls. Cross-phase: only Phase 9's optional `AEGIS_TEST_LIVE=1` smoke hits the real CLI; this is manual + sequential and outside the test suite. |
| Shared services / databases / staging APIs | n/a | none -- Aegis has no remote dependencies | n/a |

**Result**: No runtime contention requires mitigation beyond worktree filesystem isolation, which is already provided by the spark framework.

---

## Batch Schedule

| Batch | Phases | Mode | Checkpoint Deploy | Checkpoint Verify |
|-------|--------|------|-------------------|-------------------|
| 1 | Phase 1 | sequential | No (deploy disabled) | Vendored bash layers smoke-respond correctly to fixture stdin; pyproject.toml + plugin.json are valid; classifier/log.py setup_logger callable. |
| 2 | Phase 2 | sequential | No | Full `tests/bash/run.sh` reports PASS=<N> FAIL=0 across all four corpora; lib/bash-hard-ask.sh and lib/protected-paths.sh emit correct ASK JSON for fixture inputs and silent fall-through for non-matches. |
| 3 | Phase 3 | sequential | No | `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` reports PASS=10 FAIL=0; `tests/bash/run.sh` still passes; placeholder classifier returns ask JSON. |
| 4 | Phase 4 | sequential | No | `uv run pytest tests/python/test_state.py tests/python/test_rules.py -v` reports all tests pass; `rules/snapshot.json` is valid JSON with `allow`/`soft_deny`/`environment` keys. |
| 5 | Phase 5, Phase 6 | **parallel** | No | After merge: `uv run pytest tests/python/ -v` reports all tests pass (state, rules, transcript, prompt, decision, providers); existing bash tests still green. |
| 6 | Phase 7 | sequential | No | Full suite: `tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh && uv run pytest tests/python/ -v`; classifier/__main__.py end-to-end via stdin produces valid Claude Code permission JSON; orchestrator.sh diag_emit calls write decisions.jsonl rows for deterministic layers (verified in tmp_path). |
| 7 | Phase 8 | sequential | No | `uv run pytest tests/python/test_cli.py -v` passes; `bin/aegis status/on/off` round-trip works against AEGIS_STATE_DIR=tmp; slash command .md files have correct frontmatter and shell invocation. |
| 8 | Phase 9 | sequential | No | All five integration smoke runs documented in PHASE_09 functional QA pass; `./install.sh && ./install.sh` is idempotent; README has no emojis or unicode. |

---

## Batch Details

### Batch 1: Scaffold + vendor bash + logging

**Mode**: sequential
**Rationale**: Foundation phase. All other phases depend on the scaffold (`pyproject.toml`, `.claude-plugin/plugin.json`, vendored bash layers, `classifier/log.py`). Single-phase batch.

| Phase | Name | Difficulty | Subagent | Est. Tokens | Notes |
|-------|------|------------|----------|-------------|-------|
| 1 | Scaffold + vendor bash + logging | easy | spark-coder-easy | ~30k | Mostly file creation + cp commands; logging framework decision documented |

**Checkpoint**:
- **Deploy**: No (deploy disabled).
- **Verify**: Vendored bash layers smoke-respond correctly (fixture stdin -> expected stdout/exit). pyproject.toml parses. plugin.json is valid JSON. classifier/log.py imports cleanly.
- **Critical**: Yes -- failure here blocks every subsequent phase.

### Batch 2: Bash deterministic layers + test corpus

**Mode**: sequential
**Rationale**: Builds on Phase 1's vendored bash. Single-phase batch because Phase 3 (orchestrator) depends on Phase 2's layer scripts being callable.

| Phase | Name | Difficulty | Subagent | Est. Tokens | Notes |
|-------|------|------------|----------|-------------|-------|
| 2 | Bash deterministic layers + test corpus | medium | spark-coder-easy | ~70k | Vendor existing bash-gatekeeper test harness + corpora; build new ASK + protected-paths layers and corpora |

**Checkpoint**:
- **Deploy**: No.
- **Verify**: `tests/bash/run.sh` PASS=<N> FAIL=0 across should-allow.txt, should-deny.txt, known-not-allowed.txt, should-ask.txt, protected-paths.txt corpora. Manual smoke: pipe ASK fixture into bash-hard-ask.sh and protected-paths.sh.
- **Critical**: Yes.

### Batch 3: Orchestrator + Python skeleton

**Mode**: sequential
**Rationale**: Wires together Phase 1+2 deliverables into the actual hook entry. Sets up Python package skeleton for Phases 4-7.

| Phase | Name | Difficulty | Subagent | Est. Tokens | Notes |
|-------|------|------------|----------|-------------|-------|
| 3 | Orchestrator + Python skeleton | medium | spark-coder-easy | ~60k | First end-to-end pipeline; classifier placeholder unblocks orchestrator-cases.sh |

**Checkpoint**:
- **Deploy**: No.
- **Verify**: `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` PASS=10 FAIL=0. `tests/bash/run.sh` still PASS=<N> FAIL=0. Stdin smoke: `ls`, `rm -rf /`, `git push --force`, `Edit /etc/passwd`, `Read /x` all dispatch correctly.
- **Critical**: Yes -- the orchestrator IS the user-facing surface.

### Batch 4: Classifier state + rules

**Mode**: sequential
**Rationale**: Phase 4 must complete before Phase 5 and Phase 6 (which both import from rules.py). Single-phase batch.

| Phase | Name | Difficulty | Subagent | Est. Tokens | Notes |
|-------|------|------------|----------|-------------|-------|
| 4 | Classifier state + rules | medium | spark-coder-easy | ~65k | TOML deep merge + dataclasses + atomic state file r/w; 12 tests across 2 modules |

**Checkpoint**:
- **Deploy**: No.
- **Verify**: `uv run pytest tests/python/test_state.py tests/python/test_rules.py -v` reports 12 passed. `rules/snapshot.json` exists and parses with expected keys.
- **Critical**: Yes -- Phases 5, 6, 7, 8 all depend on these modules.

### Batch 5: Transcript + Prompt + Decision (Phase 5) + Providers (Phase 6)

**Mode**: **parallel**
**Rationale**: Phase 5 (classifier/{transcript, prompt, decision}.py) and Phase 6 (classifier/providers/*) are independent of each other. Both depend only on Phase 4's rules.py (read-only). Different file paths, different test files, no shared runtime resources. Worktree isolation handles the filesystem; subprocess mocking handles external state. Safe to parallelize.

| Phase | Name | Difficulty | Subagent | Est. Tokens | Notes |
|-------|------|------------|----------|-------------|-------|
| 5 | Classifier transcript + prompt + decision | medium | spark-coder-easy | ~75k | 3 modules, 19 tests, 2 fixture transcripts |
| 6 | Provider chain | medium | spark-coder-easy | ~50k | 3 modules (base, gemini, claude), 5 tests, all subprocess mocked |

**Checkpoint**:
- **Deploy**: No.
- **Verify**: After merge of both phases: `uv run pytest tests/python/ -v` reports all tests pass (state, rules, transcript, prompt, decision, providers). Existing bash tests still green: `tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh`.
- **Critical**: No (the modules don't fire end-to-end yet -- Phase 7 lights them up).
- **Merge note**: The two phases land in separate worktrees and merge into the integration branch at the checkpoint. Conflicts are unlikely (no file overlap), but if a planner-induced inconsistency surfaces (e.g., classifier/__init__.py touched by both with different content), the checkpoint resolves it.

### Batch 6: Classifier main + diag logging

**Mode**: sequential
**Rationale**: Phase 7 modifies orchestrator.sh (created in Phase 3) and replaces the placeholder __main__.py (created in Phase 3). It depends on every prior phase's deliverables. Single-phase batch.

| Phase | Name | Difficulty | Subagent | Est. Tokens | Notes |
|-------|------|------------|----------|-------------|-------|
| 7 | Classifier main + diag logging | hard | spark-coder-hard | ~90k | Chain orchestration with repair loop, state coupling, diag co-coordination across bash + Python |

**Checkpoint**:
- **Deploy**: No.
- **Verify**: Full suite passes: `tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh && uv run pytest tests/python/ -v`. Direct classifier smoke: `echo '<fixture>' | env PYTHONPATH=. python3 -m classifier` returns valid permission JSON. Orchestrator + diag co-coordination: `<fast-path-fixture> | ./orchestrator.sh && tail -1 ~/.cache/aegis/decisions.jsonl` shows correct layer + decision (verified in tmp_path setup so user's actual decisions.jsonl is untouched).
- **Critical**: Yes -- this phase lights up the slow path end-to-end. Any defect here breaks the central feature.

### Batch 7: bin/aegis CLI + slash commands

**Mode**: sequential
**Rationale**: Depends on Phase 4's state.py and Phase 7's existence (the CLI's refresh-rules subcommand interacts with the same snapshot file Phase 4 created and Phase 7 reads). Single-phase batch.

| Phase | Name | Difficulty | Subagent | Est. Tokens | Notes |
|-------|------|------------|----------|-------------|-------|
| 8 | bin/aegis CLI + slash commands | easy | spark-coder-easy | ~50k | argparse CLI, 3 tests, 3 slash command markdown files |

**Checkpoint**:
- **Deploy**: No.
- **Verify**: `uv run pytest tests/python/test_cli.py -v` passes. `bin/aegis off --session test1` then `bin/aegis on --session test1` round-trips correctly with AEGIS_STATE_DIR redirect. `jq . .claude-plugin/plugin.json` validates manifest.
- **Critical**: No -- the CLI is a control surface, not a critical-path component. Failures here don't break the hook itself.

### Batch 8: install.sh + README + integration smoke

**Mode**: sequential
**Rationale**: Final phase. Verifies everything integrates and ships an idempotent installer + full README. Single-phase batch.

| Phase | Name | Difficulty | Subagent | Est. Tokens | Notes |
|-------|------|------------|----------|-------------|-------|
| 9 | install.sh + README + integration smoke | easy | spark-coder-easy | ~30k | Install script + README + 7 integration smoke runs |

**Checkpoint**:
- **Deploy**: No.
- **Verify**: All 7 integration smoke runs from PHASE_09 functional QA pass (full bash suite, mocked-orchestrator, real-classifier-orchestrator, full pytest, fast-path stdin smoke, optional AEGIS_TEST_LIVE smoke, install idempotency). README has no emojis or unicode.
- **Critical**: Yes -- this is the project completion gate. If integration smoke reveals issues, prior phases get re-opened.

---

## Dependency Graph

```
=== Batch 1 ===
Phase 1 (easy, sequential) [Scaffold + vendor bash + logging]
  |
--- Checkpoint 1 ---
  |
=== Batch 2 ===
Phase 2 (medium, sequential) [Bash deterministic layers + test corpus]
  |
--- Checkpoint 2 ---
  |
=== Batch 3 ===
Phase 3 (medium, sequential) [Orchestrator + Python skeleton]
  |
--- Checkpoint 3 ---
  |
=== Batch 4 ===
Phase 4 (medium, sequential) [Classifier state + rules]
  |
--- Checkpoint 4 ---
  |
=== Batch 5 ===
Phase 5 (medium) --+
Phase 6 (medium) --+--> merge
                  |
--- Checkpoint 5 ---
  |
=== Batch 6 ===
Phase 7 (hard, sequential) [Classifier main + diag logging]
  |
--- Checkpoint 6 ---
  |
=== Batch 7 ===
Phase 8 (easy, sequential) [bin/aegis CLI + slash commands]
  |
--- Checkpoint 7 ---
  |
=== Batch 8 ===
Phase 9 (easy, sequential) [install.sh + README + integration smoke]
  |
--- Checkpoint 8 ---
  |
*** Project complete ***
```

---

## Conductor Pacing

- **Mode**: auto-refresh
- **Batches Per Session**: 4

**Rationale**: 8 total batches; default formula `ceil(8 / 2) = 4`. The first session covers Batches 1-4 (scaffold through state+rules). The second session resumes from Checkpoint 4 and covers Batches 5-8 (parallel batch through final integration). The auto-refresh boundary is convenient because Batch 5 (parallel) is the most context-heavy, so giving it a fresh session makes sense.

---

## Fix Strategy

- **Max inline fix attempts per checkpoint**: 3
- **Inline fix**: `spark-checkpoint` itself attempts fixes (it has full merge context)
- **Dedicated fix subagent**: `spark-fix` (fresh context, claude-opus-4-6 pinned)
- **Escalation path**: 3 inline fixes -> dedicated fix subagent -> human intervention
- **Fix scope rules**:
  - Localized failure (one file, clear cause, <50 lines): inline fix in checkpoint
  - Systemic failure (architectural incompatibility, missing interfaces): skip inline, dispatch `spark-fix` immediately
  - Fix outcomes are appended to the checkpoint summary

---

## Notes

- **Phase 7 is the highest-risk phase.** It's the only `hard` phase, replaces a placeholder, modifies a file authored two batches earlier (orchestrator.sh from Phase 3), and is where the slow-path classifier first runs end-to-end. Reviewer should pay close attention to: chain-walk-with-repair correctness, state-coupling on the on_exhaustion path, diag-after-state-save ordering, and that the orchestrator.sh modification doesn't break tests/bash/orchestrator-cases.sh.
- **Phase 3 planner flagged a typo in the source plan** (`docs/superpowers/plans/2026-04-30-aegis.md` Task 6 Step 2): the trailing fall-through invocation reads `python3 -m aegis_classifier` and omits PYTHONPATH. The phase plan corrects this to `exec env PYTHONPATH="$DIR" python3 -m classifier` consistent with the other two call sites. The coder must use the corrected form.
- **Parallel batch (Batch 5) cache efficiency**: Two coding agents share ~22k tokens of prefix. Cache hit on the second agent's prompt should land. Both agents complete in roughly the same wall-clock time (Phase 5 has more tests but Phase 6 has more subprocess mocking; rough parity). The conductor must spawn both in a single message (multi-tool dispatch) for the cache hit + parallelism to materialize.
- **No remote git push**: this project has no GitHub remote. Commits stay on the local `feature/project-initiation` branch. The conductor's deploy-verify agent is not used. The deploy section in STATUS.md is `disabled`.
- **Live verification posture is `cautious`** (per STATUS.md). Each coding agent treats writes outside its worktree as needing user approval. In practice this matters most for Phases 4, 7, 8, 9 where state files / snapshot / install paths could be touched -- all guarded by `tmp_path` in tests and explicit guidance in QUICKSTART.md and the phase plans.
- **No helpers configured**. Step 7.6 found no planner-proposed helpers. Step 7.7 skipped (deploy and smoke disabled). QUICKSTART.md `Project Helpers` section reads "No helpers configured for this feature."
- **Auto-refresh boundary**: after Batch 4 completes (Checkpoint 4 passes), the conductor instructs the user to restart `/spark-conductor project-initiation` for a fresh context window. The new session resumes from Checkpoint 4 automatically and runs Batches 5-8.
