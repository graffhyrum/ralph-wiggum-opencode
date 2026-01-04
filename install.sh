#!/bin/bash
# Ralph Wiggum: One-click installer
# Usage: curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main/install.sh | bash
#
# This installs Ralph directly into your current project.
# No external repo reference needed - everything lives in your project.

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
# Update paths to point to local scripts
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

# Check for existing API key
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
  # Only prompt if running interactively (not piped)
  echo "To enable Cloud Mode, you can:"
  echo "  1. Set environment variable: export CURSOR_API_KEY='your-key'"
  echo "  2. Create ~/.cursor/ralph-config.json with your key"
  echo "  3. Create .cursor/ralph-config.json in this project"
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

cat > .ralph/state.md <<'EOF'
---
iteration: 0
status: initialized
started_at: {{TIMESTAMP}}
---

# Ralph State

Ready to begin. Start a conversation and mention the Ralph task.
EOF
sed -i "s/{{TIMESTAMP}}/$(date -u +%Y-%m-%dT%H:%M:%SZ)/" .ralph/state.md 2>/dev/null || \
  sed -i '' "s/{{TIMESTAMP}}/$(date -u +%Y-%m-%dT%H:%M:%SZ)/" .ralph/state.md

cat > .ralph/guardrails.md <<'EOF'
# Ralph Guardrails (Signs)

These are lessons learned from iterations. Follow these to avoid known pitfalls.

## Core Signs

### Sign: Read Before Writing
- **Always** read existing files before modifying them
- Check git history for context on why things are the way they are

### Sign: Test After Changes
- Run tests after every significant change
- Don't assume code works - verify it

### Sign: Commit Checkpoints
- Commit working states before attempting risky changes
- Use descriptive commit messages

### Sign: One Thing at a Time
- Focus on one criterion at a time
- Don't try to do everything in one iteration

### Sign: Update Progress
- Always update .ralph/progress.md with what you accomplished
- This is how future iterations (and fresh contexts) know what's done

---

## Learned Signs

(Signs added from observed failures will appear below)

EOF

cat > .ralph/context-log.md <<'EOF'
# Context Allocation Log

Tracking what's been loaded into context to prevent redlining.

## The malloc/free Metaphor

- Reading files = malloc() into context
- There is NO free() - context cannot be selectively cleared
- Only way to free: start a new conversation

## Current Session

| File | Size (est tokens) | Timestamp |
|------|-------------------|-----------|

## Estimated Context Usage

- Allocated: 0 tokens
- Threshold: 80000 tokens (warn at 80%)
- Status: 🟢 Healthy

EOF

cat > .ralph/failures.md <<'EOF'
# Failure Log

Tracking failure patterns to detect "gutter" situations.

## What is the Gutter?

> "If the bowling ball is in the gutter, there's no saving it."

When the agent is stuck in a failure loop, it's "in the gutter."
The solution is fresh context, not more attempts in polluted context.

## Recent Failures

(Failures will be logged here)

## Pattern Detection

- Repeated failures: 0
- Gutter risk: Low

EOF

cat > .ralph/progress.md <<'EOF'
# Progress Log

## Summary

- Iterations completed: 0
- Tasks completed: 0
- Current status: Initialized

## How This Works

Progress is tracked in THIS FILE, not in LLM context.
When context is freed (new conversation), the new context reads this file.
This is how Ralph maintains continuity across the malloc/free cycle.

## Iteration History

(Progress will be logged here as iterations complete)

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
  - Can add todos with: npx ts-node todo.ts add "task"
  - Can list todos with: npx ts-node todo.ts list  
  - Can complete todos with: npx ts-node todo.ts done <id>
  - Todos persist to todos.json
  - Has helpful error messages
max_iterations: 20
---

# Task: CLI Todo App (TypeScript)

Build a simple command-line todo application in TypeScript.

## Requirements

1. Single file: `todo.ts`
2. Uses `todos.json` for persistence
3. Three commands: add, list, done
4. Shows todo ID and completion status when listing
5. TypeScript with proper types

## Success Criteria

The task is complete when ALL of the following are true:

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

$ npx ts-node todo.ts add "Walk dog"
✓ Added: "Walk dog" (id: 2)

$ npx ts-node todo.ts list
1. [ ] Buy milk
2. [ ] Walk dog

$ npx ts-node todo.ts done 1
✓ Completed: "Buy milk"

$ npx ts-node todo.ts list
1. [x] Buy milk
2. [ ] Walk dog
```

---

## Ralph Instructions

When working on this task:

1. Read `.ralph/progress.md` to see what's been done
2. Check `.ralph/guardrails.md` for signs to follow
3. Work on the next incomplete criterion
4. Update `.ralph/progress.md` with your progress
5. Commit your changes with descriptive messages
6. When ALL criteria are met, say: `RALPH_COMPLETE: All criteria satisfied`
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
  if ! grep -q "^\.ralph/" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Ralph state (regenerated each session)" >> .gitignore
    echo ".ralph/" >> .gitignore
  fi
  if ! grep -q "ralph-config.json" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Ralph config (may contain API key)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
  echo "✓ Updated .gitignore"
else
  cat > .gitignore <<'EOF'
# Ralph state (regenerated each session)
.ralph/

# Ralph config (may contain API key)
.cursor/ralph-config.json
EOF
  echo "✓ Created .gitignore"
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
echo "  .cursor/hooks.json        - Cursor hooks configuration"
echo "  .cursor/ralph-scripts/    - Hook scripts"
echo "  .cursor/SKILL.md          - Skill definition"
echo "  .ralph/                   - State tracking directory"
echo "  RALPH_TASK.md             - Your task definition (edit this!)"
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
  echo "To enable Cloud Mode (automatic fresh context):"
  echo "  export CURSOR_API_KEY='your-key-from-cursor-dashboard'"
fi
echo ""
echo "Learn more: https://ghuntley.com/ralph/"
echo "═══════════════════════════════════════════════════════════════════"
