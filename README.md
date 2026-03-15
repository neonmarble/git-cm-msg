# git-cm-msg

Generate Conventional Commit messages for staged changes with OpenCode.

## Usage

```bash
./git-commit-opencode.sh [model]
```

- Default model: `github-copilot/gpt-5-mini`
- Example: `./git-commit-opencode.sh github-copilot/gpt-5.4`

## How it works

- Requires a git repository and the `opencode` CLI in `PATH`
- Uses only the staged snapshot when generating the commit message
- Ignores unstaged and untracked files outside the index
- Builds a prompt from the staged file list and staged diff
- Falls back to a staged-file summary when the diff is too large
- Shows the proposed commit message and lets you `commit`, `edit`, or `abort`

## Environment variables

- `OPENCODE_MAX_PROMPT_SIZE`: max staged diff size before summary fallback; default `12000`
- `OPENCODE_COAUTHOR`: optional trailer appended if missing, for example `Co-authored-by: Name <email@example.com>`

## Notes

- The script is interactive and requires a terminal for prompts
- Generated commit bodies are normalized into `- ` bullet lines before commit
- The subject line is trimmed to 50 characters if needed
