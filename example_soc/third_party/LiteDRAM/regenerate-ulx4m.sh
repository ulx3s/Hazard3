#!/bin/bash
# -----------------------------------------------------------------------------
# File:        regenerate-ulx4m.sh
# Path:        example_soc/third_party/LiteDRAM/regenerate-ulx4m.sh
#
# Project:     Hazard3-Doom
# Purpose:     Regenerate ULX4M-LD LiteDRAM cores for a DDR3 part number.
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

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="${SCRIPT_DIR}/configs"
GENERATOR="${SCRIPT_DIR}/regenerate-ulx4m.py"

usage()
{
    cat <<'USAGE'
Usage: ./regenerate-ulx4m.sh <RAM_PART_NUMBER>

Regenerate both SERV and VexRisc ULX4M-LD LiteDRAM cores from checked-in
configuration files.

Supported RAM part numbers:
  MT41K512M16HA
  AS4C256M16D3

Outputs:
  SERV     -> generated-serv/
  VexRisc  -> generated-vexrisc/

The selected RAM part replaces both generated CPU variants. Build only for a
board containing the same DDR3 part recorded in LITEDRAM_VERSIONS.txt.
USAGE
}

require_tool()
{
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required tool: %s\n' "$1" >&2
        exit 1
    }
}

if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi
if (( $# != 1 )); then
    usage >&2
    exit 2
fi

RAM_PART="$1"
if [[ ! -d "${CONFIG_ROOT}/${RAM_PART}" ]]; then
    printf 'Unsupported RAM part number: %s\n\n' "${RAM_PART}" >&2
    usage >&2
    exit 2
fi

require_tool python3
require_tool make
require_tool ninja
require_tool meson

if ! command -v riscv32-unknown-elf-gcc >/dev/null 2>&1 &&
   ! command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
    echo "Missing RISC-V GCC toolchain required to build the LiteX BIOS." >&2
    echo 'Install the toolchain and add its bin directory to PATH.' >&2
    exit 1
fi

exec python3 "${GENERATOR}" "${RAM_PART}"
