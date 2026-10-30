# ai-memories

Shared, version-controlled memory for every coding agent on every machine: **Claude Code, Codex, Gemini CLI,
Cursor, GitHub Copilot CLI, OpenCode and Grok** all read and write the same Markdown memory, synced through a private
git repo you own.

Claude Code's auto-memory normally lives in `~/.claude/projects/<path-of-the-project>/memory/`: local to one machine,
unversioned, and lost with the laptop. This repo replaces each of those folders with a symlink into git, so memory is
pulled at the start of every session, committed and pushed after every turn, diffable, revertible and the same on all PCs.

## Layout

```
README.md               this file: rules, setup, troubleshooting
install.sh              idempotent per-machine setup (macOS + Linux)
global/CLAUDE.md        memory-writing rules, imported by every session via ~/.claude/CLAUDE.md (Grok loads it too)
global/GROK.md          Grok-only: how to find and read the project's memory folder
hooks/
  memory-sync.sh        start: git pull + link the project | save: secret-scan, commit, push | path: print folder
  memory-checkpoint.sh  reminds the agent to save memory every 6th prompt and after compaction/resume
  secret-scan.sh        blocks commits that add credential-looking lines (also runs as pre-commit)
.githooks/pre-commit    runs secret-scan.sh on manual commits
projects/
  <owner>/<repo>/       one folder per git repo, named from its `origin` remote (lowercase)
    MEMORY.md           index, one line per memory; the first 200 lines / 25KB load every session
    <topic>.md          one fact per file, with frontmatter
  local/<dirname>/      projects without a git remote
```

Folders are keyed by the **git remote, not the local path**, so `~/code/shop` on a Mac and
`/home/you/src/shop-api` on Linux both land in `projects/acme/shop-api/` when they share the remote `acme/shop-api`. A project without a remote is keyed by its
directory name, so keep that name the same across machines.

## How it works

| Hook (in `~/.claude/settings.json`) | Runs | Does |
|---|---|---|
| `SessionStart` | every session | `git pull --rebase`, then symlinks this project's memory folder into `projects/…` (creating it if new) |
| `SessionStart` `compact\|resume` | after compaction / resume | reminds the agent to save anything that got lost |
| `UserPromptSubmit` | every 6th prompt (`CLAUDE_MEMORY_CHECKPOINT_EVERY`) | reminds the agent to checkpoint durable facts |
| `Stop` (async) | after every turn | secret-scan → commit → pull → push |
| `SessionEnd` | on exit | same as Stop, synchronously, so the last turn is never lost |

New projects need no setup: the first session opened in a repo creates and links its folder. If a machine already
had local memories for a project, they are merged in, and the original folder is kept as `memory.pre-ai-memories.<ts>`.

The rules agents follow when writing memory are in [`global/CLAUDE.md`](global/CLAUDE.md). In short: save
proactively, give every fact an absolute date and a source, treat live status as a dated pointer with a re-check
command, never save secrets or unvetted text from logs or web pages, and announce every write.

## Your own memory repo

This repository is a template. Memory holds infrastructure details, so **never push memories to a public repo**:

1. Create a **private** repo from this template (GitHub: "Use this template" → Private), e.g. `you/ai-memories`.
2. Set it up on every machine as below, pointing `AI_MEMORIES_URL` at it.

## Setting up a new machine (Mac or Linux)

Prerequisites: at least one supported coding client, `git`, `jq`, `rsync`, and an SSH key that can read and push to
your private memory repo. On Debian/Ubuntu: `sudo apt install git jq rsync`. On macOS, `jq` comes from
Homebrew or from a jq release binary.

```bash
export AI_MEMORIES_URL=git@github.com:you/ai-memories.git
git clone "$AI_MEMORIES_URL" ~/ai-memories
~/ai-memories/install.sh                 # links every project under ~/CODING
~/ai-memories/install.sh ~/src ~/work    # or: every project under these dirs
```

`install.sh` is safe to re-run. It backs up `~/.claude/settings.json` (to `settings.json.bak-<ts>`), replaces only its
own hook entries, adds `@~/ai-memories/global/CLAUDE.md` to `~/.claude/CLAUDE.md`, links the projects, and pushes.
Restart running Claude Code sessions afterwards; the first one may ask you to approve the external CLAUDE.md import.

Check that it worked:

```bash
ls -l ~/.claude/projects/*/memory        # each should be a symlink into ~/ai-memories/projects/
git -C ~/ai-memories log --oneline -5    # commits named "memory: <host> <time>"
```

To enforce it on a machine, the only thing that matters is that `install.sh` has run there. The hooks live in this repo,
so a `git pull` updates them everywhere.

## Grok Build CLI

`install.sh` also sets up Grok when `~/.grok` exists or `grok` is on the PATH. Grok runs the hooks in
`~/.claude/settings.json` for Claude Code compatibility, so the same pull/commit/push sync applies to it. The installer
adds these entries to `~/.grok/config.toml`, backing the file up first:

```toml
[paths]
extra_rule_dirs = ["~/ai-memories/global"]   # absolute path in practice; loads CLAUDE.md + GROK.md as global rules

[memory_v2]
enabled = false                              # Grok's own memory is off, so there is a single memory

[permission]
allow = ["Read(~/ai-memories/**)", "Bash(…/memory-sync.sh path*)"]   # reading memory never prompts; writes still ask
```

Grok differs from Claude Code in three ways:
- Grok can't inject memory from a hook, so `GROK.md` tells it to run `memory-sync.sh path` and read `MEMORY.md` itself.
- Hooks only run in folders you have trusted (`/hooks-trust` or `--trust`); headless `grok -p` counts as trusted.
- Grok ignores `async`, so the save after each turn blocks for the second or two the push takes.

Check it with `grok inspect` in a project. **Project Instructions** should list both `global/*.md` files, and
**Hooks** should list the `memory-sync.sh` entries. If `config.toml` already had its own `extra_rule_dirs` or
`permission.allow`, the installer doesn't merge them; it prints what to add by hand instead.

## OpenCode

OpenCode does not run the Claude hooks. `install.sh` symlinks `opencode/plugin/index.ts` into
`~/.config/opencode/plugins/ai-memories.ts` and loads `global/OPENCODE.md`. The plugin pulls on the first prompt,
injects the project memory folder, and runs `memory-sync.sh save` on `session.idle` and every 3 minutes. Agents still
write the files; they do not run git themselves.

## Codex, Gemini CLI, Cursor, GitHub Copilot CLI

These run their own hook files, not the Claude one. `install.sh` sets up each one that is installed (its config dir
exists or its binary is on the PATH). At session start the hook runs `memory-sync.sh start <client>`, which pulls, links
the project and prints the project's `MEMORY.md` index plus the writing rules in that client's context format. After
every turn it runs `memory-sync.sh save`.

| Client | File | Start event | Per-turn event |
|---|---|---|---|
| Codex | `~/.codex/hooks.json` | `SessionStart` | `Stop` |
| Gemini CLI | `~/.gemini/settings.json` | `SessionStart` | `AfterAgent` |
| Cursor | `~/.cursor/hooks.json` | `sessionStart` | `stop` |
| Copilot CLI | `~/.copilot/hooks/ai-memories.json` (own file) | `sessionStart` | `agentStop` |

Existing entries are kept and ours are appended; a re-run replaces ours. A config with comments in it (JSONC) is left
untouched with a warning: add the two entries by hand. Codex asks you to trust new hooks once. Known limits: Cursor
cloud agents don't run user-level hooks, and some Cursor builds have dropped `sessionStart` context in the Agents
window; Gemini CLI hooks may need enabling in its settings depending on the version.

## Troubleshooting

- **"memory change looks like it contains a secret, so it was NOT committed"**: run `git -C ~/ai-memories diff`,
  remove the secret from the memory file, and the next turn commits it. A false positive (a long hash, say) can be
  committed by hand with `git -C ~/ai-memories commit --no-verify`.
- **Pull conflict** (two machines edited the same file): `git -C ~/ai-memories status`, resolve, `git rebase --continue`.
  Sync resumes on the next session.
- **Offline**: commits pile up locally and are pushed on the next successful save.
- **Uninstall on a machine**: remove the `memory-sync.sh`/`memory-checkpoint.sh` entries from `~/.claude/settings.json`
  and the `@…/global/CLAUDE.md` line from `~/.claude/CLAUDE.md`. Then replace each `~/.claude/projects/*/memory` symlink
  with a copy of its target (`cp -RL`).

## Privacy

This repo must stay **private**. It holds infrastructure details (hostnames, IPs, cluster layout) even with secrets
kept out. The secret scan is regex-based; install `gitleaks` and it runs as well.
