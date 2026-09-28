"""Host-side tests for Linux ioctl, memory, and preprocessing contracts."""

from __future__ import annotations

from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock

import numpy as np

from . import alexnet_board as board
from . import alexnet_camera_demo
from .preprocess import coarse_korean_category, preprocess_bgr_frame


class RuntimeContractTest(unittest.TestCase):
    def test_identity_matches_m8n126_graph_release(self) -> None:
        self.assertEqual(board.EXPECTED_ID, 0x4D388500)
        self.assertEqual(board.EXPECTED_BUILD_CONFIG, 0x087E00B9)

    def test_python_layout_matches_driver_header(self) -> None:
        header = (
            Path(__file__).parents[1] / "include" / "alexnet_buffer_layout.h"
        ).read_text(encoding="utf-8")
        macros = {
            name: int(value)
            for name, value in re.findall(
                r"^#define\s+(ALEXNET_[A-Z0-9_]+)\s+(\d+)u$",
                header,
                flags=re.MULTILINE,
            )
        }
        expected = {
            "ALEXNET_BATCH_SIZE": board.BATCH_SIZE,
            "ALEXNET_CAMERA_IMAGE_BYTES": board.INPUT_BYTES,
            "ALEXNET_CAMERA_BUFFER_BYTES": board.INPUT_ALLOC_BYTES,
            "ALEXNET_ACTIVATION_A_BYTES": board.ACTIVATION_A_BYTES,
            "ALEXNET_ACTIVATION_B_BYTES": board.ACTIVATION_B_BYTES,
            "ALEXNET_ACTIVATION_IMAGE_STRIDE": board.ACTIVATION_IMAGE_STRIDE,
            "ALEXNET_BATCH_ACTIVATION_OFFSET": board.BATCH_ACTIVATION_OFFSET,
            "ALEXNET_WEIGHT_BYTES": board.WEIGHTS_BYTES,
            "ALEXNET_PARAMETER_BYTES": board.PARAMETERS_BYTES,
            "ALEXNET_OUTPUT_IMAGE_BYTES": board.OUTPUT_IMAGE_BYTES,
            "ALEXNET_OUTPUT_VALID_BYTES": board.OUTPUT_VALID_BYTES,
            "ALEXNET_OUTPUT_ALLOC_BYTES": board.OUTPUT_ALLOC_BYTES,
            "ALEXNET_BUFFER_INPUT_OFFSET": board.INPUT_OFFSET,
            "ALEXNET_BUFFER_ACT_A_OFFSET": board.ACTIVATION_A_OFFSET,
            "ALEXNET_BUFFER_ACT_B_OFFSET": board.ACTIVATION_B_OFFSET,
            "ALEXNET_BUFFER_WEIGHTS_OFFSET": board.WEIGHTS_OFFSET,
            "ALEXNET_BUFFER_PARAMETERS_OFFSET": board.PARAMETERS_OFFSET,
            "ALEXNET_BUFFER_OUTPUT_OFFSET": board.OUTPUT_OFFSET,
            "ALEXNET_DMA_USED_BYTES": board.DMA_USED_BYTES,
        }
        self.assertEqual({key: macros[key] for key in expected}, expected)

    def test_memory_layout_is_aligned_nonoverlapping_and_exact(self) -> None:
        regions = (
            (board.INPUT_OFFSET, board.INPUT_ALLOC_BYTES),
            (board.ACTIVATION_A_OFFSET, board.ACTIVATION_A_BYTES),
            (board.ACTIVATION_B_OFFSET, board.ACTIVATION_B_BYTES),
            (board.WEIGHTS_OFFSET, board.WEIGHTS_BYTES),
            (board.PARAMETERS_OFFSET, board.PARAMETERS_BYTES),
            (board.OUTPUT_OFFSET, board.OUTPUT_ALLOC_BYTES),
        )
        previous_end = 0
        for offset, size in regions:
            self.assertEqual(offset % board.BASE_ALIGNMENT, 0)
            self.assertGreaterEqual(offset, previous_end)
            previous_end = offset + size
        self.assertEqual(previous_end, board.DMA_USED_BYTES)
        self.assertEqual(board.DMA_BUFFER_BYTES % board.mmap.PAGESIZE, 0)
        self.assertGreaterEqual(board.DMA_BUFFER_BYTES, board.DMA_USED_BYTES)
        self.assertLess(
            board.DMA_BUFFER_BYTES - board.DMA_USED_BYTES,
            board.mmap.PAGESIZE,
        )
        self.assertEqual(
            board.BATCH_ACTIVATION_OFFSET,
            board.BATCH_SIZE * board.ACTIVATION_IMAGE_STRIDE,
        )
        self.assertGreaterEqual(
            board.ACTIVATION_A_BYTES,
            board.BATCH_ACTIVATION_OFFSET + 32_768,
        )
        self.assertGreaterEqual(
            board.ACTIVATION_B_BYTES,
            board.BATCH_ACTIVATION_OFFSET + 32_768,
        )

    def test_ioctl_numbers_match_linux_generic_encoding(self) -> None:
        self.assertEqual(board.IOC_GET_INFO, 0x80304100)
        self.assertEqual(board.IOC_READ_REG, 0xC0104101)
        self.assertEqual(board.IOC_WRITE_REG, 0x40104102)

    def test_ddr_counter_register_layout_and_wraparound_delta(self) -> None:
        self.assertEqual(board.REG_DDR_READ_BYTES_LO, 0xAC)
        self.assertEqual(board.REG_DDR_WRITE_BYTES_LO, 0xB4)
        self.assertEqual(board.REG_MAIN_READ_BYTES_LO, 0xBC)
        self.assertEqual(board.REG_WEIGHT_READ_BYTES_LO, 0xC4)
        self.assertEqual(board.REG_CAMERA_READ_BYTES_LO, 0xCC)
        self.assertEqual(board.REG_PIPELINE_TOTAL, 0xD4)
        self.assertEqual(board.REG_PIPELINE_IDLE, 0xF8)
        before = {"ddr_read_bytes": (1 << 64) - 8, "active_cycles": 10}
        after = {"ddr_read_bytes": 12, "active_cycles": 25}
        self.assertEqual(
            board.AlexNetBoard.counter_delta(before, after),
            {"ddr_read_bytes": 20, "active_cycles": 15},
        )

    def test_camera_demo_defaults_to_native_batch_eight(self) -> None:
        with mock.patch("sys.argv", ["alexnet_camera_demo"]):
            args = alexnet_camera_demo.parse_args()
        self.assertEqual(args.batch_size, 8)

        fake_board = mock.Mock()
        fake_board.ddr_counters.side_effect = [
            {"ddr_read_bytes": 0, "ddr_write_bytes": 0},
            {"ddr_read_bytes": 800, "ddr_write_bytes": 80},
        ]
        fake_board.counter_delta.side_effect = board.AlexNetBoard.counter_delta
        frames = [np.zeros((1, 1, 3), dtype=np.uint8) for _ in range(8)]
        fake_board.infer_batch.return_value = [bytes(1000)] * 8
        manifest = {"input_scale": board.EXPECTED_INPUT_SCALE,
                    "categories": [str(index) for index in range(1000)]}
        with mock.patch.object(
            alexnet_camera_demo, "preprocess_bgr_frame",
            return_value=bytes(board.INPUT_BYTES),
        ), mock.patch("builtins.print") as output:
            report = alexnet_camera_demo.classify_batch(
                fake_board, frames, manifest, 10.0, 5
            )
        fake_board.infer_batch.assert_called_once()
        self.assertIn("Conv/FC 가중치 재사용", output.call_args.args[0])
        self.assertEqual(report["batch_size"], 8)
        self.assertEqual(report["ddr_total_bytes"], 880)
        self.assertEqual(len(report["per_image"]), 8)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "batch.jsonl"
            alexnet_camera_demo.append_report(path, report)
            saved = path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(saved), 1)
        self.assertIn('"batch_size": 8', saved[0])

    def test_inference_does_not_launch_unused_camera_dma(self) -> None:
        fake_board = mock.Mock()
        fake_board.job_tag = 0
        fake_board.memory = bytearray(16)
        fake_board.read_reg.return_value = board.STATUS_DONE
        with mock.patch.multiple(
            board, OUTPUT_OFFSET=0, OUTPUT_ALLOC_BYTES=16,
            OUTPUT_VALID_BYTES=8, OUTPUT_IMAGE_BYTES=8, BATCH_SIZE=1,
        ):
            result = board.AlexNetBoard.infer_batch(
                fake_board, [b"frame"]
            )
        self.assertEqual(result, [bytes(8)])
        fake_board.write_input.assert_called_once_with(b"frame", 0)
        self.assertTrue(
            all(call.args[0] != board.REG_SPACE_CAMERA_DMA
                for call in fake_board.read_reg.call_args_list)
        )
        self.assertTrue(
            all(call.args[0] != board.REG_SPACE_CAMERA_DMA
                for call in fake_board.write_reg.call_args_list)
        )

    def test_preprocess_channel_order_quantization_and_zero_padding(
        self,
    ) -> None:
        # A constant image makes interpolation irrelevant while still checking
        # BGR-to-RGB, normalization, quantization, and the 8-byte ABI.
        bgr = np.empty((224, 224, 3), dtype=np.uint8)
        bgr[:, :, 0] = 10
        bgr[:, :, 1] = 20
        bgr[:, :, 2] = 30
        resized = np.pad(bgr, ((16, 16), (16, 16), (0, 0)))
        packed = np.frombuffer(
            preprocess_bgr_frame(
                bgr,
                0.020787402400820273,
                resize_function=lambda _image, _size: resized,
            ),
            dtype=np.int8,
        ).reshape(224, 224, 8)
        self.assertTrue(np.all(packed == packed[0, 0]))
        self.assertTrue(np.array_equal(packed[0, 0], [-77, -81, -78, 0, 0, 0, 0, 0]))

    def test_korean_dog_category_range(self) -> None:
        self.assertEqual(coarse_korean_category(207), "강아지")
        self.assertEqual(coarse_korean_category(281), "고양이")
        self.assertIsNone(coarse_korean_category(0))


if __name__ == "__main__":
    unittest.main()
