# Plan: Improve `git-commit-opencode.sh`

Goal
- Bring `git-commit-opencode.sh` to parity with the more robust `git-commit-copilot.sh`:
  include the staged diff in the prompt, guard large diffs, timeout LLM calls, sanitize output,
  enforce commit-subject rules, use a tempfile + `git commit -F`, and add configurable options.
- Ensure generated commit messages follow Conventional Commits specification (https://www.conventionalcommits.org/en/v1.0.0/#specification)

High-level changes
1. Enable strict bash failure modes (`set -euo pipefail`).
2. Use `git add -A` and show staged files.
3. Capture staged diff and abort if empty.
4. Guard against very large diffs and offer a name-only fallback.
5. Build a rich prompt (staged files + diff) with clear formatting rules for the model.
6. Call `opencode` with a timeout and robust argument handling.
7. Sanitize LLM output (remove fences, trim whitespace, strip labels).
8. Extract subject/body, enforce a 50-char subject limit and remove trailing period.
9. Write final message to a tempfile, use `git commit -F`, and trap cleanup.
10. Optionally append a configurable `Co-authored-by` trailer.
11. Improve model-check robustness and add configurable env toggles.
12. Provide manual acceptance tests and verification steps.

Detailed numbered plan (what → why → how → verify)

1) Add strict bash settings
- Why: fail-fast and predictable behavior.
- How: set `set -euo pipefail` at the top of the script.
- Verify: run script with an intentional failing command and confirm it exits immediately.

2) Stage all changes robustly and show staged files
- Why: `git add .` can miss deletions; user needs to inspect what will be committed.
- How: replace `git add .` with `git add -A` and print staged files via
  `git --no-pager diff --cached --name-only`.
- Verify: delete a file, run script, confirm deletion is staged and listed.

3) Capture staged diff and exit if empty
- Why: avoid generating a message when nothing substantive changed.
- How: capture `STAGED_DIFF="$(git --no-pager diff --cached || true)"` and exit if empty/whitespace.
- Verify: run with no staged changes → script exits early.

4) Large-diff guard and summary fallback
- Why: prevent sending huge prompts to the LLM; give user control.
- How: set `MAX_PROMPT_SIZE=${OPENCODE_MAX_PROMPT_SIZE:-12000}`. If `${#STAGED_DIFF}` > limit, show
  `git --no-pager diff --cached --stat` and prompt user to continue; if user agrees use
  `git --no-pager diff --cached --name-only` as the diff for the prompt.
- Verify: stage a large diff and confirm the script asks and can fall back or abort.

5) Build a rich prompt that includes staged files + diff
- Why: explicit context produces better commit messages and enforces format rules.
- How: construct a PROMPT that instructs the model to generate Conventional Commits formatted messages (type: description, subject 50 chars max, imperative mood) and includes both the staged file list and the DIFF_FOR_PROMPT.
- Verify: inspect `PROMPT` in a dry-run to confirm it contains file list + diff and specifies Conventional Commits format.

6) Invoke `opencode` with a timeout and robust args
- Why: LLM calls can hang; avoid word-splitting when passing flags.
- How: use `OPENCODE_TIMEOUT=${OPENCODE_TIMEOUT:-60}` and build an args array, e.g.
  ```bash
  OPENCODE_ARGS=(run)
  if [[ -n "$MODEL" ]]; then OPENCODE_ARGS+=(--model "$MODEL"); fi
  ```
  Use `timeout ${OPENCODE_TIMEOUT}s opencode "${OPENCODE_ARGS[@]}" "$PROMPT"` when `timeout` exists;
  otherwise call without `timeout`. Capture raw output to `COMMIT_RAW` and handle non-zero exit.
- Verify: set `OPENCODE_TIMEOUT=1` to force timeout and confirm script handles it.

7) Sanitize LLM output
- Why: models often include fences or commentary; keep only the message text.
- How: remove fenced blocks (`sed '/^```/,/^```/d'`), trim leading/trailing blank lines (awk snippet),
  and strip leading labels like `Commit message:` from the first line.
- Verify: test with simulated `COMMIT_RAW` that contains code fences and prefixes; confirm sanitized output.

8) Extract subject and body; enforce subject rules
- Why: ensure commit subject follows Conventional Commits format (type: description) and conventional limits.
- How: SUBJECT = first non-empty line, BODY = rest; if SUBJECT length > 50, truncate at last space within
  the first 50 chars; remove trailing period via `SUBJECT="${SUBJECT%.}"`; reconstruct `FINAL_MSG`.
- Verify: test with a very long subject returned by the model; verify subject follows type: description format.

9) Use tempfile, `trap` cleanup, and `git commit -F`
- Why: multi-line messages are safer with `git commit -F`; ensure temporary files are removed.
- How: `TEMPFILE="$(mktemp)"` and `trap 'rm -f "$TEMPFILE"' EXIT`; write the message to tempfile and
  commit with `git commit -F "$TEMPFILE"`.
- Verify: ensure tempfile is removed after script exits (including on abort).

10) Optional Co-authored-by trailer (configurable)
- Why: provide attribution parity with Copilot script, but make it opt-in.
- How: support `OPENCODE_COAUTHOR` env var (empty default); if set and not present in `FINAL_MSG`, append it.
- Verify: set `OPENCODE_COAUTHOR` and confirm trailer appended.

11) Improve model availability check and graceful fallback
- Why: `opencode models` may fail (network/permissions); avoid hard abort in some environments.
- How: attempt `AVAILABLE_MODELS=$(opencode models 2>/dev/null)` and if it fails either warn and continue
  (when `OPENCODE_STRICT_MODEL_CHECK=false`) or abort (default behavior).
- Verify: simulate `opencode models` failure and test both modes.

12) Add env toggles and documentation
- Why: let users tune behavior without editing script.
- Variables to support:
  - `OPENCODE_MAX_PROMPT_SIZE` (default 12000)
  - `OPENCODE_TIMEOUT` (default 60)
  - `OPENCODE_COAUTHOR` (default empty)
  - `OPENCODE_STRICT_MODEL_CHECK` (default true)
  - `OPENCODE_SKIP_DIFF_IN_PROMPT` (default false)
- Verify: set each var and confirm behavior changes.

13) Manual acceptance tests (verification checklist)
- No staged changes -> script exits with "No changes staged".
- Small staged change -> script suggests a subject ≤ 50 chars in Conventional Commits format (type: description) and a body; commit uses `-F`.
- Large diff (> MAX_PROMPT_SIZE) -> script shows diff stats, asks to continue, and falls back to name-only when requested.
- LLM returns fenced content or "Commit message:" prefix -> sanitized message.
- Timeout -> script prints an error and exits non-zero.
- Edit flow still works when user picks edit.

14) Implementation checklist & commit plan
- File to change: `git-commit-opencode.sh` (script edits will be performed only when you explicitly permit).
- New doc (this file): `git-commit-opencode-plan.md`.
- Suggested commit message for script changes:
  - `feat(script): implement conventional commits support and enhance opencode commit script — include diff, timeout, sanitize, commit -F`
- Execution strategy:
  1. Add strict bash settings + staging fix + diff capture.
  2. Implement prompt building + large-diff guard.
  3. Add opencode invocation with timeout and sanitization.
  4. Implement subject enforcement + tempfile commit flow.
  5. Add optional coauthor and env toggles.
  6. Run the manual acceptance tests locally.

Priority summary
- High: staging fix (`git add -A`), capture diff & empty-check, build rich prompt, timeout wrapper, sanitize output, commit via `-F`.
- Medium: large-diff guard, co-author trailer, model check resiliency.
- Low: extended docs and extra env toggles.

Next steps (you asked to not edit scripts yet)
1. Review this plan and request any edits.
2. When you approve, I will implement the script changes in `git-commit-opencode.sh` only after you explicitly permit modifications.
3. Optionally request an incremental implementation (minimal safe subset first).

---
File: `git-commit-opencode-plan.md`
