#!/bin/bash
# ─── Persistent GPU node holder (long-running orchestrator) ───
#
# A *batch* job (survives SSH disconnects, unlike salloc/srun --pty) that holds a
# GPU node and runs a detached tmux session you attach to. Intended to host a
# long-running orchestrator or sweep loop so job submission happens ON the
# cluster — where sbatch/squeue need NO Kerberos ticket. A GPU node is requested
# because AI allocations typically fund GPU nodes; a plain CPU node can hit
# AssocGrpCPUMinutesLimit.
#
# Launch:   make persist CLUSTER=raider           (see Makefile for options)
# Attach:   make persist-attach CLUSTER=raider     -> tmux on the compute node
# Stop:     make persist-stop CLUSTER=raider
#
# Resource args (--account/--nodes/--time/--cpus-per-task and the per-cluster GPU
# flags) are supplied on the sbatch command line by the Makefile. The GPU flag
# string is also passed through as $PERSIST_SBATCH_GPU so chaining can reuse it.
#
# Chaining (PERSIST_CHAIN=1, PERSIST_CHAIN_LEFT>0): before this job ends it queues
# a successor (--dependency=afterany) so coverage continues past the queue
# walltime cap. Each chained job is a FRESH node with a FRESH tmux, so whatever
# you run inside must be restart-safe (resume from its own state on disk).

#SBATCH --job-name=persist
#SBATCH --ntasks-per-node=1
#SBATCH --output=logs/persist_%j.out
#SBATCH --error=logs/persist_%j.err

set -uo pipefail
cd "${SLURM_SUBMIT_DIR:-$PWD}"
mkdir -p logs

SESSION="${PERSIST_SESSION:-orch}"
STOP_FILE="${PERSIST_STOP_FILE:-${SLURM_SUBMIT_DIR:-$PWD}/.persist_stop}"
CHAIN="${PERSIST_CHAIN:-0}"
CHAIN_LEFT="${PERSIST_CHAIN_LEFT:-0}"

# A fresh job should not inherit a stale STOP sentinel from a previous cancel.
[ -f "$STOP_FILE" ] && { echo "Clearing stale STOP sentinel $STOP_FILE"; rm -f "$STOP_FILE"; }

echo "=================================================================="
echo " persist job : $SLURM_JOB_ID"
echo " node        : $(hostname -s)  ($SLURM_NODELIST)"
echo " walltime    : $(squeue -h -j "$SLURM_JOB_ID" -o %l 2>/dev/null)"
echo " tmux session: $SESSION"
echo " attach with : srun --jobid=$SLURM_JOB_ID --overlap --pty bash   # then: tmux attach -t $SESSION"
echo " chaining    : CHAIN=$CHAIN  links_left=$CHAIN_LEFT"
echo "=================================================================="

# ─── Start a detached multiplexer session (idempotent) ───
if command -v tmux >/dev/null 2>&1; then
    tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION"
    echo "tmux session '$SESSION' ready."
elif command -v screen >/dev/null 2>&1; then
    screen -list | grep -q "\.$SESSION" || screen -dmS "$SESSION"
    echo "screen session '$SESSION' ready (tmux not found)."
else
    echo "WARN: neither tmux nor screen found — node is held but no multiplexer session was started."
fi

# ─── Optional chaining: queue a successor that starts after this job finishes ───
if [ "$CHAIN" = "1" ] && [ "$CHAIN_LEFT" -gt 0 ] && [ ! -f "$STOP_FILE" ]; then
    echo "Chaining: queueing successor (links left after this: $((CHAIN_LEFT - 1)))"
    # ${PERSIST_SBATCH_GPU} is unquoted on purpose so it word-splits into the
    # per-cluster GPU flags (e.g. --constraint=mla --gpus-per-node=1 -q standard).
    PERSIST_CHAIN=1 PERSIST_CHAIN_LEFT=$((CHAIN_LEFT - 1)) \
    sbatch --export=ALL --dependency=afterany:"$SLURM_JOB_ID" --job-name=persist \
           --nodes=1 --ntasks-per-node=1 --cpus-per-task="${PERSIST_CPUS:-1}" \
           --time="${PERSIST_TIME:-72:00:00}" --account="${PERSIST_ACCOUNT:-YOUR_HPCMP_PROJECT_ID}" \
           ${PERSIST_SBATCH_GPU:-} \
           scripts/slurm/persist.sh \
        && echo "successor queued." || echo "WARN: successor submit failed (check GPU allocation/walltime)."
fi

# ─── Hold the node until walltime or a STOP sentinel (tmux keeps running) ───
echo "Holding node. Attach and work inside '$SESSION'. Touch $STOP_FILE (or make persist-stop) to release."
while [ ! -f "$STOP_FILE" ]; do sleep 300; done
echo "STOP sentinel found — releasing node, not chaining further."
