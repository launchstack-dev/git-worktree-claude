#!/usr/bin/env bash
# wt.sh — Git Worktree Management for Claude Code
# Source from ~/.zshrc. Provides: wt, wt-list, wt-merge, wt-cleanup, wtc
#
# Requires: jq, git

# ─── Dependency Check ────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "wt.sh: Warning — jq is required but not installed. Install with: brew install jq" >&2
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

_wt_ensure_git_root() {
  # Resolves to the main repo root, even when called from inside a worktree
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: Not inside a git repository." >&2
    return 1
  fi
  local toplevel common_dir main_toplevel
  toplevel="$(git rev-parse --show-toplevel)"
  common_dir="$(git rev-parse --git-common-dir)"
  common_dir="$(cd "$toplevel" && cd "$(dirname "$common_dir")" && pwd)"
  main_toplevel="$(git -C "$common_dir" rev-parse --show-toplevel 2>/dev/null || echo "$common_dir")"
  echo "$main_toplevel"
}

_wt_check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with: brew install jq" >&2
    return 1
  fi
}

_wt_ensure_gitignore() {
  local repo_root="$1"
  if ! git -C "$repo_root" check-ignore -q .worktrees 2>/dev/null; then
    if [ -f "$repo_root/.gitignore" ]; then
      echo "" >> "$repo_root/.gitignore"
      echo "# Git worktrees managed by wt.sh" >> "$repo_root/.gitignore"
      echo ".worktrees/" >> "$repo_root/.gitignore"
    else
      echo "# Git worktrees managed by wt.sh" > "$repo_root/.gitignore"
      echo ".worktrees/" >> "$repo_root/.gitignore"
    fi
    echo "Added .worktrees/ to .gitignore"
  fi
}

_wt_prompt() {
  local prompt_text="$1"
  printf "%s " "$prompt_text"
  read -r REPLY
}

# ─── Worktree Context Injection ──────────────────────────────────────────────

_wt_inject_worktree_context() {
  local claude_md="$1" project="$2" branch="$3" base="$4" worktree_path="$5" repo_root="$6"

  # Prevent double-injection
  if [ -f "$claude_md" ] && grep -q "<!-- WORKTREE-CONTEXT-INJECTED -->" "$claude_md"; then
    return 0
  fi

  # Append context (cat >> creates file if it doesn't exist)
  cat >> "$claude_md" <<WTCONTEXT

<!-- WORKTREE-CONTEXT-INJECTED -->
## Worktree Context -- READ THIS FIRST

**You are in a worktree.** This is an isolated workspace.

| Field | Value |
|-------|-------|
| Project | \`${project}\` |
| Branch | \`${branch}\` |
| Base branch | \`${base}\` |
| Worktree path | \`${worktree_path}\` |
| Main repo | \`${repo_root}\` |

### Hard Rules
1. **Stay in this directory.** Do not \`cd\` to the main repo or other worktrees.
2. **Do not switch branches.** Never \`git checkout\` or \`git switch\`.
3. **Do not read/modify files in other worktrees.** Those are other Claude instances' workspaces.
4. **PRs target \`${base}\`.**
5. **Do not create new branches** without explicit user instruction.
6. **Verify at session start:** \`pwd && git branch --show-current\`
7. **Do not modify this section.** It is auto-generated.
WTCONTEXT
}

# ─── Main CLAUDE.md Map Update ───────────────────────────────────────────────

_wt_update_main_claude_md() {
  local repo_root="$1"
  local claude_md="$repo_root/CLAUDE.md"

  # Silently skip if no CLAUDE.md or no markers
  [ ! -f "$claude_md" ] && return 0
  grep -q "<!-- WORKTREE-MAP-START -->" "$claude_md" || return 0

  # Build worktree table to a temp file (avoids awk -v escaping issues)
  local table_file
  table_file="$(mktemp)"

  echo "| Branch | Base | Path | Status |" > "$table_file"
  echo "|--------|------|------|--------|" >> "$table_file"

  local worktrees_dir="$repo_root/.worktrees"
  local has_worktrees=false

  if [ -d "$worktrees_dir" ]; then
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      [ ! -d "$entry" ] && continue
      local meta="$entry/.worktree.json"
      [ ! -f "$meta" ] && continue
      has_worktrees=true

      local wt_branch wt_base wt_name wt_status
      wt_branch="$(jq -r '.branch // "-"' "$meta")"
      wt_base="$(jq -r '.base_branch // "-"' "$meta")"
      wt_name="$(basename "$entry")"
      wt_status="$(jq -r '.status // "active"' "$meta")"

      echo "| \`${wt_branch}\` | \`${wt_base}\` | \`.worktrees/${wt_name}\` | ${wt_status} |" >> "$table_file"
    done < <(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  fi

  if [ "$has_worktrees" = false ]; then
    echo "| _(none)_ | | | |" >> "$table_file"
  fi

  # Replace content between markers using awk (reads table from file, atomic via temp+mv)
  local tmp
  tmp="$(mktemp)"
  awk -v tablefile="$table_file" '
    /<!-- WORKTREE-MAP-START -->/ {
      print
      while ((getline line < tablefile) > 0) print line
      close(tablefile)
      skip=1
      next
    }
    /<!-- WORKTREE-MAP-END -->/ {
      skip=0
      print
      next
    }
    !skip { print }
  ' "$claude_md" > "$tmp"
  mv "$tmp" "$claude_md"
  rm -f "$table_file"
}

# ─── Hookify Rule Generation ────────────────────────────────────────────────

_wt_generate_hookify_rule() {
  local worktree_path="$1"
  local rule_file="$worktree_path/.claude/hookify.worktree-boundary.local.md"

  mkdir -p "$worktree_path/.claude"

  cat > "$rule_file" <<HOOKIFY
---
name: worktree-boundary-guard
enabled: true
event: file
conditions:
  - field: file_path
    operator: not_contains
    pattern: ${worktree_path}
action: warn
---
You are editing a file outside your worktree boundary (\`${worktree_path}\`).
You should only edit files within this worktree. If you need to edit files elsewhere, ask the user first.
HOOKIFY
}

# ─── Lockfile Management ────────────────────────────────────────────────────

_wt_acquire_lock() {
  local lockfile="$1"
  local max_wait="${2:-10}"
  local waited=0

  while [ -f "$lockfile" ]; do
    local lock_pid
    lock_pid="$(cat "$lockfile" 2>/dev/null)"
    # Stale detection: check if holding PID is still alive
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      echo "Removing stale lockfile (PID $lock_pid no longer running)"
      rm -f "$lockfile"
      break
    fi
    if [ "$waited" -ge "$max_wait" ]; then
      echo "Error: Could not acquire merge lock after ${max_wait}s (held by PID $lock_pid)" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo $$ > "$lockfile"
}

_wt_release_lock() {
  local lockfile="$1"
  rm -f "$lockfile"
}

# ─── Project Setup ───────────────────────────────────────────────────────────

_wt_run_project_setup() {
  local worktree_path="$1"

  if [ -f "$worktree_path/package.json" ]; then
    if [ -f "$worktree_path/bun.lock" ] || [ -f "$worktree_path/bun.lockb" ]; then
      echo "Running bun install..."
      (cd "$worktree_path" && bun install 2>&1) || echo "Warning: bun install failed"
    elif [ -f "$worktree_path/package-lock.json" ]; then
      echo "Running npm install..."
      (cd "$worktree_path" && npm install 2>&1) || echo "Warning: npm install failed"
    elif [ -f "$worktree_path/yarn.lock" ]; then
      echo "Running yarn install..."
      (cd "$worktree_path" && yarn install 2>&1) || echo "Warning: yarn install failed"
    elif [ -f "$worktree_path/pnpm-lock.yaml" ]; then
      echo "Running pnpm install..."
      (cd "$worktree_path" && pnpm install 2>&1) || echo "Warning: pnpm install failed"
    else
      echo "Running npm install (default)..."
      (cd "$worktree_path" && npm install 2>&1) || echo "Warning: npm install failed"
    fi
  elif [ -f "$worktree_path/Cargo.toml" ]; then
    echo "Running cargo build..."
    (cd "$worktree_path" && cargo build 2>&1) || echo "Warning: cargo build failed"
  elif [ -f "$worktree_path/requirements.txt" ]; then
    echo "Running pip install..."
    (cd "$worktree_path" && pip install -r requirements.txt 2>&1) || echo "Warning: pip install failed"
  elif [ -f "$worktree_path/pyproject.toml" ]; then
    if [ -f "$worktree_path/uv.lock" ]; then
      echo "Running uv sync..."
      (cd "$worktree_path" && uv sync 2>&1) || echo "Warning: uv sync failed"
    elif [ -f "$worktree_path/poetry.lock" ]; then
      echo "Running poetry install..."
      (cd "$worktree_path" && poetry install 2>&1) || echo "Warning: poetry install failed"
    fi
  elif [ -f "$worktree_path/go.mod" ]; then
    echo "Running go mod download..."
    (cd "$worktree_path" && go mod download 2>&1) || echo "Warning: go mod download failed"
  fi
}

# ─── Main Functions ──────────────────────────────────────────────────────────

wt() {
  local name="$1"
  local base="${2:-HEAD}"

  if [ -z "$name" ]; then
    echo "Usage: wt <name> [base-branch]"
    echo "  Creates a git worktree in .worktrees/<name>"
    echo ""
    echo "Related commands:"
    echo "  wt-list              List worktrees with status"
    echo "  wt-merge [name]      Merge worktree into base branch"
    echo "  wt-cleanup <name>    Remove a worktree"
    echo "  wtc <name>           cd into an existing worktree"
    return 1
  fi

  _wt_check_jq || return 1

  # Validate branch name
  if ! git check-ref-format --branch "$name" &>/dev/null; then
    echo "Error: '$name' is not a valid branch name." >&2
    return 1
  fi

  # Get main repo root
  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  # Prevent running from inside a worktree
  local current_toplevel
  current_toplevel="$(git rev-parse --show-toplevel)"
  if [ "$current_toplevel" != "$repo_root" ]; then
    echo "Error: You are inside a worktree. Run wt from the main repo: $repo_root" >&2
    return 1
  fi

  # Ensure .worktrees is gitignored
  _wt_ensure_gitignore "$repo_root"

  local worktree_path="$repo_root/.worktrees/$name"

  if [ -d "$worktree_path" ]; then
    echo "Error: Worktree '$name' already exists at $worktree_path" >&2
    return 1
  fi

  # Resolve base to a branch name for metadata
  local base_branch
  if [ "$base" = "HEAD" ]; then
    base_branch="$(git -C "$repo_root" branch --show-current)"
    [ -z "$base_branch" ] && base_branch="$(git -C "$repo_root" rev-parse --short HEAD)"
  else
    base_branch="$base"
  fi

  local project
  project="$(basename "$repo_root")"

  # Create parent directory (handles nested branch names like feature/auth)
  mkdir -p "$(dirname "$worktree_path")"

  # Create the worktree
  echo "Creating worktree '$name' from '$base_branch'..."
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
    git -C "$repo_root" worktree add "$worktree_path" "$name" || return 1
  else
    git -C "$repo_root" worktree add -b "$name" "$worktree_path" "$base" || return 1
  fi

  # Write metadata (atomic via temp+mv)
  local now tmp_meta
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  tmp_meta="$(mktemp)"
  jq -n \
    --arg branch "$name" \
    --arg base_branch "$base_branch" \
    --arg created "$now" \
    --arg main_repo "$repo_root" \
    --arg status "active" \
    '{branch: $branch, base_branch: $base_branch, created: $created, main_repo: $main_repo, status: $status}' \
    > "$tmp_meta"
  mv "$tmp_meta" "$worktree_path/.worktree.json"
  echo "  Created .worktree.json"

  # Propagate .claude config
  if [ -d "$repo_root/.claude" ]; then
    mkdir -p "$worktree_path/.claude"

    # Symlink shared directories (absolute targets)
    for dir in hooks commands templates skills agents; do
      if [ -d "$repo_root/.claude/$dir" ]; then
        ln -sfn "$repo_root/.claude/$dir" "$worktree_path/.claude/$dir"
        echo "  Symlinked .claude/$dir"
      fi
    done

    # Copy config files (may diverge per worktree)
    for file in settings.json settings.local.json; do
      if [ -f "$repo_root/.claude/$file" ]; then
        cp "$repo_root/.claude/$file" "$worktree_path/.claude/$file"
        echo "  Copied .claude/$file"
      fi
    done
  fi

  # Inject worktree context into CLAUDE.md (git already provides tracked version)
  _wt_inject_worktree_context "$worktree_path/CLAUDE.md" "$project" "$name" "$base_branch" "$worktree_path" "$repo_root"
  echo "  Injected worktree context into CLAUDE.md"

  # Generate hookify boundary guard
  _wt_generate_hookify_rule "$worktree_path"
  echo "  Generated hookify boundary guard"

  # Update main repo CLAUDE.md worktree map
  _wt_update_main_claude_md "$repo_root"

  # Run project setup
  _wt_run_project_setup "$worktree_path"

  echo ""
  echo "Worktree '$name' ready at: $worktree_path"

  # cd into the new worktree so the user is immediately working there
  cd "$worktree_path" || return 1
  echo "Now in: $(pwd)"
  echo "Branch: $(git branch --show-current)"
}

wt-list() {
  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  local worktrees_dir="$repo_root/.worktrees"

  if [ ! -d "$worktrees_dir" ]; then
    echo "No .worktrees/ directory found."
    echo ""
    echo "Git worktree list:"
    git -C "$repo_root" worktree list
    return 0
  fi

  echo ""
  printf "%-25s %-20s %-15s %-20s %s\n" "NAME" "BRANCH" "BASE" "LAST COMMIT" "STATUS"
  printf "%-25s %-20s %-15s %-20s %s\n" "----" "------" "----" "-----------" "------"

  local has_entries=false

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ ! -d "$entry" ] && continue
    has_entries=true

    local name
    name="$(basename "$entry")"
    local meta="$entry/.worktree.json"

    local branch="-" base="-" wt_status="unknown"
    if [ -f "$meta" ] && command -v jq &>/dev/null; then
      branch="$(jq -r '.branch // "-"' "$meta")"
      base="$(jq -r '.base_branch // "-"' "$meta")"
      wt_status="$(jq -r '.status // "unknown"' "$meta")"
    fi

    # Get last commit age
    local last_commit="-"
    if [ -d "$entry/.git" ] || [ -f "$entry/.git" ]; then
      last_commit="$(git -C "$entry" log -1 --format='%cr' 2>/dev/null || echo "-")"

      # Staleness detection (>7 days since last commit)
      local commit_epoch now_epoch age_days
      commit_epoch="$(git -C "$entry" log -1 --format='%ct' 2>/dev/null || echo "0")"
      now_epoch="$(date +%s)"
      age_days=$(( (now_epoch - commit_epoch) / 86400 ))
      if [ "$age_days" -gt 7 ]; then
        wt_status="stale"
      fi
    fi

    printf "%-25s %-20s %-15s %-20s %s\n" "$name" "$branch" "$base" "$last_commit" "$wt_status"
  done < <(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

  if [ "$has_entries" = false ]; then
    echo "(no managed worktrees)"
  fi

  echo ""
  echo "Git worktree list:"
  git -C "$repo_root" worktree list
  echo ""
}

wt-merge() {
  _wt_check_jq || return 1

  local name="$1"
  local repo_root meta worktree_path

  repo_root="$(_wt_ensure_git_root)" || return 1

  if [ -n "$name" ]; then
    # Name provided — look up worktree by name
    worktree_path="$repo_root/.worktrees/$name"
    meta="$worktree_path/.worktree.json"
  else
    # Auto-detect from current directory
    worktree_path="$(pwd)"
    meta="$worktree_path/.worktree.json"
  fi

  if [ ! -f "$meta" ]; then
    echo "Error: Not in a managed worktree (no .worktree.json found)." >&2
    echo "Usage: wt-merge [name]  (run from worktree or pass name)" >&2
    return 1
  fi

  local branch base_branch main_repo
  branch="$(jq -r '.branch' "$meta")"
  base_branch="$(jq -r '.base_branch' "$meta")"
  main_repo="$(jq -r '.main_repo' "$meta")"
  name="${name:-$branch}"

  # Acquire merge lock (PID-based with stale detection)
  local lockfile="$main_repo/.worktrees/.merge.lock"
  _wt_acquire_lock "$lockfile" 10 || return 1

  # Ensure lock is released on function return
  trap '_wt_release_lock "'"$lockfile"'"' RETURN

  echo "Merging worktree '$name' (branch: $branch) into '$base_branch'"
  echo ""

  # Check for uncommitted changes
  if ! git -C "$worktree_path" diff --quiet 2>/dev/null || ! git -C "$worktree_path" diff --cached --quiet 2>/dev/null; then
    echo "Warning: Uncommitted changes in this worktree:"
    git -C "$worktree_path" status --short
    echo ""
    _wt_prompt "Continue? Uncommitted changes will NOT be merged. [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 1
    fi
  fi

  # Show diff summary
  echo "Changes to merge:"
  echo "---"
  local commits
  commits="$(git -C "$main_repo" log "${base_branch}..${branch}" --oneline 2>/dev/null)"
  if [ -z "$commits" ]; then
    echo "  No new commits to merge."
    _wt_prompt "Continue with cleanup anyway? [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 0
    fi
  else
    echo "$commits"
    echo ""
    git -C "$main_repo" diff --stat "${base_branch}..${branch}" 2>/dev/null
  fi
  echo ""

  _wt_prompt "Proceed with merge into '$base_branch'? [y/N]"
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi

  # If we're inside the worktree being removed, move out
  if [[ "$(pwd)" == "$worktree_path"* ]]; then
    cd "$main_repo" || return 1
  fi

  # Checkout base branch in main repo (explicit target from metadata)
  git -C "$main_repo" checkout "$base_branch" || {
    echo "Error: Could not checkout '$base_branch' in main repo." >&2
    return 1
  }

  # Merge
  if git -C "$main_repo" merge "$branch"; then
    echo ""
    echo "Merged '$branch' into '$base_branch' successfully."
  else
    echo ""
    echo "Error: Merge failed. Resolve conflicts in $main_repo, then run:" >&2
    echo "  wt-cleanup $name" >&2
    return 1
  fi

  # Prompt for cleanup
  echo ""
  _wt_prompt "Clean up worktree '$name'? [Y/n]"
  if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
    # Remove worktree using git -C (no cd)
    git -C "$main_repo" worktree remove "$worktree_path" --force 2>/dev/null || {
      rm -rf "$worktree_path"
      git -C "$main_repo" worktree prune
    }
    echo "Removed worktree directory."

    # Delete branch
    _wt_prompt "Delete branch '$branch'? [Y/n]"
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
      git -C "$main_repo" branch -d "$branch" 2>/dev/null || git -C "$main_repo" branch -D "$branch"
      echo "Deleted branch '$branch'."
    fi

    # Update main CLAUDE.md map
    _wt_update_main_claude_md "$main_repo"
  fi

  echo ""
  echo "Done. Branch '$base_branch' in $main_repo"
}

wt-cleanup() {
  local name="$1"

  if [ -z "$name" ]; then
    # Auto-detect from current directory
    if [ -f ".worktree.json" ]; then
      name="$(jq -r '.branch' .worktree.json 2>/dev/null)"
    fi
    if [ -z "$name" ]; then
      echo "Usage: wt-cleanup <name>" >&2
      return 1
    fi
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  local worktree_path="$repo_root/.worktrees/$name"

  if [ ! -d "$worktree_path" ]; then
    echo "Error: Worktree '$name' not found at $worktree_path" >&2
    return 1
  fi

  # Check for uncommitted changes (using git -C, no cd)
  local has_changes=false
  if ! git -C "$worktree_path" diff --quiet 2>/dev/null || ! git -C "$worktree_path" diff --cached --quiet 2>/dev/null; then
    has_changes=true
    echo "Warning: Worktree '$name' has uncommitted changes:"
    git -C "$worktree_path" status --short
    echo ""
  fi

  if [ "$has_changes" = true ]; then
    _wt_prompt "Remove worktree '$name' with uncommitted changes? This is irreversible. [y/N]"
  else
    _wt_prompt "Remove worktree '$name'? [y/N]"
  fi

  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi

  # Get branch name before removing
  local branch=""
  if [ -f "$worktree_path/.worktree.json" ] && command -v jq &>/dev/null; then
    branch="$(jq -r '.branch // ""' "$worktree_path/.worktree.json")"
  fi

  # If we're inside the worktree being removed, move out
  if [[ "$(pwd)" == "$worktree_path"* ]]; then
    cd "$repo_root" || true
  fi

  # Remove worktree (using git -C, no cd)
  git -C "$repo_root" worktree remove "$worktree_path" --force 2>/dev/null || {
    rm -rf "$worktree_path"
    git -C "$repo_root" worktree prune
  }
  echo "Removed worktree '$name'."

  # Optionally delete branch
  if [ -n "$branch" ]; then
    _wt_prompt "Also delete branch '$branch'? [y/N]"
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      git -C "$repo_root" branch -d "$branch" 2>/dev/null || git -C "$repo_root" branch -D "$branch"
      echo "Deleted branch '$branch'."
    fi
  fi

  # Update main CLAUDE.md map
  _wt_update_main_claude_md "$repo_root"
}

wtc() {
  local name="$1"

  if [ -z "$name" ]; then
    echo "Usage: wtc <name>" >&2
    echo "  cd into an existing worktree" >&2
    return 1
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  local worktree_path="$repo_root/.worktrees/$name"

  if [ ! -d "$worktree_path" ]; then
    echo "Error: Worktree '$name' not found at $worktree_path" >&2
    echo "Available worktrees:"
    ls -1 "$repo_root/.worktrees/" 2>/dev/null || echo "  (none)"
    return 1
  fi

  cd "$worktree_path" || return 1
  echo "Now in worktree '$name' at $worktree_path"
  echo "Branch: $(git branch --show-current)"
}

wt-help() {
  cat <<'HELP'
Git Worktree Management for Claude Code
========================================

Commands:
  wt <name> [base]       Create worktree in .worktrees/<name>, cd into it
                          base defaults to current branch (HEAD)

  wt-list                List all worktrees with status + stale detection

  wt-merge [name]        Merge worktree into its base branch
                          Auto-detects from current dir if no name given
                          Includes pre-merge diff, lockfile for parallel safety

  wt-cleanup <name>      Remove a worktree (prompts for confirmation)
                          Auto-detects from current dir if no name given

  wtc <name>             cd into an existing worktree

  wt-help                Show this help message

What wt creates:
  .worktrees/<name>/              The worktree directory
  .worktrees/<name>/.worktree.json   Metadata (branch, base, timestamps)
  .worktrees/<name>/CLAUDE.md        Appends isolation context for Claude
  .worktrees/<name>/.claude/         Symlinked hooks/skills, copied settings
  .worktrees/<name>/.claude/hookify.worktree-boundary.local.md
                                     Boundary guard (warns on cross-worktree edits)

Main repo integration:
  .gitignore             Auto-adds .worktrees/ if missing
  CLAUDE.md              Auto-updates worktree map between
                         <!-- WORKTREE-MAP-START --> and <!-- WORKTREE-MAP-END -->
                         (if markers exist, otherwise skipped)

Optional main repo guard:
  Install wt-guard.sh as a PreToolUse hook to prompt when editing
  source files in the main repo while worktrees exist.
  See: ~/.claude/scripts/wt-guard.sh for installation instructions.

Requirements: git, jq
HELP
}
