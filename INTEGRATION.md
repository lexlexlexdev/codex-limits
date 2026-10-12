# Official Codex integration findings

Investigated on **2026-10-12**, on arm64 macOS with Swift 6.0.2 and **codex-cli 0.154.0**. Source: [openai/codex](https://github.com/openai/codex), inspected commit [`a9b0815167c27ab13719dd12d13b63e02b70d221`](https://github.com/openai/codex/tree/a9b0815167c27ab13719dd12d13b63e02b70d221). The installed CLI’s `app-server generate-ts` output independently confirms the fields used here. No private HTTP endpoint or extracted token is used by Codex Limits.

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

Account configuration now supports any number of slots. A/B settings are backward compatible. New slots have fresh UUID-suffixed homes; labels can be reused after removal, but credential directories are not. All configured homes and slot labels must be unique, and authenticated snapshots are checked for duplicate users/workspaces across every slot. Removal only changes monitoring configuration: it never deletes credentials, logs out an account, or copies tokens. Usage reads and warm-ups remain sequential to avoid multiplying helper memory by the number of accounts.

`CODEX_HOME` controls Codex’s local state and managed credential lifecycle. Each slot gets a canonical, separate directory and an independently established OAuth login. Credential storage is left to Codex, including its file/Keychain configuration; the app does not force an existing home to a different credential store.

Login uses `account/login/start` with `{ "type": "chatgpt" }`, opens its HTTPS `auth.openai.com` authorization URL, then waits for the matching `account/login/completed` notification and `success: true`. A session timeout closes the server and its OAuth callback listener; it does not simulate success. The app explicitly confirms potential replacement of an existing dedicated login.

Current managed ChatGPT refresh uses a process-local semaphore plus a guarded auth-source reload. A reload can detect credentials already changed by another client, but this is not proof that two processes cannot race to refresh the same token. Therefore `refreshToken: false` alone does not make sharing a home safe: normal Codex authentication may refresh when needed. Homes must be **exclusively owned**, and `~/.codex` is rejected. Advisory `flock` locks prevent concurrent Codex Limits sessions, not arbitrary external Codex clients.

Evidence: [`login/src/auth/manager.rs`](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/login/src/auth/manager.rs), particularly `refresh_token`, `refresh_token_from_authority`, and `refresh_lock`. Fresh homes are recommended over attempting to audit an existing refresh-token lifecycle.

The child environment explicitly sets `CODEX_HOME` and removes inherited API/access/refresh-token selectors. Child stderr is discarded, no raw RPC payloads are logged, analytics/feedback/OTel exporters are disabled through process-local CLI overrides, and the ChatGPT base URL is pinned to Codex’s official default `https://chatgpt.com/backend-api/`. These are **Codex configuration overrides**, not direct application HTTP calls. Managed enterprise requirements remain enforced by Codex. Select the genuine official executable and do not use untrusted home configuration.

## Window semantics and the best-effort auto-start policy

[Managing usage with GPT-6 Astra in Work and Codex](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex) explicitly states:

> A new window starts when you send your first message in Work or Codex after the previous window ends.

The same page explains plan differences, weekly gates, banked resets, global resets, and credit fallback. Some plans currently have no five-hour limit. A full banked reset refreshes both windows and changes the weekly reset date. [Paid weekly resets](https://help.openai.com/en/articles/20001507-paid-weekly-work-and-codex-rate-limit-resets) likewise change the weekly anchor, with the new weekly period starting on the next request. Neither “100% remaining” nor a shifted reset timestamp is a unique natural-window identity.

Supported execution methods include `codex exec` and app-server `thread/start` + `turn/start` with turn-completion notifications. Merely sending `ok` is not safe by itself: normal execution is an agent capable of tools, read-only sandboxing does not mean “never execute shell commands,” and ordinary inference can use eligible credits after included allowance is exhausted.

Current protocol still provides no documented atomic operation to:

- Identify and claim one new natural window, distinguishing manual/global/banked resets.
- Guarantee that the next inference consumes **only included allowance**, regardless of another client’s concurrent usage.
- Perform that claim and inference with an execution idempotency key tied to the verified window.

`ordinaryUsageAllowed` is explicitly optional backend permission from a snapshot; protocol documentation says not to infer recovery from percentages or reset times. Even a true read is not a transaction spanning the subsequent turn. Auto-start was originally disabled because the strict original requirements could not be proven. The user subsequently requested a **best-effort 100% trigger**, and specified re-arming after a reading below 100%, including manual/global resets.

The implemented heuristic checks enabled slots every 600 seconds, requires five-hour `usedPercent == 0`, positive weekly allowance, ordinary permission, and a credit snapshot showing no paid entitlement/balance. A separate preflight checks those fields and account identity immediately before execution. The `auto-start.json` ledger claims the account/home/workspace attempt **before dispatch**. Repeated 100% readings and reset timestamps alone do not re-arm; only a later 10-minute check below 100% does. No automatic retry is performed, including after crash or uncertain completion. No reset/purchase API is involved. Credit checks are best effort, not an atomic billing safeguard.

The execution interface is installed CLI 0.154.0's **`codex exec --json --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check --strict-config --sandbox read-only --cd <disposable>`**. Official `features.shell_tool=false` is checked in `core/src/tools/spec_plan.rs`: shell registration returns immediately when disabled. Hooks, plugins, apps, agents, browser/computer use, and code-mode executors are also disabled. User/project instructions are omitted via `project_doc_max_bytes=0`. The official exec event contract (`exec/src/exec_events.rs`) provides `turn.completed`, `turn.failed`, and typed item events. Success requires completion plus exit code zero; non-message/reasoning items abort the attempt. There is no fake successful start event.

An outer native macOS `sandbox-exec` profile permits only the selected Codex executable to be exec'd and confines writes to dedicated state/scratch. Shell execution is kernel-denied, not merely discouraged by a prompt. Codex's inner read-only tool policy handles patch/file modification restrictions. If the CLI version, configuration, OS sandbox, or authentication prevents this mode, the attempt is recorded as failed/unknown and stays latched. No runtime sandbox relaxation is attempted. The kernel profile is tested with the actual installed CLI's `--version`, never a real prompt.

This feature intentionally does **not** claim the stronger original semantics. An unobserved dip below 100% can miss re-arming; rounding or a global reset can trigger within an existing natural window; a changed paid-credit state between preflight and inference is not atomically prevented. Future strict-window support would still require a backend-owned window identity and reservation/idempotent included-only execution contract.

## Process cost and limitations

Short-lived processes were selected after testing the installed native server. A fresh-home handshake/account read/explicit shutdown took approximately **0.62 seconds** before the final lazy-UI optimization. Startup helpers are transient; zero children remained idle. See [PERFORMANCE.md](PERFORMANCE.md) for measured app and tree RSS/CPU, methodology, and the unverified authenticated case.

No dedicated authenticated test accounts were supplied. Actual OAuth completion, live network snapshots, auto-start inference, and actual banked expirations are implemented against verified official contracts but not claimed as exercised with several signed-in users. No user credentials were copied or existing application authentication refreshed during validation. No inference or real banked-reset redemption was performed in tests.
