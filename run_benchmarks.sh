#!/bin/bash

source vllm_env/bin/activate

# Define two models
BASELINE_MODEL="meta-llama/Meta-Llama-3-8B"
TEST_MODEL="meta-llama/Meta-Llama-3-70B"

NUM_PROMPTS=200
#export HF_TOKEN="hf_your_actual_token_here" # Ensure your token is still here
export OMP_NUM_THREADS=$(nproc)

LOCAL_NODE=0
REMOTE_NODE=1
DATASET_FILE="sharegpt.json"

# --- PRE-FLIGHT: Download ShareGPT Dataset ---
if [ ! -f "$DATASET_FILE" ]; then
    echo "Downloading ShareGPT dataset for realistic TPOT benchmarking..."
    wget -qO $DATASET_FILE https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json
    echo "Download complete."
fi

run_warmup() {
    echo "========================================"
    echo "Performing Warm-up Run (Caching weights & compiling CUDA)..."
    
    vllm serve $MODEL --quantization fp8 > server_warmup.log 2>&1 &
    WARMUP_PID=$!

    while ! curl -s http://localhost:8000/v1/models > /dev/null; do
        if ! kill -0 $WARMUP_PID 2>/dev/null; then
            echo "ERROR: Warmup crashed! Check server_warmup.log"
            exit 1
        fi
        sleep 2
    done

    echo "Warmup engine initialized. Shutting down to start pristine tests..."
    kill -9 $WARMUP_PID 2>/dev/null
    pkill -9 -f "vllm"
    sudo fuser -k /dev/nvidia* > /dev/null 2>&1
    sleep 10
    echo "Warmup complete."
    echo "========================================"
}

run_scenario() {
    SCENARIO_NAME=$1
    CPU_NODE=$2
    MEM_NODE=$3
    OUT_FILE="results_${SCENARIO_NAME}.json"
    LOAD_TIME_FILE="load_time_${SCENARIO_NAME}.txt"

    echo "========================================"
    echo "Starting Scenario: $SCENARIO_NAME"
    echo "CPU Node: $CPU_NODE | Memory Node: $MEM_NODE"
    
    # Drop caches to test memory bandwidth
    # sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    ./monitor.sh $SCENARIO_NAME &
    MONITOR_PID=$!

    echo "Starting vLLM Server..."
    START_TIME=$(date +%s)

    numactl --cpunodebind=$CPU_NODE --membind=$MEM_NODE vllm serve $TEST_MODEL \
        --quantization fp8 > server_${SCENARIO_NAME}.log 2>&1 &
    SERVER_PID=$!

    while ! curl -s http://localhost:8000/v1/models > /dev/null; do
        if ! kill -0 $SERVER_PID 2>/dev/null; then
            echo "ERROR: vLLM server crashed! Check server_${SCENARIO_NAME}.log"
            kill $MONITOR_PID
            return 1
        fi
        sleep 2
    done

    END_TIME=$(date +%s)
    LOAD_TIME=$((END_TIME - START_TIME))
    echo "Engine Initialized! Total Bash Load Time: $LOAD_TIME seconds."
    echo $LOAD_TIME > $LOAD_TIME_FILE

    echo "Running benchmark client with ShareGPT dataset..."
    
    # --- UPDATED CLIENT COMMAND ---
    vllm bench serve \
        --model $MODEL \
        --dataset-name sharegpt \
        --dataset-path $DATASET_FILE \
        --num-prompts $NUM_PROMPTS \
        --save-result \
        --result-filename $OUT_FILE

    echo "Shutting down server..."
    kill -9 $SERVER_PID 2>/dev/null
    kill -9 $MONITOR_PID 2>/dev/null
    pkill -9 -f "vllm"
    sudo fuser -k /dev/nvidia* > /dev/null 2>&1
    sleep 10
    
    echo "Scenario $SCENARIO_NAME completed."
    echo "========================================"
    sleep 5
}

run_baseline() {
    echo "========================================"
    echo "Starting Scenario: BASELINE (No Quant, 8B Model)"
    
    # We use the 8B model here so it fits in 96GB VRAM at BF16
    numactl --cpunodebind=$LOCAL_NODE --membind=$LOCAL_NODE vllm serve $BASELINE_MODEL \
        --dtype bfloat16 > server_baseline.log 2>&1 &
    SERVER_PID=$!

    ./monitor.sh "baseline" &
    MONITOR_PID=$!

    while ! curl -s http://localhost:8000/v1/models > /dev/null; do
        if ! kill -0 $SERVER_PID 2>/dev/null; then
            echo "ERROR: Baseline crashed!"
            kill $MONITOR_PID
            return 1
        fi
        sleep 1
    done

    echo "Baseline initialized. Tearing down..."
    kill -9 $SERVER_PID 2>/dev/null
    kill -9 $MONITOR_PID 2>/dev/null
    sudo fuser -k /dev/nvidia* > /dev/null 2>&1
    sleep 10
}

# --- EXECUTION PIPELINE ---
run_warmup
run_baseline # <--- Add this here

# 1. OPTIMAL: Local CPU, Local Mem
run_scenario "optimal" $LOCAL_NODE $LOCAL_NODE

# 2. SPLIT: Local CPU, Remote Mem (Memory Thrashing)
run_scenario "split" $LOCAL_NODE $REMOTE_NODE

# 3. REMOTE: Remote CPU, Remote Mem (Worst Case)
run_scenario "remote" $REMOTE_NODE $REMOTE_NODE

echo "All benchmarks finished. Run analyze_results.py to view data."