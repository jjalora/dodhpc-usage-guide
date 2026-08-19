#!/usr/bin/env python
"""Cluster smoke test: train a tiny MLP on synthetic data.

The script needs no downloads and no external data, so it runs on air-gapped
clusters. Launch it with plain `python` for one GPU (or CPU), or with
`torchrun` for multiple GPUs — under torchrun it initializes a NCCL process
group and wraps the model in DistributedDataParallel, so it also verifies
multi-GPU collectives. On success it prints "SMOKE TEST PASSED (final loss
...)" and saves a checkpoint to --output-dir.

Examples:
    python examples/train_smoke.py --max-steps 200
    torchrun --nproc_per_node=4 examples/train_smoke.py --max-steps 200
"""

import argparse
import os
import time

import torch
import torch.nn as nn


def main():
    parser = argparse.ArgumentParser(description="Tiny synthetic training run")
    parser.add_argument("--max-steps", type=int, default=200)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--hidden-dim", type=int, default=512)
    parser.add_argument("--output-dir", default="smoke_output")
    # Tolerate extra flags so this script can stand in for a real entry point
    # inside the job templates without breaking on project-specific args.
    args, unknown = parser.parse_known_args()
    if unknown:
        print(f"Ignoring unrecognized args: {unknown}", flush=True)

    rank = int(os.environ.get("RANK", 0))
    world_size = int(os.environ.get("WORLD_SIZE", 1))
    distributed = world_size > 1

    if torch.cuda.is_available():
        local_rank = int(os.environ.get("LOCAL_RANK", 0))
        device = torch.device("cuda", local_rank)
        torch.cuda.set_device(device)
    else:
        device = torch.device("cpu")

    if distributed:
        torch.distributed.init_process_group(
            backend="nccl" if device.type == "cuda" else "gloo"
        )
    torch.manual_seed(1234 + rank)

    if rank == 0:
        gpus = torch.cuda.device_count() if torch.cuda.is_available() else 0
        print(f"device={device}  world_size={world_size}  visible_gpus={gpus}", flush=True)

    # A fixed random linear teacher defines a learnable regression task.
    in_dim = 64
    teacher_gen = torch.Generator().manual_seed(0)
    w_true = torch.randn(in_dim, 1, generator=teacher_gen).to(device)

    model = nn.Sequential(
        nn.Linear(in_dim, args.hidden_dim),
        nn.ReLU(),
        nn.Linear(args.hidden_dim, args.hidden_dim),
        nn.ReLU(),
        nn.Linear(args.hidden_dim, 1),
    ).to(device)
    if distributed:
        model = nn.parallel.DistributedDataParallel(
            model, device_ids=[device.index] if device.type == "cuda" else None
        )
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)

    start = time.time()
    loss = None
    for step in range(1, args.max_steps + 1):
        x = torch.randn(args.batch_size, in_dim, device=device)
        y = x @ w_true + 0.01 * torch.randn(args.batch_size, 1, device=device)
        optimizer.zero_grad(set_to_none=True)
        loss = nn.functional.mse_loss(model(x), y)
        loss.backward()
        optimizer.step()
        if rank == 0 and (step == 1 or step % 50 == 0):
            print(f"step {step:5d}/{args.max_steps}  loss {loss.item():.6f}", flush=True)

    final_loss = loss.detach()
    if distributed:
        # Averaging across ranks exercises an all-reduce — the collective that
        # hangs when NCCL is misconfigured.
        torch.distributed.all_reduce(final_loss, op=torch.distributed.ReduceOp.SUM)
        final_loss = final_loss / world_size

    if not torch.isfinite(final_loss):
        if rank == 0:
            print(f"SMOKE TEST FAILED (non-finite final loss {final_loss.item()})", flush=True)
        raise SystemExit(1)

    if rank == 0:
        os.makedirs(args.output_dir, exist_ok=True)
        to_save = model.module if distributed else model
        ckpt_path = os.path.join(args.output_dir, "checkpoint.pt")
        torch.save(to_save.state_dict(), ckpt_path)
        print(f"checkpoint saved: {ckpt_path}", flush=True)
        print(f"wall time: {time.time() - start:.1f}s", flush=True)
        print(f"SMOKE TEST PASSED (final loss {final_loss.item():.6f})", flush=True)

    if distributed:
        torch.distributed.destroy_process_group()


if __name__ == "__main__":
    main()
