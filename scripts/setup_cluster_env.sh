#!/bin/bash
# ─── One-time setup on a cluster ───
# Run this after syncing code to the cluster for the first time.
#
# Usage (on the cluster login node):
#   bash scripts/setup_cluster_env.sh [cluster] [project_name]
# The Makefile's `make setup-cluster CLUSTER=<c>` passes both; without them we
# fall back to $HPC_CLUSTER / $HPC_PROJECT, then a filesystem probe.
#
# EDIT the "install your project" lines below to match your project's install
# (pip install -e ., requirements.txt, etc.).

set -e

CLUSTER="${1:-${HPC_CLUSTER:-}}"
ENV_NAME="${2:-${HPC_PROJECT:-myproject}}"
if [ -z "$CLUSTER" ] && [ -d /anvil ]; then
    CLUSTER="anvil"
fi

# Non-interactive ssh shells don't run /etc/profile.d, so `module` may not
# exist yet (bites on fran; wheat/makau init it from bashrc anyway).
if ! type module >/dev/null 2>&1; then
    for _minit in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh \
                  /usr/share/lmod/lmod/init/bash /opt/cray/pe/lmod/lmod/init/bash; do
        [ -r "$_minit" ] && source "$_minit" && break
    done
    unset _minit
fi

echo "============================================"
echo "${ENV_NAME}: Setting up cluster environment (${CLUSTER:-hpcmp})"
echo "============================================"

if [ "$CLUSTER" = "anvil" ]; then
    # ─── Anvil (Purdue/ACCESS) ───
    module load anaconda
    echo "Loaded modules:"
    module list 2>&1 || true
    # Keep package caches off the 25 GB $HOME quota.
    export CONDA_PKGS_DIRS="${CONDA_PKGS_DIRS:-$SCRATCH/.conda_pkgs}"
    export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$SCRATCH/.pip_cache}"
    # The env itself lives under $PROJECT: a torch+CUDA env is 10-20 GB (does
    # not fit $HOME) and $SCRATCH purges after 30 days (would silently kill
    # queued jobs). cluster_env.sh activates it by this absolute prefix.
    ENV_PREFIX="$PROJECT/$USER/envs/$ENV_NAME"
    source activate base 2>/dev/null || eval "$(conda shell.bash hook)"
    if [ -d "$ENV_PREFIX" ]; then
        echo "Conda env at '$ENV_PREFIX' already exists. Updating..."
        conda activate "$ENV_PREFIX"
        pip install -e . --upgrade          # EDIT ME: your project's install
    else
        echo "Creating conda env at '$ENV_PREFIX'..."
        mkdir -p "$(dirname "$ENV_PREFIX")"
        conda create --prefix "$ENV_PREFIX" python=3.11 -y
        conda activate "$ENV_PREFIX"
        pip install -e .                    # EDIT ME: your project's install
    fi
else
    # ─── DoD HPCMP (jean / raider / nautilus / wheat / fran / makau) ───
    # Module loads live in a per-cluster ~/load_modules_cuda.sh because module
    # names differ per system. The repo ships known-good scripts in
    # load_modules/ — install the matching one, so `make setup-cluster` keeps
    # every cluster's module file in sync with the repo. A pre-existing file
    # that differs is backed up, never silently lost. For a cluster the repo
    # doesn't know yet, fall back to bootstrapping a best-effort starter.
    REPO_LM="load_modules/load_modules_cuda.${CLUSTER}.sh"
    if [ -f "$REPO_LM" ]; then
        if [ -f "$HOME/load_modules_cuda.sh" ] && ! cmp -s "$REPO_LM" "$HOME/load_modules_cuda.sh"; then
            cp "$HOME/load_modules_cuda.sh" "$HOME/load_modules_cuda.sh.bak"
            echo "Backed up existing ~/load_modules_cuda.sh -> ~/load_modules_cuda.sh.bak"
        fi
        cp "$REPO_LM" "$HOME/load_modules_cuda.sh"
        echo "Installed $REPO_LM -> ~/load_modules_cuda.sh"
    elif [ ! -f "$HOME/load_modules_cuda.sh" ]; then
        cat > "$HOME/load_modules_cuda.sh" <<'MODEOF'
#!/bin/bash
# Starter module loads — created by scripts/setup_cluster_env.sh.
# Verify against `module avail cuda` / `module avail anaconda` on THIS cluster
# and edit to match its actual module names.
module load cuda 2>/dev/null || module load cuda/12 2>/dev/null || \
    echo "WARN: no cuda module loaded — edit ~/load_modules_cuda.sh (see module avail cuda)" >&2
module load anaconda 2>/dev/null || module load anaconda3 2>/dev/null || \
    module load miniconda 2>/dev/null || \
    echo "WARN: no conda module loaded — edit ~/load_modules_cuda.sh (see module avail anaconda)" >&2
MODEOF
        echo "Created starter $HOME/load_modules_cuda.sh — review its module"
        echo "names (module avail cuda / anaconda) before trusting long jobs to it."
    fi
    source "$HOME/load_modules_cuda.sh"
    echo "Loaded modules:"
    module list 2>&1 || true

    # conda init is best-effort only: the shell hook is already sourced via
    # ~/load_modules_cuda.sh, so activation works without it — and on makau's
    # system conda (read-only base at /usr) `conda init` CRASHES outright
    # (elevated-subprocess TypeError, conda 4.14/py3.9), which under set -e
    # would kill the whole setup.
    if conda info --envs | grep -q "$ENV_NAME"; then
        echo "Conda env '$ENV_NAME' already exists. Updating..."
        conda init >/dev/null 2>&1 || true
        conda activate "$ENV_NAME"
        pip install -e . --upgrade          # EDIT ME: your project's install
    else
        echo "Creating conda env '$ENV_NAME'..."
        conda init >/dev/null 2>&1 || true
        conda create -n "$ENV_NAME" python=3.11 -y
        conda activate "$ENV_NAME"
        pip install -e .                    # EDIT ME: your project's install
    fi
fi

# ─── fran: driver-compatible torch wheel ───
# fran's NVIDIA driver is 575.x (CUDA 12.9). The default PyPI torch wheel is
# now cu130 and refuses to initialize CUDA there ("driver too old") — training
# silently falls back to CPU. Replace it with the cu128 build (CUDA 12.8
# runtime runs on any 12.8+ driver). Guarded by an actual driver probe, not
# the cluster name, so a future driver upgrade makes this a no-op: once
# nvidia-smi reports a 13.x-capable driver, the default wheel is fine.
if [ "$CLUSTER" = "fran" ]; then
    DRIVER_CUDA="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1)"
    if [ -z "$DRIVER_CUDA" ] || [ "${DRIVER_CUDA:-0}" -lt 580 ]; then
        echo ""
        echo "fran: driver < 580 (CUDA 12.x) — installing cu128 torch wheel..."
        pip install --force-reinstall torch --index-url https://download.pytorch.org/whl/cu128
    fi
fi

# ─── W&B setup (optional — remove if you don't use Weights & Biases) ───
echo ""
echo "Setting up Weights & Biases..."
if command -v wandb &>/dev/null; then
    if ! wandb verify 2>/dev/null; then
        echo "Run 'wandb login' to authenticate (or set WANDB_API_KEY)."
        echo "If the cluster has no internet, use WANDB_MODE=offline and sync later."
    else
        echo "W&B already configured."
    fi
fi

# ─── Create working directories ───
# DoD login profiles export $WORKDIR; anvil exports $SCRATCH instead.
WORK="${WORKDIR:-${SCRATCH:-$HOME}}"
mkdir -p "${WORK}/${ENV_NAME}-outputs"
mkdir -p "${WORK}/wandb"
mkdir -p logs

echo ""
echo "============================================"
echo "Setup complete!"
echo ""
echo "To activate:  conda activate ${ENV_NAME}"
echo "To submit:    make submit CLUSTER=${CLUSTER:-<cluster>}"
echo "Interactive:  bash scripts/slurm/interactive.sh"
echo "Output dir:   ${WORK}/${ENV_NAME}-outputs/"
echo "============================================"
