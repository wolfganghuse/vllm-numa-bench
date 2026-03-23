#!/bin/bash
# Note: Corrected shebang from #!/bash/bin to #!/bin/bash

MODEL="meta-llama/Meta-Llama-3-70B"
NUM_PROMPTS=200
BENCH_SCRIPT="./vllm_repo/benchmarks/benchmark_serving.py"

# UPDATE THESE BASED ON `nvidia-smi topo -m`
LOCAL_NODE=0
REMOTE_NODE=1

run_scenario() {
    SCENARIO_NAME=$1
    CPU_NODE=$2
    MEM_NODE=$3
    OUT_FILE="results_${SCENARIO_NAME}.json"

    echo "========================================"
    echo "Starting Scenario: $SCENARIO_NAME"
    echo "CPU Node: $CPU_NODE | Memory Node: $MEM_NODE"
    
    # Drop caches to ensure true cold-start for weight loading
    sync; echo 3 > /proc/sys/vm/drop_caches

    # Start monitoring in the background
    ./monitor.sh $SCENARIO_NAME &
    MONITOR_PID=$!

    # Execute benchmark
    numactl --cpunodebind=$CPU_NODE --membind=$MEM_NODE python3 $BENCH_SCRIPT \
        --model $MODEL \
        --quantization fp8 \
        --num-prompts $NUM_PROMPTS \
        --output-json $OUT_FILE

    # Kill monitoring script
    kill $MONITOR_PID
    echo "Scenario $SCENARIO_NAME completed."
    echo "========================================"
    sleep 5
}

# 1. OPTIMAL: Local CPU, Local Mem
run_scenario "optimal" $LOCAL_NODE $LOCAL_NODE

# 2. REMOTE: Remote CPU, Remote Mem (Worst Case)
run_scenario "remote" $REMOTE_NODE $REMOTE_NODE

# 3. SPLIT: Local CPU, Remote Mem (Memory Thrashing)
run_scenario "split" $LOCAL_NODE $REMOTE_NODE

echo "All benchmarks finished. Run analyze_results.py to view data."