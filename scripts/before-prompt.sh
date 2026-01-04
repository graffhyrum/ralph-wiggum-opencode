#!/bin/bash
# Ralph Wiggum: Before Prompt Hook
# - Updates iteration count
# - Injects context into agent
# - BLOCKS next prompt if context limit reached (continue: false)

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

THRESHOLD=60000
WARN_PERCENT=80
WARN_THRESHOLD=$((THRESHOLD * WARN_PERCENT / 100))

# =============================================================================
# HELPERS
# =============================================================================

sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# =============================================================================
# MAIN
# =============================================================================

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract workspace root
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // .cwd // "."')

if [[ "$WORKSPACE_ROOT" == "." ]] || [[ -z "$WORKSPACE_ROOT" ]]; then
  if [[ -f "./RALPH_TASK.md" ]]; then
    WORKSPACE_ROOT="."
  else
    echo '{}'
    exit 0
  fi
fi

RALPH_DIR="$WORKSPACE_ROOT/.ralph"
TASK_FILE="$WORKSPACE_ROOT/RALPH_TASK.md"
STATE_FILE="$RALPH_DIR/state.md"
PROGRESS_FILE="$RALPH_DIR/progress.md"
GUARDRAILS_FILE="$RALPH_DIR/guardrails.md"
CONTEXT_LOG="$RALPH_DIR/context-log.md"

# Check if Ralph is active
if [[ ! -f "$TASK_FILE" ]]; then
  echo '{}'
  exit 0
fi

# Initialize Ralph state directory if needed
if [[ ! -d "$RALPH_DIR" ]]; then
  mkdir -p "$RALPH_DIR"
  
  cat > "$STATE_FILE" <<EOF
---
iteration: 0
status: initialized
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

# Ralph State

Iteration 0 - Initialized, waiting for first prompt.
EOF

  cat > "$GUARDRAILS_FILE" <<EOF
# Ralph Guardrails (Signs)

## Core Signs

### Sign: Read Before Writing
- **Always** read existing files before modifying them

### Sign: Test After Changes
- Run tests after every significant change
- Task is NOT complete until tests pass

### Sign: Commit Checkpoints
- Commit working states before risky changes

### Sign: One Thing at a Time
- Focus on one criterion at a time

---

## Learned Signs

EOF

  cat > "$CONTEXT_LOG" <<EOF
# Context Allocation Log (Hook-Managed)

> ⚠️ This file is managed by hooks. Do not edit manually.

## Current Session

| File | Size (est tokens) | Timestamp |
|------|-------------------|-----------|

## Estimated Context Usage

- Allocated: 0 tokens
- Threshold: $THRESHOLD tokens (warn at 80%)
- Status: 🟢 Healthy

EOF

  cat > "$RALPH_DIR/edits.log" <<EOF
# Edit Log (Hook-Managed)
# Format: TIMESTAMP | FILE | CHANGE_TYPE | CHARS | ITERATION

EOF

  cat > "$RALPH_DIR/failures.md" <<EOF
# Failure Log (Hook-Managed)

## Pattern Detection

- Repeated failures: 0
- Gutter risk: Low

## Recent Failures

EOF

  cat > "$PROGRESS_FILE" <<EOF
# Progress Log

---

## Iteration History

EOF
fi

# =============================================================================
# GET CURRENT STATE
# =============================================================================

CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" 2>/dev/null | sed 's/iteration: *//' || echo "0")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Get context usage
ALLOCATED_TOKENS=0
if [[ -f "$CONTEXT_LOG" ]]; then
  ALLOCATED_TOKENS=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -o '[0-9]*' | head -1 || echo "0")
  if [[ -z "$ALLOCATED_TOKENS" ]]; then
    ALLOCATED_TOKENS=0
  fi
fi

# =============================================================================
# BLOCK IF CONTEXT LIMIT REACHED
# =============================================================================

if [[ "$ALLOCATED_TOKENS" -ge "$THRESHOLD" ]]; then
  jq -n \
    --argjson tokens "$ALLOCATED_TOKENS" \
    --argjson threshold "$THRESHOLD" \
    --argjson iter "$CURRENT_ITERATION" \
    '{
      "continue": false,
      "user_message": ("🛑 Ralph: Context limit reached (" + ($tokens|tostring) + "/" + ($threshold|tostring) + " tokens). This conversation cannot continue. A Cloud Agent will be spawned or start a new conversation: \"Continue Ralph from iteration " + ($iter|tostring) + "\"")
    }'
  exit 0
fi

# =============================================================================
# UPDATE ITERATION
# =============================================================================

NEXT_ITERATION=$((CURRENT_ITERATION + 1))

cat > "$STATE_FILE" <<EOF
---
iteration: $NEXT_ITERATION
status: active
started_at: $TIMESTAMP
---

# Ralph State

Iteration $NEXT_ITERATION - Active
EOF

# Add iteration marker to progress
cat >> "$PROGRESS_FILE" <<EOF

---

### 🔄 Iteration $NEXT_ITERATION Started
**Time:** $TIMESTAMP

EOF

# =============================================================================
# BUILD AGENT MESSAGE
# =============================================================================

# Get test command
TEST_COMMAND=""
if grep -q "^test_command:" "$TASK_FILE" 2>/dev/null; then
  TEST_COMMAND=$(grep "^test_command:" "$TASK_FILE" | sed 's/test_command: *//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | xargs)
fi

# Get guardrails
GUARDRAILS=""
if [[ -f "$GUARDRAILS_FILE" ]]; then
  GUARDRAILS=$(sed -n '/## Learned Signs/,$ p' "$GUARDRAILS_FILE" | tail -n +3)
fi

# Get last test output if exists
LAST_TEST_OUTPUT=""
if [[ -f "$RALPH_DIR/.last_test_output" ]]; then
  LAST_TEST_OUTPUT=$(head -30 "$RALPH_DIR/.last_test_output")
fi

# Build context warning if needed
CONTEXT_WARNING=""
if [[ "$ALLOCATED_TOKENS" -ge "$WARN_THRESHOLD" ]]; then
  REMAINING=$((THRESHOLD - ALLOCATED_TOKENS))
  PERCENT=$((ALLOCATED_TOKENS * 100 / THRESHOLD))
  CONTEXT_WARNING="⚠️ **CONTEXT WARNING**: ${PERCENT}% used (${ALLOCATED_TOKENS}/${THRESHOLD} tokens). ${REMAINING} remaining. Work efficiently!"
fi

# Build the message
AGENT_MSG="🔄 **Ralph Iteration $NEXT_ITERATION**

$CONTEXT_WARNING

## Your Task
Read RALPH_TASK.md for the task description and completion criteria.

## Key Files
- \`.ralph/progress.md\` - What's been done
- \`.ralph/guardrails.md\` - Signs to follow"

if [[ -n "$TEST_COMMAND" ]]; then
  AGENT_MSG="$AGENT_MSG

## ⚠️ Test-Driven Completion
**Test command:** \`$TEST_COMMAND\`

Run tests after making changes. Task is NOT complete until tests pass."

  if [[ -n "$LAST_TEST_OUTPUT" ]]; then
    AGENT_MSG="$AGENT_MSG

### Last Test Output:
\`\`\`
$LAST_TEST_OUTPUT
\`\`\`"
  fi
fi

AGENT_MSG="$AGENT_MSG

## Ralph Protocol
1. Read progress.md to see what's done
2. Work on the next unchecked criterion
3. Run tests after changes
4. Check off completed criteria
5. Commit frequently
6. When ALL criteria pass tests: \`RALPH_COMPLETE\`

$GUARDRAILS"

jq -n \
  --arg msg "$AGENT_MSG" \
  '{
    "agent_message": $msg
  }'

exit 0
