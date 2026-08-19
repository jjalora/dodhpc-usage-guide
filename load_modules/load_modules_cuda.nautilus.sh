#!/usr/bin/env bash
# ─── nautilus (NAVY) module environment ───
# Installed to ~/load_modules_cuda.sh by `make setup-cluster CLUSTER=nautilus`
# (or copy it there yourself). Sourced by every login shell and job body.
module load cseinit-noloads
module load cse/miniforge/latest
module load cuda
source /p/app/CSE/CSE.20231125/Release/Miniforge3-24.11.2-1/etc/profile.d/conda.sh

# Node via nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

export NODE_OPTIONS="--dns-result-order=ipv4first"

export NODE_EXTRA_CA_CERTS="/p/app/CSE/CSE.20231125/Release/Miniforge3-24.11.2-1/ssl/cacert.pem"

# ─── Secrets (never embed keys in this file — it is committed to git) ───
# Keys live in chmod-600 files in $HOME and are read at shell init. Create once:
#   printf '%s' '<your key>' > ~/.wandb_api_key     && chmod 600 ~/.wandb_api_key
#   printf '%s' '<your key>' > ~/.anthropic_api_key && chmod 600 ~/.anthropic_api_key
[ -f "$HOME/.wandb_api_key" ]     && export WANDB_API_KEY="$(cat "$HOME/.wandb_api_key")"
[ -f "$HOME/.anthropic_api_key" ] && export ANTHROPIC_API_KEY="$(cat "$HOME/.anthropic_api_key")"

# Skip wandb's SSL verification (DREN proxy already trusted; wandb-core's
# Go TLS doesn't reliably honor cert env vars)
export WANDB_INSECURE_DISABLE_SSL=true
