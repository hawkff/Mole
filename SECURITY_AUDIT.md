# Mole Windows CLI Security Review

Reviewed on 2026-10-13 against `88cf57e8` on the `windows` branch. This describes the open-source Windows CLI, not the paid Windows app. It follows the macOS CLI audit's structure while documenting Windows-specific controls and limitations. It is a maintainer review, not an independent security certification.


Bounded follow-up on 2026-10-14: `0b78b46b` adds unreadable-whitelist retention and preserves Spotify stores; `3a7f8b7b` narrows the Proton Pass command exception. The affected claims below are updated. This is not a new full security audit; regression and delivery evidence is in the development record.

Bounded follow-up on 2026-10-16 from `c6ce917e`: generic screenshots and screen recordings are retained even with `-GameMedia`; config removal refuses root/ancestor junctions; a locked native launcher is rejected before any uninstall mutation; SFC uses owned scratch and checked exit status. Windows Update inspection uses a bounded local-catalog query and retains unknown results instead of reporting zero updates. Operation logs now cover actual removal/recycle outcomes and checked owner-process termination, and Analyze append failures reach the existing debug session. This is a scoped repair review, not a new certification or release; current runtime receipts are in the development record.

Bounded follow-up on 2026-10-25 from `9c408d72`, implemented in `87f26494` (uninstall), `ebc7e23a` (optimization) and `c0945edc` (status): registered directory identity is independent of recursive sizing and leftover eligibility, preserving distinct registrations without relaxing protected-root checks. Cached Store selections now require current package identity/metadata and reject known sparse packages, with Game Bar explicitly protected. Physical-disk inventory failure no longer prevents an independent target-volume health check. This is a scoped follow-up, not a new full audit; native regression receipts and their failed preliminary runs are recorded in the development record.

## Threat Surface

The primary risk is unintended local data loss. Relevant surfaces are automatic cleanup, project-artifact purge, application uninstallers and leftover recycling, Analyze deletion, system maintenance, installation and self-update. Read-only inspection and successful unit tests do not establish that every destructive operation is safe on every Windows installation.

## Destructive Operation Boundaries

| Surface | Current controls | Regression evidence |
| --- | --- | --- |
| PowerShell file removal | `Test-SafePath` applies protected paths and the whitelist. `Get-MolePathSnapshot` binds the target and ancestors to volume/file identities; incomplete inspection or replacement retains the target. Directory removal checks descendants and rechecks each entry before removal. | `tests/Core.Tests.ps1`, `tests/CleanupBoundary.Tests.ps1` |
| Links and shared roots | Linked ancestors are refused. Directory traversal does not follow junction targets. Supported leaf-link removal unlinks the entry without recursively deleting its target. | `tests/CleanupBoundary.Tests.ps1` |
| Whitelist | Literal paths, including brackets, protect their descendants before wildcard interpretation. Prefix siblings are not descendants. Missing user protection is empty; metadata/content read failure retains targets, and filenames are read literally. | `tests/CleanupBoundary.Tests.ps1` |
| Owner-managed caches | Owner commands resolve their actual roots, honor exclusions and recheck root identity. Unknown roots or failed commands never fall back to direct deletion. Automatic Docker builder pruning is excluded. | `tests/CleanupTargets.Tests.ps1` |
| Application disk caches | Browser, Teams, editor/notes and Poetry cache leaves use a complete process snapshot and applicable lock-file checks before preview and after sizing. Live or unknown owners retain targets. Poetry virtualenvs, Service Worker CacheStorage and Adobe Team Projects state are clean-protected, including shared-sink parent sweeps. Sublime Local and Roaming caches use the same owner guard. The exact new Teams WebView disk-cache exception does not bypass user exclusions or allow package roots. | `tests/AppCacheSafety.Tests.ps1` |
| Error reports | Seven-day eligibility uses creation and write times across a complete bounded report tree. Recent, linked or unreadable reports are retained, including attachments arriving during sizing. WER collection roots are not removed. | `tests/AppCacheSafety.Tests.ps1` |
| Disk maintenance | Target-volume health is read independently even if physical-disk inventory fails; known Warning/Unhealthy targets are retained before optimization. Battery-equipped systems require complete external-power evidence, unknown power retains the drive, and a complete empty battery inventory permits a desktop. | `tests/Optimize.Tests.ps1` |
| Purge | Generic names require the matching project ecosystem. Git-tracked content, nested repositories and ambiguous probes retain the candidate; discovery and deletion recheck ownership. | `tests/PurgeBoundary.Tests.ps1` |
| Application leftovers | The registered uninstaller and its tracked descendants finish first. Its wait has a fixed 30-minute ceiling; timeout stops the batch without killing the vendor or recycling leftovers. Leftover recycling requires the selected registration to be gone and a complete inventory with no same, parent or child install-folder owner. Registered path identity survives protection for merging and display, with a separate restriction on recursive measurement. Preview and the removal guard both check ownership and bounded game-content markers in registered install roots; incomplete or redirected children retain the folder. | `tests/Uninstall.Tests.ps1`, `tests/UninstallWait.Tests.ps1` |
| Store uninstall | Game Bar and existing protected package metadata are excluded. Preview and the removal boundary re-read the exact current full package identity and reject protected metadata or a known sparse manifest; unknown package inventory retains the selection. | `tests/Uninstall.Tests.ps1` |
| Leftover recovery | `ITransferSource.RecycleItem` is used on fixed local drives, with no permanent-delete fallback. Identity and descendant protection are rechecked. Recycled bytes do not count as freed disk space. | `tests/Recycle.Tests.ps1` |
| Analyze deletion | Explicit selection/confirmation, raw path validation, ancestor identity binding, protected-descendant inspection and a final recheck precede the native shell operation. A generic name such as `build` is not a cleanable hint without a valid cache tag. | `cmd/analyze/windows_test.go`, `cmd/analyze/cleanable_test.go` |
| CLI installation/removal | Known files are merged without clearing shared directories. Unknown files and nonempty Git metadata survive self-removal. Linked install/config roots and ancestors and unrelated nonempty install roots are refused. A locked native launcher is rejected before PATH, shortcut or file mutation, with a direct PowerShell removal command. | `tests/Install.Tests.ps1`, `tests/InstallLifecycle.Tests.ps1` |

Automatic cleanup generally deletes permanently. Third-party uninstallers retain their own data-removal semantics. Analyze uses `SHFileOperationW` with undo support on fixed local drives and requests a Windows warning if the shell would permanently delete instead; this is not the same API or guarantee as leftover-only recycling. Windows shell behavior and user confirmation still matter.

## Protected Data and Privilege

`lib/core/base.ps1` distinguishes protected prefixes from exact protected roots. Windows, Program Files and security-sensitive stores remain protected; the user-profile root is protected without prohibiting all supported child caches. Empty or unparsable paths are refused. During automatic cleanup, additional exclusions cover key/configuration stores, browser state and Claude/Codex transcripts. Spotify Data and Storage are not automatic cleanup targets because they may contain offline media. The native Analyze policy is implemented separately and tested separately, not inferred from the PowerShell helper.

Application owner checks are fresh observations, not a shared lock held throughout deletion. An application can start after the last check, and the profile-enumeration deadline is checked between filesystem calls rather than interrupting a blocked kernel call. These guards do not establish an atomic ownership lease.

Literal path handling, no-follow inspection and identity rechecks reduce accidental traversal and replacement risks. These are path-based operations, not an atomic security boundary against a hostile process continuously replacing directory components between the last check and the operating-system call.

Commands run with the caller's Windows permissions. Administrator-only maintenance checks the current token; elevation is not permission to bypass protected paths. Verification uses mocked system actions and disposable fixtures. It does not stop the user's services, uninstall real applications or exercise UAC/MSI flows unless that specific test is authorized.

## Preview, Results and Diagnostics

`--dry-run` and `MOLE_DRY_RUN=1` prevent cleanup, optimization and uninstall mutations. Preview can still create its local report files. Dry-run tests assert that uninstallers, package removal and service mutations are not invoked.

Owner-cache preview records the resolved root without treating the whole store as reclaimable. Real accounting uses complete before/after measurements only when root identity is unchanged. A successful owner command can count as activity without an invented byte total. Native failures are checked through exit status rather than assumed to raise PowerShell exceptions.

`lib/core/log.ps1` and `cmd/analyze/oplog.go` append real outcomes to `~\.config\mole\operations.log`, escape control bytes, retry held files briefly, and send failed appends to debug diagnostics. Dry runs write no operation rows, `MO_NO_OPLOG=1` disables them, and self-removal preserves them. The log is neither tamper-resistant nor a transaction or crash-recovery guarantee; a completed filesystem action can still lose its log row. Proxy rendering sanitizes environment and WinINet inputs; malformed values are not echoed, preventing embedded proxy credentials from appearing in Status.

## Installation and Release Integrity

`lib/core/tui_binaries.ps1` compares downloaded Analyze/Status executables with the asset's SHA-256 entry in the release checksum file. A mismatch aborts that path rather than falling back to compilation. Source updates refresh both native tools and use release binaries only when source equivalence is established; otherwise Go is required. Installation and update fetch tags needed for this comparison.

[RELEASE.md](RELEASE.md) defines signing and publication. Published asset signatures, checksum readback and package-manager delivery are separate verification steps; source tests cannot prove them. Checksums served alongside assets are integrity checks within the same distribution trust boundary, not independent provenance. This review did not publish or validate a new signed release.

## Verification Evidence

At the reviewed source revision, [Check](https://github.com/tw93/Mole/actions/runs/38382721940) and [Validation](https://github.com/tw93/Mole/actions/runs/38382721936) completed successfully. Validation includes PowerShell 5.1 and 7, Go tests, native builds and protected-path checks. Earlier local evidence, fixture red runs and exact batch scope are in the [development record](docs/development-record.md).

The checks have specific limits:

- Go formatting and PowerShell parsing are enforced. `golangci-lint` is advisory through `continue-on-error`; a green workflow does not prove a clean lint result.
- The unsafe-removal and secret-pattern steps print findings without failing. They are review prompts, not enforced security gates or a comprehensive secret scanner.
- Most recycle and uninstall tests use mocked sinks. `TestRecycleBinIntegration` is opt-in and requires an explicit disposable fixture. It is skipped by default. A separate ThinkPad run passed the real file/junction/directory recycle cases and PowerShell preview/recycle/restore checks; exact scope is recorded in the [development record](docs/development-record.md).
- A Parallels run and a GitHub-hosted Windows run do not establish ThinkPad acceptance. Record the actual machine, tested revision, runtime versions, test summaries, exit codes and skipped cases before making that claim.
- Interactive shell/Recycle Bin behavior, real UAC and third-party uninstallers, Defender/SmartScreen and signed distribution remain separate acceptance surfaces.

## Known Limitations

- Permanent cleanup has no general undo, and a multi-file failure can leave a partially completed operation.
- Identity rechecks are not atomic with deletion or with a third-party owner command's work.
- Analyze's traversal checks use a ten-second checkpoint budget and a 100,000-entry cap. A blocking Windows filesystem call is not forcibly cancelled by that checkpoint budget; oversized or incomplete inspections are refused.
- Native shell recycling waits for the shell's result. A long-running shell call is not reported as complete merely because a timer elapsed.
- A cache tag is an owner's declaration, not proof that arbitrary contents are unimportant or untracked.
- Store manifests are not completely classified when unreadable. The established ordinary Store uninstall behavior remains in that case; current package inventory must still be readable and eligible.
- Leftover ownership is based on registered install locations and current-user Appx inventory. Unregistered portable applications or missing vendor metadata cannot be exhaustively classified.
- Purge reads Git without the user's Git configuration. A repository Git refuses to open, such as one owned by another non-administrator account, keeps its artifacts even when the user's global `safe.directory` lists it (verified on Windows PowerShell 5.1: plain `git status` exit 0, Purge's isolated call exit 128).
- Uninstaller waiting retains PowerShell's process-tree semantics; it is not a sandbox for vendor code or detached services. The deadline does not prove an idle process is finished. Native process start or consent dialogs can block outside the cancellable wait; UAC and real vendor behavior remain separate acceptance surfaces.
- Automated tests cover controlled fixtures. They do not establish safety for every filesystem provider, locked-file state, running application or administrator configuration.

For private vulnerability reporting, see [SECURITY.md](SECURITY.md). Keep this review aligned with changed safety boundaries and retain dated runtime evidence in the development record.
