# CLAUDE.md

@AGENTS.md

Claude Code specifics:
- `.claude/settings.json` pre-approves the build/test commands and **denies edits to the protected credits files**. Don't try to work around that.
- Prefer `make check` before saying a change is done.
