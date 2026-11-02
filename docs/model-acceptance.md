# Local-model acceptance matrix

Puddle supports local providers through the OpenAI-compatible API in
`Sources/PuddleCore/LocalInference.swift`. It does not ship model presets,
install runtimes, download weights, or gate connections by chip, RAM or OS.
The account-free workspace targets macOS 14+; model and hardware requirements
belong to the chosen provider.

We suggest [Splash](https://github.com/incoai/splash), but users can choose
any compatible local provider. No provider or model is certified merely by
appearing as an example. Test each advertised configuration independently.

| Capability | Required provider behavior |
| --- | --- |
| Discovery | `GET /v1/models` lists the selected chat model, or the first model when no ID is configured. |
| Conversation | `POST /v1/chat/completions` accepts portable chat parameters and returns complete replies and SSE streams. |
| Assistant tools | Model and server support function calling, required tool choice, tool results and complete streamed tool arguments. |
| Connection | A loopback HTTP(S) address, optional exact model ID and optional API key. Redirects remain rejected. |
| Context | Set server capacity and reasoning in the provider. Puddle honors reported capacity and its configured context budget. |

Record runtime version, resolved model revision/quantization, context capacity,
chip/RAM/OS, app commit/diff, download state and background workload for each run.

| Flow | Required evidence for each advertised configuration |
| --- | --- |
| Setup | New user starts a provider independently, enters its address/model/key and passes chat and required-tool probes. Validate wrong keys, unavailable models, offline connection, cancellation, stale probes and saved-connection migration. |
| Useful conversation | Human review of planning, writing and an underspecified request: useful answers, honest missing information, no unsupported action claims. Retain prompts and outputs. |
| Memory | Supported extract from the user's words; new-chat recall; inspect source, correct and forget; respect don't-remember and disabled learning. |
| Tasks | Correct title/time, exact review, decline without mutation, durable restart/completion. Check actual notification delivery separately. |
| Grounding | Read/cite a synthetic random source fact; recall old memory under bounded context; hostile email/document instructions cannot authorize another tool or reveal a private canary. |
| Failure/cancellation | Stop, profile switch and new chat reject late output; offline/tool errors are actionable; retries cannot replay completed/uncertain actions. |
| Browser | Only reading, reviewed URL navigation and scrolling are offered. Click/type remain unavailable; manual takeover is clear. |
| Resources | Record cold/warm start, peak app/runtime memory, first-token and total-response P50/P95, context size and tool counts with fixed synthetic prompts. Agree model-latency targets before measurement and retain raw samples/failures. |

When model testing is authorized, run the existing synthetic evaluations:

```sh
PUDDLE_LIVE_INFERENCE_ADDRESS=http://localhost:1234/v1 \
  sh scripts/swift.sh test --filter 'LiveEvaluationTests|NameMemoryTests|LocalInferenceTests.testLiveConfiguredLocalServer'
```

Set `PUDDLE_LIVE_INFERENCE_MODEL` for an exact model ID and
`PUDDLE_LIVE_INFERENCE_KEY` if the server requires a key. These tests do not establish first-time usability, provider delivery or hardware
coverage. Failed cases keep the configuration pending. Tool-template/context
changes require rerunning the affected flows.

The app-level acceptance flows also exercise encrypted persistence and restart,
memory correction/forgetting, exact reminder review and decline, task lookup and
completion, retry without duplication, cancellation and five warm planning
prompts. Capture their synthetic inputs/outputs and timing samples with:

```sh
PUDDLE_LIVE_INFERENCE_ADDRESS=http://localhost:1234/v1 PUDDLE_ACCEPTANCE_OUTPUT_DIRECTORY=/absolute/new/evidence-directory \
  sh scripts/swift.sh test --filter LiveWorkflowAcceptanceTests
```

The initial warm concise-response targets are first streamed text P95 <5 s and
total response P95 <30 s at an 8,192-token context budget. Five samples are a
regression check, not a population benchmark; measure cold start, runtime memory
and sustained load separately. User approval time is not model latency.

On 2 November 2026 these workflows and the existing live evaluations passed with
the owner's running `mlx-community/Qwen3.6-35B-A3B-4bit` on Apple M5 Pro/48 GiB,
macOS 26.6. [Evidence and limits](roadmap-acceptance-2026-11-02.md). That model is
one measured configuration; cross-provider compatibility and model quality remain pending.

Without coaching, ask a first-time user to set up local AI, get a useful day plan,
save/inspect/correct/forget a preference and capture/complete a task. Record
success, assistance needed and unclear next actions. Include keyboard-only and
minimum-window use; perform native VoiceOver/contrast/reduced-motion checks.
Resolve observed blockers before expanding specialist features.
