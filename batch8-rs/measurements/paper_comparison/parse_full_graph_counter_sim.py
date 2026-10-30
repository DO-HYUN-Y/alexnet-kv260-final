#!/usr/bin/env python3
"""Convert pure-RS simulation counter records into a reproducible CSV."""

from __future__ import annotations

import csv
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LOG = ROOT / "measurements/paper_comparison/evidence/pure_rs_full_graph_counter_profile.log"
OUTPUT = ROOT / "measurements/paper_comparison/results/pure_rs_rtl_sim_counters.csv"

FIELDS = [
    "design",
    "layer",
    "batch_size",
    "clock_hz",
    "useful_macs",
    "peak_macs_per_cycle",
    "input_read_bytes",
    "weight_read_bytes",
    "result_interface_bytes",
    "total_read_payload_bytes",
    "total_cycles",
    "issue_cycles",
    "weight_stall_cycles",
    "activation_stall_cycles",
    "result_stall_cycles",
    "memory_stall_cycles",
    "other_cycles",
    "pe_utilization_percent",
    "stall_ratio_percent",
    "latency_us",
    "simulation_memory_model",
    "traffic_scope",
    "result_scope",
]


def main() -> None:
    rows: list[dict[str, str]] = []
    for line in LOG.read_text().splitlines():
        if not line.startswith("RTL_COUNTER,pure_rs,"):
            continue
        values = line.split(",")[1:]
        if len(values) != 20:
            raise RuntimeError(f"unexpected counter record: {line}")
        row = dict(zip(FIELDS[:20], values, strict=True))
        row.update(
            simulation_memory_model="one-cycle 128-bit line return; always-ready result sink",
            traffic_scope="accepted line payload; not physical DRAM transactions",
            result_scope="core result interface; not S2MM/DRAM write payload",
        )
        rows.append(row)

    if not rows:
        raise RuntimeError(f"no RTL_COUNTER records found in {LOG}")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {OUTPUT} ({len(rows)} layer rows)")


if __name__ == "__main__":
    main()
