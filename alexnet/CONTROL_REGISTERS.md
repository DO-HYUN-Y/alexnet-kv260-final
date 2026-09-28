# AlexNet accelerator AXI-Lite register map

The AlexNet accelerator tops expose one 32-bit AXI4-Lite slave at
`S_AXI_CTRL`. All offsets are byte offsets from the accelerator control base.
The interface and accelerator run in the same 200 MHz clock domain.

In the routed KV260 board top, the PS physical control map is:

| Base | Owner |
| ---: | --- |
| `0xA0000000` | this accelerator register bank |
| `0xA0010000` | main model/activation AXI DMA |
| `0xA0020000` | PS-owned camera MM2S AXI DMA |

The camera DMA reads exactly 401,408 bytes for one preprocessed `224x224`
frame. Each eight-byte DDR word contains signed INT8 model channels in bytes
0..2 and zero padding in bytes 3..7. See
`stages/01_kv260_m4n8/README.md` for its stream and interrupt ABI.

## Register map

| Offset | Name | Access | Description |
| ---: | --- | --- | --- |
| `0x00` | `ID` | RO | implementation ID; native-batch-8 M8xN126 build is `0x4D388500` |
| `0x04` | `CONTROL` | WO/W1P | bit 0 submit, bit 1 clear all sticky status, bit 2 cancel pending job |
| `0x08` | `STATUS` | RO | live and sticky state described below |
| `0x0C` | `JOB_TAG` | RW | next-job tag in bits 15:0 |
| `0x10`/`0x14` | `INPUT_LO/HI` | RW | next-job input/camera buffer base |
| `0x18`/`0x1C` | `ACT_A_LO/HI` | RW | activation ping-pong A base |
| `0x20`/`0x24` | `ACT_B_LO/HI` | RW | activation ping-pong B base |
| `0x28`/`0x2C` | `WEIGHTS_LO/HI` | RW | packed-weight blob base |
| `0x30`/`0x34` | `PARAMETERS_LO/HI` | RW | 16-byte quantization-record blob base |
| `0x38`/`0x3C` | `OUTPUT_LO/HI` | RW | final FC8 output base |
| `0x40` | `DMA_TIMEOUT` | RW | timeout cycles per physical DMA transfer; zero selects the DMA default |
| `0x44` | `PROGRESS` | RO | graph phase, layer, completion counts, and DMA source |
| `0x48` | `ERROR` | RO | graph and DMA error detail |
| `0x4C` | `ACTIVE_TAG` | RO | completed tag in 31:16, live graph tag in 15:0 |
| `0x50` | `DMA_ACCEPTED` | RO | accepted logical DMA request count |
| `0x54` | `DMA_ISSUED` | RO | commands issued to AXI DMA |
| `0x58` | `DMA_COMPLETED` | RO | completed physical DMA transfers |
| `0x5C` | `CONV_TILES` | RO | completed post-pool Conv storage tiles |
| `0x60` | `IRQ_ENABLE` | RW | bit 0 completion IRQ, bit 1 failure/fault/rejected-submit IRQ |
| `0x64` | `IRQ_STATUS` | RO/W1C | bits 0..3: done, failed, fault, rejected submit |
| `0x68` | `LAST_JOB_CYCLES` | RO | cycles recorded for the last completed or failed job |
| `0x6C` | `COMPLETED_JOBS` | RO | successful inference count since reset |
| `0x70` | `REJECTED_SUBMITS` | RO | rejected submit count since reset |
| `0x74` | `FAILED_JOBS` | RO | failed inference count since reset |
| `0x78` | `CONFIG_STATUS` | RO | bit 0 valid, bit 1 aligned, bit 2 within 32-bit DMA range, bit 8 pending |
| `0x7C` | `BUILD_CONFIG` | RO | logical M, N, and clock target; M8xN126/200 is `0x087E00C8` |
| `0x80` | `PERF_ACTIVE` | RO | engine active cycles for the current/last job |
| `0x84` | `PERF_ISSUE` | RO | physical MAC issue cycles for the current/last job |
| `0x88` | `PERF_WEIGHT_STALL` | RO | weight-stall cycles |
| `0x8C` | `PERF_ACT_STALL` | RO | activation-stall cycles |
| `0x90` | `PERF_RESULT_STALL` | RO | result-stall cycles |
| `0x94`/`0x98` | `PERF_USEFUL_MAC_LO/HI` | RO | useful MAC operations for the current/last job |
| `0x9C`/`0xA0` | `PERF_PEAK_MAC_LO/HI` | RO | occupied physical MAC slots for the current/last job |
| `0xA4` | `PERF_SIGNATURE` | RO | folded result signature |
| `0xA8` | `PERF_TILES` | RO | completed engine commands |
| `0xAC`/`0xB0` | `DDR_READ_BYTES_LO/HI` | RO | cumulative accepted DDR-read payload bytes |
| `0xB4`/`0xB8` | `DDR_WRITE_BYTES_LO/HI` | RO | cumulative accepted DDR-write payload bytes |
| `0xBC`/`0xC0` | `MAIN_READ_BYTES_LO/HI` | RO | cumulative HP0/main-MM2S bytes |
| `0xC4`/`0xC8` | `WEIGHT_READ_BYTES_LO/HI` | RO | cumulative HP3 weight/parameter bytes |
| `0xCC`/`0xD0` | `CAMERA_READ_BYTES_LO/HI` | RO | cumulative camera-MM2S bytes received by PL |
| `0xD4` | `PIPELINE_TOTAL` | RO | cumulative cycles inside accepted inference jobs |
| `0xD8` | `PIPELINE_ENGINE` | RO | cycles with the graph engine busy |
| `0xDC` | `PIPELINE_WEIGHT` | RO | weight or parameter fill-service cycles |
| `0xE0` | `PIPELINE_PATCH` | RO | activation/raster patch-service cycles |
| `0xE4` | `PIPELINE_POOL` | RO | pooling-service cycles |
| `0xE8` | `PIPELINE_RESULT` | RO | result-coalescer fill/drain cycles |
| `0xEC` | `PIPELINE_RASTER` | RO | Conv1 raster setup/load cycles |
| `0xF0` | `PIPELINE_DMA` | RO | cycles with either DMA engine busy |
| `0xF4` | `PIPELINE_OVERLAP` | RO | engine-busy cycles overlapped by weight/patch service |
| `0xF8` | `PIPELINE_IDLE` | RO | in-job cycles with no engine or data service active |

Unmapped reads and writes return AXI `SLVERR`. Byte writes are honored through
`WSTRB`.

The five byte counters increment on AXI-Stream `TVALID && TREADY` and add the
number of asserted `TKEEP` bits. They measure payload delivered across the PL
DMA boundary, including partial final beats and excluding backpressured cycles.
They reset only with the accelerator and wrap modulo 2^64. Software must take
idle before/after snapshots and subtract modulo 2^64. To avoid a torn 32-bit
rollover, read high, low, then high again and retry if the high halves differ.

## Status fields

`STATUS` uses the following bits:

- bit 0 accelerator busy;
- bit 1 one job is pending;
- bit 2 graph currently accepts a job;
- bits 3, 4, 5: sticky done, failed, and fault;
- bit 6 live graph fault;
- bits 7 and 8: DMA busy and DMA error;
- bit 9 valid Pool5 cache;
- bit 10 interrupt output level;
- bit 11 rejected-submit sticky flag;
- bit 12 shadow configuration valid.

`PROGRESS` contains graph phase in 4:0, active layer in 11:8, completed Conv
layers in 18:16, completed FC layers in 21:20, and active DMA source in 26:24.
`ERROR` contains graph fault code in 3:0 and DMA error code in 7:4.

## Submission and address rules

Software writes the shadow configuration first, then writes `CONTROL.submit`.
The hardware snapshots the entire configuration into a one-entry pending job.
Later software writes cannot alter either that pending snapshot or the active
job. A second submit while the pending slot is occupied returns `SLVERR` and
sets `rejected submit`.

All six bases must be 128-byte aligned and below 4 GiB. The RTL address planner
is internally 64-bit, but the current simple-mode AXI DMA command engine writes
32-bit buffer-address registers. Payload descriptors are 8-byte aligned, so
both AXI DMA channels must be generated with DRE enabled.

Sticky status is cleared through `IRQ_STATUS` W1C or `CONTROL.clear`. A live
accelerator fault immediately reasserts the fault bit; the current graph fault
state requires accelerator reset before another inference.
