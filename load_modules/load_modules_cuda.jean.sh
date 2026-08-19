#!/usr/bin/env bash
# ─── jean (ARL) module environment ───
# Installed to ~/load_modules_cuda.sh by `make setup-cluster CLUSTER=jean`
# (or copy it there yourself). Sourced by every login shell and job body.
module load cseinit-noloads
module load cse/miniforge/latest
module load cuda
source /p/app/CSE/CSE/Release/Miniforge3-24.11.2-1/etc/profile.d/conda.sh

# Node via nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

export NODE_OPTIONS="--dns-result-order=ipv4first"

export NODE_EXTRA_CA_CERTS="/p/app/CSE/CSE/Release/Miniforge3-24.11.2-1/ssl/cacert.pem"

# ─── TLS / certs ───
# Point the Python/curl toolchain at the system trust store (knows the DREN
# proxy's signing CA; a fresh conda env's certifi does not).
SYS=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
export SSL_CERT_FILE=$SYS
export REQUESTS_CA_BUNDLE=$SYS
export CURL_CA_BUNDLE=$SYS
# httpx ignores those env vars (it hard-codes certifi), so if needed also append into certifi:
#cat "$SYS" >> "$(python -c 'import certifi; print(certifi.where())')"

# ─── Secrets (never embed keys in this file — it is committed to git) ───
# Keys live in chmod-600 files in $HOME and are read at shell init. Create once:
#   printf '%s' '<your key>' > ~/.wandb_api_key     && chmod 600 ~/.wandb_api_key
#   printf '%s' '<your key>' > ~/.anthropic_api_key && chmod 600 ~/.anthropic_api_key
[ -f "$HOME/.wandb_api_key" ]     && export WANDB_API_KEY="$(cat "$HOME/.wandb_api_key")"
[ -f "$HOME/.anthropic_api_key" ] && export ANTHROPIC_API_KEY="$(cat "$HOME/.anthropic_api_key")"

# Skip wandb's SSL verification (DREN proxy already trusted; wandb-core's
# Go TLS doesn't reliably honor the cert env vars above)
export WANDB_INSECURE_DISABLE_SSL=true
