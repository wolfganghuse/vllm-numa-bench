#!/bin/bash

# --- CONFIGURATION ---
export HF_TOKEN="your_huggingface_token_here"
export CUDA_VISIBLE_DEVICES=0
export OMP_NUM_THREADS=$(nproc)

# Models
BASELINE_MODEL="meta-llama/Meta-Llama-3-8B"
TEST_MODEL="meta-llama/Meta-Llama-3-70B"
DATASET_URL="https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json"
DATASET_FILE="ShareGPT_V3_unfiltered_cleaned_split.json"
NUM_PROMPTS=200

# NUMA Nodes (Verify with ./system_check.sh)
LOCAL_NODE=0
REMOTE_NODE=1

# --- PRE-FLIGHT CHECKS ---
check_dependencies() {
    echo "Checking dependencies..."
    
    # 1. Check for Dataset
    if [ ! -f "$DATASET_FILE" ]; then
        echo "Dataset missing! Downloading from HuggingFace..."
        wget -O "$DATASET_FILE" "$DATASET_URL"
    else
        echo "Dataset found: $DATASET_FILE"
    fi

    # 2. Check for numactl
    if ! command -v numactl &> /dev/null; then
        echo "ERROR: numactl is not installed. Run 'sudo apt install numactl'"
        exit 1
    fi

    # 3. Check for GPU
    if ! nvidia-smi -i 0 &> /dev/null; then
        echo "ERROR: GPU 0 not found or CUDA_VISIBLE_DEVICES is wrong."
        exit 1
    fi
}

# --- HELPER FUNCTIONS ---

run_warmup() {
    echo "========================================"
    echo "Performing Warm-up (Caching 70B weights)..."
    # We do a standard boot to ensure weights are in OS Page Cache
    vllm serve $TEST_MODEL --quantization fp8 --max-model-len 8192 > server_warmup.log 2>&1 &
    WARMUP_PID=$!
    
    until curl -s http://localhost:8000/v1/models > /dev/null; do 
        if ! kill -0 $WARMUP_PID 2>/dev/null; then echo "Warmup Crashed! Check server_warmup.log"; exit 1; fi
        sleep 5
    done
    
    echo "Warmup complete. Clearing GPU..."
    kill -9 $WARMUP_PID 2>/dev/null
    sudo fuser -k /dev/nvidia* > /dev/null 2>&1
    sleep 10
}

run_baseline() {
    echo "========================================"
    echo "Starting Scenario: BASELINE (No Quant, 8B Model)"
    
    ./monitor.sh "baseline" &
    MONITOR_PID=$!

    numactl --cpunodebind=$LOCAL_NODE --membind=$LOCAL_NODE vllm serve $BASELINE_MODEL \
        --dtype bfloat16 > server_baseline.log 2>&1 &
    SERVER_PID=$!

    until curl -s http://localhost:8000/v1/models > /dev/null; do
        if ! kill -0 $SERVER_PID 2>/dev/null; then echo "ERROR: Baseline crashed!"; break; fi
        sleep 1
    done

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

    ./monitor.sh $SCENARIO_NAME &
    MONITOR_PID=$!

    START_TIME=$(date +%s)
    numactl --cpunodebind=$CPU_NODE --membind=$MEM_NODE vllm serve $MODEL_TO_BENCH \
        --quantization fp8 > server_${SCENARIO_NAME}.log 2>&1 &
    SERVER_PID=$!

    echo "Waiting for Engine Initialization..."
    until curl -s http://localhost:8000/v1/models > /dev/null; do
        if ! kill -0 $SERVER_PID 2>/dev/null; then echo "ERROR: Server crashed!"; return 1; fi
        sleep 2
    done
    END_TIME=$(date +%s)
    echo $((END_TIME - START_TIME)) > $LOAD_TIME_FILE

    echo "Running benchmark client..."
    vllm bench serve \
        --model $MODEL_TO_BENCH \
        --dataset-name sharegpt \
        --dataset-path $DATASET_FILE \
        --num-prompts $NUM_PROMPTS \
        --save-result \
        --result-filename $OUT_FILE

    kill -9 $SERVER_PID 2>/dev/null
    kill -9 $MONITOR_PID 2>/dev/null
    sudo fuser -k /dev/nvidia* > /dev/null 2>&1
    sleep 15
}

# --- MAIN EXECUTION ---
check_dependencies
run_warmup
run_baseline
run_scenario "optimal" $LOCAL_NODE $LOCAL_NODE
run_scenario "split"   $LOCAL_NODE "0,1"
run_scenario "remote"  $LOCAL_NODE $REMOTE_NODE

echo "========================================"
echo "All benchmarks finished. Run analyze_results.py to view data."