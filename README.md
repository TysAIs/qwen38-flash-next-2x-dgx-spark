# Qwen3.8-Flash-Next on 2× DGX Spark

Serve **Qwen3.8-Flash-Next** on a pair of DGX Sparks over a single RDMA link. One recipe file,
three commands, about four minutes to boot.

```bash
./setup.sh          # find the second box, the interconnect, open the firewall
./run.sh            # boot the cluster
./view.sh           # live throughput, acceptance, RDMA proof
./stop.sh           # stop both boxes (weights and caches stay)
```

## What this is

| | |
|---|---|
| checkpoint | `Qwen3.8-Flash-Next-hibrid48` — and `-uncensored`, switchable in one line |
| engine | vLLM 0.30.0 |
| topology | TP=2 across two GB10 boxes, RoCE v2 over the ConnectX link |
| context | 262,144 tokens |
| KV pool | 2.5M pooled tokens (41 GB per box, BF16) |
| seats | 64 concurrent |

Both boxes need ~99 GB of weights. The kit downloads once and syncs to the worker at the same
absolute path.

## Measured performance

Measured on this exact stack — 2× GB10, RDMA, K=5, `vm.compaction_proactiveness=0`. One
harness, n=5 per cell, thinking off, temperature 0, full trial lists in
[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).

**Decode, single stream (c=1, 512-token budget)**

Decode tok/s is the generation rate *after* the first token — the engine's real writing
speed. End-to-end is what a caller waits for. Both are reported because they differ a lot on
short answers.

| workload | decode tok/s | end-to-end | TTFT |
|---|---|---|---|
| structured / JSON | **114.9** | 66.1 | 0.18 s |
| code generation | **100.9** | 66.1 | 0.17 s |
| prose | **54.6** | 50.1 | 0.17 s |

**Prefill** — prompt tokens ÷ time-to-first-token, with a 16-token reply so decode
contributes almost nothing. Unique prompt per trial, so the prefix cache cannot flatter it.

| prompt tokens | TTFT | prefill tok/s |
|---|---|---|
| 232 | 0.18 s | 1,307 |
| 3,232 | 1.00 s | 3,217 |
| 25,632 | 7.70 s | 3,328 |
| 102,432 | 31.82 s | 3,219 |
| 200,033 | 65.11 s | 3,072 |

Prefill plateaus at **~3,300 tok/s** and holds there to 200k tokens, with TTFT linear in
prompt length across the whole range.

## Two checkpoints

| `model:` in `recipe.yaml` | what it is | gated |
|---|---|---|
| `Qwen3.8-Flash-Next-hibrid48` (default) | the calibrated base model | no |
| `Qwen3.8-Flash-Next-hibrid48-uncensored` | the abliterated body — no refusals, no guardrails | **yes** |

To switch, comment the active `model:` line and uncomment the other, then `./run.sh`. The
uncensored body is gated on Hugging Face: accept its agreement, then `hf auth login` (or
export `HF_TOKEN`) before `run.sh` can fetch it. It is intended for research, red-teaming and
private use behind your own moderation — not for a public deployment.

## Why this configuration

Two of these we measured on this stack. The rest are inherited from the upstream recipe's
own measurements and are marked accordingly — we have not re-verified them, so treat them as
a starting point rather than a claim from us.

**Measured here:**

- **`max-num-seqs: 64`** — 64 seats. With K=5 each running request pins more pool at admission
  (the model's recurrent state plus the longer draft ring), so 64 long answers fill the pool
  after ~3 minutes and requests begin to queue. 48 keeps more headroom if your answers are long.
- **`kv-cache-memory: 41000000000`** — 41 GB per box. Unified memory is shared with the weights
  and the compile cache on a 128 GB box; do not raise this casually.

**Inherited from upstream (not re-measured here):**

- **`NCCL_MAX_NCHANNELS: 4`** — NCCL otherwise builds 64 channels and splits every large
  message across all of them. Without GPUDirect RDMA on the GB10 each piece is copied through
  host memory. Upstream reports +10% tok/s at 32 concurrent, +7% at 64, unchanged at 1.
- **`MBX_PLE_REPLICATE: "0"`** — half the n-gram table per box, exchanged per gather. Upstream
  reports the same speed as the full table on vLLM 0.30, freeing 13.4 GB per box, which is what
  pays for the 41 GB KV pin.
- **`gdn-prefill-backend: flashinfer`** — upstream reports about +5% prefill from 8k to 256k
  tokens.
- **`async-scheduling: true`** — upstream reports +9–12% at c=4–5, neutral at 8+.

If you change any of these, re-measure the decode and prefill tables above before quoting a
figure.

## Machine-specific files

`setup.sh` writes `cluster.env` — your boxes, interfaces and HCAs. It is gitignored and is the
only machine-specific thing here. Everything else is portable.

## What's in the image

`myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix-hermes` — vLLM 0.30.0 plus:

- the NVFP4 n-gram table on 0.30's embedding plugin
- the 4-bit output head (`hibrid48`) — stock 0.30 loads neither
- the fused multi-step MTP draft (= vllm-project/vllm#58449)
- QSA rope clamp, loader page-cache drop, MoE/head quant config, draft-scale knob
- **GB10 CPU spin-wait fix** — vLLM's shared-memory broadcast busy-loop sleeps 1 s per poll
  when idle, which pins a core at 100% and heats the SoC, costing memory bandwidth shared
  with the GPU. One-line `busy_loop_s` change, no throughput effect.
- **Hermes chat-protocol fix** — Hermes sends reasoning as a top-level
  `{"reasoning": {"enabled", "effort"}}` object, which stock 0.30 ignores; it only read
  `reasoning_effort`. So an explicit "thinking off" left the model thinking, and an omitted
  temperature fell back to the checkpoint default (1.0, full sampling) instead of greedy.
  Both are correctness bugs, verified: `reasoning: {enabled: false}` now produces 0 reasoning
  tokens and `{enabled: true}` still produces them.

Build it with `docker build -t myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix-hermes
docker/spinfix-hermes/`, then ship it to the worker. The Dockerfile **fails the build** if the
protocol fix does not apply cleanly, so an image can never claim a fix it does not have.

## Reproducing the numbers

One harness, both arms, same session. If you change a knob, re-measure the same way — a number
from one harness compared against a number from another is how this README previously claimed
106 tok/s while a same-stack measurement read far lower. Measuring tok/s as
`completion_tokens / total_elapsed` charges the request for prefill and time-to-first-token;
on a 30-token answer that is most of the time. The harness here streams and reports decode
and end-to-end separately.

Throughput here is governed by how many tokens each step commits, not raw kernel speed: the
engine's step cadence stays in a narrow ~20–21 Hz band while tokens-per-step swings roughly 2×
on prompt fit. Depth and confidence *relocate* throughput along that flat curve rather than
raising it — a 10-arm sweep over depth 0/1/2/3/5/8/12 × confidence 0/.30/.50/.80 produced no
winning arm. Do not spend time re-running it.

## Layout

```
run.sh setup.sh stop.sh view.sh tune-host.sh   the kit
lib.sh                                         shared helpers; rkey/rsection read recipe.yaml
recipe.yaml                                    ALL model-side configuration
recipes/vllm.yaml                              the same config, lane-named
docs/VLLM-LANE-REFERENCE.md                    the long-form reference
docs/BENCHMARKS.md                             measured results with full trial lists
cluster.env                                    YOUR machines — written by setup.sh, gitignored
```

## Requirements

- Two DGX Sparks (or any two 128 GB unified-memory boxes on a RoCE-capable interconnect), NVIDIA
  Container Toolkit, and a passwordless ssh path between them.
- ~99 GB per box for the weights. `run.sh` downloads once and syncs to the worker.
- ~4 minutes to boot.

## License and provenance

The weights are under the Qwen Community License 1.0 — read it before commercial use (display
requirements above 100M MAU / $20M revenue). See the model repo. vLLM is Apache-2.0; the
patches in this image are contributions against vLLM 0.30.0.
