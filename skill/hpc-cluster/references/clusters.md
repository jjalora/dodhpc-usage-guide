# Cluster reference

Values below are what `hpc.mk` submits. Accounts default to the AI Studio allocations
(`OUSAF40080AIR` on DoD clusters, `nairr260061-ai` on Anvil); `config.mk` overrides them.

| Cluster | Login host | Center | Scheduler | GPU nodes | GPU flags on the submit line | Default walltime |
|---|---|---|---|---|---|---|
| jean | jean01.arl.hpc.mil | ARL | SLURM | A100-PCIE-40GB via `aiml` gres | `--gres=aiml --gpus-per-node=N -p AIML` | 96 h |
| raider | raider.afrl.hpc.mil | AFRL | SLURM | 4× A100 MLA | `--constraint=mla --gpus-per-node=N -q standard` | 96 h |
| nautilus | nautilus.navydsrc.hpc.mil | NAVY | SLURM | 4× A100 SXM4 40 GB MLA | `--constraint=mla --gres=gpu:a100:N -q standard` (`-q debug` = 30 min, fast) | 96 h |
| wheat | wheat.erdc.hpc.mil | ERDC | **PBS Pro** | A100-PCIE MLA, 4 or 6 GPUs | `-q standard_lw -l select=1:ncpus=92:mpiprocs=1:nmlas=N` (`ngpus=1` for viz nodes) | 96 h |
| fran | fran.arl.hpc.mil | ARL (Cray EX4000) | SLURM | 2× H100/H200 NVL 141 GB per node | `-p AIML --gres=gpu:N` (N ≤ 2) | 96 h (AIML cap 168 h) |
| makau | makau.mhpcc.hpc.mil | MHPCC (Cray XD2000) | SLURM | 4× H100 SXM5 80 GB (AI/ML) or 1× H100 NVL 94 GB (Mixed) | `-p standard --gres=gpu:h100_sxm5:N` (or `gpu:h100_nvl:1`) | 96 h |
| anvil | `<x-user>@anvil.rcac.purdue.edu` | Purdue RCAC (ACCESS) | SLURM | 4× H100 80 GB per `ai` node | `-p ai --gpus-per-node=N --account=nairr260061-ai` | 48 h (hard cap) |

Auth: DoD = Kerberos/GSSAPI (`kshell`, `kinit`, verify `klist -s`). Anvil = SSH public key
registered in the RCAC portal; no ticket, no YubiKey. There is no auth path between DoD and
Anvil, so data between them goes through the laptop.

Scratch: `$WORKDIR` is `/p/work1/$USER` on jean/raider/nautilus/fran and `/p/work/$USER` on
wheat/makau (purged Lustre, no quota). Anvil has no `$WORKDIR`; the kit aliases it to
`$SCRATCH` (100 TB, purged after 30 days). `$HOME` is small everywhere (Anvil: 25 GB).

## Native commands (from the remote checkout, e.g. `~/<project>`)

SLURM submit, all SLURM clusters (replace `<GPU_FLAGS>` from the table):

```bash
sbatch --export=ALL,HPC_CLUSTER=<c>,HPC_NUM_GPU=<N>,HPC_PROJECT=<project> \
       <GPU_FLAGS> --nodes=<nodes> --time=<HH:MM:SS> --account=OUSAF40080AIR \
       scripts/slurm/example_job.sh <args to your entry point>
squeue --account=OUSAF40080AIR -o "%.10i %.25j %.8T %.10M %.6D %R"   # anvil: squeue -u $USER
sacct -j <jobid> --format=JobID,State,Elapsed,MaxRSS,ExitCode
scancel <jobid>
```

PBS submit (wheat). `qsub` has no `-F`, so arguments ride in the `JOB_ARGS` env var:

```bash
JOB_ARGS="<args>" qsub -A OUSAF40080AIR -q standard_lw -l walltime=<HH:MM:SS> \
     -l select=<nodes>:ncpus=92:mpiprocs=1:nmlas=<N> \
     -v NUM_NODES=<nodes>,NUM_GPU=<N>,HPC_CLUSTER=wheat -V scripts/pbs/example_job.sh
qstat -u $USER ; qstat -f <jobid> ; qdel -W force <jobid>
```

Logs: `ls -t logs/*.out | head -1 | xargs tail -100` (stdout), same with `*.err` (tracebacks).

## Quirks that cost days

**Every cluster**
- NCCL failures are hangs, not errors. A multi-GPU job frozen right after DDP init is an
  environment problem (P2P, HCA names, wrong wheel) until proven otherwise.
- Non-interactive ssh shells do not run `/etc/profile.d`, so `module` may be missing; the
  kit's scripts source the module init files by hand.
- Compute-node hostnames (`r20u09n01`, `g012`) do not identify the cluster; always pass
  `HPC_CLUSTER`.
- Always confirm the job log says `device=cuda`, not `cpu`, when validating a new cluster.

**jean**: multi-node needs InfiniBand exports (`NCCL_IB_HCA=mlx5_0:1,mlx5_3:1`,
`NCCL_SOCKET_IFNAME=ib0`, set by the SLURM template for jean only; never copy the HCA names
to another cluster). A usage agreement must be accepted on every ssh login. Driver is
**565.57.01 (CUDA 12.x)**, so the default cu13x torch wheel cannot initialize CUDA and training
silently runs on CPU — see "torch wheel vs driver". The usual cu128 fix via
`--index-url https://download.pytorch.org/whl/cu128` does NOT work here: the DREN firewall
refuses `download-r2.pytorch.org` (`[Errno 111] Connection refused`) after the metadata
resolves. PyPI is reachable, so pin a version that ships cu128 by default instead —
`pip install "torch==2.8.0"` (what `setup_cluster_env.sh` falls back to). Run pip with the
module file sourced, or DREN's TLS interception fails cert validation.

**raider**: GPU nodes via `--constraint=mla`; the queue rides in `-q`, not `-p`.

**nautilus**: some A100 nodes refuse a CUDA context on GPU index 2 (`cudaErrorDevicesUnavailable`,
reported as "first failure local_rank 2"). Mitigate with `#SBATCH --requeue` plus a preflight
that touches every GPU and requeues, or `--exclude=<node>`. Nodes are exclusive by default.

**wheat** (PBS): `logs/` must exist before `qsub` or output is silently lost (`make sync`
creates it); `#PBS -o` does not expand the job id, so the template re-execs into
`logs/run_<id>.{out,err}`. **A100-PCIE: `NCCL_P2P_DISABLE=1`** or every multi-GPU job hangs
after DDP init (the PBS template sets it). System CUDA in `LD_LIBRARY_PATH` shadows torch's
cuBLASLt (`CUBLAS_STATUS_INVALID_VALUE` on FP16 GEMMs); the template prepends torch's bundled
libs. Multi-node launches via `pbsdsh` + `torchrun`.

**torch wheel vs driver (any cluster)**: the default PyPI `torch` wheel is now cu13x and needs
an r580+ NVIDIA driver. On a CUDA 12.x driver it refuses to initialize CUDA and training
*silently* falls back to CPU, so the smoke test still prints `SMOKE TEST PASSED` — that is why
`smoke-wait` also greps for `device=cuda` and warns `smoke ran on CPU`. **Treat that warning as
a failure.** `setup_cluster_env.sh` probes the driver and installs the cu128 wheel when it is
< 580. Login nodes often have no GPU, so the probe can come back empty; it then keeps the
default wheel and prints a NOTE. Fix by hand on the cluster, inside the project's conda env:

```bash
pip install --force-reinstall torch --index-url https://download.pytorch.org/whl/cu128
```

Then re-run `make smoke`. Do not "fix" this by relaxing the `device=cuda` check.

**fran**: GPU jobs only in `-p AIML`, at most 2 GPUs per node. FIPS mode bans ed25519: deploy
key must be ECDSA-384 (`make deploy-key` handles it) and any `ssh-ed25519` known_hosts line
spams warnings. Compute nodes are air-gapped (login nodes are not): pre-download Hugging Face
assets from a login node; the kit forces `HF_HUB_OFFLINE=1` inside jobs. DREN TLS interception
answers internet probes with a real status, so `wandb.init` online hangs; the kit presets
`WANDB_MODE=offline`. Driver 575.x (CUDA 12.9) rejects the default cu13x torch wheel and
training silently runs on CPU — see "torch wheel vs driver" below; fran is just where it was
found first.
pip/HF need the system CA bundle (`SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt`, set in
its module file). No cseinit modules; module lines live in `load_modules/load_modules_cuda.fran.sh`.
Multi-node NCCL is unvalidated (Slingshot interconnect, not InfiniBand).

**Env activation is verified, not trusted** (`scripts/cluster_env.sh`): `sbatch --export=ALL`
inherits the submit shell's *already active* conda env, so `conda activate` inside the job body
is a silent no-op — and re-sourcing `~/load_modules_cuda.sh` then puts the system/CSE python
back in front of it. The job dies with `ModuleNotFoundError: No module named 'torch'` while
conda still reports the env as active. `hpc_activate_env` therefore checks that `python`
actually resolves inside the env prefix and force-prepends it if not (printing `NOTE: forced
... to the front of PATH`). Seen on jean. If you see that NOTE, nothing is wrong.

**`$TMPDIR` can be the thing that is full**: several DoD clusters point `TMPDIR` at `$WORKDIR`.
pip unpacks the ~2.5 GB torch wheel there, so an over-quota scratch fails the install with
`OSError: [Errno 122] Disk quota exceeded` raised from a stdlib `tempfile.py` — which looks
like a `$HOME` problem and is not. `setup_cluster_env.sh` probes `TMPDIR` with a real 128 MB
write (an over-quota Lustre accepts a few MB then truncates, so exit status alone lies) and
falls back to `$HOME/tmp`. Always check BOTH filesystems before moving anything:
`lfs quota -h -u $USER /p/home` and `lfs quota -h -u $USER /p/work`.

**makau**: typed gres is mandatory, and the type must MATCH the node class or the job is
rejected at submit with `Invalid GRES specified`: `gpu:h100_nvl:1` for the 1-GPU Mixed nodes,
`gpu:h100_sxm5:4` for the 4-GPU AI/ML nodes. `gpu:h100_sxm5:1` is invalid, so `hpc.mk` derives
the type from `NUM_GPU` (`make smoke` forces `NUM_GPU=1` and used to fail here). A bare
`--gres=gpu:N` may never schedule. Mixed nodes have one GPU, so multi-GPU there means
multi-node. `conda init` on the system conda crashes (read-only base); setup treats it as
best-effort. Debug queue caps at 0.5 h; the `background` queue (4 h) is uncharged and good
for free smoke tests. `$LOCALWORKDIR` is node-local NVMe, lost when the job ends. The
round-robin login alias has intermittently rejected GSSAPI with a valid ticket; if that
happens, pin a node (`makau01.mhpcc.hpc.mil`) in `hpc.mk`'s `SSH_makau`. Multi-node NCCL
unvalidated (HCA names unknown; discover with `ibstat`).

**anvil**: SSH keys via the RCAC portal; `squeue` filters by user, not account. The AI Studio
allocation authorizes only `-p ai`; `gpu`/`gpu-debug` reject the account (hpc.mk guards
this). Walltime cap 48 h (a copied `TIME=96:00:00` is rejected); max 12 GPUs per user.
`$HOME` is 25 GB: the conda env lives under `$PROJECT/$USER/envs/<project>` and pip/HF/conda
caches on `$SCRATCH`; `$SCRATCH` purges after 30 days, so download results promptly and never
put the env there. Compute nodes have internet but no W&B key, so online `wandb.init` aborts;
the kit defaults `WANDB_MODE=offline`. No `persist`, no cross-cluster `transfer`. H100 results
are not comparable with the DoD A100 clusters.
