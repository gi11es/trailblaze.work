#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook: captures Claude Code prompts and attaches them to git commits
# as git notes in the refs/notes/claude-prompts namespace.
#
# Receives PostToolUse JSON on stdin. Exits in <1ms for non-commit commands.

# Fast guard: skip if stdin doesn't mention "git commit" at all (~1ms exit)
INPUT=$(cat)
if [[ "$INPUT" != *"git commit"* ]]; then
    exit 0
fi

# Delegate all JSON parsing and note creation to Python
HOOK_INPUT="$INPUT" python3 <<'PYTHON'
import json, os, re, subprocess, sys
from datetime import datetime, timezone


def main():
    try:
        hook_data = json.loads(os.environ["HOOK_INPUT"])
    except (json.JSONDecodeError, KeyError):
        return

    # Validate this is a Bash command containing "git commit"
    tool_input = hook_data.get("tool_input", {})
    command = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
    if "git commit" not in command:
        return

    # Check tool_response for successful commit pattern: [branch hash]
    response = hook_data.get("tool_response", "")
    if isinstance(response, dict):
        response = json.dumps(response)
    match = re.search(r"\[[\w/.+-]+ ([a-f0-9]{7,})\]", str(response))
    if not match:
        return
    commit_hash = match.group(1)

    # Locate transcript
    transcript_path = hook_data.get("transcript_path", "")
    session_id = hook_data.get("session_id", "")
    if not transcript_path or not os.path.isfile(transcript_path):
        return
    if not session_id:
        return

    # Extract user prompts since the previous git commit in this session
    prompts = extract_prompts(transcript_path)
    if not prompts:
        return

    # Format note
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = [
        "## Claude Code Prompts",
        "",
        f"**Session**: {session_id}",
        f"**Captured**: {timestamp}",
        "",
        "### Prompts",
        "",
    ]
    for i, prompt in enumerate(prompts, 1):
        lines.append(f"**{i}.** {prompt}")
        lines.append("")

    note = "\n".join(lines)

    # Attach as git note (--force overwrites if amending)
    result = subprocess.run(
        ["git", "notes", "--ref=claude-prompts", "add", "-f", "-m", note, commit_hash],
        capture_output=True,
        timeout=10,
    )
    if result.returncode != 0:
        return

    # Push the note to remote (best-effort, non-blocking)
    # This avoids needing remote.origin.push which overrides default push behavior.
    subprocess.run(
        ["git", "push", "origin", "refs/notes/claude-prompts"],
        capture_output=True,
        timeout=15,
    )


def extract_prompts(transcript_path):
    """Walk backward through the transcript collecting user prompts.

    Stops at the previous git commit boundary (or session start).
    Skips the current commit's tool_use record so we capture the
    prompts that led *to* this commit, not past it.
    """
    records = []
    with open(transcript_path, "r") as f:
        for line in f:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                records.append(json.loads(stripped))
            except json.JSONDecodeError:
                continue

    prompts = []
    found_current_commit = False

    for record in reversed(records):
        rec_type = record.get("type", "")

        # Detect git-commit tool_use inside assistant messages
        if rec_type == "assistant":
            content = record.get("message", {}).get("content", [])
            if isinstance(content, list):
                for part in content:
                    if (
                        isinstance(part, dict)
                        and part.get("type") == "tool_use"
                        and part.get("name") == "Bash"
                        and "git commit" in part.get("input", {}).get("command", "")
                    ):
                        if not found_current_commit:
                            # This is the commit that just happened — skip it
                            found_current_commit = True
                            break
                        else:
                            if prompts:
                                # We have prompts, stop here
                                prompts.reverse()
                                return prompts
                            # No prompts between commits (multi-commit turn), keep looking

        # Collect user prompts (only after we've passed the current commit)
        if found_current_commit and rec_type == "user":
            text = extract_text(record)
            if text:
                if len(text) > 2000:
                    text = text[:2000] + "... [truncated]"
                mode = extract_mode(record)
                if mode:
                    text = f"[{mode}] {text}"
                prompts.append(text)

    prompts.reverse()
    return prompts


MODE_LABELS = {
    "plan": "plan",
    "dontAsk": "auto-accept",
    "bypassPermissions": "bypass",
    "acceptEdits": "accept-edits",
}


def extract_mode(record):
    """Return a readable mode label if the user record has a non-default permissionMode."""
    raw = record.get("permissionMode", "")
    return MODE_LABELS.get(raw, "")


def extract_text(record):
    """Extract plain text from a user message record."""
    msg_content = record.get("message", {}).get("content", "")
    if isinstance(msg_content, str):
        return msg_content.strip()
    if isinstance(msg_content, list):
        parts = []
        for part in msg_content:
            if isinstance(part, dict) and part.get("type") == "text":
                t = part.get("text", "").strip()
                if t:
                    parts.append(t)
        return "\n".join(parts).strip()
    return ""


if __name__ == "__main__":
    main()
PYTHON
