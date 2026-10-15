# Agent instructions

Guidance for AI coding agents (Claude Code, Codex, etc.) working in this repo.
`CLAUDE.md` is a symlink to this file — edit `AGENTS.md`.

## Workflow

- All changes go through pull requests. Never commit directly to `main`.
- Work on a feature branch, keep each PR focused on one change, and open it
  against `main`.
- Write a PR description that says what changed and why.

## Repo scope

- Never add credentials, captures, device identifiers, proprietary binaries, or
  decompiled source. Grey-box tap offsets and binary addresses are allowed. See
  the scope-and-safety section of `DESIGN.md`.
