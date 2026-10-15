# Agent instructions

Guidance for AI coding agents (Claude Code, Codex, etc.) working in this repo.
`CLAUDE.md` is a symlink to this file — edit `AGENTS.md`.

## Workflow

- All changes go through pull requests. Never commit directly to `main`.
- Work on a feature branch, keep each PR focused on one change, and open it
  against `main`.
- Write a PR description that says what changed and why.

## Repo scope

- This repo is a design proposal (see `README.md`, `DESIGN.md`,
  `docs/alternatives.md`). It holds methodology only.
- Never add credentials, captures, device identifiers, binary addresses, or
  decompiled source. See the scope-and-safety section of `DESIGN.md`.
