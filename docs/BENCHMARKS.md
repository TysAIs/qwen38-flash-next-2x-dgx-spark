# Measured benchmarks

Every number here was produced by one harness against the live cluster, so rows are
comparable with each other. Method: c=1, thinking explicitly disabled, temperature 0,
n=5 trials per cell, 256-token completion budget. Full per-trial records are in the JSON
this document was generated from.

Hardware: 2× NVIDIA GB10 (DGX Spark), 128 GB each, TP=2, RoCE v2 over the ConnectX
interconnect. Image `v6-spinfix-hermes`, vLLM 0.30.0, K=5, 262,144 context, 64 seats,
`vm.compaction_proactiveness=0`.

## Decode — single stream

| workload | median tok/s | trials min–max | spread | distinct outputs | marker check |
|---|---|---|---|---|---|
| code generation | **72.69** | 65.39–75.22 | 9.83 | 1 | 5/5 |
| structured / JSON | **67.62** | 65.21–69.33 | 4.12 | 1 | 5/5 |
| prose | **50.2** | 47.06–52.53 | 5.47 | 4 | 5/5 |

**Code decodes 45% faster than prose on identical hardware.** That is not an engine
difference — it is draft acceptance. A code-shaped continuation is more predictable, so the
speculative drafter commits more tokens per engine step. This is the single most important
thing to know when reading any tok/s figure for this model: *the workload moves the number
more than the configuration does.*

## Prefill — prompt ingestion

| target | actual prompt tokens | median elapsed | rate |
|---|---|---|---|
| 400 | 400.0 | 0.292 s | ~1367.5 |
| 1,529 | 1529.0 | 0.599 s | ~2552.6 |
| 6,043 | 6043.0 | 1.496 s | ~4038.1 |

Prefill rate is reported as prompt-tokens divided by total request elapsed time, which is an
**upper bound** on true prefill speed — it includes time-to-first-token and decode. A
dedicated prefill measurement needs server-side TTFT separation.

## Reproducibility

| workload | distinct output hashes across 5 trials at temp 0 |
|---|---|
| code | 1 |
| structured | 1 |
| prose | 4 |

Code and structured output were byte-identical across every trial. **Prose was not** — it
produced 4 distinct outputs at
temperature 0. If you build a regression gate on byte-identical output, do not use prose as
the fixture: it will fail for reasons unrelated to your change.

## Marker checks

Each workload prompt ends with an instruction to open its response with a fixed token
(`CODE-OK`, `JSON-OK`, `PROSE-OK`). All three hit 5/5 in every cell, which confirms the
completions were real and complete rather than truncated or refused.

## What these numbers do not cover

- **Long context.** A 32k-token cell was attempted and reached only ~7.8k actual prompt
  tokens, so it is omitted rather than reported as a long-context figure. Prefill beyond
  ~6k needs a proper long-prompt fixture.
- **Concurrency.** These are c=1. Aggregate behaviour under concurrent load is a different
  measurement with a different harness, and the c=1 number does not predict it.
- **Thinking enabled.** All of the above has reasoning explicitly off. With reasoning on,
  completion tokens include reasoning tokens and the decode rate is not comparable.
