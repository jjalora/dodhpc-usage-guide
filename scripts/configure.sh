#!/bin/bash
# ─── One-time configuration: writes config.mk and prints your ssh aliases ───
#
# The Makefile reads personal values (project name, usernames, accounts) from
# config.mk, which is gitignored — so `git pull` never conflicts with your
# settings and nothing personal gets committed.
#
# Interactive (prompts show the current value as the default):
#   make configure          # or: bash scripts/configure.sh
#
# Non-interactive (env vars preseed the answers; --yes accepts them):
#   PROJECT_NAME=myproj DOD_USER=jdoe ACCOUNT_DOD=PROJ123 bash scripts/configure.sh --yes
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="config.mk"

# Read a variable's value out of an existing config.mk (empty if absent).
from_config() {
    [ -f "$CONFIG" ] || { echo ""; return; }
    sed -n "s/^$1[[:space:]]*:*=[[:space:]]*//p" "$CONFIG" | tail -1
}

# Defaults: env var > existing config.mk > placeholder.
DEF_PROJECT="${PROJECT_NAME:-$(from_config PROJECT_NAME)}"
DEF_GITHUB="${GITHUB_SSH:-$(from_config GITHUB_SSH)}"
DEF_DOD_USER="${DOD_USER:-$(from_config DOD_USER)}"
DEF_ANVIL_USER="${ANVIL_USER:-$(from_config ANVIL_USER)}"
DEF_DOD_ACCT="${ACCOUNT_DOD:-$(from_config DOD_ACCOUNT)}"
DEF_ANVIL_ACCT="${ACCOUNT_ANVIL:-$(from_config ANVIL_ACCOUNT)}"

DEF_PROJECT="${DEF_PROJECT:-myproject}"
DEF_GITHUB="${DEF_GITHUB:-git@github.com:your-org/${DEF_PROJECT}.git}"
DEF_DOD_USER="${DEF_DOD_USER:-your-dod-username}"
DEF_ANVIL_USER="${DEF_ANVIL_USER:-your-anvil-username}"
DEF_DOD_ACCT="${DEF_DOD_ACCT:-YOUR_HPCMP_PROJECT_ID}"
DEF_ANVIL_ACCT="${DEF_ANVIL_ACCT:-your-anvil-allocation}"

NONINTERACTIVE=0
case "${1:-}" in --yes|-y) NONINTERACTIVE=1 ;; esac

# ask "Prompt" default  -> prints the answer (default on empty input / no tty)
ask() {
    local prompt="$1" def="$2" ans=""
    if [ "$NONINTERACTIVE" = "1" ]; then echo "$def"; return; fi
    if [ -t 0 ]; then
        read -r -p "$prompt [$def]: " ans || ans=""
    elif [ -r /dev/tty ]; then
        # `make configure` may not give us stdin — prompt on the terminal.
        printf "%s [%s]: " "$prompt" "$def" > /dev/tty
        read -r ans < /dev/tty || ans=""
    fi
    echo "${ans:-$def}"
}

echo "Configuring the HPC Makefile (writes $CONFIG; re-run any time)."
echo ""
V_PROJECT="$(ask "Project name (conda env + output dir names)" "$DEF_PROJECT")"
V_GITHUB="$(ask "GitHub SSH URL of this repo" "$DEF_GITHUB")"
V_DOD_USER="$(ask "DoD HPCMP username" "$DEF_DOD_USER")"
V_DOD_ACCT="$(ask "DoD HPCMP project/account ID" "$DEF_DOD_ACCT")"
V_ANVIL_USER="$(ask "Anvil username (keep default if you have no Anvil account)" "$DEF_ANVIL_USER")"
V_ANVIL_ACCT="$(ask "Anvil allocation/account" "$DEF_ANVIL_ACCT")"

cat > "$CONFIG" <<EOF
# Personal values for the HPC Makefile — written by scripts/configure.sh.
# Gitignored. Edit freely, or re-run: make configure
PROJECT_NAME  := $V_PROJECT
GITHUB_SSH    := $V_GITHUB
DOD_USER      := $V_DOD_USER
ANVIL_USER    := $V_ANVIL_USER
DOD_ACCOUNT   := $V_DOD_ACCT
ANVIL_ACCOUNT := $V_ANVIL_ACCT
EOF

echo ""
echo "Wrote $CONFIG:"
sed 's/^/  /' "$CONFIG"

echo ""
echo "Paste these aliases into your ~/.zshrc (Mac) or ~/.bashrc (Linux):"
echo ""
cat <<EOF
# Quick aliases per cluster
alias jean="ssh ${V_DOD_USER}@jean01.arl.hpc.mil"
alias raider="ssh ${V_DOD_USER}@raider.afrl.hpc.mil"
alias wheat="ssh ${V_DOD_USER}@wheat.erdc.hpc.mil"
alias nautilus="ssh ${V_DOD_USER}@nautilus.navydsrc.hpc.mil"
alias anvil="ssh ${V_ANVIL_USER}@anvil.rcac.purdue.edu"
alias makau="ssh ${V_DOD_USER}@makau.mhpcc.hpc.mil"
alias fran="ssh ${V_DOD_USER}@fran.arl.hpc.mil"
EOF

echo ""
echo "Next steps:"
echo "  kshell && kinit                        # Kerberos ticket (DoD clusters)"
echo "  make sync CLUSTER=<cluster>            # put the code on the cluster"
echo "  make setup-cluster CLUSTER=<cluster>   # one-time env setup"
echo "  make smoke CLUSTER=<cluster>           # verify the cluster end-to-end"
