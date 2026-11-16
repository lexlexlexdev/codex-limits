# Measured performance

Release arm64 monitoring build, macOS host, Swift 6.0.2, Codex CLI 0.154.0, 2026-10-12. These measurements precede manual reset redemption, multiple-account support, and Command Code support and have not been rerun for those features. They reflect two signed-out slots, not an arbitrary account count. The app was launched directly from its signed `.app` bundle. No popover animations run while idle. No existing Codex credentials were accessed or refreshed. No real reset or inference has been used in testing. Codex helpers remain sequential with multiple accounts, but polling work scales with account count; Command Code adds a small HTTPS request burst on the same interval.

`tools/measure.py` samples `ps` every 250 ms, follows descendants by parent PID, and records resident set size and cumulative CPU time. Idle CPU excludes the first ten seconds. RSS includes shared resident framework pages and is **not** macOS physical footprint. The sampling tool’s CPU is not counted in the app tree. Short-lived processes can be missed; the figures are observed samples, not precise allocation peaks.

## Results

| Measurement | Popover closed (60.18 s) | Popover open (30.18 s) |
|---|---:|---:|
| App idle RSS | 39.25 MiB | 61.33 MiB |
| Total process-tree idle RSS | 39.25 MiB | 61.33 MiB |
| App observed peak RSS | 53.66 MiB | 67.25 MiB |
| Total tree observed peak RSS | 80.48 MiB | 67.25 MiB |
| App idle CPU, one-core percentage | 0.000% | 0.100% |
| Observed cumulative tree CPU | 0.17 s | 0.35 s |
| Idle Codex child processes | 0 | 0 |

Both runs observed the native Codex executable as a transient child; no Node launcher or persistent helper. The open-popover run’s observed tree peak happened after its brief children exited, illustrating why sampled peaks differ. The 30-second open-popover run does not exercise its minute countdown timer.

Before deferring all popover construction and adding an autorelease pool around worker reads, a closed-popover run measured 44.86 MiB idle app RSS, 80.91 MiB sampled peak tree RSS, and 0.020% idle CPU. The final lazy construction reduced measured idle RSS to 39.25 MiB. The **<30 MB app RSS target is not met**; this is reported rather than assumed away. No claim of zero absolute CPU or authenticated polling overhead is made.

## Not measured

- Authenticated quota reads and detailed reset-credit HTTP requests.
- Browser login, long-running OAuth callback waits, and refresh-token renewal.
- Two authenticated users under real usage, banked-reset changes, or quota exhaustion.
- Post-popover-close retained AppKit caches, long-term energy impact, wake cycles, or different macOS versions.
- Launch-at-login approval and automatic relaunch behavior.

The app has no fixed idle UI timer with its popover closed. Ordinary polling is one tolerance-enabled timer (five minutes by default), transient errors have bounded recovery delays, authentication/configuration errors stop polling, and `NWPathMonitor`/workspace notifications are event-driven. Each server has a 40-second read watchdog and a bounded shutdown; login has a five-minute watchdog. The app also kills its registered helpers on sleep and orderly termination.

## Reproduce

Quit any running Codex Limits instance. Use genuine official Codex and exclusively owned homes. The optional Python tool is not needed to run the application:

```sh
./build.sh
python3 tools/measure.py --seconds 60
python3 tools/measure.py --seconds 30 --popover
```

For realistic authenticated performance, configure both accounts first and repeat. A 60-second launch run measures initial refresh, not subsequent five-minute cycles; use `--seconds 660` to include two default polling cycles. The tool terminates only the application process it launched. Do not end a measurement while an interactive login is active.
