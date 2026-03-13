#!/bin/bash
# Automated git commit message generator using Opencode LLM
# Generates commit messages from staged changes and prompts user for approval

set -o pipefail  # Exit on pipe failures
set -u           # Exit on undefined variable usage

# --- CONFIGURATION ---
MODEL=${1:-"github-copilot/gpt-5-mini"}  # LLM model to use (default: github-copilot/gpt-5-mini)
# ---------------------

# Verify that opencode CLI is available
if ! command -v opencode &> /dev/null; then
    echo "Error: 'opencode' CLI is not installed or not in PATH." >&2
    exit 1
fi

# Verify that the specified model is available in Opencode
echo "Verifying model availability..."
AVAILABLE_MODELS=$(opencode models)

if [[ -n "$MODEL" ]]; then
    if ! echo "$AVAILABLE_MODELS" | grep -q "$MODEL"; then
        echo "Error: Model '$MODEL' is not available in Opencode." >&2
        echo "Available models are:" >&2
        echo "$AVAILABLE_MODELS" >&2
        exit 1
    fi
    MODEL_FLAG="--model $MODEL"
else
    MODEL_FLAG=""  # Use default model if none specified
fi

# Stage all changes for commit
echo "Staging changes..."
git add .

# Exit early if there are no changes to commit
if git diff --cached --quiet; then
    echo "No changes staged. Nothing to do."
    exit 0
fi

# Generate commit message using the LLM
echo "Generating commit message using ${MODEL:-default model}..."
PROMPT="Generate a concise git commit subject and a multi-line description from the current diff. Output ONLY the message."
COMMIT_MSG=$(opencode run $MODEL_FLAG "$PROMPT") || exit 1

# Verify that a message was successfully generated
if [ -z "$COMMIT_MSG" ]; then
    echo "Error: Opencode failed to generate a message." >&2
    exit 1
fi

# Display the proposed commit message and prompt user for action
echo -e "\n--- PROPOSED COMMIT MESSAGE ---"
echo "$COMMIT_MSG"
echo -e "-------------------------------\n"

read -p "Do you want to (c)ommit, (e)dit, or (a)bort? [c/e/a]: " choice

# Process user's choice
case "$choice" in
  [cC]* )
    # Commit with the generated message
    git commit -m "$COMMIT_MSG" || exit 1
    ;;
  [eE]* )
    # Allow user to edit the message in their preferred editor
    TEMPFILE=$(mktemp /tmp/git-commit-msg.XXXXXX) || exit 1
    echo "$COMMIT_MSG" > "$TEMPFILE"
    "${EDITOR:-nano}" "$TEMPFILE"

    # Commit with edited message if file is not empty
    if [ -s "$TEMPFILE" ]; then
        git commit -F "$TEMPFILE" || exit 1
    else
        echo "Commit message empty. Aborting."
    fi
    rm -f "$TEMPFILE"  # Clean up temporary file
    ;;
  * )
    # User chose to abort
    echo "Commit aborted."
    exit 0
    ;;
esac
