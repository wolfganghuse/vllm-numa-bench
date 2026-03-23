import json
import os
import re
import pandas as pd
from tabulate import tabulate

def main():
    scenarios = ['optimal', 'split', 'remote']
    results = []

    print("Aggregating benchmark data...\n")

    for scenario in scenarios:
        json_filepath = f"results_{scenario}.json"
        txt_filepath = f"load_time_{scenario}.txt"
        log_filepath = f"server_{scenario}.log"
        
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
        if os.path.exists(log_filepath):
            with open(log_filepath, 'r') as f:
                log_content = f.read()
                
                # Looks for: "Loading weights took 7.26 seconds"
                wt_match = re.search(r'Loading weights took ([0-9.]+) seconds', log_content)
                if wt_match:
                    weight_load_time = float(wt_match.group(1))
                    
                # Looks for: "Model loading took X GiB memory and 8.802694 seconds"
                eng_match = re.search(r'Model loading took .* and ([0-9.]+) seconds', log_content)
                if eng_match:
                    engine_load_time = float(eng_match.group(1))

        # 3. Parse Throughput and TPOT
        throughput = 0.0
        tpot_p99 = 0.0
        if os.path.exists(json_filepath):
            with open(json_filepath, 'r') as f:
                data = json.load(f)
                throughput = data.get("request_throughput", 0.0)
                
                tpot_data = data.get("time_per_output_token_ms", {})
                if isinstance(tpot_data, dict):
                    tpot_p99 = tpot_data.get("p99", 0.0)
                elif isinstance(data.get("p99_tpot_ms"), (int, float)):
                    tpot_p99 = data.get("p99_tpot_ms", 0.0)
        else:
            print(f"Warning: {json_filepath} not found. Did you add --save-result?")

        # Append to our dataset
        results.append({
            "Scenario": scenario.upper(),
            "Total Boot (s)": bash_load_time,
            "Internal Engine Boot (s)": round(engine_load_time, 2) if isinstance(engine_load_time, float) else engine_load_time,
            "Weight Casting Phase (s)": round(weight_load_time, 2) if isinstance(weight_load_time, float) else weight_load_time,
            "Throughput (req/s)": round(throughput, 2) if isinstance(throughput, float) else throughput,
            "P99 TPOT (ms)": round(tpot_p99, 2) if isinstance(tpot_p99, float) else tpot_p99
        })

    # Generate the Markdown Table
    if results:
        df = pd.DataFrame(results)
        print("--- DUAL-BOTTLENECK BENCHMARK RESULTS ---")
        print(tabulate(df, headers='keys', tablefmt='grid', showindex=False))
        print("-----------------------------------------")
        print("\nNote: 'Weight Casting Phase' isolates the raw I/O and quantization time, removing server overhead.")

if __name__ == "__main__":
    main()