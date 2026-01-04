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

# Create directories
echo "📁 Creating directories..."
mkdir -p .cursor/ralph-scripts
mkdir -p .ralph

# Download scripts
echo "📥 Downloading Ralph scripts..."

SCRIPTS=(
  "before-prompt.sh"
  "before-read.sh"
  "before-shell.sh"
  "after-edit.sh"
  "stop-hook.sh"
  "spawn-cloud-agent.sh"
)

for script in "${SCRIPTS[@]}"; do
  curl -fsSL "$REPO_RAW/scripts/$script" -o ".cursor/ralph-scripts/$script"
  chmod +x ".cursor/ralph-scripts/$script"
done

echo "✓ Scripts installed to .cursor/ralph-scripts/"

# Download hooks.json and update paths
echo "📥 Downloading hooks configuration..."
curl -fsSL "$REPO_RAW/hooks.json" -o ".cursor/hooks.json"
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' 's|./scripts/|./.cursor/ralph-scripts/|g' .cursor/hooks.json
else
  sed -i 's|./scripts/|./.cursor/ralph-scripts/|g' .cursor/hooks.json
fi
echo "✓ Hooks configured in .cursor/hooks.json"

# Download SKILL.md
echo "📥 Downloading skill definition..."
curl -fsSL "$REPO_RAW/SKILL.md" -o ".cursor/SKILL.md"
echo "✓ Skill definition saved to .cursor/SKILL.md"

# =============================================================================
# EXPLAIN THE TWO MODES
# =============================================================================

echo ""
echo "Ralph has two modes for handling context (malloc/free):"
echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ 🌩️  CLOUD MODE (True Ralph)                                     │"
echo "├─────────────────────────────────────────────────────────────────┤"
echo "│ • Automatic fresh context via Cloud Agent API                  │"
echo "│ • When context fills up, spawns new Cloud Agent automatically  │"
echo "│ • True malloc/free cycle - fully autonomous                    │"
echo "│ • Requires: Cursor API key + GitHub repository                 │"
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ 💻 LOCAL MODE (Assisted Ralph)                                  │"
echo "├─────────────────────────────────────────────────────────────────┤"
echo "│ • Hooks detect when context is full                            │"
echo "│ • Instructs YOU to start a new conversation                    │"
echo "│ • Human-in-the-loop malloc/free cycle                          │"
echo "│ • Works without API key, works with local repos                │"
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""

# =============================================================================
# CLOUD MODE CONFIGURATION (optional)
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

if [[ "$CLOUD_ENABLED" == "false" ]] && [[ -t 0 ]]; then
  echo "To enable Cloud Mode, you can:"
  echo "  1. Set environment variable: export CURSOR_API_KEY='your-key'"
  echo "  2. Create ~/.cursor/ralph-config.json with your key"
  echo ""
  echo "Get your API key from: https://cursor.com/dashboard?tab=integrations"
  echo ""
  echo "Continuing with Local Mode for now..."
fi

# =============================================================================
# INITIALIZE STATE FILES
# =============================================================================

echo ""
echo "📁 Initializing .ralph/ state directory..."

INIT_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# state.md
cat > .ralph/state.md <<EOF
---
iteration: 0
status: initialized
started_at: $INIT_TIMESTAMP
---

# Ralph State

Iteration 0 - Initialized, waiting for first prompt.
EOF

# context-log.md
cat > .ralph/context-log.md <<EOF
# Context Allocation Log (Hook-Managed)

> ⚠️ This file is managed by hooks. Do not edit manually.

## Current Session

| File | Size (est tokens) | Timestamp |
|------|-------------------|-----------|

## Estimated Context Usage

- Allocated: 0 tokens
- Threshold: 60000 tokens (warn at 80%)
- Status: 🟢 Healthy

EOF

# edits.log
cat > .ralph/edits.log <<EOF
# Edit Log (Hook-Managed)
# This file is append-only. Do not edit manually.
# Format: TIMESTAMP | FILE | CHANGE_TYPE | CHARS | ITERATION

EOF

# failures.md
cat > .ralph/failures.md <<EOF
# Failure Log (Hook-Managed)

## Pattern Detection

- Repeated failures: 0
- Gutter risk: Low

## Recent Failures

(Failures will be logged here by hooks)

EOF

# guardrails.md
cat > .ralph/guardrails.md <<EOF
# Ralph Guardrails (Signs)

These are lessons learned from iterations. Follow these to avoid known pitfalls.

## Core Signs

### Sign: Read Before Writing
- **Always** read existing files before modifying them

### Sign: Test After Changes
- Run tests after every significant change

### Sign: Commit Checkpoints
- Commit working states before attempting risky changes

### Sign: One Thing at a Time
- Focus on one criterion at a time

---

## Learned Signs

(Signs added from observed failures will appear below)

EOF

# progress.md - incremental, hooks append checkpoints
cat > .ralph/progress.md <<EOF
# Progress Log

> This file tracks incremental progress. Hooks append checkpoints automatically.
> You can also add your own notes and summaries here.

---

## Iteration History

EOF

echo "✓ State files created in .ralph/"

# =============================================================================
# CREATE RALPH_TASK.md TEMPLATE
# =============================================================================

if [[ ! -f "RALPH_TASK.md" ]]; then
  echo "📝 Creating RALPH_TASK.md template..."
  cat > RALPH_TASK.md <<'EOF'
---
task: Build a CLI todo app in TypeScript
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

1. Read `.ralph/progress.md` to see what's been done
2. Check `.ralph/guardrails.md` for signs to follow
3. Work on the next incomplete criterion (marked [ ])
4. Check off completed criteria (change [ ] to [x])
5. Commit your changes with descriptive messages
6. When ALL criteria are [x], say: `RALPH_COMPLETE: All criteria satisfied`
7. If stuck on the same issue 3+ times, say: `RALPH_GUTTER: Need fresh context`
EOF
  echo "✓ Created RALPH_TASK.md with TypeScript example task"
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
echo "     ├── hooks.json           - Cursor hooks configuration"
echo "     ├── ralph-scripts/       - Hook scripts"
echo "     └── SKILL.md             - Skill definition"
echo ""
echo "  📁 .ralph/"
echo "     ├── state.md             - Current iteration"
echo "     ├── progress.md          - Incremental checkpoints"
echo "     ├── context-log.md       - Context (malloc) tracking"
echo "     ├── edits.log            - Raw edit history"
echo "     ├── failures.md          - Failure patterns"
echo "     └── guardrails.md        - Signs to follow"
echo ""
echo "  📄 RALPH_TASK.md            - Your task definition (edit this!)"
echo ""
echo "Next steps:"
echo "  1. Edit RALPH_TASK.md to define your actual task"
echo "  2. Open this folder in Cursor"
echo "  3. Start a new conversation"
echo "  4. Say: \"Work on the Ralph task in RALPH_TASK.md\""
echo ""
if [[ "$CLOUD_ENABLED" == "true" ]]; then
  echo "Mode: 🌩️  Cloud (automatic context management)"
else
  echo "Mode: 💻 Local (you'll be prompted to start new conversations)"
  echo ""
  echo "To enable Cloud Mode:"
  echo "  export CURSOR_API_KEY='your-key-from-cursor-dashboard'"
fi
echo ""
echo "Learn more: https://ghuntley.com/ralph/"
echo "═══════════════════════════════════════════════════════════════════"
