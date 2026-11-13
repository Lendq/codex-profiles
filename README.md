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

Select **Claude Code** to manage accounts using the same cards and profile editor as Codex. The current login appears by email. Save it with the plus button, or choose **Sign In New Profile** and follow the prompts in Terminal. Once signed in, exit Claude Code to finish saving the account. The arrow on a saved card selects that account for subsequent normal Claude Code launches.

Claude Code processes can cache and refresh their login. Close all Claude Code sessions before adding, switching, or removing Claude profiles; the app checks this to protect stored logins. A conversation can then be resumed in the usual Claude Code session. Existing profiles created by this fork's earlier launcher are preserved and imported when selected.

The active `~/.claude` configuration, project history, and MCP server definitions remain shared. The switcher also preserves the active MCP OAuth sign-ins where present. Usage limits refresh in the background and can also be refreshed with the toolbar button; the app sends the account's access token only to Anthropic's usage endpoint. Expired logins may require another sign-in, and an MCP server may require authorization again.

The app uses the MIT-licensed [ccswitch](https://github.com/2hmad/ccswitch) switching helper (based on commit `d303f8f`, modified for locking, rollback and local sign-out), bundled under `Vendor/ccswitch`. Python 3 must be available on the Mac. macOS's active Claude login is kept in Keychain. Saved Claude account credential snapshots and MCP sign-ins are held in owner-only files under `~/.config/codex-profiles-claude`; protect that folder like a password. Do not copy a saved login to multiple machines: rotating refresh tokens can invalidate another copy. ccswitch's macOS support is marked experimental upstream.

Claude profiles can be exported and imported individually. Export files contain login credentials: keep them private, and do not use the same login on multiple machines because refresh-token rotation can invalidate a copy. Automatic session renewal is not yet implemented. Claude does not change the account of a running process during a switch.

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
