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

```console
$ git clone https://github.com/mjun0812/yobirin.git
$ cd yobirin
$ bash scripts/install.sh
```

The installer builds a universal binary, assembles an ad-hoc signed `Yobirin.app`, places it into `~/Applications`, and symlinks the command into `~/.local/bin/yobirin` (make sure `~/.local/bin` is on your `PATH`, or set `YOBIRIN_BIN_DIR` to another directory).

To skip compilation, download the prebuilt universal binary from a release instead (requires the [gh CLI](https://cli.github.com/) while the repository is private):

```console
$ YOBIRIN_FROM_RELEASE=1 bash scripts/install.sh
```

Only the Mach-O binary comes from the release; the bundle, icon, and ad-hoc signature are still produced locally, so custom icons and profiles keep working. Set `YOBIRIN_RELEASE_TAG=v0.1.0` to pin a specific release.

Re-running the installer upgrades in place. The old bundle is removed before the new one is installed, so only one copy is ever registered with macOS.

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

## Icon profiles

The notification icon is fixed to the app bundle's icon (a macOS restriction; there is no per-notification icon option). To use different icons per purpose, install derivative bundles that differ only in icon and bundle ID:

```console
$ bash scripts/install.sh claude codex
```

This installs `Yobirin-Claude.app` and `Yobirin-Codex.app` with icons taken from `assets/icon/<name>.png`, and creates the commands `yobirin-claude` and `yobirin-codex`. Each profile asks for notification permission on its own first run and appears as a separate entry in System Settings, so each can be toggled independently.

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
$ bash scripts/build-app.sh [profile]   # build the signed .app bundle
```

Dev tools are managed with [mise](https://mise.jdx.dev/). CI (GitHub Actions) runs build, tests, and lint checks (swift format / shellcheck / shfmt / oxfmt) on every push to `main` and on pull requests, installing the same tool versions via `mise.toml`.

Notification display, interaction, and the permission flow are GUI-dependent and cannot be covered by automated tests; see `.kiro/specs/yobirin-cli/` for the spec and the manual verification checklist. Design rationale and the field measurements behind the architecture live in `docs/design-research.md` (Japanese).

## License

[MIT](LICENSE)

## References

- [vjeantet/alerter](https://github.com/vjeantet/alerter): the interactive notification CLI that inspired yobirin's design. Its memory leak under long-lived notifications (polling-based dismissal detection on the deprecated `NSUserNotification` API) is what motivated this rewrite.
- [julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier): the classic macOS notification CLI that alerter was forked from.
- [777genius/claude-notifications-go / swift-notifier](https://github.com/777genius/claude-notifications-go/tree/main/swift-notifier): the reference for assembling a signed `.app` bundle from a Swift Package without an Xcode project.
- [IBM/mac-ibm-notifications](https://github.com/IBM/mac-ibm-notifications): an actively maintained Swift + `UserNotifications` implementation consulted during design.
- [Apple: UserNotifications framework](https://developer.apple.com/documentation/usernotifications): the notification API yobirin is built on.
