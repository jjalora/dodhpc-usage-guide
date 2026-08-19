# DoD HPC usage guide

This repo is the one-stop reference for using the DoD High Performance Computing Modernization Program (HPCMP) clusters with the AI Studio — from getting an account to training and serving models. It also ships the helper kit that makes the clusters easy to drive from your laptop: a `Makefile` plus `scripts/` that handle authentication checks, code sync, job submission on both schedulers (SLURM and PBS Pro), monitoring, transfers, and a smoke test that verifies a cluster end-to-end.

General user documentation lives at [centers.hpc.mil/users](https://centers.hpc.mil/users/index.html) — refer to it for anything this guide does not cover.

New here? Work through sections 1–4 in order (start section 1 early — the background check takes weeks), then run the [smoke test](#6-smoke-test).

## Table of contents

1. [Get an account](#1-get-an-account)
   - [Complete cyber awareness training](#complete-cyber-awareness-training)
   - [Apply for a pIE account](#apply-for-a-pie-account)
   - [After you have a pIE account](#after-you-have-a-pie-account)
   - [Background check](#background-check)
2. [Set up your machine](#2-set-up-your-machine)
   - [Install Kerberos](#install-kerberos)
   - [SSH configuration](#ssh-configuration)
   - [The HPC Portal](#the-hpc-portal)
3. [Clusters we have access to](#3-clusters-we-have-access-to)
4. [Set up a new cluster](#4-set-up-a-new-cluster)
5. [The helper kit](#5-the-helper-kit)
6. [Smoke test](#6-smoke-test)
7. [Running jobs](#7-running-jobs)
   - [Interactive jobs](#interactive-jobs)
   - [Batch jobs](#batch-jobs)
   - [Distributed training](#distributed-training)
   - [Persistent nodes](#persistent-nodes)
8. [Transfer data and sync offline W&B](#8-transfer-data-and-sync-offline-wb)
9. [Software on the clusters](#9-software-on-the-clusters)
10. [Per-cluster quirks](#10-per-cluster-quirks)
11. [Shortcut make commands](#11-shortcut-make-commands)

## 1. Get an account

HPC users must be citizens of the USA. Contact Lt Col John Alora to begin the process. *The goal is to obtain the all-powerful YubiKey that unlocks cluster access.*

### Complete cyber awareness training

1. Go to https://www.cyber.mil/cyber-awareness-challenge
2. Complete the training and save the certificate PDF. You will upload or email it in a later step.

### Apply for a pIE account

The pIE (portal to the Information Environment) account is your HPCMP identity.

1. Go to https://ieapp.hpc.mil/info/login/pieLogin and click "Apply for pIE Account" → "Request login without CAC".
2. Fill out New User Account:
   1. Preferred Kerberos Realm: HPCMP.HPC.MIL
   2. Select org: OUSAF (Other USAF)
   3. Company/Org: Stanford University / AI Studio
   4. Business/School Address: 496 Lomita Mall, Stanford, CA 94305
   5. Email address: Stanford email address
   6. US Government employee: No
      1. Email address: john.alora.1@us.af.mil
   7. Add a new comment to this user: Stanford University (Civilian Institute) / Lt Col John Alora (Sponsor) / AI Studio / Request Yubi Key / "Put address where you want the Yubi key shipped"

### After you have a pIE account

Two things remain: submit your IA (cyber awareness) training certificate, and get a visit request on file. The steps differ depending on whether you have a CAC (Common Access Card) and a security office.

**Submit your IA training certificate.**

- If you have a CAC: log in to your pIE account at https://ieapp.hpc.mil, expand "User Information Environment", and select "Upload IA Training Certificate".
- If you do not have a CAC: email your cyber awareness certificate to "KIMMET, RYAN M CTR USAF AFMC AFRL/IZ" <ryan.kimmet.ctr@us.af.mil>.

**Get a visit request on file.**

- If you have a security office: have your security rep send a visit request via https://www.hpc.mil/user-portal/visit-requests.
- If you do not have a security office: email "KIMMET, RYAN M CTR USAF AFMC AFRL/IZ" <ryan.kimmet.ctr@us.af.mil> and tell him you are working with the AI Studio. CC John Alora (john.alora.1@us.af.mil) and Geoff Henry (geoffrey.henry@us.af.mil).

### Background check

Go to the UPS and request an **ink print**. This should be a small card that does not have a ton of numbers to fill out. The ERDC point of contact (should be Judy) will send you the detailed instructions.

> [!IMPORTANT]
> On the fingerprint card on the left-hand side, under "REASON FINGERPRINTED", you are required to document these security codes for processing:
> **SOI: Z256, SON: 2222, ALC: 21008711**
>
> If you do not document the security codes on your fingerprint card, the PSI Fingerprint Team will discard your card.

Send your tracking number to the ERDC point of contact to begin the background check.

## 2. Set up your machine

### Install Kerberos

The DoD clusters authenticate with Kerberos. Download and install the HPCMP Kerberos kit from [centers.hpc.mil/users](https://centers.hpc.mil/users/index.html#kerberos) with:

- Principal: [your username]
- Password: [sent to your email]
- Realm: `HPCMP.HPC.MIL`

Verify the installation by obtaining a ticket:

```bash
kshell    # Initialize your shell
kinit     # Initialize your session (YubiKey prompt)
klist     # View your tickets
```

Tickets are valid for 10 hours. When any cluster command fails with an authentication error, run these three commands and retry — do not edit scripts to work around an expired ticket.

> [!TIP]
> You have the option to change your password within 20 days. After obtaining a Kerberos ticket, type the following and follow the prompts:
>
> ```bash
> kshell    # Initialize your shell
> kpasswd   # Change pw
> ```

> [!TIP]
> If `kinit` picks up the wrong username, specify your principal manually:
>
> ```bash
> kinit [username]@HPCMP.HPC.MIL
> ```

> [!WARNING]
> Kerberos initialization changes the order in which your authentication certificates are handled. Run `chmod 600 ~/.ssh/config` if there is a permissions issue. To keep your non-HPC ssh identities working, you can scope other hosts in your ssh config to:
>
> ```
> IdentitiesOnly yes
> GSSAPIAuthentication no
> PreferredAuthentications publickey
> ```

### SSH configuration

To force GSS-API (Kerberos) authentication on the HPC hosts, add this to `~/.ssh/config`:

```
Host *.arl.hpc.mil *.hpc.mil
  GSSAPIAuthentication yes
  GSSAPIDelegateCredentials yes
  PreferredAuthentications gssapi-with-mic,publickey
  User [username]
```

With a valid ticket (`kshell` + `kinit`), ssh to any cluster: `ssh [user]@[cluster.system]`. Anvil is the exception — it uses plain SSH public keys registered through the [Purdue RCAC portal](https://www.rcac.purdue.edu), no Kerberos and no YubiKey.

### The HPC Portal

The HPC Portal provides GUI tools on an (incredibly outdated looking) web interface, including node availability and file/job management: https://centers.hpc.mil/portal

## 3. Clusters we have access to

As of August 2026:

| System   | Login                     | Center               | Scheduler | GPU nodes |
|----------|---------------------------|----------------------|-----------|-----------|
| Jean     | jean.arl.hpc.mil          | ARL                  | SLURM     | GPU nodes via `--gres=aiml` |
| Raider   | raider.afrl.hpc.mil       | AFRL                 | SLURM     | A100 MLA nodes |
| Nautilus | nautilus.navydsrc.hpc.mil | NAVY                 | SLURM     | A100 MLA nodes |
| Wheat    | wheat.erdc.hpc.mil        | ERDC                 | PBS Pro   | A100 MLA nodes (4- or 6-GPU) |
| Fran     | fran.arl.hpc.mil          | ARL                  | SLURM     | 2× H100/H200 NVL 141 GB per node (AIML queue) |
| Makau    | makau.mhpcc.hpc.mil       | MHPCC                | SLURM     | 4× H100 SXM5 80 GB (AI/ML nodes) or 1× H100 NVL 94 GB (Mixed nodes) |
| Anvil    | anvil.rcac.purdue.edu     | Purdue RCAC (ACCESS) | SLURM     | 4× H100 per `ai` node |

MLA is the HPCMP term for the machine-learning-accelerated (GPU) node pools; on Raider, Nautilus, and Wheat you select them explicitly (`--constraint=mla` / `nmlas=`).

Anvil is not a DoD system: it runs on an NSF ACCESS allocation and authenticates with SSH keys instead of Kerberos. There is no authentication path between the DoD clusters and Anvil, so data moves between them through your laptop.

## 4. Set up a new cluster

Do these four steps once per cluster.

### Step 1: add shell aliases

Add quick login aliases to `~/.zshrc` (Mac) or `~/.bashrc` (Linux). Running [`make configure`](#5-the-helper-kit) prints this exact block with your usernames already filled in, ready to paste:

```bash
# Quick aliases per cluster
alias jean="ssh <dod-username>@jean01.arl.hpc.mil"
alias raider="ssh <dod-username>@raider.afrl.hpc.mil"
alias wheat="ssh <dod-username>@wheat.erdc.hpc.mil"
alias nautilus="ssh <dod-username>@nautilus.navydsrc.hpc.mil"
alias anvil="ssh <anvil-username>@anvil.rcac.purdue.edu"
alias makau="ssh <dod-username>@makau.mhpcc.hpc.mil"
alias fran="ssh <dod-username>@fran.arl.hpc.mil"
```

### Step 2: install load_modules_cuda.sh

Each cluster keeps its `module load` lines in `~/load_modules_cuda.sh` on that cluster, because module names differ per system. A working Jean example lives in [jean/load_modules_cuda.sh](jean/load_modules_cuda.sh). `make setup-cluster` bootstraps a best-effort starter file automatically — verify it against `module avail cuda` / `module avail anaconda` on that cluster before trusting long jobs to it.

As of Aug 19, 2026, Fran and Makau do not have the cseinit modules, so `load_modules_cuda.sh` handles module loading differently on those clusters — which is exactly why the module lines live in a per-cluster file.

### Step 3: set up your git identity on the cluster

On the cluster, configure git and generate an SSH key (replace the name and email with your own — shown here with John's as the example):

```bash
git config --global user.name "John Alora"
git config --global user.email "jjalora@stanford.edu"
ssh-keygen -t ed25519 -C "jjalora@stanford.edu"
```

On **Fran**, generate an ECDSA key instead — Fran runs in FIPS mode, which bans ed25519 outright:

```bash
ssh-keygen -t ecdsa -b 384 -C "jjalora@stanford.edu"
```

### Step 4: register the deploy key on GitHub

1. Print the public key on the cluster: `cat ~/.ssh/id_ed25519.pub` (or `id_ecdsa.pub` on Fran).
2. In your project's GitHub repo: Settings → Deploy keys → Add deploy key. Paste the key and check **Allow write access** (the sync step pushes a snapshot branch, so read-only keys fail).
3. Save the private key on the cluster at `~/.ssh/id_deploy` (or set `DEPLOY_KEY=` when running make).

GitHub allows a key to be registered only once across all of GitHub, so each cluster needs its own key pair.

With the key in place, finish the cluster from your laptop:

```bash
make sync CLUSTER=<cluster>            # put the code on the cluster
make setup-cluster CLUSTER=<cluster>   # conda env + dependencies (one time)
make smoke CLUSTER=<cluster>           # verify end-to-end (section 6)
```

## 5. The helper kit

The `Makefile` and `scripts/` in this repo drive every cluster from your laptop. Copy them into your own project (or use this repo directly), then configure once:

```bash
make configure     # writes config.mk (gitignored) + prints your personalized ssh aliases
```

`config.mk` holds your project name, usernames, and accounts; because it is gitignored, `git pull` never conflicts with your settings and nothing personal gets committed.

**The sync model: GitHub is authoritative.** `make sync CLUSTER=<c>` makes the cluster's checkout exactly match `origin/<branch>` (default: your laptop's current branch). If the cluster has local edits, the sync first commits them to a per-cluster branch named `cluster-snapshot/<cluster>` and pushes it — nothing is lost, and because each snapshot branch has exactly one writer, clusters never conflict with each other. To keep a cluster-side change, deliberately merge `origin/cluster-snapshot/<cluster>` into your main branch.

**The submit/monitor loop.** Every training command follows the same shape:

```bash
make submit CLUSTER=raider NUM_GPU=4 TIME=24:00:00 EXTRA_ARGS='--lr 1e-4'
make status CLUSTER=raider      # queue state
make logs CLUSTER=raider        # tail newest stdout log
make logs-err CLUSTER=raider    # tail newest stderr log (Python tracebacks land here)
make cancel CLUSTER=raider RUN_ID=<jobid>
```

`submit` syncs the code, then submits `scripts/slurm/example_job.sh` (or `scripts/pbs/example_job.sh` on Wheat). The job scripts contain only universal directives; all cluster-specific resource flags come from the Makefile's per-cluster tables, so one script runs everywhere. `EXTRA_ARGS` is forwarded to your training entry point — on Wheat it rides in via the `JOB_ARGS` env var because PBS `qsub` has no `-F "args"` flag.

To run your own code, replace `examples/train_smoke.py` in the two job templates with your entry point. Everything above the launch lines is cluster plumbing you keep.

## 6. Smoke test

Before trusting a cluster — after first setup, after any environment change, and before any long run — verify it end-to-end:

```bash
make smoke CLUSTER=raider          # submits a short job: tiny MLP on synthetic data
make logs CLUSTER=raider           # expect: "SMOKE TEST PASSED (final loss ...)"
```

The smoke job trains a small neural network ([examples/train_smoke.py](examples/train_smoke.py)) for 200 steps on synthetic data — no downloads, so it works on air-gapped clusters — and saves a checkpoint. It proves the whole chain: Kerberos, sync, scheduler submission, modules, conda env, GPU allocation, and CUDA.

To also verify multi-GPU NCCL collectives (the thing that hangs when a cluster is misconfigured), run it on several GPUs:

```bash
make smoke CLUSTER=raider NUM_GPU=4
```

## 7. Running jobs

Most clusters use the SLURM scheduler; Wheat uses PBS Pro. See the [SLURM quickstart](https://slurm.schedmd.com/quickstart.html) or this [go-to reference](https://it.coecis.cornell.edu/researchit/g2cluster/#Create_a_SLURM_Submission_Script). Each cluster needs specific resource keywords, encoded in the Makefile and summarized here:

| Cluster  | GPU request on the submit line |
|----------|-------------------------------|
| jean     | `--gres=aiml --gpus-per-node=N -p AIML` |
| raider   | `--constraint=mla --gpus-per-node=N -q <qos>` |
| nautilus | `--constraint=mla --gres=gpu:a100:N -q <qos>` |
| wheat    | `-l select=1:ncpus=92:mpiprocs=1:nmlas=N` (PBS; `ngpus=1` for viz nodes) |
| fran     | `-p AIML --gres=gpu:N` (max 2 per node) |
| makau    | `-p standard --gres=gpu:h100_sxm5:N` (or `h100_nvl:1`) |
| anvil    | `-p ai --gpus-per-node=N` |

### Interactive jobs

Good for debugging. `make interactive CLUSTER=<c> NUM_GPU=<n> TIME=2:00:00` opens a shell on a GPU node; the underlying per-cluster commands:

**Raider**

```bash
srun --account ousaf40080AIR -q hie --nodes 1 --gpus-per-node 1 --ntasks-per-node=1 --constraint=mla --time=60:00 --pty bash
```

**Jean** — note: as of August 2025 you must agree to a usage agreement each time you ssh in.

```bash
srun --account ousaf40080AIR -p HIE --nodes 1 --gpus-per-node 1 --ntasks-per-node=1 --time=60:00 --pty bash
```

**Nautilus**

```bash
srun --account ousaf40080AIR -q hie --nodes 1 --gpus-per-node 1 --ntasks-per-node=1 --constraint=mla --time=60:00 --pty bash
```

**Wheat** (PBS — interactive via `qsub -I`)

```bash
qsub -I -V -A ousaf40080AIR -q standard -l walltime=2:00:00 -l select=1:ncpus=92:mpiprocs=1:nmlas=4
```

**Fran** (AIML queue only for GPUs)

```bash
srun --account ousaf40080AIR -p AIML --gres=gpu:2 --nodes 1 --ntasks-per-node=1 --time=2:00:00 --pty bash
```

**Makau** (typed gres)

```bash
srun --account ousaf40080AIR -p standard --gres=gpu:h100_sxm5:1 --nodes 1 --ntasks-per-node=1 --time=2:00:00 --pty bash
```

**Anvil** (SSH-key auth; check which partition your allocation authorizes)

```bash
srun --account <allocation> -p ai --gpus-per-node=1 --nodes 1 --ntasks-per-node=1 --time=2:00:00 --pty bash
```

### Batch jobs

Submit through the Makefile (`make submit`, section 5) or adapt the templates directly:

- [scripts/slurm/example_job.sh](scripts/slurm/example_job.sh) — SLURM: single-GPU, multi-GPU `torchrun`, and multi-node launch tiers; W&B offline fallback; per-cluster env via `scripts/cluster_env.sh`.
- [scripts/pbs/example_job.sh](scripts/pbs/example_job.sh) — PBS (Wheat): the same tiers via `pbsdsh`, plus the `JOB_ARGS` re-tokenization and Wheat-specific fixes.
- [jean/sample_slurm_script.sh](jean/sample_slurm_script.sh) — a bare-bones working multi-node example on Jean.

When a job fails, work in this order: `make status` (did it start?), `make logs` and `make logs-err` (read both tails), classify the failure (auth, environment, path, scheduler, out-of-memory, NCCL hang, NaN — check [per-cluster quirks](#10-per-cluster-quirks) first), then rerun the smallest thing that tests your hypothesis.

### Distributed training

Jean has InfiniBand with a NCCL backend. Set these before multi-node runs (the SLURM template does this automatically on Jean):

```bash
export NCCL_IB_DISABLE=0
export NCCL_NET=IB
export NCCL_IB_HCA=mlx5_0:1,mlx5_3:1  # Use both 200G IB ports
export NCCL_IB_ADDR_FAMILY=AF_INET
export NCCL_SOCKET_IFNAME=ib0  # For bootstrap only
```

Launch with `sbatch [slurm_script].sh` — see the [Jean example](jean/sample_slurm_script.sh) — or `make submit CLUSTER=jean NODES=2 NUM_GPU=4`.

On A100-PCIE nodes (Wheat's MLA nodes), set `NCCL_P2P_DISABLE=1` or every multi-GPU job hangs right after DDP initialization (see [quirks](#10-per-cluster-quirks)).

### Persistent nodes

Kerberos tickets last about 10 hours, but commands run *on* a cluster (`sbatch`, `squeue`) need no ticket. For anything that must outlive your laptop session — a sweep controller, a monitoring loop — hold a node with a detached tmux session:

```bash
make persist CLUSTER=raider          # batch job holds 1 GPU + starts tmux
make persist-attach CLUSTER=raider   # attach to the tmux on the compute node
make persist-stop CLUSTER=raider     # release the node, stop any chaining
```

To span a queue's walltime cap, chain fresh nodes: `make persist CLUSTER=raider PERSIST_CHAIN=1 PERSIST_CHAIN_LINKS=3` (each link queues its successor with `--dependency=afterany`; whatever runs inside must be restart-safe). Note that on many clusters a GPU node is exclusive — you hold the whole node — so keep `PERSIST_TIME` modest. Anvil rejects `make persist` on purpose: with SSH-key auth there is no ticket expiry to work around.

## 8. Transfer data and sync offline W&B

**Cluster to cluster (DoD only).** Kerberos lets one DoD cluster ssh to another, so runs move directly:

```bash
make transfer FROM=raider TO=nautilus RUN_ID=1650317       # push a run dir
make transfer-pull FROM=raider TO=nautilus RUN_ID=1650317  # pull, initiated on TO
make transfer-list CLUSTER=raider                          # list run dirs
```

Pairs involving Anvil are refused (no DoD↔ACCESS auth path) — use `download-run` plus a manual upload.

**Cluster to laptop.**

```bash
make download-run CLUSTER=raider RUN_ID=1650317   # rsync outputs to ./outputs/
```

**Offline Weights & Biases.** Air-gapped clusters cannot reach wandb.ai, so jobs fall back to `WANDB_MODE=offline` automatically. Sync from your laptop, which has both cluster access and internet:

```bash
make sync-wandb CLUSTER=jean                   # download + sync all offline runs
make sync-wandb CLUSTER=jean RUN_ID=2007845    # just one job's runs
```

## 9. Software on the clusters

Load modules on a cluster:

```bash
module load cseinit-noloads

module avail cse  # Check what is available
```

> [!NOTE]
> As of Aug 19, 2026, **Fran and Makau do not have the cseinit modules**. `~/load_modules_cuda.sh` handles module loading differently on those clusters — keep your module lines in that per-cluster file rather than in job scripts.

### Using Mini-Conda

The HPC clusters come with a miniforge installation of conda (Mini-Conda). Load it with:

```bash
module load cse/miniforge/latest
```

`make setup-cluster CLUSTER=<c>` automates the full environment build: module bootstrap, conda env creation, and dependency install (edit the `pip install` lines in [scripts/setup_cluster_env.sh](scripts/setup_cluster_env.sh) to match your project).

## 10. Per-cluster quirks

This knowledge costs days to rediscover. When a job fails strangely, read the cluster's entry before debugging your own code.

**Jean**
- Multi-node NCCL needs the InfiniBand exports in [Distributed training](#distributed-training).
- You must accept a usage agreement on every ssh login (as of August 2025).

**Raider**
- GPU nodes are selected by `--constraint=mla`; the queue rides in `-q`, not `-p`.

**Nautilus**
- Some A100 nodes refuse to create a CUDA context on GPU index 2 — a multi-GPU job on such a node dies at local rank 2 with an error that looks like a code bug. Submit with `#SBATCH --requeue` and a preflight check that touches every visible GPU, so a wedged node requeues the job instead of killing it.

**Wheat**
- The only PBS Pro cluster: `qsub`/`qstat`/`qdel`, and no `qsub -F "args"` — extra arguments ride in via the `JOB_ARGS` env var (`qsub -V`).
- **A100-PCIE nodes: set `NCCL_P2P_DISABLE=1`.** NCCL peer-to-peer over PCIe deadlocks; every multi-GPU job hangs immediately after DDP init. Set it in the job script and, belt-and-suspenders, from Python on A100-PCIE detection.
- The system CUDA in `LD_LIBRARY_PATH` can shadow PyTorch's bundled cuBLASLt and trigger `CUBLAS_STATUS_INVALID_VALUE` on FP16 GEMMs — the PBS template prepends torch's bundled `nvidia/*/lib` dirs to fix this.
- PBS `-o` does not expand the job id; the template redirects its own output to `logs/run_<jobid>.{out,err}`.

**Fran**
- GPU jobs must use the `AIML` partition; at most 2 GPUs per node (H100/H200 NVL 141 GB).
- FIPS mode bans ed25519 — use an ECDSA-384 deploy key.
- Compute nodes are air-gapped (login nodes are not): Hugging Face hub calls die even with a warm cache, so `scripts/cluster_env.sh` forces `HF_HUB_OFFLINE=1` inside jobs. Warm caches from a login node before submitting.
- Do not trust internet probes: DREN TLS interception answers HTTPS probes with a real status even though upstream is blocked, so `wandb.init` in online mode hangs. The kit presets `WANDB_MODE=offline` on Fran.
- Check the torch wheel against the driver: with a CUDA-12.x driver, the default cu130 wheel refuses to initialize CUDA and training silently falls back to CPU. `setup_cluster_env.sh` probes the driver and installs the cu128 wheel when needed.
- No cseinit modules (as of Aug 19, 2026) — module loading goes through `~/load_modules_cuda.sh`.

**Makau**
- Typed gres with two node classes: `h100_sxm5` (AI/ML nodes, 4× 80 GB, node-local NVMe) or `h100_nvl` (Mixed nodes, 1× 94 GB — one GPU per node, so multi-GPU means multi-node).
- The system conda's `conda init` crashes outright (read-only base install); `setup_cluster_env.sh` treats it as best-effort.
- No cseinit modules (as of Aug 19, 2026) — module loading goes through `~/load_modules_cuda.sh`.

**Anvil**
- SSH-key auth via the RCAC portal; `squeue` filters by user, not account.
- Check which partitions your allocation authorizes — some AI allocations authorize only `-p ai` and the scheduler rejects the account everywhere else. Walltime cap 48 h; max 12 GPUs per user.
- `$WORKDIR` does not exist — Anvil exports `$SCRATCH`; the kit aliases `WORKDIR=$SCRATCH`.
- `$HOME` is 25 GB. Keep conda/pip/HF caches on `$SCRATCH`; put the conda env itself under `$PROJECT` storage, because `$SCRATCH` purges after 30 days and a purged env silently kills queued jobs.
- Compute nodes have internet but no W&B key, so online `wandb.init` aborts — the kit defaults `WANDB_MODE=offline` there.

**Any cluster**
- NCCL failures are hangs, not errors. A multi-GPU job frozen right after DDP init is an environment problem until proven otherwise.
- Tilde expansion crosses machines: `export REMOTE_DIR=~/proj` expands to your laptop's home. The Makefile restores the `~/` so paths resolve on the cluster.
- Non-interactive ssh shells do not run `/etc/profile.d`, so `module` may not exist — the kit's scripts source the module init files by hand.

## 11. Shortcut make commands

Run `make help` for the live list. All targets take `CLUSTER=<jean|raider|nautilus|wheat|fran|makau|anvil>`.

| Command | What it does |
|---------|--------------|
| `make configure` | One-time: write `config.mk` (usernames, accounts, project) and print your ssh aliases |
| `make sync` | Make the cluster's code match GitHub (cluster edits saved to `cluster-snapshot/<c>` first) |
| `make setup-cluster` | One-time per cluster: modules bootstrap + conda env + dependencies |
| `make smoke` | Short tiny training job that verifies the cluster end-to-end |
| `make submit` | Sync + submit the training job (`NUM_GPU=`, `NODES=`, `TIME=`, `EXTRA_ARGS='...'`) |
| `make interactive` | Interactive GPU shell (`NUM_GPU=`, `TIME=`) |
| `make status` | Queue state (`squeue`/`qstat`) |
| `make logs` / `make logs-err` | Tail the newest stdout / stderr log |
| `make cancel` | Cancel one job (`RUN_ID=`) or all your jobs |
| `make persist` / `persist-attach` / `persist-stop` | Hold a GPU node with a detached tmux; attach; release |
| `make transfer` / `transfer-pull` | Move a run between DoD clusters (`FROM=`, `TO=`, `RUN_ID=`) |
| `make transfer-list` | List run dirs on a cluster |
| `make download-run` | rsync a run's outputs to your laptop (`RUN_ID=`) |
| `make sync-wandb` | Pull offline W&B runs off a cluster and sync to wandb.ai |
| `make clean` | Delete run artifacts on a cluster (`RUN_ID=` one run, or `EXCLUDE="id1 id2"` keep-these) |

Common invocations:

```bash
make configure                                     # first thing, once
make sync CLUSTER=jean                             # push code
make setup-cluster CLUSTER=jean                    # first time on jean
make smoke CLUSTER=jean                            # verify end-to-end
make submit CLUSTER=jean NUM_GPU=4 NODES=2 TIME=48:00:00
make submit CLUSTER=wheat NUM_GPU=6                # PBS, 6-GPU MLA node
make submit CLUSTER=anvil NUM_GPU=1 TIME=0:25:00   # short H100 job
make interactive CLUSTER=nautilus NUM_GPU=4 TIME=2:00:00
make transfer FROM=raider TO=nautilus RUN_ID=1650317
make clean CLUSTER=raider EXCLUDE="1650317 1650318"
```
