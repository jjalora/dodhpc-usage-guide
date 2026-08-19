#!/bin/bash
# ─── Sync W&B offline runs from an HPC cluster ───
# Air-gapped clusters run W&B in offline mode. This script downloads offline
# runs and syncs them to wandb.ai from your local machine.
#
# Usage:
#   PROJECT_NAME=myproject ./scripts/sync_wandb_offline.sh CLUSTER [RUN_ID] [PREFIX]
#
# Examples:
#   ./scripts/sync_wandb_offline.sh jean                    # all offline runs on jean
#   ./scripts/sync_wandb_offline.sh jean 2007845            # only job 2007845 (any prefix)
#   ./scripts/sync_wandb_offline.sh jean 2007845 run        # only run_2007845
#   ./scripts/sync_wandb_offline.sh jean "" run             # all run_* runs
#
# Via Makefile:
#   make sync-wandb CLUSTER=jean
#   make sync-wandb CLUSTER=jean RUN_ID=2007845

set -euo pipefail

CLUSTER="${1:-jean}"
RUN_ID="${2:-}"
PREFIX="${3:-}"
PROJECT_NAME="${PROJECT_NAME:-myproject}"
ANVIL_USER="${ANVIL_USER:-your-anvil-username}"

case "$CLUSTER" in
    jean)     SSH_HOST="jean01.arl.hpc.mil" ;;
    raider)   SSH_HOST="raider.afrl.hpc.mil" ;;
    nautilus) SSH_HOST="nautilus.navydsrc.hpc.mil" ;;
    wheat)    SSH_HOST="wheat.erdc.hpc.mil" ;;
    fran)     SSH_HOST="fran.arl.hpc.mil" ;;
    makau)    SSH_HOST="makau01.mhpcc.hpc.mil" ;;   # pinned node: alias intermittently rejects GSSAPI
    anvil)    SSH_HOST="${ANVIL_USER}@anvil.rcac.purdue.edu" ;;
    *)        SSH_HOST="$CLUSTER" ;;
esac

# DoD clusters authenticate via Kerberos/GSSAPI; anvil uses SSH keys.
SSH_OPTS="-o GSSAPIAuthentication=yes"
if [ "$CLUSTER" = "anvil" ]; then
    SSH_OPTS=""
elif ! klist -s 2>/dev/null; then
    echo "ERROR: No Kerberos ticket. Run: kshell && kinit"
    exit 1
fi

# Build the per-job output-dir glob from RUN_ID + PREFIX.
# Output dirs are named: {prefix}_{job_id}, e.g. run_2007845
if [ -n "$RUN_ID" ] && [ -n "$PREFIX" ]; then
    OUTPUT_GLOB="${PREFIX}_${RUN_ID}"
elif [ -n "$RUN_ID" ]; then
    OUTPUT_GLOB="*_${RUN_ID}"
elif [ -n "$PREFIX" ]; then
    OUTPUT_GLOB="${PREFIX}_*"
else
    OUTPUT_GLOB="*"
fi

LOCAL_WANDB="./wandb_offline_sync"
mkdir -p "$LOCAL_WANDB"

echo "Cluster:    $CLUSTER ($SSH_HOST)"
echo "Filter:     RUN_ID='${RUN_ID:-<any>}'  PREFIX='${PREFIX:-<any>}'"
echo "Output dir glob: $OUTPUT_GLOB"
echo ""

# Find matching offline-run-* dirs on the cluster. wandb.init(dir=output_dir)
# writes to {output_dir}/wandb/offline-run-*, so the canonical location is
# $WORKDIR/<project>-outputs/{prefix}_{run_id}/wandb/offline-run-*
echo "Locating offline runs on ${SSH_HOST}..."
REMOTE_DIRS=$(ssh $SSH_OPTS "${SSH_HOST}" "
    set -e
    BASE=\${WORKDIR:-\${SCRATCH:-\$HOME}}/${PROJECT_NAME}-outputs
    find \${BASE}/${OUTPUT_GLOB}/wandb -maxdepth 1 -type d -name 'offline-run-*' 2>/dev/null || true
")

if [ -z "$REMOTE_DIRS" ]; then
    echo "No matching offline runs found on ${SSH_HOST}."
    echo "Searched: \$WORKDIR/${PROJECT_NAME}-outputs/${OUTPUT_GLOB}/wandb/offline-run-*"
    exit 0
fi

count=$(echo "$REMOTE_DIRS" | wc -l | tr -d ' ')
echo "Found $count offline run(s):"
echo "$REMOTE_DIRS" | sed 's/^/  /'
echo ""

# Download each matching run
echo "Downloading..."
while IFS= read -r remote_dir; do
    [ -z "$remote_dir" ] && continue
    local_name=$(basename "$remote_dir")
    # Include the parent run-output dir name to disambiguate runs with the same wandb id
    parent_run=$(basename "$(dirname "$(dirname "$remote_dir")")")
    local_dir="${LOCAL_WANDB}/${parent_run}__${local_name}"
    rsync -avz --progress \
        -e "ssh $SSH_OPTS" \
        "${SSH_HOST}:${remote_dir}/" \
        "${local_dir}/"
done <<< "$REMOTE_DIRS"

# Sync each downloaded run to wandb.ai
echo ""
echo "Syncing to W&B..."
synced=0
for run_dir in "${LOCAL_WANDB}"/*__offline-run-*; do
    if [ -d "$run_dir" ]; then
        echo "  Syncing: $(basename "$run_dir")"
        wandb sync "$run_dir" --project "$PROJECT_NAME"
        synced=$((synced + 1))
    fi
done

echo ""
echo "Synced $synced run(s). Check: https://wandb.ai/<entity>/${PROJECT_NAME}"
