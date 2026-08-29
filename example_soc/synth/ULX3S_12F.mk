# ULX3S 12F compact Hazard3-Doom target.
# Board wiring is shared with ULX3S 85F; only the ECP5 density and resource
# profile differ. Full video frames and the monitor live in external SDRAM.

include ../project_paths.mk

CHIPNAME=fpga_ulx3s_12f
TOP=fpga_ulx3s
DOTF=../fpga/fpga_ulx3s.f
LPF=fpga_ulx3s.lpf

DEFINES += HAZARD3_ULX3S_12F

HAZARD3_MEMORY_PROFILE ?= 32m
ifeq ($(HAZARD3_MEMORY_PROFILE),32m)
DEFINES += HAZARD3_SDRAM_32MB
else ifneq ($(HAZARD3_MEMORY_PROFILE),64m)
$(error HAZARD3_MEMORY_PROFILE must be 32m or 64m)
endif

HAZARD3_HDMI_EXTENDED_MODES ?= 0
ifneq ($(HAZARD3_HDMI_EXTENDED_MODES),0)
$(error ULX3S 12F supports only the compact 320x200 video profile)
endif

SYNTH_OPT=-abc9
# ULX3S 12F is a speed-grade-6 LFE5U device. Keep the native nextpnr 12k
# selector; modern nextpnr maps it through the shared 12F/25F chip database.
PNR_OPT=--speed 6

DEVICE=12k
PACKAGE=CABGA381
DEVICE_IDCODE=0x21111043

include $(SCRIPTS)/synth_ecp5.mk

$(CHIPNAME).json: ../soc/cache_tags_zero_12f.hex ../soc/hazard3-12f-bootstrap.hex

# The ULX3S 12F and 85F use the same board constraints. The shared top-level
# integration flow passes fpga_ulx3s.lpf explicitly to nextpnr.

# Get ujprog from: git@github.com:emard/tools.git
prog: bit
	ujprog $(CHIPNAME).bit

flash: bit
	ujprog -j flash $(CHIPNAME).bit

clean::
	rm -f $(CHIPNAME).config $(CHIPNAME).svf $(CHIPNAME).memory-profile
