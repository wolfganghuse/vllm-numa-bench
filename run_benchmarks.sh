#!/bin/bash

# --- CONFIGURATION ---
#export HF_TOKEN="your_token_here"
export CUDA_VISIBLE_DEVICES=0
export OMP_NUM_THREADS=$(nproc)

# Models
BASELINE_MODEL="meta-llama/Meta-Llama-3-8B"
TEST_MODEL="meta-llama/Meta-Llama-3-70B"
DATASET_FILE="ShareGPT_V3_unfiltered_cleaned_split.json"
NUM_PROMPTS=200

# NUMA Nodes (Confirmed for your 4-node Blackwell system)
LOCAL_NODE=0
REMOTE_NODE=2  # True physical socket jump

# --- CLEANUP FUNCTION ---
cleanup() {
    echo "Cleaning up processes and GPU memory..."
    pkill -9 -f "vllm"
    pkill -9 -f "monitor.sh"
    pkill -9 -f "nvidia-smi"
    sudo fuser -k /dev/nvidia* > /dev/null 2>&1
    sleep 5
}

# --- RUN SCENARIO FUNCTION ---
run_scenario() {
    # Arguments
    local NAME=$1
    local CPU=$2
    local MEM=$3
    local MODEL=$TEST_MODEL
    
    echo "========================================"
    echo "SCENARIO: $NAME | CPU: $CPU | MEM: $MEM"
    
    # 1. Start Monitor
    ./monitor.sh "$NAME" &
    local MON_PID=$!

    # 2. Start vLLM Server
    echo "Starting vLLM Server ($MODEL)..."
    local START_TIME=$(date +%s)
    
    numactl --cpunodebind=$CPU --membind=$MEM vllm serve "$MODEL" \
        --quantization fp8 > "server_$NAME.log" 2>&1 &

    local SVR_PID=$!

    # 3. Wait for Health
    echo "Waiting for Engine Initialization (this can take 90s for 70B)..."
    while ! curl -s http://localhost:8000/v1/models > /dev/null; do
        if ! kill -0 $SVR_PID 2>/dev/null; then
            echo "ERROR: Server crashed! Check server_$NAME.log"
            cleanup
            return 1
        fi
        sleep 2
    done
    local END_TIME=$(date +%s)
    echo $((END_TIME - START_TIME)) > "load_time_$NAME.txt"
    echo "Engine Ready in $((END_TIME - START_TIME))s."

    # 4. Run Benchmark Client
    echo "Running Benchmark Client..."
    vllm bench serve \
        --model "$MODEL" \
        --dataset-name sharegpt \
        --dataset-path "$DATASET_FILE" \
        --num-prompts "$NUM_PROMPTS" \
        --save-result \
        --result-filename "results_$NAME.json"

    # 5. Teardown
    cleanup
}

# --- MAIN EXECUTION ---
cleanup  # Start fresh

echo "Starting Baseline (8B BF16)..."
# Simplified Baseline logic to avoid crashes
numactl --cpunodebind=$LOCAL_NODE --membind=$LOCAL_NODE vllm serve "$BASELINE_MODEL" --dtype bfloat16 > server_baseline.log 2>&1 &
SVR_PID=$!
./monitor.sh "baseline" &
MON_PID=$!
while ! curl -s http://localhost:8000/v1/models > /dev/null; do sleep 2; done
cleanup

# Run the 70B Scenarios
run_scenario "optimal" "$LOCAL_NODE" "$LOCAL_NODE"
run_scenario "remote"  "$LOCAL_NODE" "$REMOTE_NODE"

echo "DONE. Run analyze_results.py"