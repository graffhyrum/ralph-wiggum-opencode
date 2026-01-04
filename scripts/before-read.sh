#!/bin/bash
# Ralph Wiggum: Before Read File Hook
# - Tracks context allocations
# - Warns at 80% of threshold
# - DENIES file reads at 100% threshold (forces agent to stop and commit)

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Context threshold (lowered to 60k for easier testing)
THRESHOLD=60000
WARN_PERCENT=80
WARN_THRESHOLD=$((THRESHOLD * WARN_PERCENT / 100))

# Token multiplier: file reads/edits are ~25% of total context
# (agent responses, tool calls, system prompts make up the rest)
TOKEN_MULTIPLIER=4

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

# Extract file info
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.file_path // .path // ""')
CONTENT=$(echo "$HOOK_INPUT" | jq -r '.content // .file_content // ""')
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
# CHECK THRESHOLDS BEFORE ALLOWING READ
# =============================================================================

# AT OR OVER 100% - DENY (except we can't block, so just deny reads)
if [[ "$CURRENT_ALLOCATED" -ge "$THRESHOLD" ]]; then
  jq -n \
    --argjson tokens "$CURRENT_ALLOCATED" \
    --argjson threshold "$THRESHOLD" \
    '{
      "permission": "deny",
      "user_message": ("🛑 Ralph: Context limit reached (" + ($tokens|tostring) + "/" + ($threshold|tostring) + " tokens). Agent must commit and stop."),
      "agent_message": ("STOP IMMEDIATELY. Context limit reached (" + ($tokens|tostring) + "/" + ($threshold|tostring) + " tokens).\n\nYou MUST:\n1. Run: git add -A && git commit -m \"checkpoint: context limit reached\"\n2. Run: git push origin main\n3. STOP working and end this conversation.\n\nA Cloud Agent will continue your work with fresh context. Do NOT attempt any other operations.")
    }'
  exit 0
fi

# =============================================================================
# TRACK CONTEXT ALLOCATION (if under threshold)
# =============================================================================

# Estimate token count for this file
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
  NEW_ALLOCATED=$((CURRENT_ALLOCATED + ESTIMATED_TOKENS))
  
  sedi "s/Allocated: [0-9]* tokens/Allocated: $NEW_ALLOCATED tokens/" "$CONTEXT_LOG"
  
  # Update status indicator
  if [[ "$NEW_ALLOCATED" -ge "$THRESHOLD" ]]; then
    sedi "s/Status: .*/Status: 🔴 LIMIT REACHED - Must stop!/" "$CONTEXT_LOG"
  elif [[ "$NEW_ALLOCATED" -ge "$WARN_THRESHOLD" ]]; then
    sedi "s/Status: .*/Status: 🟡 Warning - Approaching limit/" "$CONTEXT_LOG"
  fi
  
  # Log this file read
  TEMP_FILE=$(mktemp)
  awk -v file="$FILE_PATH" -v tokens="$ESTIMATED_TOKENS" -v ts="$TIMESTAMP" '
    /^## Estimated Context Usage/ {
      print "| " file " | " tokens " | " ts " |"
      print ""
    }
    { print }
  ' "$CONTEXT_LOG" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$CONTEXT_LOG"
  
  CURRENT_ALLOCATED=$NEW_ALLOCATED
fi

# =============================================================================
# WARNING AT 80% (but still allow)
# =============================================================================

if [[ "$CURRENT_ALLOCATED" -ge "$WARN_THRESHOLD" ]]; then
  REMAINING=$((THRESHOLD - CURRENT_ALLOCATED))
  PERCENT=$((CURRENT_ALLOCATED * 100 / THRESHOLD))
  
  jq -n \
    --argjson tokens "$CURRENT_ALLOCATED" \
    --argjson threshold "$THRESHOLD" \
    --argjson remaining "$REMAINING" \
    --argjson percent "$PERCENT" \
    '{
      "permission": "allow",
      "user_message": ("⚠️ Ralph: Context at " + ($percent|tostring) + "% (" + ($tokens|tostring) + "/" + ($threshold|tostring) + " tokens). " + ($remaining|tostring) + " remaining."),
      "agent_message": ("WARNING: Context at " + ($percent|tostring) + "% (" + ($tokens|tostring) + "/" + ($threshold|tostring) + " tokens).\n\nYou have " + ($remaining|tostring) + " tokens remaining. Work efficiently:\n- Complete your current task quickly\n- Commit frequently with descriptive messages\n- Prepare to hand off to a fresh context soon")
    }'
  exit 0
fi

# =============================================================================
# NORMAL - ALLOW
# =============================================================================

echo '{"permission": "allow"}'
exit 0
