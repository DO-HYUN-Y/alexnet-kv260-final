# KV260 measurement registry

This directory keeps measured board results separate from RTL estimates and
simulation results.

## Layout

- [`MEASUREMENT_CHECKLIST.md`](MEASUREMENT_CHECKLIST.md): values that must be
  measured before a configuration is signed off;
- [`results/index.csv`](results/index.csv): one-row-per-run comparison table;
- [`results/`](results/): human-readable summaries and complete JSON records;
- [`templates/board_result_template.json`](templates/board_result_template.json):
  copy this file when starting a new measurement campaign.

## Recording rules

1. Store raw integer byte/cycle counts in JSON; derive percentages from those
   values whenever possible.
2. Mark every value as `measured`, `derived`, `estimated`, or `pending`.
3. Do not mix model loading, image preprocessing, or file output into PL
   inference latency unless the record explicitly says `application_e2e`.
4. Keep accelerator AXI-stream payload bytes separate from PS DDR-controller
   APM bytes.  Neither one is a count of physical DRAM row operations.
5. Record the bitstream and DTBO SHA-256 hashes, actual board-reported clock,
   input source, batch semantics, warm-up count, sample duration, and power
   sensor with every result.
6. A comparison is valid only when its workload, model, quantization, timing
   scope, and power rail are compatible.  Any exception must be called out in
   the result summary.

## Current result

The newest verified entry is the 2026-09-28 native batch-eight run at
184.998151 MHz:

| Metric | Result |
| --- | ---: |
| Throughput | 22.410211 images/s |
| Mean batch latency | 356.973198 ms |
| Mean latency per image | 44.621650 ms |
| Effective performance | 0.032010 TOPS |
| End-to-end PE utilization | 8.448730% |
| Mean SOM power | 4.048932 W |
| Effective efficiency | 0.007906 TOPS/W |
| Accelerator payload traffic | 9,612,800 bytes/image |

The full record is
[`results/2026-09-28_kv260_native_batch8_185mhz.json`](results/2026-09-28_kv260_native_batch8_185mhz.json).
