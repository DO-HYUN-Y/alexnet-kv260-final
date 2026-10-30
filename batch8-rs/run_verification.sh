#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_dir"
verilator_bin="${VERILATOR_BIN:-$(command -v verilator || true)}"
if [[ -z "$verilator_bin" || ! -x "$verilator_bin" ]]; then
  echo "Verilator was not found. Install it or set VERILATOR_BIN." >&2
  exit 1
fi

python3 -m unittest -v test_eyeriss_rs_batch8_mapping.py
python3 eyeriss_rs_batch8_mapping.py --output-dir reports

run_sv_test() {
  local top="$1"
  shift
  "$verilator_bin" --binary -j 4 --timing -Wall -Wno-fatal \
    --Mdir "build/${top}" --top-module "$top" "$@"
  "build/${top}/V${top}"
}

run_sv_test tb_alexnet_eyeriss_rs_pe \
  rtl/alexnet_eyeriss_rs_pe.sv \
  tb/tb_alexnet_eyeriss_rs_pe.sv

run_sv_test tb_alexnet_eyeriss_rs_pe_set_noc \
  rtl/alexnet_eyeriss_rs_pe_set_noc.sv \
  tb/tb_alexnet_eyeriss_rs_pe_set_noc.sv

run_sv_test tb_alexnet_eyeriss_rs_glb \
  rtl/alexnet_eyeriss_rs_glb.sv \
  tb/tb_alexnet_eyeriss_rs_glb.sv

run_sv_test tb_alexnet_eyeriss_filter_prefetch \
  rtl/alexnet_eyeriss_filter_prefetch.sv \
  tb/tb_alexnet_eyeriss_filter_prefetch.sv

run_sv_test tb_alexnet_eyeriss_rs_board_address_gen \
  rtl/alexnet_eyeriss_rs_board_address_gen.sv \
  tb/tb_alexnet_eyeriss_rs_board_address_gen.sv

run_sv_test tb_alexnet_eyeriss_rs_dma_line_cache \
  rtl/alexnet_eyeriss_rs_dma_line_cache.sv \
  tb/tb_alexnet_eyeriss_rs_dma_line_cache.sv

run_sv_test tb_alexnet_eyeriss_rs_dma_line_reader \
  rtl/alexnet_eyeriss_rs_dma_line_reader.sv \
  tb/tb_alexnet_eyeriss_rs_dma_line_reader.sv

run_sv_test tb_alexnet_eyeriss_rs_dual_dma_line_adapter \
  rtl/alexnet_eyeriss_rs_dma_line_reader.sv \
  rtl/alexnet_eyeriss_rs_dual_dma_line_adapter.sv \
  tb/tb_alexnet_eyeriss_rs_dual_dma_line_adapter.sv

run_sv_test tb_alexnet_eyeriss_rs_memory_frontend \
  rtl/alexnet_eyeriss_rs_board_address_gen.sv \
  rtl/alexnet_eyeriss_rs_dma_line_cache.sv \
  rtl/alexnet_eyeriss_rs_memory_frontend.sv \
  tb/tb_alexnet_eyeriss_rs_memory_frontend.sv

run_sv_test tb_alexnet_eyeriss_rs_channel_accumulator \
  rtl/alexnet_eyeriss_rs_channel_accumulator.sv \
  tb/tb_alexnet_eyeriss_rs_channel_accumulator.sv

run_sv_test tb_alexnet_eyeriss_rs_parameter_cache \
  rtl/alexnet_eyeriss_rs_parameter_cache.sv \
  tb/tb_alexnet_eyeriss_rs_parameter_cache.sv

run_sv_test tb_alexnet_eyeriss_rs_requant14 \
  rtl/alexnet_eyeriss_rs_requant14.sv \
  tb/tb_alexnet_eyeriss_rs_requant14.sv

run_sv_test tb_alexnet_eyeriss_rs_n8_result_store \
  rtl/alexnet_eyeriss_rs_n8_result_store.sv \
  tb/tb_alexnet_eyeriss_rs_n8_result_store.sv

run_sv_test tb_alexnet_eyeriss_rs_n8_result_store_conv \
  rtl/alexnet_eyeriss_rs_n8_result_store.sv \
  tb/tb_alexnet_eyeriss_rs_n8_result_store_conv.sv

run_sv_test tb_alexnet_eyeriss_rs_batch8_inplace_pool_service \
  rtl/alexnet_eyeriss_rs_batch8_inplace_pool_service.sv \
  tb/tb_alexnet_eyeriss_rs_batch8_inplace_pool_service.sv

run_sv_test tb_alexnet_eyeriss_rs_batch8_board_postprocess_top \
  rtl/alexnet_eyeriss_filter_vector_bank.sv \
  rtl/alexnet_eyeriss_rs_mac_pe.sv \
  rtl/alexnet_eyeriss_rs_gin.sv \
  rtl/alexnet_eyeriss_rs_local_psum_network.sv \
  rtl/alexnet_eyeriss_rs_cluster.sv \
  rtl/alexnet_eyeriss_rs_3cluster_core.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  rtl/alexnet_eyeriss_rs_batch8_control.sv \
  rtl/alexnet_eyeriss_rs_filter_load_sequencer.sv \
  rtl/alexnet_eyeriss_rs_image_op_sequencer.sv \
  rtl/alexnet_eyeriss_rs_batch8_command_top.sv \
  rtl/alexnet_eyeriss_rs_batch8_core_top.sv \
  rtl/alexnet_eyeriss_rs_board_address_gen.sv \
  rtl/alexnet_eyeriss_rs_dma_line_cache.sv \
  rtl/alexnet_eyeriss_rs_memory_frontend.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_frontend_top.sv \
  rtl/alexnet_eyeriss_rs_channel_accumulator.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_accum_top.sv \
  rtl/alexnet_eyeriss_rs_dma_line_reader.sv \
  rtl/alexnet_eyeriss_rs_dual_dma_line_adapter.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_dma_top.sv \
  rtl/alexnet_eyeriss_rs_parameter_cache.sv \
  rtl/alexnet_eyeriss_rs_requant14.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_postprocess_top.sv \
  tb/tb_alexnet_eyeriss_rs_batch8_board_postprocess_top.sv

run_sv_test tb_alexnet_eyeriss_rs_filter_load_sequencer \
  rtl/alexnet_eyeriss_rs_filter_load_sequencer.sv \
  tb/tb_alexnet_eyeriss_rs_filter_load_sequencer.sv

run_sv_test tb_alexnet_eyeriss_rs_image_op_sequencer \
  rtl/alexnet_eyeriss_rs_image_op_sequencer.sv \
  tb/tb_alexnet_eyeriss_rs_image_op_sequencer.sv

run_sv_test tb_alexnet_eyeriss_rs_batch8_pass_scheduler \
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv \
  tb/tb_alexnet_eyeriss_rs_batch8_pass_scheduler.sv

run_sv_test tb_alexnet_eyeriss_rs_batch8_pass_executor \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  tb/tb_alexnet_eyeriss_rs_batch8_pass_executor.sv

run_sv_test tb_alexnet_eyeriss_rs_multiset_mapping \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  tb/tb_alexnet_eyeriss_rs_multiset_mapping.sv

run_sv_test tb_alexnet_eyeriss_rs_batch8_control \
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  rtl/alexnet_eyeriss_rs_batch8_control.sv \
  tb/tb_alexnet_eyeriss_rs_batch8_control.sv

run_sv_test tb_alexnet_eyeriss_rs_batch8_command_top \
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  rtl/alexnet_eyeriss_rs_batch8_control.sv \
  rtl/alexnet_eyeriss_rs_filter_load_sequencer.sv \
  rtl/alexnet_eyeriss_rs_image_op_sequencer.sv \
  rtl/alexnet_eyeriss_rs_batch8_command_top.sv \
  tb/tb_alexnet_eyeriss_rs_batch8_command_top.sv

run_sv_test tb_alexnet_eyeriss_rs_batch8_core_top \
  rtl/alexnet_eyeriss_filter_vector_bank.sv \
  rtl/alexnet_eyeriss_rs_mac_pe.sv \
  rtl/alexnet_eyeriss_rs_gin.sv \
  rtl/alexnet_eyeriss_rs_local_psum_network.sv \
  rtl/alexnet_eyeriss_rs_cluster.sv \
  rtl/alexnet_eyeriss_rs_3cluster_core.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  rtl/alexnet_eyeriss_rs_batch8_control.sv \
  rtl/alexnet_eyeriss_rs_filter_load_sequencer.sv \
  rtl/alexnet_eyeriss_rs_image_op_sequencer.sv \
  rtl/alexnet_eyeriss_rs_batch8_command_top.sv \
  rtl/alexnet_eyeriss_rs_batch8_core_top.sv \
  tb/tb_alexnet_eyeriss_rs_batch8_core_top.sv

run_sv_test tb_alexnet_eyeriss_rs_batch8_board_frontend_top \
  rtl/alexnet_eyeriss_filter_vector_bank.sv \
  rtl/alexnet_eyeriss_rs_mac_pe.sv \
  rtl/alexnet_eyeriss_rs_gin.sv \
  rtl/alexnet_eyeriss_rs_local_psum_network.sv \
  rtl/alexnet_eyeriss_rs_cluster.sv \
  rtl/alexnet_eyeriss_rs_3cluster_core.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  rtl/alexnet_eyeriss_rs_batch8_control.sv \
  rtl/alexnet_eyeriss_rs_filter_load_sequencer.sv \
  rtl/alexnet_eyeriss_rs_image_op_sequencer.sv \
  rtl/alexnet_eyeriss_rs_batch8_command_top.sv \
  rtl/alexnet_eyeriss_rs_batch8_core_top.sv \
  rtl/alexnet_eyeriss_rs_board_address_gen.sv \
  rtl/alexnet_eyeriss_rs_dma_line_cache.sv \
  rtl/alexnet_eyeriss_rs_memory_frontend.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_frontend_top.sv \
  tb/tb_alexnet_eyeriss_rs_batch8_board_frontend_top.sv

run_sv_test tb_alexnet_eyeriss_rs_cluster \
  rtl/alexnet_eyeriss_filter_vector_bank.sv \
  rtl/alexnet_eyeriss_rs_mac_pe.sv \
  rtl/alexnet_eyeriss_rs_pe_set_noc.sv \
  rtl/alexnet_eyeriss_rs_gin.sv \
  rtl/alexnet_eyeriss_rs_local_psum_network.sv \
  rtl/alexnet_eyeriss_rs_cluster.sv \
  tb/tb_alexnet_eyeriss_rs_cluster.sv

"$verilator_bin" --lint-only -Wall -Wno-fatal \
  --top-module alexnet_eyeriss_rs_3cluster_core \
  rtl/alexnet_eyeriss_filter_vector_bank.sv \
  rtl/alexnet_eyeriss_rs_mac_pe.sv \
  rtl/alexnet_eyeriss_rs_pe_set_noc.sv \
  rtl/alexnet_eyeriss_rs_gin.sv \
  rtl/alexnet_eyeriss_rs_local_psum_network.sv \
  rtl/alexnet_eyeriss_rs_cluster.sv \
  rtl/alexnet_eyeriss_rs_3cluster_core.sv

"$verilator_bin" --lint-only -Wall -Wno-fatal \
  --top-module alexnet_eyeriss_rs_batch8_board_dma_top \
  rtl/alexnet_eyeriss_filter_vector_bank.sv \
  rtl/alexnet_eyeriss_rs_mac_pe.sv \
  rtl/alexnet_eyeriss_rs_gin.sv \
  rtl/alexnet_eyeriss_rs_local_psum_network.sv \
  rtl/alexnet_eyeriss_rs_cluster.sv \
  rtl/alexnet_eyeriss_rs_3cluster_core.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  rtl/alexnet_eyeriss_rs_batch8_control.sv \
  rtl/alexnet_eyeriss_rs_filter_load_sequencer.sv \
  rtl/alexnet_eyeriss_rs_image_op_sequencer.sv \
  rtl/alexnet_eyeriss_rs_batch8_command_top.sv \
  rtl/alexnet_eyeriss_rs_batch8_core_top.sv \
  rtl/alexnet_eyeriss_rs_board_address_gen.sv \
  rtl/alexnet_eyeriss_rs_dma_line_cache.sv \
  rtl/alexnet_eyeriss_rs_memory_frontend.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_frontend_top.sv \
  rtl/alexnet_eyeriss_rs_channel_accumulator.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_accum_top.sv \
  rtl/alexnet_eyeriss_rs_dma_line_reader.sv \
  rtl/alexnet_eyeriss_rs_dual_dma_line_adapter.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_dma_top.sv

"$verilator_bin" --lint-only -Wall -Wno-fatal \
  --top-module alexnet_eyeriss_rs_batch8_board_postprocess_top \
  rtl/alexnet_eyeriss_filter_vector_bank.sv \
  rtl/alexnet_eyeriss_rs_mac_pe.sv \
  rtl/alexnet_eyeriss_rs_gin.sv \
  rtl/alexnet_eyeriss_rs_local_psum_network.sv \
  rtl/alexnet_eyeriss_rs_cluster.sv \
  rtl/alexnet_eyeriss_rs_3cluster_core.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  rtl/alexnet_eyeriss_rs_batch8_control.sv \
  rtl/alexnet_eyeriss_rs_filter_load_sequencer.sv \
  rtl/alexnet_eyeriss_rs_image_op_sequencer.sv \
  rtl/alexnet_eyeriss_rs_batch8_command_top.sv \
  rtl/alexnet_eyeriss_rs_batch8_core_top.sv \
  rtl/alexnet_eyeriss_rs_board_address_gen.sv \
  rtl/alexnet_eyeriss_rs_dma_line_cache.sv \
  rtl/alexnet_eyeriss_rs_memory_frontend.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_frontend_top.sv \
  rtl/alexnet_eyeriss_rs_channel_accumulator.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_accum_top.sv \
  rtl/alexnet_eyeriss_rs_dma_line_reader.sv \
  rtl/alexnet_eyeriss_rs_dual_dma_line_adapter.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_dma_top.sv \
  rtl/alexnet_eyeriss_rs_parameter_cache.sv \
  rtl/alexnet_eyeriss_rs_requant14.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_postprocess_top.sv

"$verilator_bin" --lint-only -Wall -Wno-fatal \
  --top-module alexnet_eyeriss_rs_batch8_board_store_top \
  rtl/alexnet_eyeriss_filter_vector_bank.sv \
  rtl/alexnet_eyeriss_rs_mac_pe.sv \
  rtl/alexnet_eyeriss_rs_gin.sv \
  rtl/alexnet_eyeriss_rs_local_psum_network.sv \
  rtl/alexnet_eyeriss_rs_cluster.sv \
  rtl/alexnet_eyeriss_rs_3cluster_core.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv \
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv \
  rtl/alexnet_eyeriss_rs_batch8_control.sv \
  rtl/alexnet_eyeriss_rs_filter_load_sequencer.sv \
  rtl/alexnet_eyeriss_rs_image_op_sequencer.sv \
  rtl/alexnet_eyeriss_rs_batch8_command_top.sv \
  rtl/alexnet_eyeriss_rs_batch8_core_top.sv \
  rtl/alexnet_eyeriss_rs_board_address_gen.sv \
  rtl/alexnet_eyeriss_rs_dma_line_cache.sv \
  rtl/alexnet_eyeriss_rs_memory_frontend.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_frontend_top.sv \
  rtl/alexnet_eyeriss_rs_channel_accumulator.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_accum_top.sv \
  rtl/alexnet_eyeriss_rs_dma_line_reader.sv \
  rtl/alexnet_eyeriss_rs_dual_dma_line_adapter.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_dma_top.sv \
  rtl/alexnet_eyeriss_rs_parameter_cache.sv \
  rtl/alexnet_eyeriss_rs_requant14.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_postprocess_top.sv \
  rtl/alexnet_eyeriss_rs_n8_result_store.sv \
  rtl/alexnet_eyeriss_rs_batch8_inplace_pool_service.sv \
  rtl/alexnet_eyeriss_rs_batch8_board_store_top.sv

echo "ALL_PURE_EYERISS_RS_VERIFICATION_PASSED"
