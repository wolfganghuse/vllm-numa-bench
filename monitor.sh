#!/bin/bash
# monitor.sh: Logs NUMA faults and GPU utilization

PHASE=$1
LOG_FILE="monitor_${PHASE}.log"

echo "Starting hardware monitoring for phase: $PHASE" > $LOG_FILE

while true; do
    echo "--- $(date '+%H:%M:%S') ---" >> $LOG_FILE
    
    # Check NUMA remote misses (indicates interconnect traffic)
    numastat -s | grep "numa_miss" >> $LOG_FILE
    numastat -s | grep "numa_foreign" >> $LOG_FILE
    
    # Check PCIe Rx/Tx throughput to GPU
    nvidia-smi dmon -s t -c 1 >> $LOG_FILE
    
    sleep 2
done