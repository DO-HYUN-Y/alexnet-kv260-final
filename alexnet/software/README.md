# KV260 AlexNet Linux runtime

This directory contains the board-runtime boundary for the routed 185 MHz
M8xN126 full-graph bitstream. It is designed for polling bring-up first; IRQ-driven
operation can follow after one saved image completes correctly.

## What is implemented

- `driver/alexnet_board.c` maps the accelerator, main AXI DMA, and camera AXI
  DMA registers, verifies the stock PS PL0 input is near 100 MHz and checks the
fixed 184,998,151 Hz MMCM fabric-clock metadata, allocates one page-rounded
  coherent DMA region for the 68,768,000-byte native-batch layout below 4 GiB,
  and exposes bounded register
  ioctls plus buffer `mmap` through `/dev/alexnet_board`.
- `runtime/alexnet_camera_demo.py` verifies and loads the generated model,
  performs the frozen resize/center-crop/RGB-normalize/INT8 packing, starts the
  graph, waits for FC8, and prints ImageNet top-k plus measured AXI-stream
  DMA payload read/write bytes and bandwidth. It submits one native eight-image
  PL job and reuses FC weights across the eight image lanes. Dog indices print
  in the requested form, for example
  `결과: 강아지 (golden retriever)`.
- `../BATCH8_DESIGN.md` records the native weight-reusing batch-8 hardware
  work and its measurable FC-weight traffic target.
- `overlay/alexnet_kv260.dts` describes the three fixed PS register windows.
- `scripts/package_firmware.sh` converts the routed `.bit` for FPGA manager and
  compiles the overlay.

This software has passed its host-side contract tests.
The deployed M4 frame-cache firmware passed coherent DMA/CSR inspection,
saved-image inference, and 15 consecutive live USB-camera classifications at
502.227 ms mean PL round-trip latency. The prior M8xN126 batch-one graph
firmware also completed physical-board inference. The native-batch-8 build uses
accelerator ID `0x4D388500`; older firmware is intentionally rejected.

## Coherent DDR layout

| Region | Offset | Allocated bytes |
| --- | ---: | ---: |
| eight preprocessed inputs | 0 | 3,211,264 |
| activation A | 3,211,264 | 2,129,920 |
| activation B | 5,341,184 | 2,129,920 |
| packed weights | 7,471,104 | 61,123,264 |
| quantization parameters | 68,594,432 | 165,504 |
| eight FC8 outputs | 68,759,936 | 8,064 (8,000 valid) |

Every region base is 128-byte aligned. Each activation region contains eight
262,144-byte image slots followed by one 32,768-byte compact FC batch tensor.
The listed regions use 68,768,000 bytes; the kernel allocation is page-rounded.

The allocation is intentionally kernel-owned. Stock generic DMA-BUF mappings
do not provide a portable physical/bus address that this 32-bit simple-mode
AXI DMA can consume. Ensure the board boot arguments reserve at least 128 MiB
of CMA (for example `cma=128M`) before loading the module.

## Host-side checks

Generate and verify the model images, then run the software contract tests:

```sh
python -m alexnet.export_board_weights
python -m alexnet.verify_board_weights
python -m unittest alexnet.software.runtime.test_runtime
```

Package the FPGA-manager files. The default input is the timing-clean
`release/alexnet_m8n126_graph_kv260_ddr_counters.bit`; the previous release
image remains untouched. When Xilinx tools are not on `PATH`, pass their
locations explicitly. Set `ALEXNET_BITSTREAM` only to package a different
validated build:

```sh
BOOTGEN=/path/to/Vivado/bin/bootgen \
DTC=/path/to/Vivado/bin/dtc \
alexnet/software/scripts/package_firmware.sh
```

## Board-side order

After copying this repository and the generated board model directory to the
KV260, copy the files from `release/` into the firmware directory under the
names expected by the installer. Build the module for the running board kernel,
then load the FPGA and probe the driver:

```sh
cd /home/ubuntu/alexnet_kv260
mkdir -p alexnet/software/build/firmware
cp release/alexnet_m8n126_graph_kv260_ddr_counters.bit.bin \
  alexnet/software/build/firmware/alexnet_m8n126_graph_kv260.bit.bin
cp release/alexnet_m8n126_graph_kv260_ddr_counters.dtbo \
  alexnet/software/build/firmware/alexnet_m8n126_graph_kv260.dtbo
make -C alexnet/software/driver
sudo alexnet/software/scripts/install_board.sh --load-and-probe
```

The installer verifies the exact timing-clean firmware hashes before changing
the FPGA, unloads the stock starter-kit overlay, loads the AlexNet full
bitstream/overlay, probes the driver, and creates `/dev/alexnet_board`. Use
`--load-only` and `--probe-only` when debugging those two stages separately.

Probe must report PL0 input near 100 MHz and fabric metadata 184,998,151 Hz.
The accelerator, DMAs, and AXI interconnect run from the internal MMCM fabric
clock, not directly from PL0. Before opening a camera, verify the board ID,
M8xN126/185 build word, clock, and status:

```sh
python3 -m alexnet.software.runtime.alexnet_camera_demo --inspect
```

Install `python3-opencv` and `python3-numpy` if they are absent. First classify
one saved image repeated across the fixed native batch:

```sh
python3 -m alexnet.software.runtime.alexnet_camera_demo \
  --board-dir alexnet_output/int8_mlcommons500_board \
  --image test.jpg
```

Only after that passes, start a V4L2 USB camera:

```sh
python3 -m alexnet.software.runtime.alexnet_camera_demo \
  --board-dir alexnet_output/int8_mlcommons500_board --camera 0 \
  --batch-size 8 --report-jsonl batch8_measurements.jsonl
```

The runtime uses polling and submits all eight frames in one native graph job.
The M8xN126 graph top sinks the optional camera stream while HP0 supplies the
actual Conv1 raster, so the runtime no longer launches the redundant camera
DMA. `CAMERA_READ_BYTES` should therefore remain zero for new inferences.
The counters measure accepted DMA stream payload bytes, not physical DDR bus
transactions including burst overhead.
`Ctrl+C` stops the live loop. OpenCV bilinear resize is used on the PS; its
final board accuracy must be measured because pixel interpolation can differ
slightly from torchvision.

For a sustained 60-second native batch-8 benchmark with DMA payload
bytes, throughput, effective TOPS, and optional INA260 SOM power, preprocess
eight frames once and keep inference inside the timed loop:

```sh
python3 -m alexnet.software.runtime.measure_batch8 \
  --image /home/ubuntu/alexnet_kv260/dog.jpg --active-seconds 60 \
  --output batch8_measurement.json
```

Omit `--image` to capture eight camera frames before timing. This measures
preprocessed inference throughput; frame acquisition and model loading are not
included. FC6-FC8 weights are reused across all eight images in the PL.
