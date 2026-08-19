# ─── HPC Cluster Makefile Template ─── #
# Clusters: jean (ARL), raider (AFRL), nautilus (NAVY), wheat (ERDC),
#           fran (ARL), makau (MHPCC) — DoD HPCMP;
#           anvil (Purdue RCAC / ACCESS)
# Auth: DoD clusters use Kerberos (run `kshell && kinit` first);
#       anvil uses SSH public keys (no Kerberos, no YubiKey).
#
# SETUP: run `make configure` once — it writes config.mk (gitignored) with your
# project name, usernames, and accounts, and prints personalized ssh aliases.
# Job scripts live in scripts/slurm/ and scripts/pbs/; the default entry point
# is examples/train_smoke.py, so `make smoke` verifies a cluster end-to-end.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Personal values live in config.mk (written by `make configure`, gitignored).
# Anything set there wins over every ?= default below.
-include config.mk

# ─── Project identity (set via `make configure`, or edit the defaults) ─── #
PROJECT_NAME ?= myproject
# Your GitHub repo (deploy-key access; see README "Set up a new cluster"):
GITHUB_SSH   ?= git@github.com:your-org/$(PROJECT_NAME).git
# Per-cluster deploy key on the CLUSTER (each cluster needs its own key —
# GitHub allows a key to be registered only once):
DEPLOY_KEY   ?= $$HOME/.ssh/id_deploy

# ─── Configuration ─── #
# Override per invocation: make submit CLUSTER=nautilus NUM_GPU=4 TIME=48:00:00
CLUSTER   ?= raider

# Remote usernames (set via `make configure`). DoD HPCMP clusters share one
# username; anvil assigns its own (usually x-<name>).
DOD_USER   ?= your-dod-username
ANVIL_USER ?= your-anvil-username

# Per-cluster defaults (must precede the generic ?= block so they win).
# wheat uses PBS at ERDC. Default = 4-GPU MLA node, 96h (standard_lw queue cap).
ifeq ($(CLUSTER),wheat)
NUM_GPU   ?= 4
NODES     ?= 1
TIME      ?= 96:00:00
PARTITION ?= standard_lw
endif

# anvil (Purdue RCAC / ACCESS): SLURM, SSH-key auth, 48h walltime cap.
# Check which partitions YOUR allocation authorizes — some (e.g. NAIRR AI
# allocations) authorize ONLY one partition and reject the account elsewhere.
# If so, add a hard guard like:
#   ifneq ($(strip $(PARTITION)),ai)
#   $(error anvil: this allocation authorizes ONLY the ai partition)
#   endif
ifeq ($(CLUSTER),anvil)
NUM_GPU   ?= 4
NODES     ?= 1
TIME      ?= 48:00:00
PARTITION ?= ai
ACCOUNT   ?= $(or $(ANVIL_ACCOUNT),your-anvil-allocation)
endif

# fran (ARL DSRC, Cray EX4000): SLURM + Kerberos. AI/ML nodes carry 2x NVIDIA
# H100/H200 NVL (141 GB each), and GPU jobs must run in the AIML queue (168h
# cap), so both defaults deviate from the generic block.
ifeq ($(CLUSTER),fran)
NUM_GPU   ?= 2
NODES     ?= 1
TIME      ?= 96:00:00
PARTITION ?= AIML
endif

# Generic defaults (Slurm clusters: jean / raider / nautilus / makau)
NUM_GPU   ?= 4
NODES     ?= 1
TIME      ?= 96:00:00
# Queue/QOS: standard (default), AIML, high, debug, etc.
PARTITION ?= standard
PYTHON    ?= python
# Your HPCMP project/subproject ID (shows in `show_usage` on any DoD cluster).
# config.mk supplies DOD_ACCOUNT / ANVIL_ACCOUNT so each world resolves to the
# right account; an explicit ACCOUNT=... on the command line still wins.
ACCOUNT   ?= $(or $(DOD_ACCOUNT),YOUR_HPCMP_PROJECT_ID)
WANDB_PROJECT ?= $(PROJECT_NAME)

# Per-developer remote workspace on the cluster. Override when running in
# parallel with a collaborator so syncs don't clobber each other:
#   make submit CLUSTER=raider REMOTE_DIR=~/$(PROJECT_NAME)-alice ...
REMOTE_DIR ?= ~/$(PROJECT_NAME)
# If REMOTE_DIR came in via an env var that the local shell tilde-expanded
# (e.g. `export REMOTE_DIR=~/proj-alice` becomes `/Users/.../proj-alice` at
# export time), restore the leading "~/" so remote ssh/rsync commands resolve
# against the CLUSTER's $HOME rather than this machine's.
REMOTE_DIR := $(REMOTE_DIR:$(HOME)/%=~/%)

# Map cluster names to SSH hosts. DoD hosts are bare (the Kerberos principal
# supplies the user); anvil embeds user@ because it authenticates by SSH key.
SSH_jean     = jean01.arl.hpc.mil
SSH_raider   = raider.afrl.hpc.mil
SSH_nautilus = nautilus.navydsrc.hpc.mil
SSH_wheat    = wheat.erdc.hpc.mil
SSH_fran     = fran.arl.hpc.mil
# makau: pin a login node (like jean01). The round-robin alias makau.mhpcc.hpc.mil
# intermittently rejects GSSAPI — some nodes lack the alias host principal in
# their keytab — while every node accepts its own name (verified makau01-04).
SSH_makau    = makau01.mhpcc.hpc.mil
SSH_anvil    = $(ANVIL_USER)@anvil.rcac.purdue.edu
# Recursive so the error only fires when a remote target actually expands it;
# without the guard an unknown CLUSTER yields an empty host and ssh silently
# targets the wrong thing.
SSH_HOST     = $(or $(SSH_$(CLUSTER)),$(error Unknown CLUSTER '$(CLUSTER)'. Known: jean raider nautilus wheat fran makau anvil))

# Auth: DoD HPCMP = Kerberos/GSSAPI; anvil (ACCESS) = plain SSH public key.
ifeq ($(CLUSTER),anvil)
SSH_OPTS =
else
SSH_OPTS = -o GSSAPIAuthentication=yes
endif

# ─── GitHub is the source of truth for code ─── #
# `make sync` makes the cluster checkout match origin/$(GIT_BRANCH); any local
# cluster changes are first saved to a per-cluster `cluster-snapshot/<name>`
# branch (single writer => no cross-cluster conflicts). GIT_BRANCH defaults to
# the laptop's current branch.
# Keep these free of trailing inline comments (a trailing space corrupts the ssh cmd).
GIT_BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
# fran runs in FIPS mode: ed25519 keys are banned outright (use an ECDSA-384
# deploy key there) and naming ssh-ed25519 anywhere just adds FIPS noise.
ifeq ($(CLUSTER),fran)
GIT_SSH_KEYOPT =
else
GIT_SSH_KEYOPT = -o PubkeyAcceptedKeyTypes=+ssh-ed25519
endif
GIT_SSH_CMD = GIT_SSH_COMMAND="ssh -i $(strip $(DEPLOY_KEY)) -o IdentitiesOnly=yes $(GIT_SSH_KEYOPT)"

# ─── Per-cluster scheduler GPU args (uses NUM_GPU and PARTITION) ─── #
# Jean:     partition-based, --gres for GPU count
# Raider:   constraint + gpus-per-node + QOS
# Nautilus: constraint + typed gres + QOS
# Anvil:    plain partition (-p, not the DoD -q QOS convention) + gpus-per-node
# Fran:     partition-based (AIML queue), untyped --gres for GPU count (<=2/node)
# Makau:    typed gres (h100_sxm5 on AI/ML nodes, h100_nvl on Mixed), plain -p
# Wheat:    PBS — args built via QSUB_ARGS below; SBATCH_GPU not used.
SBATCH_GPU_jean     = --gres=aiml --gpus-per-node=$(NUM_GPU)  -p AIML
SBATCH_GPU_raider   = --constraint=mla --gpus-per-node=$(NUM_GPU) -q $(PARTITION)
SBATCH_GPU_nautilus = --constraint=mla --gres=gpu:a100:$(NUM_GPU) -q $(PARTITION)
SBATCH_GPU_anvil    = --gpus-per-node=$(NUM_GPU) -p $(strip $(PARTITION))
SBATCH_GPU_fran     = -p $(strip $(PARTITION)) --gres=gpu:$(strip $(NUM_GPU))
SBATCH_GPU_makau    = -p $(strip $(PARTITION)) --gres=gpu:$(strip $(MAKAU_GPU_TYPE)):$(strip $(NUM_GPU))
SBATCH_GPU          = $(SBATCH_GPU_$(CLUSTER))

# Common sbatch args (nodes + time + account, applied to every job)
SBATCH_COMMON = --nodes=$(NODES) --time=$(TIME) --account=$(ACCOUNT)
SBATCH_ARGS   = $(SBATCH_GPU) $(SBATCH_COMMON)

# Makau GPU node type for the typed gres request: h100_sxm5 = AI/ML nodes
# (4x H100 SXM5 80GB + node-local NVMe, default) or h100_nvl = Mixed nodes
# (1x H100 NVL 94GB — force NUM_GPU=1 with it; multi-GPU means multi-node).
MAKAU_GPU_TYPE ?= h100_sxm5

# Wheat (PBS) qsub args. ncpus=92 is the full standard/MLA node on wheat.
# nmlas=NUM_GPU targets 4-GPU MLA when NUM_GPU=4 (default) or 6-GPU MLA when NUM_GPU=6.
# For single-GPU visualization nodes, override: WHEAT_GPU_KEY=ngpus NUM_GPU=1.
WHEAT_NCPUS   ?= 92
WHEAT_GPU_KEY ?= nmlas
# $(strip) every interpolated value: target-specific assignments like
# `NUM_GPU := 1   # comment` carry trailing whitespace (Make keeps everything up
# to the #), which would otherwise split the comma-separated `-v` list into a
# stray token and make qsub reject the whole command line.
QSUB_ARGS = -A $(strip $(ACCOUNT)) -q $(strip $(PARTITION)) -l walltime=$(strip $(TIME)) \
            -l select=$(strip $(NODES)):ncpus=$(strip $(WHEAT_NCPUS)):mpiprocs=1:$(strip $(WHEAT_GPU_KEY))=$(strip $(NUM_GPU)) \
            -v NUM_NODES=$(strip $(NODES)),NUM_GPU=$(strip $(NUM_GPU)),HPC_CLUSTER=wheat -V

# Job submission dispatcher. $(call SUBMIT_JOB,script_basename,job_args)
# emits the right invocation for the current $(CLUSTER): qsub on wheat (PBS),
# sbatch on every other cluster (Slurm).
#
# Wheat's qsub doesn't support `-F "args"`, so extra arguments ride in via the
# JOB_ARGS env var (exported into the job by `qsub -V`); each PBS script
# re-tokenizes it into "$@" before launching python.
ifeq ($(CLUSTER),wheat)
SUBMIT_JOB = JOB_ARGS="$(strip $(2))" qsub $(QSUB_ARGS) scripts/pbs/$(1)
else
SUBMIT_JOB = sbatch --export=ALL,HPC_CLUSTER=$(CLUSTER),HPC_NUM_GPU=$(NUM_GPU),HPC_PROJECT=$(PROJECT_NAME) $(SBATCH_ARGS) scripts/slurm/$(1) $(2)
endif

# Per-cluster monitoring + cancellation commands (PBS vs. Slurm).
# anvil filters squeue by user, not account — ACCESS allocations are shared.
ifeq ($(CLUSTER),wheat)
STATUS_QUEUE_CMD = qstat -u $$USER
CANCEL_ONE_CMD   = qdel -W force
CANCEL_ALL_CMD   = qselect -u $$USER | xargs -r qdel -W force
else ifeq ($(CLUSTER),anvil)
STATUS_QUEUE_CMD = squeue -u $$USER -o "%.10i %.25j %.8T %.10M %.6D %R"
CANCEL_ONE_CMD   = scancel
CANCEL_ALL_CMD   = scancel -u $$USER
else
STATUS_QUEUE_CMD = squeue --account=$(ACCOUNT) -o "%.10i %.25j %.8T %.10M %.6D %R"
CANCEL_ONE_CMD   = scancel
CANCEL_ALL_CMD   = scancel -u $$USER
endif

# Cluster-specific srun args for quick single-GPU tasks (analysis, checks).
# Wheat uses qsub -I (interactive) for its analog.
SRUN_GPU_jean     = srun --account $(ACCOUNT) --gres=aiml --partition=$(PARTITION) --gpus-per-node=1 --nodes 1 --time=1:00:00
SRUN_GPU_raider   = srun --account $(ACCOUNT) --constraint=mla --gpus-per-node=1 -q $(PARTITION) --nodes 1 --time=1:00:00
SRUN_GPU_nautilus = srun --account $(ACCOUNT) --constraint=mla --gpus-per-node=1 -q $(PARTITION) --nodes 1 --time=1:00:00
SRUN_GPU_anvil    = srun --account $(strip $(ACCOUNT)) -p $(strip $(PARTITION)) --gpus-per-node=1 --nodes 1 --time=1:00:00
SRUN_GPU_fran     = srun --account $(ACCOUNT) -p $(strip $(PARTITION)) --gres=gpu:1 --nodes 1 --time=1:00:00
SRUN_GPU_makau    = srun --account $(ACCOUNT) -p $(strip $(PARTITION)) --gres=gpu:$(strip $(MAKAU_GPU_TYPE)):1 --nodes 1 --time=1:00:00
SRUN_GPU          = $(SRUN_GPU_$(CLUSTER))

# Remote environment preamble: one dispatcher script handles every cluster
# (DoD = ~/load_modules_cuda.sh + conda; anvil = Lmod + WORKDIR=$SCRATCH alias).
REMOTE_INIT = export HPC_CLUSTER=$(CLUSTER) HPC_PROJECT=$(PROJECT_NAME) && source $(REMOTE_DIR)/scripts/cluster_env.sh

# Run prefix used in output dir / log names: {PREFIX}_{jobid}
PREFIX ?= run
TAG     = $(PREFIX)_$(RUN_ID)

# ─── Help ─── #
.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Overridable variables:"
	@echo "  PROJECT_NAME=$(PROJECT_NAME)  CLUSTER=$(CLUSTER)  NUM_GPU=$(NUM_GPU)  NODES=$(NODES)  TIME=$(TIME)  PARTITION=$(PARTITION)"
	@echo "  REMOTE_DIR=$(REMOTE_DIR)   (override for parallel collaborator workspaces)"
	@echo ""
	@echo "Examples:"
	@echo "  make configure                                  # one-time: write config.mk + print your ssh aliases"
	@echo "  make smoke CLUSTER=raider                       # tiny synthetic training run to verify a cluster"
	@echo "  make submit CLUSTER=nautilus NUM_GPU=4"
	@echo "  make submit CLUSTER=jean NUM_GPU=4 NODES=2 TIME=48:00:00"
	@echo "  make submit CLUSTER=wheat                       # PBS, 4-GPU MLA"
	@echo "  make submit CLUSTER=wheat NUM_GPU=6             # 6-GPU MLA"
	@echo "  make submit CLUSTER=anvil NUM_GPU=1 TIME=0:25:00  # smoke test (short job)"
	@echo "  make submit CLUSTER=fran                        # AIML queue, 2x H100/H200 NVL"
	@echo "  make submit CLUSTER=makau MAKAU_GPU_TYPE=h100_nvl NUM_GPU=1  # Mixed node"
	@echo "  make interactive CLUSTER=nautilus NUM_GPU=4 TIME=2:00:00"
	@echo "  make transfer FROM=raider TO=nautilus RUN_ID=1650317"

# ─── One-time configuration ─── #
.PHONY: configure
configure: ## Write config.mk (project, usernames, accounts) via guided prompts + print your ssh aliases
	@bash scripts/configure.sh

# ─── Smoke test ─── #
# Submits the example job with a tiny budget. The default entry point
# (examples/train_smoke.py) trains a small MLP on synthetic data — no
# downloads, air-gap safe — and prints "SMOKE TEST PASSED". Run this on every
# new cluster and after every environment change; add NUM_GPU=4 to also
# exercise NCCL collectives.
.PHONY: smoke
smoke: NUM_GPU := 1
smoke: TIME := 0:30:00
smoke: sync ## Short tiny training job that verifies a cluster end-to-end (CLUSTER=x [NUM_GPU=4])
	ssh $(SSH_OPTS) $(SSH_HOST) \
		'$(REMOTE_INIT) && cd $(REMOTE_DIR) && $(call SUBMIT_JOB,example_job.sh,--max-steps 200 $(EXTRA_ARGS))'

# ─── Kerberos (required before any DoD cluster command) ─── #
.PHONY: kerberos
kerberos: ## Show how to initialize a Kerberos ticket (~10-hour validity)
	@echo "Run these commands manually:"
	@echo "  kshell"
	@echo "  kinit"
	@echo "  klist   # verify"

.PHONY: check-kerberos
check-kerberos:
	@klist -s 2>/dev/null || (echo "ERROR: No Kerberos ticket. Run: kshell && kinit" && exit 1)

# Per-cluster auth gate: anvil uses SSH keys (probe the connection); everything
# else requires a Kerberos ticket. Remote targets depend on check-auth.
.PHONY: check-auth
ifeq ($(CLUSTER),anvil)
check-auth:
	@ssh -o BatchMode=yes -o ConnectTimeout=8 $(SSH_HOST) true 2>/dev/null || \
		(echo "ERROR: SSH key auth to $(SSH_HOST) failed. Register your public key via the RCAC account portal and retry." && exit 1)
else
check-auth: check-kerberos
endif

# ─── Cluster Operations ─── #
.PHONY: sync
sync: check-auth ## Make a cluster's code checkout match GitHub (GIT_BRANCH=<branch>, default=laptop branch)
	@ssh $(SSH_OPTS) $(SSH_HOST) \
		'mkdir -p $(REMOTE_DIR) && cd $(REMOTE_DIR) && $(GIT_SSH_CMD) bash -s -- "$(GIT_BRANCH)" "$(GITHUB_SSH)" "$(CLUSTER)"' \
		< scripts/git_sync_cluster.sh

.PHONY: setup-cluster
setup-cluster: sync ## First-time cluster env setup (conda + deps)
	ssh $(SSH_OPTS) $(SSH_HOST) \
		'$(REMOTE_INIT) && cd $(REMOTE_DIR) && bash scripts/setup_cluster_env.sh $(CLUSTER) $(PROJECT_NAME)'

.PHONY: submit
submit: sync ## Sync + submit the example job (EXTRA_ARGS='...' passed to your entry point)
	ssh $(SSH_OPTS) $(SSH_HOST) \
		'$(REMOTE_INIT) && cd $(REMOTE_DIR) && $(call SUBMIT_JOB,example_job.sh,$(EXTRA_ARGS))'

.PHONY: interactive
interactive: check-auth ## Get an interactive GPU session on the cluster
	ssh -t $(SSH_OPTS) $(SSH_HOST) \
		'$(REMOTE_INIT) && cd $(REMOTE_DIR) && bash scripts/slurm/interactive.sh $(CLUSTER) $(NUM_GPU) $(TIME) $(ACCOUNT)'

# ─── Persistent GPU node (long-running orchestrator; survives SSH + Kerberos expiry) ─── #
# A batch job holds a GPU node and runs a detached tmux session you attach to.
# On-cluster sbatch/squeue need NO Kerberos ticket, so long-running orchestration
# lives here. NOTE: on some clusters a GPU node is EXCLUSIVE — you hold the whole
# node, so keep PERSIST_TIME modest and use PERSIST_CHAIN=1 to span longer.
#   sacctmgr show qos format=Name,MaxWall,MaxTRESMins   # confirm the walltime cap
PERSIST_CPUS        ?= 1
PERSIST_TIME        ?= 72:00:00            # SLURM [D-]HH:MM:SS; raise or chain for longer
PERSIST_SESSION     ?= orch
PERSIST_CHAIN       ?= 0                    # 1 = self-resubmit (--dependency=afterany) to span the walltime cap
PERSIST_CHAIN_LINKS ?= 3                    # number of successor jobs to chain when PERSIST_CHAIN=1

.PHONY: persist
# anvil needs no persist node: SSH-key auth means there is no Kerberos ticket
# to outlive, so submit/monitor directly from the laptop instead.
ifeq ($(CLUSTER),anvil)
.PHONY: persist persist-attach persist-stop
persist persist-attach persist-stop:
	@echo "ERROR: persist is not supported on anvil (no Kerberos to work around — submit jobs directly)." && exit 1
else
# hold 1 GPU — keep these assignments free of trailing comments.
# wheat: single-GPU viz node (ngpus=1); override WHEAT_GPU_KEY=nmlas NUM_GPU=4 for a full MLA node.
persist: NUM_GPU := 1
persist: WHEAT_GPU_KEY := ngpus
ifeq ($(CLUSTER),wheat)
persist: sync ## Hold a persistent GPU node with a tmux session (CLUSTER=wheat [PERSIST_TIME=72:00:00 PERSIST_CHAIN=1])
	ssh $(SSH_OPTS) $(SSH_HOST) \
		'$(REMOTE_INIT) && cd $(REMOTE_DIR) && mkdir -p logs && \
		PERSIST_SESSION=$(strip $(PERSIST_SESSION)) PERSIST_CHAIN=$(strip $(PERSIST_CHAIN)) PERSIST_CHAIN_LEFT=$(strip $(PERSIST_CHAIN_LINKS)) HPC_CLUSTER=wheat \
		PERSIST_QSUB_RES="-A $(strip $(ACCOUNT)) -q $(strip $(PARTITION)) -l walltime=$(strip $(PERSIST_TIME)) -l select=1:ncpus=$(strip $(WHEAT_NCPUS)):mpiprocs=1:$(strip $(WHEAT_GPU_KEY))=$(strip $(NUM_GPU))" \
		qsub -N persist -A $(strip $(ACCOUNT)) -q $(strip $(PARTITION)) -l walltime=$(strip $(PERSIST_TIME)) \
			-l select=1:ncpus=$(strip $(WHEAT_NCPUS)):mpiprocs=1:$(strip $(WHEAT_GPU_KEY))=$(strip $(NUM_GPU)) \
			-V scripts/pbs/persist.sh'
	@echo "Submitted persist PBS job on wheat. Attach with: make persist-attach CLUSTER=wheat"
else
persist: sync ## Hold a persistent GPU node with a tmux session (CLUSTER=raider [PERSIST_TIME=72:00:00 PERSIST_CHAIN=1])
	ssh $(SSH_OPTS) $(SSH_HOST) \
		'$(REMOTE_INIT) && cd $(REMOTE_DIR) && mkdir -p logs && \
		PERSIST_SBATCH_GPU="$(SBATCH_GPU)" \
		sbatch --export=ALL,HPC_CLUSTER=$(strip $(CLUSTER)),PERSIST_SESSION=$(strip $(PERSIST_SESSION)),PERSIST_CHAIN=$(strip $(PERSIST_CHAIN)),PERSIST_CHAIN_LEFT=$(strip $(PERSIST_CHAIN_LINKS)),PERSIST_CPUS=$(strip $(PERSIST_CPUS)),PERSIST_TIME=$(strip $(PERSIST_TIME)),PERSIST_ACCOUNT=$(strip $(ACCOUNT)) \
			--job-name=persist --nodes=1 --ntasks-per-node=1 --cpus-per-task=$(strip $(PERSIST_CPUS)) \
			--time=$(strip $(PERSIST_TIME)) --account=$(strip $(ACCOUNT)) $(SBATCH_GPU) \
			scripts/slurm/persist.sh'
	@echo "Submitted persist GPU job on $(CLUSTER). Attach with: make persist-attach CLUSTER=$(CLUSTER)"
endif

.PHONY: persist-attach
ifeq ($(CLUSTER),wheat)
persist-attach: check-auth ## Attach to the persistent tmux session on the compute node
	ssh -t $(SSH_OPTS) $(SSH_HOST) \
		'NODE=$$(cat $(REMOTE_DIR)/.persist_node 2>/dev/null); \
		if [ -z "$$NODE" ]; then echo "No persist node recorded (is a persist job RUNNING? make status CLUSTER=wheat)"; exit 1; fi; \
		echo "Attaching on $$NODE ..."; \
		ssh -t $$NODE "tmux attach -t $(PERSIST_SESSION)"'
else
persist-attach: check-auth ## Attach to the persistent tmux session on the compute node
	ssh -t $(SSH_OPTS) $(SSH_HOST) \
		'$(REMOTE_INIT) && JID=$$(squeue -u $$USER -n persist -t RUNNING -h -o %i | head -1); \
		if [ -z "$$JID" ]; then echo "No RUNNING persist job (check: make status CLUSTER=$(CLUSTER))"; exit 1; fi; \
		echo "Attaching to job $$JID ..."; \
		srun --jobid=$$JID --overlap --pty tmux attach -t $(PERSIST_SESSION)'
endif

.PHONY: persist-stop
ifeq ($(CLUSTER),wheat)
persist-stop: check-auth ## Release the persistent node(s) and stop any chaining
	ssh $(SSH_OPTS) $(SSH_HOST) \
		'touch $(REMOTE_DIR)/.persist_stop; \
		JIDS=$$(qselect -u $$USER -N persist 2>/dev/null); \
		if [ -n "$$JIDS" ]; then echo "Deleting persist jobs: $$JIDS"; qdel -W force $$JIDS; else echo "No persist jobs queued/running."; fi'
else
persist-stop: check-auth ## Release the persistent node(s) and stop any chaining
	ssh $(SSH_OPTS) $(SSH_HOST) \
		'touch $(REMOTE_DIR)/.persist_stop; \
		JIDS=$$(squeue -u $$USER -n persist -h -o %i); \
		if [ -n "$$JIDS" ]; then echo "Cancelling persist jobs: $$JIDS"; scancel $$JIDS; else echo "No persist jobs queued/running."; fi'
endif
endif

# ─── Monitoring ─── #
.PHONY: status
status: check-auth ## Check cluster job queue
	@ssh $(SSH_OPTS) $(SSH_HOST) '$(STATUS_QUEUE_CMD)'

.PHONY: logs
logs: check-auth ## Tail latest cluster log
	@ssh $(SSH_OPTS) $(SSH_HOST) \
		'cd $(REMOTE_DIR) && ls -t logs/*.out 2>/dev/null | head -1 | xargs tail -100'

.PHONY: logs-err
logs-err: check-auth ## Tail latest cluster stderr log (shows Python tracebacks)
	@ssh $(SSH_OPTS) $(SSH_HOST) \
		'cd $(REMOTE_DIR) && ls -t logs/*.err 2>/dev/null | head -1 | xargs tail -100'

.PHONY: cancel
cancel: check-auth ## Cancel cluster job (RUN_ID=xxx to cancel specific job, else cancels all)
	@if [ -n "$(RUN_ID)" ]; then \
		echo "Cancelling job $(RUN_ID) on $(CLUSTER)..."; \
		ssh $(SSH_OPTS) $(SSH_HOST) '$(CANCEL_ONE_CMD) $(RUN_ID)'; \
	else \
		echo "Cancelling all your jobs on $(CLUSTER)..."; \
		ssh $(SSH_OPTS) $(SSH_HOST) '$(CANCEL_ALL_CMD)'; \
	fi

# ─── Data Transfer ─── #
.PHONY: download-run
download-run: check-auth ## Download a run's outputs to ./outputs/ (RUN_ID=xxx [PREFIX=run])
	PROJECT_NAME=$(PROJECT_NAME) ANVIL_USER=$(ANVIL_USER) \
		bash scripts/download_run.sh $(RUN_ID) $(CLUSTER) $(PREFIX)

.PHONY: sync-wandb
sync-wandb: check-auth ## Download & sync offline W&B runs (CLUSTER=x [RUN_ID=xxx] [PREFIX=run])
	PROJECT_NAME=$(PROJECT_NAME) ANVIL_USER=$(ANVIL_USER) \
		bash scripts/sync_wandb_offline.sh $(CLUSTER) "$(RUN_ID)" "$(PREFIX)"

# ─── Cross-Cluster Transfer ─── #
# Transfer runs between DoD HPC clusters from your local machine.
# The source cluster SSHes to the destination cluster via Kerberos.
# The hpc-send/hpc-pull/hpc-list helpers are defined in scripts/cluster_env.sh.

FROM ?=
TO   ?=

SSH_FROM = $(SSH_$(FROM))
SSH_TO   = $(SSH_$(TO))

# Cluster-to-cluster transfer rides on Kerberos between DoD hosts; there is no
# auth path between DoD and ACCESS (anvil), so refuse it up front.
.PHONY: check-transfer-clusters
check-transfer-clusters:
	@case "$(FROM)::$(TO)" in *anvil*) \
		echo "ERROR: transfer does not support anvil (no Kerberos path between DoD and ACCESS). Use make download-run + manual upload instead."; exit 1;; \
	esac

.PHONY: transfer
transfer: check-auth check-transfer-clusters ## Send a run between clusters (FROM=x TO=y RUN_ID=z [PREFIX=run])
	@test -n "$(TO)" || (echo "ERROR: TO not set. Usage: make transfer FROM=raider TO=nautilus RUN_ID=xxx" && exit 1)
	@test -n "$(FROM)" || (echo "ERROR: FROM not set. Usage: make transfer FROM=raider TO=nautilus RUN_ID=xxx" && exit 1)
	@test -n "$(RUN_ID)" || (echo "ERROR: RUN_ID not set." && exit 1)
	@echo "Transferring $(TAG): $(FROM) → $(TO)"
	ssh $(SSH_OPTS) $(SSH_FROM) \
		'export HPC_CLUSTER=$(FROM) HPC_PROJECT=$(PROJECT_NAME) && source $(REMOTE_DIR)/scripts/cluster_env.sh && hpc-send $(TO) $(RUN_ID) $(PREFIX)'

.PHONY: transfer-pull
transfer-pull: check-auth check-transfer-clusters ## Pull a run TO a cluster FROM another (FROM=x TO=y RUN_ID=z [PREFIX=run])
	@test -n "$(TO)" || (echo "ERROR: TO not set." && exit 1)
	@test -n "$(FROM)" || (echo "ERROR: FROM not set." && exit 1)
	@test -n "$(RUN_ID)" || (echo "ERROR: RUN_ID not set." && exit 1)
	@echo "Pulling $(TAG) from $(FROM) to $(TO)"
	ssh $(SSH_OPTS) $(SSH_TO) \
		'export HPC_CLUSTER=$(TO) HPC_PROJECT=$(PROJECT_NAME) && source $(REMOTE_DIR)/scripts/cluster_env.sh && hpc-pull $(FROM) $(RUN_ID) $(PREFIX)'

.PHONY: transfer-list
transfer-list: check-auth ## List runs on a cluster (CLUSTER=raider)
	ssh $(SSH_OPTS) $(SSH_HOST) \
		'$(REMOTE_INIT) && hpc-list'

# ─── Clean ─── #
# Deletes run artifacts on ONE cluster: outputs/{PREFIX}_<ID>/, offline W&B
# runs referencing <ID>, and scheduler logs *_<ID>.{out,err}.
# Requires either RUN_ID (delete one run) or EXCLUDE (delete all except listed IDs).
EXCLUDE ?=

.PHONY: clean
clean: check-auth ## Clean run artifacts on a cluster (CLUSTER=x RUN_ID=xxx or EXCLUDE="id1 id2 ...")
	@if [ -z "$(RUN_ID)" ] && [ -z "$(EXCLUDE)" ]; then \
		echo "ERROR: must specify RUN_ID or EXCLUDE."; \
		exit 1; \
	fi
	@if [ -n "$(RUN_ID)" ]; then \
	  ssh $(SSH_OPTS) $(SSH_HOST) \
	    'BASE=$${WORKDIR:-$${SCRATCH:-$$HOME}}/$(PROJECT_NAME)-outputs; \
	     LOGS=$(REMOTE_DIR)/logs; ID="$(RUN_ID)"; \
	     echo "Removing output dirs for $$ID..."; \
	     rm -rf "$$BASE"/*_"$$ID"; \
	     echo "Removing scheduler logs for $$ID..."; \
	     find "$$LOGS" -maxdepth 1 \( -name "*_$$ID.out" -o -name "*_$$ID.err" \) \
	       -exec rm -f {} + 2>/dev/null || true; \
	     echo "Done."'; \
	else \
	  ssh $(SSH_OPTS) $(SSH_HOST) \
	    'BASE=$${WORKDIR:-$${SCRATCH:-$$HOME}}/$(PROJECT_NAME)-outputs; \
	     LOGS=$(REMOTE_DIR)/logs; KEEP="$(EXCLUDE)"; \
	     _keep() { echo " $$KEEP " | grep -q " $$1 "; }; \
	     echo "Keeping IDs: $$KEEP"; \
	     for d in "$$BASE"/*/; do \
	       [ -d "$$d" ] || continue; \
	       name=$$(basename "$$d"); id="$${name##*_}"; \
	       [ -z "$$id" ] && continue; \
	       [ -n "$$(echo "$$id" | tr -d 0-9)" ] && continue; \
	       _keep "$$id" || { echo "  removed: $$name"; rm -rf "$$d"; }; \
	     done; \
	     for f in "$$LOGS"/*.out "$$LOGS"/*.err; do \
	       [ -f "$$f" ] || continue; \
	       base=$$(basename "$$f"); stem="$${base%.*}"; id="$${stem##*_}"; \
	       [ -z "$$id" ] && continue; \
	       [ -n "$$(echo "$$id" | tr -d 0-9)" ] && continue; \
	       _keep "$$id" || { echo "  removed: $$base"; rm -f "$$f"; }; \
	     done; \
	     echo "Done."'; \
	fi
