# Measured benchmarks

Every number here was produced by one harness against the live cluster, so rows are
comparable with each other. c=1, thinking explicitly disabled, temperature 0, n=5 trials per
cell, 512-token completion budget.

Hardware: 2× NVIDIA GB10 (DGX Spark), 128 GB each, TP=2, RoCE v2 over the ConnectX
interconnect. Image `v6-spinfix-hermes`, vLLM 0.30.0, K=5, 262,144 context, 64 seats.

## Decode — the number that matters

**Decode tok/s is the model's generation rate after the first token arrives.** It is the
figure to compare against any published tok/s, because it is what the engine is actually
doing while it writes.

| workload | decode tok/s | trials min–max | end-to-end | TTFT | marker |
|---|---|---|---|---|---|
| structured / JSON | **114.94** | 111.68–118.29 | 66.13 | 0.1798 | 5/5 |
| code generation | **100.92** | 97.95–116.08 | 66.13 | 0.172 | 5/5 |
| prose | **54.64** | 52.98–59.64 | 50.13 | 0.1721 | 5/5 |

## Why there are two columns

They answer different questions and both are real:

- **decode tok/s** — `completion_tokens / (total − TTFT)`. The engine's generation rate.
- **end-to-end tok/s** — `completion_tokens / total`. What a caller waits for, including
  prefill and time-to-first-token.

**Do not compare an end-to-end figure against a decode-only figure.** On this stack TTFT is
~0.17 s, which is a large fraction of a short answer and a negligible fraction of a long one:
structured output is ~115 tok/s in the decode phase but ~66 tok/s end-to-end, because a
30-token answer spends more time starting than generating. The same run, two correct
numbers.

## Prefill — prompt ingestion

| target | actual prompt tokens | median elapsed | rate (upper bound) |
|---|---|---|---|
| 400 | 400.0 | 0.32 s | ~1252.0 tok/s |
| 1,529 | 1529.0 | 0.603 s | ~2537.8 tok/s |
| 6,043 | 6043.0 | 1.502 s | ~4023.3 tok/s |

These are `prompt_tokens / total elapsed`, so they are **upper bounds** on true prefill
speed — they include decode of the 64-token reply. A true prefill number needs TTFT
subtracted, which is what the decode column already accounts for.

## Reproducibility

| workload | distinct output hashes across 5 trials at temp 0 |
|---|---|
| code | 1 |
| structured | 1 |
| prose | 5 |

Code and structured output were byte-identical across every trial. **Prose was not** — it
produced 5 distinct outputs at temperature 0. If you
build a regression gate on byte-identical output, do not use prose as the fixture: it will
fail for reasons unrelated to your change.

## Marker checks

Each prompt ends with an instruction to open its response with a fixed token (`CODE-OK`,
`JSON-OK`, `PROSE-OK`). All hit 5/5 in every cell, which confirms the completions were real
and complete rather than truncated or refused.

## What these numbers do not cover

- **Long context.** A 32k-token cell reached only ~7.8k actual prompt tokens and is omitted
  rather than reported as a long-context figure.
- **Concurrency.** These are c=1. Aggregate behaviour under concurrent load is a different
  measurement and the c=1 number does not predict it.
- **Thinking enabled.** All rows have reasoning explicitly off. With reasoning on, completion
  tokens include reasoning tokens and decode rate is not comparable.
