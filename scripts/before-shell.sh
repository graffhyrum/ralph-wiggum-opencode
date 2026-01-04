#!/bin/bash
# Ralph Wiggum: Before Shell Execution Hook
# - Warns at 80% of threshold
# - At 100%: ONLY allows git commands (add, commit, push, status)
# - Blocks everything else to force agent to stop gracefully

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

THRESHOLD=60000
WARN_PERCENT=80
WARN_THRESHOLD=$((THRESHOLD * WARN_PERCENT / 100))

# =============================================================================
# MAIN
# =============================================================================

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract command and workspace
COMMAND=$(echo "$HOOK_INPUT" | jq -r '.command // ""')
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')

RALPH_DIR="$WORKSPACE_ROOT/.ralph"
CONTEXT_LOG="$RALPH_DIR/context-log.md"

# If Ralph isn't active, pass through
if [[ ! -d "$RALPH_DIR" ]]; then
  echo '{"permission": "allow"}'
  exit 0
fi

# =============================================================================
# GET CURRENT CONTEXT USAGE
# =============================================================================

CURRENT_ALLOCATED=0
if [[ -f "$CONTEXT_LOG" ]]; then
  CURRENT_ALLOCATED=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -o '[0-9]*' | head -1 || echo "0")
  if [[ -z "$CURRENT_ALLOCATED" ]]; then
    CURRENT_ALLOCATED=0
  fi
fi

# =============================================================================
# AT OR OVER 100% - ONLY ALLOW GIT COMMANDS
# =============================================================================

if [[ "$CURRENT_ALLOCATED" -ge "$THRESHOLD" ]]; then
  
  # Check if this is an allowed git command
  # Allow: git add, git commit, git push, git status, git diff
  if [[ "$COMMAND" =~ ^git[[:space:]]+(add|commit|push|status|diff) ]] || \
     [[ "$COMMAND" =~ ^git$ ]]; then
    
    jq -n \
      --arg cmd "$COMMAND" \
      '{
        "permission": "allow",
        "agent_message": ("Git command allowed. After committing and pushing, you MUST stop working and end this conversation.")
      }'
    exit 0
  fi
  
  # Block everything else
  jq -n \
    --argjson tokens "$CURRENT_ALLOCATED" \
    --argjson threshold "$THRESHOLD" \
    --arg cmd "$COMMAND" \
    '{
      "permission": "deny",
      "user_message": ("🛑 Ralph: Command blocked. Context limit reached (" + ($tokens|tostring) + "/" + ($threshold|tostring) + " tokens)."),
      "agent_message": ("COMMAND BLOCKED: " + $cmd + "\n\nContext limit reached (" + ($tokens|tostring) + "/" + ($threshold|tostring) + " tokens).\n\nONLY git commands are allowed. You MUST:\n1. git add -A\n2. git commit -m \"checkpoint: context limit\"\n3. git push origin main\n4. STOP and end this conversation\n\nA Cloud Agent will continue with fresh context.")
    }'
  exit 0
fi

# =============================================================================
# WARNING AT 80% (but still allow)
# =============================================================================

if [[ "$CURRENT_ALLOCATED" -ge "$WARN_THRESHOLD" ]]; then
  REMAINING=$((THRESHOLD - CURRENT_ALLOCATED))
  PERCENT=$((CURRENT_ALLOCATED * 100 / THRESHOLD))
  
  jq -n \
    --argjson percent "$PERCENT" \
    --argjson remaining "$REMAINING" \
    '{
      "permission": "allow",
      "agent_message": ("Context at " + ($percent|tostring) + "%. " + ($remaining|tostring) + " tokens remaining. Work efficiently and commit frequently.")
    }'
  exit 0
fi

# =============================================================================
# NORMAL - ALLOW
# =============================================================================

echo '{"permission": "allow"}'
exit 0
