#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_dir"

verilator_bin="${VERILATOR_BIN:-$(command -v verilator || true)}"
if [[ -z "$verilator_bin" || ! -x "$verilator_bin" ]]; then
  echo "Verilator was not found. Install it or set VERILATOR_BIN." >&2
  exit 1
fi

top=tb_pure_rs_full_graph_counters
build_dir="measurements/paper_comparison/build/${top}"
evidence_dir="measurements/paper_comparison/evidence"
mkdir -p "$build_dir" "$evidence_dir"

sources=(
  rtl/alexnet_eyeriss_filter_vector_bank.sv
  rtl/alexnet_eyeriss_rs_mac_pe.sv
  rtl/alexnet_eyeriss_rs_gin.sv
  rtl/alexnet_eyeriss_rs_local_psum_network.sv
  rtl/alexnet_eyeriss_rs_cluster.sv
  rtl/alexnet_eyeriss_rs_3cluster_core.sv
  rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv
  rtl/alexnet_eyeriss_rs_batch8_pass_executor.sv
  rtl/alexnet_eyeriss_rs_batch8_control.sv
  rtl/alexnet_eyeriss_rs_filter_load_sequencer.sv
  rtl/alexnet_eyeriss_rs_image_op_sequencer.sv
  rtl/alexnet_eyeriss_rs_batch8_command_top.sv
  rtl/alexnet_eyeriss_rs_batch8_core_top.sv
  rtl/alexnet_eyeriss_rs_board_address_gen.sv
  rtl/alexnet_eyeriss_rs_dma_line_cache.sv
  rtl/alexnet_eyeriss_rs_memory_frontend.sv
  rtl/alexnet_eyeriss_rs_batch8_board_frontend_top.sv
  measurements/paper_comparison/tb/${top}.sv
)

"$verilator_bin" --binary -j 4 --timing -O3 -Wall -Wno-fatal \
  --Mdir "$build_dir" --top-module "$top" "${sources[@]}" \
  >"$evidence_dir/pure_rs_full_graph_counter_build.log" 2>&1

stop_args=()
if [[ -n "${STOP_AFTER_LAYER:-}" ]]; then
  stop_args+=("+STOP_AFTER_LAYER=${STOP_AFTER_LAYER}")
fi

"${build_dir}/V${top}" "${stop_args[@]}" \
  | tee "$evidence_dir/pure_rs_full_graph_counter_profile.log"

python3 measurements/paper_comparison/parse_full_graph_counter_sim.py
