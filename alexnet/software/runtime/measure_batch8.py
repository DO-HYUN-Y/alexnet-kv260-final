"""Sustained KV260 AlexNet measurement with one native batch-eight graph job.

Frame capture, preprocessing, model loading, and JSON writing are outside the
timed inference loop. DDR figures are AXI-stream DMA payload bytes, not DDR
controller transactions.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import threading
import time

import numpy as np

from .alexnet_board import AlexNetBoard
from .preprocess import preprocess_bgr_frame


MACS_PER_IMAGE = 714_188_480
MAC_SLOTS_PER_ISSUE_CYCLE = 1_024


def power_input() -> Path | None:
    for candidate in Path("/sys/class/hwmon").glob("hwmon*/name"):
        if candidate.read_text(encoding="utf-8").strip() == "ina260_u14":
            sensor = candidate.parent / "power1_input"
            return sensor if sensor.is_file() else None
    return None


def source_frames(image: Path | None, camera_index: int) -> list[np.ndarray]:
    import cv2

    if image is not None:
        frame = cv2.imread(str(image), cv2.IMREAD_COLOR)
        if frame is None:
            raise SystemExit(f"cannot read image: {image}")
        return [frame] * 8
    camera = cv2.VideoCapture(camera_index, cv2.CAP_V4L2)
    if not camera.isOpened():
        raise SystemExit(f"cannot open V4L2 camera index {camera_index}")
    try:
        frames = []
        for _ in range(8):
            ok, frame = camera.read()
            if not ok:
                raise RuntimeError("USB camera frame capture failed")
            frames.append(frame)
        return frames
    finally:
        camera.release()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--board-dir", type=Path,
        default=Path("alexnet_output/int8_mlcommons500_board"),
    )
    parser.add_argument("--image", type=Path)
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--active-seconds", type=float, default=60.0)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.active_seconds <= 0:
        parser.error("--active-seconds must be positive")

    frames = source_frames(args.image, args.camera)
    sensor = power_input()
    power_w: list[float] = []
    stop_sampling = threading.Event()

    def sample_power() -> None:
        assert sensor is not None
        while not stop_sampling.is_set():
            try:
                power_w.append(int(sensor.read_text(encoding="utf-8")) / 1e6)
            except (OSError, ValueError):
                pass
            stop_sampling.wait(0.1)

    with AlexNetBoard() as board:
        board.require_identity()
        manifest = board.load_model(args.board_dir)
        board.configure()
        packed_frames = [
            preprocess_bgr_frame(frame, float(manifest["input_scale"]))
            for frame in frames
        ]
        power_thread = None
        if sensor is not None:
            power_thread = threading.Thread(target=sample_power, daemon=True)
            power_thread.start()

        ddr_before = board.ddr_counters()
        batch_latencies_s: list[float] = []
        output_hashes: list[set[str]] = [set() for _ in range(8)]
        winners: list[int] = [0] * 8
        start = time.monotonic()
        try:
            while not batch_latencies_s or time.monotonic() - start < args.active_seconds:
                batch_start = time.monotonic()
                batch_logits = board.infer_batch(
                    packed_frames, timeout_s=30.0
                )
                for slot, logits in enumerate(batch_logits):
                    output_hashes[slot].add(hashlib.sha256(logits).hexdigest())
                    winners[slot] = int(np.argmax(np.frombuffer(logits, dtype=np.int8)))
                batch_latencies_s.append(time.monotonic() - batch_start)
            active_seconds = time.monotonic() - start
            ddr = board.counter_delta(ddr_before, board.ddr_counters())
        finally:
            stop_sampling.set()
            if power_thread is not None:
                power_thread.join()

        # The active/stall counters are 32-bit and can wrap more than once in
        # a 60-second run.  Measure one additional steady-state native batch
        # outside the timed/power/DDR interval so its delta is unambiguous.
        diagnostic_before = board.performance_counters()
        board.infer_batch(packed_frames, timeout_s=30.0)
        counters = board.counter_delta(
            diagnostic_before, board.performance_counters()
        )
        identity = board.inspect()

    image_count = 8 * len(batch_latencies_s)
    images_per_second = image_count / active_seconds
    tops = 2 * MACS_PER_IMAGE * images_per_second / 1e12
    peak_tops = (
        2 * MAC_SLOTS_PER_ISSUE_CYCLE * identity["pl_clock_hz"] / 1e12
    )
    total_bytes = ddr["ddr_read_bytes"] + ddr["ddr_write_bytes"]
    mean_power = statistics.fmean(power_w) if power_w else None
    active_cycles = counters["active_cycles"]
    issue_cycles = counters["issue_cycles"]
    physical_slots = counters["peak_mac_slot_count"]
    useful_macs = counters["useful_mac_count"]

    def ratio_percent(numerator: int | float, denominator: int | float) -> float | None:
        return 100.0 * numerator / denominator if denominator else None

    report = {
        "execution_mode": "native_pl_batch8_conv_fc_weight_reuse",
        "measurement_scope": "preprocessed_infer_only",
        "ddr_counter_scope": "accepted_axi_stream_dma_payload_bytes",
        "hardware_counter_scope": "one_untimed_steady_state_native_batch",
        "source": "repeated_saved_image" if args.image else "eight_captured_frames_repeated",
        "active_seconds": active_seconds,
        "batch_size": 8,
        "completed_batches": len(batch_latencies_s),
        "completed_images": image_count,
        "images_per_second": images_per_second,
        "effective_tops": tops,
        "theoretical_peak_tops": peak_tops,
        "end_to_end_pe_utilization_percent": ratio_percent(tops, peak_tops),
        "mean_image_ms": 1000 * statistics.fmean(batch_latencies_s) / 8,
        "mean_batch_ms": 1000 * statistics.fmean(batch_latencies_s),
        "hardware_counters": {
            "active_cycles": active_cycles,
            "issue_cycles": issue_cycles,
            "weight_stall_cycles": counters["weight_stall_cycles"],
            "activation_stall_cycles": counters["activation_stall_cycles"],
            "result_stall_cycles": counters["result_stall_cycles"],
            "useful_mac_count": useful_macs,
            "physical_mac_slot_count": physical_slots,
            "completed_tiles": counters["completed_tiles"],
            "arithmetic_slot_utilization_percent": ratio_percent(
                useful_macs, physical_slots
            ),
            "issue_duty_within_payload_percent": ratio_percent(
                issue_cycles, active_cycles
            ),
            "weight_stall_percent_of_active": ratio_percent(
                counters["weight_stall_cycles"], active_cycles
            ),
            "activation_stall_percent_of_active": ratio_percent(
                counters["activation_stall_cycles"], active_cycles
            ),
            "result_stall_percent_of_active": ratio_percent(
                counters["result_stall_cycles"], active_cycles
            ),
            "pipeline_total_cycles": counters["pipeline_total_cycles"],
            "pipeline_engine_cycles": counters["pipeline_engine_cycles"],
            "pipeline_weight_cycles": counters["pipeline_weight_cycles"],
            "pipeline_patch_cycles": counters["pipeline_patch_cycles"],
            "pipeline_pool_cycles": counters["pipeline_pool_cycles"],
            "pipeline_result_cycles": counters["pipeline_result_cycles"],
            "pipeline_raster_cycles": counters["pipeline_raster_cycles"],
            "pipeline_dma_cycles": counters["pipeline_dma_cycles"],
            "pipeline_overlap_cycles": counters["pipeline_overlap_cycles"],
            "pipeline_idle_cycles": counters["pipeline_idle_cycles"],
            "issue_duty_end_to_end_percent": ratio_percent(
                issue_cycles, counters["pipeline_total_cycles"]
            ),
            "engine_share_percent": ratio_percent(
                counters["pipeline_engine_cycles"],
                counters["pipeline_total_cycles"],
            ),
            "overlap_share_percent": ratio_percent(
                counters["pipeline_overlap_cycles"],
                counters["pipeline_total_cycles"],
            ),
        },
        "ddr": {
            **ddr,
            "total_bytes": total_bytes,
            "total_bytes_per_image": total_bytes / image_count,
            "weight_bytes_per_image": ddr["weight_read_bytes"] / image_count,
            "payload_bandwidth_MBps": total_bytes / active_seconds / 1e6,
        },
        "power": {
            "sensor": "ina260_u14" if sensor is not None else None,
            "samples": len(power_w),
            "mean_w": mean_power,
            "effective_tops_per_w": tops / mean_power if mean_power else None,
        },
        "output_sha256_by_slot": [sorted(hashes) for hashes in output_hashes],
        "last_winner_index_by_slot": winners,
        "board_identity_after": identity,
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        key: report[key] for key in (
            "execution_mode", "active_seconds", "completed_batches",
            "completed_images", "images_per_second", "effective_tops",
            "theoretical_peak_tops", "end_to_end_pe_utilization_percent",
            "mean_image_ms", "mean_batch_ms", "hardware_counters", "ddr",
            "power",
        )
    }, indent=2))
    print(f"ALEXNET_KV260_BATCH8_MEASUREMENT_PASS output={args.output}")


if __name__ == "__main__":
    main()
