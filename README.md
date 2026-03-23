# vLLM NUMA & Quantization Benchmark

This repository tests the impact of NUMA placement on vLLM online quantization (FP8) load times and inference throughput.

## Prerequisites
* Dual-socket CPU (Intel/AMD)
* At least 1x NVIDIA GPU (A100/H100)
* Ubuntu 22.04+ with NVIDIA drivers installed

## Usage
1. Run `./setup.sh` to install dependencies.
2. Determine your GPU's affinity using `nvidia-smi topo -m`. Update `LOCAL_NODE` and `REMOTE_NODE` in `run_benchmarks.sh` accordingly.
3. Execute `sudo ./run_benchmarks.sh`. (Sudo is recommended for accurate memory dropping).
4. Run `python3 analyze_results.py` to view the performance staircase.