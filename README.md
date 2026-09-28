# AlexNet KV260 final

This repository is the standalone AlexNet graph-integration project split
from `DO-HYUN-Y/lenet5-kv260-final` at source checkpoint
`56fb4a3947b65672aef36e09d89f29d4e25e7b66`.

The current design implements the complete AlexNet Conv1-through-FC8 graph
for the Kria KV260, including a native batch-eight path that reuses Conv/FC
weights across images.  Its physical compute array is the packed M8xN128
design (512 DSP48E2 for the systolic array plus 64 DSP48E2 for
requantization), with four PS HP ports exposed by the integrated platform.

## Verified checkpoint

- one continuous integrated-top XSim run passes all 11 Conv/Pool/FC DDR
  boundaries byte-for-byte against the C++ golden model;
- the run retires 1,635 descriptors and 4,487,914 K issues, accounts for
  714,188,480 useful MACs, and consumes 61,123,264 physical weight bytes;
- the routed KV260 image closes at 200 MHz with WNS `+0.041 ns`, WHS
  `+0.010 ns`, zero TNS/THS, no failed routes, and no DRC errors or critical
  warnings;
- implementation utilization is 89,829 LUTs (76.70%), 91,572 registers
  (39.09%), 96 BRAM tiles (66.67%), 40 URAMs (62.50%), and 576 DSP48E2s
  (46.15%).

The native batch-eight image has also passed a physical KV260 functional and
10-second sustained run at a measured 184.998151 MHz fabric clock.  It reached
22.410 images/s, 0.032010 effective TOPS, 4.049 W mean SOM power, and 0.007906
TOPS/W.  Accepted accelerator DMA payload traffic was 9,612,800 bytes/image,
84.94% below the earlier host-sequential baseline.  See
[`measurements/`](measurements/) for the exact scope, raw values, pending
measurements, and reusable result format.

## Layout

- `alexnet/rtl/`: synthesizable AlexNet RTL;
- `alexnet/tb/` and `alexnet/scripts/`: XSim and Vivado regressions;
- `alexnet/cpp/`: bit-exact C++ golden model;
- `alexnet/stages/03_kv260_m8n126_graph/`: final KV260 integration flow;
- `docs/`: architecture plan and development roadmap;
- `rtl/axi_dma_simple_master.sv`: shared AXI DMA master used by the integrated
  top;
- `release/`: the timing-clean bitstream and fixed hardware handoff.
- `measurements/`: board-measurement checklist, result index, and machine-
  readable records.

See [`alexnet/RTL_STATUS.md`](alexnet/RTL_STATUS.md) for the full verification
record and
[`alexnet/stages/03_kv260_m8n126_graph/README.md`](alexnet/stages/03_kv260_m8n126_graph/README.md)
for the final build flow.

## Rebuild and core checks

Run commands from the repository root:

```sh
cmake -S alexnet/cpp -B alexnet/cpp/build-release -DCMAKE_BUILD_TYPE=Release
cmake --build alexnet/cpp/build-release --parallel
ctest --test-dir alexnet/cpp/build-release --output-on-failure

vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m8n126_graph_top_trained_full_graph.tcl \
  -notrace

vivado -mode batch \
  -source alexnet/stages/03_kv260_m8n126_graph/scripts/build_kv260_m8n126_graph.tcl \
  -notrace
```

The trained full-graph regression additionally requires the generated,
git-ignored `alexnet_output/int8_mlcommons500_board/` model image described in
`alexnet/cpp/README.md`.
