<p align="center">
  <img src="screenshots/codex-profiles-logo.png" width="128" alt="Codex Profiles logo">
</p>

<h1 align="center">Codex Profiles</h1>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/codex-profiles-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="screenshots/codex-profiles-light.png">
  <img alt="Codex Profiles in light mode" src="screenshots/codex-profiles-light.png">
</picture>

Native macOS manager for local ChatGPT / Codex profiles, with Claude Code account launching and conversation handoff.

This is a community fork of [qwersyk/codex-profiles](https://github.com/qwersyk/codex-profiles).

## Features

- Browser sign-in, profile switching, imports, exports, and local sign-out
- Cached limits, reset counts, and manual or automatic session renewal
- Optional menu bar, ⌘0–9 switching, email privacy, and custom avatars

## Claude Code accounts

Select **Claude Code**, add a named account, then choose **Open** and a project folder. Claude Code will ask you to sign in on the first launch. Your original account remains available as **Current Claude account**. Each additional account has its own Claude configuration folder and Keychain login.

To switch conversations, choose **Switch & Continue…** on the destination account, select the project folder, and choose a saved conversation. Claude Code opens a fork in a new Terminal session; the original stays intact. This is a manual handoff, not an automatic switch at a usage limit, and it does not replace the account in an already-running process.

User- and project-local MCP server definitions from the original `~/.claude.json` are passed to newly launched profiles; project `.mcp.json` files remain available normally. Server OAuth sign-ins are separate, so authenticate again with `/mcp` if needed. Shared definitions are refreshed on each launch. Other settings and extensions are not automatically shared. The macOS automation permission for Terminal may be requested on first use.

## Build

```bash
chmod +x Scripts/build_dmg.sh
./Scripts/build_dmg.sh
```

The app and DMG are created in `dist/`.

## Test

```bash
./Scripts/test.sh
```
