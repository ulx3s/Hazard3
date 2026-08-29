# ULX3S target with cached external SDR SDRAM and an indexed HDMI framebuffer.
# The ULX3S 12K does not have enough EBR capacity for the CPU SRAM, cache,
# framebuffers, and palette RAM used by this hardware configuration.

include ../project_paths.mk

CHIPNAME=fpga_ulx3s
TOP=fpga_ulx3s
DOTF=../fpga/fpga_ulx3s.f

HAZARD3_HDMI_EXTENDED_MODES ?= 1
ifeq ($(HAZARD3_HDMI_EXTENDED_MODES),1)
DEFINES += HAZARD3_HDMI_EXTENDED_MODES
else ifneq ($(HAZARD3_HDMI_EXTENDED_MODES),0)
$(error HAZARD3_HDMI_EXTENDED_MODES must be 0 or 1)
endif

SYNTH_OPT=-abc9
# Bring-up target: timing failures remain visible in the nextpnr report.
PNR_OPT=--timing-allow-fail

DEVICE=um5g-85k
PACKAGE=CABGA381

include $(SCRIPTS)/synth_ecp5.mk

# power-up initialization file for the new SDRAM cache tag RAM
$(CHIPNAME).json: ../soc/cache_tags_zero.hex ../soc/hazard3-boot-monitor.hex

../soc/hazard3-boot-monitor.hex:
	@echo "Missing $@; run Hazard3-Doom/scripts/build-ulx3s-doom.sh to build the resident monitor preload." >&2
	@false

# Get ujprog from: git@github.com:emard/tools.git
prog: bit
	ujprog $(CHIPNAME).bit

flash: bit
	ujprog -j flash $(CHIPNAME).bit
