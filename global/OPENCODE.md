# OpenCode and shared memory

OpenCode does not run the Claude Code hooks. These rules apply in every OpenCode session.

At the start of a session, before other work:

1. Run `~/ai-memories/hooks/memory-sync.sh path` from the project directory. It prints `~/ai-memories/projects/<owner>/<repo>`.
2. Read `MEMORY.md` there, then any topic file whose description matters for the task.
3. Follow `~/ai-memories/global/CLAUDE.md` when writing memory: one fact per file with frontmatter, a one-line pointer in `MEMORY.md`, absolute dates, a source, no secrets, and announce each write in one line.

Do not run git in `~/ai-memories` yourself. The `ai-memories` OpenCode plugin calls `memory-sync.sh save` when a session goes idle and every 3 minutes. That script secret-scans, commits `projects/`, and pushes. If you just wrote a memory and need it committed before idle, run `~/ai-memories/hooks/memory-sync.sh save` and nothing else.

Every 6th prompt, checkpoint durable facts the same way. If nothing new is worth saving, skip the write.
