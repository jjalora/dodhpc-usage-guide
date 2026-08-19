#!/bin/bash
# ─── Download a run's outputs from an HPC cluster ───
# Usage:
#   PROJECT_NAME=myproject ./scripts/download_run.sh <run_id> [cluster] [prefix]
#
# Via Makefile:
#   make download-run CLUSTER=raider RUN_ID=1650317

RUN_ID="${1:?Usage: download_run.sh <run_id> [cluster] [prefix]}"
CLUSTER="${2:-jean}"
PREFIX="${3:-run}"
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

# Anvil login shells export $SCRATCH, not $WORKDIR (escaped so the REMOTE
# shell expands them).
REMOTE_BASE="\${WORKDIR:-\${SCRATCH:-\$HOME}}/${PROJECT_NAME}-outputs"
LOCAL_BASE="./outputs"
mkdir -p "${LOCAL_BASE}/${PREFIX}_${RUN_ID}"

echo "Downloading ${PREFIX}_${RUN_ID} from ${SSH_HOST}..."

rsync -avz --progress \
    -e "ssh $SSH_OPTS" \
    "${SSH_HOST}:${REMOTE_BASE}/${PREFIX}_${RUN_ID}/" \
    "${LOCAL_BASE}/${PREFIX}_${RUN_ID}/"

echo ""
echo "Done: ${LOCAL_BASE}/${PREFIX}_${RUN_ID}/"
