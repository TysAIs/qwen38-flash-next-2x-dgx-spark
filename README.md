# Qwen3.8-Flash-Next on 2× DGX Spark — vLLM and TensorFold lanes

Serve the same checkpoint on the same pair of Sparks with **either engine**. One repository, two
lanes, one variable at launch.

```bash
ENGINE=vllm        ./run.sh    # many simultaneous clients  (default — this is the fleet lane)
ENGINE=tensorfold  ./run.sh    # one agent at a time, faster per stream
```

**→ [docs/ENGINES.md](docs/ENGINES.md) is the decision document.** Read it before choosing; it has
the measured head-to-head and says which lane fits which workload.

---

## The short version

| | vLLM lane | TensorFold lane |
|---|---|---|
| single stream | 67.7 tok/s | **71.0 tok/s** (94.7 on a drafting-friendly prompt) |
| **aggregate at c=16** | **249.3 tok/s** | 79.9 tok/s |
| scales with concurrency | **4.02×** from c=1 to c=16 | flat (0.85×) |
| per-stream at c=16 | 29.5 tok/s | **82.7 tok/s** |
| native two-node concurrency | works | **not finished upstream** |
| **use it for** | **many agents, fleet serving** | one agent, latency-sensitive |

Both lanes run either checkpoint and produce **identical output for identical input** — verified by
`token_sha`, a hash of the emitted tokens, matching across every trial.

The two lanes cannot run at the same time: each box has ~120 GB and one engine takes ~99 GB. Pick
one per boot. A boot is about four minutes.

## Layout — read this before editing anything

```
run.sh setup.sh stop.sh view.sh tune-host.sh   the kit (unchanged from the original recipe)
lib.sh                                         shared helpers; rkey/rsection read $RECIPE_FILE
lib-lanes.sh                                   ENGINE + CHECKPOINT resolution — the only place to
                                               add a new lane or checkpoint

recipes/vllm.yaml                              ALL model-side config for the vLLM lane
recipes/tensorfold.yaml                        ALL model-side config for the TensorFold lane
recipe.yaml                                    backwards-compatible alias for the vLLM lane
                                               (what you get if you set no ENGINE)

patches/tensorfold-qwen4exp-ct-tp2.patch       TensorFold 0.5.0 + the qwen4_exp compressed-tensors
                                               port and native TP2. 20 files, 1746 insertions.
                                               Apply to ashhart/TensorFold @ 9cd52ab.
patches/tensorfold-ordered-f32-reducer.patch   the accepted optimization: fused Triton FP32
                                               reducer for the PLE/target-verify path. Bit-identical
                                               output, +8.6% engine steps/s.

docs/ENGINES.md                                the comparison, the tradeoff, how to reproduce it
cluster.env                                    YOUR machines — written by setup.sh, gitignored
```

**The rule that keeps this from drifting:** all model-side configuration lives in
`recipes/<engine>.yaml` and nowhere else. `run.sh` never hardcodes a model, an image, a port or a
flag. Adding a third engine means adding one YAML file and one line in `lib-lanes.sh` — no changes
to the kit scripts.

## Checkpoints

Both lanes run either body. The output head (`hibrid48`, NVFP4) is identical either way.

| `CHECKPOINT=` | repo | gated? |
|---|---|---|
| `stock` (default) | `myllmbox/Qwen3.8-Flash-Next-hibrid48` | no |
| `uncensored` | `myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored` | **yes** — accept the HF agreement, then `hf auth login` |

`CHECKPOINT` overrides both what gets downloaded and the name clients must request, so it is
impossible to pull stock weights and serve them under the uncensored name.

The uncensored body is the abliterated checkpoint — no refusals, no guardrails. Research,
red-teaming and private use behind your own moderation. Not a model to point a public deployment at.

```bash
CHECKPOINT=uncensored ENGINE=vllm ./run.sh
```

## Setup

```bash
./setup.sh                  # finds the second box, the interconnect, opens the firewall
./setup.sh user@203.0.113.10   # or name the worker explicitly
```

`setup.sh` writes `cluster.env` — your boxes, interfaces and HCAs. That file is gitignored and is
the only machine-specific thing in the kit. Everything else is portable.

Then `./run.sh`, and watch it come up with `./view.sh` (throughput, acceptance, RDMA proof).
`./stop.sh` stops both boxes; weights and caches stay, so a restart is fast.

## Requirements

- Two DGX Sparks (or any two 128 GB unified-memory boxes on a RoCE-capable interconnect), NVIDIA
  Container Toolkit, and a passwordless ssh path between them.
- ~99 GB per box for the weights. `run.sh` downloads once and syncs to the worker.
- ~4 minutes to boot.

## Honest status of the TensorFold lane

TensorFold is genuinely the faster engine **per stream** and its advantage is real and bit-exact.
Its native two-node *concurrent* path is not finished upstream and does not yet scale in aggregate;
on this kit it has never completed a successful concurrent boot. The 0.85× figure is a placeholder
from a scheduler that has not yet run under load, **not** a measured ceiling — the per-stream win of
+46% to +180% at every concurrency level is the signature of fast kernels behind a scheduler that
does not overlap requests.

Treat the TensorFold lane as single-stream / low-concurrency until that path is validated. **Do not
put a fleet behind it.** The vLLM lane is the safe default and the one with numbers behind it at
every rung.

## License and provenance

The kit scripts, `recipes/vllm.yaml` and this README are the original recipe work. TensorFold is
MIT-licensed (see its `LICENSE`); the patches in `patches/` are contributions against
[ashhart/TensorFold](https://github.com/ashhart/TensorFold) @ `9cd52ab` (0.5.0) and carry no
third-party code. The model weights are under the Qwen Community License 1.0 — read it before
commercial use (see `README` in the model repo).
