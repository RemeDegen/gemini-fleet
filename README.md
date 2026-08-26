# gemini-fleet

A [Claude Code](https://claude.com/claude-code) skill that drives Google's **Antigravity CLI (`agy`)** as a delegate and fleet runner for Gemini models — from inside a Claude session.

Ask Claude *"have Gemini review this module"* or *"spawn a 3-lane Gemini fleet on these directories"*, and it runs real `agy` processes in the background, verifies their output, and reports back.

**Runs on your Google subscription via keyring OAuth. No API key. No `--dangerously-skip-permissions`.**

It is the Gemini-side sibling of [`codex-fleet`](https://avenox.lol), which does the same for OpenAI's Codex CLI — same orchestration philosophy, different substrate, and a different set of traps.

---

## Why this exists

Google moved the consumer subscription rail off Gemini CLI on 18 June 2026. `gemini` now needs an API key or Vertex; `agy` is the binary that talks to your Google AI subscription. So if you want Gemini agents without paying per token, `agy` is the only local road — and its headless mode has sharp edges that aren't in the docs.

This skill is the map of those edges.

## Every rule here was measured

The skill contains no guesses. Each rule was verified against **`agy 1.1.20` on macOS (darwin/arm64), 2026-08-26**. Where a rule contradicts the upstream docs or an open GitHub issue, the measurement won and the discrepancy is documented in place.

Four findings worth knowing before you write your own wrapper:

| Finding | Why it matters |
|---|---|
| **`--add-dir` is mandatory** | Without a registered workspace, `agy` falls back to a shell command to read a file — and headless auto-denies shell. Even *reading* fails. This flag is why you never need `--dangerously-skip-permissions`. |
| **`"status":"SUCCESS"` lies** | A fully blocked run still returns `SUCCESS` with an empty `response`. The real reason appears only on stderr. Never `2>/dev/null`. |
| **`--print-timeout` defaults to 5 minutes** | Any real refactor lane runs past it and gets cut off mid-edit with no report. |
| **`--add-dir` is necessary but not sufficient** | Identical prompt and flags: one run wrote the file, another hit the permission denial. The model sometimes chooses to `cat >` instead of using the write tool. Mitigate with an explicit tool constraint in the brief *and* the acceptance gate. |

There is also a fifth, cheap to miss: **`agy` reads `GEMINI.md`, not `CLAUDE.md`.** Verified with three competing directive files in one workspace. `ln -s CLAUDE.md GEMINI.md` keeps both agents on the same rules.

## Install

```bash
# 1. Antigravity CLI
curl -fsSL https://antigravity.google/cli/install.sh | bash   # macOS / Linux
agy                                                            # sign in once, then quit

# 2. The skill
git clone https://github.com/RemeDegen/gemini-fleet.git ~/.claude/skills/gemini-fleet
```

Claude Code picks it up on the next session. Verify with `agy --version` and `agy models`.

## Use

You don't type `agy` — you ask Claude:

```
have gemini review src/auth.ts for race conditions
spawn a gemini fleet over backend/, frontend/ and contracts/
get gemini to fix the failing parser, then run the tests yourself
```

Claude picks the model tier, scopes the workspace, runs lanes in the background, applies the acceptance gate, and summarises. Measured: 4 concurrent lanes, 7s wall time, no contention.

## Know the limits

- **Lanes cannot run shell.** They read, write and edit files; they cannot run `npm test`, `tsc`, or `git`. The orchestrator does that. This is a real constraint — and a quiet benefit, since a lane physically cannot report a fake test result.
- **No image generation.** `agy models` lists text models only. Use `codex-fleet` for image assets.
- **Cost.** A trivial prompt is ~13.7k input tokens; with `--add-dir` it's ~45k, because workspace context loads. Scope lane directories narrowly — that's a quota decision, not a performance one.

## Windows: unverified, do not assume

Everything above was measured on macOS. The skill's shell recipes (`caffeinate`, process-group kills, `jq`) are Unix-shaped, and — more importantly — the Antigravity CLI has open issues on Windows in exactly the mechanism this depends on: [#76](https://github.com/google-antigravity/antigravity-cli/issues/76) (stdout silently dropped under non-TTY), [#318](https://github.com/google-antigravity/antigravity-cli/issues/318) (hangs indefinitely), [#548](https://github.com/google-antigravity/antigravity-cli/issues/548) (headless ignores `permissions.allow`).

Those reports span 1.0.5–1.1.8 and may be fixed by now. Rather than guess, measure:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\agy-windows-test.ps1
```

It runs six non-TTY checks — auth, print, JSON, read lane, write lane, 3-way parallelism — reaps anything that hangs, and ends with a verdict. If it fails, don't install the skill on that machine; it would fail silently, which is the worst way to fail.

PRs with Windows results welcome.

## Credits

Structure and orchestration doctrine adapted from **codex-fleet** by [Avenox](https://avenox.lol), shared freely. The worktree-per-lane pattern, the OWNS / DO-NOT-TOUCH brief contract, and *"completions are claims, not evidence"* come from there and transfer to any terminal agent.

MIT licensed.
