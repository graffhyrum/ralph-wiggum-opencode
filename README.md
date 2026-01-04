# Ralph Wiggum Cursor Skill

A Cursor Skill implementing [Geoffrey Huntley's Ralph Wiggum technique](https://ghuntley.com/ralph/) for autonomous AI development with deliberate context management.

> "That's the beauty of Ralph - the technique is deterministically bad in an undeterministic world."

## Quick Start

```bash
# In your project directory
curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main/install.sh | bash
```

That's it. Edit `RALPH_TASK.md`, open Cursor, and tell it to work on the Ralph task.

## What is Ralph?

Ralph is a technique for autonomous AI development. In its purest form, it's a loop:

```bash
while :; do cat PROMPT.md | npx --yes @sourcegraph/amp ; done
```

The same prompt is fed repeatedly to an AI agent. Progress persists in **files and git**, not in the LLM's context window. Each iteration starts fresh, reads the current state from files, and continues the work.

## The malloc/free Problem

> "When data is `malloc()`'ed into the LLM's context window, it cannot be `free()`'d unless you create a brand new context window."

This is the core insight. LLM context is like memory:
- Reading files, tool outputs, conversation history = `malloc()`
- **There is no `free()`** - you cannot selectively clear context
- The only way to free context is to **start a new conversation**

Most implementations miss this. They keep the same context running, just blocking exit. Context accumulates, gets polluted, and performance degrades.

## Two Modes

### 🌩️ Cloud Mode (True Ralph)

**Automatic malloc/free via Cloud Agent API**

When context fills up, Ralph automatically spawns a Cloud Agent with fresh context. True autonomous operation.

**Enable with:**
```bash
export CURSOR_API_KEY='your-key'  # Get from cursor.com/dashboard
```

### 💻 Local Mode (Assisted Ralph)

**Human-in-the-loop malloc/free**

When context fills up, Ralph tells you to start a new conversation. You trigger the context reset manually.

**Works out of the box** - no API key needed.

## Installation

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main/install.sh | bash
```

This installs everything directly into your project:
- `.cursor/hooks.json` - Hook configuration
- `.cursor/ralph-scripts/` - Hook scripts
- `.ralph/` - State tracking
- `RALPH_TASK.md` - Task template

### Manual

```bash
git clone https://github.com/agrimsingh/ralph-wiggum-cursor.git
cp -r ralph-wiggum-cursor/scripts .cursor/ralph-scripts
cp ralph-wiggum-cursor/hooks.json .cursor/
# Update paths in hooks.json: ./scripts/ → ./.cursor/ralph-scripts/
mkdir .ralph
# Create state files (see install.sh for contents)
```

## Usage

### 1. Define Your Task

Edit `RALPH_TASK.md`:

```markdown
---
task: Build a REST API
completion_criteria:
  - All CRUD endpoints working
  - Tests passing
  - Documentation complete
max_iterations: 20
---

# Task: REST API

## Requirements
...

## Success Criteria
1. [ ] Endpoint X works
2. [ ] Endpoint Y works
3. [ ] Tests pass
```

### 2. Start Ralph

Open Cursor, new conversation:

> "Work on the Ralph task in RALPH_TASK.md"

### 3. Let It Run

Ralph will:
- Read the task and progress files
- Work on incomplete criteria
- Update `.ralph/progress.md`
- Commit checkpoints
- Handle context limits (Cloud or Local mode)

### 4. Context Limit Reached

**Cloud Mode:** Automatically spawns new Cloud Agent

**Local Mode:** Shows:
```
═══════════════════════════════════════════════════════════════════
⚠️  RALPH: CONTEXT LIMIT REACHED (malloc full)
═══════════════════════════════════════════════════════════════════

To continue with fresh context:
  1. Your progress is saved in .ralph/progress.md
  2. START A NEW CONVERSATION in Cursor
  3. Say: "Continue the Ralph task from iteration N"
```

## How It Works

### The malloc/free Cycle

```
┌─────────────────────────────────────────────────────────────────┐
│ ITERATION N - Context filling up                                │
│ [prompt] [file1] [file2] [errors] [attempts] [more stuff...]   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    Context limit detected
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
       Cloud Mode                       Local Mode
    Spawn Cloud Agent              Tell human to start
      automatically                 new conversation
              │                               │
              └───────────────┬───────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ ITERATION N+1 - Fresh context                                   │
│ [prompt] ← Only loads what's needed                            │
│ Reads .ralph/progress.md to know what's done                   │
└─────────────────────────────────────────────────────────────────┘
```

### State Files

| File | Purpose |
|------|---------|
| `.ralph/state.md` | Current iteration, status |
| `.ralph/progress.md` | What's been accomplished (survives context reset) |
| `.ralph/guardrails.md` | "Signs" - lessons from failures |
| `.ralph/context-log.md` | Tracks context allocations |
| `.ralph/failures.md` | Failure patterns for gutter detection |

### Hooks

| Hook | Trigger | Purpose |
|------|---------|---------|
| `beforeSubmitPrompt` | Before each message | Inject guardrails |
| `beforeReadFile` | File read | Track malloc |
| `afterFileEdit` | File edited | Log progress |
| `stop` | Conversation end | Manage iterations |

## Cloud Mode Setup

Get your API key from [cursor.com/dashboard](https://cursor.com/dashboard?tab=integrations)

**Option 1: Environment variable**
```bash
export CURSOR_API_KEY='key-here'
```

**Option 2: Global config** (`~/.cursor/ralph-config.json`)
```json
{"cursor_api_key": "key-here"}
```

**Option 3: Project config** (`.cursor/ralph-config.json`)
```json
{"cursor_api_key": "key-here", "cloud_agent_enabled": true}
```

## Completion Signals

Tell Ralph when you're done or stuck:

- `RALPH_COMPLETE: All criteria satisfied` - Task finished
- `RALPH_GUTTER: Need fresh context` - Stuck in failure loop

## Learn More

- [Original Ralph technique](https://ghuntley.com/ralph/) - Geoffrey Huntley
- [Context as memory](https://ghuntley.com/allocations/) - The malloc/free metaphor
- [The gutter](https://ghuntley.com/gutter/) - Autoregressive failure

## License

MIT
