#!/bin/bash
# ─── Persistent GPU node holder (PBS / wheat) — long-running orchestrator ───
#
# PBS Pro analog of scripts/slurm/persist.sh. A batch job holds a GPU node and runs
# a detached tmux session you attach to (`make persist-attach CLUSTER=wheat`), so
# job submission happens ON the cluster where qsub/qstat need NO Kerberos ticket.
#
# The running job records its exec node in .persist_node so persist-attach can ssh
# to it. Chaining (PERSIST_CHAIN=1, PERSIST_CHAIN_LEFT>0) queues a successor with
# `qsub -W depend=afterany:` to span the walltime cap; each link is a FRESH node
# with a FRESH tmux, so whatever you run inside must be restart-safe. Resource
# flags ride in via $PERSIST_QSUB_RES (exported with `qsub -V`).

#PBS -N persist
#PBS -j oe
#PBS -o logs/

set -uo pipefail

JOBID="${PBS_JOBID%%.*}"
JOBID="${JOBID%%[*}"                       # strip array brackets if any
WORKDIR_LOCAL="${PBS_O_WORKDIR:-$PWD}"
cd "$WORKDIR_LOCAL"
mkdir -p logs
# PBS -o doesn't expand $PBS_JOBID; redirect to canonical filenames.
exec > "logs/persist_${JOBID}.out" 2> "logs/persist_${JOBID}.err"

SESSION="${PERSIST_SESSION:-orch}"
STOP_FILE="${PERSIST_STOP_FILE:-$WORKDIR_LOCAL/.persist_stop}"
NODE_FILE="$WORKDIR_LOCAL/.persist_node"
CHAIN="${PERSIST_CHAIN:-0}"
CHAIN_LEFT="${PERSIST_CHAIN_LEFT:-0}"

# A fresh job should not inherit a stale STOP sentinel from a previous cancel.
[ -f "$STOP_FILE" ] && { echo "Clearing stale STOP sentinel $STOP_FILE"; rm -f "$STOP_FILE"; }

# Record the exec (mother-superior) node so `make persist-attach` can ssh to it.
MOTHER="$(hostname)"
echo "$MOTHER" > "$NODE_FILE"

echo "=================================================================="
echo " persist PBS job : $JOBID"
echo " node            : $MOTHER"
echo " tmux session    : $SESSION"
echo " attach with     : make persist-attach CLUSTER=wheat   (or: ssh -t $MOTHER 'tmux attach -t $SESSION')"
echo " chaining        : CHAIN=$CHAIN  links_left=$CHAIN_LEFT"
echo "=================================================================="

# ─── Start a detached multiplexer session (idempotent) ───
if command -v tmux >/dev/null 2>&1; then
    tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION"
    echo "tmux session '$SESSION' ready."
elif command -v screen >/dev/null 2>&1; then
    screen -list | grep -q "\.$SESSION" || screen -dmS "$SESSION"
    echo "screen session '$SESSION' ready (tmux not found)."
else
    echo "WARN: neither tmux nor screen found — node held but no multiplexer session."
fi

# ─── Optional chaining: queue a successor that starts after this job finishes ───
# $PERSIST_QSUB_RES (inherited via the initial `qsub -V`) is unquoted on purpose so
# it word-splits into the PBS resource flags (-A/-q/-l select=.../-l walltime=...).
if [ "$CHAIN" = "1" ] && [ "$CHAIN_LEFT" -gt 0 ] && [ ! -f "$STOP_FILE" ]; then
    echo "Chaining: queueing successor (links left after this: $((CHAIN_LEFT - 1)))"
    PERSIST_CHAIN=1 PERSIST_CHAIN_LEFT=$((CHAIN_LEFT - 1)) \
    qsub -N persist -W depend=afterany:"$PBS_JOBID" ${PERSIST_QSUB_RES:-} -V \
         scripts/pbs/persist.sh \
        && echo "successor queued." || echo "WARN: successor submit failed (check GPU allocation/walltime)."
fi

# ─── Hold the node until walltime or a STOP sentinel (tmux keeps running) ───
echo "Holding node. Attach and work inside '$SESSION'. Touch $STOP_FILE (or make persist-stop) to release."
while [ ! -f "$STOP_FILE" ]; do sleep 300; done
echo "STOP sentinel found — releasing node, not chaining further."
rm -f "$NODE_FILE"
