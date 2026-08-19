#!/usr/bin/env bash
# ─── makau (MHPCC, Cray XD2000) module environment ───
# Installed to ~/load_modules_cuda.sh by `make setup-cluster CLUSTER=makau`
# (or copy it there yourself). Sourced by every login shell and job body.
#
# makau has NO CSE tree (no cseinit, no cse/miniforge — module avail cse is
# empty) and no standalone cuda module. Equivalents used instead:
#   cse/miniforge/latest  -> system-wide conda at /usr (conda 4.14, hook at
#                            /etc/profile.d/conda.sh); envs land in ~/.conda/envs
#   nvidia/cuda           -> nvidia/2026/nvhpc-nompi/26.3 (CUDA without an MPI
#                            stack; conda-installed PyTorch ships its own CUDA
#                            runtime, so this mainly provides nvcc/libs)
#   CSE cacert.pem        -> RHEL system CA bundle

module load nvidia/2026/nvhpc-nompi/26.3 2>/dev/null \
    || module load nvidia/2023/nvhpc-byo-compiler/23.11 2>/dev/null \
    || echo "WARN: no nvidia/nvhpc module loaded (module avail nvidia)" >&2
source /etc/profile.d/conda.sh

# Node via nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

export NODE_OPTIONS="--dns-result-order=ipv4first"

export NODE_EXTRA_CA_CERTS="/etc/pki/tls/certs/ca-bundle.crt"

# ─── API keys are read from chmod-600 files, never embedded here ───
# This file is committed to git. Create the key files once on the cluster:
#   printf '%s' '<your key>' > ~/.wandb_api_key     && chmod 600 ~/.wandb_api_key
#   printf '%s' '<your key>' > ~/.anthropic_api_key && chmod 600 ~/.anthropic_api_key
[ -f "$HOME/.wandb_api_key" ]     && export WANDB_API_KEY="$(cat "$HOME/.wandb_api_key")"
[ -f "$HOME/.anthropic_api_key" ] && export ANTHROPIC_API_KEY="$(cat "$HOME/.anthropic_api_key")"

# Skip wandb's SSL verification (DREN proxy already trusted; wandb-core's
# Go TLS doesn't reliably honor cert env vars)
export WANDB_INSECURE_DISABLE_SSL=true
