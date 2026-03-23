#!/bin/bash

source vllm_env/bin/activate

MODEL="meta-llama/Meta-Llama-3-8B" 
NUM_PROMPTS=200

# UPDATE THESE BASED ON `nvidia-smi topo -m`
LOCAL_NODE=0
REMOTE_NODE=1

run_scenario() {
    SCENARIO_NAME=$1
    CPU_NODE=$2
    MEM_NODE=$3
    OUT_FILE="results_${SCENARIO_NAME}.json"
    LOAD_TIME_FILE="load_time_${SCENARIO_NAME}.txt"

    echo "========================================"
    echo "Starting Scenario: $SCENARIO_NAME"
    echo "CPU Node: $CPU_NODE | Memory Node: $MEM_NODE"
    
    # Drop caches for true cold-start memory testing
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    # Start hardware monitoring in the background
    ./monitor.sh $SCENARIO_NAME &
    MONITOR_PID=$!

    echo "Starting vLLM Server (Measuring Load Time...)"
    START_TIME=$(date +%s)

    # 1. Start the SERVER in the background, strictly bound to the NUMA nodes
    # We pass the quantization argument here, as this is where weights are loaded!
    numactl --cpunodebind=$CPU_NODE --membind=$MEM_NODE vllm serve $MODEL \
        --quantization fp8 \
        --disable-log-requests > server_${SCENARIO_NAME}.log 2>&1 &
    SERVER_PID=$!

    # 2. Poll the API to find the exact moment the weights finish loading
    while ! curl -s http://localhost:8000/v1/models > /dev/null; do
        # Safety check: Exit if the server crashed (e.g., Out of Memory)
        if ! kill -0 $SERVER_PID 2>/dev/null; then
            echo "ERROR: vLLM server crashed! Check server_${SCENARIO_NAME}.log"
            kill $MONITOR_PID
            return 1
        fi
        sleep 2
    done

    END_TIME=$(date +%s)
    LOAD_TIME=$((END_TIME - START_TIME))
    echo "Engine Initialized! Load Time: $LOAD_TIME seconds."
    
    # Save the load time so our Python analyzer can read it later
    echo $LOAD_TIME > $LOAD_TIME_FILE

    # 3. Start the CLIENT to benchmark throughput and TPOT
    echo "Running benchmark client..."
    vllm bench serve \
        --model $MODEL \
        --dataset-name random \
        --num-prompts $NUM_PROMPTS \
        --result-filename $OUT_FILE

    # 4. Graceful teardown
    echo "Shutting down server..."
    kill $SERVER_PID
    wait $SERVER_PID 2>/dev/null
    
    kill $MONITOR_PID
    echo "Scenario $SCENARIO_NAME completed."
    echo "========================================"
    sleep 5 # Wait a few seconds to ensure the port is completely freed
}

# 1. OPTIMAL: Local CPU, Local Mem
run_scenario "optimal" $LOCAL_NODE $LOCAL_NODE

# 2. REMOTE: Remote CPU, Remote Mem (Worst Case)
run_scenario "remote" $REMOTE_NODE $REMOTE_NODE

# 3. SPLIT: Local CPU, Remote Mem (Memory Thrashing)
run_scenario "split" $LOCAL_NODE $REMOTE_NODE

echo "All benchmarks finished. Check the generated JSON and TXT files."