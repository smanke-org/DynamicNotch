# DynamicNotch

A Dynamic Island for your Mac's notch: live activities from any script, Claude Code sessions (with approve/deny right in the notch), now playing, and volume.

On a Mac without a notch (or an external display), it shows as a pill in the middle of the menu bar, only when there's something to show. Hover over the notch to expand it.

## Install

**From a release:** download `DynamicNotch-x.y.z.zip` from [Releases](https://github.com/smanke-org/DynamicNotch/releases), unzip it, and move `DynamicNotch.app` to Applications. The app isn't notarized, so macOS will block the first launch. Clear the download flag once:

```bash
xattr -dr com.apple.quarantine /Applications/DynamicNotch.app
```

To get the `notch` command:

```bash
ln -sf /Applications/DynamicNotch.app/Contents/MacOS/notch ~/.local/bin/notch
```

**From source:**

```bash
./build.sh               # builds build/DynamicNotch.app
./build.sh --install     # copies to ~/Applications, links ~/.local/bin/notch, launches it
./build.sh --universal   # Apple Silicon + Intel build, zipped for a release (needs Xcode)
```

Needs macOS 14+. If Xcode's license hasn't been accepted, the build falls back to the Command Line Tools.

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

## How it fits together

- `Sources/DynamicNotch`: the menu-bar app. A transparent panel over the notch (`NotchWindow.swift`), SwiftUI views (`Views.swift`), state (`HubStore.swift`), and a Unix socket server at `~/Library/Application Support/DynamicNotch/hub.sock`.
- `Sources/notch`: the CLI. Each command sends one JSON line over the socket and reads one reply. Permission requests keep the connection open until you decide.
- `Sources/NotchKit`: the shared message types and socket client.

Activities tied to a process (`--pid`, `notch run`, shell hooks, Claude sessions) disappear on their own if that process dies.
