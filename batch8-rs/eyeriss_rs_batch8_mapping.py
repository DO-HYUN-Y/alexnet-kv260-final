#!/usr/bin/env python3
"""Pure Eyeriss row-stationary mapping for AlexNet, adapted to batch eight.

The external tensor layout remains compatible with the KV260 AlexNet graph,
but the compute fabric is three independent 12x14 PE clusters.  Each PE owns
filter, ifmap, and psum scratchpads.  There is no centralized convolution
line buffer; a PE retains only an S-wide sliding ifmap window.

This is a design-time mapping and traffic model, not a board measurement.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path
import argparse
import csv
import json
import math


BATCH = 8
CLUSTERS = 3
PE_ROWS = 12
PE_COLS = 14
PE_PER_CLUSTER = PE_ROWS * PE_COLS
TOTAL_MAC_PES = CLUSTERS * PE_PER_CLUSTER
POSTPROCESS_DSPS = 64
TOTAL_DSP_BUDGET = 576
FILTER_SPAD_ENTRIES = 224
IFMAP_SPAD_ENTRIES = 12
PSUM_SPAD_ENTRIES = 24
GLB_BYTES = 128 * 1024
FILTER_PREFETCH_BYTES_PER_CLUSTER = 8 * 1024
USEFUL_MACS_PER_IMAGE = 714_188_480


@dataclass(frozen=True)
class Layer:
    layer_id: int
    name: str
    kind: str
    input_h: int
    input_w: int
    filter_r: int
    filter_s: int
    stride: int
    pad: int
    channels: int
    filters: int
    output_h: int
    output_w: int
    input_bytes: int
    output_bytes: int
    current_write_bytes: int
    pool_read_bytes: int

    @property
    def weights(self) -> int:
        return self.filter_r * self.filter_s * self.channels * self.filters

    @property
    def parameter_bytes(self) -> int:
        return math.ceil(self.filters / 8) * 128


@dataclass(frozen=True)
class Mapping:
    m: int
    n: int
    e: int
    p: int
    q: int
    r: int
    t: int
    provenance: str


LAYERS = (
    Layer(1, "conv1", "conv", 224, 224, 11, 11, 4, 2, 3, 64, 55, 55,
          401_408, 193_600, 240_256, 193_600),
    Layer(2, "conv2", "conv", 27, 27, 5, 5, 1, 2, 64, 192, 27, 27,
          46_656, 139_968, 172_416, 139_968),
    Layer(3, "conv3", "conv", 13, 13, 3, 3, 1, 1, 192, 384, 13, 13,
          32_448, 64_896, 64_896, 0),
    Layer(4, "conv4", "conv", 13, 13, 3, 3, 1, 1, 384, 256, 13, 13,
          64_896, 43_264, 43_264, 0),
    Layer(5, "conv5", "conv", 13, 13, 3, 3, 1, 1, 256, 256, 13, 13,
          43_264, 43_264, 52_480, 43_264),
    Layer(6, "fc6", "fc", 1, 1, 1, 1, 1, 0, 9_216, 4_096, 1, 1,
          9_216, 4_096, 4_096, 0),
    Layer(7, "fc7", "fc", 1, 1, 1, 1, 1, 0, 4_096, 4_096, 1, 1,
          4_096, 4_096, 4_096, 0),
    Layer(8, "fc8", "fc", 1, 1, 1, 1, 1, 0, 4_096, 1_000, 1, 1,
          4_096, 1_000, 1_000, 0),
)


# Convolution mappings follow Table III's p/q/r/t organization.  n is eight
# because filters remain resident while the eight images stream sequentially.
MAPPINGS = {
    "conv1": Mapping(64, BATCH, 7, 16, 1, 1, 2,
                     "Eyeriss Table III; batch streamed as N=8"),
    "conv2": Mapping(32, BATCH, 27, 16, 2, 1, 1,
                     "Eyeriss Table III; INT32 psum allocation"),
    "conv3": Mapping(64, BATCH, 13, 16, 4, 1, 4,
                     "Eyeriss Table III; batch streamed as N=8"),
    "conv4": Mapping(64, BATCH, 13, 16, 3, 2, 2,
                     "Eyeriss Table III; batch streamed as N=8"),
    "conv5": Mapping(64, BATCH, 13, 16, 3, 2, 2,
                     "Eyeriss Table III; batch streamed as N=8"),
    "fc6": Mapping(756, BATCH, 1, 18, 12, 12, 14,
                   "R=S=1 RS-degenerate extension"),
    "fc7": Mapping(756, BATCH, 1, 18, 12, 12, 14,
                   "R=S=1 RS-degenerate extension"),
    "fc8": Mapping(756, BATCH, 1, 18, 12, 12, 14,
                   "R=S=1 RS-degenerate extension"),
}


def ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b


def mapping_record(layer: Layer) -> dict:
    mapping = MAPPINGS[layer.name]
    mapped_pes = (layer.filter_r * mapping.e * mapping.r * mapping.t
                  if layer.kind == "conv" else PE_PER_CLUSTER)
    if mapped_pes > PE_PER_CLUSTER:
        raise ValueError(f"{layer.name}: {mapped_pes} PEs exceed one cluster")
    if mapping.p * mapping.q * layer.filter_s > FILTER_SPAD_ENTRIES:
        raise ValueError(f"{layer.name}: filter SPad capacity exceeded")
    if mapping.q * layer.filter_s > IFMAP_SPAD_ENTRIES:
        raise ValueError(f"{layer.name}: ifmap SPad capacity exceeded")
    if mapping.p > PSUM_SPAD_ENTRIES:
        raise ValueError(f"{layer.name}: psum SPad capacity exceeded")

    vertical_strips = ceil_div(layer.output_h, mapping.e)
    channels_per_pass = mapping.q * mapping.r
    filters_per_pass = mapping.p * mapping.t * CLUSTERS
    channel_groups = ceil_div(layer.channels, channels_per_pass)
    filter_groups = ceil_div(layer.filters, filters_per_pass)

    # Only one image's working set occupies the GLB at a time.  The next image
    # streams after the previous one while PE filter SPads remain unchanged.
    padded_w = layer.input_w + 2 * layer.pad
    input_rows = min(layer.input_h + 2 * layer.pad,
                     (mapping.e - 1) * layer.stride + layer.filter_r)
    ifmap_glb = input_rows * padded_w * channels_per_pass
    psum_glb = mapping.m * min(mapping.e, layer.output_h) * layer.output_w * 4
    glb_total = ifmap_glb + psum_glb
    if glb_total > GLB_BYTES:
        raise ValueError(f"{layer.name}: GLB allocation {glb_total} exceeds {GLB_BYTES}")

    return {
        "mapping": asdict(mapping),
        "mapped_pes_per_cluster": mapped_pes,
        "active_pe_fraction": mapped_pes / PE_PER_CLUSTER,
        "vertical_strips": vertical_strips,
        "channels_per_pass": channels_per_pass,
        "filters_per_pass_all_clusters": filters_per_pass,
        "channel_groups": channel_groups,
        "filter_groups": filter_groups,
        "processing_passes": vertical_strips * channel_groups * filter_groups,
        "ifmap_glb_bytes": ifmap_glb,
        "psum_glb_bytes": psum_glb,
        "glb_total_bytes": glb_total,
    }


def iter_passes():
    ordinal = 0
    for layer in LAYERS:
        mapping = MAPPINGS[layer.name]
        rec = mapping_record(layer)
        for strip_y in range(0, layer.output_h, mapping.e):
            strip_rows = min(mapping.e, layer.output_h - strip_y)
            for filter_base in range(0, layer.filters,
                                     rec["filters_per_pass_all_clusters"]):
                filter_count = min(rec["filters_per_pass_all_clusters"],
                                   layer.filters - filter_base)
                for channel_base in range(0, layer.channels,
                                          rec["channels_per_pass"]):
                    channel_count = min(rec["channels_per_pass"],
                                        layer.channels - channel_base)
                    ordinal += 1
                    yield {
                        "ordinal": ordinal,
                        "layer_id": layer.layer_id,
                        "name": layer.name,
                        "batch_count": BATCH,
                        "strip_y": strip_y,
                        "strip_rows": strip_rows,
                        "channel_base": channel_base,
                        "channel_count": channel_count,
                        "filter_base": filter_base,
                        "filter_count": filter_count,
                        "output_width": layer.output_w,
                        "filter_r": layer.filter_r,
                        "filter_s": layer.filter_s,
                        "p": mapping.p,
                        "q": mapping.q,
                        "r": mapping.r,
                        "t": mapping.t,
                        "load_ifmap": 1,
                        "load_filter": 1,
                        "keep_filter_for_batch": 1,
                        "psum_first": int(channel_base == 0),
                        "psum_final": int(channel_base + channel_count == layer.channels),
                        "useful_macs": (BATCH * strip_rows * layer.output_w *
                                        channel_count * filter_count *
                                        layer.filter_r * layer.filter_s),
                        "weight_dram_bytes": (channel_count * filter_count *
                                              layer.filter_r * layer.filter_s),
                    }


def validate_pass_partition() -> None:
    passes = list(iter_passes())
    if len(passes) != 1_185:
        raise ValueError(f"pass count mismatch: {len(passes)}")
    if sum(row["useful_macs"] for row in passes) != USEFUL_MACS_PER_IMAGE * BATCH:
        raise ValueError("processing passes do not cover batch-eight MAC total")
    if sum(row["weight_dram_bytes"] for row in passes) != 61_253_120:
        raise ValueError("processing passes do not match filter traffic contract")


def layer_record(layer: Layer) -> dict:
    rows = [row for row in iter_passes() if row["layer_id"] == layer.layer_id]
    return {
        **asdict(layer),
        "weights": layer.weights,
        "parameter_bytes": layer.parameter_bytes,
        **mapping_record(layer),
        "weight_dram_bytes_per_batch": sum(row["weight_dram_bytes"] for row in rows),
        "useful_macs_per_batch": sum(row["useful_macs"] for row in rows),
    }


def build_report() -> dict:
    validate_pass_partition()
    layers = [layer_record(layer) for layer in LAYERS]
    weight_dram = sum(row["weight_dram_bytes_per_batch"] for row in layers)
    input_dram = BATCH * sum(layer.input_bytes for layer in LAYERS)
    parameter_dram = sum(layer.parameter_bytes for layer in LAYERS)
    pool_read = BATCH * sum(layer.pool_read_bytes for layer in LAYERS)
    writes = BATCH * sum(layer.current_write_bytes for layer in LAYERS)
    fused_writes = BATCH * sum(layer.output_bytes for layer in LAYERS)
    conservative = weight_dram + input_dram + parameter_dram + pool_read + writes
    fused = weight_dram + input_dram + parameter_dram + fused_writes
    return {
        "scope": "Pure Eyeriss RS, three 12x14 clusters, native batch eight",
        "status": "RTL/mapping model; not a physical-board measurement",
        "architecture": {
            "cluster_shape": "12x14",
            "clusters": CLUSTERS,
            "total_mac_pes": TOTAL_MAC_PES,
            "postprocess_dsps": POSTPROCESS_DSPS,
            "projected_total_dsps": TOTAL_MAC_PES + POSTPROCESS_DSPS,
            "comparison_dsp_budget": TOTAL_DSP_BUDGET,
            "filter_spad_entries_per_pe": FILTER_SPAD_ENTRIES,
            "ifmap_spad_entries_per_pe": IFMAP_SPAD_ENTRIES,
            "psum_spad_entries_per_pe": PSUM_SPAD_ENTRIES,
            "shared_glb_bytes": GLB_BYTES,
            "filter_prefetch_bytes_per_cluster": FILTER_PREFETCH_BYTES_PER_CLUSTER,
            "central_line_buffer": False,
            "batch": BATCH,
        },
        "schedule": {
            "processing_passes": 1_185,
            "useful_macs_per_image": USEFUL_MACS_PER_IMAGE,
            "useful_macs_per_batch": USEFUL_MACS_PER_IMAGE * BATCH,
            "filter_load_policy": "once per processing pass, reused by all 8 images",
            "pass_order": "strip, filter tile, channel group",
        },
        "layers": layers,
        "traffic": {
            "weight_dram_bytes_per_batch": weight_dram,
            "weight_dram_bytes_per_image_equivalent": weight_dram / BATCH,
            "input_dram_bytes_per_batch": input_dram,
            "parameter_dram_bytes_per_batch": parameter_dram,
            "pool_read_bytes_per_batch_conservative": pool_read,
            "write_bytes_per_batch_conservative": writes,
            "total_bytes_per_batch_conservative": conservative,
            "total_bytes_per_image_equivalent_conservative": conservative / BATCH,
            "total_bytes_per_batch_fused_pool": fused,
            "macs_per_external_byte_conservative":
                (USEFUL_MACS_PER_IMAGE * BATCH) / conservative,
        },
        "limits": [
            "Traffic is an accepted-payload projection, not AXI protocol or DDR-row traffic.",
            "Batch images stream sequentially through a pass; filter SPads stay resident.",
            "FC6-FC8 use the R=S=1 degenerate RS mapping.",
            "Board claims require full integration, route, golden-output, and KV260 counters.",
        ],
    }


def write_outputs(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    report = build_report()
    (output_dir / "eyeriss_rs_batch8_mapping.json").write_text(
        json.dumps(report, indent=2) + "\n")

    rows = list(iter_passes())
    with (output_dir / "eyeriss_rs_batch8_passes.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    traffic = report["traffic"]
    lines = [
        "# Pure Eyeriss RS batch-8 mapping",
        "",
        "> Projection only; this is not a KV260 measurement.",
        "",
        "| Metric | Value |",
        "|---|---:|",
        "| Physical RS clusters | 3 x (12 x 14) |",
        "| MAC PEs / postprocess / projected DSP | 504 / 64 / 568 |",
        "| Batch | 8 |",
        "| Central line buffer | none |",
        "| Per-PE filter / ifmap / psum SPad | 224 B / 12 B / 96 B |",
        "| Processing passes | 1,185 |",
        f"| Filter DDR payload | {traffic['weight_dram_bytes_per_batch']/1e6:.6f} MB/batch |",
        f"| Filter payload, image equivalent | {traffic['weight_dram_bytes_per_image_equivalent']/1e6:.6f} MB/image |",
        f"| Conservative external payload | {traffic['total_bytes_per_batch_conservative']/1e6:.6f} MB/batch |",
        f"| Conservative image equivalent | {traffic['total_bytes_per_image_equivalent_conservative']/1e6:.6f} MB/image |",
        f"| MAC/external byte | {traffic['macs_per_external_byte_conservative']:.4f} |",
        "",
        "Filters are multicast horizontally, ifmaps diagonally, and partial sums vertically. "
        "The eight images reuse resident filter rows without a second filter fetch.",
    ]
    (output_dir / "eyeriss_rs_batch8_summary.md").write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path,
                        default=Path(__file__).with_name("reports"))
    args = parser.parse_args()
    write_outputs(args.output_dir)
    print(json.dumps(build_report()["traffic"], indent=2))


if __name__ == "__main__":
    main()
