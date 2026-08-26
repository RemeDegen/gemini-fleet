---
name: gemini-fleet
description: Standalone Antigravity CLI (agy) runner + fleet orchestrator for Gemini models. Does TWO things and always EXECUTES them (never just describes): (1) general code tasks via `agy -p` delegates, and (2) parallel multi-lane fleets — spawning many `agy` delegates at once with worktree isolation. Runs on the user's Google subscription via keyring OAuth — no API key, no elevated permission flags. Defaults locked: `--add-dir` always, `--output-format json` always, stderr never discarded. For multiple independent jobs, fire them ALL in parallel — measured 4 concurrent lanes at 7s wall time with zero contention. Triggers on: "use gemini", "run gemini", "ask gemini to ...", "have gemini ...", "agy", "antigravity", "gemini fleet", "spawn a gemini fleet", "parallel gemini", and any request to delegate code-level work to Gemini models.
---

# Gemini Fleet — Antigravity CLI Action Runner

> Drives the [Antigravity CLI](https://github.com/google-antigravity/antigravity-cli) (`agy`) from Claude Code as a delegate/fleet runner for Gemini models. Sibling to `codex-fleet`; same orchestration philosophy, different substrate.
>
> **Every rule in this file was measured against `agy 1.1.20` on macOS (darwin/arm64) on 2026-08-26.** Where a rule contradicts the upstream docs or a GitHub issue, the measurement wins and the discrepancy is noted.

This skill does two things and ALWAYS executes them, never describes them:

1. **General Gemini tasks** — code review, refactor, multi-file edits, analysis, diagnosis; anything you'd hand to a peer-AI for parallel processing.
2. **Fleets** — spawning many `agy` delegates at once (one lane or twenty), with worktree isolation for concurrent write lanes.

**Image generation is NOT part of this skill.** `agy` has no built-in image tool — `agy models` lists only text models. For image assets use `codex-fleet`, which drives `gpt-image-2`.

## STOP — read this first if you are on Windows

Every shell recipe below is Unix (`caffeinate`, `jq`, `perl setpgrp`, `&`/`wait`, `kill -KILL -PID`). None of them exist on Windows. **Do not run them, and do not report their failure as an `agy` problem.**

Worse, `agy`'s headless mode has open Windows issues in exactly the mechanism this skill depends on — [#76](https://github.com/google-antigravity/antigravity-cli/issues/76) (stdout silently dropped under non-TTY), [#318](https://github.com/google-antigravity/antigravity-cli/issues/318) (hangs indefinitely), [#548](https://github.com/google-antigravity/antigravity-cli/issues/548) (headless ignores `permissions.allow`). Those reports span 1.0.5–1.1.8 and may be fixed — nobody has measured a current version.

**On Windows, before using this skill for anything, run the measurement script and read its verdict:**

```powershell
powershell -ExecutionPolicy Bypass -File tools/agy-windows-test.ps1
```

- **Verdict says it works** → translate the recipes as you go: drop `caffeinate` (no equivalent), `ConvertFrom-Json` instead of `jq`, `Start-Job`/`Wait-Job` instead of `&`/`wait`, `taskkill /PID <id> /T /F` instead of the process-group kill. Everything in THE FOUR RULES still applies — those are `agy` behaviours, not shell behaviours.
- **Verdict says it's broken** → stop and tell the user. Do not improvise workarounds. A silently-empty lane is worse than no lane.

Then send the script's `AGY-WINDOWS-SONUC.txt` upstream so the Windows section can be written from data.

---

## CRITICAL: This is an ACTION skill, not commentary

When invoked you MUST:

1. **Actually invoke `agy` via the Bash tool.** Never write instructions for the user to run themselves.
2. **Default to background execution** (`run_in_background: true`) for any task likely to take >10s.
3. **For multiple independent jobs, fire them ALL in parallel** — separate Bash calls in a single message. Measured: 4 concurrent lanes completed in 7s wall time (individual durations 2.0–3.1s), no contention, no throttling.
4. **Verify before reporting.** See the acceptance gate below — `agy` reports `SUCCESS` on runs that did nothing.

## Prerequisites

- `agy` on PATH (`~/.local/bin/agy`). Check with `agy --version`.
- Authenticated. `agy` uses **keyring OAuth against the user's Google subscription** (`authMethod=consumer`) — no `GEMINI_API_KEY`, no Vertex project. It auto-refreshes expired tokens from the keyring, including tokens left by the Antigravity desktop IDE.
- If `agy` has been idle a long time, the **first** call can take 60s+ (cold auth refresh + conversation-store reconciliation) and may look hung. Warm it with a trivial `agy -p "hi" --output-format json` before spawning a fleet. Subsequent calls are 2–7s. The warm-up is the one call that deliberately omits `--add-dir`: it touches no files, so it needs no workspace.

---

## THE FOUR RULES (learned the hard way — do not skip)

### 1. `--add-dir <DIR>` is mandatory for any task that touches files. Without it, even reading fails.

`agy` auto-allows file tools only inside a registered workspace. Outside one it falls back to a shell `command` to read the file, and headless mode auto-denies any tool needing approval. The run then produces nothing.

```
WRONG:  agy -p "read veri.txt and tell me its contents" --output-format json
        → {"status":"SUCCESS","response":"", ...}
        → stderr: a tool required the "command" permission that headless mode
                  cannot prompt for, so it was auto-denied.

RIGHT:  agy -p "read veri.txt and tell me its contents" --add-dir /path/to/dir --output-format json
        → {"status":"SUCCESS","response":"kirmizi=5\n", ...}
```

This single flag is why you do **not** need `--dangerously-skip-permissions`. Read lanes, write lanes and edit lanes all work at normal permission level once the directory is registered. Never reach for the dangerous flag to fix a permission denial — add the directory instead.

`permissions.allow` in `~/.gemini/antigravity-cli/settings.json` is **not** needed and was verified irrelevant: the read lane succeeds with that file deleted.

**`--add-dir` is necessary but not sufficient — the model can still choose to shell out.** Measured: the identical prompt, model and flags produced a written file on one run and the permission denial on another. When the model reaches for `write_file` it succeeds; when it decides to `cat >` the file instead, it is silently denied. Two defences, use both:

1. Put an explicit tool constraint at the top of every write brief:
   > TOOL CONSTRAINT: Use only the built-in file write/edit tools. Do NOT run shell commands — no `cat`, `echo`, `touch`, `sed` to write files. Shell is denied in this environment and fails silently.
2. Never trust the run without the acceptance gate below. This failure looks exactly like success in the JSON.

### 2. `"status":"SUCCESS"` is not evidence. It lies.

A run that was fully blocked still returns `"status":"SUCCESS"` — with `"response":""` and the real reason only on **stderr**. Therefore:

- **Never** discard stderr. `codex-fleet` uses `2>/dev/null`; here that would hide every failure. Always `> lane.out 2> lane.err`.
- A lane succeeded only if exit code is 0 **and** `.response` is non-empty. Non-empty stderr means inspect, not necessarily fail.

```bash
resp=$(jq -r '.response // ""' lane.out)
[ -z "$resp" ] && echo "LANE FAILED — empty response"
[ -s lane.err ] && echo "LANE STDERR (inspect):" && cat lane.err
```

On `agy 1.1.20` every successful run measured wrote **exactly zero bytes** to stderr, so "stderr empty" is a reliable signal today. Don't harden it into an automatic failure: a future version emitting a deprecation or telemetry warning would then fail every healthy lane. Treat the empty `.response` as the failure condition and stderr as the diagnosis. The specific string to watch for is `a tool required the ... permission that headless mode cannot prompt for` — that one always means a missing `--add-dir`.

Then still run the lane's own acceptance check (targeted test / typecheck / `ls` the file it claimed to write). A completion is a claim, not evidence.

### 3. `--print-timeout` defaults to 5 minutes. Raise it on every real lane.

A trivial prompt returns in 2–7s and a research lane in ~2 minutes, so the default hides. But any lane doing actual multi-file work — a refactor, a feature, a migration — will run past 5 minutes and be cut off mid-flight, leaving a half-edited tree and no report. Pass `--print-timeout 30m` (or more) on anything beyond a quick question. This costs nothing when the lane finishes early.

### 4. Do NOT wrap in a PTY. It makes things worse.

GitHub issues #76/#318 report `agy -p` dropping stdout or hanging under non-TTY, and recommend `script -q /dev/null` as a workaround. **This does not reproduce on macOS 1.1.20.** Plain non-TTY redirection to a file works cleanly (measured: exit 0, 3s, correct bytes).

The PTY wrapper *does* work, but it injects a `^D` prefix, spinner frames (`⠋ Fetching...`) and ANSI padding into stdout that you then have to strip. Plain is strictly cleaner. Those issues are Windows/PowerShell-rooted; ignore the workaround on macOS. If a future version regresses, the fallback is `script -q /dev/null agy ...` piped through `sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r//g'`.

---

## Defaults (locked in)

| Setting | Value | When to override |
|---|---|---|
| Workspace | `--add-dir <LANE_DIR>` | **always** — never omit |
| Output | `--output-format json` | `stream-json` when you need live events |
| Stderr | `2> lane.err`, always read | never discard |
| Model | `gemini-3.1-pro-high` | see roster below |
| Mode | `--mode plan` (read) / `--mode accept-edits` (write) | never `--dangerously-skip-permissions` |
| Timeout | `--print-timeout 30m` on any real work lane | raise further for large refactors |
| PTY wrapper | none | only if a future version regresses |
| Elevated flags | none | requires explicit user OK first |

### Model roster (from `agy models`, on the user's subscription)

| Slug | Use |
|---|---|
| `gemini-3.1-pro-high` | **default for real work** — deep reasoning, refactors, review gates |
| `gemini-3.1-pro-low` | pro-class with less deliberation |
| `gemini-3.7-flash-high` | strong workhorse, much cheaper than pro |
| `gemini-3.7-flash-medium` / `-low` | mechanical/grunt lanes, cheap sweeps |
| `gemini-3.6-flash-*`, `gemini-3.5-flash-*` | older flash tiers |
| `claude-sonnet-4-6`, `claude-opus-4-6-thinking` | Claude models, also served through Antigravity |
| `gpt-oss-120b-medium` | open-weight option |

**Reasoning effort is baked into the model slug** (`-high` / `-medium` / `-low`), unlike `codex-fleet`'s `-c model_reasoning_effort=`. A separate `--effort` flag exists but is redundant with the slug — pick the tier via the slug and leave `--effort` alone.

### Cost awareness (measured)

| Call shape | Input tokens |
|---|---|
| Trivial prompt, no workspace | ~13.7k |
| Same prompt with `--add-dir` | ~44.8k |
| Edit lane on a 1-line file | ~57k |

`--add-dir` costs ~3.3× in input tokens because it loads workspace context. This runs against a **consumer subscription quota**, so scope each lane's directory as narrowly as the work allows — that is a quota decision, not a performance one. A 20-lane fleet spends roughly 900k input tokens before doing any work.

---

## Project directives: `agy` reads `GEMINI.md`, not `CLAUDE.md`

Measured with three competing directive files in one workspace (`CLAUDE.md`, `GEMINI.md`, `AGENTS.md`, each demanding a different comment language and function name, with the brief mentioning none of them): the lane followed **`GEMINI.md`** and ignored the other two.

So a project whose conventions live in `CLAUDE.md` gets none of them by default. Two fixes:

```bash
# Preferred — one symlink, both agents read the same rules, no drift
ln -s CLAUDE.md GEMINI.md
```

Or name the file in the brief's "read first" section: *"Read `CLAUDE.md` before writing anything and follow it."* The symlink is better for a project you use repeatedly; the brief line is better for a one-off in someone else's repo.

---

## Part 1 — Single delegate

### Base command

```bash
agy -p "<PROMPT>" \
  --add-dir <DIR> \
  --model gemini-3.1-pro-high \
  --mode plan \
  --output-format json \
  --print-timeout 30m \
  > /tmp/gf-<name>.out 2> /tmp/gf-<name>.err
```

### Mode quick reference

| Use case | Flags |
|---|---|
| Review / analysis / diagnosis (default) | `--mode plan` — structurally read-only |
| Apply local edits | `--mode accept-edits` — auto-approves edit tools inside the workspace |
| Shell commands | still gated; see note below |

**Shell commands remain gated even inside a workspace.** File read/write/edit are auto-allowed; running shell is not. If a lane genuinely needs to execute commands, the only lever `agy` currently offers is `--dangerously-skip-permissions`, which auto-approves *everything*. That is a real escalation: **get explicit user OK before the first use in a session**, and prefer restructuring the lane to avoid shell (have the lane edit files; run the build/test yourself as orchestrator). Scoped `permissions.allow` rules are documented upstream but were measured to have no effect in print mode.

### Reading the result

```bash
jq -r '.response'           /tmp/gf-x.out  # the answer — empty means the run failed
jq -r '.status'             /tmp/gf-x.out  # SUCCESS — not trustworthy on its own
jq -r '.conversation_id'    /tmp/gf-x.out  # for resume
jq -r '.usage.total_tokens' /tmp/gf-x.out  # quota accounting
cat /tmp/gf-x.err                          # expected empty; read it whenever it isn't
```

### Resume

```bash
agy -p "follow-up prompt" --conversation <CONVERSATION_ID> --output-format json
```

`--continue` / `-c` resumes the most recent conversation instead. Don't re-pass `--model` when resuming unless deliberately changing it.

### Critical evaluation of Gemini output

Treat the delegate as a peer, not an authority. Trust your own knowledge when confident; push back on claims you know to be wrong; verify against live docs when uncertain, especially for model names, library versions and post-cutoff API changes. For substantive disagreements, resume the conversation and discuss rather than silently overriding. Either side can be wrong — if genuine ambiguity remains, surface it to the user.

---

## Part 2 — Fleets

A fleet is N `agy` delegates working at once. Each lane is a plain background `agy` process. You (the orchestrator) spawn the lanes, hand each a self-contained brief, watch their logs, verify their claims, and integrate.

### Spawn recipe (one lane)

From the Claude Code harness, one Bash call per lane with `run_in_background: true`:

```bash
caffeinate -i agy -p "<SELF-CONTAINED LANE BRIEF>" \
  --add-dir <LANE_DIR> \
  --model gemini-3.1-pro-high \
  --mode accept-edits \
  --output-format json \
  --print-timeout 30m \
  > /tmp/lane-A.out 2> /tmp/lane-A.err
```

Inside a **shell script** the same recipe needs a trailing `&` per lane plus a `wait`, or the lanes run one after another:

```bash
for L in A B C; do
  caffeinate -i agy -p "$(brief_for "$L")" \
    --add-dir "$LANE_DIR_$L" --model gemini-3.1-pro-high --mode accept-edits \
    --output-format json > "/tmp/lane-$L.out" 2> "/tmp/lane-$L.err" &
done
wait
```

To also make a lane reapable (see Liveness), nest the wrappers **`caffeinate` outermost, `setpgrp` innermost** so the sleep guard covers the whole lane and the kill target is the agent's own group:

```bash
caffeinate -i perl -e 'setpgrp(0,0); exec @ARGV' \
  agy -p "<BRIEF>" --add-dir <LANE_DIR> --model gemini-3.1-pro-high \
  --mode accept-edits --output-format json > /tmp/lane-A.out 2> /tmp/lane-A.err &
LANE_A_PID=$!
# later, to reap a wedged lane:  kill -KILL -$LANE_A_PID
```

The brief is the lane's **entire contract** — goal, the exact files it OWNS, the files it must NOT touch (and which sibling owns them), its acceptance check, and how to report done/failed. A delegate cannot see your conversation; everything it needs goes in the brief.

> **`caffeinate -i` (macOS).** Lid-close or idle sleep silently kills a mid-flight lane. Wrap every spawn.

### Fleet patterns

- **Warm up first.** One trivial `agy -p "hi"` before the fleet, so the cold auth refresh doesn't make several lanes look hung simultaneously.
- **Stagger spawns 2–5s apart** for large fleets. Measured 4 simultaneous lanes with zero contention, so small fleets can fire together; stagger is insurance at scale, not a measured requirement here.
- **Tier the lanes**: explore/read → `gemini-3.7-flash-low` + `--mode plan`; standard write → `gemini-3.7-flash-high` + `--mode accept-edits`; deep refactor / review gate → `gemini-3.1-pro-high`.
- **Read lanes stay `--mode plan`** so they physically cannot edit. Escalate to a write lane if edits are needed; never tell a read lane to patch.
- **Liveness**: a lane whose `.out` and `.err` are both empty and unchanged for many minutes is dead regardless of the process table. `agy` is a Go binary that **ignores SIGALRM** and spawns child processes (language server, store manager), so `perl -e 'alarm ...'` and a plain `kill` on the parent will not reap it — spawn it in its own process group and kill the group (see the nested-wrapper recipe above). Note `timeout` is not present on stock macOS; `gtimeout` only exists with Homebrew coreutils.
- **Completions are claims.** Apply the three-part gate (exit 0 + non-empty `.response` + empty `.err`), then run the lane's real acceptance check yourself.

### Concurrent WRITE lanes — worktree isolation

When several lanes must write to the same repo at once they will clobber each other in a shared checkout. Two shapes:

**A. Worktree-per-lane + orchestrator commits and cherry-picks** — best when lanes carve disjoint regions of the same file, or whenever live collisions are possible.

Because shell is gated, the lane **cannot commit its own work** — this is the main divergence from `codex-fleet`, whose lanes self-commit. Here the lane only edits files in its worktree; the orchestrator commits on its behalf, which is simpler and keeps one hand on the history:

```bash
git worktree add --detach ../fleet-lane-A <BASE_SHA>
# spawn the lane with --add-dir ../fleet-lane-A
# brief tells it: edit files only, then report which files you changed
# when the lane passes the acceptance gate, the ORCHESTRATOR does:
git -C ../fleet-lane-A add -A && git -C ../fleet-lane-A commit -m "lane A: <summary>"
# then cherry-pick each lane's commit onto main in completion order,
# gating (build + typecheck + test) at each pick
```

Prove the mechanics on a baseline worktree whose gate is GREEN before any lane spawns. Conflicts concentrate in append zones (import blocks, guard arrays) and resolve as unions; for moved code, resolve by OWNERSHIP — grep the lane's target file for the moved declaration before deleting anything.

**B. Shared tree with explicit OWNS / DO-NOT-TOUCH lists** — works when lanes touch clearly disjoint files.

- Each brief carries an OWNS list and a DO-NOT-TOUCH list naming which sibling owns what. Lanes self-report fouls ("sibling edits present, left intact") instead of "fixing" them.
- Shared files (barrels, CLI entry, validators) are **append-only** and allocated to exactly one commit at integration.
- Lanes cannot run the repo-root gate or git at all (shell is gated). The orchestrator runs the single full gate after all lanes settle, repairs cross-lane breakage, then commits per coherent unit.
- A lane editing a shared barrel/type file can break every other lane's build mid-flight. Rebuild that package so downstream lanes resolve; for long fleets, a quiet rebuild loop every ~2 min bounds the outage window.

In both patterns the division of labour is the same: **lanes edit files, the orchestrator runs git and the gates.** Write every brief accordingly — a brief that tells a lane to "commit when done" or "run the tests" describes work the lane physically cannot do, and the lane will either stall or claim success without doing it.

---

## Failure table

| Symptom | Cause | Fix |
|---|---|---|
| `"status":"SUCCESS"` with `"response":""` | A tool was auto-denied; reason is on stderr | Add `--add-dir <DIR>`. Read stderr always |
| First call hangs 60s+ | Cold auth refresh + conversation reconciliation | Expected once; warm up before fleets |
| `You are not logged into Antigravity` in the log | Keyring token missing/expired beyond refresh | Run `agy` interactively once to re-auth |
| Empty stdout, process alive forever | Killed watchdog failed — Go ignores SIGALRM | Kill the process group (see Liveness) |
| Lane needs to run a build/test and silently does nothing | Shell is gated in headless | Restructure: lane edits, orchestrator builds |
| `^D` and spinner frames in output | A PTY wrapper was used | Drop `script`; use plain redirection |
| `timeout: command not found` | Not on stock macOS | Use the process-group recipe |

## Relationship to codex-fleet

Same orchestration philosophy — background-first, parallel by default, briefs as contracts, verify claims. Different substrate, and the differences matter:

| | codex-fleet | gemini-fleet |
|---|---|---|
| Working dir | `-C <dir>`, optional | `--add-dir <dir>`, **mandatory** |
| Effort | `-c model_reasoning_effort=high` | baked into model slug |
| Read-only | `--sandbox read-only` | `--mode plan` |
| Write | `--sandbox workspace-write --full-auto` | `--mode accept-edits` |
| Stderr | `2>/dev/null` | **never discard** |
| Structured output | parse stdout | `--output-format json` + `jq` |
| Shell in lanes | yes | gated — orchestrator's job |
| Image generation | `gpt-image-2` | not available |

Use `codex-fleet` for image assets and for lanes that must run shell themselves. Use `gemini-fleet` for Gemini-model delegates on the user's Google subscription, and when you want two independent model families reviewing the same problem.

---

## Credits

Structure and orchestration doctrine adapted from **codex-fleet** by [Avenox](https://avenox.lol), shared freely. The worktree-per-lane pattern, the OWNS / DO-NOT-TOUCH brief contract, and "completions are claims, not evidence" originate there and transfer to any terminal agent.

Source: https://github.com/RemeDegen/gemini-fleet — MIT.
