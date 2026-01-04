#!/bin/bash
# Ralph Wiggum: Before Shell Execution Hook
# - DENIES shell commands when context limit is exceeded (forces agent to stop)
# - Allows git commit/push even when over limit (to save work)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract command and workspace
COMMAND=$(echo "$HOOK_INPUT" | jq -r '.command // ""')
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')

RALPH_DIR="$WORKSPACE_ROOT/.ralph"
CONTEXT_LOG="$RALPH_DIR/context-log.md"
CONFIG_FILE="$WORKSPACE_ROOT/.cursor/ralph-config.json"

# If Ralph isn't active, pass through
if [[ ! -d "$RALPH_DIR" ]]; then
  echo '{"permission": "allow"}'
  exit 0
fi

# =============================================================================
# CHECK CONTEXT LIMIT - DENY IF OVER LIMIT (except for git commit/push)
# =============================================================================

THRESHOLD=80000

if [[ -f "$CONTEXT_LOG" ]]; then
  CURRENT_ALLOCATED=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -o '[0-9]*' | head -1 || echo "0")
  if [[ -z "$CURRENT_ALLOCATED" ]]; then
    CURRENT_ALLOCATED=0
  fi
  
  # If over the limit, check if this is a git save command (allowed) or other (denied)
  if [[ "$CURRENT_ALLOCATED" -gt "$THRESHOLD" ]]; then
    
    # Allow git commit, git push, git add (to save work before stopping)
    if [[ "$COMMAND" =~ ^git[[:space:]]+(commit|push|add|status) ]]; then
      jq -n \
        --arg cmd "$COMMAND" \
        '{
          "permission": "allow",
          "agent_message": "Git command allowed to save work. After committing, you MUST stop. Context limit exceeded."
        }'
      exit 0
    fi
    
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

    # DENY the command
    if is_cloud_enabled; then
      # Try to spawn Cloud Agent in background (if not already spawning)
      if [[ ! -f "/tmp/ralph-spawning-$$.lock" ]]; then
        touch "/tmp/ralph-spawning-$$.lock"
        "$SCRIPT_DIR/spawn-cloud-agent.sh" "$WORKSPACE_ROOT" > /tmp/ralph-cloud-spawn.log 2>&1 &
      fi
      
      jq -n \
        --argjson tokens "$CURRENT_ALLOCATED" \
        --arg cmd "$COMMAND" \
        '{
          "permission": "deny",
          "user_message": "🛑 Ralph: Context limit exceeded (" + ($tokens|tostring) + " tokens). Command blocked. Spawning Cloud Agent...",
          "agent_message": "STOP. Context limit exceeded (" + ($tokens|tostring) + " tokens). Command DENIED: " + $cmd + ". A Cloud Agent is being spawned. You must stop working. Only git commit/push commands are allowed to save your work."
        }'
    else
      CURRENT_ITERATION=$(grep '^iteration:' "$RALPH_DIR/state.md" 2>/dev/null | sed 's/iteration: *//' || echo "0")
      
      jq -n \
        --argjson tokens "$CURRENT_ALLOCATED" \
        --argjson iter "$CURRENT_ITERATION" \
        --arg cmd "$COMMAND" \
        '{
          "permission": "deny",
          "user_message": "🛑 Ralph: Context limit exceeded (" + ($tokens|tostring) + " tokens). Start a NEW conversation: \"Continue Ralph from iteration " + ($iter|tostring) + "\"",
          "agent_message": "STOP. Context limit exceeded (" + ($tokens|tostring) + " tokens). Command DENIED: " + $cmd + ". You must stop working. Only git commit/push commands are allowed. Tell the user to start a new conversation."
        }'
    fi
    exit 0
  fi
fi

# Normal case - allow the command
echo '{"permission": "allow"}'
exit 0
