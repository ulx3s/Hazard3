# LiteDRAM generated core

This directory contains the generated LiteDRAM 2024.12 / LiteX 2024.12
ECP5DDRPHY core used by the ULX4M-LD target. The fitted DRAM is a Micron
MT41K512M16HA-125 (D9SWB), 8 Gbit x16 DDR3L device.

The core receives the board's 25 MHz oscillator and generates a 75 MHz
LiteDRAM user clock and 150 MHz DDR clock. Hazard3 runs independently at the
board-build system clock and crosses to the generated Wishbone port through
`soc/ahb_litedram.v`.

The 8-Gbit device uses 16 row-address signals (`ddram_a[15:0]`); A15 is FPGA
pin P18 on ULX4M-LD. The generated 1-GiB core exposes a 26-bit 128-bit-word
Wishbone address. The adapter preserves the current 64-MiB Hazard3/Doom memory
window by keeping the upper four Wishbone word-address bits at zero.

`generated-serv/LITEDRAM_VERSIONS.txt` and
`generated-vexrisc/LITEDRAM_VERSIONS.txt` record the exact runtime build IDs
and clock configuration for each generated CPU variant.

## SERV

```
cpu: serv
cpu_variant: standard
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
```

Versions

```
ULX4M-LD-LITEDRAM-SERV-20260829
LiteDRAM=2024.12
LiteX=2024.12
Migen=0.9.2
pythondata-cpu-serv=1.2.0.post146
SERV_variant=standard
FPGA=LFE5UM-85F-8BG381C
litedram_input_clock_hz=25000000
hazard3_system_clock_hz=50000000
litedram_sys_clock_hz=75000000
ddr_clock_hz=150000000
memory_class=MT41K512M16
memory_geometry=16-row,10-column,3-bank,x16,8-Gbit
FPGA_BUILD_ID=0x4C445035
DDR_CORE_BUILD_ID=0x32343132
DDR_ADAPTER_BUILD_ID=0x41444C35
FIRMWARE_BUILD_ID=0x48335235
DOOM_IMAGE_BUILD_ID=0x44335235
```

## VexRISC-V

```
cpu: vexriscv
cpu_variant: minimal
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
```

Versions

```
LiteDRAM=2024.12
LiteX=2024.12
Migen=0.9.2
pythondata-cpu-vexriscv=1.0.1.post407
VexRiscv_variant=minimal
```