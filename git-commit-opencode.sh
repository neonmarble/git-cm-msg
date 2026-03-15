#!/usr/bin/env bash
set -euo pipefail

# Generate a Conventional Commit message with OpenCode.
# Usage: ./git-commit-opencode.sh [model]
# Env: OPENCODE_MAX_PROMPT_SIZE, OPENCODE_COAUTHOR

readonly DEFAULT_MODEL="github-copilot/gpt-5-mini"
readonly SUBJECT_MAX_LENGTH=50
readonly OPENCODE_TIMEOUT_SECONDS=60
readonly DEFAULT_MAX_PROMPT_SIZE=12000
readonly PROMPT_SUMMARY_STATEMENT="Continue using a summary instead of the full diff? [y/N]: "

MODEL="${1:-${DEFAULT_MODEL}}"
MAX_PROMPT_SIZE="${OPENCODE_MAX_PROMPT_SIZE:-${DEFAULT_MAX_PROMPT_SIZE}}"

TEMPFILE=""
STAGED_FILES=""
STAGED_DIFF=""

log() {
  printf '%s\n' "$*"
}

log_err() {
  printf '%s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMPFILE}" && -f "${TEMPFILE}" ]]; then
    rm -f "${TEMPFILE}"
  fi
}

check_prerequisites() {
  command -v opencode >/dev/null 2>&1 || die "'opencode' CLI is not installed or not in PATH."
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "This is not a git repository."
}

require_interactive_input() {
  [[ -t 0 ]] || die "This script requires an interactive terminal for prompts."
}

get_unstaged_entries() {
  git status --porcelain | grep -E '^.[^ ]|^\?\?' || true
}

collect_staged_changes() {
  STAGED_FILES="$(git --no-pager diff --cached --name-only)"
  STAGED_DIFF="$(git --no-pager diff --cached || true)"
}

validate_staged_changes() {
  local unstaged

  unstaged="$(get_unstaged_entries)"
  if [[ -n "${unstaged}" ]]; then
    die "You have unstaged changes or untracked files. Please stage everything with 'git add' before running this script."
  fi

  collect_staged_changes

  log "Staged files:"
  printf '%s\n' "${STAGED_FILES}"

  if [[ -z "${STAGED_DIFF//[[:space:]]/}" ]]; then
    die "No staged changes found. Nothing to do."
  fi
}

prepare_diff_for_prompt() {
  local staged_diff="${1}"
  local choice

  if (( ${#staged_diff} <= MAX_PROMPT_SIZE )); then
    printf '%s' "${staged_diff}"
    return 0
  fi

  log_err "Staged diff is large (${#staged_diff} bytes)."
  log_err "Showing staged diff stats before continuing."
  git --no-pager diff --cached --stat >&2 || true
  require_interactive_input
  read -r -p "${PROMPT_SUMMARY_STATEMENT}" choice

  if [[ ! "${choice}" =~ ^[Yy]$ ]]; then
    log_err "Aborting."
    return 1
  fi

  printf '%s\n' "${STAGED_FILES}"
}

build_prompt() {
  local diff_for_prompt="${1}"

  cat <<EOF
Analyze the following staged changes and generate a Git commit message strictly adhering to the Conventional Commits specification:

### CONSTRAINTS:
- Format: <type>([optional scope]): <description> followed by a blank line and a multi-line body.
- Allowed Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
- Subject: Max ${SUBJECT_MAX_LENGTH} characters, imperative mood ('add', not 'added'), no trailing period, and use lowercase after the colon.
- Body: Max 72 characters per line. Explain the why and what, not the how. Prefer 1-3 short lines.
- Output: Return only the raw commit message text. No markdown code fences, no headers, and no introductory or concluding commentary.
- Do not include bullet markers, trailers, or surrounding quotes.

Staged files:
${STAGED_FILES}

Diff:
${diff_for_prompt}
EOF
}

run_opencode() {
  local prompt="${1}"
  local -a opencode_args

  opencode_args=(run)
  if [[ -n "${MODEL}" ]]; then
    opencode_args+=(--model "${MODEL}")
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "${OPENCODE_TIMEOUT_SECONDS}s" opencode "${opencode_args[@]}" "${prompt}" 2>/dev/null || \
      die "OpenCode failed or timed out after ${OPENCODE_TIMEOUT_SECONDS} seconds."
    return 0
  fi

  opencode "${opencode_args[@]}" "${prompt}" 2>/dev/null || die "OpenCode failed."
}

sanitize_commit_message() {
  local commit_raw="${1}"
  local commit_msg

  commit_msg="$(printf '%s\n' "${commit_raw}" | sed '/^```/,/^```/d')"
  commit_msg="$(printf '%s\n' "${commit_msg}" | sed '1s/^[[:space:]]*[Cc]ommit[[:space:]]*[Mm]essage[: -]*[[:space:]]*//')"
  commit_msg="$(printf '%s\n' "${commit_msg}" | sed '/./,$!d')"
  commit_msg="$(printf '%s\n' "${commit_msg}" | awk 'NF { last = NR } { lines[NR] = $0 } END { for (i = 1; i <= last; i++) print lines[i] }')"

  if [[ -z "${commit_msg//[[:space:]]/}" ]]; then
    die "OpenCode returned an empty commit message."
  fi

  printf '%s\n' "${commit_msg}"
}

format_final_message() {
  local commit_msg="${1}"
  local subject
  local body
  local trunc_subject
  local final_msg
  local body_with_bullets

  subject="$(printf '%s\n' "${commit_msg}" | sed -n '1p')"
  body="$(printf '%s\n' "${commit_msg}" | sed -n '2,$p')"

  if (( ${#subject} > SUBJECT_MAX_LENGTH )); then
    trunc_subject="${subject:0:SUBJECT_MAX_LENGTH}"
    if [[ "${trunc_subject}" == *" "* ]]; then
      subject="${trunc_subject% *}"
    else
      subject="${trunc_subject}"
    fi
  fi
  subject="${subject%.}"

  final_msg="${subject}"
  if [[ -n "${body//[[:space:]]/}" ]]; then
    body_with_bullets="$(printf '%s\n' "${body}" | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*/- /')"
    final_msg+=$'\n\n'
    final_msg+="${body_with_bullets}"
  fi

  if [[ -n "${OPENCODE_COAUTHOR:-}" ]] && ! printf '%s\n' "${final_msg}" | grep -qF "${OPENCODE_COAUTHOR}"; then
    final_msg+=$'\n\n'
    final_msg+="${OPENCODE_COAUTHOR}"
  fi

  printf '%s\n' "${final_msg}"
}

write_tempfile() {
  local final_msg="${1}"

  TEMPFILE="$(mktemp)"
  printf '%s\n' "${final_msg}" > "${TEMPFILE}"
}

confirm_and_commit() {
  local choice

  require_interactive_input

  printf '\nProposed commit message\n'
  printf '%s\n' '-----------------------'
  cat "${TEMPFILE}"
  printf '%s\n\n' '-----------------------'

  read -r -p "Choose: [c]ommit, [e]dit, or [a]bort: " choice

  case "${choice}" in
    [cC]* )
      git commit -F "${TEMPFILE}"
      ;;
    [eE]* )
      "${EDITOR:-${VISUAL:-nano}}" "${TEMPFILE}"
      [[ -s "${TEMPFILE}" ]] || die "Commit message is empty. Aborting."
      git commit -F "${TEMPFILE}"
      ;;
    * )
      log "Commit aborted."
      ;;
  esac
}

main() {
  local diff_for_prompt
  local prompt
  local commit_raw
  local commit_msg
  local final_msg

  trap cleanup EXIT

  check_prerequisites
  validate_staged_changes

  log "Generating commit message using ${MODEL}..."

  diff_for_prompt="$(prepare_diff_for_prompt "${STAGED_DIFF}")" || exit 0
  prompt="$(build_prompt "${diff_for_prompt}")"
  commit_raw="$(run_opencode "${prompt}")"
  commit_msg="$(sanitize_commit_message "${commit_raw}")"
  final_msg="$(format_final_message "${commit_msg}")"

  write_tempfile "${final_msg}"
  confirm_and_commit
}

main "$@"
