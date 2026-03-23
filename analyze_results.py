import json
import os
import re
import pandas as pd
from tabulate import tabulate

def main():
    scenarios = ['baseline', 'optimal', 'split', 'remote']
    results = []

    print("Aggregating benchmark data...\n")

    for scenario in scenarios:
        json_filepath = f"results_{scenario}.json"
        txt_filepath = f"load_time_{scenario}.txt"
        server_log = f"server_{scenario}.log"
        monitor_log = f"monitor_{scenario}.log"
        
        # 1. Parse Total Bash Boot Time
        bash_load_time = "N/A"
        if os.path.exists(txt_filepath):
            with open(txt_filepath, 'r') as f:
                try:
                    bash_load_time = int(f.read().strip())
                except ValueError:
                    bash_load_time = "Error"

        # 2. Deep Dive: Parse Engine Logs for pure weight casting time
        weight_load_time = "N/A"
        engine_load_time = "N/A"
        if os.path.exists(server_log):
            with open(server_log, 'r') as f:
                log_content = f.read()
                wt_match = re.search(r'Loading weights took ([0-9.]+) seconds', log_content)
                if wt_match:
                    weight_load_time = float(wt_match.group(1))
                    
                eng_match = re.search(r'Model loading took .* and ([0-9.]+) seconds', log_content)
                if eng_match:
                    engine_load_time = float(eng_match.group(1))

        # 3. Parse PCIe Bandwidth from Monitor Logs
        peak_rx_gbs = 0.0
        if os.path.exists(monitor_log):
            with open(monitor_log, 'r') as f:
                for line in f:
                    # nvidia-smi dmon outputs GPU index, rxpci (MB/s), txpci (MB/s)
                    # Example line: "    0      4500       12"
                    match = re.match(r'^\s*0\s+(\d+)\s+(\d+)', line)
                    if match:
                        rx_mbs = int(match.group(1))
                        if rx_mbs > (peak_rx_gbs * 1000): # Convert GB/s back to MB/s for comparison
                            peak_rx_gbs = rx_mbs / 1000.0

        # 4. Parse Throughput and TPOT
        throughput = 0.0
        tpot_p99 = 0.0
        if os.path.exists(json_filepath):
            with open(json_filepath, 'r') as f:
                data = json.load(f)
                throughput = data.get("request_throughput", 0.0)
                
                # Check for vLLM 0.18+ flat schema first
                if "p99_tpot_ms" in data:
                    tpot_p99 = data["p99_tpot_ms"]
                # Fallback to older nested schema
                elif "time_per_output_token_ms" in data:
                    tpot_p99 = data["time_per_output_token_ms"].get("p99", 0.0)
        else:
            print(f"Warning: {json_filepath} not found.")

        # Append to our dataset
        results.append({
            "Scenario": scenario.upper(),
            "Total Boot (s)": bash_load_time,
            "Weight Casting (s)": round(weight_load_time, 2) if isinstance(weight_load_time, float) else weight_load_time,
            "Peak PCIe Rx (GB/s)": round(peak_rx_gbs, 2),
            "Throughput (req/s)": round(throughput, 2) if isinstance(throughput, float) else throughput,
            "P99 TPOT (ms)": round(tpot_p99, 2) if isinstance(tpot_p99, float) else tpot_p99
        })

    # Generate the Markdown Table
    if results:
        df = pd.DataFrame(results)
        print("--- DUAL-BOTTLENECK BENCHMARK RESULTS ---")
        print(tabulate(df, headers='keys', tablefmt='grid', showindex=False))
        print("-----------------------------------------")
        print("\nNote: Peak PCIe Rx measures the data transfer speed into the GPU during weight loading.")

if __name__ == "__main__":
    main()