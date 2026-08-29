include ../project_paths.mk

CHIPNAME=fpga_ulx4m_ld
TOP=fpga_ulx4m_ld
DOTF=../fpga/fpga_ulx4m_ld.f

SYNTH_OPT=-abc9
# Bring-up target: timing failures remain visible in the nextpnr report.
PNR_OPT=--timing-allow-fail --speed 8

DEVICE=um-85k
DEVICE_IDCODE=0x01113043
PACKAGE=CABGA381

include $(SCRIPTS)/synth_ecp5.mk

LITEDRAM_GENERATED_FILES= \
    ../third_party/LiteDRAM/generated/litedram_ulx4m_cpu.v \
    ../third_party/LiteDRAM/generated/litedram_ulx4m_cpu_rom.init \
    ../third_party/LiteDRAM/generated/litedram_ulx4m_cpu_sram.init

# Power-up initialization files for the resident monitor, LiteDRAM, and cache.
$(CHIPNAME).json: ../soc/cache_tags_zero.hex ../soc/hazard3-boot-monitor.hex $(LITEDRAM_GENERATED_FILES)

../soc/hazard3-boot-monitor.hex:
	@echo "Missing $@; run Hazard3-Doom/scripts/build-ulx4m-ld-doom.sh to build the resident monitor preload." >&2
	@false

# Load through the ULX4M module DFU bootloader.
dfu: bit
	dfu-util -a 0 -D $(CHIPNAME).bit -R

.PHONY: dfu
