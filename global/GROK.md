# Shared memory for Grok (from ~/ai-memories)

You share one memory with the Claude Code agents on this machine and the user's other PCs: the private git repo
`~/ai-memories`. Grok's built-in memory is turned off on purpose, so don't use `/remember` or `~/.grok/memory-v2`.

At the start of every session, before other work:
1. Find this project's memory folder by running `~/ai-memories/hooks/memory-sync.sh path`.
   It prints `~/ai-memories/projects/<owner>/<repo>`.
2. Read `MEMORY.md` in that folder, then read any topic file whose description matters for the task.

When you learn a durable fact, write it into that folder by following the rules in `CLAUDE.md` (loaded next to this
file): one fact per file with frontmatter, plus a one-line pointer in `MEMORY.md`. Use absolute dates, give a source,
store live status as dated pointers with a re-check command, never save secrets, and announce each write.

Hooks pull the repo when a session starts and commit and push it after every turn. Don't run git in `~/ai-memories`
yourself.
