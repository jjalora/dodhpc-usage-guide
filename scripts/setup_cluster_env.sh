#!/bin/bash
# ─── One-time setup on a cluster ───
# Run this after syncing code to the cluster for the first time.
#
# Usage (on the cluster login node):
#   bash scripts/setup_cluster_env.sh [cluster] [project_name]
# The Makefile's `make setup-cluster CLUSTER=<c>` passes both; without them we
# fall back to $HPC_CLUSTER / $HPC_PROJECT, then a filesystem probe.
#
# Project install: HPC_INSTALL_CMD (config.mk / env) wins; otherwise auto-detect
# pyproject.toml|setup.py -> pip install -e ., requirements.txt -> pip install -r.
# torch is installed afterwards if the project did not bring it (the smoke
# test needs it).

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

install_project() {
    if [ -n "${HPC_INSTALL_CMD:-}" ]; then
        echo "Installing project: $HPC_INSTALL_CMD"; eval "$HPC_INSTALL_CMD"
    elif [ -f pyproject.toml ] || [ -f setup.py ]; then
        echo "Installing project: pip install -e ."; pip install -e .
    elif [ -f requirements.txt ]; then
        echo "Installing project: pip install -r requirements.txt"; pip install -r requirements.txt
    else
        echo "No pyproject.toml / setup.py / requirements.txt — skipping project install."
    fi
    python -c "import torch" 2>/dev/null || { echo "Installing torch (needed by the smoke test)..."; pip install torch; }
}

# ─── Usable TMPDIR ───
# pip unpacks multi-GB wheels (torch alone is ~2.5 GB) into $TMPDIR. Several DoD
# clusters point TMPDIR at $WORKDIR: on makau that was /p/work, which sat at
# 499.7 G against a 450 G quota with the grace period expired, so the install died
# with "OSError: [Errno 122] Disk quota exceeded" pointing at a stdlib tempfile.py
# — nowhere near the real cause. Probe with a real write (an over-quota Lustre
# accepts a few MB and then truncates, so check the resulting SIZE, not just the
# exit status) and fall back to somewhere that works.
ensure_tmpdir() {
    local d probe want=134217728   # 128 MB
    for d in "${TMPDIR:-}" "$HOME/tmp" /tmp; do
        [ -n "$d" ] || continue
        mkdir -p "$d" 2>/dev/null || continue
        probe="$d/.hpckit_tmp_probe.$$"
        # `|| true`: this script runs under `set -e` and dd legitimately fails
        # on the very filesystem we are trying to rule out.
        dd if=/dev/zero of="$probe" bs=1M count=128 >/dev/null 2>&1 || true
        if [ "$(wc -c < "$probe" 2>/dev/null || echo 0)" -ge "$want" ]; then
            rm -f "$probe"
            if [ "$d" != "${TMPDIR:-}" ]; then
                echo "NOTE: \$TMPDIR (${TMPDIR:-unset}) cannot hold a large write — using $d instead."
                echo "      That filesystem is probably over quota; check with:"
                echo "        lfs quota -h -u \$USER \$(df -P \"${TMPDIR:-/tmp}\" | tail -1 | awk '{print \$6}')"
            fi
            export TMPDIR="$d"
            return 0
        fi
        rm -f "$probe" 2>/dev/null
    done
    echo "WARN: no TMPDIR with room for a 128 MB write — pip will likely fail." >&2
}
ensure_tmpdir

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
        install_project
    else
        echo "Creating conda env at '$ENV_PREFIX'..."
        mkdir -p "$(dirname "$ENV_PREFIX")"
        conda create --prefix "$ENV_PREFIX" python=3.11 -y
        conda activate "$ENV_PREFIX"
        install_project
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
    # Where the env lives. A torch+CUDA env is 10-20 GB, so this is quota-
    # sensitive — but do NOT assume $WORKDIR is the roomy one. Measured on makau:
    # $HOME was 13.5 G of a 90 G quota while $WORKDIR (/p/work) was 499.7 G against
    # a 450 G quota with the grace period EXPIRED, so every write there failed with
    # "OSError: [Errno 122] Disk quota exceeded". $WORKDIR is also purged Lustre,
    # which the anvil branch above deliberately refuses to put an env on.
    # Default therefore stays with conda's normal by-name env (~/.conda/envs);
    # point HPC_ENV_ROOT at a large, non-purged filesystem to override.
    #
    # If a `Disk quota exceeded` shows up here, check BOTH filesystems before
    # moving anything:  lfs quota -h -u $USER /p/home ; lfs quota -h -u $USER /p/work
    ENV_ROOT="${HPC_ENV_ROOT:-}"
    ENV_PREFIX="${ENV_ROOT:+$ENV_ROOT/$ENV_NAME}"

    if [ -n "$ENV_PREFIX" ] && [ -x "$ENV_PREFIX/bin/python" ]; then
        echo "Conda env at '$ENV_PREFIX' already exists. Updating..."
        conda init >/dev/null 2>&1 || true
        conda activate "$ENV_PREFIX"
        install_project
    elif [ -n "$ENV_PREFIX" ]; then
        echo "Creating conda env at '$ENV_PREFIX' (HPC_ENV_ROOT)..."
        conda init >/dev/null 2>&1 || true
        mkdir -p "$ENV_ROOT"
        conda create --prefix "$ENV_PREFIX" python=3.11 -y
        conda activate "$ENV_PREFIX"
        install_project
    elif conda info --envs 2>/dev/null | grep -qE "^$ENV_NAME[[:space:]]"; then
        echo "Conda env '$ENV_NAME' already exists. Updating..."
        echo "  (in \$HOME; if this hits a quota, remove it with"
        echo "   'conda env remove -n $ENV_NAME' and re-run with HPC_ENV_ROOT=<big-fs>)"
        conda init >/dev/null 2>&1 || true
        conda activate "$ENV_NAME"
        install_project
    else
        echo "Creating conda env '$ENV_NAME'..."
        conda init >/dev/null 2>&1 || true
        conda create -n "$ENV_NAME" python=3.11 -y
        conda activate "$ENV_NAME"
        install_project
    fi
fi

# ─── Driver-compatible torch wheel (every cluster) ───
# The default PyPI torch wheel is now cu13x, which needs an r580+ NVIDIA driver.
# On a CUDA 12.x driver it refuses to initialize CUDA ("driver too old") and
# training silently falls back to CPU — a passing smoke test that proves nothing.
# Replace it with the cu128 build (the CUDA 12.8 runtime runs on any 12.8+ driver).
#
# Gated on an actual driver probe, never on the cluster name: this bit fran first,
# but any cluster on a 12.x driver has it, and a driver upgrade makes this a no-op.
#
# Login nodes usually have no GPU, so nvidia-smi is tried on a compute node first
# and we only fall back to the local probe. An indeterminate probe is NOT treated
# as "old" — that would downgrade healthy r580+ clusters; the smoke test's
# "ran on CPU" warning is the backstop.
# Probe the LOGIN node only. Never srun: outside a job that is a real allocation
# (billable, and it pends on a busy cluster), and sinfo returns a compressed
# hostlist like nid[001000-001127] that would request every node in the range.
DRIVER_MAJOR="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
DRIVER_MAJOR="${DRIVER_MAJOR%%.*}"

# Login nodes usually have no GPU, so the probe often comes back empty. Fall back
# to what we know per cluster rather than guessing — an indeterminate probe used
# to mean "keep the default wheel", which silently put fran (confirmed 575.x)
# back on CPU. Add a cluster here once you have measured its driver.
if [ -z "$DRIVER_MAJOR" ]; then
    case "$CLUSTER" in
        fran) DRIVER_MAJOR=575 ;;   # ARL Cray EX4000, CUDA 12.9 — measured
        jean) DRIVER_MAJOR=565 ;;   # ARL A100-PCIE nodes            — measured
    esac
fi
if [ -n "$DRIVER_MAJOR" ] && [ "$DRIVER_MAJOR" -lt 580 ] 2>/dev/null; then
    echo ""
    echo "$CLUSTER: NVIDIA driver $DRIVER_MAJOR.x (< 580, CUDA 12.x) — installing cu128 torch wheel..."
    # DoD networks make this awkward twice over: DREN's TLS interception breaks
    # cert validation (hence the CA bundle in the module files), and on jean the
    # firewall refuses download-r2.pytorch.org outright, so the pytorch.org index
    # resolves metadata and then dies with [Errno 111] Connection refused.
    # PyPI IS reachable, and torch 2.8.x ships cu128 as its DEFAULT wheel — so
    # fall back to pinning the version rather than switching the index.
    TORCH_CU12_FALLBACK="${TORCH_CU12_FALLBACK:-2.8.0}"
    pip install --force-reinstall torch --index-url https://download.pytorch.org/whl/cu128 || {
        echo ""
        echo "  pytorch.org unreachable from $CLUSTER — falling back to PyPI torch==$TORCH_CU12_FALLBACK (bundles cu128)."
        pip install --force-reinstall "torch==$TORCH_CU12_FALLBACK"
    }
elif [ -z "$DRIVER_MAJOR" ]; then
    echo ""
    echo "NOTE: could not probe the NVIDIA driver from this login node; keeping the default"
    echo "      torch wheel. If the smoke test warns it ran on CPU, the driver is CUDA 12.x —"
    echo "      fix with: pip install --force-reinstall torch --index-url https://download.pytorch.org/whl/cu128"
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
