#!/usr/bin/env python3
"""
Generate a Conventional Commit message with OpenCode.

Usage: python git-commit-opencode.py [--model MODEL] [--dry-run] [--timeout SECONDS]

Environment variables:
  OPENCODE_MAX_PROMPT_SIZE - Maximum prompt size in bytes (default: 12000)
  OPENCODE_COAUTHOR        - Co-author trailer to add to commit message
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

# Constants
DEFAULT_MODEL = "github-copilot/gpt-5-mini"
SUBJECT_MAX_LENGTH = 50
DEFAULT_TIMEOUT_SECONDS = 60
DEFAULT_MAX_PROMPT_SIZE = 12000
PROMPT_SUMMARY_STATEMENT = "Continue using a summary instead of the full diff? [y/N]: "


class GitCommitError(RuntimeError):
    """Custom exception for git commit-related errors."""
    pass


def log(message: str) -> None:
    """Print message to stdout."""
    print(message)


def log_err(message: str) -> None:
    """Print message to stderr."""
    print(message, file=sys.stderr)


def die(message: str) -> None:
    """Print error message to stderr and exit with code 1."""
    log_err(f"Error: {message}")
    sys.exit(1)


def check_prerequisites() -> None:
    """Verify that required tools are available and we're in a git repo."""
    if not shutil.which("opencode"):
        die("'opencode' CLI is not installed or not in PATH.")
    
    result = subprocess.run(
        ["git", "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
        text=True
    )
    if result.returncode != 0:
        die("This is not a git repository.")


def require_interactive_input() -> None:
    """Verify that stdin is a TTY for interactive prompts."""
    if not sys.stdin.isatty():
        die("This script requires an interactive terminal for prompts.")


def get_staged_files() -> str:
    """Get list of staged files."""
    result = subprocess.run(
        ["git", "--no-pager", "diff", "--cached", "--name-only"],
        capture_output=True,
        text=True
    )
    if result.returncode != 0:
        die("Failed to get staged files.")
    return result.stdout.strip()


def get_staged_diff() -> str:
    """Get staged diff content."""
    result = subprocess.run(
        ["git", "--no-pager", "diff", "--cached"],
        capture_output=True,
        text=True
    )
    # Diff can be empty, don't error on that
    return result.stdout.strip()


def validate_staged_changes() -> tuple[str, str]:
    """Validate that there are staged changes to commit."""
    staged_files = get_staged_files()
    staged_diff = get_staged_diff()
    
    log("Staged files:")
    log(staged_files)
    
    if not staged_diff:
        die("No staged changes found. Nothing to do.")
    
    return staged_files, staged_diff


def prepare_diff_for_prompt(staged_diff: str, staged_files: str, max_prompt_size: int) -> Optional[str]:
    """
    Prepare diff for the prompt, prompting user if it's too large.
    
    Returns the diff to use, or None if user aborts.
    """
    if len(staged_diff) <= max_prompt_size:
        return staged_diff
    
    log_err(f"Staged diff is large ({len(staged_diff)} bytes).")
    log_err("Showing staged diff stats before continuing.")
    
    subprocess.run(
        ["git", "--no-pager", "diff", "--cached", "--stat"],
        capture_output=False
    )
    
    require_interactive_input()
    choice = input(PROMPT_SUMMARY_STATEMENT).strip()
    
    if not choice.lower().startswith('y'):
        log_err("Aborting.")
        return None
    
    return staged_files


def build_prompt(diff_for_prompt: str, staged_files: str) -> str:
    """Build the prompt for opencode."""
    return f"""Analyze the following staged changes and generate a Git commit message strictly adhering to the Conventional Commits specification:

### CONSTRAINTS:
- Format: <type>([optional scope]): <description> followed by a blank line and a multi-line body.
- Allowed Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
- Subject: Max {SUBJECT_MAX_LENGTH} characters, imperative mood ('add', not 'added'), no trailing period, and use lowercase after the colon.
- Body: Max 72 characters per line. Explain the why and what, not the how. Prefer 1-3 short lines.
- Output: Return only the raw commit message text. No markdown code fences, no headers, and no introductory or concluding commentary.
- Do not include bullet markers, trailers, or surrounding quotes.

Staged files:
{staged_files}

Diff:
{diff_for_prompt}
"""


def run_opencode(prompt: str, model: str, timeout_seconds: int) -> str:
    """
    Run opencode CLI with the given prompt and model.
    
    Raises:
        GitCommitError: If opencode fails or times out.
    """
    opencode_args = ["opencode", "run"]
    if model:
        opencode_args.extend(["--model", model])
    opencode_args.append(prompt)
    
    try:
        result = subprocess.run(
            opencode_args,
            capture_output=True,
            text=True,
            timeout=timeout_seconds
        )
        if result.returncode != 0:
            raise GitCommitError(f"OpenCode failed with return code {result.returncode}: {result.stderr}")
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        raise GitCommitError(f"OpenCode timed out after {timeout_seconds} seconds.")
    except FileNotFoundError:
        raise GitCommitError("'opencode' CLI not found.")


def sanitize_commit_message(commit_raw: str) -> str:
    """
    Sanitize the raw commit message from opencode.
    
    Uses regex instead of sed/awk to clean the message.
    
    Raises:
        GitCommitError: If the resulting message is empty.
    """
    commit_msg = commit_raw
    
    # Remove markdown code fences (```...```)
    commit_msg = re.sub(r'^```[\s\S]*?^```', '', commit_msg, flags=re.MULTILINE)
    
    # Remove "Commit Message:" or similar prefixes from first line
    commit_msg = re.sub(r'^[\s]*[Cc]ommit[\s]*[Mm]essage[:\s-]*[\s]*', '', commit_msg)
    
    # Trim leading empty lines
    commit_msg = re.sub(r'^[\s]*\n+', '', commit_msg)
    
    # Trim trailing empty lines - split into lines, find last non-empty, rebuild
    lines = commit_msg.split('\n')
    # Find last non-empty line index
    last_non_empty = -1
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip():
            last_non_empty = i
            break
    
    if last_non_empty >= 0:
        commit_msg = '\n'.join(lines[:last_non_empty + 1])
    else:
        commit_msg = ""
    
    if not commit_msg.strip():
        raise GitCommitError("OpenCode returned an empty commit message.")
    
    return commit_msg


def format_final_message(commit_msg: str, coauthor: Optional[str]) -> str:
    """
    Format the final commit message with subject truncation and body formatting.
    """
    lines = commit_msg.split('\n')
    subject = lines[0] if lines else ""
    body = '\n'.join(lines[1:]) if len(lines) > 1 else ""
    
    # Truncate subject if too long
    if len(subject) > SUBJECT_MAX_LENGTH:
        trunc_subject = subject[:SUBJECT_MAX_LENGTH]
        # Try to break at last space if possible
        last_space = trunc_subject.rfind(' ')
        if last_space > 0:
            subject = trunc_subject[:last_space]
        else:
            subject = trunc_subject
    
    # Remove trailing period from subject
    subject = subject.rstrip('.')
    
    final_msg = subject
    
    # Format body with bullet points
    if body.strip():
        body_lines = body.split('\n')
        bullet_lines = []
        for line in body_lines:
            stripped = line.strip()
            if stripped:
                bullet_lines.append(f"- {stripped}")
        
        if bullet_lines:
            final_msg += '\n\n' + '\n'.join(bullet_lines)
    
    # Add co-author if specified and not already present
    if coauthor and coauthor not in final_msg:
        final_msg += f"\n\n{coauthor}"
    
    return final_msg


def write_tempfile(final_msg: str) -> Path:
    """Write commit message to a temporary file using pathlib."""
    temp_file = Path(tempfile.mktemp())
    temp_file.write_text(final_msg + '\n')
    return temp_file


def confirm_and_commit(temp_file: Path, dry_run: bool = False) -> str:
    """
    Show the proposed commit message and prompt user for action.
    
    Returns:
        'committed' - if commit was successful
        'edited' - if user edited and committed
        'aborted' - if user aborted
        'regenerate' - if user wants to regenerate the message
    """
    require_interactive_input()
    
    print('\nProposed commit message')
    print('-----------------------')
    print(temp_file.read_text(), end='')
    print('-----------------------\n')
    
    if dry_run:
        log("Dry run mode - not committing.")
        return 'aborted'
    
    choice = input("Choose: [c]ommit, [e]dit, [r]egenerate, or [a]bort: ").strip().lower()
    
    if choice.startswith('c'):
        result = subprocess.run(["git", "commit", "-F", str(temp_file)])
        if result.returncode != 0:
            die("Git commit failed.")
        return 'committed'
    elif choice.startswith('e'):
        editor = os.environ.get('EDITOR') or os.environ.get('VISUAL') or 'nano'
        subprocess.run([editor, str(temp_file)])
        
        if not temp_file.read_text().strip():
            die("Commit message is empty. Aborting.")
        
        result = subprocess.run(["git", "commit", "-F", str(temp_file)])
        if result.returncode != 0:
            die("Git commit failed.")
        return 'edited'
    elif choice.startswith('r'):
        log("Regenerating commit message...")
        return 'regenerate'
    else:
        log("Commit aborted.")
        return 'aborted'


def generate_commit_message(
    staged_files: str,
    diff_for_prompt: str,
    model: str,
    timeout: int,
    coauthor: Optional[str]
) -> str:
    """Generate and return a formatted commit message."""
    prompt = build_prompt(diff_for_prompt, staged_files)
    
    commit_raw = ""
    try:
        commit_raw = run_opencode(prompt, model, timeout)
    except GitCommitError as e:
        die(str(e))
    
    # Sanitize and format message
    commit_msg = ""
    try:
        commit_msg = sanitize_commit_message(commit_raw)
    except GitCommitError as e:
        die(str(e))
    
    return format_final_message(commit_msg, coauthor)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a Conventional Commit message with OpenCode."
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Model to use (default: {DEFAULT_MODEL})"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Generate message without committing"
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"Timeout in seconds for opencode (default: {DEFAULT_TIMEOUT_SECONDS})"
    )
    
    args = parser.parse_args()
    
    # Read environment variables
    max_prompt_size = int(os.environ.get("OPENCODE_MAX_PROMPT_SIZE", DEFAULT_MAX_PROMPT_SIZE))
    coauthor = os.environ.get("OPENCODE_COAUTHOR")
    
    # Check prerequisites
    check_prerequisites()
    
    # Validate staged changes
    staged_files, staged_diff = validate_staged_changes()
    
    # Prepare diff for prompt
    diff_for_prompt = prepare_diff_for_prompt(staged_diff, staged_files, max_prompt_size)
    if diff_for_prompt is None:
        sys.exit(0)
    
    # Loop to handle regeneration
    while True:
        log(f"Generating commit message using {args.model}...")
        
        final_msg = generate_commit_message(
            staged_files, diff_for_prompt, args.model, args.timeout, coauthor
        )
        
        # Write to temp file and confirm
        temp_file = write_tempfile(final_msg)
        try:
            result = confirm_and_commit(temp_file, args.dry_run)
            if result == 'regenerate':
                continue
            break
        finally:
            # Cleanup temp file
            if temp_file.exists():
                temp_file.unlink()


if __name__ == "__main__":
    main()
