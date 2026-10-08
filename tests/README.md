# Sparkle integration tests

Run the real Sparkle integration suites on macOS in a logged-in GUI session:

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

The bundled Sparkle framework and CLI tools must already be available under
`build/SourcePackages/artifacts/sparkle/Sparkle`. The tests compile small Swift
hosts with `xcrun swiftc`; they do not run Xcode builds.

## Feed checks

`test_sparkle_feed.py` exercises actual Sparkle feed discovery, signature
verification, channel filtering, OS eligibility, and version selection against a
localhost server. These checks do not download or install update payloads.

## Download, installation, and relaunch

`test_sparkle_install.py` creates disposable, ad-hoc-signed application bundles
with unique bundle identifiers. A custom test user driver accepts the update and
relaunches automatically through the real Sparkle installer. Tests verify:

- Both ZIP and compressed DMG updates replace build 1 with build 2 and launch the
  new executable.
- A preference written by the old executable remains readable after relaunch.
- The updater actually reaches download, extraction, and ready-to-install stages.
- Interrupted HTTP downloads, a tampered artifact, a signed invalid archive, and
  an archive without an application leave build 1 and its preference intact.

All apps, payloads, signing keys, and result files are temporary. The suites
create ephemeral Ed25519 signing keys without reading or modifying the production
Keychain signing account. App preferences and Sparkle caches use unique test
identifiers and are removed afterward. The installed VibeWindowManager app and
its preferences are never used or replaced; nothing is uploaded or published.

These tests verify Sparkle's real lifecycle with the production security flags
(`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`). They are **not** a
full VibeWindowManager UI or migration test: preference preservation uses a test
sentinel, not every application setting. Failure cases cover download,
verification, and extraction/pre-install failures; they do not simulate power
loss, disk exhaustion, permission prompts, or rollback after replacement has
already begun. Signing authority can intentionally change bundle identity, so
release-script validation separately enforces VibeWindowManager's exact bundle
identifier and metadata.

## App regression and performance checks

The Xcode scheme runs app unit tests plus UI close/reopen and relaunch checks.
`UsageConcurrencyLifecycleTests` uses controlled completions and manual timers
to cover overlapping refreshes, cancellation, stale responses, and cleanup.
`AccessibilityFailureTests` injects permission state without changing macOS permissions
or moving real windows. Provider tests inject network failures and use temporary
SQLite databases. `ClaudeRefreshPolicyTests` verifies shared requests, caching,
Retry-After, escalating cooldowns across relaunches, and preserved cached usage.

`PerformanceRegressionTests` records XCTest clock, CPU, and memory metrics for
server-list parsing, layout generation, and usage parsing. These are repeatable
benchmarks with correctness assertions; performance regression thresholds require
a baseline on the same hardware.

A one-time idle sample on 2026-10-08 measured the Debug app after startup, with its
main window closed and no active streaming workload. Over 30 seconds, the app
used 0.00056 CPU seconds (0.0019% of one core); reaped helper processes used another
0.00561 seconds (combined approximately 0.021% of one core). Its physical footprint
was 43.55 MiB, down 0.06 MiB during the sample, with zero package-idle wakeups,
16 interrupt wakeups, 4 KiB disk reads, and no disk writes. Counters came from
macOS proc_pid_rusage, sampled outside the sandboxed UI runner. This is a short
idle observation, not a battery-life estimate or a streaming/recording benchmark.
The measurement-only UI test was removed afterward so ordinary runs do not wait
for another idle sample.

Physical sleep/wake, display unplugging, OS permission prompts, and real-device
energy consumption still need manual/device testing; they are not simulated by
the UI close/reopen tests.
