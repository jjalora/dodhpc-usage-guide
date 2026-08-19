#!/bin/bash
# ─── Example training job (SLURM clusters: jean/raider/nautilus/fran/makau/anvil) ───
#
# TEMPLATE: the launch lines at the bottom run examples/train_smoke.py — a tiny
# synthetic-data training script — so a fresh clone's `make submit`/`make smoke`
# verifies the cluster end-to-end. Replace it with your project's entry point;
# everything above the launch lines is cluster plumbing you can keep.
#
# Usage (via Makefile — preferred):
#   make submit CLUSTER=raider NUM_GPU=1
#   make submit CLUSTER=nautilus NUM_GPU=4 NODES=1 TIME=48:00:00
#   make submit CLUSTER=anvil NUM_GPU=1 TIME=0:25:00        # smoke test
#
# Usage (manual sbatch — supply the per-cluster GPU args yourself):
#   sbatch --constraint=mla --gpus-per-node=4 -q standard --nodes=1 \
#          --time=24:00:00 --account=YOUR_HPCMP_PROJECT_ID scripts/slurm/example_job.sh

# ─── Universal directives only ───
# Cluster-specific args (--partition, --qos, --constraint, --gpus-per-node,
# --gres, --nodes, --time, --account) are passed on the sbatch command line
# by the Makefile's SBATCH_GPU / SBATCH_COMMON tables.
#SBATCH --job-name=run
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=32
#SBATCH --output=logs/run_%j.out
#SBATCH --error=logs/run_%j.err

# ─── Cluster detection + modules/env (per-cluster dispatcher) ───
source "${SLURM_SUBMIT_DIR:-.}/scripts/cluster_env.sh"
CLUSTER="$HPC_CLUSTER"

echo "============================================"
echo "Cluster:       $CLUSTER"
echo "Job ID:        $SLURM_JOB_ID"
echo "Nodes:         $SLURM_NODELIST"
echo "GPUs/node:     ${SLURM_GPUS_PER_NODE:-?}"
echo "Date:          $(date)"
echo "hostname -s:   $(hostname -s)"
echo "============================================"

# ─── InfiniBand / NCCL (jean multi-node) ───
if [ "$CLUSTER" = "jean" ] && [ "${SLURM_NNODES:-1}" -gt 1 ]; then
    echo "Configuring InfiniBand + NCCL for distributed training..."
    export NCCL_IB_DISABLE=0
    export NCCL_NET=IB
    export NCCL_IB_HCA=mlx5_0:1,mlx5_3:1
    export NCCL_IB_ADDR_FAMILY=AF_INET
    export NCCL_SOCKET_IFNAME=ib0
    export NCCL_DEBUG=INFO
fi

# NOTE: on A100-PCIE nodes (e.g. wheat's MLA nodes), NCCL peer-to-peer over
# PCIe deadlocks — every multi-GPU job hangs right after DDP init. If you hit
# that on a PCIe cluster, export NCCL_P2P_DISABLE=1 (see scripts/pbs/example_job.sh).

# ─── Paths ───
PROJECT_DIR="${SLURM_SUBMIT_DIR:-.}"
cd "$PROJECT_DIR"
mkdir -p logs

OUTPUT_BASE="${WORKDIR:-$HOME}/${HPC_PROJECT}-outputs"
mkdir -p "$OUTPUT_BASE"

# ─── W&B (offline mode for air-gapped clusters; optional) ───
export WANDB_PROJECT="${WANDB_PROJECT:-$HPC_PROJECT}"
export WANDB_DIR="${WORKDIR:-/tmp}/wandb"
mkdir -p "$WANDB_DIR"

# Probe only ever SETS offline, never clears it (cluster_env.sh may have
# preset offline for clusters where the probe itself is unreliable).
if ! curl -s --max-time 5 https://api.wandb.ai > /dev/null 2>&1; then
    echo "No internet — W&B offline mode. Sync later: make sync-wandb CLUSTER=$CLUSTER"
    export WANDB_MODE=offline
fi

# ─── Launch ───
NUM_NODES=${SLURM_NNODES:-1}
GPUS_PER_NODE=${HPC_NUM_GPU:-${SLURM_GPUS_PER_NODE:-${SLURM_GPUS_ON_NODE:-1}}}
TOTAL_GPUS=$((NUM_NODES * GPUS_PER_NODE))

echo "Config: ${NUM_NODES} nodes × ${GPUS_PER_NODE} GPUs = ${TOTAL_GPUS} total"
echo "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-not set}"
nvidia-smi -L 2>/dev/null || echo "nvidia-smi not available"

# REPLACE `examples/train_smoke.py` below with your project's entry point.
# "$@" forwards whatever `make submit EXTRA_ARGS='...'` passed on the sbatch
# command line.
if [ "$TOTAL_GPUS" -gt 1 ]; then
    MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)
    MASTER_PORT=$((29500 + SLURM_JOB_ID % 1000))
    echo "Master: ${MASTER_ADDR}:${MASTER_PORT}"

    srun torchrun \
        --nnodes="$NUM_NODES" \
        --nproc_per_node="$GPUS_PER_NODE" \
        --rdzv_id="$SLURM_JOB_ID" \
        --rdzv_backend=c10d \
        --rdzv_endpoint="${MASTER_ADDR}:${MASTER_PORT}" \
        examples/train_smoke.py \
            --output-dir "${OUTPUT_BASE}/run_${SLURM_JOB_ID}" \
            "$@"
else
    python examples/train_smoke.py \
        --output-dir "${OUTPUT_BASE}/run_${SLURM_JOB_ID}" \
        "$@"
fi

echo "Job finished at $(date)"
