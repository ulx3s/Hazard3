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

ULX4M_LITEDRAM_CPU ?= serv

ifeq ($(ULX4M_LITEDRAM_CPU),serv)
LITEDRAM_GENERATED_DIR=../third_party/LiteDRAM/generated-serv
LITEDRAM_CPU_DEFINE=HAZARD3_ULX4M_CPU_SERV
else ifeq ($(ULX4M_LITEDRAM_CPU),vexrisc)
LITEDRAM_GENERATED_DIR=../third_party/LiteDRAM/generated-vexrisc
LITEDRAM_CPU_DEFINE=HAZARD3_ULX4M_CPU_VEXRISCV
else
$(error ULX4M_LITEDRAM_CPU must be serv or vexrisc)
endif

DEFINES += $(LITEDRAM_CPU_DEFINE)

include $(SCRIPTS)/synth_ecp5.mk

LITEDRAM_GENERATED_FILES= \
    ../third_party/LiteDRAM/litedram_ulx4m_cpu.v \
    $(LITEDRAM_GENERATED_DIR)/litedram_ulx4m_cpu.v \
    $(LITEDRAM_GENERATED_DIR)/litedram_ulx4m_cpu_rom.init \
    $(LITEDRAM_GENERATED_DIR)/litedram_ulx4m_cpu_sram.init

LITEDRAM_CPU_STAMP=$(CHIPNAME).litedram-cpu

.PHONY: check-litedram-cpu
check-litedram-cpu:
	@if [ "$$(cat "$(LITEDRAM_CPU_STAMP)" 2>/dev/null || true)" != "$(ULX4M_LITEDRAM_CPU)" ]; then \
		echo "ULX4M-LD LiteDRAM CPU changed to $(ULX4M_LITEDRAM_CPU); invalidating synthesized artifacts."; \
		rm -f \
			"$(CHIPNAME).json" \
			"$(CHIPNAME).config" \
			"$(CHIPNAME).bit" \
			"$(CHIPNAME).svf"; \
		printf '%s\n' "$(ULX4M_LITEDRAM_CPU)" > "$(LITEDRAM_CPU_STAMP)"; \
	fi

# Power-up initialization files for the resident monitor, LiteDRAM, and cache.
$(CHIPNAME).json: ../soc/cache_tags_zero.hex ../soc/hazard3-boot-monitor.hex $(LITEDRAM_GENERATED_FILES) | check-litedram-cpu

../soc/hazard3-boot-monitor.hex:
	@echo "Missing $@; run Hazard3-Doom/scripts/build-ulx4m-ld-doom.sh to build the resident monitor preload." >&2
	@false

# Load through the ULX4M module DFU bootloader.
dfu: bit
	dfu-util -a 0 -D $(CHIPNAME).bit -R

.PHONY: dfu
