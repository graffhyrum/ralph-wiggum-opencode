#!/bin/bash
# Ralph Wiggum: Before Prompt Hook
# - Updates iteration count in state.md
# - Adds iteration marker to progress.md
# - Injects guardrails AND test requirements into agent context
#
# NOTE: This hook CANNOT block the agent (Cursor limitation).
# Blocking is done by beforeReadFile and beforeShellExecution hooks.

set -euo pipefail

# Cross-platform sed -i
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

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

# Check if Ralph is active
if [[ ! -f "$TASK_FILE" ]]; then
  echo '{}'
  exit 0
fi

# Initialize Ralph state directory if needed
if [[ ! -d "$RALPH_DIR" ]]; then
  mkdir -p "$RALPH_DIR"
  
  cat > "$RALPH_DIR/state.md" <<EOF
---
iteration: 0
status: initialized
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

# Ralph State

Iteration 0 - Initialized, waiting for first prompt.
EOF

  cat > "$RALPH_DIR/guardrails.md" <<EOF
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

  cat > "$RALPH_DIR/context-log.md" <<EOF
# Context Allocation Log (Hook-Managed)

> ⚠️ This file is managed by hooks. Do not edit manually.

## Current Session

| File | Size (est tokens) | Timestamp |
|------|-------------------|-----------|

## Estimated Context Usage

- Allocated: 0 tokens
- Threshold: 80000 tokens (warn at 80%)
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

  cat > "$RALPH_DIR/progress.md" <<EOF
# Progress Log

---

## Iteration History

EOF
fi

# Read current state
STATE_FILE="$RALPH_DIR/state.md"
PROGRESS_FILE="$RALPH_DIR/progress.md"
GUARDRAILS_FILE="$RALPH_DIR/guardrails.md"
CONTEXT_LOG="$RALPH_DIR/context-log.md"

# Extract current iteration
CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" 2>/dev/null | sed 's/iteration: *//' || echo "0")
NEXT_ITERATION=$((CURRENT_ITERATION + 1))
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# =============================================================================
# EXTRACT TEST COMMAND FROM TASK
# =============================================================================

TEST_COMMAND=""
if grep -q "^test_command:" "$TASK_FILE" 2>/dev/null; then
  TEST_COMMAND=$(grep "^test_command:" "$TASK_FILE" | sed 's/test_command: *//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | xargs)
fi

# =============================================================================
# UPDATE STATE
# =============================================================================

cat > "$STATE_FILE" <<EOF
---
iteration: $NEXT_ITERATION
status: active
started_at: $TIMESTAMP
---

# Ralph State

Iteration $NEXT_ITERATION - Active
EOF

# Add iteration marker to progress.md
cat >> "$PROGRESS_FILE" <<EOF

---

### 🔄 Iteration $NEXT_ITERATION Started
**Time:** $TIMESTAMP

EOF

# =============================================================================
# CHECK CONTEXT HEALTH (for warning only - blocking done elsewhere)
# =============================================================================

ESTIMATED_TOKENS=$(grep 'Allocated:' "$CONTEXT_LOG" 2>/dev/null | grep -o '[0-9]*' | head -1 || echo "0")
if [[ -z "$ESTIMATED_TOKENS" ]]; then
  ESTIMATED_TOKENS=0
fi
THRESHOLD=80000
WARN_THRESHOLD=$((THRESHOLD * 80 / 100))

CONTEXT_WARNING=""
if [[ "$ESTIMATED_TOKENS" -gt "$THRESHOLD" ]]; then
  CONTEXT_WARNING="🛑 **CONTEXT LIMIT EXCEEDED**: $ESTIMATED_TOKENS tokens. Operations will be blocked. Commit your work and stop."
elif [[ "$ESTIMATED_TOKENS" -gt "$WARN_THRESHOLD" ]]; then
  REMAINING=$((THRESHOLD - ESTIMATED_TOKENS))
  CONTEXT_WARNING="⚠️ **CONTEXT WARNING**: $ESTIMATED_TOKENS tokens used ($REMAINING remaining). Work efficiently."
fi

# =============================================================================
# READ GUARDRAILS
# =============================================================================

GUARDRAILS=""
if [[ -f "$GUARDRAILS_FILE" ]]; then
  GUARDRAILS=$(sed -n '/## Learned Signs/,$ p' "$GUARDRAILS_FILE" | tail -n +3)
fi

# =============================================================================
# CHECK FOR PREVIOUS TEST FAILURES
# =============================================================================

LAST_TEST_FAILURE=""
if [[ -f "$RALPH_DIR/.last_test_output" ]]; then
  LAST_TEST_FAILURE=$(cat "$RALPH_DIR/.last_test_output" | head -30)
fi

# =============================================================================
# BUILD AGENT MESSAGE
# =============================================================================

AGENT_MSG="🔄 **Ralph Iteration $NEXT_ITERATION**

$CONTEXT_WARNING

## Your Task
Read RALPH_TASK.md for the task description and completion criteria.

## Key Files
- \`.ralph/progress.md\` - What's been done
- \`.ralph/guardrails.md\` - Signs to follow
- \`.ralph/edits.log\` - Edit history"

# Add test command prominently if defined
if [[ -n "$TEST_COMMAND" ]]; then
  AGENT_MSG="$AGENT_MSG

## ⚠️ IMPORTANT: Test-Driven Completion
**Test command:** \`$TEST_COMMAND\`

- Run tests AFTER making changes
- Task is NOT complete until tests pass
- Checking boxes is not enough - tests must verify"

  if [[ -n "$LAST_TEST_FAILURE" ]]; then
    AGENT_MSG="$AGENT_MSG

### Last Test Output:
\`\`\`
$LAST_TEST_FAILURE
\`\`\`"
  fi
fi

AGENT_MSG="$AGENT_MSG

## Ralph Protocol
1. Read progress.md to see what's done
2. Work on the next unchecked criterion in RALPH_TASK.md
3. Run tests: \`$TEST_COMMAND\`
4. If tests pass, check off the criterion
5. Repeat until all criteria pass tests
6. When ALL criteria are [x] AND tests pass: \`RALPH_COMPLETE\`
7. If stuck 3+ times on same issue: \`RALPH_GUTTER\`

## Guardrails
$GUARDRAILS

**Remember: Tests determine completion, not checkboxes.**"

jq -n \
  --arg msg "$AGENT_MSG" \
  '{
    "agent_message": $msg
  }'

exit 0
