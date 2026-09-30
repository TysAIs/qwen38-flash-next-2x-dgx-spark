# Which engine should you run?

Two lanes serve the **same model on the same two Sparks**. Pick with one variable at launch:

```bash
ENGINE=vllm ./run.sh        # many simultaneous clients   (default)
ENGINE=tensorfold ./run.sh  # one agent at a time, faster per stream
```

Both lanes run either checkpoint — see [Checkpoints](#checkpoints) below.

## Measured head-to-head

Same hardware (2× DGX Spark, 128 GB each, GB10), same weights, same interconnect, both engines
measured in the same session on 2026-09-29. Method: quiet-gated forced-512, thinking off, n=5 clean
trials, warm-up discarded.

### Single stream (Method-D forced-512, n=5)

| engine | median | spread | cadence | acceptance | notes |
|---|---|---|---|---|---|
| TensorFold + ordered-FP32 reducer | **71.0** | 71.0–71.4 | 21.02 Hz | 3.384 | `token_sha` bit-identical across all trials |
| vLLM v6-spinfix | 67.7 | 64.5–73.0 | 19.88 Hz | 3.406 | 8.5 tok/s trial spread |

TensorFold's spread is 0.3 tok/s wide; vLLM's is 8.5. TensorFold is both faster *and* far more
reproducible at c=1.

### Concurrency (256 tokens, 16 cells, 0 failed / 0 unmeasured)

| streams | TensorFold agg | vLLM agg | TensorFold per-stream | vLLM per-stream |
|---|---|---|---|---|
| 1 | **94.0** | 64.2 | **94.0** | 64.2 |
| 4 | 81.1 | 132.4 | **80.7** | 39.2 |
| 8 | 80.0 | 210.5 | **82.8** | 30.2 |
| 16 | 79.9 | **249.3** | **82.7** | 29.5 |

Two different stories in one table:

- **Per stream, TensorFold wins everywhere** — +46% at c=1, rising to +180% at c=16. Every
  individual client is faster.
- **In aggregate, vLLM wins at concurrency** — it multiplies 4.02× from c=1 to c=16 while
  TensorFold is flat (0.85× on the code family). At c=16 the incumbent moves ~3× more total tokens
  per second.

## Why TensorFold does not scale yet

This is a property of the engine, not of the checkpoint or the kit. TensorFold's native two-node
concurrent path is **not finished upstream**. On this kit it has never completed a successful boot:
a dropped `self.e` attribute crashes construction for every `streams>1` start, and activating the
rank-0 lockstep barrier before warmup deadlocks into a 900-second rendezvous hang. Both are fixed
in `patches/`, and the 0.85× figure above is a placeholder from a scheduler that has not yet run
under load — **not** a measured ceiling. Per-stream throughput beating the incumbent by 105–180% at
every concurrency level is the signature of fast kernels behind a scheduler that does not overlap
requests.

Until that path is validated, treat the TensorFold lane as **single-stream / low-concurrency only**.
Do not put many agents behind it.

## Recommendation

| your situation | lane |
|---|---|
| one agent, or a few, latency-sensitive | **TensorFold** — 40% faster per stream, far tighter variance |
| many concurrent agents, throughput-bound | **vLLM** — the only lane that scales today |
| unsure | vLLM. It is the safe default and the one with the numbers behind it at every rung. |

## Checkpoints

Both lanes run either body. The output head (`hibrid48`, NVFP4) is identical either way.

| `CHECKPOINT=` | repo | notes |
|---|---|---|
| `stock` (default) | `myllmbox/Qwen3.8-Flash-Next-hibrid48` | public, no access agreement needed |
| `uncensored` | `myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored` | **gated** — accept the HF agreement, then `hf auth login` |

The uncensored body is the abliterated checkpoint: no refusals, no guardrails. It is for
research, red-teaming and private use behind your own moderation. It is not a model to point a
public deployment at, and this repo does not endorse that.

```bash
CHECKPOINT=uncensored ENGINE=tensorfold ./run.sh
```

## Reproducing the numbers

Everything above came from one harness so the two engines were always compared like-for-like. If you
change a knob, re-measure **both** lanes in the same session — a TensorFold number from one harness
against a vLLM number from another is how the recipe README's 106 tok/s and this repo's 67.7 tok/s
end up describing the same engine on the same hardware.

Throughput on this model is driven by **how many tokens each engine step commits** — a product of
draft acceptance and prompt fit — not by raw kernel speed. Cadence stays in a narrow 20.6–23.0 Hz
band across every configuration measured, while tokens-per-step swings 1.96× purely on prompt choice.
A prompt that drafts well measured 94.7 tok/s on TensorFold; one that drafts poorly measured 54.2 at
a *higher* cadence. Depth and confidence relocate throughput along a flat curve rather than lifting
it, which is why the 10-arm sweep behind these numbers accepted no winner.

> **On comparing acceptance across these two engines.** They do not report it on the same scale.
> vLLM publishes accepted-tokens per verify *step*; TensorFold publishes accepted **+ bonus** tokens
> per *round*, and the bonus token is exactly 1.0. Comparing 4.60 against 3.28 directly overstates
> the drafter gap by roughly 5×. Like-for-like the drafters are close to parity. TensorFold's real,
> demonstrated advantage is **cadence** — the ordered-FP32 reducer buys +8.6% engine steps/s with
> bit-identical output — and that is where its per-stream win comes from.

The one optimization that did win is the ordered FP32 reducer (`f32-reducer: triton`): 3.40× less
kernel time in the PLE/target-verify path, bit-identical output, +8.6% cadence. Set it to `python`
to reproduce the original chain.
