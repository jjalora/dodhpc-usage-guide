#!/bin/bash
# ─── Update THIS cluster's code checkout to match GitHub (authoritative) ───
#
# GitHub is the single source of truth for code. This makes the cluster checkout
# EXACTLY match origin/<branch>, but first preserves any local changes on a
# per-cluster `cluster-snapshot/<cluster>` branch and pushes it — so cluster-side
# work reaches the repo WITHOUT clusters ever conflicting on a shared branch
# (each snapshot branch has exactly one writer). To keep a snapshot's change,
# review/merge `origin/cluster-snapshot/<cluster>` into the authoritative branch
# deliberately.
#
# Invoked by `make sync` (piped in over ssh), run from the checkout dir:
#   ssh host 'cd ~/myproject && GIT_SSH_COMMAND=... bash -s -- <branch> <url> <cluster>' \
#       < scripts/git_sync_cluster.sh
#
# Idempotent: converts an rsync'd (non-git) tree — or an empty dir — into a real
# clone. Gitignored results/data (outputs/, wandb/, logs/, checkpoints/, *.pt)
# are never touched.
set -uo pipefail

BRANCH="${1:?branch required}"
URL="${2:?repo url required}"
CLUSTER="${3:-$(hostname -s)}"

# Turn an rsync'd (non-git) or empty tree into a real clone in place.
if [ ! -d .git ]; then
    echo "No .git here — initializing a checkout of $URL"
    git init -q
    git remote add origin "$URL" 2>/dev/null || git remote set-url origin "$URL"
fi

# First contact on a fresh cluster: non-interactive ssh cannot show the
# accept-fingerprint prompt, so `git fetch` dies with "Host key verification
# failed" before the deploy key is even tried. Pre-seed GitHub's PUBLISHED
# host keys (api.github.com/meta — pinned constants, deliberately not a live
# ssh-keyscan). FIPS clusters (fran) ban ed25519 outright: an ed25519 line in
# known_hosts makes EVERY ssh spam "Ed25519 keys are not allowed in FIPS
# mode", so there we pin only ECDSA and strip any ed25519 line.
GH_ED25519="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
GH_ECDSA="github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg="
FIPS="$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if ! grep -qs "^github.com ecdsa-sha2-nistp256" ~/.ssh/known_hosts; then
    echo "$GH_ECDSA" >> ~/.ssh/known_hosts
    echo "Added github.com ECDSA host key to ~/.ssh/known_hosts."
fi
if [ "$FIPS" = "1" ]; then
    if grep -qs "^github.com ssh-ed25519" ~/.ssh/known_hosts; then
        sed -i "/^github.com ssh-ed25519/d" ~/.ssh/known_hosts
        echo "FIPS host: removed github.com ed25519 known_hosts line (parse noise)."
    fi
elif ! grep -qs "^github.com ssh-ed25519" ~/.ssh/known_hosts; then
    echo "$GH_ED25519" >> ~/.ssh/known_hosts
    echo "Added github.com ed25519 host key to ~/.ssh/known_hosts."
fi
chmod 600 ~/.ssh/known_hosts

git fetch --prune origin || { echo "ERROR: git fetch failed (check deploy key / network)"; exit 1; }

# Preserve local changes (tracked edits + new non-ignored files) on a per-cluster
# branch so nothing is lost and clusters never clash. .gitignore keeps results/data out.
if [ -n "$(git status --porcelain)" ]; then
    SNAP="cluster-snapshot/${CLUSTER}"
    TS="$(date -u +%Y%m%d-%H%M%S)"
    echo "Local changes present — snapshotting to origin/${SNAP} before force-matching."
    git add -A
    git -c user.name="${CLUSTER}-cluster" -c user.email="${CLUSTER}@cluster.invalid" \
        commit -q -m "cluster snapshot: ${CLUSTER} ${TS}" || true
    # force-push: this branch is owned solely by ${CLUSTER}; single writer => no conflict.
    if git push -f origin "HEAD:${SNAP}"; then
        echo "Saved local changes -> origin/${SNAP} (review/merge to keep them)."
    else
        echo "WARN: snapshot push failed — changes are committed locally but NOT in the repo."
        echo "      (Does the deploy key have WRITE access? Not force-matching to avoid data loss.)"
        exit 1
    fi
fi

# Force the checkout to exactly match the authoritative branch.
git checkout -q -B "$BRANCH" "origin/${BRANCH}"
git reset --hard "origin/${BRANCH}"
# Remove leftover untracked files (respects .gitignore); keep the persist sentinels.
git clean -ffd -e .persist_node -e .persist_stop
echo "Cluster now matches origin/${BRANCH} at $(git rev-parse --short HEAD)."
