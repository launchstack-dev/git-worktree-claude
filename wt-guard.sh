#!/usr/bin/env bash
# wt-guard.sh — PreToolUse hook for main repo protection when worktrees exist
#
# Prompts (not blocks) when editing source files in the main repo while
# worktrees exist, since changes likely belong in a worktree instead.
#
# Install per-project in .claude/settings.json:
#   {
#     "hooks": {
#       "PreToolUse": [{
#         "matcher": "Write|Edit",
#         "hooks": [{
#           "type": "command",
#           "command": "bash ~/.claude/scripts/wt-guard.sh",
#           "timeout": 5000
#         }]
#       }]
#     }
#   }

# Fast exit: no worktrees directory means no guard needed
[ ! -d ".worktrees" ] && exit 0

# Read tool input from stdin
input="$(cat)"

file_path="$(echo "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"

# No file path — can't guard, allow
[ -z "$file_path" ] && exit 0

# Get repo root
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$repo_root" ] && exit 0

# If editing inside a worktree, allow (Claude is working correctly)
if [[ "$file_path" == "$repo_root/.worktrees/"* ]]; then
  exit 0
fi

# If file is outside the repo entirely, don't guard
if [[ "$file_path" != "$repo_root/"* && "$file_path" != "$repo_root" ]]; then
  exit 0
fi

# Check if we're already running inside a worktree (git-dir points to main .git/worktrees/<name>)
git_dir="$(git rev-parse --git-dir 2>/dev/null)"
if [[ "$git_dir" == *"/worktrees/"* ]]; then
  exit 0
fi

# Exempt config files that are legitimately edited in the main repo
case "$(basename "$file_path")" in
  .gitignore|CLAUDE.md|*.json|*.lock|*.toml|*.yaml|*.yml)
    exit 0
    ;;
esac

# Source files in main repo while worktrees exist — ask user
echo '{"decision":"ask","reason":"Worktrees exist for this project. You are editing a file in the main repo — are you sure this change does not belong in a worktree?"}'
