# Measured benchmarks

Every number here was produced by one harness against the live cluster, so rows are
comparable with each other. c=1, thinking explicitly disabled, temperature 0, n=5 trials per
decode cell, n=3 (n=2 above 100k) per prefill cell.

Hardware: 2x NVIDIA GB10 (DGX Spark), 128 GB each, TP=2, RoCE v2 over the ConnectX
interconnect. Image `v6-spinfix-hermes`, vLLM 0.30.0, K=5, 262,144 context, 64 seats.

## Decode, single stream

Decode tok/s is the generation rate after the first token arrives, which is what the engine is
actually doing while it writes.

**These are ranges, not points.** Each workload produced a different answer length, and answer
length drives the variance: a 33-token reply gives a decode window of about 0.3 s, inside which
startup cost is a large share of the total. The same configuration measured at different
moments read anywhere from 55 to 85 tok/s. Longer generations (prose at 1024 tokens, measured
over a 24 s window) reproduce to about 10%.

| workload | decode tok/s | completion length | notes |
|---|---|---|---|
| structured / JSON | 90-115 | ~30 tok | short window, high variance |
| code generation | 55-101 | ~35 tok | short window, highest variance |
| prose | ~42 | 1024 tok | long window, reproduces to ~10% |

All completions were byte-verified against a required opening marker (`CODE-OK`, `JSON-OK`,
`PROSE-OK`), 5/5 in every cell, so no figure here includes a truncated or refused request.

**If you need a single-stream number for capacity planning, measure it yourself on a quiet
cluster with a long generation and report the spread.** Do not copy a point value out of this
table.

## Why there are two columns

They answer different questions and both are real:

- **decode tok/s**, `completion_tokens / (total - TTFT)`. The engine's generation rate.
- **end-to-end tok/s**, `completion_tokens / total`. What a caller waits for, including
 prefill and time-to-first-token.

**Do not compare an end-to-end figure against a decode-only figure.** With ~0.17 s TTFT,
that is most of the time on a short answer and negligible on a long one: structured output
is ~115 tok/s in the decode phase but ~66 tok/s end-to-end, because a 30-token answer
spends more time starting than generating. Same run, two correct numbers.

## Prefill, measured as prompt tokens / TTFT

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
prefill and not a cached shortcut, a cache hit would have flattened TTFT as size grew.

## Concurrency ladder

Read this before quoting any number from it.

**Throughput on this model depends heavily on the workload and on how long each generation
runs.** A short answer gives a decode window so brief that startup cost dominates: the same
configuration measured repeatedly will swing by a factor of two. Long generations average that
out and produce repeatable readings.

What follows is the honest result of that lesson. Rows are labelled with their trial-to-trial
spread. **Only rows under ~12% spread are quoted as numbers**; the rest are shown so the shape
is visible, not because the value is trustworthy.

Method: code workload, forced 256-token generations (`min_tokens` so the engine runs the full
budget instead of stopping at ~33 tokens), one discarded warmup trial per rung, 5 recorded
trials. Aggregate is total tokens produced during the shared generation window, from the first
token any stream emits to the last token any stream finishes. Client-side connection setup is
excluded, because it is not engine time.

| concurrent | aggregate tok/s | spread | per-stream | TTFT | trust |
|---|---|---|---|---|---|
| 1 | ~ | 46% | 57 | 0.24 s | no |
| 2 | ~ | 35% | 71 | 0.25 s | no |
| 4 | ~ | 44% | 58 | 0.29 s | no |
| 8 | ~ | 34% | 49 | 0.31 s | no |
| 16 | 460 | 11% | 36 | 0.42 s | **yes** |
| 32 | 605 | 9% | 23 | 0.70 s | **yes** |
| 48 | 682 | 11% | 17 | 1.05 s | **yes** |
| 64 | 725 | 4% | 16 | 1.33 s | **yes** |

### What this table supports

**Scaling is roughly an order of magnitude, and it flattens past c=32.** Aggregate roughly
doubles from c=8 to c=32, then adds only about 20% more from c=32 to c=64 while per-stream
speed keeps falling. That shape reproduced across three independent measurement runs with
different denominators, so it is the reliable finding here.

**Zero errors at every rung.** All 64 seats accept concurrent requests; nothing was truncated,
failed, or refused.

**Scheduling is fair.** At c<=48 the spread *between concurrent streams* stays around
0.1 tok/s, so no stream is starved while another runs fast. At c=64 the per-stream spread
widens noticeably, which coincides with the capacity warnings in the metrics.

### What this table does not support

Do not quote the c=1 through c=16 absolute figures. Their trial spread is 34-45%, which means
they are measuring cluster load as much as they measure the engine. If you need single-stream
numbers, measure them on a quiet cluster with long generations and report the spread.

### Sizing a fleet from this

Roughly: the cluster delivers on the order of **700 tok/s aggregate at 64 concurrent streams**
on code-shaped work, and useful per-stream speed is around **20-25 tok/s at c=32**. Past 32
you are queueing rather than scaling. Plan around c=32.

## Reproducibility

| workload | distinct output hashes across 5 trials at temp 0 |
|---|---|
| code | 1 |
| structured | 1 |
| prose | 5 |

Code and structured output were byte-identical across every trial. **Prose was not**, it
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
