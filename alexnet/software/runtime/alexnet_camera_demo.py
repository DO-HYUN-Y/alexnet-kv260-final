"""Run saved-image or live USB-camera AlexNet inference on KV260."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import numpy as np

from .alexnet_board import AlexNetBoard
from .preprocess import format_prediction, preprocess_bgr_frame

USEFUL_MACS_PER_IMAGE = 714_188_480


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="/dev/alexnet_board")
    parser.add_argument(
        "--board-dir",
        type=Path,
        default=Path("alexnet_output/int8_mlcommons500_board"),
    )
    parser.add_argument("--image", type=Path, help="run a saved image (repeated for a batch)")
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument(
        "--inspect", action="store_true", help="check board identity and exit"
    )
    parser.add_argument("--once", action="store_true", help="classify one camera batch")
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--topk", type=int, default=5)
    parser.add_argument(
        "--batch-size", type=int, default=8,
        help="native FPGA batch size (fixed at 8)",
    )
    parser.add_argument(
        "--report-jsonl", type=Path,
        help="append machine-readable measurements for each batch",
    )
    return parser.parse_args()


def classify(
    board: AlexNetBoard,
    frame: np.ndarray,
    manifest: dict,
    timeout_s: float,
    topk: int,
) -> dict:
    packed = preprocess_bgr_frame(frame, float(manifest["input_scale"]))
    ddr_before = board.ddr_counters()
    start = time.monotonic()
    raw_logits = board.infer(packed, timeout_s)
    elapsed_ms = (time.monotonic() - start) * 1000.0
    ddr_after = board.ddr_counters()
    ddr = board.counter_delta(ddr_before, ddr_after)
    logits = np.frombuffer(raw_logits, dtype=np.int8)
    order = np.argsort(-logits.astype(np.int16), kind="stable")[:topk]
    winner = int(np.argmax(logits))
    categories = manifest["categories"]
    print(format_prediction(winner, categories[winner], int(logits[winner])))
    top_text = ", ".join(
        f"{categories[int(index)]}={int(logits[int(index)])}"
        for index in order
    )
    print(f"Top-{topk}: {top_text} / PL 왕복 {elapsed_ms:.1f} ms", flush=True)
    total_bytes = ddr["ddr_read_bytes"] + ddr["ddr_write_bytes"]
    print(
        "DDR DMA payload 실측: "
        f"read={ddr['ddr_read_bytes']:,} B "
        f"(main={ddr['main_read_bytes']:,}, "
        f"weight={ddr['weight_read_bytes']:,}, "
        f"camera={ddr['camera_read_bytes']:,}), "
        f"write={ddr['ddr_write_bytes']:,} B, "
        f"total={total_bytes / (1024 * 1024):.3f} MiB/image, "
        f"bandwidth={total_bytes / (elapsed_ms * 1000):.3f} MB/s",
        flush=True,
    )
    return {
        "winner_index": winner,
        "winner_label": categories[winner],
        "winner_score": int(logits[winner]),
        "elapsed_ms": elapsed_ms,
        **ddr,
    }


def classify_batch(
    board: AlexNetBoard,
    frames: list[np.ndarray],
    manifest: dict,
    timeout_s: float,
    topk: int,
) -> dict:
    """Run one native batch-eight graph job with FC weight reuse."""
    if len(frames) != 8:
        raise ValueError("native FPGA execution requires exactly eight frames")
    packed_frames = [
        preprocess_bgr_frame(frame, float(manifest["input_scale"]))
        for frame in frames
    ]
    ddr_before = board.ddr_counters()
    start = time.monotonic()
    batch_logits = board.infer_batch(packed_frames, timeout_s)
    elapsed_s = time.monotonic() - start
    ddr = board.counter_delta(ddr_before, board.ddr_counters())
    categories = manifest["categories"]
    per_image = []
    for index, raw_logits in enumerate(batch_logits, start=1):
        logits = np.frombuffer(raw_logits, dtype=np.int8)
        order = np.argsort(-logits.astype(np.int16), kind="stable")[:topk]
        winner = int(np.argmax(logits))
        print(
            f"배치 {index}/8: " +
            format_prediction(
                winner, categories[winner], int(logits[winner])
            ) + " / Top-" + str(topk) + ": " +
            ", ".join(
                f"{categories[int(item)]}={int(logits[int(item)])}"
                for item in order
            ),
            flush=True,
        )
        per_image.append({
            "winner_index": winner,
            "winner_label": categories[winner],
            "winner_score": int(logits[winner]),
        })
    total_bytes = ddr["ddr_read_bytes"] + ddr["ddr_write_bytes"]
    images_per_s = len(frames) / elapsed_s
    effective_tops = 2 * USEFUL_MACS_PER_IMAGE * images_per_s / 1e12
    print(
        f"배치 요약 (PL native batch-8, Conv/FC 가중치 재사용): "
        f"{len(frames)}장/{elapsed_s:.3f}s, "
        f"{images_per_s:.3f} images/s, "
        f"{effective_tops:.6f} "
        f"유효 TOPS(호스트 경과시간), "
        f"DDR DMA payload {total_bytes / (1024 * 1024):.3f} MiB/batch "
        f"({total_bytes / len(frames) / (1024 * 1024):.3f} MiB/image)",
        flush=True,
    )
    return {
        "batch_size": len(frames),
        "execution_mode": "native_pl_batch8_conv_fc_weight_reuse",
        "elapsed_s": elapsed_s,
        "images_per_s": images_per_s,
        "effective_tops": effective_tops,
        "useful_macs_per_image": USEFUL_MACS_PER_IMAGE,
        "ddr_total_bytes": total_bytes,
        **ddr,
        "per_image": per_image,
    }


def append_report(path: Path | None, report: dict) -> None:
    if path is not None:
        with path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(report, ensure_ascii=False) + "\n")


def main() -> None:
    args = parse_args()
    if not 1 <= args.topk <= 1000:
        raise SystemExit("--topk must be in 1..1000")
    if args.batch_size != 8:
        raise SystemExit("--batch-size must be 8 for this bitstream")
    with AlexNetBoard(args.device) as board:
        board.require_identity()
        if args.inspect:
            print(json.dumps(board.inspect(), indent=2))
            print("ALEXNET_KV260_BOARD_INSPECT_PASS")
            return
        try:
            import cv2
        except ImportError as error:
            raise SystemExit("OpenCV is required: install python3-opencv") from error
        manifest = board.load_model(args.board_dir)
        board.configure()
        print(
            f"AlexNet 준비 완료: PL={board.pl_clock_hz} Hz, "
            f"DMA=0x{board.dma_addr:08x}, 모델 적재 완료",
            flush=True,
        )

        if args.image is not None:
            frame = cv2.imread(str(args.image), cv2.IMREAD_COLOR)
            if frame is None:
                raise SystemExit(f"cannot read image: {args.image}")
            report = classify_batch(
                board, [frame] * args.batch_size, manifest,
                args.timeout, args.topk,
            )
            report["source"] = "repeated_saved_image"
            append_report(args.report_jsonl, report)
            return

        camera = cv2.VideoCapture(args.camera, cv2.CAP_V4L2)
        if not camera.isOpened():
            raise SystemExit(f"cannot open V4L2 camera index {args.camera}")
        print("USB 카메라 분류 시작 (종료: Ctrl+C)", flush=True)
        try:
            while True:
                frames = []
                for _ in range(args.batch_size):
                    ok, frame = camera.read()
                    if not ok:
                        raise RuntimeError("USB camera frame capture failed")
                    frames.append(frame)
                report = classify_batch(
                    board, frames, manifest, args.timeout, args.topk
                )
                report["source"] = "camera_frames"
                append_report(args.report_jsonl, report)
                if args.once:
                    break
                if args.interval > 0:
                    time.sleep(args.interval)
        except KeyboardInterrupt:
            print("카메라 분류 종료")
        finally:
            camera.release()


if __name__ == "__main__":
    main()
