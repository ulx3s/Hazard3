# Shared ULX3S source list. Device profiles select the full EBR framebuffer
# (85F) or external-SDRAM line-buffered scanout (12F) in fpga_ulx3s.v.
file fpga_ulx3s.v
file pll_25_50.v
file pll_25_40.v
file pll_25_50_250.v
file ulx3s_hdmi_test_pattern.v
file ulx3s_hdmi_framebuffer.v
file ulx3s_hdmi_sdram_scanout.v
file ../libfpga/common/reset_sync.v
file ../libfpga/common/fpga_reset.v
file ../libfpga/common/ddr_out.v
file ../libfpga/common/popcount.v
file ../libfpga/video/tmds_encode.v

list ../soc/soc.f

# ECP5 DTM is not in main SoC list because the JTAGG primitive doesn't exist
# on most platforms
list ../../hdl/debug/dtm/hazard3_ecp5_jtag_dtm.f

