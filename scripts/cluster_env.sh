#!/bin/bash
# ─── Per-cluster environment bootstrap (SOURCE me, don't run me) ───
#
# Single source of truth for cluster identity + modules + conda env + scratch.
# Sourced by (a) the Makefile's REMOTE_INIT on login nodes and (b) every
# scripts/slurm/*.sh and scripts/pbs/*.sh job body on compute nodes.
#
# Cluster identity resolution order:
#   1. $HPC_CLUSTER  (injected by the Makefile / sbatch --export / qsub -v)
#   2. hostname prefix (DoD HPCMP node naming)
#   3. filesystem probe (/anvil exists only on Purdue Anvil; its node names
#      like login04/g### are too generic for a hostname match)
#
# Deliberately no `set -e`/`set -u`: this file is sourced into scripts that
# do not use them. Every export is ${VAR:-...}-guarded so double-sourcing
# (submit shell via `sbatch --export=ALL` + job body) is idempotent.

# Project name: drives conda env name and output dir names. The Makefile
# exports this; the fallback is only for hand-run shells.
export HPC_PROJECT="${HPC_PROJECT:-myproject}"

# Non-interactive ssh shells don't run /etc/profile.d, so `module` may not
# exist yet (bites on fran; wheat/makau init it from bashrc anyway).
if ! type module >/dev/null 2>&1; then
    for _minit in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh \
                  /usr/share/lmod/lmod/init/bash /opt/cray/pe/lmod/lmod/init/bash; do
        [ -r "$_minit" ] && source "$_minit" && break
    done
    unset _minit
fi

if [ -z "${HPC_CLUSTER:-}" ]; then
    case "$(hostname -s)" in
        jean*)                      HPC_CLUSTER="jean" ;;
        raider*|cr*u*ai*)           HPC_CLUSTER="raider" ;;
        nautilus*|mla*|viz*|naut*)  HPC_CLUSTER="nautilus" ;;
        wheat*)                     HPC_CLUSTER="wheat" ;;
        fran*)                      HPC_CLUSTER="fran" ;;
        makau*)                     HPC_CLUSTER="makau" ;;
        *)  if [ -d /anvil ]; then HPC_CLUSTER="anvil"; else HPC_CLUSTER="unknown"; fi ;;
    esac
fi
export HPC_CLUSTER

case "$HPC_CLUSTER" in
    anvil)
        # Purdue Anvil (ACCESS): Lmod; the CUDA runtime is auto-loaded on GPU
        # nodes, so only conda is needed. Soft-fail on module-name drift — the
        # activation WARN below gives a clear message instead of a cryptic error.
        module load anaconda 2>/dev/null || true
        # Anvil sets no $WORKDIR — alias it to $SCRATCH so every existing
        # ${WORKDIR:-...} fallback (job scripts, Makefile remote cmds) resolves
        # to purgeable scratch instead of the 25 GB $HOME quota.
        export WORKDIR="${WORKDIR:-$SCRATCH}"
        # Keep large caches off $HOME too.
        export HF_HOME="${HF_HOME:-$SCRATCH/hf_home}"
        export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$SCRATCH/.pip_cache}"
        export CONDA_PKGS_DIRS="${CONDA_PKGS_DIRS:-$SCRATCH/.conda_pkgs}"
        # The conda env lives under $PROJECT (large quota, never purged —
        # $SCRATCH purges after 30 days and would silently kill queued jobs).
        # Activate by absolute prefix: anvil's conda (2024.02) ignores
        # CONDA_ENVS_PATH for name lookup and errors if CONDA_ENVS_DIRS is set.
        HPC_CONDA_ENV="${HPC_CONDA_ENV:-$PROJECT/$USER/envs/$HPC_PROJECT}"
        # Anvil compute nodes HAVE internet, so a job script's "no internet ->
        # offline" W&B probe never fires here — and with no API key on the
        # cluster, wandb.init aborts the run. Default to the offline-and-sync-
        # later convention; an explicit WANDB_MODE=online still wins.
        export WANDB_MODE="${WANDB_MODE:-offline}"
        ;;
    *)
        # DoD HPCMP (jean/raider/nautilus/wheat/fran/makau). $HOME is
        # /p/home/<user> on every DoD cluster; the module file is per-cluster
        # (module names differ) and is bootstrapped by setup_cluster_env.sh.
        # Warn instead of dying so a pre-setup shell gets an actionable message.
        if [ -f "$HOME/load_modules_cuda.sh" ]; then
            source "$HOME/load_modules_cuda.sh"
        else
            echo "WARN: $HOME/load_modules_cuda.sh not found (run: make setup-cluster CLUSTER=$HPC_CLUSTER)" >&2
        fi
        ;;
esac

# fran compute nodes are air-gapped (login nodes are not). Even with a warm HF
# cache, hub resolution HEADs huggingface.co to revalidate and dies after the
# retry ladder ([Errno 99] Cannot assign requested address) — observed killing
# jobs whose model was fully cached. Force offline resolution inside scheduler
# jobs only, so login-node cache warming and setup keep network access.
if [ "$HPC_CLUSTER" = "fran" ] && [ -n "${SLURM_JOB_ID:-}" ]; then
    export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
    export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
    export HF_DATASETS_OFFLINE="${HF_DATASETS_OFFLINE:-1}"
    # DREN TLS interception answers internet probes with a real HTTP status
    # even though upstream is blocked, so a curl-based "online" conclusion is
    # a lie and wandb.init then hangs on api.wandb.ai. Preset offline: probes
    # should only ever *set* offline, never clear it; an explicit
    # WANDB_MODE=online still wins.
    export WANDB_MODE="${WANDB_MODE:-offline}"
fi

# Non-fatal so first-time `make setup-cluster` can bootstrap before the env
# exists; a genuinely missing env then fails at `python` with a clear traceback.
# DoD clusters activate by name; anvil by prefix (HPC_CONDA_ENV above).
conda activate "${HPC_CONDA_ENV:-$HPC_PROJECT}" 2>/dev/null || \
    echo "WARN: conda env '${HPC_CONDA_ENV:-$HPC_PROJECT}' not active (run: make setup-cluster CLUSTER=$HPC_CLUSTER)" >&2

# ─── Cross-cluster transfer helpers (DoD clusters only — Kerberos hop) ───
# Used by the Makefile's transfer / transfer-pull / transfer-list targets.
# Output dirs are named {prefix}_{jobid} under ${WORKDIR}/${HPC_PROJECT}-outputs.

hpc_host() {
    case "$1" in
        jean)     echo jean01.arl.hpc.mil ;;
        raider)   echo raider.afrl.hpc.mil ;;
        nautilus) echo nautilus.navydsrc.hpc.mil ;;
        wheat)    echo wheat.erdc.hpc.mil ;;
        fran)     echo fran.arl.hpc.mil ;;
        makau)    echo makau.mhpcc.hpc.mil ;;
        *)        echo "$1" ;;
    esac
}

hpc-list() {
    local base="${WORKDIR:-${SCRATCH:-$HOME}}/${HPC_PROJECT}-outputs"
    echo "Runs in $base:"
    ls -1 "$base" 2>/dev/null || echo "  (none)"
}

# hpc-send <to-cluster> <run_id> [prefix] — push a run dir to another DoD cluster.
hpc-send() {
    local to="${1:?usage: hpc-send <to-cluster> <run_id> [prefix]}"
    local id="${2:?usage: hpc-send <to-cluster> <run_id> [prefix]}"
    local prefix="${3:-run}"
    local host base
    host="$(hpc_host "$to")"
    base="${WORKDIR:-${SCRATCH:-$HOME}}/${HPC_PROJECT}-outputs"
    [ -d "$base/${prefix}_${id}" ] || { echo "ERROR: $base/${prefix}_${id} not found"; return 1; }
    # The destination path is expanded by the REMOTE shell (escaped $).
    ssh -o GSSAPIAuthentication=yes "$host" \
        "mkdir -p \${WORKDIR:-\$HOME}/${HPC_PROJECT}-outputs"
    rsync -avz -e "ssh -o GSSAPIAuthentication=yes" \
        "$base/${prefix}_${id}" \
        "$host:\${WORKDIR:-\$HOME}/${HPC_PROJECT}-outputs/"
}

# hpc-pull <from-cluster> <run_id> [prefix] — fetch a run dir from another DoD cluster.
hpc-pull() {
    local from="${1:?usage: hpc-pull <from-cluster> <run_id> [prefix]}"
    local id="${2:?usage: hpc-pull <from-cluster> <run_id> [prefix]}"
    local prefix="${3:-run}"
    local host base
    host="$(hpc_host "$from")"
    base="${WORKDIR:-${SCRATCH:-$HOME}}/${HPC_PROJECT}-outputs"
    mkdir -p "$base"
    rsync -avz -e "ssh -o GSSAPIAuthentication=yes" \
        "$host:\${WORKDIR:-\$HOME}/${HPC_PROJECT}-outputs/${prefix}_${id}" \
        "$base/"
}
