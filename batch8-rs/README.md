# AlexNet pure Eyeriss row-stationary accelerator

This directory is self-contained for RTL simulation and is designed to live
inside the `alexnet-kv260-final` repository for KV260 board builds.  It uses no
machine-specific absolute paths.  A board build reuses the parent repository's
AlexNet board shell; set `ALEXNET_REPO_ROOT` only when this directory is stored
somewhere else.

## Quick start on another computer

Requirements are Python 3, Verilator, and Vivado 2024.1 for FPGA builds.

```sh
git clone https://github.com/DO-HYUN-Y/alexnet-kv260-final.git
cd alexnet-kv260-final/batch8-rs
python3 -m unittest -v test_eyeriss_rs_batch8_mapping.py
bash measurements/paper_comparison/run_rtl_profiles.sh
bash run_verification.sh
```

Run the simulation-only full-graph counters with:

```sh
bash measurements/paper_comparison/run_full_graph_counter_sim.sh
```

The counter simulation uses a one-cycle 128-bit line-return model and an
always-ready result sink.  Its byte counts are accepted payload, not physical
DRAM transactions.  To build the KV260 design from the repository root:

```sh
cd batch8-rs
vivado -mode batch -source scripts/build_kv260_eyeriss_rs.tcl \
  -nolog -nojournal
```

This project now contains a paper-shaped Eyeriss row-stationary compute core,
adapted to the KV260 and native batch eight.  It no longer uses the earlier
M8xN128 systolic array, centralized convolution line buffer, strip cache, or
activation feeder as the RS implementation.

## Architecture

- Three independent `12 x 14` clusters: 504 MAC PEs.
- Filters multicast horizontally, ifmaps multicast diagonally, and partial
  sums move vertically through neighboring PE rows.
- Logical PE storage: 224-byte filter RF, 12-byte ifmap window, and 24 INT32
  psums.
- Every PE retains independent logical filter contents.  Nine 224-byte PE
  filter RFs are packed into one 72-bit vector BRAM bank, so simultaneous
  `r x t` PE sets can hold distinct filters without a centralized feature-map
  line buffer.  Ifmap windows and psums remain PE-local.
- 128 KiB, 32-bank GLB model plus two-bank 8 KiB filter prefetch per cluster.
- Batch eight is native: every processing pass loads its filters once, then
  executes images 0 through 7 before releasing them.
- AlexNet mapping uses the Eyeriss `p/q/r/t` organization.  Conv2's `5 x 27`
  PE set is folded into `5 x 14 + 5 x 13` inside a cluster.

The FC layers use the `R=S=1` degenerate form of RS.  There is no convolution
line buffer in this design.

## Verified results

The 27-group SystemVerilog suite plus five mapping-model tests verify the PE
primitive, PE-set routing, configurable GIN, vertical local psum network, GLB,
filter prefetch, all 1,185
AlexNet processing passes, the batch-eight pass executor, the
filter/ifmap/operation sequencers, board address generation, 128-bit line
caches, 16-byte DMA readers, concurrent main/weight DMA operation,
channel-inner pass ordering, the 49-URAM channel accumulator, the integrated
board-memory frontend plus three-cluster core, and the signed-INT8 N8 result
reorder/S2MM path.  The result-store tests cover both Conv1 strip ordering and
the FC 756-channel tile boundary, including the four-byte carry into the next
tile.  The batch-eight in-place pooling test checks every Conv1, Conv2, and
Conv5 output value across all eight images: 512 N8 tiles and 88,320 pooled N8
words.

The current integrated DMA-frontend-plus-accumulator-plus-core-plus-postprocess-
plus-result-store-plus-pooling
out-of-context synthesis on
`xck26-sfvc784-2LV-c` at 185 MHz reports:

| Metric | Pure RS through N8 store and pooling | K26 capacity | Use |
|---|---:|---:|---:|
| LUT | 82,269 | 117,120 | 70.24% |
| FF | 37,137 | 234,240 | 15.85% |
| DSP48E2 | 518 | 1,248 | 41.51% |
| BRAM tile / URAM | 108 / 55 | 144 / 64 | 75.00% / 85.94% |
| 185 MHz setup slack | +0.203 ns | — | pass, 0 failing endpoints |

Of the 108 BRAM tiles, 84 implement the independent PE filter RF packing, 16
implement eight result-reorder banks, and 8 buffer one raw N8 pooling tile.
The integrated boundary includes coordinate-to-DDR address
translation, two 128-bit one-line read caches, two 16-byte DMA readers, and a
28,672-slot channel-pass accumulator.  Filter lines map to the existing weight
MM2S contract and ifmap lines map to main MM2S.  The scheduler holds a filter
tile while walking channel groups; 49 URAMs retain partial results.  Six more
URAMs cache all 10,344 frozen channel-parameter records after one 165,504-byte
weight-DMA preload.  Fourteen DSPs apply bias, requantization, and ReLU to each
final vector.  The result store then converts the 14-column RS stream into the
physical N8 `[N/8][y][x][8]` layout and emits main-DMA S2MM commands and data.
At Conv1, Conv2, and Conv5 barriers, a batch-eight in-place 3x3/stride-2
max-pool service sequentially reuses the main MM2S and S2MM channels.  This is
a postprocess tile buffer, not a convolution feature-map line buffer.  The
AXI-DMA control masters themselves and the board shell are not included.

The synthesized boundary includes the 1,185-pass scheduler/executor, five
cached GIN mappings, filter and image/operation command sequencers, and
registered filter/ifmap/operation/reduction handoff buffers.  Registered
coordinate, relative-offset, and base-address stages prevent the memory
frontend from becoming a controller timing path.  The result is still an OOC
synthesis report, not a placed-and-routed board-shell report.

For context, the previous RS-enhanced hybrid used 84,680 LUTs.  The pure RS
boundary through N8 result storage and pooling is 2,411 LUTs lower, about
2.8%, while
replacing the internal dataflow rather than adding a line buffer to the hybrid
array.  This remains a boundary-level comparison; a fair final comparison
requires the same complete board shell.

The all-one Conv1 integration test reaches the first partial output with
correct psums `81, 99 x 6`, 3,388 MACs, and 70 local psum hops.  Up to that
exact point, the filter cache observes 7,744 byte requests, 6,600 hits, and
1,144 128-bit line fetches (85.2% request hit rate).  The ifmap cache observes
297 byte requests and 297 line fetches (0 hits), identifying the current
one-line ifmap cache as the next bandwidth optimization.  These are RTL
integration counters for the first partial output, not full-network board
measurements.

## Batch-eight mapping projection

- Processing passes: 1,185.
- Useful MACs: 5,713,507,840 per batch.
- Filter DDR payload: 61,253,120 bytes per batch, or 7,656,640 bytes per image
  equivalent because one filter load is reused by eight images.
- Conservative accepted external payload: 73,941,952 bytes per batch,
  9,242,744 bytes per image equivalent.
- Implemented pool traffic: 3,014,656 read bytes plus 706,560 write bytes per
  batch, using 512 MM2S and 512 S2MM commands.
- Useful MACs per accepted external byte: 77.2702.

These are traffic-model projections, not AXI transaction counts or KV260
measurements.

## Run

```sh
bash run_verification.sh
vivado -mode batch -source scripts/synth_eyeriss_rs_3cluster_ooc.tcl \
  -nolog -nojournal
vivado -mode batch -source scripts/synth_eyeriss_rs_batch8_core_top_ooc.tcl \
  -nolog -nojournal
vivado -mode batch \
  -source scripts/synth_eyeriss_rs_batch8_board_frontend_ooc.tcl \
  -nolog -nojournal
vivado -mode batch \
  -source scripts/synth_eyeriss_rs_batch8_board_accum_ooc.tcl \
  -nolog -nojournal
vivado -mode batch \
  -source scripts/synth_eyeriss_rs_batch8_board_dma_ooc.tcl \
  -nolog -nojournal
vivado -mode batch \
  -source scripts/synth_eyeriss_rs_batch8_board_postprocess_ooc.tcl \
  -nolog -nojournal
vivado -mode batch \
  -source scripts/synth_eyeriss_rs_n8_result_store_ooc.tcl \
  -nolog -nojournal
vivado -mode batch \
  -source scripts/synth_eyeriss_rs_batch8_inplace_pool_ooc.tcl \
  -nolog -nojournal
vivado -mode batch \
  -source scripts/synth_eyeriss_rs_batch8_board_store_ooc.tcl \
  -nolog -nojournal
```

Mapping reports are under `reports/`, and the latest full-boundary synthesis
reports are under `reports/synth_eyeriss_rs_batch8_board_store/`.

## Current boundary

The pure RS core, batch-eight control plane, RF/operation sequencers, frozen
AlexNet DDR address mapping, two 128-bit line caches, main/weight MM2S DMA
bridges, on-chip channel-pass accumulation, complete parameter-blob cache, and
14-lane bias/requantization/ReLU are implemented and verified.  The N8
activation-store reorder/S2MM path is also implemented, including Conv1 strip
commands and FC non-multiple-of-eight carry merging.  Conv1/2/5 batch-eight
pooling and DMA arbitration are implemented as well.  Remaining work is
continuous Conv1-FC8 golden simulation and wiring the completed boundary into
the existing KV260 block design for route/bitstream.
The bitstream previously run on the board is still the RS-enhanced hybrid and
must not be reported as a pure-RS board measurement.
