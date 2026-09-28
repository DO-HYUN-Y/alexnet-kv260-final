"""Measure KV260 DDR-port AXI bytes with the PS APM_DDR hardware monitor.

Run on the KV260 with sudo. The APM measures DDR-controller ingress/egress
AXI bytes shared with CPU and other agents, not physical DRAM ACT/PRE commands.
The PL DMA payload counters are captured alongside it for comparison.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import struct
import time

import numpy as np

from .alexnet_board import AlexNetBoard
from .preprocess import preprocess_bgr_frame


UIO = Path("/dev/uio1")
UIO_SYSFS = Path("/sys/class/uio/uio1")
APM_DDR_PHYSICAL_ADDRESS = 0xFD0B0000
MAP_SIZE = 0x10000
CTRL = 0x300
MSR = (0x44, 0x48, 0x4C)
METRIC_COUNTER_0 = 0x100
METRIC_COUNTER_STRIDE = 0x10
METRIC_READ_BYTES = 3
METRIC_WRITE_BYTES = 2
# HP0/HP1 share DDR slots 0/1 with the CPU; HP2 uses slot 3, HP3 uses slot 4.
# Slot 5 is included to expose other background traffic; slot 2 serves the RPU.
DDR_SLOTS = (0, 1, 3, 4, 5)


class DDRAPM:
    """Own only the DDR APM metric selectors and metric-counter control."""

    def __enter__(self) -> "DDRAPM":
        name = (UIO_SYSFS / "name").read_text(encoding="utf-8").strip()
        address = int((UIO_SYSFS / "maps/map0/addr").read_text().strip(), 16)
        size = int((UIO_SYSFS / "maps/map0/size").read_text().strip(), 16)
        if name != "axi-pmon" or address != APM_DDR_PHYSICAL_ADDRESS or size < MAP_SIZE:
            raise RuntimeError("/dev/uio1 is not the expected APM_DDR mapping")
        self.fd = os.open(UIO, os.O_RDWR | os.O_SYNC)
        try:
            self.map = mmap.mmap(
                self.fd, MAP_SIZE, flags=mmap.MAP_SHARED,
                prot=mmap.PROT_READ | mmap.PROT_WRITE,
            )
        except BaseException:
            os.close(self.fd)
            raise
        self.saved_ctrl = self.read(CTRL)
        self.saved_msr = tuple(self.read(offset) for offset in MSR)
        if self.saved_ctrl & 0x01:
            self.map.close()
            os.close(self.fd)
            raise RuntimeError("APM_DDR metric counters are already in use")
        selectors = []
        for slot in DDR_SLOTS:
            selectors.extend(((slot << 5) | METRIC_READ_BYTES,
                              (slot << 5) | METRIC_WRITE_BYTES))
        self.write(CTRL, self.saved_ctrl & ~0x03)
        for group, offset in enumerate(MSR):
            word = sum(
                selectors[index] << (8 * (index % 4))
                for index in range(group * 4, min(group * 4 + 4, len(selectors)))
            )
            self.write(offset, word)
        self.running = False
        return self

    def __exit__(self, _type, _value, _traceback) -> None:
        try:
            self.write(CTRL, self.saved_ctrl & ~0x03)
            for offset, value in zip(MSR, self.saved_msr):
                self.write(offset, value)
            self.write(CTRL, self.saved_ctrl)
        finally:
            self.map.close()
            os.close(self.fd)

    def read(self, offset: int) -> int:
        return struct.unpack_from("<I", self.map, offset)[0]

    def write(self, offset: int, value: int) -> None:
        struct.pack_into("<I", self.map, offset, value & 0xFFFFFFFF)

    def measure(self, workload) -> tuple[float, dict[str, dict[str, int]]]:
        if self.running:
            raise RuntimeError("APM interval already running")
        base_ctrl = self.saved_ctrl & ~0x03
        self.write(CTRL, base_ctrl | 0x02)  # Pulse metric-counter reset.
        self.write(CTRL, base_ctrl)
        self.write(CTRL, base_ctrl | 0x01)
        self.running = True
        start = time.monotonic()
        try:
            workload()
            elapsed = time.monotonic() - start
        finally:
            self.write(CTRL, base_ctrl)
            self.running = False
        counters = [
            self.read(METRIC_COUNTER_0 + index * METRIC_COUNTER_STRIDE)
            for index in range(2 * len(DDR_SLOTS))
        ]
        return elapsed, {
            str(slot): {"read_bytes": counters[2 * index],
                        "write_bytes": counters[2 * index + 1]}
            for index, slot in enumerate(DDR_SLOTS)
        }


def sums_by_direction(ports: dict[str, dict[str, int]]) -> dict[str, int]:
    return {
        direction: sum(port[direction] for port in ports.values())
        for direction in ("read_bytes", "write_bytes")
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board-dir", type=Path,
                        default=Path("alexnet_output/int8_mlcommons500_board"))
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--idle-seconds", type=float, default=2.0)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.idle_seconds <= 0:
        parser.error("--idle-seconds must be positive")
    try:
        import cv2
    except ImportError as error:
        raise SystemExit("OpenCV is required: install python3-opencv") from error
    frame = cv2.imread(str(args.image), cv2.IMREAD_COLOR)
    if frame is None:
        parser.error(f"cannot read image: {args.image}")

    with AlexNetBoard() as board:
        board.require_identity()
        manifest = board.load_model(args.board_dir)
        board.configure()
        packed = preprocess_bgr_frame(frame, float(manifest["input_scale"]))
        packed_batch = [packed] * 8
        outputs: list[bytes] = []
        with DDRAPM() as apm:
            idle_before_seconds, idle_before = apm.measure(
                lambda: time.sleep(args.idle_seconds)
            )
            dma_before = board.ddr_counters()
            active_seconds, active = apm.measure(
                lambda: outputs.extend(
                    board.infer_batch(packed_batch, timeout_s=30.0)
                )
            )
            dma_delta = board.counter_delta(dma_before, board.ddr_counters())
            idle_after_seconds, idle_after = apm.measure(
                lambda: time.sleep(args.idle_seconds)
            )

    raw_total = sums_by_direction(active)
    baseline_estimate = {
        direction: active_seconds * (
            sums_by_direction(idle_before)[direction] / idle_before_seconds +
            sums_by_direction(idle_after)[direction] / idle_after_seconds
        ) / 2
        for direction in ("read_bytes", "write_bytes")
    }
    report = {
        "monitor": "PS APM_DDR via /dev/uio1 at 0xFD0B0000",
        "scope": "DDR-controller AXI port bytes, not DRAM command/row activity",
        "slots_measured": list(DDR_SLOTS),
        "slot_2_omitted": "RPU-dedicated port, not used by this PL graph",
        "workload": "one native PL batch of eight identical saved images",
        "idle_before": {"seconds": idle_before_seconds, "ports": idle_before,
                        "total": sums_by_direction(idle_before)},
        "active": {"seconds": active_seconds, "ports": active,
                   "total": raw_total},
        "idle_after": {"seconds": idle_after_seconds, "ports": idle_after,
                       "total": sums_by_direction(idle_after)},
        "background_bytes_estimate_over_active_interval": baseline_estimate,
        "background_subtracted_estimate": {
            direction: raw_total[direction] - baseline_estimate[direction]
            for direction in raw_total
        },
        "pl_dma_payload_bytes": dma_delta,
        "outputs_sha256": [hashlib.sha256(value).hexdigest() for value in outputs],
        "winner_index": [int(np.argmax(np.frombuffer(value, dtype=np.int8)))
                         for value in outputs],
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "active": report["active"],
        "background_subtracted_estimate": report["background_subtracted_estimate"],
        "pl_dma_payload_bytes": dma_delta,
        "winner_index": report["winner_index"],
    }, indent=2))
    print(f"ALEXNET_KV260_DDR_APM_MEASUREMENT_PASS output={args.output}")


if __name__ == "__main__":
    main()
