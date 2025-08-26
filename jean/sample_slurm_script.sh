#!/usr/bin/env bash
#SBATCH --account ousaf40080AIR
#SBATCH -p standard
#SBATCH --job-name=[JOB NAME]
#SBATCH --output=%j.out
#SBATCH --error=%j.err
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node 4
#SBATCH --time=20:00:00

source $(pwd)/scripts/jean/load_modules_cuda.sh
# module load conda
echo $pwd


# Remember to run `pip install nvidia-nccl-cu12`

export NUM_GPUS=4

# Conda env
source /p/home/jjalora/anaconda3/etc/profile.d/conda.sh
eval "$(/p/home/jjalora/anaconda3/bin/conda shell.bash hook)"
conda activate [CONDA_ENV_NAME]

MASTER_ADDR=$(scontrol show hostnames $SLURM_JOB_NODELIST | head -n 1)
export MASTER_ADDR=$MASTER_ADDR
export MASTER_PORT=37500

export NCCL_IB_DISABLE=0
export NCCL_NET=IB
export NCCL_IB_HCA=mlx5_0:1,mlx5_3:1  # Use both 200G IB ports
export NCCL_IB_ADDR_FAMILY=AF_INET
export NCCL_SOCKET_IFNAME=ib0  # For bootstrap only
# export NCCL_DEBUG=INFO


echo "MASTER_ADDR: $MASTER_ADDR"
echo "MASTER_PORT: $MASTER_PORT"

srun torchrun \
    --nnodes=$SLURM_NNODES \
    --nproc_per_node=$NUM_GPUS \
    --rdzv_id=$SLURM_JOB_ID \
    --rdzv_backend=c10d \
    --rdzv_endpoint=${MASTER_ADDR}:${MASTER_PORT} \
    train.py