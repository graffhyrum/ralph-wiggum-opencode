#!/bin/bash
# Ralph Wiggum: One-click installer
# Usage: curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main/install.sh | bash

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main"

echo "═══════════════════════════════════════════════════════════════════"
echo "🐛 Ralph Wiggum Installer"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for checkpoint tracking."
  echo "   Cloud Mode REQUIRES a GitHub repository."
  echo ""
  echo "   Run: git init && gh repo create <name> --private --source=. --remote=origin"
  echo ""
fi

WORKSPACE_ROOT="$(pwd)"

# =============================================================================
# CREATE DIRECTORIES
# =============================================================================

echo "📁 Creating directories..."
mkdir -p .cursor/ralph-scripts
mkdir -p .ralph

# Create external state directory
WORKSPACE_HASH=$(echo -n "$WORKSPACE_ROOT" | shasum -a 256 | cut -c1-12)
EXTERNAL_STATE_DIR="$HOME/.cursor/ralph/$WORKSPACE_HASH"
mkdir -p "$EXTERNAL_STATE_DIR"
echo "   External state: $EXTERNAL_STATE_DIR"

# =============================================================================
# DOWNLOAD SCRIPTS
# =============================================================================

echo "📥 Downloading Ralph scripts..."

SCRIPTS=(
  "ralph-common.sh"
  "before-prompt.sh"
  "before-read.sh"
  "before-shell.sh"
  "after-edit.sh"
  "stop-hook.sh"
  "spawn-cloud-agent.sh"
  "watch-cloud-agent.sh"
  "ralph-loop.sh"
  "test-cloud-api.sh"
)

for script in "${SCRIPTS[@]}"; do
  curl -fsSL "$REPO_RAW/scripts/$script" -o ".cursor/ralph-scripts/$script"
  chmod +x ".cursor/ralph-scripts/$script"
done

echo "✓ Scripts installed to .cursor/ralph-scripts/"

# =============================================================================
# DOWNLOAD AND CONFIGURE HOOKS
# =============================================================================

echo "📥 Downloading hooks configuration..."
curl -fsSL "$REPO_RAW/hooks.json" -o ".cursor/hooks.json"

# Update paths in hooks.json
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' 's|./scripts/|./.cursor/ralph-scripts/|g' .cursor/hooks.json
else
  sed -i 's|./scripts/|./.cursor/ralph-scripts/|g' .cursor/hooks.json
fi
echo "✓ Hooks configured in .cursor/hooks.json"

# =============================================================================
# INITIALIZE EXTERNAL STATE
# =============================================================================

echo "📁 Initializing external state..."

INIT_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# state.md
cat > "$EXTERNAL_STATE_DIR/state.md" <<EOF
---
iteration: 0
status: initialized
workspace: $WORKSPACE_ROOT
started_at: $INIT_TIMESTAMP
---

# Ralph State

Iteration 0 - Initialized, waiting for first prompt.
EOF

# context-log.md
cat > "$EXTERNAL_STATE_DIR/context-log.md" <<EOF
# Context Allocation Log (External State)

> This file is managed by hooks. Stored outside workspace to prevent tampering.

## Current Session

- Turn count: 0
- Estimated tokens: 0
- Threshold: 60000 tokens
- Status: 🟢 Healthy

## Activity Log

| Turn | Tokens | Timestamp |
|------|--------|-----------|
EOF

# progress.md
cat > "$EXTERNAL_STATE_DIR/progress.md" <<EOF
# Progress Log

> External state - survives context resets.
> Workspace: $WORKSPACE_ROOT

---

## Iteration History

EOF

# guardrails.md
cat > "$EXTERNAL_STATE_DIR/guardrails.md" <<EOF
# Ralph Guardrails (Signs)

## Core Signs

### Sign: Read Before Writing
- **Always** read existing files before modifying them

### Sign: Test After Changes
- Run tests after every significant change

### Sign: Commit Checkpoints
- Commit working states before risky changes

### Sign: One Thing at a Time
- Focus on one criterion at a time

---

## Learned Signs

EOF

# failures.md
cat > "$EXTERNAL_STATE_DIR/failures.md" <<EOF
# Failure Log

## Pattern Detection

- Repeated failures: 0
- Gutter risk: Low

## Recent Failures

EOF

# edits.log
cat > "$EXTERNAL_STATE_DIR/edits.log" <<EOF
# Edit Log (External State)
# Format: TIMESTAMP | FILE | CHANGE_TYPE | CHARS | ITERATION

EOF

echo "✓ External state initialized at $EXTERNAL_STATE_DIR"

# =============================================================================
# INITIALIZE IN-WORKSPACE STATE (for Cloud Agents)
# =============================================================================

echo "📁 Initializing .ralph/ (synced for Cloud Agents)..."

# These files are synced from external state and committed for cloud agents
cat > .ralph/progress.md <<EOF
# Progress Log

> This file is synced from external state for Cloud Agent access.
> Workspace: $WORKSPACE_ROOT

---

## Iteration History

EOF

cat > .ralph/guardrails.md <<EOF
# Ralph Guardrails (Signs)

## Core Signs

### Sign: Read Before Writing
- **Always** read existing files before modifying them

### Sign: Test After Changes
- Run tests after every significant change

### Sign: Commit Checkpoints
- Commit working states before risky changes

### Sign: One Thing at a Time
- Focus on one criterion at a time

---

## Learned Signs

EOF

cat > .ralph/README.md <<EOF
# Ralph State Files

These files are synced from external state for Cloud Agent access.
The authoritative state is stored outside the workspace at:
  ~/.cursor/ralph/$WORKSPACE_HASH/

Do not edit these files directly - they will be overwritten during sync.
EOF

echo "✓ .ralph/ initialized"

# =============================================================================
# CREATE RALPH_TASK.md TEMPLATE
# =============================================================================

if [[ ! -f "RALPH_TASK.md" ]]; then
  echo "📝 Creating RALPH_TASK.md template..."
  cat > RALPH_TASK.md <<'TASKEOF'
---
task: Build a CLI todo app in TypeScript
test_command: "npx ts-node todo.ts list"
completion_criteria:
  - Can add todos
  - Can list todos
  - Can complete todos
  - Todos persist to JSON
  - Has error handling
max_iterations: 20
---

# Task: CLI Todo App (TypeScript)

Build a simple command-line todo application in TypeScript.

## Requirements

1. Single file: `todo.ts`
2. Uses `todos.json` for persistence
3. Three commands: add, list, done
4. TypeScript with proper types

## Success Criteria

1. [ ] `npx ts-node todo.ts add "Buy milk"` adds a todo and confirms
2. [ ] `npx ts-node todo.ts list` shows all todos with IDs and status
3. [ ] `npx ts-node todo.ts done 1` marks todo 1 as complete
4. [ ] Todos survive script restart (JSON persistence)
5. [ ] Invalid commands show helpful usage message
6. [ ] Code has proper TypeScript types (no `any`)

## Example Output

```
$ npx ts-node todo.ts add "Buy milk"
✓ Added: "Buy milk" (id: 1)

$ npx ts-node todo.ts list
1. [ ] Buy milk

$ npx ts-node todo.ts done 1
✓ Completed: "Buy milk"
```

---

## Ralph Instructions

1. Work on the next incomplete criterion (marked [ ])
2. Check off completed criteria (change [ ] to [x])
3. Run tests after changes
4. Commit your changes frequently
5. When ALL criteria are [x], say: `RALPH_COMPLETE`
6. If stuck on the same issue 3+ times, say: `RALPH_GUTTER`
TASKEOF
  echo "✓ Created RALPH_TASK.md with example task"
else
  echo "✓ RALPH_TASK.md already exists (not overwritten)"
fi

# =============================================================================
# UPDATE .gitignore
# =============================================================================

if [[ -f ".gitignore" ]]; then
  if ! grep -q "ralph-config.json" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Ralph config (may contain API key)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
else
  cat > .gitignore <<'EOF'
# Ralph config (may contain API key)
.cursor/ralph-config.json
EOF
fi
echo "✓ Updated .gitignore"

# =============================================================================
# CLOUD MODE CHECK
# =============================================================================

CLOUD_ENABLED=false

if [[ -n "${CURSOR_API_KEY:-}" ]]; then
  echo "✓ Found CURSOR_API_KEY in environment - Cloud Mode enabled"
  CLOUD_ENABLED=true
elif [[ -f "$HOME/.cursor/ralph-config.json" ]]; then
  EXISTING_KEY=$(jq -r '.cursor_api_key // empty' "$HOME/.cursor/ralph-config.json" 2>/dev/null || echo "")
  if [[ -n "$EXISTING_KEY" ]]; then
    echo "✓ Found API key in ~/.cursor/ralph-config.json - Cloud Mode enabled"
    CLOUD_ENABLED=true
  fi
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✅ Ralph installed!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Files created:"
echo ""
echo "  📁 .cursor/"
echo "     ├── hooks.json              - Cursor hooks configuration"
echo "     └── ralph-scripts/          - Hook scripts"
echo ""
echo "  📁 .ralph/                     - Synced state (for Cloud Agents)"
echo "     ├── progress.md"
echo "     └── guardrails.md"
echo ""
echo "  📁 ~/.cursor/ralph/$WORKSPACE_HASH/"
echo "     └── (external state - tamper-proof)"
echo ""
echo "  📄 RALPH_TASK.md               - Your task definition (edit this!)"
echo ""
echo "Next steps:"
echo "  1. Edit RALPH_TASK.md to define your actual task"
echo "  2. Restart Cursor (to load hooks)"
echo "  3. Start a new conversation"
echo "  4. Say: \"Work on the Ralph task in RALPH_TASK.md\""
echo ""
if [[ "$CLOUD_ENABLED" == "true" ]]; then
  echo "Mode: 🌩️  Cloud (automatic context handoff)"
else
  echo "Mode: 💻 Local (you'll be prompted to start new conversations)"
  echo ""
  echo "To enable Cloud Mode:"
  echo "  export CURSOR_API_KEY='your-key-from-cursor-dashboard'"
  echo "  # or"
  echo "  echo '{\"cursor_api_key\": \"your-key\"}' > ~/.cursor/ralph-config.json"
fi
echo ""
echo "Commands:"
echo "  Start loop:    ./.cursor/ralph-scripts/ralph-loop.sh"
echo "  Watch agent:   ./.cursor/ralph-scripts/watch-cloud-agent.sh <agent-id>"
echo "  Test API:      ./.cursor/ralph-scripts/test-cloud-api.sh"
echo "Learn more: https://ghuntley.com/ralph/"
echo "═══════════════════════════════════════════════════════════════════"
