import json
import os
import pandas as pd
from tabulate import tabulate

scenarios = ['optimal', 'remote', 'split']
results = []

for scenario in scenarios:
    filepath = f"results_{scenario}.json"
    if os.path.exists(filepath):
        with open(filepath, 'r') as f:
            data = json.load(f)
            
            # vLLM benchmark JSON keys may vary slightly by version, 
            # adapt these if necessary.
            throughput = data.get("request_throughput", 0)
            # TPOT (Time Per Output Token) P99
            tpot_p99 = data.get("time_per_output_token_ms", {}).get("p99", 0) 
            
            results.append({
                "Scenario": scenario.upper(),
                "Throughput (req/s)": round(throughput, 2),
                "P99 TPOT (ms)": round(tpot_p99, 2)
            })
    else:
        print(f"Warning: {filepath} not found.")

if results:
    df = pd.DataFrame(results)
    print("\n--- BENCHMARK RESULTS ---")
    print(tabulate(df, headers='keys', tablefmt='grid', showindex=False))
    print("-------------------------\n")
    print("Check monitor_*.log files to correlate NUMA misses with throughput drops.")