# Local-model acceptance matrix

This contract covers the current setup presets in `Sources/PuddleCore/LocalAISetup.swift`.
It defines planned coverage, without certifying model quality or treating a prior
run with another model as acceptance. Verify the existing core before adding presets.

| Preset | Configured model | App setup eligibility | Acceptance |
| --- | --- | --- | --- |
| Compact | `unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS` | Apple M3+; macOS 26.4+; ≥24 GiB memory; 20 GiB disk headroom | Pending actual preset runs and first-time-user review. |
| Balanced | `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M` | Apple M3+; macOS 26.4+; ≥36 GiB memory; 26 GiB disk headroom | Pending actual preset runs and first-time-user review. |

The account-free workspace targets macOS 14+. Guided Splash installation has
the additional eligibility checks above; they are not measured performance.
Record runtime version, resolved model revision/quantization, context capacity,
chip/RAM/OS, app commit/diff, download state and background workload for each run.

| Flow | Required evidence for each advertised configuration |
| --- | --- |
| Setup | New user installs/downloads without a terminal; chat and required-tool probes pass; cancellation, interrupted download and cached offline restart work. |
| Useful conversation | Human review of planning, writing and an underspecified request: useful answers, honest missing information, no unsupported action claims. Retain prompts and outputs. |
| Memory | Supported extract from the user's words; new-chat recall; inspect source, correct and forget; respect don't-remember and disabled learning. |
| Tasks | Correct title/time, exact review, decline without mutation, durable restart/completion. Check actual notification delivery separately. |
| Grounding | Read/cite a synthetic random source fact; recall old memory under bounded context; hostile email/document instructions cannot authorize another tool or reveal a private canary. |
| Failure/cancellation | Stop, profile switch and new chat reject late output; offline/tool errors are actionable; retries cannot replay completed/uncertain actions. |
| Browser | Only reading, reviewed URL navigation and scrolling are offered. Click/type remain unavailable; manual takeover is clear. |
| Resources | Record cold/warm start, peak app/runtime memory, first-token and total-response P50/P95, context size and tool counts with fixed synthetic prompts. Agree model-latency targets before measurement and retain raw samples/failures. |

When model testing is authorized, run the existing synthetic evaluations:

```sh
PUDDLE_LIVE_SPLASH=1 sh scripts/swift.sh test --filter 'LiveEvaluationTests|NameMemoryTests|LocalAISetupTests.testLiveSetupAgainstRunningSplash'
```

These tests do not establish first-time usability, provider delivery or hardware
coverage. Failed cases keep the configuration pending. Tool-template/context
changes require rerunning the affected flows.

The app-level acceptance flows also exercise encrypted persistence and restart,
memory correction/forgetting, exact reminder review and decline, task lookup and
completion, retry without duplication, cancellation and five warm planning
prompts. Capture their synthetic inputs/outputs and timing samples with:

```sh
PUDDLE_LIVE_SPLASH=1 PUDDLE_ACCEPTANCE_OUTPUT_DIRECTORY=/absolute/new/evidence-directory \
  sh scripts/swift.sh test --filter LiveWorkflowAcceptanceTests
```

The initial warm concise-response targets are first streamed text P95 <5 s and
total response P95 <30 s at an 8,192-token context budget. Five samples are a
regression check, not a population benchmark; measure cold start, runtime memory
and sustained load separately. User approval time is not model latency.

On 2 November 2026 these workflows and the existing live evaluations passed with
the owner's running `mlx-community/Qwen3.6-35B-A3B-4bit` on Apple M5 Pro/48 GiB,
macOS 26.6. [Evidence and limits](roadmap-acceptance-2026-11-02.md). That model is
different from the compact and balanced presets above, which remain pending.

Without coaching, ask a first-time user to set up local AI, get a useful day plan,
save/inspect/correct/forget a preference and capture/complete a task. Record
success, assistance needed and unclear next actions. Include keyboard-only and
minimum-window use; perform native VoiceOver/contrast/reduced-motion checks.
Resolve observed blockers before expanding specialist features.
