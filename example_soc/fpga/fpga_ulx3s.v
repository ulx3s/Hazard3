/*****************************************************************************\
|                        Copyright (C) 2021 Luke Wren                         |
|                     SPDX-License-Identifier: Apache-2.0                     |
|                                                                             |
|                          ulx-doom updates: gojimmypi                        |
\*****************************************************************************/

`default_nettype none

module fpga_ulx3s (
	input  wire       clk_osc,
	output wire [7:0] led,

	output wire       uart_tx,
	input  wire       uart_rx,

	// Dedicated FPGA <-> ESP32 Serial1 sideband for shared SAO access.
	// Names are from the ESP32 perspective: GPIO16 is RX, GPIO17 is TX.
	inout  wire       wifi_gpio16,
	input  wire       wifi_gpio17,

	inout  wire       sao_sda,
	inout  wire       sao_scl,
	inout  wire       sao_gpio1,
	inout  wire       sao_gpio2,

	// Onboard micro-SD socket. These nets are also connected to ESP32
	// GPIO14/15/2/13; ESP32 firmware must release them while FPGA-owned.
	output wire       sd_clk,
	output wire       sd_mosi,
	input  wire       sd_miso,
	output wire       sd_csn,

	output wire [3:0]  gpdi_dp,

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

`ifdef HAZARD3_ULX3S_12F
/*
 * The ULX3S 12F is a compact board with a 40 MHz system clock. The 12F
 * has a smaller EBR profile than the 85F, so the video framebuffer must
 * be implemented in SDRAM. The 12F has a smaller SDRAM chip than the 85F,
 * so the framebuffer is limited to 32 MiB and the SDRAM cache is limited
 * to 32 KiB.
 *
 * With limited resources, when HAS_REGISTERED_READ_HITS is not defined,
 * the timing closure will not likely succeed even at the lower 40MHz.
 */
`define HAS_REGISTERED_READ_HITS
pll_25_40 pll_sys (
	.clkin   (clk_osc),
	.clkout0 (clk_sys),
	.locked  (pll_sys_locked)
);
`else
/* The ULX3S 85F has a 50 MHz system clock. The 85F has a larger EBR profile than
 * the 12F, so the video framebuffer can be implemented in EBR. The 85F has
 * a larger SDRAM chip than the 12F, so the framebuffer is limited to 64 MiB
 * and the SDRAM cache is limited to 64 KiB.
 *
 * The HAS_REGISTERED_READ_HITS is optional here. The timing closure will likely
 * succeed at 50MHz with or without it.
 */
pll_25_50 pll_sys (
	.clkin   (clk_osc),
	.clkout0 (clk_sys),
	.locked  (pll_sys_locked)
);
`endif

fpga_reset #(
	.SHIFT (3)
) rstgen (
	.clk         (clk_sys),
	.force_rst_n (pll_sys_locked),
	.rst_n       (rst_n_sys)
);

// Keep the proven Hazard3/SDRAM clock tree unchanged. HDMI uses a second PLL,
// so initial video bring-up cannot disturb CPU, JTAG, UART or SDRAM timing.
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
reg  [31:0] video_apb_prdata;
wire [31:0] video_apb_prdata_framebuffer;
wire        video_apb_pready;
wire        video_apb_pslverr;

// The shared SoC exposes both the ULX3S SDR SDRAM and ULX4M-LD LiteDRAM ports.
// This wrapper explicitly disables LiteDRAM and terminates every unused DDR3
// port so the ULX3S build never relies on parameter defaults or open inputs.
wire [15:0] unused_ddram_a;
wire [2:0]  unused_ddram_ba;
wire        unused_ddram_cas_n;
wire        unused_ddram_cke;
wire        unused_ddram_clk_n;
wire        unused_ddram_clk_p;
wire        unused_ddram_cs_n;
wire [1:0]  unused_ddram_dm;
wire [15:0] unused_ddram_dq;
wire [1:0]  unused_ddram_dqs_n;
wire [1:0]  unused_ddram_dqs_p;
wire        unused_ddram_odt;
wire        unused_ddram_ras_n;
wire        unused_ddram_reset_n;
wire        unused_ddram_we_n;
wire        unused_ddr3_calib_complete;
wire [31:0] unused_ddr3_debug_status;

// The FPGA remains the only electrical I2C driver connected to the SAO
// connector. Hazard3 and the ESP32 share logical ownership inside the FPGA;
// the selected I2C engine drives these open-drain controls. GPIO1/GPIO2
// remain under Hazard3/APB control and are independently tri-stated.
wire sao_sda_drive_low;
wire sao_scl_drive_low;
wire sao_gpio1_o;
wire sao_gpio1_oe;
wire sao_gpio2_o;
wire sao_gpio2_oe;
wire esp_sao_uart_tx;
wire esp_sao_uart_tx_oe;

assign wifi_gpio16 = esp_sao_uart_tx_oe ? esp_sao_uart_tx : 1'bz;
assign sao_sda   = sao_sda_drive_low ? 1'b0 : 1'bz;
assign sao_scl   = sao_scl_drive_low ? 1'b0 : 1'bz;
assign sao_gpio1 = sao_gpio1_oe ? sao_gpio1_o : 1'bz;
assign sao_gpio2 = sao_gpio2_oe ? sao_gpio2_o : 1'bz;

// Runtime IDs use the same APB slots as ULX4M-LD so one monitor firmware can
// verify either board without compile-time board selection. The ULX3S 12F is
// the same board-level design with a compact EBR profile; pins, peripherals,
// clocks and CPU ISA remain shared with the 85F target.
localparam [31:0] MEMORY_CORE_BUILD_ID    = 32'h53445235; // ASCII "SDR5"
localparam [31:0] MEMORY_ADAPTER_BUILD_ID = 32'h41485335; // ASCII "AHS5"

`ifdef HAZARD3_ULX3S_12F
localparam integer SOC_CLK_MHZ = 40;
localparam [31:0] FPGA_BUILD_ID = 32'h554c3132; // ASCII "UL12"
localparam ULX3S_SDRAM_SCANOUT = 1'b1;
localparam HDMI_EXTENDED_VIDEO_MODES = 1'b0;
localparam integer SOC_SRAM_DEPTH = 1 << 8;
localparam SOC_SRAM_PRELOAD_FILE = "../soc/hazard3-12f-bootstrap.hex";
localparam integer SOC_SDRAM_CACHE_DEPTH = 512; // 32 KiB, two-way unified
localparam SOC_SDRAM_CACHE_TAG_PRELOAD = "../soc/cache_tags_zero_12f.hex";

`ifdef HAS_REGISTERED_READ_HITS
    localparam SOC_SDRAM_CACHE_REGISTERED_READ_HITS = 1'b1;
`endif

localparam [31:0] SOC_SDRAM_UNCACHED_LOW_MASK = 32'hfffc0000;
localparam [31:0] SOC_SDRAM_UNCACHED_LOW_BASE = 32'h20000000;
`ifdef HAZARD3_SDRAM_32MB
localparam [24:0] VIDEO_FRAMEBUFFER0_HALFWORD_BASE = 25'h0e00000;
localparam [24:0] VIDEO_FRAMEBUFFER1_HALFWORD_BASE = 25'h0e08000;
localparam [31:0] SOC_VIDEO_APERTURE_BASE = 32'h21c00000;
localparam integer SOC_SDRAM_COLUMN_WIDTH = 9;
`else
localparam [24:0] VIDEO_FRAMEBUFFER0_HALFWORD_BASE = 25'h1e00000;
localparam [24:0] VIDEO_FRAMEBUFFER1_HALFWORD_BASE = 25'h1e08000;
localparam [31:0] SOC_VIDEO_APERTURE_BASE = 32'h23c00000;
localparam integer SOC_SDRAM_COLUMN_WIDTH = 10;
`endif /* HAZARD3_SDRAM_32MB */

`else /* ! HAZARD3_ULX3S_12F */
localparam integer SOC_CLK_MHZ = 50;
localparam [31:0] FPGA_BUILD_ID = 32'h554c5035; // ASCII "ULP5"
localparam ULX3S_SDRAM_SCANOUT = 1'b0;
`ifdef HAZARD3_HDMI_EXTENDED_MODES
localparam HDMI_EXTENDED_VIDEO_MODES = 1'b1;
`else
localparam HDMI_EXTENDED_VIDEO_MODES = 1'b0;
`endif
localparam integer SOC_SRAM_DEPTH = 1 << 15;
localparam SOC_SRAM_PRELOAD_FILE = "../soc/hazard3-boot-monitor.hex";
localparam integer SOC_SDRAM_CACHE_DEPTH = 1024; // established 64 KiB cache
localparam SOC_SDRAM_CACHE_TAG_PRELOAD = "../soc/cache_tags_zero.hex";
`ifdef HAS_REGISTERED_READ_HITS
    localparam SOC_SDRAM_CACHE_REGISTERED_READ_HITS = 1'b0;
`endif
localparam [31:0] SOC_SDRAM_UNCACHED_LOW_MASK = 32'hfff00000;
localparam [31:0] SOC_SDRAM_UNCACHED_LOW_BASE = 32'h20000000;
localparam [31:0] SOC_VIDEO_APERTURE_BASE = 32'h23c00000;
localparam integer SOC_SDRAM_COLUMN_WIDTH = 10;
localparam [24:0] VIDEO_FRAMEBUFFER0_HALFWORD_BASE = 25'h1e00000;
localparam [24:0] VIDEO_FRAMEBUFFER1_HALFWORD_BASE = 25'h1e08000;
`endif /* 12F or 85F */

wire [31:0] memory_status = {
    16'h5344,                 // ASCII "SD"
    11'd0,
    video_sdram_init_done,    // ready
    rst_n_sys,                // user clock/reset ready
    pll_sys_locked,
    1'b0,                     // no initialization error
    video_sdram_init_done
};

always @(*) begin
    case (video_apb_paddr[5:2])
    4'h7: video_apb_prdata = FPGA_BUILD_ID;
    4'h8: video_apb_prdata = memory_status;
    4'h9: video_apb_prdata = MEMORY_CORE_BUILD_ID;
    4'ha: video_apb_prdata = MEMORY_ADAPTER_BUILD_ID;
    default: video_apb_prdata = video_apb_prdata_framebuffer;
    endcase
end

`ifdef HAZARD3_ULX3S_12F
generate
if (ULX3S_SDRAM_SCANOUT) begin: compact_video
    ulx3s_hdmi_sdram_scanout #(
        .FRAMEBUFFER0_HALFWORD_BASE (VIDEO_FRAMEBUFFER0_HALFWORD_BASE),
        .FRAMEBUFFER1_HALFWORD_BASE (VIDEO_FRAMEBUFFER1_HALFWORD_BASE)
    ) hdmi_video_u (
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
	.apbs_prdata      (video_apb_prdata_framebuffer),
	.apbs_pready      (video_apb_pready),
	.apbs_pslverr     (video_apb_pslverr),

	.gpdi_dp          (gpdi_dp)
    );
end else begin: full_ebr_video
    ulx3s_hdmi_framebuffer #(
        .EXTENDED_VIDEO_MODES (HDMI_EXTENDED_VIDEO_MODES)
    ) hdmi_video_u (
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
	.apbs_prdata      (video_apb_prdata_framebuffer),
	.apbs_pready      (video_apb_pready),
	.apbs_pslverr     (video_apb_pslverr),

	.gpdi_dp          (gpdi_dp)
    );
end
endgenerate
`else
ulx3s_hdmi_framebuffer #(
    .EXTENDED_VIDEO_MODES (HDMI_EXTENDED_VIDEO_MODES)
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
	.apbs_prdata      (video_apb_prdata_framebuffer),
	.apbs_pready      (video_apb_pready),
	.apbs_pslverr     (video_apb_pslverr),

	.gpdi_dp          (gpdi_dp)
);
`endif

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
	.DTM_TYPE                    ("ECP5"),
	.SRAM_DEPTH                  (SOC_SRAM_DEPTH),
	.SRAM_PRELOAD_FILE           (SOC_SRAM_PRELOAD_FILE),
	.SRAM_HAS_WRITE_BUFFER       (1),
	.CLK_MHZ                     (SOC_CLK_MHZ),
	.SDRAM_ENABLE                (1),
	.LITEDRAM_ENABLE             (0),
	.ESP_SAO_UART_ENABLE         (1),
	.SD_SPI_ENABLE               (1),
	.SDRAM_COL_WIDTH             (SOC_SDRAM_COLUMN_WIDTH),
	.SDRAM_CACHE_DEPTH           (SOC_SDRAM_CACHE_DEPTH),
	.SDRAM_CACHE_TAG_PRELOAD     (SOC_SDRAM_CACHE_TAG_PRELOAD),
`ifdef HAS_REGISTERED_READ_HITS
	.SDRAM_CACHE_REGISTERED_READ_HITS (SOC_SDRAM_CACHE_REGISTERED_READ_HITS),
`endif
	.SDRAM_UNCACHED_LOW_MASK     (SOC_SDRAM_UNCACHED_LOW_MASK),
	.SDRAM_UNCACHED_LOW_BASE     (SOC_SDRAM_UNCACHED_LOW_BASE),
	.SDRAM_VIDEO_APERTURE_BASE   (SOC_VIDEO_APERTURE_BASE),

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

	.sd_clk  (sd_clk),
	.sd_mosi (sd_mosi),
	.sd_miso (sd_miso),
	.sd_csn  (sd_csn),

    .gpio_out (led),

    .sao_sda_i         (sao_sda),
    .sao_scl_i         (sao_scl),
    .sao_sda_drive_low (sao_sda_drive_low),
    .sao_scl_drive_low (sao_scl_drive_low),
    .sao_gpio1_i       (sao_gpio1),
    .sao_gpio1_o       (sao_gpio1_o),
    .sao_gpio1_oe      (sao_gpio1_oe),
    .sao_gpio2_i       (sao_gpio2),
    .sao_gpio2_o       (sao_gpio2_o),
    .sao_gpio2_oe      (sao_gpio2_oe),

    .esp_sao_uart_rx   (wifi_gpio17),
    .esp_sao_uart_tx   (esp_sao_uart_tx),
    .esp_sao_uart_tx_oe(esp_sao_uart_tx_oe),

	.sdram_a    (sdram_a),
	.sdram_ba   (sdram_ba),
	.sdram_d    (sdram_d),
	.sdram_dqm  (sdram_dqm),
	.sdram_cke  (sdram_cke),
	.sdram_csn  (sdram_csn),
	.sdram_rasn (sdram_rasn),
	.sdram_casn (sdram_casn),
	.sdram_wen  (sdram_wen),

	.litedram_ref_clk    (1'b0),
	.ddram_a             (unused_ddram_a),
	.ddram_ba            (unused_ddram_ba),
	.ddram_cas_n         (unused_ddram_cas_n),
	.ddram_cke           (unused_ddram_cke),
	.ddram_clk_n         (unused_ddram_clk_n),
	.ddram_clk_p         (unused_ddram_clk_p),
	.ddram_cs_n          (unused_ddram_cs_n),
	.ddram_dm            (unused_ddram_dm),
	.ddram_dq            (unused_ddram_dq),
	.ddram_dqs_n         (unused_ddram_dqs_n),
	.ddram_dqs_p         (unused_ddram_dqs_p),
	.ddram_odt           (unused_ddram_odt),
	.ddram_ras_n         (unused_ddram_ras_n),
	.ddram_reset_n       (unused_ddram_reset_n),
	.ddram_we_n          (unused_ddram_we_n),
	.ddr3_calib_complete (unused_ddr3_calib_complete),
	.ddr3_debug_status   (unused_ddr3_debug_status),

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
