# Codex Limits

A native Apple Silicon menu bar monitor for **multiple independent ChatGPT users**, with optional **Command Code** usage tracking. Add Codex accounts as needed; there is no two-account limit. AppKit, Swift, Foundation, and Network.framework only. No WebView, Node runtime, analytics, backend, or persistent Codex helper.

## Install

Build from source with `./build.sh`, or create a compressed disk image with `./build-dmg.sh`. The DMG is written to `dist/Codex-Limits-<version>-arm64.dmg`; open it and drag **Codex Limits** onto **Applications**. Generated bundles and disk images are excluded from Git.

The built app is **[`dist/Codex Limits.app`](dist/)**. Copy it to `/Applications` or `~/Applications`, then double-click it. The Dock icon is hidden. Click the menu bar item to open the popover, then use **Settings…** in its fixed header. **⌘,** also opens Settings while Codex Limits is active. Quit from Settings or the app menu.

Requirements:

- Apple Silicon, macOS 13 or newer.
- The [official Codex CLI](https://github.com/openai/codex#installation), authenticated with ChatGPT, not API keys. Integration was checked against **0.154.0**. Use this version or newer for banked-reset details; older servers may omit them.
- The **native CLI executable**. If installed with npm, Settings resolves the official launcher to its bundled native executable; the app does not run Node. CLI installation is separate from this app.
- Optional: the Command Code CLI (`npm i -g command-code`) signed in with `cmd login`. The app reads Command Code’s `auth.json` read-only. Its `/alpha` usage endpoints are the ones the CLI uses, not a documented public API; an incompatible response becomes an error instead of a fabricated meter.

The bundle is locally ad-hoc signed, not Developer ID signed or notarized. Local builds launch without full Xcode. If macOS blocks a downloaded/shared copy, inspect its source, build locally, or use the system’s Open Anyway action. Do not disable Gatekeeper globally.

## Connect Codex accounts

1. Open Settings. Set the native Codex executable if it was not discovered. You can choose the `codex` launcher; its native binary is resolved automatically. Use **⌘⇧G** in the chooser to reach hidden directories.
2. Keep the initial A/B dedicated homes, or choose **existing dedicated directories**. Names and paths are editable. Choose **Save & Refresh**, then wait for the refresh to finish.
3. Choose **Sign in…** for A. The official Codex app-server starts OAuth and opens the official sign-in URL in your browser. Select the first ChatGPT account. Completion is verified through `account/login/completed`, not inferred from the browser opening.
4. Repeat for each slot with a **different ChatGPT user**. Switch browser accounts during the official login if needed. Separate workspaces belonging to the same user do not qualify as independent users.
5. To connect more users, choose **Settings → + Add Account → Save & Refresh → Sign in…**. New slots get fresh dedicated directories. Settings and the popover scroll to accommodate additional accounts. Account labels continue A, B, C…Z, AA, AB…
6. The app checks returned emails and workspace/account IDs across **all** configured slots. A later duplicate slot shows a conflict with the earlier account rather than being presented as independently connected.

**Remove** stages removal until **Save & Refresh**. It stops monitoring that slot but does **not** delete its home, credentials, or local attempt journals, and does not log it out. You may remove all slots and add new ones later. A reused slot label receives a new directory instead of reusing removed credentials.

Default homes:

```text
~/Library/Application Support/Codex Limits/Accounts/A
~/Library/Application Support/Codex Limits/Accounts/B
```

New slots use `~/Library/Application Support/Codex Limits/Accounts/<slot>-<UUID>` so each new credential lifecycle starts independently.

**A home must not be used by another Codex client.** `~/.codex` and symlink aliases of it are rejected. Other existing directories require confirmation that they belong exclusively to this utility. The app cannot prove whether an arbitrary external client has been configured to use your chosen directory. Stop that client or use a fresh home and a separate official login. Never copy `auth.json`, duplicate refresh tokens, or point multiple slots at the same directory.

The app never copies, parses, logs, or manages Codex OAuth credentials itself. Codex owns credential storage/refresh, including its configured Keychain storage. Newly created directories use mode 0700; settings use mode 0600. Signing in can replace an existing login **only after you confirm**. Account errors stop automatic retries until you sign in again or explicitly refresh. A five-minute interval is the default; Settings supports 1–60 minutes. Launch at login uses macOS `SMAppService`; move the bundle to its permanent location first.

## Command Code (optional)

Codex Limits can also show a Command Code plan: monthly credits, rolling 5-hour and weekly usage, reset times, extra credits, and renewal. It uses the login the Command Code CLI already created, so there is no second sign-in:

1. Install and sign in with the official CLI: `npm i -g command-code`, then `cmd login`.
2. Open **Settings → Command Code**. Keep `~/.commandcode/auth.json` or choose another file, enable **Monitor Command Code**, then **Save & Refresh**.
3. `COMMAND_CODE_API_KEY` in the app’s launch environment takes precedence over `auth.json`.

Only one Command Code login is tracked because the CLI stores one credential set. A missing or rejected login shows **Not connected** or **Needs attention** with a recovery message. The card labels a pay-as-you-go account with **no 5-hour or weekly caps** instead of drawing 0%. Extra pay-as-you-go credits are shown separately and never treated as a usage cap.

The app loads the API key into memory for read-only requests. It never writes `auth.json`, never copies or logs the key, and never calls Command Code model endpoints. Command Code’s `/alpha/whoami`, `/alpha/billing/credits`, `/alpha/billing/subscriptions`, and `/alpha/usage/summary` endpoints are internal CLI endpoints rather than a documented public API; they may change. Missing fields show unavailable, not zero.

## What is shown

- Menu bar: **remaining five-hour allowance**, for the first three Codex slots plus `+N` for additional accounts, followed by `CC:` for Command Code when enabled. All accounts appear in the popover. An em dash means unavailable/not applicable; `!` means an error or stale data. Plans without a five-hour limit do not get a fabricated percentage.
- Popover: real five-hour and weekly windows, selected by the server’s duration, not assumed primary/secondary ordering. Percentages are `100 − usedPercent`, clamped to 0–100. Codex rounds its reported usage, so these are server-reported estimates, not sub-percent measurements.
- Command Code: the card shows remaining monthly credits, 5-hour and weekly caps, reset countdowns, renewal, and extra credits. `windowLimits` values are server-reported credit amounts, not request counts; the app converts them to remaining percentages. A pay-as-you-go account without caps falls back to monthly remaining without inventing a window.
- Window dates use server Unix timestamps and your local timezone. Expired timestamps say **awaiting server update**; the app never locally refills a meter. Countdown text is updated once per minute **only while the popover is open**.
- Banked resets: separate compact, expandable lists, sorted by expiration. Orange at ≤72 hours; red at <24 hours or expired. `expiresAt: null` explicitly means non-expiring. Missing/incomplete fields mean **unavailable**, not “no expiration.” A count-only or capped response shows how many details are unavailable. Ordinary credit balances are never interpreted as banked resets.
- **Apply a reset:** click its compact expiration row, review the account and expiry in the confirmation dialog, then choose **Apply Reset**. Cancel is the default action. The app rereads identity, workspace, and the exact reset before using the supported `account/rateLimitResetCredit/consume` method. A result dialog distinguishes applied, already applied, nothing eligible to reset, and no reset available; usage is reread afterward. Your weekly reset date may change. This does not purchase anything or run a model request.
- Reset buttons are disabled for expired resets, unverified identity, errors, offline state, or another active operation. Count-only reset data cannot be redeemed by guessing which credit to consume; use **Open Usage** instead.
- A request key is saved locally **before submission** in `reset-attempts.json` (mode 0600, no OAuth tokens). A timeout or lost response is reported as **unknown**, never success, and is not automatically retried. A later explicit confirmation for the same account/home/workspace/reset reuses its saved key, including after restart. A known `nothingToReset` or `noCredit` result ends that attempt; a later confirmation starts a new one. Background refresh and startup never consume resets.
- **Codex usage** opens [the official usage page](https://chatgpt.com/codex/settings/usage). It uses your browser’s current account; confirm or switch the browser account before redeeming there. There is no supported credential-free deep link that signs your browser into the selected local slot. **Command Code** opens [the Command Code usage page](https://commandcode.ai/usage).

Polling is sequential across Codex accounts to keep peak process-tree memory down. Each Codex account read starts a short-lived `codex app-server`, performs the official handshake, reads identity and usage, checks identity again, and closes it. Ordinary monitoring sends no model requests. Command Code is read over HTTPS with the existing CLI login and does not launch the Command Code agent. Reset redemption occurs only after explicit confirmation. No purchases are made. Background refresh works without an open popover. Sleep cancels running helpers, wake checks freshness, and offline polling is suspended through `NWPathMonitor`. Transient read errors have bounded 30/60/120-second recovery delays before ordinary polling resumes; authentication/configuration errors require user action. These retries never resend reset mutations. Raw server errors and stderr are not displayed or logged because they can contain sensitive information.

## Build and test

Only Apple Command Line Tools are required; full Xcode is not:

```sh
xcode-select --install  # only if the Command Line Tools are absent
cd /Users/aveaxii/desk/projects/CodexLimits
swift test
./build.sh
open "dist/Codex Limits.app"
```

`build.sh` builds arm64 Release, assembles the bundle with `LSUIElement = true`, ad-hoc signs it, and verifies the signature. The executable depends on Apple system frameworks and Swift’s system runtime. A Codex or Command Code installation is not bundled.

Tests cover account/home isolation, symlink aliases, locking, official snapshot decoding, bucket selection, percentage conversion, timezone/countdown formatting, banked-reset sorting/warnings, unavailable and malformed details, bounded retries, authentication failures, and settings persistence. Command Code tests cover subscription/credit decoding, plan mapping, window and monthly percentage derivation, missing fields, and settings migration. Reset tests cover cancellation without a request, exact-credit submission, identity/workspace changes, expiration during confirmation, uncertain outcomes, persisted idempotency keys, and known outcomes.

Read-only Codex CLI smoke test, with a **dedicated** home:

```sh
"dist/Codex Limits.app/Contents/MacOS/CodexLimits" --probe --home /absolute/path/to/dedicated/home
```

Read-only Command Code probe:

```sh
"dist/Codex Limits.app/Contents/MacOS/CodexLimits" --command-code-probe --auth "$HOME/.commandcode/auth.json"
```

Both perform no login or inference and print no identity or key. They return 1 when signed out or rejected, 2 for transient failures, and 0 for a decoded usage response.

## Verification and performance

**44 unit tests cover the current implementation**, including 32-slot persistence, non-adjacent duplicate-account detection, empty account lists, safe removal, and A/B migration. The release action/layout test passes with five disposable Codex slots plus the Command Code card. Checks cover nonzero popover width, account content, visible refresh, click-to-close, Settings, and adding a draft account. A captured popover and Command Code card were inspected to check controls are not clipped. Posted mouse-event tests passed during debugging but later failed to deliver clicks to the status-button action on this multi-display host; physical left-click behavior was not re-tested.

Manual redemption is tested without live account mutations or inference, against verified official interfaces. No real reset or model request was used in testing. The Command Code path was exercised against a rejected credential (401) and with decoder fixtures; a live authenticated Command Code response was not available in this environment. Multiple authenticated accounts, live Codex/Command Code reads, real banked-reset entries, browser login completion, sleep/wake, and launch-at-login still require interactive validation.

[PERFORMANCE.md](PERFORMANCE.md) records app-only and process-tree measurements. Closed-popover idle RSS was **39.25 MiB**, idle CPU **0.00%** at the measurement’s precision, and **zero idle child processes**. The <30 MB RSS target was **not reached**; authenticated refresh peaks have not been measured. Do not interpret signed-out startup figures as the cost of authenticated network polling.

To reproduce (quit the running copy first):

```sh
python3 tools/measure.py --seconds 60
python3 tools/measure.py --seconds 30 --popover
```

Python is used only by this optional measurement tool, never by the app.

For a credential-free action/layout check, run `"dist/Codex Limits.app/Contents/MacOS/CodexLimits" --ui-smoke-test`. For the **real mouse-event path**, use `--ui-mouse-test` instead; event-posting permission must already be available to the test process. This permission is not needed for ordinary manual use. Both modes use disposable settings, disable polling, verify Codex account content, the Command Code card, and popover sizing, check show/refresh/close, and exercise Settings/Add Account without saving real configuration. No real account data or inference is accessed. `--ui-snapshot /absolute/path.png` captures the isolated popover; `--ui-command-code-snapshot /absolute/path.png` captures the Command Code card; `--ui-settings-snapshot /absolute/path.png` captures the Settings window.

## Project

```text
Sources/CodexLimits/  AppKit lifecycle, menu bar, popover, settings, polling
Sources/LimitsCore/  Codex protocol, Command Code client, isolation, settings
Tests/               Fixtures and unit tests
tools/measure.py     Optional process-tree performance measurement
build.sh             Release .app builder
```
