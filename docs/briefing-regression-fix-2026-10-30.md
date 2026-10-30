# Briefing countdown and undated tasks — verified fix

The briefing P1 from [the release regression](release-regression-2026-10-30.md)
is resolved for newly generated executive briefs. Other public-release gates
in that report still require acceptance.

## Behavior

At **12:43 IST**, an event starting at **14:00 IST** displays **Starts in
1h 17m**. A task titled “Alex will review the release checklist by Friday.”
with no saved `dueAt` displays **No scheduled due date**, and does not enter
the due-today count. Words in titles remain quoted source text.

`BriefingAnswer` derives timing and deadline labels from the executive tool's
timestamps, timezone and saved task fields. It computes elapsed time between
instants across DST, distinguishes upcoming/ongoing/ended/all-day events, and
does not guess unknown end times. Countdown minutes round up; an event less
than a minute away is labeled explicitly.

After reading an executive brief, `LocalAgent` asks the model only to select
permitted next-step kinds and source IDs. The app validates those selections
and renders the entire factual answer itself. Freeform prose, invented IDs,
extra fields or incomplete JSON produce deterministic suggestions from the
saved work instead. They cannot contribute a countdown or deadline claim.
Unverified post-tool prose is buffered and never streamed to the UI. Ordinary
conversations without an executive-brief read retain their existing behavior.

Actual tool receipts are preserved for requests combining a brief with an
action. Selecting a suggested next step does not execute it. End-of-day
selections can ask the user about progress without claiming completion.
Routine reads use one captured as-of instant, so their displayed time and
countdowns refer to the same snapshot. Existing historical results remain
records of their original generations.

## Regression and acceptance evidence

Thirteen tests were added: eight renderer/source-validation cases, three agent
integration cases, one persisted routine/restart case and one live local-model
case. The two agent regressions first failed against the old response path,
which returned and streamed deliberately incorrect model statements. They pass
through the corrected path without trusting that prose.

Coverage includes the exact 12:43 → 14:00 failure, undated Friday titles, actual
saved due timestamps, spring/fall DST changes, sub-minute timing, all-day and
missing-end events, invalid source selections, extra model fields, end-of-day
progress questions, action receipts and persisted routine results after restart.

| Final check | Result |
| --- | --- |
| Full debug suite | **408 passed, 0 failed, 0 skipped** — 283 core + 125 app |
| Full optimized release suite | **406 passed, 0 failed, 0 skipped** — 283 core + 123 app |
| Live opt-ins | Enabled for the complete suites: running Splash model and installed Cua Driver |
| Live default routine prompt | Correct 1h 17m countdown, undated label and zero scheduled due-today tasks |
| Native acceptance | The rebuilt isolated app's saved routine completed at 13:03 IST; its 14:00 event displayed **Starts in 57 min**. Both undated commitments displayed **No scheduled due date**, with due-later-today count zero. |
| Scope | Existing Qwen3.6-35B-A3B model, Apple M5 Pro, macOS 26.6; synthetic provider data, no real provider writes |

Reproduction:

```sh
PUDDLE_LIVE_SPLASH=1 \
PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver \
  sh scripts/swift.sh test
PUDDLE_LIVE_SPLASH=1 \
PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver \
  sh scripts/swift.sh test -c release
```

Before/after logs, full suite logs, source/artifact hashes, native acceptance
facts and bundle verification are retained locally in
`build/briefing-fix-2026-10-30/`. Public signing/notarization and the other
installation/provider/OS acceptance gates are separate from this fix.
