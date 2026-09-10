#!/bin/bash
# Local check for install.sh + hpc.mk: installs into a throwaway repo that already
# has a Makefile, then asserts the layout, idempotency, and that every cluster's
# targets expand under `make -n` (no $(error), no empty ssh host). No cluster access.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

git init -q "$T" && git -C "$T" remote add origin https://github.com/acme/widget.git
printf 'all: build\n\nbuild:\n\t@echo building\n\nclean:\n\t@echo cleaning\n' > "$T/Makefile"

for i in 1 2; do  # twice: must be idempotent
    bash "$KIT/install.sh" --target "$T" --dod-user jdoe --anvil-user x-jdoe >/dev/null
done

for f in hpc.mk scripts/cluster_env.sh scripts/deploy_key.sh scripts/slurm/example_job.sh \
         scripts/pbs/example_job.sh load_modules/load_modules_cuda.fran.sh examples/train_smoke.py \
         config.mk .claude/skills/hpc-cluster/SKILL.md .claude/skills/hpc-cluster/references/clusters.md; do
    [ -f "$T/$f" ] || fail "missing $f"
done
[ -L "$T/.agents/skills/hpc-cluster" ] && [ -f "$T/.agents/skills/hpc-cluster/SKILL.md" ] || fail "codex skill symlink"
[ "$(grep -c '^include hpc.mk' "$T/Makefile")" = 1 ] || fail "include line count"
[ "$(grep -c 'hpc-cluster-kit' "$T/AGENTS.md")" = 1 ] || fail "AGENTS.md block count"
[ "$(grep -c 'hpc-cluster-kit' "$T/CLAUDE.md")" = 1 ] || fail "CLAUDE.md block count"
grep -q '^DOD_USER  *:= jdoe' "$T/config.mk" || fail "DOD_USER in config.mk"
grep -q '^ANVIL_USER  *:= x-jdoe' "$T/config.mk" || fail "ANVIL_USER in config.mk"
grep -q '^PROJECT_NAME  *:= '"$(basename "$T")" "$T/config.mk" || fail "PROJECT_NAME derived"
grep -q '^GITHUB_SSH  *:= git@github.com:acme/widget.git' "$T/config.mk" || fail "GITHUB_SSH derived from https origin"
grep -qx 'config.mk' "$T/.gitignore" || fail ".gitignore"
head -1 "$T/.claude/skills/hpc-cluster/SKILL.md" | grep -q '^---$' || fail "skill frontmatter"
grep -q '^name: hpc-cluster$' "$T/.claude/skills/hpc-cluster/SKILL.md" || fail "skill name matches dir"

# Host Makefile keeps its own default goal and clean target.
[ "$(make -s -C "$T")" = "building" ] || fail "host default goal overridden"
[ "$(make -s -C "$T" clean)" = "cleaning" ] || fail "host clean shadowed"
out="$(make -s -C "$T" help)"; echo "$out" | grep -q 'smoke-wait' || fail "make help lacks kit targets"

# Every cluster's remote targets expand (dry run; nothing is executed).
for c in jean raider nautilus wheat fran makau anvil; do
    for tgt in submit smoke smoke-wait status interactive setup-cluster deploy-key; do
        out="$(make -n -C "$T" "$tgt" CLUSTER=$c 2>&1)" || fail "make -n $tgt CLUSTER=$c: $out"
        echo "$out" | grep -q 'ssh' || fail "$tgt CLUSTER=$c produced no ssh command"
    done
    out="$(make -n -C "$T" sync CLUSTER=$c SYNC_MODE=rsync 2>&1)"; echo "$out" | grep -q 'rsync -az' || fail "rsync sync $c"
done
# Capture first, then grep: grep -q on a live pipe trips pipefail with SIGPIPE.
dry() { make -n -C "$T" "$@" 2>&1 || true; }
dry submit CLUSTER=anvil | grep -q -- '-p ai' || fail "anvil partition"
dry submit CLUSTER=anvil PARTITION=gpu | grep -q 'ONLY the ai partition' || fail "anvil guard"
dry submit CLUSTER=wheat | grep -q 'qsub' || fail "wheat uses qsub"
dry submit CLUSTER=anvil | grep -q 'x-jdoe@anvil' || fail "anvil user in host"
dry status CLUSTER=nope | grep -q "Unknown CLUSTER" || fail "unknown cluster error"

for s in "$T"/scripts/*.sh "$T"/scripts/slurm/*.sh "$T"/scripts/pbs/*.sh "$T"/load_modules/*.sh "$KIT/install.sh"; do
    bash -n "$s" || fail "syntax $s"
done
echo "INSTALL TEST PASSED"
