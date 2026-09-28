# KV260 native batch-8 result at 185 MHz

## Scope

- Board: Kria KV260
- Fabric clock reported by the driver: 184,998,151 Hz
- Workload: complete INT8 AlexNet, 714,188,480 useful MAC/image
- Mode: one native PL batch of eight images with Conv/FC weight reuse
- Timed region: preprocessed inference only; model load and JSON output excluded
- Input: one saved image repeated into all eight slots
- Sustained interval: 10.352424 s, 29 batches, 232 images

The repeated image produced ImageNet class 104 (`wallaby`) in every slot.  This
is a functional smoke result, not an ImageNet accuracy result or a proof of
batch-slot independence.

## Measured result

| Metric | Value |
| --- | ---: |
| Throughput | 22.410211 images/s |
| Mean batch latency | 356.973198 ms |
| Mean per-image equivalent latency | 44.621650 ms |
| Effective performance | 0.032010 TOPS |
| Theoretical M8xN128 peak at measured clock | 0.378876 TOPS |
| End-to-end PE utilization | 8.448730% |
| Arithmetic slot utilization | 54.478298% |
| Issue duty inside active payload | 85.111692% |
| Issue duty over total pipeline time | 15.793514% |
| Mean SOM power (`ina260_u14`) | 4.048932 W |
| Effective efficiency | 0.007906 TOPS/W |
| Energy per image | 0.180674 J |

## DDR traffic

The hardware counters below count accepted accelerator AXI-stream payload
bytes.  The APM values are a separate PS DDR-port observation; neither is a
physical DRAM command count.

| Payload component | Bytes/batch | Bytes/image |
| --- | ---: | ---: |
| Main/activation reads | 11,119,104 | 1,389,888 |
| Weight/parameter reads | 61,123,264 | 7,640,408 |
| Total reads | 72,242,368 | 9,030,296 |
| Total writes | 4,660,032 | 582,504 |
| Read + write | 76,902,400 | 9,612,800 |

The one-batch APM run measured 72,302,011 idle-subtracted read bytes and
6,148,994 idle-subtracted write bytes.  The display/CPU background makes this
a noisier value than the dedicated payload counters, so both are retained.

Relative to the 2026-09-22 host-sequential 200 MHz baseline:

- throughput increased 5.9086x;
- accelerator payload bytes/image fell 84.9381%;
- weight/parameter bytes/image fell 87.7275%;
- effective TOPS/W increased 6.3125x.

The clock differs between the two runs and power was not collected as a
controlled same-session A/B test.  The traffic reduction is the direct batch
reuse result; the power comparison should be repeated under controlled
conditions.

## Layer profile

The layer profile is a single sampled batch.  Effective utilization is
derived as `2 * layer MACs * 8 / layer_seconds / 0.378876213248 TOPS`.

| Layer | Batch latency (ms) | Effective PE utilization |
| --- | ---: | ---: |
| Conv1 | 11.636 | 25.505% |
| Conv2 | 71.374 | 13.251% |
| Conv3 | 48.061 | 9.854% |
| Conv4 | 70.934 | 8.902% |
| Conv5 | 48.443 | 8.690% |
| FC6 | 64.451 | 2.473% |
| FC7 | 28.635 | 2.474% |
| FC8 | 10.728 | 1.612% |

Conv2-5 patch production and FC6-8 scheduling are the largest compute-array
utilization bottlenecks.  Repeat this profile with hardware per-layer cycle
counters before using it as a final sign-off value.

## Artifact identity

- FPGA-manager bitstream SHA-256:
  `344d5afa958cb8ae782e249b07e3dcb1258489398da7a8fe144f4b9801d82d0d`
- DTBO SHA-256:
  `e53568a30b17818119ff441d4ce1c8cafebbf1b9458b1dfa2669bc66f4ef64d5`
- Deployment archive SHA-256:
  `0c0874f503167b5a31271dab9a9353f3978f1a6e5c4c61ad71720d4cd7734a22`
- Source base before measurement-record commit:
  `2d2003eafda32856fbf9cc3dfbf9e7004c43414f`

The complete machine-readable counters are in the adjacent JSON file.  The
remaining required measurements are tracked in
[`../MEASUREMENT_CHECKLIST.md`](../MEASUREMENT_CHECKLIST.md).
