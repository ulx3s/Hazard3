# LiteDRAM generated core

This directory contains the LiteDRAM 2024.12 / LiteX 2024.12 ECP5DDRPHY core
used by the ULX4M-LD target. ULX4M-LD boards may contain either of these x16
DDR3 devices:

| Board part number | LiteDRAM module class | Capacity |
| --- | --- | ---: |
| Micron `MT41K512M16HA` | `MT41K512M16` | 1 GiB |
| Alliance `AS4C256M16D3` | `AS4C256M16D3A` | 512 MiB |

The core receives the board's 25 MHz oscillator and generates a 60 MHz
LiteDRAM user clock and 120 MHz DDR clock. Hazard3 runs independently at the
board-build system clock and crosses to the generated Wishbone port through
`soc/ahb_litedram.v`.

## Regeneration

The checked-in YAML files beneath `configs/` are the source of truth for RAM
geometry, LiteDRAM settings, and initialization CPU. Select the physical RAM
part number when regenerating:

```bash
./regenerate-ulx4m.sh MT41K512M16HA
./regenerate-ulx4m.sh AS4C256M16D3
```

Each command regenerates both CPU variants:

```text
generated-serv/
generated-vexrisc/
```

The generated directories therefore contain one RAM profile at a time. Before
building or testing a board, check `LITEDRAM_VERSIONS.txt` in the selected CPU
directory and confirm that `ram_part` matches the fitted DDR3 device.

`regenerate-ulx4m.sh` performs host-tool checks. The Python implementation in
`regenerate-ulx4m.py` verifies pinned LiteX packages, installs the pinned CPU
and software-data packages into an isolated temporary directory, invokes
LiteDRAM, embeds the selected CPU RTL, normalizes initialization-file paths,
and records the selected source profile. Set `HAZARD3_ULX4M_REUSE_TMP` to a
preserved temporary directory when continuing a failed generation attempt.

The manually maintained `litedram_ulx4m_cpu.v` wrapper selects SERV or VexRisc
at FPGA build time. Generated Verilog and initialization files must not be
edited manually.

The Micron core exposes 16 row-address bits and a 26-bit, 128-bit-word
Wishbone address. The Alliance core exposes 15 row-address bits and a 25-bit
Wishbone address because the device has half the density. Both capacities are
larger than the 64 MiB external-memory window currently exposed by
Hazard3-Doom.
