# Agent setup instructions: install the DoD HPC kit into a project

You are an AI coding agent (Claude Code, Codex, or OpenCode). The user wants this project to
run training jobs on the DoD HPCMP clusters and Purdue Anvil. Follow these steps exactly, in
order, and report the result of each. Do not skip the smoke test.

## 0. Collect the two inputs

Ask the user for, and do not guess:

1. **DoD HPCMP username** (their Kerberos principal, e.g. `jdoe`).
2. **Anvil username** (Purdue RCAC, always of the form `x-<name>`, e.g. `x-jdoe`).

Everything else (project name, GitHub URL, accounts) is derived or defaulted. The accounts
default to the AI Studio allocations (`OUSAF40080AIR` on DoD, `nairr260061-ai` on Anvil).

## 1. Preflight (laptop)

Run these and report anything missing:

```bash
git -C . rev-parse --show-toplevel        # the project must be a git repo (cd to its root)
git -C . remote get-url origin            # and it must have a GitHub remote (see below)
which make ssh rsync git                  # all required
which kshell kinit klist                  # HPCMP Kerberos kit — required for the DoD clusters
which gh && gh auth status                # optional: lets make deploy-key register keys itself
```

If `kshell` is missing, the user must install the HPCMP Kerberos kit first
(https://centers.hpc.mil/users/index.html#kerberos). Anvil does not need it.

**If the project is not a git repo, or has no GitHub `origin`**, stop and ask the user which
they want before installing — do not guess:

- *Recommended:* `git init`, commit the existing tree, and create the GitHub repo
  (`gh repo create <owner>/<project> --private --source=. --remote=origin --push`). This
  enables the default deploy-key sync, where GitHub is the source of truth on the cluster.
- *Alternative:* stay local and use `SYNC_MODE=rsync` for **every** command in step 5 onward.

Without one of these, `config.mk` gets the placeholder `git@github.com:your-org/<project>.git`
and `make sync` fails on the cluster with a confusing clone error.

Note the branch name (`git branch --show-current`). `make sync` defaults `GIT_BRANCH` to the
laptop's current branch and the cluster is reset to `origin/<that branch>`, so the branch must
exist on GitHub.

## 2. Install the kit

From the project root:

```bash
curl -fsSL https://raw.githubusercontent.com/jjalora/dodhpc-usage-guide/main/install.sh \
  | bash -s -- --target . --dod-user <DOD_USER> --anvil-user <ANVIL_USER>
```

(Or clone `https://github.com/jjalora/dodhpc-usage-guide` and run `bash install.sh` with the
same flags.) Add `--install-cmd '<cmd>'` if the project needs a special install on the
cluster; the default auto-detects `pyproject.toml`/`setup.py`/`requirements.txt` and adds
`torch` if the project does not bring it.

Verify: `make help` lists `smoke`, `smoke-wait`, `submit`, `status`; `config.mk` contains the two
usernames; `.claude/skills/hpc-cluster/SKILL.md` exists and `.agents/skills/hpc-cluster` links
to it; `AGENTS.md` and `CLAUDE.md` contain the "HPC clusters" section. Then read
`.claude/skills/hpc-cluster/SKILL.md` — it is your operating manual from here on.

## 3. Wire the project's entry point (optional now)

The templates `scripts/slurm/example_job.sh` and `scripts/pbs/example_job.sh` launch
`examples/train_smoke.py`. Leave that in place for the smoke test. Afterwards, replace it with
the project's training script in both files (keep `--output-dir` and `"$@"`).

## 4. Pick a cluster and authenticate

Ask the user which cluster to validate first (default: `raider`). Authentication cannot be
done by you:

- **DoD cluster**: the user runs, in their own terminal, `kshell` then `kinit` (YubiKey
  prompt). In Claude Code they can type `! kshell` and `! kinit`. Then you verify with
  `klist -s && echo ok`.
- **Anvil**: `make check-auth CLUSTER=anvil`. If it fails, the user must register their SSH
  public key in the RCAC portal; you cannot fix this.

Never edit Kerberos or SSH configuration, never store or forge credentials, never retry an
auth failure in a loop.

## 5. Sync the code to the cluster

**First commit and push the kit.** In the default git mode `make sync` resets the cluster
checkout to `origin/<branch>`, so anything uncommitted — including every file the installer
just wrote — never reaches the cluster, and `setup-cluster` then fails with
`scripts/setup_cluster_env.sh: No such file or directory`:

```bash
git add -A && git commit -m 'chore(hpc): install DoD HPC helper kit' && git push
```

(Skip only in `SYNC_MODE=rsync`, which copies the working tree as-is.)

Then, preferred (GitHub is the source of truth on the cluster):

```bash
make deploy-key CLUSTER=<c>      # creates the cluster's key; registers it with gh if available
make sync CLUSTER=<c>
```

If `deploy-key` printed manual steps (no `gh`), give them to the user and wait, or fall back to
rsync for now:

```bash
SYNC_MODE=rsync make sync CLUSTER=<c>
```

Use the same `SYNC_MODE` for every later command on that cluster in this session.

## 6. One-time environment setup on the cluster

```bash
make setup-cluster CLUSTER=<c>        # 5–20 min: module file, conda env, project install
```

It installs `load_modules/load_modules_cuda.<c>.sh` as `~/load_modules_cuda.sh` on the cluster,
creates the conda env named after the project, and installs the project. Report the tail of its
output; a `WARN:` about a module name means the cluster's modules drifted and the user should
check `module avail`.

## 7. Smoke test (mandatory)

```bash
make smoke CLUSTER=<c>          # submits a 200-step synthetic 1-GPU job, prints the job id
make smoke-wait CLUSTER=<c>     # polls up to 30 min, prints the log tail and a RESULT line
```

- Exit 0 and `RESULT: SMOKE TEST PASSED`: done. If it also printed `WARNING: smoke ran on CPU`,
  it is not a pass; see the fran torch-wheel quirk in the skill's `references/clusters.md`.
- Exit 2: the job is still queued. Re-run `make smoke-wait` later (do not resubmit).
- Exit 1: read the `.err` tail it printed, classify the failure using the skill's "When a job
  fails" order, fix the smallest thing, re-run `make smoke`. Do not submit anything else until
  the smoke passes.

Optionally repeat with `NUM_GPU=4` to exercise multi-GPU NCCL (the thing that hangs on
misconfigured clusters).

## 8. Report

Tell the user: which cluster passed, the job id, where outputs landed
(`$WORKDIR/<project>-outputs/run_<id>`), what was installed in the repo, and that the same
steps 4–7 validate each additional cluster. Commit the kit files if the user wants them
tracked (`config.mk` and `.hpc_smoke_job` stay gitignored).
