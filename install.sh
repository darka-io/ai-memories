#!/usr/bin/env bash
# Sets up ai-memories for Claude Code on this machine (macOS or Linux). Idempotent: re-run any time.
#
#   ./install.sh                     # link every project directory under ~/CODING
#   ./install.sh ~/src ~/work/repo   # link every project under these dirs (a git repo itself counts as one)
#
# Env overrides: AI_MEMORIES_URL, AI_MEMORIES_DIR (default ~/ai-memories), CLAUDE_CONFIG_DIR (default ~/.claude)
set -euo pipefail
REPO_URL="${AI_MEMORIES_URL:-}"   # your PRIVATE memory repo, made from this template
REPO="${AI_MEMORIES_DIR:-$HOME/ai-memories}"
CLAUDE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

for bin in git jq rsync; do command -v "$bin" >/dev/null || { echo "install.sh: missing $bin" >&2; exit 1; }; done

if [ ! -d "$REPO/.git" ]; then
  [ -n "$REPO_URL" ] || { echo "install.sh: set AI_MEMORIES_URL to your private memory repo (see README)" >&2; exit 1; }
  git clone "$REPO_URL" "$REPO"
fi
git -C "$REPO" config core.hooksPath .githooks
chmod +x "$REPO"/hooks/*.sh "$REPO"/.githooks/*

# 1. Hooks in the user settings. Any earlier ai-memories entries are replaced, everything else is kept.
mkdir -p "$CLAUDE"
S="$CLAUDE/settings.json"
[ -f "$S" ] || echo '{}' >"$S"
cp "$S" "$S.bak-$(date +%Y%m%d%H%M%S)"
H="$REPO/hooks"
jq --arg sync "$H/memory-sync.sh" --arg ck "$H/memory-checkpoint.sh" '
  def strip: map(.hooks |= map(select((.command // "") | test("memory-(sync|checkpoint)\\.sh") | not)))
             | map(select(.hooks | length > 0));
  .hooks //= {}
  | .hooks.SessionStart = ((.hooks.SessionStart // [] | strip) + [
      {hooks: [{type: "command", command: ($sync + " start"), timeout: 30}]},
      {matcher: "compact|resume", hooks: [{type: "command", command: $ck, timeout: 10}]}])
  | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [] | strip) + [
      {hooks: [{type: "command", command: $ck, timeout: 10}]}])
  | .hooks.Stop = ((.hooks.Stop // [] | strip) + [
      {hooks: [{type: "command", command: ($sync + " save"), async: true, timeout: 60}]}])
  | .hooks.SessionEnd = ((.hooks.SessionEnd // [] | strip) + [
      {hooks: [{type: "command", command: ($sync + " save"), timeout: 30}]}])
' "$S" >"$S.tmp" && mv "$S.tmp" "$S"

# 2. Shared memory rules, imported into the user-level CLAUDE.md that every session loads.
CM="$CLAUDE/CLAUDE.md"
LINE="@$REPO/global/CLAUDE.md"
grep -qxF "$LINE" "$CM" 2>/dev/null || printf '%s\n' "$LINE" >>"$CM"

# 3. Grok Build CLI, if installed. It already runs the hooks above from ~/.claude/settings.json once a folder is
#    trusted, but it can't inject context from them, so global/GROK.md tells it where memory is. Its own memory store
#    is turned off so there is only one memory.
toml_set() { # file table key value: adds the key only when absent, creating the table if needed
  awk -v tbl="[$2]" -v key="$3" -v line="$3 = $4" '
    $0 == tbl { intbl = 1; seen = 1; print; next }
    /^\[/ { if (intbl && !done) { print line; done = 1 }; intbl = 0 }
    intbl && $0 ~ "^" key "[ \t]*=" { done = 1 }
    { print }
    END { if (!seen) { print ""; print tbl; print line } else if (intbl && !done) print line }
  ' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}
GROK_DIR="${GROK_HOME:-$HOME/.grok}"
if [ -d "$GROK_DIR" ] || command -v grok >/dev/null; then
  GT="$GROK_DIR/config.toml"
  mkdir -p "$GROK_DIR"; touch "$GT"; cp "$GT" "$GT.bak-$(date +%Y%m%d%H%M%S)"
  toml_set "$GT" paths extra_rule_dirs "[\"$REPO/global\"]"
  toml_set "$GT" memory_v2 enabled false
  # Reading memory and finding its folder never prompt. Writes still ask, which keeps a human on memory changes.
  toml_set "$GT" permission allow "[\"Read($REPO/**)\", \"Bash(~/ai-memories/hooks/memory-sync.sh path*)\", \"Bash($H/memory-sync.sh path*)\"]"
  grep -qF "$REPO/global" "$GT" || echo "install.sh: $GT already sets paths.extra_rule_dirs; add \"$REPO/global\" to it by hand" >&2
  grep -qF "Read($REPO/**)" "$GT" || echo "install.sh: $GT already sets permission.allow; add \"Read($REPO/**)\" and the memory-sync.sh path rule by hand" >&2
fi

# 3b. OpenCode does not run the Claude hooks. Load the same rules and a plugin that commits on idle.
OC="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
mkdir -p "$OC/plugins"
ln -sfn "$REPO/opencode/plugin/index.ts" "$OC/plugins/ai-memories.ts"
OC_JSON="$OC/opencode.jsonc"
[ -f "$OC_JSON" ] || echo '{ "$schema": "https://opencode.ai/config.json" }' >"$OC_JSON"
cp "$OC_JSON" "$OC_JSON.bak-$(date +%Y%m%d%H%M%S)"
jq --arg claude "$REPO/global/CLAUDE.md" --arg grok "$REPO/global/GROK.md" --arg oc "$REPO/global/OPENCODE.md" --arg repo "$REPO" '
  .instructions = ((.instructions // []) + [$claude, $grok, $oc] | unique)
  | .permissions = ((.permissions // []) + [
      {action:"read", resource:($repo + "/*"), effect:"allow"},
      {action:"edit", resource:($repo + "/projects/*"), effect:"allow"},
      {action:"external_directory", resource:($repo + "/*"), effect:"allow"},
      {action:"shell", resource:($repo + "/hooks/memory-sync.sh *"), effect:"allow"}
    ] | unique)
' "$OC_JSON" >"$OC_JSON.tmp" && mv "$OC_JSON.tmp" "$OC_JSON"
AGENTS="$OC/AGENTS.md"
MARKER="Shared memory is \`~/ai-memories\`"
grep -qF "$MARKER" "$AGENTS" 2>/dev/null || cat >>"$AGENTS" <<'EOF'

# Shared memory

Before other work, read `~/ai-memories/global/OPENCODE.md` and follow it.

Shared memory is `~/ai-memories`, not OpenCode's own notes. Find this project's folder with `~/ai-memories/hooks/memory-sync.sh path`, read its `MEMORY.md`, and write durable facts there. Do not run git in `~/ai-memories`. Commit only through `~/ai-memories/hooks/memory-sync.sh save`. The ai-memories plugin does that on session idle and every 3 minutes.
EOF

# 3c. Other clients run their own hook files. Each gets: pull + link + memory index as context at session start,
#     save after every turn. Our entries are appended after existing ones (Codex keys hook trust by position) and
#     replaced on re-run. Every client is set up only when it is installed.
has() { [ -d "$1" ] || command -v "$2" >/dev/null; }
backup() { local def=${2-}; [ -n "$def" ] || def='{}'; [ -f "$1" ] || echo "$def" >"$1"; cp "$1" "$1.bak-$(date +%Y%m%d%H%M%S)"; }
# A config with comments (JSONC) can't go through jq: leave it alone and say so instead of aborting the install.
jq_edit() { local f=$1; shift; jq "$@" "$f" >"$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || { rm -f "$f.tmp"; echo "install.sh: could not edit $f (comments in JSON?); add the ai-memories hooks by hand, see README" >&2; }; }
# Claude-shaped hooks file (Codex, Gemini): file, start event, per-turn event, client name, timeout start, timeout save
claude_shaped() {
  backup "$1"
  jq_edit "$1" --arg sync "$H/memory-sync.sh" --arg se "$2" --arg te "$3" --arg c "$4" --argjson ts "$5" --argjson tt "$6" '
    def strip: map(.hooks |= map(select((.command // "") | test("memory-(sync|checkpoint)\\.sh") | not)))
               | map(select(.hooks | length > 0));
    .hooks //= {}
    | .hooks[$se] = ((.hooks[$se] // [] | strip) + [{hooks: [{type: "command", command: ($sync + " start " + $c), timeout: $ts}]}])
    | .hooks[$te] = ((.hooks[$te] // [] | strip) + [{hooks: [{type: "command", command: ($sync + " save"), timeout: $tt}]}])
  '
}

CX="${CODEX_HOME:-$HOME/.codex}"
if has "$CX" codex; then mkdir -p "$CX"; claude_shaped "$CX/hooks.json" SessionStart Stop codex 30 60; fi

GM="${GEMINI_HOME:-$HOME/.gemini}"   # Gemini CLI: timeouts in ms; AfterAgent fires once per turn
if has "$GM" gemini; then mkdir -p "$GM"; claude_shaped "$GM/settings.json" SessionStart AfterAgent gemini 30000 60000; fi

CU="$HOME/.cursor"                   # Cursor: flat entries, sessionStart/stop, version 1
if has "$CU" cursor; then
  mkdir -p "$CU"; backup "$CU/hooks.json" '{"version":1}'
  jq_edit "$CU/hooks.json" --arg sync "$H/memory-sync.sh" '
    def strip: map(select((.command // "") | test("memory-(sync|checkpoint)\\.sh") | not));
    .version //= 1 | .hooks //= {}
    | .hooks.sessionStart = ((.hooks.sessionStart // [] | strip) + [{command: ($sync + " start cursor"), timeout: 30}])
    | .hooks.stop = ((.hooks.stop // [] | strip) + [{command: ($sync + " save"), timeout: 60}])
  '
fi

CP="${COPILOT_HOME:-$HOME/.copilot}" # Copilot CLI: loads every ~/.copilot/hooks/*.json, so ours is its own file
if has "$CP" copilot; then
  mkdir -p "$CP/hooks"
  jq -n --arg sync "$H/memory-sync.sh" '{version: 1, hooks: {
    sessionStart: [{type: "command", bash: ($sync + " start copilot"), timeoutSec: 30}],
    agentStop:    [{type: "command", bash: ($sync + " save"), timeoutSec: 60}]}}' >"$CP/hooks/ai-memories.json"
fi

KIMI="${KIMI_CODE_HOME:-$HOME/.kimi-code}" # Kimi uses flat TOML hook entries in config.toml.
if has "$KIMI" kimi; then
  mkdir -p "$KIMI"
  KT="$KIMI/config.toml"
  [ -f "$KT" ] || : >"$KT"
  cp "$KT" "$KT.bak-$(date +%Y%m%d%H%M%S)"
  awk '
    hook && /^\[/ {
      if (block !~ /memory-(sync|checkpoint)\.sh/) printf "%s", block
      hook = 0; block = ""
    }
    /^\[\[hooks\]\][ \t]*$/ { hook = 1; block = $0 ORS; next }
    hook { block = block $0 ORS; next }
    { print }
    END { if (hook && block !~ /memory-(sync|checkpoint)\.sh/) printf "%s", block }
  ' "$KT" >"$KT.tmp" && mv "$KT.tmp" "$KT"
  cat >>"$KT" <<EOF

[[hooks]]
event = "SessionStart"
command = "$H/memory-sync.sh start"
timeout = 30

[[hooks]]
event = "UserPromptSubmit"
command = "$H/memory-sync.sh context kimi"
timeout = 10

[[hooks]]
event = "UserPromptSubmit"
command = "$H/memory-checkpoint.sh kimi"
timeout = 10

[[hooks]]
event = "PostCompact"
command = "$H/memory-sync.sh clear-context"
timeout = 10

[[hooks]]
event = "Stop"
command = "$H/memory-sync.sh save"
timeout = 60

[[hooks]]
event = "SessionEnd"
command = "$H/memory-sync.sh save"
timeout = 30
EOF
fi

# 4. Link projects. New projects get linked automatically by the SessionStart hook later on.
[ $# -gt 0 ] || set -- "$HOME/CODING"
for root in "$@"; do
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1 && [ "$(git -C "$root" rev-parse --show-toplevel)" = "$(cd "$root" && pwd -P)" ]; then
    "$H/memory-sync.sh" link "$root"
  else
    for d in "$root"/*/; do [ -d "$d" ] && "$H/memory-sync.sh" link "${d%/}"; done
  fi
done

# 5. Commit and push whatever was migrated.
"$H/memory-sync.sh" save </dev/null
echo "ai-memories installed. Linked projects:"
find "$CLAUDE/projects" -maxdepth 2 -name memory -type l -exec sh -c 'printf "  %s -> %s\n" "$(basename "$(dirname "$1")")" "$(readlink "$1")"' _ {} \; 2>/dev/null || true
