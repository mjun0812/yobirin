<p align="center">
  <img src="assets/icon/AppIcon.png" width="160" alt="yobirin icon (a Shinto shrine bell)" />
</p>

<h1 align="center">yobirin</h1>

<p align="center"><b>yobirin</b> (呼び鈴, "call bell") is a macOS notification CLI that rings and waits for your response.</p>

<p align="center">
  <a href="https://github.com/mjun0812/yobirin/actions/workflows/ci.yml"><img src="https://github.com/mjun0812/yobirin/actions/workflows/ci.yml/badge.svg" alt="CI" height="20" /></a>
  <img src="https://shieldcn.dev/badge/platform-macOS-gray.svg?size=xs" alt="Platform: macOS" height="20" />
  <img src="https://shieldcn.dev/badge/Swift-6.0-orange.svg?size=xs" alt="Swift 6.0" height="20" />
  <a href="LICENSE"><img src="https://shieldcn.dev/badge/license-MIT-blue.svg?size=xs" alt="License: MIT" height="20" /></a>
</p>

<p align="center"><a href="README.ja.md">日本語版 README はこちら</a></p>

yobirin is a CLI that delivers a macOS notification, waits for the user's reaction (click, dismiss, action button, text reply, or timeout), and prints the result as JSON. Shell scripts and tool hooks can branch on how the notification was answered.

```console
$ yobirin --title "Deploy" --message "Approve the release?" --action "Approve" --action "Reject" --timeout 60
{"result":"action","action":"Approve","actionIndex":0}
```

## Features

- **Response capture**: distinguishes click, dismiss, action selection, text reply, and timeout, and returns each as JSON
- **Low resource usage**: no polling; it waits on `UserNotifications` framework delegate callbacks only, so an unattended notification costs no CPU and no memory
- **Easy installation**: a single release binary and `yobirin install` is all it takes; no build toolchain required
- **Flexible notification identities**: switch profiles to deliver notifications under different icons and names
- **Visible state**: `yobirin list` shows the installed profiles, and `yobirin ps` shows the processes waiting for a response

## Usecase

### Act on a completion notification

Announce that a long build or test run finished, and open the log when clicked. If the notification is ignored or dismissed, nothing happens:

```bash
result=$(yobirin --title "Build finished" --message "Open the log?" --timeout 300)
case "$(echo "$result" | jq -r '.result')" in
  clicked) open build.log ;;
esac
```

### Ask for approval before running

Confirm with action buttons, and proceed only when approved:

```bash
answer=$(yobirin --title "Deploy" --message "Release to production?" \
  --action "Approve" --action "Reject" --timeout 600)
if [ "$(echo "$answer" | jq -r '.action')" = "Approve" ]; then
  ./deploy.sh production
fi
```

### Receive instructions from a coding agent hook

Wire it into the notification hook of Claude Code or Codex, and you can reply to the completion notification to send the next instruction:

```bash
reply=$(yobirin --profile claude --title "Claude Code" \
  --message "Task finished. Reply with the next instruction if any" \
  --reply --timeout 300)
text=$(echo "$reply" | jq -r 'select(.result == "replied") | .text')
[ -n "$text" ] && echo "$text" >> next-instructions.txt
```

### Offer a chance to cancel before proceeding

Use the timeout as "run unless someone objects". If you are at your desk you can stop it; if not, it proceeds as scheduled:

```bash
result=$(yobirin --title "Maintenance" --message "Backup starts in 5 minutes" \
  --action "Start now" --action "Cancel" --timeout 300)
case "$(echo "$result" | jq -r '.action // .result')" in
  Cancel) exit 0 ;;
  *) ./backup.sh ;;   # both timeout and "Start now" proceed
esac
```

## Requirements

- macOS (Apple Silicon / Intel)
- Xcode Command Line Tools (only when building from source)

## Install

### From a release binary (no toolchain required)

Download the prebuilt binary and let it install itself:

```console
$ gh release download --repo mjun0812/yobirin --pattern yobirin
$ chmod +x yobirin
$ ./yobirin install
```

Running `install` makes the binary copy itself into an ad-hoc signed `Yobirin.app`, place it into `~/Applications`, and symlink the command to `~/.local/bin/yobirin`. Make sure `~/.local/bin` is on your `PATH` (the directory can be changed with `YOBIRIN_BIN_DIR`). The downloaded file can be deleted once installation is done.

### From source

```console
$ git clone https://github.com/mjun0812/yobirin.git
$ cd yobirin
$ swift build -c release
$ .build/release/yobirin install
```

Upgrading is just re-running `yobirin install`. The old bundle is removed before the new one is placed, so only one copy is ever registered with macOS.

## Notification permission

On first run, macOS shows a permission dialog for "Yobirin". Click **Allow**.

- The dialog only appears when the bundle lives in a proper location such as `~/Applications`. The installer places it there, so you normally don't need to think about this
- While the dialog is open, `--timeout` does not advance. The timer starts only after permission is resolved
- If permission is denied (including turning it off later), yobirin prints the reason to stderr and exits with code `2`, without emitting JSON. Re-enable it under System Settings > Notifications > Yobirin

## Usage

```
yobirin --title <string> --message <string>
        [--subtitle <string>]
        [--group <id>]                 # replace an existing notification with the same group
        [--timeout <seconds>]          # wait forever when omitted
        [--action <label>]...          # repeatable; two or more become a dropdown
        [--reply]                      # add a text input action
        [--reply-placeholder <string>] # placeholder for the reply field (requires --reply)
        [--sound default|<name>]
        [--image <path>]               # attach an image (see known limitations)
```

`--timeout` accepts a positive number of seconds. When omitted, yobirin waits indefinitely for a response, so always pass it when calling from hooks or automation.

### Output

One JSON object is printed to stdout when the result is determined:

```json
{"result":"clicked"}
{"result":"action","action":"Approve","actionIndex":0}
{"result":"replied","text":"typed text"}
{"result":"dismissed"}
{"result":"timeout"}
```

- `result`: one of `clicked`, `action`, `replied`, `dismissed`, `timeout`
- `action` / `actionIndex`: label and zero-based index of the pressed action button (the index disambiguates duplicate labels)
- `text`: the text entered through the reply field

Exit codes:

| Code           | Meaning                                                        | stdout                  |
| -------------- | -------------------------------------------------------------- | ----------------------- |
| 0              | A user response or timeout was captured                        | result JSON             |
| 2              | Notification permission not granted                            | none (reason on stderr) |
| other non-zero | Environment error (invalid arguments, attachment failure, ...) | none                    |

A timed-out notification is removed from Notification Center before yobirin exits, so it never lingers unanswered. If a notification is left behind by a force-killed process, launching `yobirin` with no arguments sweeps it away.

### Listing waiting processes

`yobirin ps` shows what is currently waiting for a response. It is handy for spotting notifications launched without `--timeout` and forgotten:

```console
$ yobirin ps
PID    PROFILE    TITLE   TIMEOUT  ELAPSED
4211   (default)  Deploy  300      42s
4300   claude     Done    -        12m30s
```

Add `--json` for machine-readable output.

## Icon profiles

The notification icon is fixed to the icon of the app bundle that delivers it. This is a macOS restriction; there is no way to specify an icon per notification. yobirin works around it by installing derivative bundles that differ only in icon and bundle ID:

```console
$ yobirin install --profile claude --icon assets/icon/claude.png
$ yobirin --profile claude --title "Claude" --message "Done"
```

The first line installs `Yobirin-Claude.app` (bundle ID `com.mjun0812.yobirin.claude`) with the given icon; from then on, adding `--profile <name>` delivers notifications under that bundle's name and icon. Execution is dispatched to the target bundle, so `PATH` keeps a single `yobirin` command no matter how many profiles you add. Each profile asks for notification permission independently on its first run and appears as a separate entry in System Settings, so each can be toggled on and off individually.

Profile names may contain lowercase letters and digits only (`^[a-z0-9]+$`). Omitting `--icon` uses the bundled default bell icon.

Installed bundles can be listed with `yobirin list` (`--json` supported):

```console
$ yobirin list
PROFILE    BUNDLE ID                    VERSION  PATH
(default)  com.mjun0812.yobirin         0.4.1    /Users/you/Applications/Yobirin.app
claude     com.mjun0812.yobirin.claude  0.4.1    /Users/you/Applications/Yobirin-Claude.app
```

## Known limitations

- `--image`: the attachment is accepted and stored by macOS, but current macOS versions do not render the thumbnail in banners or Notification Center
- Notification banners composite transparent areas of the app icon over white. Like other macOS apps, design icons with an opaque rounded-tile background, leaving only the corners outside the tile transparent
- Replacing the icon of an already-installed bundle takes effect in notification banners only after you log out and back in (macOS caches notification source icons aggressively). To see a new icon immediately, install under a new profile name. When a reinstall changes the icon, the CLI prints this guidance on the spot
- macOS only. There are no plans to support Linux or Windows

## Uninstall

```console
$ rm -rf ~/Applications/Yobirin*.app
$ rm -f ~/.local/bin/yobirin*
```

## How it works

yobirin is, at its core, a single CLI binary. However, the current macOS notification API (the `UserNotifications` framework) only lets registered `.app` bundles deliver notifications; calling it from a bare binary does not work. The legacy `NSUserNotification` API had no such restriction, but it is deprecated and requires polling to detect dismissal, which is a breeding ground for memory leaks, so yobirin does not use it.

Instead, `yobirin install` makes the running binary copy itself into an assembled `Yobirin.app`, sign it ad-hoc, place it into `~/Applications`, and create the `yobirin` command on `PATH` as a symlink to the executable inside:

```text
~/.local/bin/yobirin  →  ~/Applications/Yobirin.app/Contents/MacOS/yobirin  (symlink)
```

In other words, the CLI you invoke is the very binary inside the app. It behaves as an app only while delivering a notification and waiting for the response (it never appears in the Dock), and exits once the result is determined. Nothing stays resident. `install`, `list`, and `ps` run as plain CLI commands that never touch the notification API.

Icon profiles are an application of the same mechanism: the same binary is copied as a separate app (`Yobirin-Claude.app`, etc.) that differs only in icon and bundle ID, and `--profile` hands execution over to the binary inside that bundle. From macOS's point of view each profile is an independent app, so permissions, icons, and identities are all managed separately.

## Development

```console
$ mise install            # install dev tools pinned in mise.toml (prek, shfmt, shellcheck, oxfmt)
$ prek install            # enable pre-commit hooks (swift format / shfmt / shellcheck / oxfmt)
$ swift test              # unit and integration tests (mocked notification center)
$ swift build -c release && .build/release/yobirin install   # build and install locally
```

Dev tools are managed with [mise](https://mise.jdx.dev/). CI (GitHub Actions) runs build, tests, and lint checks (swift format / oxfmt) on every push to `main` and on pull requests, installing the same tool versions via `mise.toml`.

Notification display, interaction, and the permission flow are GUI-dependent and cannot be covered by automated tests; see `.kiro/specs/yobirin-cli/` for the spec and the manual verification checklist. Design rationale and the field measurements behind the architecture live in `docs/design-research.md` (Japanese).

## License

[MIT](LICENSE)

## References

- [vjeantet/alerter](https://github.com/vjeantet/alerter): the interactive notification CLI that inspired yobirin's design; its memory leak motivated this project
- [julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier): the classic macOS notification CLI that alerter was forked from
- [777genius/claude-notifications-go / swift-notifier](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier): the reference for assembling a signed `.app` bundle from a Swift Package without an Xcode project
- [IBM/mac-ibm-notifications](https://github.com/IBM/mac-ibm-notifications): an actively maintained Swift + `UserNotifications` implementation consulted during design
- [Apple: UserNotifications framework](https://developer.apple.com/documentation/usernotifications): the notification API yobirin is built on
