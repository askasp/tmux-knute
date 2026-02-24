# tmux-knute

A tmux plugin for managing workspaces, git worktrees, and Claude Code agents from a single dashboard.

## What it does

Press `prefix + K` to open a full-screen fzf dashboard that shows all your tmux sessions with live agent status. From there you can create worktrees, spawn Claude agents with file context, open terminals, run lazygit, and switch between everything instantly.

### Dashboard keybindings

| Key | Action |
|-----|--------|
| `enter` | Switch to selected session/window |
| `ctrl-w` | Create new git worktree + optional Claude agent |
| `ctrl-a` | Add new Claude agent to selected session |
| `ctrl-t` | Open terminal window in selected session |
| `ctrl-n` | Create new standalone tmux session |
| `ctrl-x` | Kill selected window or session |
| `ctrl-g` | Merge selected worktree back |
| `ctrl-l` | Open lazygit for selected session |
| `ctrl-e` | Toggle expanded/collapsed view |
| `ctrl-r` | Refresh list |

### Agent status indicators

The dashboard shows live status for Claude Code agents:

- **active** -- agent is working
- **input** -- agent is waiting for your input (permission prompt, question)
- **done** -- agent has finished (bell notification)

### File context with `@`

When creating a worktree (`ctrl-w`) or agent (`ctrl-a`), type `@` in the task prompt to open an inline fzf file picker. Selected files are inserted as `@path/to/file` references that Claude Code uses as context. Multi-select with tab.

## Requirements

- tmux (with popup support, 3.2+)
- [fzf](https://github.com/junegunn/fzf)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude` CLI)
- git
- Optional: [lazygit](https://github.com/jesseduffield/lazygit)

## Install

### With TPM (recommended)

Add to `~/.tmux.conf`:

```bash
set -g @plugin 'path/to/tmux-knute'
```

For a local clone:

```bash
set -g @plugin '$HOME/git/tmux-knute'
```

Make sure TPM is installed and runs at the end of your tmux.conf:

```bash
# Install TPM if you don't have it:
# git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

run '~/.tmux/plugins/tpm/tpm'
```

Then reload tmux:

```bash
tmux source ~/.tmux.conf
```

### Manual

Clone the repo and source the plugin file from your tmux.conf:

```bash
git clone https://github.com/youruser/tmux-knute ~/git/tmux-knute
```

Add to `~/.tmux.conf`:

```bash
run-shell ~/git/tmux-knute/knute.tmux
```

Reload:

```bash
tmux source ~/.tmux.conf
```

## How it works

- **Worktrees** (`ctrl-w`): Creates a git worktree on a new branch, starts a tmux session in it, and optionally launches a Claude agent with a task and file context.
- **Agents** (`ctrl-a`): Adds a new window to an existing session running Claude Code with your task. The wrapper script tracks agent state and sends a bell notification when Claude finishes.
- **Sessions** (`ctrl-n`): Creates a plain tmux session in any directory -- not tied to a worktree or agent.
- **Switching** (`enter`): Switches your client to the selected session or specific window within it.
- **Preview pane**: Shows git branch, recent commits, and live pane content for the selected item.

## Project structure

```
knute.tmux              TPM entry point, binds prefix+K
scripts/
  dashboard.sh          fzf dashboard UI and all sub-modes
  new-worktree.sh       create worktree + session + optional agent
  new-agent.sh          add claude agent window to a session
  claude-wrapper.sh     wraps claude with state tracking and bell notification
  merge-worktree.sh     merge a worktree branch back
  kill-worktree.sh      kill session and clean up worktree
  post-switch.sh        handles session switching after popup closes
  helpers.sh            shared utilities (file completion, session resolution)
```
