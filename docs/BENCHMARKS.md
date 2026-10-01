# Measured benchmarks

Every number here was produced by one harness against the live cluster, so rows are
comparable with each other. c=1, thinking explicitly disabled, temperature 0, n=5 trials per
decode cell, n=3 (n=2 above 100k) per prefill cell.

Hardware: 2× NVIDIA GB10 (DGX Spark), 128 GB each, TP=2, RoCE v2 over the ConnectX
interconnect. Image `v6-spinfix-hermes`, vLLM 0.30.0, K=5, 262,144 context, 64 seats.

## Decode — the number that matters

**Decode tok/s is the model's generation rate after the first token arrives.** It is the
figure to compare against any published tok/s, because it is what the engine is actually
doing while it writes.

| workload | decode tok/s | trials min–max | end-to-end | TTFT | marker |
|---|---|---|---|---|---|
| structured / JSON | **114.94** | 111.68–118.29 | 66.13 | 0.180 | 5/5 |
| code generation | **100.92** | 97.95–116.08 | 66.13 | 0.172 | 5/5 |
| prose | **54.64** | 52.98–59.64 | 50.13 | 0.172 | 5/5 |

## Why there are two columns

They answer different questions and both are real:

- **decode tok/s** — `completion_tokens / (total − TTFT)`. The engine's generation rate.
- **end-to-end tok/s** — `completion_tokens / total`. What a caller waits for, including
  prefill and time-to-first-token.

**Do not compare an end-to-end figure against a decode-only figure.** With ~0.17 s TTFT,
that is most of the time on a short answer and negligible on a long one: structured output
is ~115 tok/s in the decode phase but ~66 tok/s end-to-end, because a 30-token answer
spends more time starting than generating. Same run, two correct numbers.

## Prefill — measured as prompt tokens ÷ TTFT

Reply budget is 16 tokens, so decode contributes almost nothing to the elapsed time. Each
trial uses a **unique prompt**; reusing text would let the prefix cache serve the repeat and
report a prefill rate several times too high.

| prompt tokens | TTFT per trial (s) | median TTFT | prefill tok/s |
|---|---|---|---|
| 232 | 0.15 / 0.18 / 0.19 | 0.18 | **1,307** |
| 832 | 0.32 / 0.33 / 0.32 | 0.32 | **2,567** |
| 3,232 | 1.01 / 0.98 / 1.00 | 1.00 | **3,217** |
| 12,832 | 3.88 / 3.88 / 3.88 | 3.88 | **3,308** |
| 25,632 | 7.71 / 7.70 / 7.70 | 7.70 | **3,328** |
| 51,232 | 15.50 | 15.50 | **3,306** |
| 102,432 | 31.82 | 31.82 | **3,219** |
| 200,033 | 65.11 | 65.11 | **3,072** |

Prefill climbs quickly and then plateaus: the first token costs fixed startup, and beyond a
few hundred tokens the rate sits at **~3,300 tok/s**, holding to 200k. Measured TTFT is
linear in prompt length across the whole range, which is the check that the numbers are real
prefill and not a cached shortcut — a cache hit would have flattened TTFT as size grew.

## Concurrency ladder — measured

Workload: code generation, 256-token budget, thinking off, temperature 0, n=3 trials per
rung. All streams of a rung launch from one barrier so they genuinely overlap. Per-stream
figures are decode-only (tokens after the first), so queueing does not distort them.

Aggregate tok/s is total completion tokens over the wall-clock window of the whole rung — the
cluster's real throughput, not a sum of averages.

| concurrent | aggregate tok/s | vs c=1 | per-stream | fairness spread | median TTFT | errors |
|---|---|---|---|---|---|---|
| 1 | **70.4** | 1.00× | 98.5 | 0.0 | 0.137 | 0 |
| 2 | **122.0** | 1.73× | 90.3 | 0.1 | 0.156 | 0 |
| 4 | **204.0** | 2.90× | 75.4 | 0.1 | 0.208 | 0 |
| 8 | **345.6** | 4.91× | 63.5 | 0.1 | 0.251 | 0 |
| 16 | **469.2** | 6.66× | 45.1 | 0.2 | 0.396 | 0 |
| 32 | **564.5** | 8.02× | 28.4 | 0.2 | 0.702 | 0 |
| 48 | **595.3** | 8.46× | 20.6 | 0.1 | 1.041 | 0 |
| 64 | **636.9** | 9.05× | 16.9 | 0.1 | 1.349 | 0 |

**Saturates around c=32.** Aggregate climbs 9.05× from one stream to 64, but the curve
flattens hard past 32: c=32→64 buys only 13% more aggregate throughput while halving
per-stream speed (28.4 → 16.9 tok/s) and doubling TTFT (0.70 → 1.35 s).

That is the number to design around. Adding agents past ~32 is close to free in aggregate
terms but expensive in latency — each one gets about half the speed. For an agent fleet, the
useful ceiling is around 32 concurrent streams; beyond that you are queueing.

**Fairness holds.** Per-stream spread stays at ~0.1 tok/s even at c=64, so the scheduler
treats concurrent streams evenly — no stream is starved while another runs fast.

**Zero errors across every rung, and all 525 completions opened with the required
`CODE-OK` marker**, so no result here includes a truncated, failed or refused request.

## Reproducibility

| workload | distinct output hashes across 5 trials at temp 0 |
|---|---|
| code | 1 |
| structured | 1 |
| prose | 5 |

Code and structured output were byte-identical across every trial. **Prose was not** — it
produced 5 distinct outputs at temperature 0. If you build a regression gate on byte-identical
output, do not use prose as the fixture: it will fail for reasons unrelated to your change.

## Marker checks

Each decode prompt ends with an instruction to open its response with a fixed token
(`CODE-OK`, `JSON-OK`, `PROSE-OK`). All hit 5/5, which confirms the completions were real
and complete rather than truncated or refused.

## What these numbers do not cover

- **Concurrency.** These are c=1. Aggregate behaviour under concurrent load is a different
  measurement and the c=1 number does not predict it.
- **Thinking enabled.** All rows have reasoning explicitly off. With reasoning on, completion
  tokens include reasoning tokens and decode rate is not comparable.
- **Prefill beyond 200k.** Verified to 200,033 tokens; not pushed to the 262,144 limit.
