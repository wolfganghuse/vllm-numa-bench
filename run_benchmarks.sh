#!/bin/bash

# --- CONFIGURATION ---
#export HF_TOKEN="your_huggingface_token_here"
export CUDA_VISIBLE_DEVICES=0
export OMP_NUM_THREADS=$(nproc)

# Models
BASELINE_MODEL="meta-llama/Meta-Llama-3-8B"
TEST_MODEL="meta-llama/Meta-Llama-3-70B"
DATASET_FILE="ShareGPT_V3_unfiltered_cleaned_split.json"
NUM_PROMPTS=200

# NUMA Nodes (Verify with ./system_check.sh)
LOCAL_NODE=0
REMOTE_NODE=1

# --- HELPER FUNCTIONS ---

run_warmup() {
    echo "========================================"
    echo "Performing Warm-up (Caching 70B weights)..."
    vllm serve $TEST_MODEL --quantization fp8 --max-model-len 8192 > server_warmup.log 2>&1 &
    WARMUP_PID=$!
    
    # Wait for engine to initialize
    until curl -s http://localhost:8000/v1/models > /dev/null; do sleep 2; done
    
    echo "Warmup complete. Shutting down server..."
    kill -9 $WARMUP_PID 2>/dev/null
    sudo fuser -k /dev/nvidia* > /dev/null 2>&1
    sleep 10
}

run_baseline() {
    echo "========================================"
    echo "Starting Scenario: BASELINE (No Quant, 8B Model)"
    
    # Run 8B in BF16 to see max PCIe pipe speed
    numactl --cpunodebind=$LOCAL_NODE --membind=$LOCAL_NODE vllm serve $BASELINE_MODEL \
        --dtype bfloat16 > server_baseline.log 2>&1 &
    SERVER_PID=$!

    ./monitor.sh "baseline" &
    MONITOR_PID=$!

    until curl -s http://localhost:8000/v1/models > /dev/null; do
        if ! kill -0 $SERVER_PID 2>/dev/null; then echo "ERROR: Baseline crashed!"; return 1; fi
        sleep 1
    done

    echo "Baseline I/O captured. Tearing down..."
    kill -9 $SERVER_PID 2>/dev/null
    kill -9 $MONITOR_PID 2>/dev/null
    sudo fuser -k /dev/nvidia* > /dev/null 2>&1
    sleep 10
}

run_scenario() {
    SCENARIO_NAME=$1
    CPU_NODE=$2
    MEM_NODE=$3
    MODEL_TO_BENCH=$TEST_MODEL
    
    OUT_FILE="results_${SCENARIO_NAME}.json"
    LOAD_TIME_FILE="load_time_${SCENARIO_NAME}.txt"

    echo "========================================"
    echo "Starting Scenario: $SCENARIO_NAME"
    echo "CPU Node: $CPU_NODE | Memory Node: $MEM_NODE"

    # 1. Start vLLM Server
    START_TIME=$(date +%s)
    numactl --cpunodebind=$CPU_NODE --membind=$MEM_NODE vllm serve $MODEL_TO_BENCH \
        --quantization fp8 > server_${SCENARIO_NAME}.log 2>&1 &
    SERVER_PID=$!

    ./monitor.sh $SCENARIO_NAME &
    MONITOR_PID=$!

    echo "Waiting for Engine Initialization..."
    until curl -s http://localhost:8000/v1/models > /dev/null; do
        if ! kill -0 $SERVER_PID 2>/dev/null; then echo "ERROR: Server crashed!"; return 1; fi
        sleep 2
    done
    END_TIME=$(date +%s)
    echo $((END_TIME - START_TIME)) > $LOAD_TIME_FILE
    echo "Engine Initialized in $((END_TIME - START_TIME))s."

    # 2. Run Benchmark Client
    echo "Running benchmark client..."
    vllm bench serve \
        --model $MODEL_TO_BENCH \
        --dataset-name sharegpt \
        --dataset-path $DATASET_FILE \
        --num-prompts $NUM_PROMPTS \
        --save-result \
        --result-filename $OUT_FILE

    # 3. Teardown
    echo "Shutting down server..."
    kill -9 $SERVER_PID 2>/dev/null
    kill -9 $MONITOR_PID 2>/dev/null
    sudo fuser -k /dev/nvidia* > /dev/null 2>&1
    sleep 15
    echo "Scenario $SCENARIO_NAME completed."
}

# --- MAIN EXECUTION ---
# Make sure weights are in RAM but not disk-throttled
run_warmup

# Run Baseline (I/O only)
run_baseline

# Run Main 70B Scenarios
run_scenario "optimal" $LOCAL_NODE $LOCAL_NODE
run_scenario "split"   $LOCAL_NODE "0,1"
run_scenario "remote"  $LOCAL_NODE $REMOTE_NODE

echo "========================================"
echo "All benchmarks finished. Run analyze_results.py to view data."