# M8xN126 native full-graph batch-8 implementation

The graph now executes each Conv N tile across all eight input slots before
advancing to the next N tile, then executes FC6-FC8 once with M=8. Conv and FC
weight tiles are therefore loaded once and reused by all eight image lanes.
The result coalescer writes FC tensors in
`[N8 tile][batch image][8 lanes]` order, and the runtime deinterleaves the final
8,000-byte logits tensor into eight 1,000-byte results.

## Why FC-layer reuse is the first hardware target

The frozen board model contains 61,123,264 bytes of packed weights. FC6,
FC7, and FC8 account for 58,654,720 bytes (95.96%); the five convolution
layers account for 2,468,544 bytes. Keeping each FC N16/K tile resident while
executing eight M lanes would ideally read the FC weights once per eight
images, instead of eight times. That would avoid 410,583,040 FC-weight bytes
per eight-image batch, or 51,322,880 bytes per image. These were the
design-time traffic targets. The physical-board result below now confirms the
reduction, including activation/result traffic and DMA alignment.

## Implemented hardware changes

1. Eight image input slots and independently addressable intermediate
   activation tensors; preserve the existing N8-tile-major layout within each
   image. Add a batch/image index to Conv1 raster requests, activation cache
   tags, pooling, and result address mapping.
2. Conv1-Pool5 executes for all eight inputs and retains eight Pool5 outputs.
3. FC6-FC8 schedules M=8 for each N16/K tile. Each weight tile is filled once,
   issue eight activation lanes through the same resident tile, and release
   only after all eight outputs retire. Preserve the FC6 three-chunk INT32
   partial sums separately for all eight M lanes.
4. FC6/7 intermediate results use compact batch tensors; FC8 emits one
   coalesced 8,000-byte result. Parameter records are loaded once into an
   on-chip blob cache and result slices are combined into one DMA command per
   N tile.
5. The FC batch activation block closes 200 MHz standalone timing at
   WNS +0.995 ns using four URAM and no DSP. Full native-batch top synthesis
   after the Conv reuse and banked-gather changes uses 576 DSP, 54 URAM and
   120.5 BRAM tiles out of context. The deployable full system closes at the
   selected 185 MHz target with post-route WNS/WHS +0.015/+0.010 ns and has
   passed the physical-board run described below.
6. Conv2-5 and FC6-8 activation gathering use independent 64-bit banks so all
   active M lanes are fetched in parallel. The graph engine also prefetches
   the next weight/patch descriptor into the inactive ping-pong set while the
   current descriptor computes.
7. Whole-inference cycle counters separate engine, weight, patch, pool,
   result, raster, DMA, overlap and idle time so board results identify the
   remaining bottleneck instead of inferring it from TOPS alone.

## Expected batch traffic

The analytical AXI-stream payload expectation after Conv and FC weight reuse
is 72,407,872 read bytes and 4,660,032 write bytes per eight-image batch, or
9,633,488 total bytes/image. Compared with the measured host-sequential
baseline of 63,821,864 bytes/image, this is an expected 84.91% payload
reduction. Conv N-tile ordering adds 3,255,808 activation-read bytes per batch
but avoids 17,279,808 Conv-weight bytes, a net 14,024,000-byte (15.40%)
improvement over the previous native-batch estimate. Conv/FC weights plus
parameters now contribute 7,661,096 bytes/image.

The batch-1 timing-clean, byte-counted firmware is the comparison point. The
native path is integrated; its unit, numerical Conv1, synthesis, standalone
timing, full-system route, and physical-board functional checks pass.

## Measured native batch 8 (KV260, 2026-09-28)

The 184.998151 MHz board run completed 29 native batches (232 images) in
10.352424 s: 22.410211 images/s, 0.032010 effective TOPS, 356.973 ms mean
batch latency, and 44.622 ms per-image equivalent latency. Mean SOM input
power was 4.048932 W, giving 0.007906 effective TOPS/W.

Measured accepted AXI-stream DMA payload was 76,902,400 bytes/batch, or
9,612,800 bytes/image. This is 20,688 bytes/image below the analytical target
and 84.938% below the 63,821,864-byte host-sequential baseline. The separate
PS DDR APM run measured 72,302,011 read and 6,148,994 write bytes after idle
subtraction for one batch. See `../measurements/` for the complete counters,
layer profile, measurement limitations, and remaining sign-off list.

## Measured host-sequential baseline (KV260, 2026-09-22)

The DDR-counter build completed 29 eight-image host batches (232 jobs) in
61.168421 s: 3.792807 images/s, 0.005418 effective TOPS, and 263.482 ms mean
single-image PL round trip. Measured AXI-stream DMA payload was 63,821,864
bytes/image, including 62,256,448 bytes on the shared weight/parameter read
channel and zero bytes on the redundant camera channel. The parameter loader
rereads 1,133,184 parameter bytes/image across result tiles, which explains
the 967,680-byte excess over the previous once-per-blob DDR estimate. These
measurements are the baseline for the native batch-8 result above.
