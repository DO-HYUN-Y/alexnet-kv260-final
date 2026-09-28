#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
software_dir=$(cd "${script_dir}/.." && pwd)
project_dir=$(cd "${software_dir}/../.." && pwd)
bitstream="${ALEXNET_BITSTREAM:-${project_dir}/release/alexnet_m8n126_graph_kv260_ddr_counters.bit}"
build_dir="${software_dir}/build/firmware"

if [[ ! -f "${bitstream}" ]]; then
    echo "Missing bitstream: ${bitstream}" >&2
    exit 1
fi

if [[ -n "${BOOTGEN:-}" ]]; then
    bootgen_bin=${BOOTGEN}
elif command -v bootgen >/dev/null 2>&1; then
    bootgen_bin=$(command -v bootgen)
elif [[ -n "${XILINX_VIVADO:-}" && -x "${XILINX_VIVADO}/bin/bootgen" ]]; then
    bootgen_bin="${XILINX_VIVADO}/bin/bootgen"
else
    echo "bootgen is unavailable; set BOOTGEN or XILINX_VIVADO" >&2
    exit 1
fi

if [[ -n "${DTC:-}" ]]; then
    dtc_bin=${DTC}
elif command -v dtc >/dev/null 2>&1; then
    dtc_bin=$(command -v dtc)
elif [[ -x "$(dirname "${bootgen_bin}")/dtc" ]]; then
    dtc_bin="$(dirname "${bootgen_bin}")/dtc"
else
    echo "dtc is unavailable; set DTC" >&2
    exit 1
fi

mkdir -p "${build_dir}"
cp "${bitstream}" "${build_dir}/alexnet_m8n126_graph_kv260.bit"
cp "${software_dir}/firmware/alexnet_kv260.bif" \
    "${build_dir}/alexnet_kv260.bif"

(
    cd "${build_dir}"
    "${bootgen_bin}" -image alexnet_kv260.bif -arch zynqmp -w on \
        -process_bitstream bin
)

"${dtc_bin}" -@ -I dts -O dtb \
    -o "${build_dir}/alexnet_m8n126_graph_kv260.dtbo" \
    "${software_dir}/overlay/alexnet_kv260.dts"

test -s "${build_dir}/alexnet_m8n126_graph_kv260.bit.bin"
test -s "${build_dir}/alexnet_m8n126_graph_kv260.dtbo"
(
    cd "${build_dir}"
    sha256sum \
        alexnet_m8n126_graph_kv260.bit.bin \
        alexnet_m8n126_graph_kv260.dtbo \
        > alexnet_m8n126_graph_kv260.SHA256SUMS
    sha256sum -c alexnet_m8n126_graph_kv260.SHA256SUMS
)
echo "ALEXNET_KV260_FIRMWARE_PACKAGE_PASS"
