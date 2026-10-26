# Integration findings

Investigated on **2026-10-12**, on arm64 macOS with Swift 6.0.2 and **codex-cli 0.154.0**. Source: [openai/codex](https://github.com/openai/codex), inspected commit [`a9b0815167c27ab13719dd12d13b63e02b70d221`](https://github.com/openai/codex/tree/a9b0815167c27ab13719dd12d13b63e02b70d221). The installed CLI’s `app-server generate-ts` output independently confirms the Codex fields used here. The Codex sections use no private HTTP endpoint or extracted token. Command Code support is separate: it reads the CLI’s existing key and calls the CLI’s internal usage endpoints, documented below.

## Transport and reads

`codex app-server --listen stdio://` accepts newline-delimited JSON-RPC-style messages over stdin/stdout. Initialize with `clientInfo` and capabilities, receive the response, then send `initialized`. Experimental APIs are not enabled.

The monitor uses:

1. `account/read` with `{ "refreshToken": false }`: a `chatgpt` account provides nullable `email` and `planType`; `apiKey` accounts are rejected. A null email is insufficient to verify independent users, so connection fails closed. No forced proactive refresh.
2. `account/rateLimits/read` with `{}`: returns `rateLimits`, optional `rateLimitsByLimitId`, optional `rateLimitResetCredits`, optional `ordinaryUsageAllowed`, and optional `accountId`. Passing no exclusion option preserves detailed banked-reset reads on current servers.
3. `account/read` again: avoids exposing a snapshot after an observed user change during the read.

`account/rateLimits/updated` exists but is a **sparse update** of a `RateLimitSnapshot`, not a complete account snapshot. Official source explicitly recommends merging or rereading. This app uses complete reads instead of retaining a large helper to receive notifications. During a short session unrelated notifications are not treated as complete quota or reset-credit state.

`RateLimitWindow` fields are `usedPercent`, nullable `windowDurationMins`, nullable `resetsAt`. `resetsAt` is Unix seconds. The conversion from the core snapshot rounds `usedPercent` to an integer, so zero used is **not** proof that no request has been made. Five-hour and weekly windows are matched by 300 and 10080 minutes; unknown durations are not guessed. The ordinary `codex` bucket is selected explicitly when a multi-bucket map exists; an unrelated premium bucket is not substituted.

Evidence:

- [`app-server-protocol/src/protocol/v2/account.rs`](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/app-server-protocol/src/protocol/v2/account.rs): account/read types, usage-read types, rounded conversion, sparse-update semantics.
- [`app-server/src/request_processors/account_processor.rs`](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/app-server/src/request_processors/account_processor.rs): backend usage read, account identity association, detail fallback.
- Installed CLI-generated `GetAccountRateLimitsResponse.ts`, `RateLimitResetCredit.ts`, `InitializeParams.ts`, and `AccountLoginCompletedNotification.ts` were checked before implementation.

## Banked resets: accessible, but optional

The current official app-server **does expose individual expiration timestamps**:

```text
rateLimitResetCredits:
  availableCount: integer
  credits: array | null
    id: string
    resetType: "codexRateLimits" | "unknown"
    status: "available" | "redeeming" | "redeemed" | "unknown"
    grantedAt: Unix seconds
    expiresAt: Unix seconds | null
    title: string | null
    description: string | null
```

Null `credits` means count-only information. An empty list means details were fetched but no available entries were returned. Lists can be capped below `availableCount`. Null `expiresAt` means **does not expire**; absence of the field is not equivalent to null. Unknown types/statuses and non-available entries are not presented as available Codex resets. Incomplete detail lists fall back to the known count and an unavailable-details notice. Neither example data nor estimates are substituted.

Official app-server fetches a separate detailed reset-credit list and falls back to the usage response’s count if that detail read fails or times out. Therefore, lack of details is a supported backend state, not a parsing error that should invent dates.

The supported mutation is **`account/rateLimitResetCredit/consume`**, verified in the installed CLI-generated `ClientRequest.ts`. Its parameters are `idempotencyKey` (nonempty string, UUID recommended) and optional `creditId`. **This app always supplies the specific clicked credit ID**, never the backend-selected default. Official outcomes are `reset`, `nothingToReset`, `noCredit`, and `alreadyRedeemed`.

Following the request to add manual redemption, the app now calls this method **only after an explicit native confirmation dialog**. It checks ChatGPT user identity, workspace/account ID, and fresh availability/expiration before sending; other app operations are blocked during confirmation and execution. Cancel makes no mutation or journal write. A request key is persisted before dispatch; uncertain outcomes retain it for a later explicitly confirmed retry of that same reset, even across restarts or other reset attempts. There are no automatic mutation retries. Known `nothingToReset`/`noCredit` outcomes permit a new logical attempt on a later confirmation. Post-reset usage is fetched from the server, never simulated. Confirmed success remains confirmed if that follow-up read fails, with a separate warning. No purchase or inference method is involved.

Banked resets and credit balances are different things. Open Usage remains the fallback when identity or reset details are unavailable. **No real reset was redeemed during development**; mutation tests use in-memory transports only.

Evidence: [`account_processor/rate_limit_resets.rs`](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/app-server/src/request_processors/account_processor/rate_limit_resets.rs), protocol types above, and [How banked Codex resets work](https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work).

## Authentication isolation

Account configuration now supports any number of slots. A/B settings are backward compatible. New slots have fresh UUID-suffixed homes; labels can be reused after removal, but credential directories are not. All configured homes and slot labels must be unique, and authenticated snapshots are checked for duplicate users/workspaces across every slot. Removal only changes monitoring configuration: it never deletes credentials, logs out an account, or copies tokens. Codex usage reads remain sequential to avoid multiplying helper memory by the number of accounts.

`CODEX_HOME` controls Codex’s local state and managed credential lifecycle. Each slot gets a canonical, separate directory and an independently established OAuth login. Credential storage is left to Codex, including its file/Keychain configuration; the app does not force an existing home to a different credential store.

Login uses `account/login/start` with `{ "type": "chatgpt" }`, opens its HTTPS `auth.openai.com` authorization URL, then waits for the matching `account/login/completed` notification and `success: true`. A session timeout closes the server and its OAuth callback listener; it does not simulate success. The app explicitly confirms potential replacement of an existing dedicated login.

Current managed ChatGPT refresh uses a process-local semaphore plus a guarded auth-source reload. A reload can detect credentials already changed by another client, but this is not proof that two processes cannot race to refresh the same token. Therefore `refreshToken: false` alone does not make sharing a home safe: normal Codex authentication may refresh when needed. Homes must be **exclusively owned**, and `~/.codex` is rejected. Advisory `flock` locks prevent concurrent Codex Limits sessions, not arbitrary external Codex clients.

Evidence: [`login/src/auth/manager.rs`](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/login/src/auth/manager.rs), particularly `refresh_token`, `refresh_token_from_authority`, and `refresh_lock`. Fresh homes are recommended over attempting to audit an existing refresh-token lifecycle.

The child environment explicitly sets `CODEX_HOME` and removes inherited API/access/refresh-token selectors. Child stderr is discarded, no raw RPC payloads are logged, analytics/feedback/OTel exporters are disabled through process-local CLI overrides, and the ChatGPT base URL is pinned to Codex’s official default `https://chatgpt.com/backend-api/`. These are **Codex configuration overrides**, not direct application HTTP calls. Managed enterprise requirements remain enforced by Codex. Select the genuine official executable and do not use untrusted home configuration.

## Window semantics

The app displays only windows the server reports. Five-hour and weekly Codex windows are selected by duration (300 and 10080 minutes), not by primary/secondary ordering. `usedPercent` is converted to remaining with `100 − usedPercent`, clamped to 0–100. Some plans have no five-hour limit; the app shows unavailable rather than a fabricated percentage. Expired reset timestamps say **awaiting server update**; the app never locally refills a meter.

No inference is sent by monitoring. The former best-effort auto-start trigger has been removed: the app no longer sends `ok`, launches `codex exec`, writes an `auto-start.json` ledger, or exposes a 10-minute auto-start toggle. Monitoring remains read-only, and reset redemption is the only mutation, only after explicit confirmation.

## Command Code usage reads

Command Code support uses the HTTP endpoints the Command Code CLI uses (package `command-code` 1.88.0), not a documented public API:

- `GET https://api.commandcode.ai/alpha/whoami?limits=1`
- `GET /alpha/billing/credits?orgId=…`
- `GET /alpha/billing/subscriptions?orgId=…`
- `GET /alpha/usage/summary?orgId=…&since=…`
- Header: `Authorization: Bearer <key>`. The key comes from `COMMAND_CODE_API_KEY` or `~/.commandcode/auth.json`.

The credits response provides `credits.{monthlyCredits,purchasedCredits,freeCredits,planId}`, `windowLimits.{limited,fiveHour,weekly}.{used,cap,resetAt}`, and optional sandbox fields. `resetAt` is in milliseconds. Subscription `data.{planId,status,currentPeriodStart,currentPeriodEnd}` and summary `totalCost`/`totalCount` supply renewal and spend context. These projections were extracted from the CLI bundle; no public API schema guarantees them.

The app derives remaining window percentages as `1 − used/cap`. Monthly remaining uses the plan’s monthly allowance when the subscription is active, otherwise `totalCost + remaining`; missing credits, caps, or dates are shown as unavailable. The key is held in memory for the request, never written back, logged, or included in errors. The app makes no Command Code model requests and no purchase/reset calls. A missing `auth.json` is a distinct not-connected state; a 401/403 stops automatic retries until the user signs in again.

## Process cost and limitations

Short-lived processes were selected after testing the installed native server. A fresh-home handshake/account read/explicit shutdown took approximately **0.62 seconds** before the final lazy-UI optimization. Startup helpers are transient; zero children remained idle. See [PERFORMANCE.md](PERFORMANCE.md) for measured app and tree RSS/CPU, methodology, and the unverified authenticated case.

No dedicated authenticated test accounts were supplied. Actual OAuth completion, live network snapshots, and real banked expirations are implemented against verified official contracts but not claimed as exercised with several signed-in users. The Command Code client was validated against a rejected credential and decoder fixtures, not a live authenticated account. No user credentials were copied or existing application authentication refreshed during validation. No inference or real banked-reset redemption was performed in tests.
