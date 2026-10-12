# Codex Limits

A native Apple Silicon menu bar monitor for **multiple independent ChatGPT users**. Add accounts as needed; there is no two-account limit. AppKit, Swift, Foundation, and Network.framework only. No WebView, Node runtime, analytics, backend, or persistent Codex helper.

## Install

Build from source with `./build.sh`, or create a compressed disk image with `./build-dmg.sh`. The DMG is written to `dist/Codex-Limits-<version>-arm64.dmg`; open it and drag **Codex Limits** onto **Applications**. Generated bundles and disk images are excluded from Git.

The built app is **[`dist/Codex Limits.app`](dist/)**. Copy it to `/Applications` or `~/Applications`, then double-click it. The Dock icon is hidden. Click **◈ A: — · B: —** to open the popover, then use the labeled **Settings…** button in its fixed header (visible even while scrolling). **⌘,** also opens Settings while Codex Limits is active; right-clicking the menu bar item still opens Settings directly. Quit from Settings or the app menu.

Requirements:

- Apple Silicon, macOS 13 or newer.
- The [official Codex CLI](https://github.com/openai/codex#installation), authenticated with ChatGPT, not API keys. Integration was checked against **0.154.0**. Use this version or newer for banked-reset details; older servers may omit them.
- The **native CLI executable**. If installed with npm, Settings resolves the official launcher to its bundled native executable; the app does not run Node. CLI installation is separate from this app.

The bundle is locally ad-hoc signed, not Developer ID signed or notarized. Local builds launch without full Xcode. If macOS blocks a downloaded/shared copy, inspect its source, build locally, or use the system’s Open Anyway action. Do not disable Gatekeeper globally.

## Connect the accounts

1. Open Settings. Set the native Codex executable if it was not discovered. You can choose the `codex` launcher; its native binary is resolved automatically. Use **⌘⇧G** in the chooser to reach hidden directories.
2. Keep the initial A/B dedicated homes, or choose **existing dedicated directories**. Names and paths are editable. Choose **Save & Refresh**, then wait for the refresh to finish.
3. Choose **Sign in…** for A. The official Codex app-server starts OAuth and opens the official sign-in URL in your browser. Select the first ChatGPT account. Completion is verified through `account/login/completed`, not inferred from the browser opening.
4. Repeat for each slot with a **different ChatGPT user**. Switch browser accounts during the official login if needed. Separate workspaces belonging to the same user do not qualify as independent users.
5. To connect more users, choose **Settings → + Add Account → Save & Refresh → Sign in…**. New slots get fresh dedicated directories and default to auto-start off. Settings and the popover scroll to accommodate additional accounts. Account labels continue A, B, C…Z, AA, AB…
6. The app checks returned emails and workspace/account IDs across **all** configured slots. A later duplicate slot shows a conflict with the earlier account rather than being presented as independently connected.

**Remove** stages removal until **Save & Refresh**. It stops monitoring that slot but does **not** delete its home, credentials, or local attempt journals, and does not log it out. You may remove all slots and add new ones later. A reused slot label receives a new directory instead of reusing removed credentials. Existing A/B settings load unchanged.

Default homes:

```text
~/Library/Application Support/Codex Limits/Accounts/A
~/Library/Application Support/Codex Limits/Accounts/B
```

New slots use `~/Library/Application Support/Codex Limits/Accounts/<slot>-<UUID>` so each new credential lifecycle starts independently.

**A home must not be used by another Codex client.** `~/.codex` and symlink aliases of it are rejected. Other existing directories require confirmation that they belong exclusively to this utility. The app cannot prove whether an arbitrary external client has been configured to use your chosen directory. Stop that client or use a fresh home and a separate official login. Never copy `auth.json`, duplicate refresh tokens, or point multiple slots at the same directory. You can keep using the same ChatGPT accounts in other applications with their own separately established credentials.

The app never copies, parses, logs, or manages OAuth credentials itself. Codex owns credential storage/refresh, including its configured Keychain storage. Newly created directories use mode 0700; settings use mode 0600. Signing in can replace an existing login **only after you confirm**. Account errors stop automatic retries until you sign in again or explicitly refresh. A five-minute interval is the default; Settings supports 1–60 minutes. Launch at login uses macOS `SMAppService`; move the bundle to its permanent location first.

## What is shown

- Menu bar: **remaining five-hour allowance**, for the first three slots plus `+N` for additional accounts. All accounts appear in the popover. An em dash means unavailable/not applicable; `!` means an error or stale data. Plans without a five-hour limit do not get a fabricated percentage.
- Popover: real five-hour and weekly windows, selected by the server’s duration, not assumed primary/secondary ordering. Percentages are `100 − usedPercent`, clamped to 0–100. Codex rounds its reported usage, so these are server-reported estimates, not sub-percent measurements.
- Window dates use server Unix timestamps and your local timezone. Expired timestamps say **awaiting server update**; the app never locally refills a meter. Countdown text is updated once per minute **only while the popover is open**.
- Banked resets: separate compact, expandable lists, sorted by expiration. Orange at ≤72 hours; red at <24 hours or expired. `expiresAt: null` explicitly means non-expiring. Missing/incomplete fields mean **unavailable**, not “no expiration.” A count-only or capped response shows how many details are unavailable. Ordinary credit balances are never interpreted as banked resets.
- **Apply a reset:** click its compact expiration row, review the account and expiry in the confirmation dialog, then choose **Apply Reset**. Cancel is the default action. The app rereads identity, workspace, and the exact reset before using the supported `account/rateLimitResetCredit/consume` method. A result dialog distinguishes applied, already applied, nothing eligible to reset, and no reset available; usage is reread afterward. Your weekly reset date may change. This does not purchase anything or run a model request.
- Reset buttons are disabled for expired resets, unverified identity, errors, offline state, or another active operation. Count-only reset data cannot be redeemed by guessing which credit to consume; use **Open Usage** instead.
- A request key is saved locally **before submission** in `reset-attempts.json` (mode 0600, no OAuth tokens). A timeout or lost response is reported as **unknown**, never success, and is not automatically retried. A later explicit confirmation for the same account/home/workspace/reset reuses its saved key, including after restart. A known `nothingToReset` or `noCredit` result ends that attempt; a later confirmation starts a new one. Background refresh and startup never consume resets.
- **Open Usage** still opens [the official usage page](https://chatgpt.com/codex/settings/usage). It uses your browser’s current account; confirm or switch the browser account before redeeming there. There is no supported credential-free deep link that signs your browser into the selected local slot.

Polling is sequential to keep peak process-tree memory down. Each account read starts a short-lived `codex app-server`, performs the official handshake, reads identity and usage, checks identity again, and closes it. Ordinary monitoring sends no model requests. Optional auto-start sends the minimal request described below; reset redemption occurs only after explicit confirmation. No purchases are made. Background refresh works without an open popover. Sleep cancels running helpers, wake checks freshness, and offline polling is suspended through `NWPathMonitor`. Transient read errors have bounded 30/60/120-second recovery delays before ordinary polling resumes; authentication/configuration errors require user action. These retries never resend reset mutations or auto-start attempts. Raw server errors and stderr are not displayed or logged because they can contain sensitive information.

## Auto-start: best-effort 100% trigger

Enable **Auto-start window** separately for each account in the popover or Settings. It defaults **off** for new accounts and when upgrading settings that lack this field. Its check interval is fixed at **10 minutes**, separate from the configurable usage polling interval. Enabling it performs an immediate initial check; sleep/offline state postpones checks rather than accumulating a catch-up queue.

The requested best-effort logic is:

1. Read real server data. Require 100% five-hour remaining (official `usedPercent == 0`), positive weekly allowance, `ordinaryUsageAllowed: true`, verified account/workspace identity, and server-reported **no paid-credit entitlement/balance**. Missing credit/permission data skips execution with an explanation.
2. If armed, **save the attempt before dispatch**, then send `ok` once using supported `codex exec`. Record confirmed completion or failed/unknown status, and reread usage. A crash or failed execution stays latched; it is not retried for the same continuous 100% reading.
3. At a later 10-minute check, a server reading **below 100%** re-arms that account. A later 100% triggers again—even if caused by a manual/global/banked reset. Repeated 100% readings, a changed reset timestamp alone, and off/on toggling do not re-arm.

The ledger is `auto-start.json` (mode 0600), keyed by canonical home, user, and workspace. It survives app restarts. Corruption blocks execution rather than resetting the latch. The immediate post-request refresh is **not** used to re-arm within the same check. Changes between checks can be missed; if usage never visibly drops below 100%, the next window/reset can be missed too. This is the chosen heuristic, not a guarantee of one initialization per natural window.

Execution uses a fresh disposable directory, `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, zero project-instruction bytes, official OpenAI provider/default service tier, approval policy `never`, read-only sandbox, and disabled shell/hooks/apps/plugins/agents/browser/computer/code-mode features. An outer macOS Seatbelt profile also blocks execution of shell/interpreter binaries and restricts writes to the dedicated Codex state/home and disposable scratch; Codex's additional read-only tool sandbox protects user files. Any unexpected tool event fails the warm-up. Completion requires a successful `turn.completed` event **and** exit status zero. A 90-second watchdog stops a hanging execution. Account/home authentication remains managed by Codex; ignoring custom home configuration can make non-default credential-store logins unavailable for this feature, in which case it reports failure.

No credits are bought, no card is charged by a purchase operation, and banked resets are never automatically redeemed. The app skips auto-start if it sees an existing paid-credit balance/entitlement. **There is still no atomic included-allowance-only guard**: credit/allowance state could change between the final read and inference. Without paid credits, exhausted allowance should fail instead of consuming them. Auto-start consumes a small amount of included usage. It is best effort under the relaxed requirement, not proof of an unused window. See [INTEGRATION.md](INTEGRATION.md).

## Build and test

Only Apple Command Line Tools are required; full Xcode is not:

```sh
xcode-select --install  # only if the Command Line Tools are absent
cd /Users/aveaxii/desk/projects/CodexLimits
swift test
./build.sh
open "dist/Codex Limits.app"
```

`build.sh` builds arm64 Release, assembles the bundle with `LSUIElement = true`, ad-hoc signs it, and verifies the signature. The executable depends on Apple system frameworks and Swift’s system runtime. A Codex installation is not bundled.

Tests cover account/home isolation, symlink aliases, locking, official snapshot decoding, bucket selection, percentage conversion, timezone/countdown formatting, banked-reset sorting/warnings, unavailable and malformed details, bounded retries, authentication failures, and settings persistence. Auto-start tests cover 100→99→100, restart/crash latching, ten-minute cadence, independent accounts, weekly/credit safety gates, corrupted state, tool rejection, and completion verification. The actual kernel sandbox is checked using only `codex --version` and a denied shell launch—no model request. Reset tests cover cancellation without a request, exact-credit submission, identity/workspace changes, expiration during confirmation, uncertain outcomes, persisted idempotency keys, and confirmed success followed by a failed refresh. All redemption tests use in-memory mocks; no real reset was consumed during development. Test fixtures never enter production UI.

Read-only CLI smoke test, with a **dedicated** home:

```sh
"dist/Codex Limits.app/Contents/MacOS/CodexLimits" --probe --home /absolute/path/to/dedicated/home
```

This performs no login/inference, prints no account identity, and returns 1 when signed out, 2 for transient failures, or 0 for a decoded authenticated snapshot.

## Verification and performance

**48 unit tests cover the current implementation**, including 32-slot persistence, non-adjacent duplicate-account detection, empty account lists, safe removal, and A/B migration. The release action/layout test passes with five disposable account slots. Checks cover nonzero popover width, account content, visible refresh, click-to-close, Settings, and adding a draft account. A captured popover image was inspected to check controls are not clipped. This found and fixed both an outside-click monitor bug and a zero-width fitting-size layout bug that the earlier action-only smoke test missed. Posted mouse-event tests passed during debugging but later failed to deliver clicks to the status-button action on this multi-display host; physical left-click behavior in the release app still needs user confirmation.

Manual redemption and auto-start logic are tested without live account mutations or inference, against verified official interfaces. No real reset or model request was used in testing. Multiple authenticated accounts, live warm-up/redemption, real banked-reset entries, browser login completion, sleep/wake, and launch-at-login still require interactive validation; existing credentials were not reused or altered during development.

[PERFORMANCE.md](PERFORMANCE.md) records app-only and process-tree measurements. Closed-popover idle RSS was **39.25 MiB**, idle CPU **0.00%** at the measurement’s precision, and **zero idle child processes**. The <30 MB RSS target was **not reached**; authenticated refresh peaks have not been measured. Do not interpret signed-out startup figures as the cost of authenticated network polling.

To reproduce (quit the running copy first):

```sh
python3 tools/measure.py --seconds 60
python3 tools/measure.py --seconds 30 --popover
```

Python is used only by this optional measurement tool, never by the app.

For a credential-free action/layout check, run `"dist/Codex Limits.app/Contents/MacOS/CodexLimits" --ui-smoke-test`. For the **real mouse-event path**, use `--ui-mouse-test` instead; event-posting permission must already be available to the test process. This permission is not needed for ordinary manual use. Both modes use disposable settings, disable polling/auto-start, verify account content and popover sizing, check show/refresh/close, and exercise Settings/Add Account without saving real configuration. No real account data or inference is accessed. `--ui-snapshot /absolute/path.png` optionally captures only this isolated popover's content.

## Project

```text
Sources/CodexLimits/  AppKit lifecycle, menu bar, popover, settings, polling
Sources/LimitsCore/  Typed official protocol, short-lived client, isolation, settings, safety gate
Tests/               Fixtures and unit tests
tools/measure.py     Optional process-tree performance measurement
build.sh             Release .app builder
```
