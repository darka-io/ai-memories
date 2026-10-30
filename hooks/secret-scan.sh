#!/usr/bin/env bash
# Exits 1 if the staged diff adds a line that looks like a credential. Used by memory-sync.sh and
# the pre-commit hook. Prints only file names, never the matched text, so a hit can't leak into
# a transcript. Regex-based on purpose (no extra dependency); use gitleaks too if it's installed.
PATTERNS='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|xox[abprs]-[A-Za-z0-9-]{10,}|AGE-SECRET-KEY-1[0-9A-Z]{50,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.|(password|passwd|secret|token|api[_-]?key)["'"'"' ]*[:=]["'"'"' ]*[^ "'"'"'<>$]{12,}|[A-Za-z0-9+/]{64,}={0,2}'

bad=0
while IFS= read -r f; do
  if git diff --cached -U0 --no-color -- "$f" | grep '^+' | grep -v '^+++' | grep -qEi -- "$PATTERNS"; then
    echo "secret-scan: suspicious content in $f" >&2
    bad=1
  fi
done < <(git diff --cached --name-only --diff-filter=AM)

if [ $bad -eq 0 ] && command -v gitleaks >/dev/null; then
  gitleaks git --staged --no-banner --redact -v >/dev/null 2>&1 || { echo "secret-scan: gitleaks flagged staged changes" >&2; bad=1; }
fi
exit $bad
