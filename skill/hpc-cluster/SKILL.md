---
name: hpc-cluster
description: Run, monitor, and debug training jobs on the DoD HPCMP clusters (jean, raider, nautilus, fran, makau = SLURM; wheat = PBS Pro) and Purdue Anvil (ACCESS, SLURM, SSH-key auth) through the helper kit's make targets. Use when the user mentions a cluster by name, Kerberos/kinit/YubiKey, sbatch/squeue/scancel, qsub/qstat/qdel, "submit a job", "check the queue", "tail the log", "smoke test", "sync to the cluster", "interactive GPU node", or offline W&B sync.
license: MIT
metadata:
  source: github.com/jjalora/dodhpc-usage-guide
  version: "1.0"
---

# HPC cluster operations (DoD HPCMP + Anvil)

This project carries the DoD HPC helper kit: `hpc.mk` (included from the `Makefile`),
`scripts/` (job templates + cluster plumbing), `load_modules/` (per-cluster module files),
and `config.mk` (the user's usernames and accounts, gitignored). Every cluster is driven
from the laptop with `make <target> CLUSTER=<c>`. Run `make help` to see the live target
list. Per-cluster flags, hosts, and quirks: [references/clusters.md](references/clusters.md).

## Safety rules (always)

1. **Authentication is the user's job.** DoD clusters (jean, raider, nautilus, wheat, fran,
   makau) need a Kerberos ticket from the HPCMP kit: the user runs `kshell`, then `kinit`
   (YubiKey prompt). Check with `klist -s` (exit 0 = valid; tickets last ~10 h). Anvil uses
   SSH keys only: check with `make check-auth CLUSTER=anvil`. If auth fails, tell the user
   exactly which command to run and stop. Never edit Kerberos/SSH config, never store,
   forge, or cache credentials, never "work around" an expired ticket.
2. **Confirm before**: submitting a job longer than a smoke test, holding a persistent node,
   deleting or overwriting remote data (`clean-runs`), cross-cluster transfers, syncing W&B to
   the cloud, or changing modules / environment files on a cluster. Show the exact command
   and wait for a yes.
3. **Safe without asking**: `make status`, `make logs`, `make logs-err`, `make check-auth`,
   `make smoke-wait`, reading files.
4. **Cancel-all** (`make cancel` with no `RUN_ID`) kills every job of the user: require a
   second explicit confirmation.
5. Keep usernames, scratch paths, and keys out of committed files (`config.mk` is gitignored
   for this reason).

## The standard loop

```bash
make sync CLUSTER=raider                     # code -> cluster (git; SYNC_MODE=rsync to rsync)
make submit CLUSTER=raider NUM_GPU=4 TIME=24:00:00 EXTRA_ARGS='--lr 1e-4'
make status CLUSTER=raider                   # queue
make logs CLUSTER=raider                     # newest stdout (progress)
make logs-err CLUSTER=raider                 # newest stderr (Python tracebacks)
make cancel CLUSTER=raider RUN_ID=<jobid>
```

`submit` runs `scripts/slurm/example_job.sh` (or `scripts/pbs/example_job.sh` on wheat).
The launch lines at the bottom of those two templates call the project's entry point; the
rest is cluster plumbing. `EXTRA_ARGS` reaches the entry point unchanged (on wheat via the
`JOB_ARGS` env var). Output dirs are `$WORKDIR/<project>-outputs/run_<jobid>` on the
cluster; scheduler logs are `logs/run_<jobid>.{out,err}` in the remote checkout.

Knobs: `CLUSTER`, `NUM_GPU`, `NODES`, `TIME` (HH:MM:SS), `PARTITION`, `ACCOUNT`,
`EXTRA_ARGS`, `REMOTE_DIR` (per-developer checkout dir on the cluster), `GIT_BRANCH`.

## First contact with a cluster (in order)

```bash
make deploy-key CLUSTER=<c>       # cluster-side GitHub deploy key (gh registers it, else manual)
make setup-cluster CLUSTER=<c>    # installs the module file, creates the conda env, installs the project
make smoke CLUSTER=<c>            # 200-step synthetic job, 1 GPU
make smoke-wait CLUSTER=<c>       # polls; exit 0 PASSED / 1 FAILED / 2 still queued (re-run later)
```

Without a deploy key (repo not on GitHub, no `gh`): `SYNC_MODE=rsync make smoke CLUSTER=<c>`
rsyncs the working tree instead. Do not alternate modes on one remote checkout.

A passing smoke proves: auth, sync, scheduler flags, modules, conda env, CUDA, and (with
`NUM_GPU=4`) NCCL collectives. `smoke-wait` warns when the job ran on CPU: that is a
torch-wheel-vs-driver mismatch, not a pass.

## Wiring a real entry point

Edit the launch lines in `scripts/slurm/example_job.sh` and `scripts/pbs/example_job.sh`:
replace `examples/train_smoke.py` with the project's script and keep `--output-dir` and
`"$@"`. Keep the templates free of cluster-specific `#SBATCH`/`#PBS` resource directives;
those come from `hpc.mk`. If the project needs extra `pip` steps on the cluster, set
`HPC_INSTALL_CMD := <command>` in `config.mk` and re-run `make setup-cluster`.

## When a job fails

Classify before changing anything, in this order: auth (no ticket / key) → environment
(modules, conda env, torch wheel) → filesystem/path (`$WORKDIR` differs per cluster) →
scheduler rejection (partition, account, walltime cap, gres form) → your code (traceback in
`logs-err`) → OOM → NCCL/DDP hang → NaN. Check the cluster's quirks in
[references/clusters.md](references/clusters.md) first; most strange failures are known.
Then rerun the smallest thing that tests the hypothesis (`make smoke`, `NODES=1`, a short
`TIME`), never a broad rewrite.

## Other targets

- `make interactive CLUSTER=<c> NUM_GPU=<n> TIME=2:00:00`: shell on a GPU node (holds an
  allocation, so confirm first).
- `make persist` / `persist-attach` / `persist-stop`: batch job holding a GPU node with a
  detached tmux, for orchestration that must outlive the laptop's 10 h Kerberos ticket.
  Not available on Anvil (no ticket to outlive).
- `make transfer FROM=<c1> TO=<c2> RUN_ID=<id>` / `transfer-pull` / `transfer-list`:
  DoD-to-DoD only (Kerberos hop). Anvil pairs are refused; go through the laptop.
- `make download-run CLUSTER=<c> RUN_ID=<id>`: rsync a run's outputs to `./outputs/`.
- `make sync-wandb CLUSTER=<c> [RUN_ID=<id>]`: pull offline W&B runs and sync them (confirm).
- `make clean-runs CLUSTER=<c> RUN_ID=<id>` or `EXCLUDE="id1 id2"`: destructive, confirm.

## Native scheduler commands

Prefer the make targets. When already on a login node, the equivalent native commands and
the exact per-cluster resource flags are in [references/clusters.md](references/clusters.md).
Always pass the cluster name into the job (`--export=ALL,HPC_CLUSTER=<c>` / `-v HPC_CLUSTER=wheat`);
compute-node hostnames do not identify the cluster, and an `unknown` cluster skips the
cluster-gated NCCL settings.
