#!/bin/bash
set -e

echo "Installing OS NUMA utilities..."
sudo apt-get update
sudo apt-get install -y numactl hwloc linux-tools-common linux-tools-generic jq

echo "Setting up Python environment..."
python3 -m venv vllm_env
source vllm_env/bin/activate

echo "Installing vLLM and dependencies..."
pip install --upgrade pip
pip install vllm pandas tabulate

# Clone vLLM to get their official benchmark_serving.py script
if [ ! -d "vllm_repo" ]; then
    git clone https://github.com/vllm-project/vllm.git vllm_repo
fi

echo "Setup complete. Activate your environment using: source vllm_env/bin/activate"