# Task 2 Report: TranscriptSettingsInstaller

## Status: DONE

## What Was Done

Implemented `TranscriptSettingsInstaller` following TDD steps exactly as specified in the brief.

## TDD Evidence

### Step 1: Test written (verbatim from brief)
File: `LumiPackages/Tests/LumiServicesTests/TranscriptSettingsInstallerTests.swift`

### Step 2: RED run
Command: `cd LumiPackages && swift test --filter TranscriptSettingsInstallerTests`
Output (key lines):
```
error: cannot find 'TranscriptSettingsInstaller' in scope
error: fatalError
```
Confirmed RED as expected.

### Step 3: Implementation written (verbatim from brief)
File: `LumiPackages/Sources/LumiServices/Remote/TranscriptSettingsInstaller.swift`
- Created `Remote/` subdirectory under `LumiServices/Sources/` (SPM auto-picks it up)
- No manifest edit needed

### Step 4: GREEN run
Command: `cd LumiPackages && swift test --filter TranscriptSettingsInstallerTests`
Output:
```
Test Suite 'TranscriptSettingsInstallerTests' passed at 2026-08-06 14:09:35.185.
   Executed 2 tests, with 0 failures (0 unexpected) in 0.006 (0.007) seconds
```
Both tests passed:
- `testInstallWritesHookAndSettingsAndReturnsSettingsPath` — PASS
- `testInstallIsIdempotent` — PASS

### Full LumiServicesTests suite (no regressions)
Command: `cd LumiPackages && swift test --filter LumiServicesTests`
Result: **94 tests, 0 failures** (92 pre-existing + 2 new)

## Step 5: Commit
```
35cb809 feat(services): TranscriptSettingsInstaller — SessionStart hook + --settings dosyası
```

## Files Changed
- Created: `LumiPackages/Sources/LumiServices/Remote/TranscriptSettingsInstaller.swift`
- Created: `LumiPackages/Tests/LumiServicesTests/TranscriptSettingsInstallerTests.swift`

## Self-Review

The implementation is verbatim from the brief. Key design points confirmed:
1. `install()` is idempotent — writes/overwrites on each call, directories created with `withIntermediateDirectories: true`
2. Script is set to 0o755 permissions — test checks `perms & 0o111 == 0o111` (passes)
3. `claude-settings.json` contains `hooks.SessionStart` — verified by test
4. `transcript-map/` directory is created — verified by test
5. No Swift 6 concurrency annotations needed — `TranscriptSettingsInstaller` is a plain `struct` with no actor or async code; Foundation FileManager calls are synchronous

## Concerns

None. Implementation matches brief exactly, all tests pass, no regressions in existing suite.

---

## Review Fix: Hook Command Path Quoting

### Finding Fixed
`TranscriptSettingsInstaller.swift` generated `"sh \(script.path)"` — unquoted path breaks when the install root contains a space (e.g. `/Users/John Doe/.lumi/...`).

### Change Applied
File: `LumiPackages/Sources/LumiServices/Remote/TranscriptSettingsInstaller.swift`

Before:
```swift
"command": "sh \(script.path)"
```
After:
```swift
"command": "sh '\(script.path)'"
```

### New Regression Test Added
File: `LumiPackages/Tests/LumiServicesTests/TranscriptSettingsInstallerTests.swift`

`testHookCommandSingleQuotesPathWithSpace` — installs into a `lumiRoot` whose path contains a space (`lumi inst <UUID>`), reads and JSON-parses `claude-settings.json`, navigates `hooks.SessionStart[0].hooks[0].command`, asserts it contains `'<script.path>'` (the single-quoted absolute path).

### Verification Run
Command: `cd LumiPackages && swift test --filter TranscriptSettingsInstallerTests`
Output:
```
Test Suite 'TranscriptSettingsInstallerTests' passed at 2026-08-06 14:12:28.289.
   Executed 3 tests, with 0 failures (0 unexpected) in 0.008 (0.008) seconds
```
Tests:
- `testHookCommandSingleQuotesPathWithSpace` — PASS (new)
- `testInstallIsIdempotent` — PASS
- `testInstallWritesHookAndSettingsAndReturnsSettingsPath` — PASS
