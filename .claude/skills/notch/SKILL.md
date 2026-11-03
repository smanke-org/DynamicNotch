---
name: notch
description: Drive DynamicNotch, the app that turns this Mac's notch into a status area, from the shell with the `notch` command: see what the notch shows (live activities, Claude Code sessions, music, volume), show a notice or a live activity with progress, update or clear activities, open the notch, and read or change its settings. Use when the user asks to show something in the notch, report progress there, check what it shows, change its settings, or names DynamicNotch.
---

# DynamicNotch

`notch` runs commands in the DynamicNotch app. Changes show in the notch at once. If the app is
closed, the command opens it in the background. If `notch` isn't on PATH, use
`/Applications/DynamicNotch.app/Contents/MacOS/DynamicNotch` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- Find activity ids with `notch activities list --json`. An id is the title in lowercase with
  dashes unless one was given with `--id`.
- A notice or activity appears on the person's screen. Show one only when they asked, or to
  report a long job they're waiting on, and finish what you start (`--state success|failure`).
- `sessions list` shows Claude Code's waiting permission questions. Never try to answer them:
  only the person can, in the notch.
- `settings set` changes the person's settings (and syncs them to their other Macs when sync is
  on). Only change what they asked for.
- To try something without the real app, run a Debug build with `APP_STORE=/tmp/notch-test` in
  front: a test copy with its own settings and nothing on screen.

## Main commands

| Command | Does |
| --- | --- |
| `notch status --json` | Activities, Claude Code sessions, waiting permissions, music, volume |
| `notch notice show "<title>" [--detail T] [--failed] --json` | A one-off notice: green check, or red cross and shake |
| `notch activities start "<title>" [--progress 40%] [--detail T] --json` | A running activity with progress |
| `notch activities update <id> [--progress P] [--detail T] [--state success] --json` | Move it on, or finish it |
| `notch activities list --json` / `notch activities clear --json` | See them / remove the finished ones |
| `notch settings show --json` / `notch settings set --animation fade --json` | Read / change settings |

Everything else: `notch help`, and `notch help <command>` for its options. Script-style
activity commands (`notch start`, `notch done`, `notch run -- <cmd>`) work too.
