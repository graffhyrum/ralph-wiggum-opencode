#!/bin/bash
# Ralph Wiggum: Stop Hook
# - Runs when agent stops (completed, aborted, or error)
# - Forces commit of any uncommitted work
# - Spawns Cloud Agent if context limit was reached
# - Verifies completion via tests
#
# Core Ralph principle: Tests determine completion, not the agent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# CONFIGURATION
# =============================================================================

THRESHOLD=60000

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

# Extract info
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')
STOP_STATUS=$(echo "$HOOK_INPUT" | jq -r '.status // "unknown"')

RALPH_DIR="$WORKSPACE_ROOT/.ralph"
STATE_FILE="$RALPH_DIR/state.md"
TASK_FILE="$WORKSPACE_ROOT/RALPH_TASK.md"
PROGRESS_FILE="$RALPH_DIR/progress.md"
FAILURES_FILE="$RALPH_DIR/failures.md"
CONTEXT_LOG="$RALPH_DIR/context-log.md"
CONFIG_FILE="$WORKSPACE_ROOT/.cursor/ralph-config.json"

# If Ralph isn't active, allow exit
if [[ ! -f "$TASK_FILE" ]] || [[ ! -d "$RALPH_DIR" ]]; then
  echo '{}'
  exit 0
fi

# =============================================================================
# GET CURRENT STATE
# =============================================================================

CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" 2>/dev/null | sed 's/iteration: *//' || echo "0")
UNCHECKED_CRITERIA=$(grep -c '\- \[ \]' "$TASK_FILE" 2>/dev/null || echo "0")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Get context usage
ALLOCATED_TOKENS=0
if [[ -f "$CONTEXT_LOG" ]]; then
  ALLOCATED_TOKENS=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -o '[0-9]*' | head -1 || echo "0")
  if [[ -z "$ALLOCATED_TOKENS" ]]; then
    ALLOCATED_TOKENS=0
  fi
fi

# Get test command
TEST_COMMAND=""
if grep -q "^test_command:" "$TASK_FILE" 2>/dev/null; then
  TEST_COMMAND=$(grep "^test_command:" "$TASK_FILE" | sed 's/test_command: *//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | xargs)
fi

# =============================================================================
# CLOUD MODE CHECK
# =============================================================================

is_cloud_enabled() {
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    return 0
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$KEY" ]]; then
      return 0
    fi
  fi
  GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"
  if [[ -f "$GLOBAL_CONFIG" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$GLOBAL_CONFIG" 2>/dev/null)
    if [[ -n "$KEY" ]]; then
      return 0
    fi
  fi
  return 1
}

# =============================================================================
# FORCE COMMIT ANY UNCOMMITTED WORK
# =============================================================================

force_commit() {
  cd "$WORKSPACE_ROOT"
  
  # Check for uncommitted changes
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
    echo "Uncommitted changes detected, forcing commit..." >&2
    
    git add -A 2>/dev/null || true
    git commit -m "ralph: auto-checkpoint at iteration $CURRENT_ITERATION (context: $ALLOCATED_TOKENS tokens)" 2>/dev/null || true
    git push origin main 2>/dev/null || git push origin HEAD 2>/dev/null || true
    
    return 0  # Had uncommitted changes
  fi
  
  return 1  # No uncommitted changes
}

# =============================================================================
# RUN TESTS
# =============================================================================

run_tests() {
  local test_cmd="$1"
  local workspace="$2"
  
  if [[ -z "$test_cmd" ]]; then
    echo "NO_TEST_COMMAND"
    return 0
  fi
  
  cd "$workspace"
  
  set +e
  TEST_OUTPUT=$(eval "$test_cmd" 2>&1)
  TEST_EXIT_CODE=$?
  set -e
  
  echo "$TEST_OUTPUT" > "$RALPH_DIR/.last_test_output"
  
  if [[ $TEST_EXIT_CODE -eq 0 ]]; then
    echo "PASS"
  else
    echo "FAIL:$TEST_EXIT_CODE"
  fi
}

# =============================================================================
# DECISION LOGIC
# =============================================================================

# Log the stop event
cat >> "$PROGRESS_FILE" <<EOF

---

### Agent Stopped (Iteration $CURRENT_ITERATION)
- Time: $TIMESTAMP
- Status: $STOP_STATUS
- Context: $ALLOCATED_TOKENS tokens
- Criteria remaining: $UNCHECKED_CRITERIA

EOF

# =============================================================================
# CASE 1: Context limit reached - handoff to Cloud Agent
# =============================================================================

if [[ "$ALLOCATED_TOKENS" -ge "$THRESHOLD" ]]; then
  
  # Force commit any uncommitted work
  force_commit
  
  cat >> "$PROGRESS_FILE" <<EOF
**Context limit reached. Initiating handoff...**

EOF
  
  # Update state for next iteration
  NEXT_ITERATION=$((CURRENT_ITERATION + 1))
  cat > "$STATE_FILE" <<EOF
---
iteration: $NEXT_ITERATION
status: handoff_pending
started_at: $TIMESTAMP
previous_context: $ALLOCATED_TOKENS
---

# Ralph State

Iteration $NEXT_ITERATION - Awaiting fresh context (handoff from iteration $CURRENT_ITERATION)
EOF

  # Reset context log for next agent
  cat > "$CONTEXT_LOG" <<EOF
# Context Allocation Log (Hook-Managed)

> ⚠️ This file is managed by hooks. Do not edit manually.

## Current Session

| File | Size (est tokens) | Timestamp |
|------|-------------------|-----------|

## Estimated Context Usage

- Allocated: 0 tokens
- Threshold: $THRESHOLD tokens (warn at 80%)
- Status: 🟢 Fresh context (handoff from iteration $CURRENT_ITERATION)

EOF

  # Try Cloud Mode
  if is_cloud_enabled; then
    if "$SCRIPT_DIR/spawn-cloud-agent.sh" "$WORKSPACE_ROOT" 2>/dev/null; then
      jq -n \
        --argjson iter "$NEXT_ITERATION" \
        '{
          "followup_message": ("🌩️ Context limit reached. Cloud Agent spawned for iteration " + ($iter|tostring) + ". Check the Cursor dashboard for progress.")
        }'
      exit 0
    else
      # Cloud spawn failed
      jq -n \
        --argjson iter "$NEXT_ITERATION" \
        '{
          "followup_message": ("⚠️ Context limit reached but Cloud Agent spawn failed. Start a NEW conversation: \"Continue Ralph from iteration " + ($iter|tostring) + "\"")
        }'
      exit 0
    fi
  fi
  
  # Local Mode
  jq -n \
    --argjson iter "$NEXT_ITERATION" \
    '{
      "followup_message": ("⚠️ Context limit reached. Start a NEW conversation: \"Continue Ralph from iteration " + ($iter|tostring) + "\"")
    }'
  exit 0
fi

# =============================================================================
# CASE 2: All criteria checked - verify with tests
# =============================================================================

if [[ "$UNCHECKED_CRITERIA" -eq 0 ]]; then
  
  if [[ -n "$TEST_COMMAND" ]]; then
    TEST_RESULT=$(run_tests "$TEST_COMMAND" "$WORKSPACE_ROOT")
    TEST_OUTPUT=$(cat "$RALPH_DIR/.last_test_output" 2>/dev/null || echo "")
    
    if [[ "$TEST_RESULT" == "PASS" ]]; then
      # Commit final state
      force_commit
      
      cat >> "$PROGRESS_FILE" <<EOF
## 🎉 RALPH COMPLETE (Tests Verified)
- Test command: $TEST_COMMAND
- Result: ✅ PASSED

\`\`\`
$TEST_OUTPUT
\`\`\`

EOF
      
      cat > "$STATE_FILE" <<EOF
---
iteration: $CURRENT_ITERATION
status: complete
completed_at: $TIMESTAMP
---

# Ralph State

✅ Task completed - verified by tests.
EOF
      
      jq -n '{
        "followup_message": "🎉 Ralph task COMPLETE! All criteria satisfied and tests pass."
      }'
      exit 0
      
    else
      # Tests failed - not actually complete
      cat >> "$PROGRESS_FILE" <<EOF
### ❌ Tests FAILED
- Test command: $TEST_COMMAND
- Output:
\`\`\`
$TEST_OUTPUT
\`\`\`

**Task is NOT complete. Tests must pass.**

EOF
      
      jq -n \
        --arg output "$TEST_OUTPUT" \
        '{
          "followup_message": ("⚠️ Criteria are checked but tests FAIL. Task is not complete.\n\nTest output:\n" + $output)
        }'
      exit 0
    fi
    
  else
    # No test command
    force_commit
    
    cat > "$STATE_FILE" <<EOF
---
iteration: $CURRENT_ITERATION
status: complete
completed_at: $TIMESTAMP
---

# Ralph State

✅ Task completed (no test verification).
EOF
    
    jq -n '{
      "followup_message": "🎉 Ralph task complete (no test command defined for verification)."
    }'
    exit 0
  fi
fi

# =============================================================================
# CASE 3: Normal stop with work remaining
# =============================================================================

# Commit any work
force_commit

jq -n \
  --argjson remaining "$UNCHECKED_CRITERIA" \
  '{
    "followup_message": ("Agent stopped with " + ($remaining|tostring) + " criteria remaining. Continue working or start a new conversation.")
  }'

exit 0
