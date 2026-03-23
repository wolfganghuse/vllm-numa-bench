import json
import os
import pandas as pd
from tabulate import tabulate

def main():
    scenarios = ['optimal', 'split', 'remote']
    results = []

    print("Aggregating benchmark data...\n")

    for scenario in scenarios:
        json_filepath = f"results_{scenario}.json"
        txt_filepath = f"load_time_{scenario}.txt"
        
        # 1. Parse Load Time (Weight Casting Phase)
        load_time_sec = "N/A"
        if os.path.exists(txt_filepath):
            with open(txt_filepath, 'r') as f:
                try:
                    load_time_sec = int(f.read().strip())
                except ValueError:
                    load_time_sec = "Error"
        else:
            print(f"Warning: {txt_filepath} not found.")

        # 2. Parse Throughput and TPOT (Inference Phase)
        throughput = 0.0
        tpot_p99 = 0.0
        
        if os.path.exists(json_filepath):
            with open(json_filepath, 'r') as f:
                data = json.load(f)
                
                # Extract Request Throughput (requests per second)
                throughput = data.get("request_throughput", 0.0)
                
                # Extract P99 Time Per Output Token (ms)
                # vLLM bench typically nests this inside a dictionary, but we use 
                # .get() safely in case the format shifted in v0.18
                tpot_data = data.get("time_per_output_token_ms", {})
                if isinstance(tpot_data, dict):
                    tpot_p99 = tpot_data.get("p99", 0.0)
                elif isinstance(data.get("p99_tpot_ms"), (int, float)):
                    # Fallback for alternative vLLM JSON formatting
                    tpot_p99 = data.get("p99_tpot_ms", 0.0)
        else:
            print(f"Warning: {json_filepath} not found.")

        # Append to our dataset
        results.append({
            "Scenario": scenario.upper(),
            "Load Time (s)": load_time_sec,
            "Throughput (req/s)": round(throughput, 2) if isinstance(throughput, float) else throughput,
            "P99 TPOT (ms)": round(tpot_p99, 2) if isinstance(tpot_p99, float) else tpot_p99
        })

    # 3. Generate the Markdown Table
    if results:
        df = pd.DataFrame(results)
        print("--- DUAL-BOTTLENECK BENCHMARK RESULTS ---")
        print(tabulate(df, headers='keys', tablefmt='grid', showindex=False))
        print("-----------------------------------------")
        
        print("\nAnalysis Guide for your Thesis:")
        print("- Load Time validates Bottleneck 1: Interconnect Saturation during BF16 -> FP8 Casting.")
        print("- Throughput & TPOT validate Bottleneck 2: CPU-GPU Command Latency during Inference.")

if __name__ == "__main__":
    main()