/*****************************************************************************\
|                        Copyright (C) 2021 Luke Wren                         |
|                     SPDX-License-Identifier: Apache-2.0                     |
\*****************************************************************************/

`default_nettype none

module fpga_ulx4m_ls (
	input  wire       clk_osc,
	output wire [3:0] led,

	output wire       uart_tx,
	input  wire       uart_rx,

	output wire [3:0] gpdi_dp,
	output wire [3:0] gpdi_dn,

	output wire [12:0] sdram_a,
	output wire [1:0]  sdram_ba,
	inout  wire [15:0] sdram_d,
	output wire [1:0]  sdram_dqm,
	output wire        sdram_clk,
	output wire        sdram_cke,
	output wire        sdram_csn,
	output wire        sdram_rasn,
	output wire        sdram_casn,
	output wire        sdram_wen
);

wire clk_sys;
wire pll_sys_locked;
wire rst_n_sys;

pll_25_50 pll_sys (
	.clkin   (clk_osc),
	.clkout0 (clk_sys),
	.locked  (pll_sys_locked)
);

fpga_reset #(
	.SHIFT (3)
) rstgen (
	.clk         (clk_sys),
	.force_rst_n (pll_sys_locked),
	.rst_n       (rst_n_sys)
);

// Keep the proven Hazard3/SDRAM clock tree unchanged. The ULX4M-LS uses the
// same 25 MHz input clock and a 32 MiB, 16-bit SDR SDRAM interface. HDMI uses a
// second PLL, so video cannot disturb CPU, JTAG, UART or SDRAM timing.
wire clk_video_pix;
wire clk_tmds_x5;
wire pll_video_locked;
wire rst_n_video_pix;
wire rst_n_tmds_x5;

pll_25_50_250 pll_video (
	.clkin        (clk_osc),
	.clk_pix      (clk_video_pix),
	.clk_tmds_x5  (clk_tmds_x5),
	.locked       (pll_video_locked)
);

fpga_reset #(
	.SHIFT (3)
) rstgen_video_pix (
	.clk         (clk_video_pix),
	.force_rst_n (pll_video_locked),
	.rst_n       (rst_n_video_pix)
);

fpga_reset #(
	.SHIFT (3)
) rstgen_tmds (
	.clk         (clk_tmds_x5),
	.force_rst_n (pll_video_locked),
	.rst_n       (rst_n_tmds_x5)
);

`ifdef 0
ulx3s_hdmi_test_pattern hdmi_test_pattern_u (
	.clk_pix       (clk_video_pix),
	.rst_n_pix     (rst_n_video_pix),
	.clk_tmds_x5   (clk_tmds_x5),
	.rst_n_tmds_x5 (rst_n_tmds_x5),
	.gpdi_dp       (gpdi_dp)
);
`endif

wire [7:0] gpio_out;
assign led = gpio_out[3:0];

wire        video_sdram_req_valid;
wire        video_sdram_req_ready;
wire [24:0] video_sdram_req_addr;
wire        video_sdram_rsp_valid;
wire [15:0] video_sdram_rsp_rdata;
wire        video_sdram_init_done;

wire        video_apb_psel;
wire        video_apb_penable;
wire        video_apb_pwrite;
wire [15:0] video_apb_paddr;
wire [31:0] video_apb_pwdata;
wire [31:0] video_apb_prdata;
wire        video_apb_pready;
wire        video_apb_pslverr;

ulx3s_hdmi_framebuffer #(
    .FRAMEBUFFER0_HALFWORD_BASE      (25'h0e00000),
    .FRAMEBUFFER1_HALFWORD_BASE      (25'h0e08000),
    .FRAMEBUFFER1_HIGH_HALFWORD_BASE (25'h0e0c000)
) hdmi_framebuffer_u (
	.clk_sys          (clk_sys),
	.rst_n_sys        (rst_n_sys),
	.clk_pix          (clk_video_pix),
	.rst_n_pix        (rst_n_video_pix),
	.clk_tmds_x5      (clk_tmds_x5),
	.rst_n_tmds_x5    (rst_n_tmds_x5),

	.sdram_req_valid  (video_sdram_req_valid),
	.sdram_req_ready  (video_sdram_req_ready),
	.sdram_req_addr   (video_sdram_req_addr),
	.sdram_rsp_valid  (video_sdram_rsp_valid),
	.sdram_rsp_rdata  (video_sdram_rsp_rdata),
	.sdram_init_done  (video_sdram_init_done),

	.apbs_psel        (video_apb_psel),
	.apbs_penable     (video_apb_penable),
	.apbs_pwrite      (video_apb_pwrite),
	.apbs_paddr       (video_apb_paddr),
	.apbs_pwdata      (video_apb_pwdata),
	.apbs_prdata      (video_apb_prdata),
	.apbs_pready      (video_apb_pready),
	.apbs_pslverr     (video_apb_pslverr),

	.gpdi_dp          (gpdi_dp)
);

// ULX4M GPDI examples drive the positive and negative pins as separate
// LVCMOS33 outputs. Keep the serialized positive lanes unchanged and drive
// their complementary pins explicitly.
assign gpdi_dn = ~gpdi_dp;

// Forward an inverted copy of the 50 MHz system clock. Commands and data are
// launched on clk_sys rising edges and reach the SDRAM half a cycle before
// its rising clock edge.
ddr_out sdram_clock_u (
	.clk     (clk_sys),
	.rst_n   (rst_n_sys),
	.d_rise  (1'b0),
	.d_fall  (1'b1),
	.e       (1'b1),
	.q       (sdram_clk)
);

example_soc #(
	.DTM_TYPE           ("ECP5"),
	.SRAM_DEPTH         (1 << 15),
	.CLK_MHZ            (50),
	.SDRAM_ENABLE       (1),
	.SDRAM_COL_WIDTH    (9),
	.SDRAM_DIAGNOSTIC_ALIAS_MASK (32'hfe000000),
	.SDRAM_VIDEO_APERTURE_BASE   (32'h21c00000),

	.EXTENSION_M         (1),
	.EXTENSION_A         (0),
	.EXTENSION_C         (1),
	.EXTENSION_ZBA       (1),
	.EXTENSION_ZBB       (1),
	.EXTENSION_ZBC       (0),
	.EXTENSION_ZBS       (1),
	.EXTENSION_ZBKB      (0),
	.EXTENSION_ZIFENCEI  (1),
	.EXTENSION_XH3BEXTM  (0),
	.EXTENSION_XH3PMPM   (0),
	.EXTENSION_XH3POWER  (0),
	.CSR_COUNTER         (1),
	.MUL_FAST            (1),
	.MUL_FASTER          (1),
	.MULH_FAST           (1),
	.MULDIV_UNROLL       (4),
	.FAST_BRANCHCMP      (1),
	.BRANCH_PREDICTOR    (1)
) soc_u (
	.clk     (clk_sys),
	.rst_n   (rst_n_sys),

	// JTAG connections provided internally by ECP5 JTAGG primitive
	.tck     (1'b0),
	.trst_n  (1'b0),
	.tms     (1'b0),
	.tdi     (1'b0),
	.tdo     (/* unused */),

	.uart_tx (uart_tx),
	.uart_rx (uart_rx),

    .gpio_in  (8'h00),
    .gpio_out (gpio_out),

	.sdram_a    (sdram_a),
	.sdram_ba   (sdram_ba),
	.sdram_d    (sdram_d),
	.sdram_dqm  (sdram_dqm),
	.sdram_cke  (sdram_cke),
	.sdram_csn  (sdram_csn),
	.sdram_rasn (sdram_rasn),
	.sdram_casn (sdram_casn),
	.sdram_wen  (sdram_wen),

	.video_sdram_req_valid (video_sdram_req_valid),
	.video_sdram_req_ready (video_sdram_req_ready),
	.video_sdram_req_addr  (video_sdram_req_addr),
	.video_sdram_rsp_valid (video_sdram_rsp_valid),
	.video_sdram_rsp_rdata (video_sdram_rsp_rdata),
	.video_sdram_init_done (video_sdram_init_done),

	.video_apb_psel        (video_apb_psel),
	.video_apb_penable     (video_apb_penable),
	.video_apb_pwrite      (video_apb_pwrite),
	.video_apb_paddr       (video_apb_paddr),
	.video_apb_pwdata      (video_apb_pwdata),
	.video_apb_prdata      (video_apb_prdata),
	.video_apb_pready      (video_apb_pready),
	.video_apb_pslverr     (video_apb_pslverr)
);

endmodule
