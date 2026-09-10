#!/bin/bash
# ─── Install the DoD HPC helper kit into a project ───
#
#   bash install.sh --target <repo-dir> --dod-user <dod-username> --anvil-user <x-username>
#                   [--project <name>] [--github-ssh <git@github.com:owner/repo.git>]
#                   [--install-cmd '<how to install your project on the cluster>']
#
# Copies hpc.mk + scripts/ + load_modules/ + examples/train_smoke.py into the
# target, adds `include hpc.mk` to its Makefile, writes config.mk (gitignored)
# with your usernames, installs the `hpc-cluster` agent skill where Claude Code,
# Codex, and OpenCode each look for it, and appends a short HPC section to
# AGENTS.md / CLAUDE.md. Idempotent: re-run to update the kit.
#
# Standalone (no checkout): the script clones the guide into a temp dir itself.
set -euo pipefail

TARGET=""; DOD_USER=""; ANVIL_USER=""; PROJECT=""; GITHUB_SSH=""; INSTALL_CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target)      TARGET="$2"; shift 2 ;;
        --dod-user)    DOD_USER="$2"; shift 2 ;;
        --anvil-user)  ANVIL_USER="$2"; shift 2 ;;
        --project)     PROJECT="$2"; shift 2 ;;
        --github-ssh)  GITHUB_SSH="$2"; shift 2 ;;
        --install-cmd) INSTALL_CMD="$2"; shift 2 ;;
        -h|--help)     sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done
[ -n "$TARGET" ] && [ -n "$DOD_USER" ] && [ -n "$ANVIL_USER" ] || {
    echo "ERROR: --target, --dod-user and --anvil-user are required (see --help)"; exit 1; }
[ -d "$TARGET" ] || { echo "ERROR: target dir '$TARGET' does not exist"; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

# Locate the kit: the directory of this script, or a fresh clone when piped in.
KIT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ ! -f "$KIT/hpc.mk" ]; then
    KIT="$(mktemp -d)"
    echo "Fetching the kit into $KIT ..."
    git clone -q --depth 1 https://github.com/jjalora/dodhpc-usage-guide.git "$KIT"
fi

# Derive project name and GitHub URL from the target repo when not given.
PROJECT="${PROJECT:-$(basename "$TARGET")}"
if [ -z "$GITHUB_SSH" ]; then
    ORIGIN="$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)"
    case "$ORIGIN" in
        git@github.com:*) GITHUB_SSH="$ORIGIN" ;;
        https://github.com/*) GITHUB_SSH="git@github.com:${ORIGIN#https://github.com/}"; GITHUB_SSH="${GITHUB_SSH%.git}.git" ;;
        *) GITHUB_SSH="git@github.com:your-org/${PROJECT}.git" ;;
    esac
fi

echo "Installing HPC kit -> $TARGET  (project=$PROJECT, dod=$DOD_USER, anvil=$ANVIL_USER)"

# ─── 1. Kit files ───
mkdir -p "$TARGET/scripts/slurm" "$TARGET/scripts/pbs" "$TARGET/load_modules" "$TARGET/examples"
cp "$KIT/hpc.mk" "$TARGET/hpc.mk"
cp "$KIT"/scripts/*.sh "$TARGET/scripts/"
cp "$KIT"/scripts/slurm/*.sh "$TARGET/scripts/slurm/"
cp "$KIT"/scripts/pbs/*.sh "$TARGET/scripts/pbs/"
cp "$KIT"/load_modules/*.sh "$TARGET/load_modules/"
# The smoke entry point is only seeded, never overwritten (you may have edited it).
[ -f "$TARGET/examples/train_smoke.py" ] || cp "$KIT/examples/train_smoke.py" "$TARGET/examples/"
chmod +x "$TARGET"/scripts/*.sh "$TARGET"/scripts/slurm/*.sh "$TARGET"/scripts/pbs/*.sh

# ─── 2. Makefile include ───
if [ ! -f "$TARGET/Makefile" ]; then
    printf 'include hpc.mk\n' > "$TARGET/Makefile"
elif ! grep -qE '^[[:space:]]*-?include[[:space:]]+hpc\.mk' "$TARGET/Makefile"; then
    printf '\n# DoD HPC helper kit (github.com/jjalora/dodhpc-usage-guide)\ninclude hpc.mk\n' >> "$TARGET/Makefile"
fi

# ─── 3. .gitignore ───
touch "$TARGET/.gitignore"
for line in config.mk .hpc_smoke_job logs/ outputs/ smoke_output/ wandb_offline_sync/; do
    grep -qxF "$line" "$TARGET/.gitignore" || echo "$line" >> "$TARGET/.gitignore"
done

# ─── 4. config.mk (personal, gitignored) ───
( cd "$TARGET" && PROJECT_NAME="$PROJECT" GITHUB_SSH="$GITHUB_SSH" DOD_USER="$DOD_USER" \
    ANVIL_USER="$ANVIL_USER" bash scripts/configure.sh --yes >/dev/null )
[ -n "$INSTALL_CMD" ] && printf 'HPC_INSTALL_CMD := %s\n' "$INSTALL_CMD" >> "$TARGET/config.mk"

# ─── 5. Agent skill: one copy, visible to Claude Code, Codex, and OpenCode ───
# Claude Code reads .claude/skills; Codex reads .agents/skills; OpenCode reads both.
mkdir -p "$TARGET/.claude/skills" "$TARGET/.agents/skills"
rm -rf "$TARGET/.claude/skills/hpc-cluster"
cp -R "$KIT/skill/hpc-cluster" "$TARGET/.claude/skills/hpc-cluster"
if [ ! -e "$TARGET/.agents/skills/hpc-cluster" ]; then
    ln -s ../../.claude/skills/hpc-cluster "$TARGET/.agents/skills/hpc-cluster"
fi

# ─── 6. Agent instructions (AGENTS.md for Codex/OpenCode, CLAUDE.md for Claude Code) ───
MARK="<!-- hpc-cluster-kit -->"
BLOCK="$(cat <<MD

$MARK
## HPC clusters (DoD HPCMP + Purdue Anvil)

This repo carries the DoD HPC helper kit (\`hpc.mk\`, \`scripts/\`, \`load_modules/\`) from
github.com/jjalora/dodhpc-usage-guide. Before any cluster work, read the \`hpc-cluster\`
skill at \`.claude/skills/hpc-cluster/SKILL.md\`. Rules: drive clusters through the
\`make\` targets (\`make help\`); DoD clusters need a Kerberos ticket that only the user can
obtain interactively (\`kshell\` then \`kinit\`), so never forge, cache, or work around
credentials; Anvil uses SSH keys. Ask before submitting anything longer than a smoke test,
deleting remote data, or syncing W&B to the cloud. Monitoring (\`make status\`, \`make logs\`)
is always safe.
MD
)"
for f in AGENTS.md CLAUDE.md; do
    touch "$TARGET/$f"
    grep -qF "$MARK" "$TARGET/$f" || printf '%s\n' "$BLOCK" >> "$TARGET/$f"
done

cat <<MSG

Installed. Files: hpc.mk, scripts/, load_modules/, examples/train_smoke.py, config.mk,
.claude/skills/hpc-cluster (+ .agents/skills symlink), AGENTS.md / CLAUDE.md section.

Next (per cluster; DoD clusters need a ticket first: kshell, then kinit):
  make deploy-key CLUSTER=<c>       # register this cluster's GitHub deploy key (or use SYNC_MODE=rsync)
  make setup-cluster CLUSTER=<c>    # one-time: modules + conda env + your project
  make smoke CLUSTER=<c> && make smoke-wait CLUSTER=<c>
MSG
