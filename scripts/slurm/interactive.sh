#!/bin/bash
# ─── Get an interactive GPU session on HPCMP clusters ───
# Usage:
#   make interactive CLUSTER=raider                          # 1 GPU
#   make interactive CLUSTER=nautilus NUM_GPU=4              # 4 GPUs
#   make interactive CLUSTER=jean NUM_GPU=2 TIME=2:00:00     # 2 GPUs, 2h

CLUSTER="${1:-raider}"
GPUS="${2:-1}"
TIME="${3:-2:00:00}"
ACCOUNT="${4:-${HPC_ACCOUNT:-YOUR_HPCMP_PROJECT_ID}}"

echo "Requesting interactive session: ${CLUSTER} | ${GPUS} GPU(s) | ${TIME} | account=${ACCOUNT}"

case "$CLUSTER" in
    jean)
        srun --account "$ACCOUNT" --partition=standard --gres=gpu:${GPUS} \
            --nodes 1 --ntasks-per-node=1 \
            --time="$TIME" --pty bash
        ;;
    raider)
        srun --account "$ACCOUNT" --constraint=mla --gres=gpu:a100:"$GPUS" -q hie \
            --nodes 1 --ntasks-per-node=1 \
            --time="$TIME" --pty bash
        ;;
    nautilus)
        salloc --account "$ACCOUNT" --constraint=mla --gpus-per-node="$GPUS" -q standard \
            --nodes 1 --ntasks-per-node=1 \
            --time="$TIME"
        ;;
    wheat)
        # Wheat runs PBS, not Slurm. Use qsub -I for an interactive shell on
        # an MLA node (4-GPU default; override GPUS=6 for 6-GPU MLA).
        QUEUE="${WHEAT_QUEUE:-standard}"
        NCPUS="${WHEAT_NCPUS:-92}"
        GPU_KEY="${WHEAT_GPU_KEY:-nmlas}"
        qsub -I -V \
            -A "$ACCOUNT" -q "$QUEUE" \
            -l "walltime=$TIME" \
            -l "select=1:ncpus=${NCPUS}:mpiprocs=1:${GPU_KEY}=${GPUS}"
        ;;
    anvil)
        # Anvil (Purdue/ACCESS): check which partitions YOUR allocation
        # authorizes (some AI allocations authorize ONLY -p ai; H100, 48h cap,
        # max 12 GPUs per user).
        srun --account "$ACCOUNT" -p ai --gpus-per-node="$GPUS" \
            --nodes 1 --ntasks-per-node=1 \
            --time="$TIME" --pty bash
        ;;
    fran)
        # Fran (ARL, Cray EX4000): GPU jobs must use the AIML queue.
        # AI/ML nodes carry 2x H100/H200 NVL (141 GB) — GPUS <= 2.
        srun --account "$ACCOUNT" -p AIML --gres=gpu:"$GPUS" \
            --nodes 1 --ntasks-per-node=1 \
            --time="$TIME" --pty bash
        ;;
    makau)
        # Makau (MHPCC, Cray XD2000): typed gres. Default h100_sxm5 = AI/ML
        # nodes (4x 80GB); MAKAU_GPU_TYPE=h100_nvl = Mixed nodes (1x 94GB).
        GPU_TYPE="${MAKAU_GPU_TYPE:-h100_sxm5}"
        srun --account "$ACCOUNT" -p standard --gres=gpu:"$GPU_TYPE":"$GPUS" \
            --nodes 1 --ntasks-per-node=1 \
            --time="$TIME" --pty bash
        ;;
    *)
        echo "Unknown cluster: $CLUSTER"
        echo "Available: jean, raider, nautilus, wheat, fran, makau, anvil"
        exit 1
        ;;
esac
