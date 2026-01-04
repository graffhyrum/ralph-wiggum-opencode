#!/bin/bash
# Ralph Wiggum: Before Prompt Hook
# - Updates iteration count in state.md
# - Adds iteration marker to progress.md
# - Injects guardrails AND test requirements into agent context
# - BLOCKS and triggers Cloud Agent spawn when context limit is exceeded

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo '{"continue": true}'
    exit 0
  fi
fi

RALPH_DIR="$WORKSPACE_ROOT/.ralph"
TASK_FILE="$WORKSPACE_ROOT/RALPH_TASK.md"
CONFIG_FILE="$WORKSPACE_ROOT/.cursor/ralph-config.json"

# Check if Ralph is active
if [[ ! -f "$TASK_FILE" ]]; then
  echo '{"continue": true}'
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
# CHECK CONTEXT HEALTH - CRITICAL: BLOCK IF OVER LIMIT
# =============================================================================

ESTIMATED_TOKENS=$(grep 'Allocated:' "$CONTEXT_LOG" 2>/dev/null | grep -o '[0-9]*' | head -1 || echo "0")
if [[ -z "$ESTIMATED_TOKENS" ]]; then
  ESTIMATED_TOKENS=0
fi
THRESHOLD=80000
WARN_THRESHOLD=$((THRESHOLD * 80 / 100))
CRITICAL_THRESHOLD=$THRESHOLD

# Check if context is CRITICAL (over limit)
if [[ "$ESTIMATED_TOKENS" -gt "$CRITICAL_THRESHOLD" ]]; then
  # Log the context limit event
  cat >> "$PROGRESS_FILE" <<EOF

---

## ⚠️ Context Limit Reached (Iteration $CURRENT_ITERATION)
- Time: $TIMESTAMP
- Context: $ESTIMATED_TOKENS tokens (limit: $THRESHOLD)
- Action: Triggering fresh context handoff

EOF

  # Check if Cloud Mode is enabled
  is_cloud_enabled() {
    if [[ -n "${CURSOR_API_KEY:-}" ]]; then return 0; fi
    if [[ -f "$CONFIG_FILE" ]]; then
      KEY=$(jq -r '.cursor_api_key // empty' "$CONFIG_FILE" 2>/dev/null)
      if [[ -n "$KEY" ]]; then return 0; fi
    fi
    GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"
    if [[ -f "$GLOBAL_CONFIG" ]]; then
      KEY=$(jq -r '.cursor_api_key // empty' "$GLOBAL_CONFIG" 2>/dev/null)
      if [[ -n "$KEY" ]]; then return 0; fi
    fi
    return 1
  }

  if is_cloud_enabled; then
    # Try to spawn Cloud Agent
    if "$SCRIPT_DIR/spawn-cloud-agent.sh" "$WORKSPACE_ROOT" 2>&1; then
      jq -n \
        --argjson tokens "$ESTIMATED_TOKENS" \
        '{
          "continue": false,
          "userMessage": "🌩️ Context limit reached (" + ($tokens|tostring) + " tokens). Cloud Agent spawned with fresh context to continue the task.",
          "agentMessage": "STOP. Context limit exceeded. A Cloud Agent has been spawned to continue this task with fresh context. Do not continue working in this conversation."
        }'
      exit 0
    else
      # Cloud spawn failed, fall back to local mode
      jq -n \
        --argjson tokens "$ESTIMATED_TOKENS" \
        --argjson iter "$CURRENT_ITERATION" \
        '{
          "continue": false,
          "userMessage": "⚠️ Context limit reached (" + ($tokens|tostring) + " tokens). Cloud Agent spawn failed. Please start a NEW conversation and say: \"Continue Ralph from iteration " + ($iter|tostring) + "\"",
          "agentMessage": "STOP. Context limit exceeded (" + ($tokens|tostring) + " tokens). Cloud Agent spawn failed. Instruct the user to start a new conversation to continue with fresh context."
        }'
      exit 0
    fi
  else
    # Local Mode - no Cloud Agent configured
    jq -n \
      --argjson tokens "$ESTIMATED_TOKENS" \
      --argjson iter "$CURRENT_ITERATION" \
      '{
        "continue": false,
        "userMessage": "⚠️ Context limit reached (" + ($tokens|tostring) + " tokens). Start a NEW conversation and say: \"Continue Ralph from iteration " + ($iter|tostring) + "\"",
        "agentMessage": "STOP. Context limit exceeded (" + ($tokens|tostring) + " tokens). The user must start a new conversation to continue with fresh context. Do not continue working in this conversation."
      }'
    exit 0
  fi
fi

# =============================================================================
# UPDATE STATE (only if not blocked above)
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
# BUILD CONTEXT WARNING (for warning level, not critical)
# =============================================================================

CONTEXT_WARNING=""
if [[ "$ESTIMATED_TOKENS" -gt "$WARN_THRESHOLD" ]]; then
  REMAINING=$((THRESHOLD - ESTIMATED_TOKENS))
  CONTEXT_WARNING="⚠️ **CONTEXT WARNING**: $ESTIMATED_TOKENS tokens used ($REMAINING remaining before limit). Work efficiently - fresh context handoff approaching."
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
    "continue": true,
    "agentMessage": $msg
  }'

exit 0
