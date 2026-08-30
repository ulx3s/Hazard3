// SPDX-License-Identifier: CERN-OHL-W-2.0
//
// Manually maintained ULX4M-LD LiteDRAM generated-core selector.
//
// Define exactly one of the following when this file is read by Yosys:
//
//   HAZARD3_ULX4M_CPU_SERV
//   HAZARD3_ULX4M_CPU_VEXRISCV
//
// The selected generated core contains the litedram_ulx4m_cpu module and
// the matching LiteX CPU RTL. Generated files must not be edited manually.

`ifdef HAZARD3_ULX4M_CPU_SERV
    `ifdef HAZARD3_ULX4M_CPU_VEXRISCV
        HAZARD3_ULX4M_ERROR_DEFINE_ONLY_ONE_CPU_TYPE
    `else
        `include "../third_party/LiteDRAM/generated-serv/litedram_ulx4m_cpu.v"
    `endif
`elsif HAZARD3_ULX4M_CPU_VEXRISCV
    `include "../third_party/LiteDRAM/generated-vexrisc/litedram_ulx4m_cpu.v"
`else
    HAZARD3_ULX4M_ERROR_CPU_TYPE_NOT_DEFINED
`endif
