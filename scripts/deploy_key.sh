#!/bin/bash
# ─── One-time per cluster: create + register the cluster's GitHub deploy key ───
#
# `make sync` (git mode) clones/fetches your repo ON the cluster, so the cluster
# needs its own deploy key (GitHub allows a key to be registered once, so one
# key per cluster). This script:
#   1. ssh-es to the cluster and creates $DEPLOY_KEY if missing
#      (ECDSA-384 on FIPS hosts such as fran — ed25519 is banned there),
#   2. registers the public key on the repo with `gh` if it is installed and
#      logged in (write access, needed for the cluster-snapshot push),
#   3. otherwise prints the key and the manual steps.
#
# Usage (via Makefile): make deploy-key CLUSTER=raider
set -euo pipefail

CLUSTER="${1:?cluster}"
SSH_HOST="${2:?ssh host}"
DEPLOY_KEY="${DEPLOY_KEY:-\$HOME/.ssh/id_deploy}"
GITHUB_SSH="${GITHUB_SSH:-}"
SSH_OPTS="${SSH_OPTS:-}"

# shellcheck disable=SC2086
PUB="$(ssh $SSH_OPTS "$SSH_HOST" "
    KEY=\"$DEPLOY_KEY\"
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    if [ ! -f \"\$KEY\" ]; then
        if [ \"\$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)\" = 1 ]; then
            ssh-keygen -q -t ecdsa -b 384 -N '' -C \"deploy-$CLUSTER\" -f \"\$KEY\"
        else
            ssh-keygen -q -t ed25519 -N '' -C \"deploy-$CLUSTER\" -f \"\$KEY\"
        fi
        echo \"Created \$KEY on $CLUSTER\" >&2
    fi
    cat \"\$KEY.pub\"
")"

echo "Public key on $CLUSTER ($DEPLOY_KEY.pub):"
echo "  $PUB"

# git@github.com:owner/repo.git  or  https://github.com/owner/repo(.git)  -> owner/repo
REPO="$(echo "$GITHUB_SSH" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && [[ "$REPO" == */* ]]; then
    echo "Registering on github.com/$REPO via gh (write access)..."
    TMP="$(mktemp)"; echo "$PUB" > "$TMP"
    if OUT="$(gh repo deploy-key add "$TMP" -R "$REPO" --allow-write --title "hpc-$CLUSTER" 2>&1)"; then
        echo "  $OUT"
    elif echo "$OUT" | grep -qi "already in use"; then
        echo "  Key already registered — nothing to do."
    else
        echo "  gh failed: $OUT"; rm -f "$TMP"; exit 1
    fi
    rm -f "$TMP"
else
    cat <<MSG

gh is not available (or GITHUB_SSH is not a github.com URL), so register the key by hand:
  1. Open https://github.com/${REPO:-<owner>/<repo>}/settings/keys/new
  2. Title: hpc-$CLUSTER   Key: (the line above)   Check "Allow write access"
MSG
fi
echo "Done. Next: make sync CLUSTER=$CLUSTER"
