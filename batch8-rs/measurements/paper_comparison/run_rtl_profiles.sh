#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
profile_dir="$project_dir/measurements/paper_comparison"
verilator_bin="${VERILATOR_BIN:-$(command -v verilator || true)}"
if [[ -z "$verilator_bin" || ! -x "$verilator_bin" ]]; then
  echo "Verilator was not found. Install it or set VERILATOR_BIN." >&2
  exit 1
fi

mkdir -p "$profile_dir/build" "$profile_dir/evidence"

"$verilator_bin" --binary -j 4 --timing -Wall -Wno-fatal \
  --Mdir "$profile_dir/build/pure_rs_scheduler_profile" \
  --top-module tb_pure_rs_scheduler_profile \
  "$project_dir/rtl/alexnet_eyeriss_rs_batch8_pass_scheduler.sv" \
  "$profile_dir/tb/tb_pure_rs_scheduler_profile.sv" \
  >"$profile_dir/evidence/pure_rs_scheduler_build.log" 2>&1
"$profile_dir/build/pure_rs_scheduler_profile/Vtb_pure_rs_scheduler_profile" \
  | tee "$profile_dir/evidence/pure_rs_scheduler_profile.log"
