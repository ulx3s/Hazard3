# Hazard3-Doom ULX5M-GS GateMate A1 target.

include ../project_paths.mk

CHIPNAME := fpga_ulx5m_gs
TOP := fpga_ulx5m_gs
DOTF := ../fpga/fpga_ulx5m_gs.f
DEVICE ?= CCGM1A1
CCF := fpga_ulx5m_gs.ccf
SDC := fpga_ulx5m_gs.sdc
BUILD_DIR ?= build_ulx5m_gs

YOSYS ?= yosys
NEXTPNR ?= nextpnr-himbaechel
GMPACK ?= gmpack

ULX5M_SYS_CLK_MHZ ?= 25

DEFINES += FPGA FPGA_GATEMATE HAS_REGISTERED_READ_HITS HAZARD3_SDRAM_32MB
ifeq ($(ULX5M_SYS_CLK_MHZ),12)
DEFINES += ULX5M_SYS_CLK_12M
else ifeq ($(ULX5M_SYS_CLK_MHZ),20)
DEFINES += ULX5M_SYS_CLK_20M
else ifeq ($(ULX5M_SYS_CLK_MHZ),25)
else
$(error ULX5M_SYS_CLK_MHZ must be 12, 20 or 25)
endif

PNR_OPT ?= --placer-heap-beta=0.6

SRCS = $(shell PROJ_ROOT=$(PROJ_ROOT) HDL=$(HDL) $(SCRIPTS)/listfiles --relative -f flat $(DOTF))
INCDIRS = $(shell PROJ_ROOT=$(PROJ_ROOT) HDL=$(HDL) $(SCRIPTS)/listfiles --relative -f flati $(DOTF))

JSON := $(BUILD_DIR)/$(CHIPNAME).json
IMPL := $(BUILD_DIR)/$(CHIPNAME).txt
BIT := $(BUILD_DIR)/$(CHIPNAME).bit
SYNTH_LOG := $(BUILD_DIR)/synth.log
PNR_LOG := $(BUILD_DIR)/pnr.log

SYNTH_CMD = read_verilog $(addprefix -I,$(INCDIRS)) $(addprefix -D,$(DEFINES)) $(SRCS); \
	synth_gatemate -top $(TOP) -luttree -nomx8 -json $(abspath $(JSON))

.PHONY: all synth pnr bit clean
all: bit
synth: $(JSON)
pnr: $(IMPL)
bit: $(BIT)

$(BUILD_DIR):
	mkdir -p $@

$(JSON): $(SRCS) ../soc/cache_tags_zero_12f.hex ../soc/hazard3-boot-monitor.hex | $(BUILD_DIR)
	@echo ">>> GateMate synthesis"
	$(YOSYS) -p "$(SYNTH_CMD)" > $(SYNTH_LOG)
	tail -n 40 $(SYNTH_LOG)

$(IMPL): $(JSON) $(CCF) $(SDC)
	@echo ">>> GateMate place and route"
	$(NEXTPNR) \
		--device $(DEVICE) \
		--json $(abspath $(JSON)) \
		-o ccf=$(abspath $(CCF)) \
		-o out=$(abspath $(IMPL)) \
		--sdc $(abspath $(SDC)) \
		--router router2 \
		$(PNR_OPT) \
		-l $(abspath $(PNR_LOG))

$(BIT): $(IMPL)
	@echo ">>> GateMate bitstream"
	$(GMPACK) $(abspath $(IMPL)) $(abspath $(BIT))

clean:
	rm -rf $(BUILD_DIR)
