#!/bin/bash
# ─── Example training job (PBS Pro: wheat / ERDC DSRC) ───
#
# TEMPLATE: the launch lines at the bottom run examples/train_smoke.py — a tiny
# synthetic-data training script — so a fresh clone's `make submit`/`make smoke`
# verifies the cluster end-to-end. Replace it with your project's entry point;
# everything above the launch lines is cluster plumbing you can keep.
#
# Usage (via Makefile — preferred):
#   make submit CLUSTER=wheat                       # 4-GPU MLA (default)
#   make submit CLUSTER=wheat NUM_GPU=6             # 6-GPU MLA
#   make submit CLUSTER=wheat NODES=2               # 2x 4-GPU MLA nodes
#
# Manual qsub:
#   qsub -A <project> -q standard -l walltime=24:00:00 \
#        -l select=1:ncpus=92:mpiprocs=1:nmlas=4 \
#        -V scripts/pbs/example_job.sh
#
# Extra arguments are passed via the JOB_ARGS env var (wheat's qsub has no -F
# flag) — the Makefile's SUBMIT_JOB sets it and `qsub -V` carries it in.

#PBS -N run
#PBS -j oe
#PBS -o logs/

set -e

# ─── Identify job + working dir ───
JOBID="${PBS_JOBID%%.*}"
JOBID="${JOBID%%[*}"   # strip array brackets if any

cd "${PBS_O_WORKDIR:-.}"
mkdir -p logs

# Redirect to canonical log filenames (PBS -o doesn't expand $PBS_JOBID).
exec > "logs/run_${JOBID}.out" 2> "logs/run_${JOBID}.err"

# ─── Cluster detection + modules/env (per-cluster dispatcher) ───
source "${PBS_O_WORKDIR:-.}/scripts/cluster_env.sh"
CLUSTER="$HPC_CLUSTER"

echo "============================================"
echo "Cluster:       $CLUSTER"
echo "Job ID:        $JOBID"
echo "Date:          $(date)"
echo "Hostname:      $(hostname -s)"
echo "Submit dir:    $PBS_O_WORKDIR"
echo "============================================"

# Wheat's system CUDA (12.9) lands in LD_LIBRARY_PATH via the module file.
# PyTorch ships its own libcublas/libcublasLt and finds libcublas via RPATH —
# but libcublasLt is dlopen'd through LD_LIBRARY_PATH, so the system's newer
# version wins and the cuBLAS/cuBLASLt minor-version skew triggers
# CUBLAS_STATUS_INVALID_VALUE on FP16 tensor-core GEMMs. Prepend torch's
# bundled nvidia/*/lib dirs so they resolve first.
NVIDIA_LIBS=$(find "$CONDA_PREFIX/lib/python3.11/site-packages/nvidia" -maxdepth 2 -type d -name lib 2>/dev/null | tr '\n' ':')
export LD_LIBRARY_PATH="${NVIDIA_LIBS}${LD_LIBRARY_PATH:-}"

# A100-PCIE nodes: NCCL peer-to-peer over PCIe deadlocks, so every multi-GPU
# job hangs right after "DDP initialized". Route collectives through shared
# memory instead. Consider ALSO setting this from inside your Python code on
# A100-PCIE detection, so the fix survives this file being edited.
export NCCL_P2P_DISABLE="${NCCL_P2P_DISABLE:-1}"

# Extra args arrive via JOB_ARGS env var (wheat's qsub has no -F flag).
# Re-tokenize into "$@" so the launch lines below stay identical to the slurm version.
if [ -n "${JOB_ARGS:-}" ]; then
    eval "set -- $JOB_ARGS"
fi

# ─── Detect node + GPU layout ───
# NUM_NODES / NUM_GPU are exported via `qsub -v ...` from the Makefile.
# Fall back to inferring from $PBS_NODEFILE and `nvidia-smi -L`.
NUM_NODES="${NUM_NODES:-$(sort -u "$PBS_NODEFILE" | wc -l)}"
NUM_NODES="${NUM_NODES// /}"
GPUS_PER_NODE="${NUM_GPU:-$(nvidia-smi -L 2>/dev/null | wc -l)}"
GPUS_PER_NODE="${GPUS_PER_NODE:-1}"
TOTAL_GPUS=$((NUM_NODES * GPUS_PER_NODE))

echo "Config: ${NUM_NODES} nodes × ${GPUS_PER_NODE} GPUs = ${TOTAL_GPUS} total"
echo "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-not set}"
nvidia-smi -L 2>/dev/null || echo "nvidia-smi not available"

# ─── Paths ───
OUTPUT_BASE="${WORKDIR:-$HOME}/${HPC_PROJECT}-outputs"
mkdir -p "$OUTPUT_BASE"

# ─── W&B (offline fallback for air-gapped clusters; optional) ───
export WANDB_PROJECT="${WANDB_PROJECT:-$HPC_PROJECT}"
export WANDB_DIR="${WORKDIR:-/tmp}/wandb"
mkdir -p "$WANDB_DIR"

if ! curl -s --max-time 5 https://api.wandb.ai > /dev/null 2>&1; then
    echo "No internet — W&B offline mode. Sync later: make sync-wandb CLUSTER=$CLUSTER"
    export WANDB_MODE=offline
fi

# ─── Launch ───
# REPLACE `examples/train_smoke.py` below with your project's entry point.
# "$@" forwards whatever `make submit EXTRA_ARGS='...'` passed via JOB_ARGS.
if [ "$TOTAL_GPUS" -gt 1 ] && [ "$NUM_NODES" -gt 1 ]; then
    # Multi-node via pbsdsh (one torchrun per allocated node, c10d rendezvous).
    readarray -t NODES < <(sort -u "$PBS_NODEFILE")
    MASTER_ADDR="${NODES[0]}"
    MASTER_PORT=$((29500 + (10#${JOBID:-0} % 1000)))
    echo "Multi-node master: ${MASTER_ADDR}:${MASTER_PORT}"

    RANK_LOG_DIR="logs/run_${JOBID}"
    mkdir -p "$RANK_LOG_DIR"
    echo "Per-rank logs: $RANK_LOG_DIR/<rank>/{stdout,stderr}.log"

    # pbsdsh starts a BARE shell on each node: re-source the env there.
    pbsdsh -- bash -lc "
        cd '$PBS_O_WORKDIR' && \
        export HPC_CLUSTER='$CLUSTER' HPC_PROJECT='$HPC_PROJECT' && \
        source scripts/cluster_env.sh && \
        export LD_LIBRARY_PATH=\"\$(find \"\$CONDA_PREFIX/lib/python3.11/site-packages/nvidia\" -maxdepth 2 -type d -name lib 2>/dev/null | tr '\n' ':')\${LD_LIBRARY_PATH:-}\" && \
        export NCCL_P2P_DISABLE=1 && \
        torchrun \
            --nnodes=$NUM_NODES \
            --nproc_per_node=$GPUS_PER_NODE \
            --rdzv_id=$JOBID \
            --rdzv_backend=c10d \
            --rdzv_endpoint='${MASTER_ADDR}:${MASTER_PORT}' \
            --log-dir '$RANK_LOG_DIR' \
            --redirects 3 \
            --tee 0 \
            examples/train_smoke.py \
                --output-dir '${OUTPUT_BASE}/run_${JOBID}' \
                $*
    "
elif [ "$TOTAL_GPUS" -gt 1 ]; then
    # Single node, multi-GPU
    RANK_LOG_DIR="logs/run_${JOBID}"
    mkdir -p "$RANK_LOG_DIR"
    echo "Per-rank logs: $RANK_LOG_DIR/<rank>/{stdout,stderr}.log"

    torchrun \
        --nnodes=1 \
        --nproc_per_node="$GPUS_PER_NODE" \
        --log-dir "$RANK_LOG_DIR" \
        --redirects 3 \
        --tee 0 \
        examples/train_smoke.py \
            --output-dir "${OUTPUT_BASE}/run_${JOBID}" \
            "$@"
else
    python examples/train_smoke.py \
        --output-dir "${OUTPUT_BASE}/run_${JOBID}" \
        "$@"
fi

echo "Job finished at $(date)"
