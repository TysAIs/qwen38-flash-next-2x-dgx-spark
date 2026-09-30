# Two engines, one cluster. Pick the lane with ENGINE= at launch; nothing else changes.
#
#   ENGINE=vllm        ./run.sh    -> the vLLM lane (mature, scales under concurrency)
#   ENGINE=tensorfold  ./run.sh    -> the TensorFold lane (faster per stream, TP2 not yet concurrent-scaled)
#
# The default is the lane in DEFAULT_ENGINE below. Everything machine-specific (boxes, interfaces,
# HCAs) stays in cluster.env, written by setup.sh and gitignored. Everything model-side lives in
# the recipes/ file named by ENGINE.

ENGINE="${ENGINE:-vllm}"

# The lane's recipe file. recipes/vllm.yaml and recipes/tensorfold.yaml are the ONLY model-side
# configuration; the top-level recipe.yaml is kept as a symlink target for backwards compatibility.
RECIPE_FILE="recipes/${ENGINE}.yaml"

# Checkpoint lane. STOCK is the public calibrated checkpoint anyone can pull without an access
# agreement. UNcensored is the abliterated body: no refusals, no guardrails, research /
# red-teaming / private use behind your own moderation. It is GATED on Hugging Face — you must
# accept its agreement and `hf auth login` (or export HF_TOKEN) before run.sh can fetch it.
#
# Both lanes run the same stack and the same hibrid48 output head; only the body differs.
CHECKPOINT="${CHECKPOINT:-stock}"   # stock | uncensored

resolve_checkpoint() {  # -> prints the HF repo id, or exits with guidance
  case "${CHECKPOINT:-stock}" in
    stock)      printf '%s' "myllmbox/Qwen3.8-Flash-Next-hibrid48" ;;
    uncensored) printf '%s' "myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored" ;;
    *) echo "✗ CHECKPOINT must be 'stock' or 'uncensored' (got '${CHECKPOINT:-}')" >&2; exit 1 ;;
  esac
}

served_name() {  # -> the --served-model-name clients pass in requests
  case "${CHECKPOINT:-stock}" in
    stock)      printf '%s' "qwen3.8-flash-next" ;;
    uncensored) printf '%s' "qwen3.8-flash-next-uncensored" ;;
  esac
}

# Kept for callers that want the canonical name regardless of CHECKPOINT.
stock_served_name() { printf '%s' "qwen3.8-flash-next"; }
