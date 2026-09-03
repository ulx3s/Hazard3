/*****************************************************************************\
|                        Copyright (C) 2026 gojimmypi                        |
|                         SPDX-License-Identifier: MIT                       |
\*****************************************************************************/

`default_nettype none

`ifndef HAZARD3_ULX4M_SYS_CLK_MHZ
`define HAZARD3_ULX4M_SYS_CLK_MHZ 50
`endif

// Hazard3 + Doom target for ULX4M-LD v0.0.3 with LiteDRAM ECP5 DDR3.
// FPGA build: ULX4M-LD-LITEDRAM-PERFORMANCE-R5-20260716
module fpga_ulx4m_ld (
    input  wire        clk_osc,
    output wire [7:0]  led,

    output wire        uart_tx,
    input  wire        uart_rx,

    // CM4-compatible micro-SD interface on the ULX4M carrier.
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_csn,
    output wire        sd_pwr_on,

    output wire [3:0]  gpdi_dp,

    output wire [15:0] ddram_a,
    output wire [2:0]  ddram_ba,
    output wire        ddram_cas_n,
    output wire        ddram_cke,
    output wire        ddram_clk_p,
    output wire        ddram_cs_n,
    output wire [1:0]  ddram_dm,
    inout  wire [15:0] ddram_dq,
    inout  wire [1:0]  ddram_dqs_p,
    output wire        ddram_odt,
    output wire        ddram_ras_n,
    output wire        ddram_reset_n,
    output wire        ddram_we_n
);

// Match the proven ULX3S Hazard3 clock rate. LiteDRAM still receives the
// board's direct 25 MHz oscillator and generates its independent 75/150 MHz
// memory clock domains; the existing bundled-data CDC crosses between them.
wire clk_sys;
wire pll_sys_locked;
wire rst_n_sys;

// CM4 SD_PWR_ON is active high. Keep card power enabled while this bitstream runs.
assign sd_pwr_on = 1'b1;

localparam integer SYS_CLK_MHZ = `HAZARD3_ULX4M_SYS_CLK_MHZ;

generate
if (SYS_CLK_MHZ == 25) begin : gen_sys_clk_25
    assign clk_sys = clk_osc;
    assign pll_sys_locked = 1'b1;
end else if (SYS_CLK_MHZ == 40) begin : gen_pll_sys_40
    pll_25_40 pll_sys_u (
        .clkin   (clk_osc),
        .clkout0 (clk_sys),
        .locked  (pll_sys_locked)
    );
end else if (SYS_CLK_MHZ == 50) begin : gen_pll_sys_50
    pll_25_50 pll_sys_u (
        .clkin   (clk_osc),
        .clkout0 (clk_sys),
        .locked  (pll_sys_locked)
    );
end else begin : gen_pll_sys_unsupported
    unsupported_ulx4m_sys_clk_mhz unsupported_sys_clk_u ();
end
endgenerate

fpga_reset #(
    .SHIFT (3)
) rstgen_sys_u (
    .clk         (clk_sys),
    .force_rst_n (pll_sys_locked),
    .rst_n       (rst_n_sys)
);

// The video clock tree is unchanged from the working ULX3S target.
wire clk_video_pix;
wire clk_tmds_x5;
wire pll_video_locked;
wire rst_n_video_pix;
wire rst_n_tmds_x5;

pll_25_50_250 pll_video_u (
    .clkin       (clk_osc),
    .clk_pix     (clk_video_pix),
    .clk_tmds_x5 (clk_tmds_x5),
    .locked      (pll_video_locked)
);

fpga_reset #(
    .SHIFT (3)
) rstgen_video_pix_u (
    .clk         (clk_video_pix),
    .force_rst_n (pll_video_locked),
    .rst_n       (rst_n_video_pix)
);

fpga_reset #(
    .SHIFT (3)
) rstgen_tmds_u (
    .clk         (clk_tmds_x5),
    .force_rst_n (pll_video_locked),
    .rst_n       (rst_n_tmds_x5)
);

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

wire [7:0]  soc_gpio_out;
wire        ddr3_calib_complete;
wire [31:0] ddr3_debug_status;

// Runtime build IDs let firmware prove that the intended bitstream and the
// intended LiteDRAM implementation are actually running on the board.
localparam [31:0] FPGA_BUILD_ID        = 32'h4c445035; // ASCII "LDP5"
localparam [31:0] DDR_CORE_BUILD_ID    = 32'h32343132; // ASCII "2412"
localparam [31:0] DDR_ADAPTER_BUILD_ID = 32'h41444c35; // ASCII "ADL5"

// Registers 7-10 are unused by the shared framebuffer block.
always @(*) begin
    case (video_apb_paddr[5:2])
    4'h7: video_apb_prdata = FPGA_BUILD_ID;
    4'h8: video_apb_prdata = ddr3_debug_status;
    4'h9: video_apb_prdata = DDR_CORE_BUILD_ID;
    4'ha: video_apb_prdata = DDR_ADAPTER_BUILD_ID;
    default: video_apb_prdata = video_apb_prdata_framebuffer;
    endcase
end

// LiteDRAM leaves insufficient EBR for the extended 400x240/512x300
// framebuffer on the 85F. Keep ULX4M-LD on the standard 320x200 mode.
ulx3s_hdmi_framebuffer #(
    .EXTENDED_VIDEO_MODES (1'b0)
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

// D7 is a hardware heartbeat driven directly from the board oscillator. It
// proves that the user bitstream is active even if either PLL or DDR3 stalls.
wire heartbeat;

blinky #(
    .CLK_HZ   (25_000_000),
    .BLINK_HZ (1)
) heartbeat_u (
    .clk   (clk_osc),
    .blink (heartbeat)
);

// Before initialization completes, the LEDs expose LiteDRAM status:
// D7 heartbeat, D6 video PLL, D5 DDR PLL, D4 init_done, D3 init_error,
// D2 user clock ready, D1 adapter busy, D0 user Wishbone busy.
assign led = ddr3_calib_complete ? {heartbeat, soc_gpio_out[6:0]} : {
    heartbeat,
    pll_video_locked,
    ddr3_debug_status[2],
    ddr3_debug_status[0],
    ddr3_debug_status[1],
    ddr3_debug_status[3],
    ddr3_debug_status[5],
    ddr3_debug_status[6]
};

// The SDR SDRAM outputs remain internal and unused on ULX4M-LD. They are kept
// here only because example_soc retains its proven ULX3S interface.
wire [12:0] unused_sdram_a;
wire [1:0]  unused_sdram_ba;
wire [15:0] unused_sdram_d;
wire [1:0]  unused_sdram_dqm;
wire        unused_sdram_cke;
wire        unused_sdram_csn;
wire        unused_sdram_rasn;
wire        unused_sdram_casn;
wire        unused_sdram_wen;
wire        unused_ddram_clk_n;
wire [1:0]  unused_ddram_dqs_n;

example_soc #(
    .DTM_TYPE           ("ECP5"),
    .SRAM_DEPTH         (1 << 15),
    .SRAM_PRELOAD_FILE  ("../soc/hazard3-boot-monitor.hex"),
    .CLK_MHZ            (SYS_CLK_MHZ),
    .SDRAM_ENABLE       (1),
    .LITEDRAM_ENABLE     (1),
    .SD_SPI_ENABLE       (1),

    .EXTENSION_M        (1),
    .EXTENSION_A        (0),
    .EXTENSION_C        (1),
    .EXTENSION_ZBA      (1),
    .EXTENSION_ZBB      (1),
    .EXTENSION_ZBC      (0),
    .EXTENSION_ZBS      (1),
    .EXTENSION_ZBKB     (0),
    .EXTENSION_ZIFENCEI (1),
    .EXTENSION_XH3BEXTM (0),
    .EXTENSION_XH3PMPM  (0),
    .EXTENSION_XH3POWER (0),
    .CSR_COUNTER        (1),
    .MUL_FAST           (1),
    .MUL_FASTER         (1),
    .MULH_FAST          (1),
    .MULDIV_UNROLL      (4),
    .FAST_BRANCHCMP     (1),
    .BRANCH_PREDICTOR   (1)
) soc_u (
    .clk     (clk_sys),
    .rst_n   (rst_n_sys),

    // JTAG connections are provided internally by the ECP5 JTAGG primitive.
    .tck     (1'b0),
    .trst_n  (1'b0),
    .tms     (1'b0),
    .tdi     (1'b0),
    .tdo     (),

    .uart_tx (uart_tx),
    .uart_rx (uart_rx),

    .gpio_out (soc_gpio_out),

    .sd_clk  (sd_clk),
    .sd_mosi (sd_mosi),
    .sd_miso (sd_miso),
    .sd_csn  (sd_csn),

    .sdram_a    (unused_sdram_a),
    .sdram_ba   (unused_sdram_ba),
    .sdram_d    (unused_sdram_d),
    .sdram_dqm  (unused_sdram_dqm),
    .sdram_cke  (unused_sdram_cke),
    .sdram_csn  (unused_sdram_csn),
    .sdram_rasn (unused_sdram_rasn),
    .sdram_casn (unused_sdram_casn),
    .sdram_wen  (unused_sdram_wen),

    // LiteDRAM keeps its proven 25 MHz reference while Hazard3 uses the selected system clock.
    .litedram_ref_clk    (clk_osc),
    .ddram_a             (ddram_a),
    .ddram_ba            (ddram_ba),
    .ddram_cas_n         (ddram_cas_n),
    .ddram_cke           (ddram_cke),
    .ddram_clk_n         (unused_ddram_clk_n),
    .ddram_clk_p         (ddram_clk_p),
    .ddram_cs_n          (ddram_cs_n),
    .ddram_dm            (ddram_dm),
    .ddram_dq            (ddram_dq),
    .ddram_dqs_n         (unused_ddram_dqs_n),
    .ddram_dqs_p         (ddram_dqs_p),
    .ddram_odt           (ddram_odt),
    .ddram_ras_n         (ddram_ras_n),
    .ddram_reset_n       (ddram_reset_n),
    .ddram_we_n          (ddram_we_n),
    .ddr3_calib_complete (ddr3_calib_complete),
    .ddr3_debug_status   (ddr3_debug_status),

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

`default_nettype wire
