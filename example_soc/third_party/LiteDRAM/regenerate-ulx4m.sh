#!/bin/bash
# -----------------------------------------------------------------------------
# File:           regenerate-ulx4m.sh
# Path (repo)     \example_soc\third_party\LiteDRAM\regenerate-ulx4m.sh
# Path (project): \third_party\Hazard3\example_soc\third_party\LiteDRAM\regenerate-ulx4m.sh
#
# Project:     Hazard3-Doom
# Purpose:     Generate LiteDRAM code
#
# Copyright (c) 2026 gojimmypi
#
# Licensed under the Apache License, Version 2.0.
#
# SPDX-License-Identifier: Apache-2.0
#
# This software is provided under the terms of the applicable license.
# See LICENSES/Apache-2.0.txt for the complete license terms.
# See LICENSING.md for project licensing policy and scope.
# -----------------------------------------------------------------------------

# Physical DRAM:  Micron MT41K512M16HA-125
# Marking:        D9SWB
# Organization:   512M x 16
# Capacity:       8 Gbit = 1 GiB
# Type:           DDR3L
# Speed grade:    -125 = DDR3-1600
# Package:        96-ball FBGA
#
# Benign warnings in this run:
#
#   Meson 1.12.0 prints: WARNING: Unknown CPU family riscv
#
#   WARNING: Broken features used:
#   * 1.3.0: {'str.format: Value other than strings, integers, bools, options, dictionaries and lists thereof.'}
#
#   WARNING: Running the setup command as `meson [options]` instead of `meson setup [options]` is ambiguous and deprecated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_NAME="litedram_ulx4m_cpu"

usage()
{
    cat <<'USAGE'
Usage: ./regenerate-ulx4m.sh <serv|vexrisc>

Generate the ULX4M-LD LiteDRAM core for the selected LiteX CPU.

Outputs:
  serv      -> generated-serv/
  vexrisc   -> generated-vexrisc/

The generated directories are build artifacts. The manually maintained
litedram_ulx4m_cpu.v wrapper selects one of them at FPGA build time.
USAGE
}

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

CPU="$1"
case "${CPU}" in
    serv)
        CPU_VARIANT="standard"
        CPU_PACKAGE="pythondata-cpu-serv"
        CPU_PACKAGE_VERSION="1.2.0.post146"
        GENERATED_DIR="${SCRIPT_DIR}/generated-serv"
        GENERATED_REL="../third_party/LiteDRAM/generated-serv"
        LEGACY_REUSE_TMP="${HAZARD3_ULX4M_SERV_REUSE_TMP:-}"
        ;;
    vexrisc|vexriscv|vex)
        CPU="vexriscv"
        CPU_VARIANT="minimal"
        CPU_PACKAGE="pythondata-cpu-vexriscv"
        CPU_PACKAGE_VERSION="1.0.1.post407"
        GENERATED_DIR="${SCRIPT_DIR}/generated-vexrisc"
        GENERATED_REL="../third_party/LiteDRAM/generated-vexrisc"
        LEGACY_REUSE_TMP="${HAZARD3_ULX4M_VEXRISCV_REUSE_TMP:-}"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        printf 'Unsupported CPU type: %s\n\n' "${CPU}" >&2
        usage >&2
        exit 2
        ;;
esac

require_tool()
{
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required tool: %s\n' "$1" >&2
        exit 1
    }
}

require_tool python3
require_tool make
require_tool ninja

if ! command -v riscv32-unknown-elf-gcc >/dev/null 2>&1 &&
   ! command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
    echo "Missing RISC-V GCC toolchain required to build the LiteX BIOS." >&2
    echo "Check toolchain is installed and included in path:  export PATH=\"/opt/riscv/bin:\${PATH}\""  >&2
    exit 1
fi

if ! command -v meson >/dev/null 2>&1; then
    echo "Installing Meson required to build the LiteX BIOS."
    python3 -m pip install --user meson
fi
require_tool meson

python3 - <<'PY'
from importlib.metadata import PackageNotFoundError, version

expected = {
    "litex": "2024.12",
    "litedram": "2024.12",
    "migen": "0.9.2",
}

failed = False
for package, wanted in expected.items():
    try:
        actual = version(package)
    except PackageNotFoundError:
        print(f"Missing Python package: {package}=={wanted}")
        failed = True
        continue
    print(f"{package}={actual}")
    if actual != wanted:
        print(f"ERROR: expected {package}=={wanted}, found {actual}")
        failed = True

if failed:
    raise SystemExit(1)
PY

mkdir -p "${GENERATED_DIR}"

reuse_tmp="${HAZARD3_ULX4M_REUSE_TMP:-${LEGACY_REUSE_TMP}}"
if [[ -n "${reuse_tmp}" ]]; then
    tmp_dir="${reuse_tmp}"
    build_dir="${tmp_dir}/build"
    pydata_dir="${tmp_dir}/pydata"
    config_tmp="${tmp_dir}/${CORE_NAME}.yml"

    [[ -d "${build_dir}" ]] || {
        printf 'Saved LiteDRAM build directory not found: %s\n' "${build_dir}" >&2
        exit 1
    }
    [[ -d "${pydata_dir}" ]] || {
        printf 'Saved Python-data directory not found: %s\n' "${pydata_dir}" >&2
        exit 1
    }
    [[ -f "${config_tmp}" ]] || {
        printf 'Saved LiteDRAM config not found: %s\n' "${config_tmp}" >&2
        exit 1
    }

    printf 'Reusing completed LiteDRAM build: %s\n' "${tmp_dir}"
else
    tmp_dir="$(mktemp -d)"
    cleanup()
    {
        local status=$?

        if (( status == 0 )); then
            rm -rf "${tmp_dir}"
        else
            printf 'Generation failed; preserving temporary directory: %s\n' "${tmp_dir}" >&2
        fi
    }
    trap cleanup EXIT

    build_dir="${tmp_dir}/build"
    pydata_dir="${tmp_dir}/pydata"
    config_tmp="${tmp_dir}/${CORE_NAME}.yml"

    cat > "${config_tmp}" <<EOF_CONFIG
cpu: ${CPU}
cpu_variant: ${CPU_VARIANT}
uart: fifo
device: LFE5UM-85F-8BG381C
memtype: DDR3
sdram_module: MT41K512M16
sdram_module_nb: 2
sdram_rank_nb: 1
sdram_phy: ECP5DDRPHY
input_clk_freq: 25e6
sys_clk_freq: 75e6
init_clk_freq: 25e6
user_ports:
  wb:
    type: wishbone
    data_width: 128
EOF_CONFIG

    printf 'Preparing isolated LiteX software-data packages for %s/%s...\n' \
        "${CPU}" "${CPU_VARIANT}"
    python3 -m pip install \
        --disable-pip-version-check \
        --no-cache-dir \
        --no-deps \
        --target "${pydata_dir}" \
        "${CPU_PACKAGE}==${CPU_PACKAGE_VERSION}" \
        "pythondata-software-picolibc==1.7.9.post181" \
        "pythondata-software-compiler-rt==0.0.post6206"

    PYTHONPATH="${pydata_dir}${PYTHONPATH:+:${PYTHONPATH}}" \
        python3 - "${CPU_PACKAGE}" "${CPU_PACKAGE_VERSION}" <<'PY'
from importlib.metadata import PackageNotFoundError, version
import sys

package, wanted = sys.argv[1:]
try:
    actual = version(package)
except PackageNotFoundError:
    raise SystemExit(f"Missing isolated Python package: {package}=={wanted}")

print(f"{package}={actual}")
if actual != wanted:
    raise SystemExit(f"Expected {package}=={wanted}; found {actual}")
PY

    PYTHONPATH="${pydata_dir}${PYTHONPATH:+:${PYTHONPATH}}" python3 - <<'PY'
from pathlib import Path
import re
import pythondata_software_picolibc

meson_build = Path(pythondata_software_picolibc.data_location) / "meson.build"
text = meson_build.read_text(encoding="utf-8")
match = re.search(r"^[ \t]*version\s*:\s*['\"]([^'\"]+)['\"]", text, re.MULTILINE)
if match is None:
    raise SystemExit(f"Could not determine Picolibc source version from {meson_build}")
print(f"picolibc-source={match.group(1)}")
if match.group(1) != "1.7.9":
    raise SystemExit(
        f"Expected Picolibc source 1.7.9 for LiteX 2024.12; found {match.group(1)}"
    )
PY

    PYTHONPATH="${pydata_dir}${PYTHONPATH:+:${PYTHONPATH}}" python3 -m litedram.gen \
        "${config_tmp}" \
        --name "${CORE_NAME}" \
        --output-dir "${build_dir}"
fi

find_one()
{
    local pattern="$1"
    local result

    result="$(find "${build_dir}" -type f -name "${pattern}" -print -quit)"
    [[ -n "${result}" ]] || {
        printf 'Generated file not found: %s\n' "${pattern}" >&2
        exit 1
    }
    printf '%s\n' "${result}"
}

generated_v="$(find_one "${CORE_NAME}.v")"
generated_rom="$(find_one "${CORE_NAME}_rom.init")"
generated_sram="$(find "${build_dir}" -type f -name "${CORE_NAME}_sram.init" -print -quit)"

if [[ -z "${generated_sram}" ]]; then
    generated_sram="${tmp_dir}/${CORE_NAME}_sram.init"
    : > "${generated_sram}"
fi

python3 - "${generated_v}" "${GENERATED_REL}" "${CPU}" "${CPU_VARIANT}" \
    "${CPU_PACKAGE}" "${CPU_PACKAGE_VERSION}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
generated_rel, cpu, cpu_variant, cpu_package, cpu_package_version = sys.argv[2:]
text = path.read_text(encoding="utf-8")

for suffix in ("rom.init", "sram.init"):
    name = f"litedram_ulx4m_cpu_{suffix}"
    replacement = f'$readmemh("{generated_rel}/{name}"'
    pattern = rf'\$readmemh\("[^"]*{re.escape(name)}"'
    text, count = re.subn(pattern, replacement, text)
    if count != 1:
        raise SystemExit(f"Expected exactly one $readmemh reference for {name}; found {count}")

header = f"""// ULX4M-LD LiteDRAM generated core.
// LiteDRAM 2024.12, LiteX 2024.12, Migen 0.9.2
// CPU: {cpu} ({cpu_variant}); {cpu_package} {cpu_package_version}
// FPGA: LFE5UM-85F-8BG381C; input 25 MHz; LiteDRAM sys 75 MHz; DDR3-300.
// Generated by regenerate-ulx4m.sh. Do not edit this file manually.
// -----------------------------------------------------------------------------
"""

if not text.startswith("// ULX4M-LD LiteDRAM generated core."):
    text = header + text

path.write_text(text, encoding="utf-8", newline="\n")
PY

case "${CPU}" in
    serv)
        grep -Fq 'serv_rf_top' "${generated_v}" || {
            echo "Generated core does not instantiate SERV module serv_rf_top." >&2
            exit 1
        }
        if grep -Eq '^[[:space:]]*module[[:space:]]+VexRiscv([[:space:]#(]|$)' "${generated_v}"; then
            echo "Generated SERV core unexpectedly contains VexRiscv." >&2
            exit 1
        fi

        if ! grep -Eq '^[[:space:]]*module[[:space:]]+serv_rf_top([[:space:]#(]|$)' "${generated_v}"; then
            PYTHONPATH="${pydata_dir}${PYTHONPATH:+:${PYTHONPATH}}" \
                python3 - "${generated_v}" <<'PY'
from pathlib import Path
import sys
import pythondata_cpu_serv

output = Path(sys.argv[1])
package_dir = Path(pythondata_cpu_serv.__file__).resolve().parent
roots = []
for value in (getattr(pythondata_cpu_serv, "data_location", None), package_dir):
    if value is not None:
        root = Path(value).resolve()
        roots.extend((root, root / "verilog"))

rtl_dir = None
for root in roots:
    candidate = root / "rtl"
    if (candidate / "serv_rf_top.v").is_file():
        rtl_dir = candidate
        break

if rtl_dir is None:
    raise SystemExit(
        f"Could not locate SERV RTL below pythondata_cpu_serv package {package_dir}"
    )

sources = sorted(rtl_dir.glob("serv_*.v"))
required = {
    "serv_rf_top.v",
    "serv_top.v",
    "serv_state.v",
    "serv_decode.v",
    "serv_alu.v",
}
missing = sorted(required - {path.name for path in sources})
if missing:
    raise SystemExit("Missing required SERV RTL: " + ", ".join(missing))

with output.open("a", encoding="utf-8", newline="\n") as dst:
    dst.write("\n")
    for source in sources:
        text = source.read_text(encoding="utf-8")
        dst.write(text)
        if not text.endswith("\n"):
            dst.write("\n")

print(f"Embedded {len(sources)} SERV RTL source files from {rtl_dir}")
PY
        fi

        grep -Eq '^[[:space:]]*module[[:space:]]+serv_rf_top([[:space:]#(]|$)' "${generated_v}" || {
            echo "Combined generated core still does not define SERV module serv_rf_top." >&2
            exit 1
        }
        ;;

    vexriscv)
        grep -Fq 'VexRiscv VexRiscv' "${generated_v}" || {
            echo "Generated core does not instantiate VexRiscv." >&2
            exit 1
        }
        if grep -Eq '^[[:space:]]*module[[:space:]]+serv_rf_top([[:space:]#(]|$)' "${generated_v}"; then
            echo "Generated VexRiscv core unexpectedly contains SERV." >&2
            exit 1
        fi

        if ! grep -Eq '^[[:space:]]*module[[:space:]]+VexRiscv([[:space:]#(]|$)' "${generated_v}"; then
            PYTHONPATH="${pydata_dir}${PYTHONPATH:+:${PYTHONPATH}}" \
                python3 - "${generated_v}" <<'PY'
from pathlib import Path
import re
import sys
from pythondata_cpu_vexriscv import data_file

output = Path(sys.argv[1])
source = Path(data_file("VexRiscv_Min.v"))
text = source.read_text(encoding="utf-8")

if re.search(r"^\s*module\s+VexRiscv(?:\s|#|\(|$)", text, re.MULTILINE) is None:
    raise SystemExit(f"{source} does not define module VexRiscv")

with output.open("a", encoding="utf-8", newline="\n") as dst:
    dst.write("\n")
    dst.write(text)
    if not text.endswith("\n"):
        dst.write("\n")

print(f"Embedded VexRiscv minimal RTL from {source}")
PY
        fi

        grep -Eq '^[[:space:]]*module[[:space:]]+VexRiscv([[:space:]#(]|$)' "${generated_v}" || {
            echo "Combined generated core still does not define VexRiscv." >&2
            exit 1
        }
        ;;
esac

for suffix in rom.init sram.init; do
    expected_path="${GENERATED_REL}/${CORE_NAME}_${suffix}"
    grep -Fq "${expected_path}" "${generated_v}" || {
        printf 'Generated core %s path was not normalized to %s.\n' \
            "${suffix}" "${expected_path}" >&2
        exit 1
    }
done

install -m 0644 "${config_tmp}" "${GENERATED_DIR}/${CORE_NAME}.yml"
install -m 0644 "${generated_v}" "${GENERATED_DIR}/${CORE_NAME}.v"
install -m 0644 "${generated_rom}" "${GENERATED_DIR}/${CORE_NAME}_rom.init"
install -m 0644 "${generated_sram}" "${GENERATED_DIR}/${CORE_NAME}_sram.init"

cat > "${GENERATED_DIR}/LITEDRAM_VERSIONS.txt" <<EOF_VERSIONS
ULX4M-LD-LITEDRAM-PERFORMANCE-R5-20260716
LiteDRAM=2024.12
LiteX=2024.12
Migen=0.9.2
CPU=${CPU}
CPU_variant=${CPU_VARIANT}
${CPU_PACKAGE}=${CPU_PACKAGE_VERSION}
FPGA=LFE5UM-85F-8BG381C
litedram_input_clock_hz=25000000
hazard3_system_clock_hz=50000000
litedram_sys_clock_hz=75000000
ddr_clock_hz=150000000
memory_class=MT41K512M16
memory_geometry=16-row,10-column,3-bank,x16,8-Gbit
memory_modules=2
memory_ranks=1
user_port=wishbone
user_port_data_width=128
FPGA_BUILD_ID=0x4C445035
DDR_CORE_BUILD_ID=0x32343132
DDR_ADAPTER_BUILD_ID=0x41444C35
FIRMWARE_BUILD_ID=0x48335235
DOOM_IMAGE_BUILD_ID=0x44335235
EOF_VERSIONS

printf '\nRegenerated ULX4M-LD LiteDRAM core for %s/%s.\n' "${CPU}" "${CPU_VARIANT}"
printf 'Output directory: %s\n' "${GENERATED_DIR}"
printf 'Updated: %s\n' "${GENERATED_DIR}/${CORE_NAME}.v"
printf 'Updated: %s\n' "${GENERATED_DIR}/${CORE_NAME}.yml"
printf 'Updated: %s\n' "${GENERATED_DIR}/${CORE_NAME}_rom.init"
printf 'Updated: %s\n' "${GENERATED_DIR}/${CORE_NAME}_sram.init"
printf 'Updated: %s\n' "${GENERATED_DIR}/LITEDRAM_VERSIONS.txt"
printf '\nReview with:\n'
printf '  (cd %q && git diff -- %q)\n' "${SCRIPT_DIR}" "$(basename "${GENERATED_DIR}")"
