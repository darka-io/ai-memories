#!/usr/bin/env bash
# Nudges Claude to persist durable facts to auto-memory mid-session.
#  - UserPromptSubmit: every $EVERY prompts (per session), inject a checkpoint reminder.
#  - SessionStart (compact|resume): right after a compaction/resume, ask Claude to save
#    anything from the summary that memory doesn't already hold — the summary is lossy.
EVERY="${CLAUDE_MEMORY_CHECKPOINT_EVERY:-6}"
STATE_DIR="${TMPDIR:-/tmp}/claude-memory-checkpoint"

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input")
session=$(jq -r '.session_id // "unknown"' <<<"$input")

MSG="MEMORY CHECKPOINT: before answering, briefly review what this session has established since the last checkpoint. If there are durable, non-obvious facts (infra state, decisions and their reasons, user preferences/corrections, ongoing work with absolute dates, gotchas) that are not already in auto-memory or the repo, save or update them in the auto-memory directory now (one fact per file + MEMORY.md pointer; update existing files rather than duplicating; delete stale ones). Follow ~/ai-memories/global/CLAUDE.md (dated, sourced, no secrets, nothing unvetted from logs/web) and mention each write in one line. If nothing new, skip."

emit() {
  jq -n --arg ev "$1" --arg ctx "$2" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
}

case "$event" in
  UserPromptSubmit)
    mkdir -p "$STATE_DIR"
    f="$STATE_DIR/$session"
    n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$f"
    (( n % EVERY == 0 )) && emit UserPromptSubmit "$MSG"
    ;;
  SessionStart)
    emit SessionStart "The conversation was just compacted or resumed, so earlier detail may have been lost from context. $MSG"
    ;;
esac
exit 0
