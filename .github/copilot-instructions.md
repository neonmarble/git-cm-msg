# Copilot Instructions

## Validation commands

- There is no dedicated build, lint, or automated test suite in this repository.
- Syntax-check the scripts with:
  - `bash -n git-commit-copilot.sh`
  - `bash -n git-commit-opencode.sh`
- Manual smoke-test commands:
  - `./git-commit-copilot.sh [model]`
  - `./git-commit-opencode.sh [model]`
- There is no single-test command because no automated tests are defined.

## High-level architecture

- This repository is a small collection of Bash entry points for generating git commit messages with LLM CLIs.
- `git-commit-copilot.sh` implements the flow for the GitHub Copilot CLI.
- `git-commit-opencode.sh` implements the same overall flow for the Opencode CLI, with extra model-availability validation before execution.
- Both scripts follow the same pipeline:
  1. Verify required CLI tooling is available and that the current directory is a git worktree.
  2. Stage all current changes with `git add .`.
  3. Stop early when `git diff --cached --quiet` shows there is nothing to commit.
  4. Ask the LLM for a plain-text commit message consisting of a concise subject plus a multi-line body.
  5. Show the proposed message and prompt the user to commit, edit, or abort.
  6. Commit directly with the generated message or reopen it in a temporary file for editing.

## Key conventions

- Treat these scripts as Bash-specific, not generic POSIX shell. The Copilot variant uses Bash arrays and `[[ ... ]]`.
- The scripts intentionally stage everything with `git add .` before generating the message. Preserve that behavior unless the repository explicitly changes its workflow.
- LLM prompts are expected to return message text only. Downstream logic assumes there are no code fences, labels, or extra commentary in the response.
- The first positional argument is the model override in both scripts:
  - Copilot default: `gpt-5-mini`
  - Opencode default: `github-copilot/gpt-5-mini`
- Editing flow is standardized around a temporary file plus `${EDITOR:-nano}`, then `git commit -F <tempfile>`.
- Error handling is explicit and fail-fast. Keep prerequisite checks and user-facing error messages direct rather than silently falling back.
- The two scripts are similar on purpose. When changing one script's workflow, review the other to decide whether the behavior should stay aligned.
