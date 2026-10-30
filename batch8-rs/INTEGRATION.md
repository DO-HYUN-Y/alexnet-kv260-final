# Pure RS integration boundary

## Implemented

1. `alexnet_eyeriss_rs_3cluster_core.sv` provides three 12x14 clusters and
   504 DSP MAC PEs.
2. `alexnet_eyeriss_rs_gin.sv` implements the configurable two-level global
   input network used for horizontal filter and diagonal ifmap multicast.
3. `alexnet_eyeriss_rs_local_psum_network.sv` moves psum tokens vertically,
   one neighboring PE row per cycle.
4. `alexnet_eyeriss_rs_batch8_pass_scheduler.sv` enumerates all 1,185 AlexNet
   processing passes.
5. `alexnet_eyeriss_rs_batch8_pass_executor.sv` programs the GIN, requests one
   filter load, and launches eight image phases per pass.
6. `alexnet_eyeriss_rs_glb.sv` and `alexnet_eyeriss_filter_prefetch.sv` provide
   the banked GLB and overlapped filter-prefetch primitives.
7. `alexnet_eyeriss_rs_batch8_control.sv` connects the complete 1,185-pass
   scheduler to the executor and caches the five distinct GIN mappings.
8. `alexnet_eyeriss_rs_filter_load_sequencer.sv` generates filter RF writes
   for every AlexNet `p/q/r/t` mapping and zero-fills partial groups.
9. `alexnet_eyeriss_rs_image_op_sequencer.sv` generates diagonal ifmap loads,
   PE operation masks, addresses, and local-psum reductions, including Conv2
   folding and `R=S=1` FC passes.
10. `alexnet_eyeriss_rs_batch8_command_top.sv` and
    `alexnet_eyeriss_rs_batch8_core_top.sv` connect the full command plane to
    all 504 PEs through registered command buffers.

## Required before a board build

1. Make the data mover service each filter phase and image phase.
2. Connect the 128 KiB GLB and three filter-prefetch blocks to the existing AXI
   DMA boundary.
3. Connect reduced INT32 results to requantization, activation, pooling, and
   output addressing.
4. Run full-graph byte-exact simulation for batch eight.
5. Integrate into the KV260 top, implement/place/route at 185 MHz, generate a
   new bitstream, and read hardware traffic/latency counters on the board.

Do not reuse the previous M8xN128 graph top as the compute engine.  Its DMA
and postprocess blocks can be adapted around the new RS boundary, but its
systolic array, line buffer, strip cache, and feeder are not part of pure RS.

The current integrated synthesis checkpoint covers the scheduler, command
sequencers, registered handoff buffers, and the three-cluster core.  It meets
185 MHz with +0.200 ns WNS, but it does not yet cover the AXI/GLB/postprocess
board shell and is not a routed full-design or board result.
