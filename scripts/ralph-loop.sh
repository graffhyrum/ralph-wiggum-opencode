#!/bin/bash
# Ralph Wiggum: The Loop (CLI Mode)
#
# Runs opencode locally with JSON parsing for accurate token tracking.
# Handles context rotation via --session when thresholds are hit.
#
# Usage:
#   ./ralph-loop.sh                    # Start from current directory
#   ./ralph-loop.sh /path/to/project   # Start from specific project
#
# Requirements:
#   - RALPH_TASK.md in the project root
#   - Git repository
#   - opencode CLI installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# CONFIGURATION
# =============================================================================

MAX_ITERATIONS=20       # Max rotations before giving up
WARN_THRESHOLD=70000    # Tokens: send wrapup warning
ROTATE_THRESHOLD=80000  # Tokens: force rotation

# Model selection (override with RALPH_MODEL env var)
DEFAULT_MODEL="zen"
MODEL="${RALPH_MODEL:-$DEFAULT_MODEL}"

# =============================================================================
# HELPERS
# =============================================================================

# Spinner to show the loop is alive (not frozen)
# Outputs to stderr so it's not captured by $()
spinner() {
  local workspace="$1"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while true; do
    printf "\r  🐛 Agent working... %s  (watch: tail -f %s/.ralph/activity.log)" "${spin:i++%${#spin}:1}" "$workspace" >&2
    sleep 0.1
  done
}

# Log to progress.md (called by the loop, not the agent)
log_progress() {
  local workspace="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local progress_file="$workspace/.ralph/progress.md"

  echo "" >> "$progress_file"
  echo "### $timestamp" >> "$progress_file"
  echo "$message" >> "$progress_file"
}

# Initialize .ralph directory with default files
init_ralph_dir() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"

  mkdir -p "$ralph_dir"

  # Initialize progress.md if it doesn't exist
  if [[ ! -f "$ralph_dir/progress.md" ]]; then
    cat > "$ralph_dir/progress.md" << 'EOF'
# Progress Log

> Updated by the agent after significant work.

---

## Session History

EOF
  fi

  # Initialize guardrails.md if it doesn't exist
  if [[ ! -f "$ralph_dir/guardrails.md" ]]; then
    cat > "$ralph_dir/guardrails.md" << 'EOF'
# Ralph Guardrails (Signs)

> Lessons learned from past failures. READ THESE BEFORE ACTING.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Always read the existing file first
- **Added after**: Core principle

### Sign: Test After Changes
- **Trigger**: After any code change
- **Instruction**: Run tests to verify nothing broke
- **Added after**: Core principle

### Sign: Commit Checkpoints
- **Trigger**: Before risky changes
- **Instruction**: Commit current working state first
- **Added after**: Core principle

---

## Learned Signs

EOF
  fi

  # Initialize errors.log if it doesn't exist
  if [[ ! -f "$ralph_dir/errors.log" ]]; then
    cat > "$ralph_dir/errors.log" << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi

  # Initialize activity.log if it doesn't exist
  if [[ ! -f "$ralph_dir/activity.log" ]]; then
    cat > "$ralph_dir/activity.log" << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi
}

# Build the Ralph prompt
build_prompt() {
  local workspace="$1"
  local iteration="$2"

  cat << EOF
# Ralph Iteration $iteration

You are an autonomous development agent using the Ralph methodology.

## FIRST: Read State Files

Before doing anything:
1. Read \`RALPH_TASK.md\` - your task and completion criteria
2. Read \`.ralph/guardrails.md\` - lessons from past failures (FOLLOW THESE)
3. Read \`.ralph/progress.md\` - what's been accomplished
4. Read \`.ralph/errors.log\` - recent failures to avoid

## Git Protocol (Critical)

Ralph's strength is state-in-git, not LLM memory. Commit early and often:

1. After completing each criterion, commit your changes:
   \`git add -A && git commit -m 'ralph: implement state tracker'\`
   \`git add -A && git commit -m 'ralph: fix async race condition'\`
   \`git add -A && git commit -m 'ralph: add CLI adapter with commander'\`
   Always describe what you actually did - never use placeholders like '<description>'
2. After any significant code change (even partial): commit with descriptive message
3. Before any risky refactor: commit current state as checkpoint
4. Push after every 2-3 commits: \`git push\`

If you get rotated, the next agent picks up from your last commit. Your commits ARE your memory.

## Task Execution

1. Work on the next unchecked criterion in RALPH_TASK.md (look for \`[ ]\`)
2. Run tests after changes (check RALPH_TASK.md for test_command)
3. **Mark completed criteria**: Edit RALPH_TASK.md and change \`[ ]\` to \`[x]\`
   - Example: \`- [ ] Implement parser\` becomes \`- [x] Implement parser\`
   - This is how progress is tracked - YOU MUST update the file
4. Update \`.ralph/progress.md\` with what you accomplished
5. When ALL criteria show \`[x]\`: say \`RALPH_COMPLETE\`
6. If stuck 3+ times on same issue: say \`RALPH_GUTTER\`

## Learning from Failures

When something fails:
1. Check \`.ralph/errors.log\` for failure history
2. Figure out the root cause
3. Add a Sign to \`.ralph/guardrails.md\` using this format:

\`\`\`
### Sign: [Descriptive Name]
- **Trigger**: When this situation occurs
- **Instruction**: What to do instead
- **Added after**: Iteration $iteration - what happened
\`\`\`

## Context Rotation Warning

You may receive a warning that context is running low. When you see it:
1. Finish your current file edit
2. Commit and push your changes
3. Update .ralph/progress.md with what you accomplished and what's next
4. You will be rotated to a fresh agent that continues your work

Begin by reading the state files.
EOF
}

# Check if task is complete
check_task_complete() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"

  if [[ ! -f "$task_file" ]]; then
    echo "NO_TASK_FILE"
    return
  fi

  local unchecked
  unchecked=$(grep -c '\[ \]' "$task_file" 2>/dev/null) || unchecked=0

  if [[ "$unchecked" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$unchecked"
  fi
}

# Run a single agent iteration
run_iteration() {
  local workspace="$1"
  local iteration="$2"
  local session_id="${3:-}"

  local prompt=$(build_prompt "$workspace" "$iteration")
  local parser_output
  local fifo="$workspace/.ralph/.parser_fifo"

  # Create named pipe for parser signals
  rm -f "$fifo"
  mkfifo "$fifo"

  # Use stderr for display (stdout is captured for signal)
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "🐛 Ralph Iteration $iteration" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "Monitor:   tail -f $workspace/.ralph/activity.log" >&2
  echo "" >&2

  # Log session start to progress.md
  log_progress "$workspace" "**Session $iteration started** (model: $MODEL)"

  # Build opencode command
  local cmd="opencode run --format json --model $MODEL"

  if [[ -n "$session_id" ]]; then
    echo "Resuming session: $session_id" >&2
    cmd="$cmd --session=\"$session_id\""
  fi

  # Run opencode, pipe through stream-parser
  # Parser writes signals (ROTATE, WARN, GUTTER) to fifo
  cd "$workspace"

  # Start spinner to show we're alive
  spinner "$workspace" &
  local spinner_pid=$!

  # Start parser in background, reading from opencode
  # Parser outputs to fifo, we read signals from fifo
  (
    eval "$cmd \"$prompt\"" 2>&1 | "$SCRIPT_DIR/stream-parser.sh" "$workspace" > "$fifo"
  ) &
  local agent_pid=$!

  # Read signals from parser
  local signal=""
  while IFS= read -r line < "$fifo"; do
    case "$line" in
      "ROTATE")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "🔄 Context rotation triggered - stopping agent..." >&2
        kill $agent_pid 2>/dev/null || true
        signal="ROTATE"
        break
        ;;
      "WARN")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "⚠️  Context warning - agent should wrap up soon..." >&2
        # Send interrupt to encourage wrap-up (agent continues but is notified)
        ;;
      "GUTTER")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "🚨 Gutter detected - agent may be stuck..." >&2
        signal="GUTTER"
        # Don't kill yet, let agent try to recover
        ;;
    esac
  done

  # Wait for agent to finish
  wait $agent_pid 2>/dev/null || true

  # Stop spinner and clear line
  kill $spinner_pid 2>/dev/null || true
  wait $spinner_pid 2>/dev/null || true
  printf "\r\033[K" >&2  # Clear spinner line

  # Cleanup
  rm -f "$fifo"

  echo "$signal"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  local workspace="${1:-.}"
  if [[ "$workspace" == "." ]]; then
    workspace="$(pwd)"
  fi
  workspace="$(cd "$workspace" && pwd)"

  local task_file="$workspace/RALPH_TASK.md"

  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: The Loop (CLI Mode)"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  \"That's the beauty of Ralph - the technique is deterministically"
  echo "   bad in an undeterministic world.\""
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""

  # Check prerequisites
  if [[ ! -f "$task_file" ]]; then
    echo "❌ No RALPH_TASK.md found in $workspace"
    echo ""
    echo "Create a task file first:"
    echo "  cat > RALPH_TASK.md << 'EOF'"
    echo "  ---"
    echo "  task: Your task description"
    echo "  test_command: \"npm test\""
    echo "  ---"
    echo "  # Task"
    echo "  ## Success Criteria"
    echo "  1. [ ] First thing to do"
    echo "  2. [ ] Second thing to do"
    echo "  EOF"
    exit 1
  fi

  # Check for opencode CLI
  if ! command -v opencode &> /dev/null; then
    echo "❌ opencode CLI not found"
    echo ""
    echo "Install via:"
    echo "  curl https://opencode.ai/install -fsS | bash"
    exit 1
  fi

  # Check for git repo
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not a git repository"
    echo "   Ralph requires git for state persistence."
    exit 1
  fi

  # Initialize .ralph directory
  init_ralph_dir "$workspace"

  echo "Workspace: $workspace"
  echo "Task:      $task_file"
  echo ""

  # Show task summary
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""

  # Count criteria
  local total_criteria done_criteria remaining
  total_criteria=$(grep -cE '\[ \]|\[x\]' "$task_file" 2>/dev/null) || total_criteria=0
  done_criteria=$(grep -c '\[x\]' "$task_file" 2>/dev/null) || done_criteria=0
  remaining=$((total_criteria - done_criteria))

  echo "Progress: $done_criteria / $total_criteria criteria complete ($remaining remaining)"
  echo "Model:    $MODEL"
  echo ""

  if [[ "$remaining" -eq 0 ]] && [[ "$total_criteria" -gt 0 ]]; then
    echo "🎉 Task already complete! All criteria are checked."
    exit 0
  fi

  # Confirm before starting
  echo "This will run opencode locally to work on this task."
  echo "The agent will be rotated when context fills up (~80k tokens)."
  echo ""
  echo "To use a different model, set RALPH_MODEL:"
  echo "  RALPH_MODEL=deepseek-v3 ./ralph-loop.sh"
  echo ""
  read -p "Start Ralph loop? [y/N] " -n 1 -r
  echo ""

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi

  echo ""
  echo "🚀 Starting Ralph loop..."
  echo ""

  # Commit any uncommitted work first
  cd "$workspace"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: initial commit before loop" || true
  fi

  # Main loop
  local iteration=1
  local session_id=""

  while [[ $iteration -le $MAX_ITERATIONS ]]; do
    # Run iteration
    local signal
    signal=$(run_iteration "$workspace" "$iteration" "$session_id")

    # Check task completion
    local task_status
    task_status=$(check_task_complete "$workspace")

    if [[ "$task_status" == "COMPLETE" ]]; then
      log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE"
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "🎉 RALPH COMPLETE! All criteria satisfied."
      echo "═══════════════════════════════════════════════════════════════════"
      echo ""
      echo "Completed in $iteration iteration(s)."
      echo "Check git log for detailed history."
      exit 0
    fi

    # Handle signals
    case "$signal" in
      "ROTATE")
        log_progress "$workspace" "**Session $iteration ended** - 🔄 Context rotation (token limit reached)"
        echo ""
        echo "🔄 Rotating to fresh context..."
        iteration=$((iteration + 1))
        # TODO: Extract session ID for --resume
        # For now, start fresh each iteration (state is in files/git)
        session_id=""
        ;;
      "GUTTER")
        log_progress "$workspace" "**Session $iteration ended** - 🚨 GUTTER (agent stuck)"
        echo ""
        echo "🚨 Gutter detected. Check .ralph/errors.log for details."
        echo "   The agent may be stuck. Consider:"
        echo "   1. Check .ralph/guardrails.md for lessons"
        echo "   2. Manually fix the blocking issue"
        echo "   3. Re-run the loop"
        exit 1
        ;;
      *)
        # Agent finished naturally, check if more work needed
        if [[ "$task_status" == INCOMPLETE:* ]]; then
          local remaining_count=${task_status#INCOMPLETE:}
          log_progress "$workspace" "**Session $iteration ended** - Agent finished naturally ($remaining_count criteria remaining)"
          echo ""
          echo "📋 Agent finished but $remaining_count criteria remaining."
          echo "   Starting next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
    esac

    # Brief pause between iterations
    sleep 2
  done

  log_progress "$workspace" "**Loop ended** - ⚠️ Max iterations ($MAX_ITERATIONS) reached"
  echo ""
  echo "⚠️  Max iterations ($MAX_ITERATIONS) reached."
  echo "   Task may not be complete. Check progress manually."
  exit 1
}

main "$@"
