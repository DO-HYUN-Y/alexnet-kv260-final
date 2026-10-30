import unittest

from eyeriss_rs_batch8_mapping import (
    BATCH,
    GLB_BYTES,
    LAYERS,
    TOTAL_DSP_BUDGET,
    USEFUL_MACS_PER_IMAGE,
    build_report,
    iter_passes,
)


class EyerissRsBatch8MappingTest(unittest.TestCase):
    def setUp(self):
        self.passes = list(iter_passes())
        self.report = build_report()

    def test_paper_shaped_compute_and_budget(self):
        arch = self.report["architecture"]
        self.assertEqual(arch["cluster_shape"], "12x14")
        self.assertEqual(arch["clusters"], 3)
        self.assertEqual(arch["total_mac_pes"], 504)
        self.assertLessEqual(arch["projected_total_dsps"], TOTAL_DSP_BUDGET)
        self.assertFalse(arch["central_line_buffer"])

    def test_native_batch_eight_reuses_filters(self):
        self.assertEqual(BATCH, 8)
        self.assertEqual(len(self.passes), 1_185)
        self.assertEqual(sum(row["useful_macs"] for row in self.passes),
                         USEFUL_MACS_PER_IMAGE * BATCH)
        self.assertTrue(all(row["batch_count"] == 8 for row in self.passes))
        self.assertTrue(all(row["keep_filter_for_batch"] for row in self.passes))
        self.assertEqual(sum(row["weight_dram_bytes"] for row in self.passes),
                         61_253_120)

    def test_processing_pass_partition(self):
        expected = {1: 24, 2: 128, 3: 96, 4: 192,
                    5: 129, 6: 384, 7: 174, 8: 58}
        for layer_id, count in expected.items():
            self.assertEqual(sum(row["layer_id"] == layer_id
                                 for row in self.passes), count)

    def test_spad_and_glb_capacity(self):
        for layer in self.report["layers"]:
            self.assertLessEqual(layer["glb_total_bytes"], GLB_BYTES)
            mapping = layer["mapping"]
            source = LAYERS[layer["layer_id"] - 1]
            self.assertLessEqual(mapping["p"] * mapping["q"] * source.filter_s, 224)
            self.assertLessEqual(mapping["q"] * source.filter_s, 12)
            self.assertLessEqual(mapping["p"], 24)

    def test_batch_external_payload(self):
        traffic = self.report["traffic"]
        self.assertEqual(traffic["weight_dram_bytes_per_batch"], 61_253_120)
        self.assertAlmostEqual(traffic["weight_dram_bytes_per_image_equivalent"],
                               7_656_640.0)
        self.assertGreater(traffic["macs_per_external_byte_conservative"], 70.0)


if __name__ == "__main__":
    unittest.main()
