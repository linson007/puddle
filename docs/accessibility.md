# Accessibility review

The November 2026 pass covers Today, tasks, chat, sidebar navigation, settings and
meeting capture. Icon-only buttons/links expose action names, including dismiss,
refresh, clear search, task completion/priority, row menus, sidebar pins, voice
input, send, calendar period navigation and the menu-bar item. Decorative
connection dots are hidden. Custom navigation exposes its destination, selected
state and stable identifiers. Task controls expose completion/priority values;
meeting capture exposes its status and stop/review behavior without relying on
color. Text editors have explicit names.

The sidebar, task actions and capture controls use native Button/Picker elements.
Existing command shortcuts include Command-K search, Command-N conversation,
Command-Shift-N quick capture and Command-Shift-M voice input. Search supports
arrow selection and Return. Enable macOS Keyboard Navigation when reviewing full
Tab traversal, including buttons and menus.

## Reproducible native review

Use synthetic data only:

```sh
make build
open -n build/Puddle.app --args --demo
```

1. Enable VoiceOver with Command-F5. Navigate Today and the sidebar: confirm
   destinations, selected state, More expansion and pin actions are announced.
2. Open Tasks. Tab through capture, filters, completion, priority and actions.
   Activate with Space; check changed state and visible keyboard focus.
3. Open chat. Read the message field and voice/send names; send synthetic text,
   copy a reply, then open Command-K and navigate results with arrows/Return.
4. Open Settings with Command-comma. Read control names and selected values;
   cancel editors with Escape. Check long text and Turkish at minimum window size.
5. Open a meeting note. Inspect source selection, start/stop/review controls,
   status, notes and transcript labels. Demo intentionally disables audio capture;
   live hardware/permission behavior needs a separate explicit test.

Fixture tests establish store behavior, not spoken VoiceOver output. The native
accessibility-tree/keyboard observations for this change are recorded with the
PR verification. A full spoken VoiceOver pass and real audio permission review
remain manual acceptance checks; do not infer them from a passing build.

## Observed in the isolated November 2026 demo build

On macOS 26.6, the native accessibility tree exposed sidebar destinations and
selected values, named chat/voice/send controls, labeled settings fields and
meeting source/start controls. Keyboard task capture with Return created a
synthetic task; completing it exposed `Completed` and `Reopen` in the tree.
Command-K, search and Return opened Meetings. The packaged Turkish launch
rendered translated navigation and control labels. These observations used a
separately identified demo bundle, without touching the personal workspace.
