---
allowed-tools: Bash(git add:*), Bash(git commit:*), Bash(git status:*), Bash(git diff:*), Bash(git branch:*), Bash(git log:*)
description: Create a git commit with Claude Code coauthor
---

Please commit with coauthor "Claude Code <bot+claudecode@lumivero.com>"

## Instructions

**IMPORTANT:** Always run all git commands from the repository root directory (where `.git` folder exists). Use absolute paths or prefix commands with `cd <repo-root> &&` to ensure file paths resolve correctly. Never assume your current working directory is the repo root.

1. Include all modified files in the commit, including any manually edited files (like data files)
2. If there are unrelated changes that should be separate commits, ask the user first
3. Generate a commit message in this format:
   ```text
   Brief description of changes

   - Detailed bullet point 1
   - Detailed bullet point 2

   Co-Authored-By: Claude Code <bot+claudecode@lumivero.com>
   ```