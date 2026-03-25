#!/bin/bash
SCENARIO=$1
LOG_FILE="monitor_${SCENARIO}.log"

echo "Monitoring Metrics for $SCENARIO..." > $LOG_FILE

# 1. Monitor PCIe Throughput (Rx/Tx) in the background
# -s t: PCIe throughput, -i 0: GPU 0
nvidia-smi dmon -s t -i 0 -c 300 >> $LOG_FILE &

# 2. Monitor NUMA Misses/Foreign memory hits
# We run this in a loop to capture snapshots during the weight-casting phase
while true; do
    echo "--- NUMA SNAPSHOT $(date +%T) ---" >> $LOG_FILE
    numastat -n >> $LOG_FILE
    sleep 2
done &

# Save the PID of the loop so it can be cleaned up if needed
# (Though the pkill in the main script will handle it)