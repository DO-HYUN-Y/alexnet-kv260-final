# Board measurement checklist

Use this list for every new bitstream.  `Required` entries are needed for a
performance claim; `diagnostic` entries explain bottlenecks or improve
reproducibility.

## 1. Identity and reproducibility

| Priority | Value | Unit / format | Current 185 MHz run |
| --- | --- | --- | --- |
| Required | Git commit or tagged source snapshot | commit SHA | Commit containing the result file; resolve with `git log -- <result-file>` |
| Required | Bitstream SHA-256 | hex | `344d5afa958cb8ae782e249b07e3dcb1258489398da7a8fe144f4b9801d82d0d` |
| Required | DTBO SHA-256 | hex | `e53568a30b17818119ff441d4ce1c8cafebbf1b9458b1dfa2669bc66f4ef64d5` |
| Required | Board/accelerator ID and ABI | hex / integer | ABI 2; exact ID pending capture |
| Required | Actual fabric and PL input clocks | Hz | 184,998,151 / 99,999,999 |
| Required | Model/weight manifest hash | SHA-256 | Pending |
| Diagnostic | OS, kernel, driver and tool versions | text | Pending |
| Diagnostic | Board temperature before/after | degC | Pending |

## 2. Correctness and accuracy

| Priority | Value | Minimum method | Current 185 MHz run |
| --- | --- | --- | --- |
| Required | Full-graph completion and fault registers | every measured run | Pass; no reported fault source |
| Required | Output match against INT8 golden model | byte exact or documented tolerance | Pending byte-exact comparison |
| Required | Batch-slot independence | at least eight different images | Pending; current run repeated one image |
| Required | ImageNet/MLCommons top-1 and top-5 accuracy | complete agreed validation set | Pending |
| Diagnostic | Stable output hashes | all timed samples | Pending hash capture |
| Diagnostic | Camera path | eight live frames | Pending on native batch-eight image |

## 3. Latency and throughput

| Priority | Value | Unit / statistic | Current 185 MHz run |
| --- | --- | --- | --- |
| Required | Batch size and execution semantics | text | Native PL batch 8, Conv/FC weight reuse |
| Required | Timed scope | text | Preprocessed inference only |
| Required | Warm-up and sample count | count / duration | 29 batches, 232 images, 10.352 s; explicit warm-up count pending |
| Required | Batch latency | mean, median, p95, p99 ms | Mean 356.973 ms; distribution pending |
| Required | Per-image equivalent latency | ms | Mean 44.622 ms |
| Required | Sustained throughput | images/s | 22.410211 |
| Required | Effective TOPS | 2 x useful MAC/s | 0.032010 |
| Diagnostic | Host submission and completion overhead | ms | Pending |
| Diagnostic | Frequency sweep | 100/150/175/185/200 MHz | Only 185 MHz measured |

## 4. PE and pipeline utilization

| Priority | Value | Unit / statistic | Current 185 MHz run |
| --- | --- | --- | --- |
| Required | Theoretical array peak | TOPS | 0.378876 |
| Required | End-to-end PE utilization | useful TOPS / peak | 8.448730% |
| Required | Useful MAC and physical slot counts | integer per batch | 5,713,507,840 / 10,487,676,928 |
| Required | Arithmetic slot utilization | useful / physical slots | 54.478298% |
| Required | Active and issue cycles | cycles per batch | 12,033,449 / 10,241,872 |
| Required | Issue duty within payload | issue / active | 85.111692% |
| Required | Issue duty end-to-end | issue / total pipeline | 15.793514% |
| Required | Weight/activation/result stalls | cycles and % | 512 / 0 / 0 cycles |
| Required | Per-layer latency and effective utilization | ms and % | Captured once; repeat and collect percentiles |
| Diagnostic | Patch, pool, result, raster and DMA stage cycles | cycles/share | Captured in latest JSON |
| Diagnostic | Stage overlap and idle cycles | cycles/share | 61,689,178 overlap; 112 idle |

## 5. DDR and DMA traffic

| Priority | Value | Unit / statistic | Current 185 MHz run |
| --- | --- | --- | --- |
| Required | Accelerator payload read/write | bytes/image and bytes/batch | 72,242,368 / 4,660,032 bytes per batch |
| Required | Main/weight/camera read split | bytes/image | 1,389,888 / 7,640,408 / 0 |
| Required | Total accelerator payload | bytes/image | 9,612,800 |
| Required | Payload bandwidth | MB/s | 215.424880 |
| Required | PS APM active and idle-subtracted bytes | port and total | Captured for one batch |
| Required | DDR reduction versus named baseline | percent | 84.938077% vs 200 MHz host-sequential baseline |
| Diagnostic | AXI burst length, outstanding depth and stalls | distribution/cycles | Pending |
| Diagnostic | Physical DRAM utilization/commands | controller-specific | Not available from current counters |

## 6. Power and efficiency

| Priority | Value | Unit / statistic | Current 185 MHz run |
| --- | --- | --- | --- |
| Required | Sensor and rail | text | `ina260_u14`, SOM input |
| Required | Idle power | mean W | Pending controlled measurement |
| Required | Active power | mean/median/p95 W | Mean 4.048932 W; distribution pending |
| Required | Sample interval and count | seconds / count | 0.1 s / 103 samples |
| Required | TOPS/W | effective TOPS / active W | 0.007906 |
| Required | Energy per image | joules | 0.180674 J (derived) |
| Diagnostic | Dynamic power | active minus idle W | Pending |
| Diagnostic | Rail-separated PL/PS/DDR power | W | Pending if sensors permit |

## 7. Baselines and robustness

| Priority | Value | Minimum method | Current status |
| --- | --- | --- | --- |
| Required | Previous FPGA image A/B | same input and measurement scope | Host-sequential 200 MHz baseline recorded |
| Required | Board CPU-only baseline | same INT8 model; optimized and reference noted separately | Pending |
| Required | Long-run stability | >= 1 hour; jobs/errors/temp | Pending |
| Required | Reboot/reload repeatability | >= 3 cold or clean reloads | Pending |
| Diagnostic | Batch sweep | 1/2/4/8 | Batch 8 only on native path |
| Diagnostic | Input diversity | saved set plus camera | Pending |
