# yobirin

_yobirin_ (呼び鈴, "call bell") is a macOS notification CLI that rings and waits for your response.

It posts a single notification, synchronously waits for the user's reaction (click, dismiss, action button, text reply, or timeout), prints the result as JSON to stdout, and exits. This makes notification interactions scriptable from shell scripts and tool hooks.

[日本語版 README はこちら](README.ja.md)

```console
$ yobirin --title "Deploy" --message "Approve the release?" --action "Approve" --action "Reject" --timeout 60
{"result":"action","action":"Approve","actionIndex":0}
```

## Why

Existing macOS notification CLIs either cannot capture interactions at all (terminal-notifier is fire-and-forget), or are built on the deprecated `NSUserNotification` API and detect dismissal by polling, which leaks memory while a notification sits unattended (alerter).

yobirin uses the current `UserNotifications` framework only. Dismissal is detected through a delegate callback (`customDismissAction`), so there is no polling loop, no busy CPU, and no memory growth while waiting. Notifications are posted under yobirin's own identity; it does not impersonate other apps.

## Requirements

- macOS (universal binary: Apple Silicon and Intel)
- Xcode Command Line Tools (to build from source)

## Install

### From a release binary (no toolchain required)

Download the prebuilt universal binary and let it install itself (requires the [gh CLI](https://cli.github.com/) while the repository is private):

```console
$ gh release download --repo mjun0812/yobirin --pattern yobirin-universal
$ chmod +x yobirin-universal
$ ./yobirin-universal install
```

The binary copies itself into an ad-hoc signed `Yobirin.app`, places it into `~/Applications`, and symlinks the command into `~/.local/bin/yobirin` (make sure `~/.local/bin` is on your `PATH`, or set `YOBIRIN_BIN_DIR` to another directory). The downloaded file can be deleted afterwards.

### From source

```console
$ git clone https://github.com/mjun0812/yobirin.git
$ cd yobirin
$ swift build -c release
$ .build/release/yobirin install
```

Re-running `yobirin install` upgrades in place. The old bundle is removed before the new one is installed, so only one copy is ever registered with macOS.

## Notification permission

On first run, macOS shows a permission dialog for "Yobirin". Click **Allow**.

- The dialog only appears when the app bundle lives in a proper location such as `~/Applications`. The installer takes care of this.
- While the dialog is open, `--timeout` does not advance. The timer starts only after permission is resolved.
- If permission is denied (or later disabled), yobirin prints the reason to stderr and exits with code `2`, without emitting JSON. Re-enable it under System Settings > Notifications > Yobirin.

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

`--timeout` accepts a positive number of seconds. When omitted, yobirin waits indefinitely for a response; when calling from hooks or automation, always pass an explicit timeout.

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
- `action` / `actionIndex`: label and zero-based index of the pressed action button (index disambiguates duplicate labels)
- `text`: the text entered through the reply field

Exit codes:

| Code           | Meaning                                                        | stdout                  |
| -------------- | -------------------------------------------------------------- | ----------------------- |
| 0              | A user response or timeout was captured                        | result JSON             |
| 2              | Notification permission not granted                            | none (reason on stderr) |
| other non-zero | Environment error (invalid arguments, attachment failure, ...) | none                    |

A typical script branches on `jq -r '.result'`:

```bash
result=$(yobirin --title "Build finished" --message "Open the log?" --timeout 300)
case "$(echo "$result" | jq -r '.result')" in
  clicked) open build.log ;;
  timeout|dismissed) ;;
esac
```

On timeout, the delivered notification is removed from Notification Center before yobirin exits, so no stale notification is left behind. Launching `yobirin` with no arguments quietly sweeps orphaned notifications (left over after a force-killed process) and exits.

`yobirin ps` lists the processes still waiting for a notification result — useful for spotting forgotten notifications launched without `--timeout`. Add `--json` for machine-readable output:

```console
$ yobirin ps
PID    PROFILE    TITLE   TIMEOUT  ELAPSED
4211   (default)  Deploy  300      42s
4300   claude     Done    -        12m30s
```

## Icon profiles

The notification icon is fixed to the app bundle's icon (a macOS restriction; there is no per-notification icon option). To use different icons per purpose, install derivative bundles that differ only in icon and bundle ID:

```console
$ yobirin install --profile claude --icon assets/icon/claude.png
$ yobirin --profile claude --title "Claude" --message "Done"
```

This installs `Yobirin-Claude.app` (bundle ID `com.mjun0812.yobirin.claude`) with the given icon. On the notify side, `--profile <name>` dispatches execution to that bundle, so `PATH` keeps a single `yobirin` command no matter how many profiles you add. Each profile asks for notification permission on its own first run and appears as a separate entry in System Settings, so each can be toggled independently.

Profile names must match `^[a-z0-9]+$`. Omitting `--icon` installs the bundled default bell icon.

`yobirin list` shows every installed bundle (the default plus all profiles) with its bundle ID, version, and path; add `--json` for machine-readable output:

```console
$ yobirin list
PROFILE    BUNDLE ID                    VERSION  PATH
(default)  com.mjun0812.yobirin         0.3.0    /Users/you/Applications/Yobirin.app
claude     com.mjun0812.yobirin.claude  0.3.0    /Users/you/Applications/Yobirin-Claude.app
```

## Known limitations

- `--image`: the attachment is accepted and stored by macOS, but current macOS versions do not render the thumbnail in banners or Notification Center.
- Notification banners composite transparent areas of the app icon over white. Design icons with an opaque rounded-tile background (leaving only the corners outside the tile transparent), the same way other macOS apps do.
- Replacing the app icon of an already-installed bundle takes effect in notification banners only after logging out and back in (macOS caches notification source icons aggressively). Installing under a new bundle ID (a new profile name) shows the new icon immediately.
- macOS only. There are no plans for Linux or Windows support.

## Uninstall

```console
$ rm -rf ~/Applications/Yobirin*.app
$ rm -f ~/.local/bin/yobirin*
```

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

- [vjeantet/alerter](https://github.com/vjeantet/alerter): the interactive notification CLI that inspired yobirin's design. Its memory leak under long-lived notifications (polling-based dismissal detection on the deprecated `NSUserNotification` API) is what motivated this rewrite.
- [julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier): the classic macOS notification CLI that alerter was forked from.
- [777genius/claude-notifications-go / swift-notifier](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier): the reference for assembling a signed `.app` bundle from a Swift Package without an Xcode project.
- [IBM/mac-ibm-notifications](https://github.com/IBM/mac-ibm-notifications): an actively maintained Swift + `UserNotifications` implementation consulted during design.
- [Apple: UserNotifications framework](https://developer.apple.com/documentation/usernotifications): the notification API yobirin is built on.
