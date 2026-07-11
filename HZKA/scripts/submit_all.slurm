#!/bin/bash
#SBATCH --job-name=hzka_all
#SBATCH --output=/datastore/uitchain/hzka_benchmark/logs/bench_all_%j.out
#SBATCH --error=/datastore/uitchain/hzka_benchmark/logs/bench_all_%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=200G
#SBATCH --time=24:00:00
#SBATCH --partition=defq

cd /datastore/uitchain/hzka_benchmark
export RAYON_NUM_THREADS=$SLURM_CPUS_PER_TASK
bash run_benchmark_all.sh