# DynamicNotch

DynamicNotch turns your Mac's notch into a status area, like the Dynamic Island on iPhone. Long builds, uploads and shell commands show their progress there, Claude Code sessions show whether they're working or need you (with Allow and Deny right in the notch), and the music that's playing and the volume are a hover away. You no longer have to keep switching windows to see whether something has finished.

On a Mac without a notch (or on an external display), it shows as a pill in the middle of the menu bar, only when there's something to show. Hover over the notch to open it.

## Download

**[⬇ Download DynamicNotch.dmg](https://github.com/smanke-org/DynamicNotch/releases/latest/download/DynamicNotch.dmg)**

1. Open the disk image and drag DynamicNotch to Applications.
2. Open DynamicNotch. It lives in the notch and the menu bar.
3. To use the `notch` command in Terminal, link it once:

```bash
ln -sf /Applications/DynamicNotch.app/Contents/MacOS/notch ~/.local/bin/notch
```

Requires macOS 14 or later.

## Live activities

```bash
notch start "Deploy" --progress 40% --detail "Uploading"
notch update deploy --progress 80%
notch done "Deploy"                      # or: notch fail "Deploy" --detail "502 from server"
notch done "Tests passed ✅"             # one-shot
notch run -- ffmpeg -i in.mov out.mp4    # wraps any command; reads %, [3/10], ffmpeg time= for progress
notch ci 123                             # watches PR #123's checks (needs `gh`)
notch list
```

**Every long shell command, automatically:** add this to `~/.zshrc`:

```bash
eval "$(notch shell-init zsh)"
```

Commands that run longer than `NOTCH_SHOW_AFTER` seconds (default 10) appear in the notch and go green or red when they finish. Interactive tools (vim, ssh, less, claude…) are skipped. Change the list with `NOTCH_IGNORE`.

## Claude Code

```bash
notch setup claude            # adds hooks to ~/.claude/settings.json (backs it up first)
notch setup claude --print    # just print the JSON
notch setup claude --remove   # undo
```

Sessions show as Working / Needs you / Idle. When Claude asks for a permission, the notch opens with **Allow / Deny / Answer in terminal**. If you don't answer within `NOTCH_APPROVAL_TIMEOUT` seconds (default 120), or DynamicNotch isn't running, Claude Code shows its normal prompt.

## Music & volume

Music and Spotify are shown through their track-change broadcasts. Play/pause/skip use AppleScript, so macOS asks once per player. Other sources, like browsers, aren't covered: Apple locked the system Now Playing API to its own apps in macOS 15.4. The volume slider controls the current output device and follows the keyboard volume keys.

## Features

- **Two ways to open:** in Settings › Notch, choose **Grow** (the notch stretches open with a little bounce, the album art slides into place and each row comes into focus in turn) or **Fade** (the open notch fades in at full size). With Reduce Motion on, it always fades.
- **Events you can see:** the edge glows orange when something needs you, the notch shakes when an activity fails, and a green ripple spreads from the check mark when one succeeds. The open notch has a faint outline so it stands out on dark wallpaper.
- **Every display, or just one:** show the notch on the built-in display only, or on every display (as a pill in the middle of the menu bar where there's no notch).
- Right-click or ⌘-click the notch to open Settings.
- Can be driven from a URL, for ToolHUD, Shortcuts or scripts: `dynamicnotch://show`, `clear` and `settings`.
- Built-in Help (⌘? or the ? in Settings) covers every feature and command.
- System, Light or Dark appearance for its windows, whatever the Mac uses.
- Optional iCloud sync keeps settings the same on every Mac signed in to your iCloud account (through iCloud Drive; turn it on in Settings › General).
- Shows in the menu bar, the Dock, both, or neither, and folds its menu into ToolHUD's while ToolHUD runs. Can open at login.

## Updates

DynamicNotch checks GitHub for updates once a day (or as often as you choose, from every hour to once a year) and either asks first (the default) or installs them itself. An automatic update waits until nothing is running or waiting for you in the notch, no app is presenting, and your Mac hasn't been used for 2 minutes. Every download must be signed by the same developer and notarized by Apple before it's installed.

## How it fits together

- `Sources/DynamicNotch`: the menu-bar app. A transparent panel over the notch (`NotchWindow.swift`), SwiftUI views (`Views.swift`), state (`HubStore.swift`), and a Unix socket server at `~/Library/Application Support/DynamicNotch/hub.sock`.
- `Sources/notch`: the CLI. Each command sends one JSON line over the socket and reads one reply. Permission requests keep the connection open until you decide.
- `Sources/NotchKit`: the shared message types and socket client.

Activities tied to a process (`--pid`, `notch run`, shell hooks, Claude sessions) disappear on their own if that process dies.

## Building

```bash
./build.sh             # signed ad hoc, for building from source: build/DynamicNotch.app
./build.sh --install   # also copies to ~/Applications, links ~/.local/bin/notch, launches it
./build_app.sh         # universal binary, Developer ID signed (for releases)
./install.sh           # copies that build to /Applications in place, links notch, launches it
./release.sh 0.1.1     # build, notarize, disk image, GitHub release
```

If Xcode's license hasn't been accepted, `build.sh` falls back to the Command Line Tools. A copy built with `build.sh` can't update itself, since updates must match the signature of the copy that's running.

## License

© 2026 Steve Manke. All rights reserved.
