#!/bin/bash
# Ralph Wiggum: Before Read File Hook
# - Tracks context allocations to prevent redlining
# - DENIES file reads when context limit is exceeded (forces agent to stop)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Token multiplier: We only track file reads/edits, but context also includes
# agent responses, tool calls, system prompts, etc. 4x approximates total usage.
TOKEN_MULTIPLIER=4

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

# Extract file info - Cursor may send different field names
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.file_path // .path // ""')
CONTENT=$(echo "$HOOK_INPUT" | jq -r '.content // .file_content // ""')
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
# CHECK CONTEXT LIMIT FIRST - DENY IF OVER LIMIT
# =============================================================================

THRESHOLD=80000

if [[ -f "$CONTEXT_LOG" ]]; then
  CURRENT_ALLOCATED=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -o '[0-9]*' | head -1 || echo "0")
  if [[ -z "$CURRENT_ALLOCATED" ]]; then
    CURRENT_ALLOCATED=0
  fi
  
  # If over the limit, DENY the file read to force the agent to stop
  if [[ "$CURRENT_ALLOCATED" -gt "$THRESHOLD" ]]; then
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

    # Try to spawn Cloud Agent in background
    if is_cloud_enabled; then
      "$SCRIPT_DIR/spawn-cloud-agent.sh" "$WORKSPACE_ROOT" > /tmp/ralph-cloud-spawn.log 2>&1 &
      
      jq -n \
        --argjson tokens "$CURRENT_ALLOCATED" \
        '{
          "permission": "deny",
          "user_message": "🛑 Ralph: Context limit exceeded (" + ($tokens|tostring) + " tokens). Spawning Cloud Agent with fresh context...",
          "agent_message": "STOP. Context limit exceeded (" + ($tokens|tostring) + " tokens). File read DENIED. A Cloud Agent is being spawned to continue this task. You must stop working immediately. Commit any pending changes and end this conversation."
        }'
    else
      # Local Mode - no Cloud Agent
      CURRENT_ITERATION=$(grep '^iteration:' "$RALPH_DIR/state.md" 2>/dev/null | sed 's/iteration: *//' || echo "0")
      
      jq -n \
        --argjson tokens "$CURRENT_ALLOCATED" \
        --argjson iter "$CURRENT_ITERATION" \
        '{
          "permission": "deny",
          "user_message": "🛑 Ralph: Context limit exceeded (" + ($tokens|tostring) + " tokens). Start a NEW conversation: \"Continue Ralph from iteration " + ($iter|tostring) + "\"",
          "agent_message": "STOP. Context limit exceeded (" + ($tokens|tostring) + " tokens). File read DENIED. You must stop working immediately. Commit any pending changes. Tell the user to start a new conversation to continue with fresh context."
        }'
    fi
    exit 0
  fi
fi

# =============================================================================
# TRACK CONTEXT ALLOCATION
# =============================================================================

# Estimate token count
if [[ -n "$CONTENT" ]]; then
  CONTENT_LENGTH=${#CONTENT}
  RAW_TOKENS=$((CONTENT_LENGTH / 4))
elif [[ -f "$FILE_PATH" ]]; then
  FILE_SIZE=$(wc -c < "$FILE_PATH" 2>/dev/null || echo "0")
  RAW_TOKENS=$((FILE_SIZE / 4))
else
  RAW_TOKENS=100
fi

ESTIMATED_TOKENS=$((RAW_TOKENS * TOKEN_MULTIPLIER))
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Update context log
if [[ -f "$CONTEXT_LOG" ]]; then
  CURRENT_ALLOCATED=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -o '[0-9]*' | head -1 || echo "0")
  if [[ -z "$CURRENT_ALLOCATED" ]]; then
    CURRENT_ALLOCATED=0
  fi
  NEW_ALLOCATED=$((CURRENT_ALLOCATED + ESTIMATED_TOKENS))
  
  sedi "s/Allocated: [0-9]* tokens/Allocated: $NEW_ALLOCATED tokens/" "$CONTEXT_LOG"
  
  # Determine status
  WARN_THRESHOLD=$((THRESHOLD * 80 / 100))
  CRITICAL_THRESHOLD=$((THRESHOLD * 95 / 100))
  
  if [[ "$NEW_ALLOCATED" -gt "$CRITICAL_THRESHOLD" ]]; then
    STATUS="🔴 Critical - Start fresh!"
    sedi "s/Status: .*/Status: $STATUS/" "$CONTEXT_LOG"
  elif [[ "$NEW_ALLOCATED" -gt "$WARN_THRESHOLD" ]]; then
    STATUS="🟡 Warning - Approaching limit"
    sedi "s/Status: .*/Status: $STATUS/" "$CONTEXT_LOG"
  fi
  
  # Log this file
  TEMP_FILE=$(mktemp)
  awk -v file="$FILE_PATH" -v tokens="$ESTIMATED_TOKENS" -v ts="$TIMESTAMP" '
    /^## Estimated Context Usage/ {
      print "| " file " | " tokens " | " ts " |"
      print ""
    }
    { print }
  ' "$CONTEXT_LOG" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$CONTEXT_LOG"
fi

# =============================================================================
# WARNING AT 80% (but still allow)
# =============================================================================

WARN_THRESHOLD=$((THRESHOLD * 80 / 100))

if [[ -f "$CONTEXT_LOG" ]]; then
  CURRENT_ALLOCATED=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -o '[0-9]*' | head -1 || echo "0")
  if [[ -z "$CURRENT_ALLOCATED" ]]; then
    CURRENT_ALLOCATED=0
  fi
  
  if [[ "$CURRENT_ALLOCATED" -gt "$WARN_THRESHOLD" ]] && [[ "$CURRENT_ALLOCATED" -le "$THRESHOLD" ]]; then
    REMAINING=$((THRESHOLD - CURRENT_ALLOCATED))
    jq -n \
      --argjson tokens "$CURRENT_ALLOCATED" \
      --argjson remaining "$REMAINING" \
      '{
        "permission": "allow",
        "user_message": "⚠️ Ralph: Context at " + ($tokens|tostring) + " tokens (" + ($remaining|tostring) + " remaining). Approaching limit.",
        "agent_message": "WARNING: Context approaching limit (" + ($tokens|tostring) + "/" + "80000 tokens). Work efficiently. Complete current task and commit soon."
      }'
    exit 0
  fi
fi

# Normal case - allow the read
echo '{"permission": "allow"}'
exit 0
