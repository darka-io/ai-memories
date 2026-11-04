#!/usr/bin/env bash
# Keeps Claude Code auto-memory inside the ai-memories git repo.
#   memory-sync.sh start          SessionStart hook: pull, then link this session's project into the repo
#   memory-sync.sh context kimi   UserPromptSubmit hook: inject Kimi's memory index once per session
#   memory-sync.sh clear-context  PostCompact hook: allow Kimi's next prompt to inject the index again
#   memory-sync.sh save           Stop/SessionEnd hook: secret-scan, commit and push memory changes
#   memory-sync.sh link <dir>     link one project directory (install.sh uses this)
#   memory-sync.sh path [dir]     print the project's memory folder in the repo (Grok uses this)
#
# Claude Code keeps a project's memory in ~/.claude/projects/<sanitized-path>/memory. That name is
# derived from the local path, so it differs per machine. We replace it with a symlink to
# projects/<owner>/<repo> (from the git remote), which is the same on every machine.
set -uo pipefail
REPO="${AI_MEMORIES_DIR:-$HOME/ai-memories}"
CLAUDE_PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
LOCK="$REPO/.git/memory-sync.lock"

t() { local s=$1; shift; if command -v timeout >/dev/null; then timeout "$s" "$@"; else "$@"; fi; }

# Serialise git operations across concurrent sessions; a lock older than ~10s is treated as stale.
with_lock() {
  local i
  for i in $(seq 1 20); do mkdir "$LOCK" 2>/dev/null && break; sleep 0.5; done
  "$@"; local rc=$?
  rmdir "$LOCK" 2>/dev/null
  return $rc
}

# Project root as Claude Code sees it: the main worktree of a git repo, else the directory itself.
root_for() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && { dirname "$common"; return; }
  (cd "$1" && pwd -P)
}

# projects/<owner>/<repo> from the origin remote, or projects/local/<dirname> without one.
slug_for() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null)
  if [ -n "$url" ]; then
    url=${url%.git}; url=${url%/}
    echo "$url" | tr ':' '/' | awk -F/ '{print tolower($(NF-1)) "/" tolower($NF)}'
  else
    echo "local/$(basename "$1" | tr '[:upper:]' '[:lower:]')"
  fi
}

link() {
  local root slug target mem
  root=$(root_for "$1") || return 0
  # a session in $HOME or / is not a project
  if [ "$root" = "$HOME" ] || [ "$root" = / ]; then return 0; fi
  slug=$(slug_for "$root")
  target="$REPO/projects/$slug"
  mem="$CLAUDE_PROJECTS/$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')/memory"
  mkdir -p "$target" "$(dirname "$mem")"
  if [ -L "$mem" ]; then
    [ "$(readlink "$mem")" = "$target" ] && return 0
    rm "$mem"
  elif [ -d "$mem" ]; then
    # This machine already has local memories for the project: merge them in, keep the original.
    if [ -f "$mem/MEMORY.md" ] && [ -f "$target/MEMORY.md" ]; then
      grep -vxFf "$target/MEMORY.md" "$mem/MEMORY.md" >>"$target/MEMORY.md" || true
    fi
    rsync -a --ignore-existing "$mem/" "$target/"
    mv "$mem" "$mem.pre-ai-memories.$(date +%Y%m%d%H%M%S)"
  fi
  [ -f "$target/MEMORY.md" ] || : >"$target/MEMORY.md"
  ln -s "$target" "$mem"
}

pull() { t 15 git -C "$REPO" pull --rebase --autostash -q >&2 2>/dev/null || echo "ai-memories: pull failed (offline or conflict)" >&2; }

commit_and_push() {
  cd "$REPO" || return 0
  git add -A projects
  git diff --cached --quiet && return 0
  if ! "$REPO/hooks/secret-scan.sh"; then
    git reset -q
    jq -n '{systemMessage: "ai-memories: memory change looks like it contains a secret, so it was NOT committed. Review with: git -C ~/ai-memories diff"}'
    return 0
  fi
  git commit -q --no-verify -m "memory: $(hostname -s) $(date -u +%Y-%m-%dT%H:%MZ)"
  pull
  t 20 git push -q origin HEAD 2>/dev/null || echo "ai-memories: push failed, will retry on next save" >&2
}

KIMI_STATE_DIR="${TMPDIR:-/tmp}/ai-memories-kimi"

kimi_state_file() {
  local session
  session=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9_-]/-/g')
  echo "$KIMI_STATE_DIR/$session"
}

clear_kimi_context() {
  rm -f "$(kimi_state_file "$1")"
}

# Clients without Claude Code's auto-memory get the index injected in their own hook format.
context() {
  local dir text
  dir="$REPO/projects/$(slug_for "$(root_for "$1")")"
  text="Shared memory for this project is $dir (git repo ~/ai-memories, synced by hooks; never run git there).
Write durable facts there following $REPO/global/CLAUDE.md: one fact per file with frontmatter, one-line pointer in MEMORY.md.
MEMORY.md index:
$(head -c 25000 "$dir/MEMORY.md" 2>/dev/null)"
  case "$2" in
    cursor)        jq -n --arg t "$text" '{additional_context: $t}' ;;
    copilot)       jq -n --arg t "$text" '{additionalContext: $t}' ;;
    gemini|codex)  jq -n --arg t "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $t}}' ;;
    kimi)          printf '%s\n' "$text" ;;
  esac
}

case "${1:-}" in
  start)
    # start [cursor|copilot|gemini|codex]: the optional client name also prints the memory index as context.
    input=$(cat 2>/dev/null || true)
    cwd=$(jq -r '.cwd // .workspace_roots[0] // empty' <<<"$input" 2>/dev/null)
    session=$(jq -r '.session_id // "unknown"' <<<"$input" 2>/dev/null)
    clear_kimi_context "$session"
    with_lock pull
    link "${cwd:-$PWD}"
    [ -n "${2:-}" ] && context "${cwd:-$PWD}" "$2"
    ;;
  context)
    # Kimi SessionStart is observation-only, so inject once on UserPromptSubmit instead.
    input=$(cat 2>/dev/null || true)
    cwd=$(jq -r '.cwd // .workspace_roots[0] // empty' <<<"$input" 2>/dev/null)
    session=$(jq -r '.session_id // "unknown"' <<<"$input" 2>/dev/null)
    state=$(kimi_state_file "$session")
    [ -f "$state" ] && exit 0
    mkdir -p "$KIMI_STATE_DIR"
    : >"$state"
    context "${cwd:-$PWD}" "${2:-kimi}"
    ;;
  clear-context)
    input=$(cat 2>/dev/null || true)
    session=$(jq -r '.session_id // "unknown"' <<<"$input" 2>/dev/null)
    clear_kimi_context "$session"
    ;;
  save)
    cat >/dev/null 2>&1 || true
    with_lock commit_and_push
    ;;
  link)
    shift; for d in "$@"; do link "$d"; done
    ;;
  path)
    # memory folder for a project dir (default: current dir); for agents without the symlink, e.g. Grok
    echo "$REPO/projects/$(slug_for "$(root_for "${2:-$PWD}")")"
    ;;
  *) echo "usage: $0 {start|context|clear-context|save|link <dir>...|path [dir]}" >&2; exit 1 ;;
esac
exit 0
