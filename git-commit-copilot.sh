#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
# Usage:
#   ./git-commit-copilot.sh [model]
MODEL="${1:-gpt-5-mini}"
# ---------------------

# 1) Check prerequisites
if ! command -v copilot >/dev/null 2>&1; then
  echo "Error: 'copilot' CLI is not installed or not in PATH."
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: This is not a git repository."
  exit 1
fi

# 2) Stage changes
echo "Staging changes..."
git add .

# 3) Check if there are actually changes to commit
if git diff --cached --quiet; then
  echo "No changes staged. Nothing to do."
  exit 0
fi

# 4) Call Copilot CLI to generate the message
echo "Generating commit message using ${MODEL:-default model}..."
PROMPT="Generate a concise git commit subject and a multi-line description from the currently staged git diff. Output ONLY the message, no code fences."

COPILOT_ARGS=(-p "$PROMPT" --allow-all-tools -s)
if [[ -n "${MODEL:-}" ]]; then
  COPILOT_ARGS+=(--model "$MODEL")
fi

COMMIT_MSG="$(copilot "${COPILOT_ARGS[@]}")"

# Reject empty or whitespace-only output
if [[ -z "${COMMIT_MSG//[[:space:]]/}" ]]; then
  echo "Error: Copilot failed to generate a message."
  exit 1
fi

# 5) Display the message
echo
echo "--- PROPOSED COMMIT MESSAGE ---"
echo "$COMMIT_MSG"
echo "-------------------------------"
echo

# 6) Ask for confirmation
read -r -p "Do you want to (c)ommit, (e)dit, or (a)bort? [c/e/a]: " choice

case "$choice" in
  [cC]* )
    git commit -m "$COMMIT_MSG"
    ;;
  [eE]* )
    TEMPFILE="$(mktemp)"
    trap 'rm -f "$TEMPFILE"' EXIT
    printf "%s\n" "$COMMIT_MSG" > "$TEMPFILE"
    "${EDITOR:-nano}" "$TEMPFILE"

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