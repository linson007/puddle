# Persistence and concurrency

`PuddleStore` coordinates UI state on MainActor. `WorkspaceWriter` owns persistence
coordination; startup decryption and full saves run in utility tasks. A loading
view is shown during startup. While a disk write is running, edits share one
pending write containing the newest snapshot. Revision numbers prevent an older
request from replacing a newer snapshot.

Edits are **optimistically visible** while saving. Mutation methods are async and
report success only after a durable write. On failure, the current batch is
rejected and the UI returns to the last acknowledged snapshot. The writer rejects
late arrivals from that failed epoch, so they cannot overwrite the rollback.
Epochs increase after rollback; a single rejection watermark retains this
protection for every older epoch without accumulating UUIDs.
External actions await their intent save and recheck workspace/account policy
before dispatch. Normal Quit waits for pending writes; a failed save offers a
keep-open choice. Forced termination can still lose work that was not acknowledged.
Private-session and demo transitions wait for pending saves.

Live transcription writes `meeting-recovery.vault`, encrypted with the workspace
key, without rewriting `workspace.vault`. Startup merges recovery text for notes
that still exist. Saving applied text or explicitly discarding recovery records a
dismissal timestamp, preventing an older sidecar from resurrecting discarded
text after a crash. Previous single-file recovery records remain readable. No raw
audio is persisted. The recovery file contains only the bounded recovery payload;
ordinary workspace saves may also include those records.

An unreadable recovery sidecar does not block an intact workspace. Startup logs
the error, shows a non-blocking notice and moves the damaged file to
`meeting-recovery-unreadable-<uuid>.vault`. If moving fails, the original is kept
and checkpoints must preserve it before replacing it. Discarding, applying, or
deleting recovered text rewrites the sidecar with only the remaining recoveries;
an empty sidecar is deleted. Deleted notes' dismissal entries are pruned on edits,
so bookkeeping contains at most one entry per existing note. Normal encrypted
workspace backups can still retain earlier snapshots according to their existing
recovery policy.

Live capture checkpoints at most once every 30 seconds, including provisional
text even when no further segment arrives. Unchanged text does not cause a write.
Stopping capture flushes immediately. A forced termination can lose up to 30
seconds of recognized text plus any in-flight disk-write time; a failed checkpoint
shows an error and is retried on the next tick. Encoding, encryption and file I/O
stay on `WorkspaceWriter`, off the main actor. Raw audio is never saved.

The encrypted store checks inode, size, modification time, change time and key
fingerprint before reusing its validated primary. Changed files or keys require
validation again. Backups use a staged file copy and atomic replacement, rejecting
nonregular destinations. Transcript pages keep independent validation/recovery.

## Swift 6

The package uses Swift 6 language mode. CI explicitly runs complete concurrency
checking and `scripts/check-concurrency.py`. `NetworkPolicy` uses
`OSAllocatedUnfairLock`, available on the macOS 14 deployment target. The newer
`Mutex` API would raise the minimum runtime requirement. Immutable project and
URLSession wrappers use checked Sendable.

Retained unchecked types document their synchronization invariant next to the
declaration. `TranscriptVault.Cache` keeps its recursive lock because synchronous
legacy migration re-enters the same persistence store. Converting that cache to
an actor would conflict with `SnapshotPersistence`'s synchronous interface; the
writer supplies background isolation and the lock protects shared store copies.
Audio conversion is serialized by its sink lock. Process/transport teardown uses
its documented lock/queue. Debug screen-audio counters run on the registered
serial audio callback queue.

## Diagnostics

Console categories under subsystem `app.puddle`: `persistence`, `network`,
`speech`, `oauth`. Stable operation names are public; error details are always
private because they may contain paths, URLs, provider responses or user content.
Swift `CancellationError`, URLSession `URLError(.cancelled)` and the bridged
`NSURLErrorDomain` / `NSURLErrorCancelled` form are not logged as failures.
Timeouts and privacy-policy interruptions remain logged. User-visible errors
remain visible.

```sh
log stream --level error --predicate 'subsystem == "app.puddle"'
sh scripts/swift.sh test --filter 'WorkspaceWriterTests|PuddleStoreTests'
```

These fixtures force save failures and exercise the logging path without personal
credentials. Never enable private-data logging or attach unredacted Console logs.

## Remaining force-unwrap invariants

There are no `try!` or `as!` expressions in production sources. Fallible encoding,
calendar calculations, decoded token fields, PCM channels, buffer addresses and
project reads use guards or explicit failure values. The remaining unwraps are
limited to these construction invariants:

| Family | Invariant |
| --- | --- |
| Literal web links and service endpoints | Fixed, syntactically valid URLs; no parsed response or user string is unwrapped. |
| Google/Microsoft/Atlassian/GitHub URL construction | Base hosts are constants or validated absolute provider URLs; path components are validated/percent encoded and query values use URLQueryItem. Host unwraps follow provider-host validation. |
| Loopback OAuth callbacks | Listener port is a UInt16 inserted into a fixed HTTP loopback URL. |
| Assistant preset UUIDs | A fixed UUID prefix plus a fixed, bounded preset number produces exactly 12 decimal digits. |
| DEBUG UI fixture HTTP response | Validated fixture URL and a fixed valid status code; excluded from release builds. |

When changing any constructor, preserve the stated invariant or replace its
unwrap with a thrown `PuddleError`. The DEBUG-only `UITestWorkspace` fatal error
continues to fail fast on invalid fixture configuration.
