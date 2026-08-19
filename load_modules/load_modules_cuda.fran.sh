#!/usr/bin/env bash
# ─── fran (ARL, Cray EX4000) module environment ───
# Installed to ~/load_modules_cuda.sh by `make setup-cluster CLUSTER=fran`
# (or copy it there yourself). Sourced by every login shell and job body.
#
# fran has the CSE tree on disk (/p/app/CSE/CSE.20231125, same Miniforge as
# wheat) but it is NOT wired into modules (module avail cse is empty, no
# cseinit). Equivalents used instead:
#   cseinit-noloads + cse/miniforge/latest -> source the CSE Miniforge conda.sh
#                                             directly (same file wheat's module
#                                             resolves to)
#   nvidia/cuda                            -> cuda/12.9 (Cray module; default is
#                                             11.8 which is too old for torch cu12)

module load cuda/12.9 2>/dev/null \
    || module load cuda 2>/dev/null \
    || echo "WARN: no cuda module loaded (module avail cuda)" >&2

CSE_CONDA_SH="/p/app/CSE/CSE.20231125/Release/Miniforge3-24.11.2-1/etc/profile.d/conda.sh"
if [ -f "$CSE_CONDA_SH" ]; then
    source "$CSE_CONDA_SH"
else
    echo "WARN: CSE Miniforge conda.sh not found at $CSE_CONDA_SH" >&2
fi

# Node via nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

export NODE_OPTIONS="--dns-result-order=ipv4first"

export NODE_EXTRA_CA_CERTS="/p/app/CSE/CSE.20231125/Release/Miniforge3-24.11.2-1/ssl/cacert.pem"

# DREN TLS-inspecting proxy: outbound HTTPS (pypi, huggingface, ...) is
# re-signed by "DoD WCF Signing CA DREN 3", which only the SYSTEM trust store
# knows — a fresh conda env's certifi does not, so pip/requests fail with
# CERTIFICATE_VERIFY_FAILED. Point the whole toolchain at the system bundle.
export SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt
export REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt
export CURL_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt
export PIP_CERT=/etc/pki/tls/certs/ca-bundle.crt

# ─── API keys are read from chmod-600 files, never embedded here ───
# This file is committed to git. Create the key files once on the cluster:
#   printf '%s' '<your key>' > ~/.wandb_api_key     && chmod 600 ~/.wandb_api_key
#   printf '%s' '<your key>' > ~/.anthropic_api_key && chmod 600 ~/.anthropic_api_key
[ -f "$HOME/.wandb_api_key" ]     && export WANDB_API_KEY="$(cat "$HOME/.wandb_api_key")"
[ -f "$HOME/.anthropic_api_key" ] && export ANTHROPIC_API_KEY="$(cat "$HOME/.anthropic_api_key")"

# Skip wandb's SSL verification (DREN proxy already trusted; wandb-core's
# Go TLS doesn't reliably honor the cert env vars above)
export WANDB_INSECURE_DISABLE_SSL=true
