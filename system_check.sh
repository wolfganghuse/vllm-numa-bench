#!/bin/bash
# system_check.sh: Inspects CPU, NUMA, and GPU topology

echo "====================================================="
echo "            SYSTEM TOPOLOGY EXAMINATION              "
echo "====================================================="

echo -e "\n[1/4] CPU & SYSTEM OVERVIEW"
echo "-----------------------------------------------------"
lscpu | egrep -i 'Model name|Socket\(s\)|Core\(s\) per socket|NUMA node\(s\)|Architecture'
echo "Total System Memory:"
free -h | awk '/^Mem:/ {print "  " $2}'

echo -e "\n[2/4] NUMA TOPOLOGY & MEMORY DISTANCE"
echo "-----------------------------------------------------"
if command -v numactl &> /dev/null; then
    # Shows how much RAM is on each node and the interconnect penalty matrix
    numactl --hardware 
else
    echo "ERROR: numactl not found. Please run setup.sh."
fi

echo -e "\n[3/4] GPU INVENTORY"
echo "-----------------------------------------------------"
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id --format=csv,noheader | \
    awk -F', ' '{print "GPU " $1 ": " $2 " | VRAM: " $3 " | PCIe Bus: " $4}'
else
    echo "ERROR: nvidia-smi not found."
fi

echo -e "\n[4/4] GPU-NUMA AFFINITY MATRIX (CRITICAL)"
echo "-----------------------------------------------------"
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi topo -m
else
    echo "ERROR: Cannot map affinity without nvidia-smi."
fi
echo "====================================================="
echo "ACTION REQUIRED:"
echo "Look at the [4/4] Affinity Matrix above. Find your GPU row."
echo "Match it to the NUMA Node column that shows 'NODE' (meaning local)."
echo "This is your LOCAL_NODE. The other socket is your REMOTE_NODE."
echo "Update these variables in run_benchmarks.sh."
echo "====================================================="