#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
# Usage:
#   ./git-commit-opencode.sh [model]
MODEL="${1:-github-copilot/gpt-5-mini}"
# ---------------------

# 1) Check prerequisites
if ! command -v opencode >/dev/null 2>&1; then
  echo "Error: 'opencode' CLI is not installed or not in PATH."
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: This is not a git repository."
  exit 1
fi

# 2) Check for unstaged changes (files with unstaged modifications)
UNSTAGED="$(git status --porcelain | grep -E '^ [^ ]|^\?')" || true
if [[ -n "$UNSTAGED" ]]; then
  echo -e "\033[38;5;208mError: You have unstaged changes or untracked files. Please stage your changes with 'git add' before running this script.\033[0m"
  exit 1
fi

# 3) Prepare prompt with staged diff and call Opencode
echo "Generating commit message using ${MODEL:-default model}..."

# Show a quick summary of staged files
echo "Staged files:"
git --no-pager diff --cached --name-only || true

# Capture staged diff (may be empty if only metadata changed)
STAGED_DIFF="$(git --no-pager diff --cached || true)"
if [[ -z "${STAGED_DIFF//[[:space:]]/}" ]]; then
  echo "Error: no staged changes found. Nothing to do."
  exit 1
fi

# If the diff is very large, fall back to a compact summary to avoid overwhelming the LLM
MAX_PROMPT_SIZE=${OPENCODE_MAX_PROMPT_SIZE:-12000}
if [ "${#STAGED_DIFF}" -gt "$MAX_PROMPT_SIZE" ]; then
  echo "Staged diff is large (${#STAGED_DIFF} bytes). Showing stats and asking to continue."
  git --no-pager diff --cached --stat || true
  read -r -p "Staged diff is large. Continue using a summary instead of full diff? [y/N]: " cont
  if [[ ! "$cont" =~ ^[Yy] ]]; then
    echo "Aborting."
    exit 1
  fi
  DIFF_FOR_PROMPT="$(git --no-pager diff --cached --name-only || true)"
else
  DIFF_FOR_PROMPT="$STAGED_DIFF"
fi

# Build prompt with Conventional Commits specification
PROMPT="Generate a concise git commit subject and a multi-line body describing the following staged changes. 
Follow Conventional Commits specification (https://www.conventionalcommits.org):
- Subject must be in format: <type>: <description>
- Type must be one of: feat, fix, docs, style, refactor, perf, test, chore, etc.
- Subject must be 50 characters max, imperative mood, no trailing period
- Body should explain what and why, not how
- Output ONLY the commit message (subject and body), no code fences or commentary

Staged files:
$(git --no-pager diff --cached --name-only)

Diff:
$DIFF_FOR_PROMPT"

# Build opencode arguments array to avoid word-splitting issues
OPENCODE_ARGS=(run)
if [[ -n "${MODEL:-}" ]]; then
  OPENCODE_ARGS+=(--model "$MODEL")
fi

# Call opencode with a timeout if available
if command -v timeout >/dev/null 2>&1; then
  if ! COMMIT_RAW="$(timeout 60s opencode "${OPENCODE_ARGS[@]}" "$PROMPT" 2>/dev/null)"; then
    echo "Error: Opencode CLI failed or timed out."
    exit 1
  fi
else
  if ! COMMIT_RAW="$(opencode "${OPENCODE_ARGS[@]}" "$PROMPT" 2>/dev/null)"; then
    echo "Error: Opencode CLI failed."
    exit 1
  fi
fi

# Sanitize Opencode output: remove fenced blocks and trim leading/trailing blank lines
COMMIT_MSG="$(printf "%s\n" "$COMMIT_RAW" | sed '/^```/,/^```/d')"
# Trim leading/trailing empty lines
COMMIT_MSG="$(printf "%s\n" "$COMMIT_MSG" | awk 'BEGIN{n=0} {lines[++n]=$0} END{start=1; while(start<=n && lines[start] ~ /^[[:space:]]*$/) start++; end=n; while(end>=start && lines[end] ~ /^[[:space:]]*$/) end--; for(i=start;i<=end;i++) print lines[i]}')"
# Remove common leading labels like "Commit message:"
COMMIT_MSG="$(printf "%s\n" "$COMMIT_MSG" | sed '1s/^[[:space:]]*[Cc]ommit[[:space:]]*[Mm]essage[: -]*[[:space:]]*//')"

# Reject empty or whitespace-only output
if [[ -z "${COMMIT_MSG//[[:space:]]/}" ]]; then
  echo "Error: Opencode failed to generate a message."
  exit 1
fi

# Extract subject (first non-empty line) and body (rest)
SUBJECT="$(printf "%s\n" "$COMMIT_MSG" | sed -n '1p')"
BODY="$(printf "%s\n" "$COMMIT_MSG" | sed -n '2,$p')"

# Enforce subject length limit and clean trailing period
if [ "${#SUBJECT}" -gt 50 ]; then
  TRUNC="${SUBJECT:0:50}"
  if [[ "$TRUNC" == *" "* ]]; then
    SUBJECT="${TRUNC% *}"
  else
    SUBJECT="$TRUNC"
  fi
fi
SUBJECT="${SUBJECT%.}"

# Reconstruct final message (use real newlines, not literal "\n")
FINAL_MSG="$SUBJECT"
if [[ -n "${BODY//[[:space:]]/}" ]]; then
  # Convert body lines to bullet points
  BODY_WITH_BULLETS="$(printf "%s\n" "$BODY" | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*/• /')"
  FINAL_MSG="$FINAL_MSG"$'\n\n'"$BODY_WITH_BULLETS"
fi

# Append Co-authored-by trailer if missing and OPENCODE_COAUTHOR is set
if [[ -n "${OPENCODE_COAUTHOR:-}" ]]; then
  if ! printf "%s\n" "$FINAL_MSG" | grep -qF "$OPENCODE_COAUTHOR"; then
    FINAL_MSG="$FINAL_MSG"$'\n\n'"$OPENCODE_COAUTHOR"
  fi
fi

# Prepare tempfile for commit message and set cleanup trap
TEMPFILE="$(mktemp)"
trap 'rm -f "$TEMPFILE"' EXIT
printf "%s\n" "$FINAL_MSG" > "$TEMPFILE"

# 5) Display and confirm
echo
echo "--- PROPOSED COMMIT MESSAGE ---"
cat "$TEMPFILE"
echo "-------------------------------"
echo

read -r -p "Do you want to (c)ommit, (e)dit, or (a)bort? [c/e/a]: " choice

case "$choice" in
  [cC]* )
    git commit -F "$TEMPFILE"
    ;;
  [eE]* )
    "${EDITOR:-${VISUAL:-nano}}" "$TEMPFILE"
    if [[ -s "$TEMPFILE" ]]; then
      git commit -F "$TEMPFILE"
    else
      echo "Commit message empty. Aborting."
      exit 1
    fi
    ;;
  * )
    echo "Commit aborted."
    exit 0
    ;;
esac
