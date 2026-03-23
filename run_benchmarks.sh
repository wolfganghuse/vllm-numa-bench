#!/bin/bash

source vllm_env/bin/activate

MODEL="meta-llama/Meta-Llama-3-8B" 
NUM_PROMPTS=200
export HF_TOKEN="hf_your_actual_token_here" # Ensure your token is still here

LOCAL_NODE=0
REMOTE_NODE=1

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
    kill $WARMUP_PID
    wait $WARMUP_PID 2>/dev/null
    sleep 5
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
    
    # Drop caches to test memory bandwidth, but keep disk/compiler caches intact
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    ./monitor.sh $SCENARIO_NAME &
    MONITOR_PID=$!

    echo "Starting vLLM Server..."
    START_TIME=$(date +%s)

    numactl --cpunodebind=$CPU_NODE --membind=$MEM_NODE vllm serve $MODEL \
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

    echo "Running benchmark client..."
    vllm bench serve \
        --model $MODEL \
        --dataset-name random \
        --num-prompts $NUM_PROMPTS \
        --save-result \
        --result-filename $OUT_FILE

    echo "Shutting down server..."
    kill $SERVER_PID
    wait $SERVER_PID 2>/dev/null
    
    kill $MONITOR_PID
    echo "Scenario $SCENARIO_NAME completed."
    echo "========================================"
    sleep 5
}

# --- EXECUTION PIPELINE ---
run_warmup

# 1. OPTIMAL: Local CPU, Local Mem
run_scenario "optimal" $LOCAL_NODE $LOCAL_NODE

# 2. SPLIT: Local CPU, Remote Mem (Memory Thrashing)
run_scenario "split" $LOCAL_NODE $REMOTE_NODE

# 3. REMOTE: Remote CPU, Remote Mem (Worst Case)
run_scenario "remote" $REMOTE_NODE $REMOTE_NODE

echo "All benchmarks finished. Run analyze_results.py to view data."