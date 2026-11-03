/*****************************************************************************\
|                      Hazard3-Doom ULX5M-GS wrapper                         |
|                     SPDX-License-Identifier: Apache-2.0                     |
\*****************************************************************************/

`default_nettype none
module fpga_ulx5m_gs (
    input  wire        clk25,
    input  wire        btn0_n,
    output wire [7:0]  led_n,

    output wire        uart_tx,
    input  wire        uart_rx,

    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_csn,

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

/*
 * Keep 25 MHz as the synthesis default so existing 25 MHz seed sweeps remain
 * unchanged. The ULX5M build scripts can select 12 MHz or 20 MHz for hardware
 * bring-up; those clocks are generated from the board's 25 MHz oscillator by a
 * GateMate CC_PLL and then placed on the global clock network with CC_BUFG.
 */
wire clk_sys;
wire clock_ready;
wire config_rst_n;
wire rst_n_sys;

`ifdef ULX5M_SYS_CLK_12M
localparam integer SOC_CLK_MHZ = 12;
`define ULX5M_USE_PLL
`define ULX5M_PLL_OUT_CLK 12.0
`elsif ULX5M_SYS_CLK_20M
localparam integer SOC_CLK_MHZ = 20;
`define ULX5M_USE_PLL
`define ULX5M_PLL_OUT_CLK 20.0
`else
localparam integer SOC_CLK_MHZ = 25;
`endif

`ifdef ULX5M_USE_PLL
wire pll_clk;
wire pll_locked;

CC_PLL #(
    .REF_CLK    (25.0),
    .OUT_CLK    (`ULX5M_PLL_OUT_CLK),
    .LOW_JITTER (1),
    .LOCK_REQ   (1)
) system_pll_u (
    .CLK_REF             (clk25),
    .USR_CLK_REF         (1'b0),
    .CLK_FEEDBACK        (1'b0),
    .USR_LOCKED_STDY_RST (1'b0),
    .USR_PLL_LOCKED_STDY (),
    .USR_PLL_LOCKED      (pll_locked),
    .CLK0                (pll_clk),
    .CLK90               (),
    .CLK180              (),
    .CLK270              (),
    .CLK_REF_OUT         ()
);

CC_BUFG system_clock_buf_u (
    .I (pll_clk),
    .O (clk_sys)
);

assign clock_ready = pll_locked;
`else
assign clk_sys = clk25;
assign clock_ready = 1'b1;
`endif

CC_USR_RSTN config_reset_u (
    .USR_RSTN (config_rst_n)
);

reset_sync reset_sync_u (
    .clk       (clk_sys),
    .rst_n_in  (config_rst_n & btn0_n & clock_ready),
    .rst_n_out (rst_n_sys)
);

`ifdef ULX5M_USE_PLL
`undef ULX5M_USE_PLL
`undef ULX5M_PLL_OUT_CLK
`endif

/* ULX5M LEDs are active-low. */
wire [7:0] gpio_out;
assign led_n = ~gpio_out;

/*
 * Native SDR SDRAM runtime IDs are shared with ULX3S because this target uses
 * the same Hazard3 ahb_sdram + ulx3s_sdram_controller implementation.
 */
localparam [31:0] FPGA_BUILD_ID           = 32'h554c354d; // ASCII "UL5M"
localparam [31:0] MEMORY_CORE_BUILD_ID    = 32'h53445235; // ASCII "SDR5"
localparam [31:0] MEMORY_ADAPTER_BUILD_ID = 32'h41485335; // ASCII "AHS5"

localparam integer SOC_SRAM_DEPTH = 1 << 14; // 64 KiB resident monitor
localparam SOC_SRAM_PRELOAD_FILE = "../soc/hazard3-boot-monitor.hex";
localparam integer SOC_SDRAM_CACHE_DEPTH = 512; // 32 KiB, two-way unified
localparam SOC_SDRAM_CACHE_TAG_PRELOAD = "../soc/cache_tags_zero_12f.hex";
localparam [31:0] SOC_SDRAM_UNCACHED_LOW_MASK = 32'hfffc0000;
localparam [31:0] SOC_SDRAM_UNCACHED_LOW_BASE = 32'h20000000;
localparam [31:0] SOC_VIDEO_APERTURE_BASE = 32'h21c00000;
localparam integer SOC_SDRAM_COLUMN_WIDTH = 9; // 32 MiB IS42S16160

/*
 * Phase 1 is deliberately headless. The APB shim exposes SDRAM readiness and
 * board/memory IDs so the resident monitor can qualify SDRAM and SD boot.
 * All actual video registers read as zero until the GateMate DVI block is
 * added. Doom therefore falls back to its existing headless path after the
 * present timeout, while memory and loader bring-up remain testable.
 */
wire        video_sdram_req_ready;
wire        video_sdram_rsp_valid;
wire [15:0] video_sdram_rsp_rdata;
wire        video_sdram_init_done;
wire        video_apb_psel;
wire        video_apb_penable;
wire        video_apb_pwrite;
wire [15:0] video_apb_paddr;
wire [31:0] video_apb_pwdata;
reg  [31:0] video_apb_prdata;
wire        video_apb_pready = 1'b1;
wire        video_apb_pslverr = 1'b0;

wire [31:0] video_status = {
    27'd0,
    video_sdram_init_done, // bit 4: HAZARD3_VIDEO_STATUS_SDRAM_READY
    4'd0
};

wire [31:0] memory_status = {
    16'h5344,              // native SDR SDRAM marker, ASCII "SD"
    11'd0,
    video_sdram_init_done, // bit 4: ready
    rst_n_sys,             // bit 3: user clock/reset ready
    clock_ready,            // bit 2: system clock ready
    1'b0,                  // bit 1: initialization error
    video_sdram_init_done  // bit 0: initialization complete
};

always @(*) begin
    case (video_apb_paddr[5:2])
    4'h0: video_apb_prdata = video_status;
    4'h7: video_apb_prdata = FPGA_BUILD_ID;
    4'h8: video_apb_prdata = memory_status;
    4'h9: video_apb_prdata = MEMORY_CORE_BUILD_ID;
    4'ha: video_apb_prdata = MEMORY_ADAPTER_BUILD_ID;
    default: video_apb_prdata = 32'd0;
    endcase
end

/*
 * Launch SDRAM commands/data on clk_sys edges and present the SDRAM with the
 * opposite clock phase, matching the established Hazard3 ULX3S interface.
 * CC_ODDR is the GateMate output DDR primitive supported by synth_gatemate.
 */
CC_ODDR #(
    .CLK_INV (1'b0)
) sdram_clock_u (
    .D0  (1'b0),
    .D1  (1'b1),
    .CLK (clk_sys),
    .DDR (clk_sys),
    .Q   (sdram_clk)
);

/* Unused optional interfaces from the shared example SoC. */
wire        unused_tdo;
wire        unused_sao_sda_drive_low;
wire        unused_sao_scl_drive_low;
wire        unused_sao_gpio1_o;
wire        unused_sao_gpio1_oe;
wire        unused_sao_gpio2_o;
wire        unused_sao_gpio2_oe;
wire        unused_esp_sao_uart_tx;
wire        unused_esp_sao_uart_tx_oe;
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

example_soc #(
    .DTM_TYPE                    ("JTAG"),
    .SRAM_DEPTH                  (SOC_SRAM_DEPTH),
    .SRAM_PRELOAD_FILE           (SOC_SRAM_PRELOAD_FILE),
    .SRAM_HAS_WRITE_BUFFER       (1),
    .CLK_MHZ                     (SOC_CLK_MHZ),
    .SDRAM_ENABLE                (1),
    .LITEDRAM_ENABLE             (0),
    .ESP_SAO_UART_ENABLE         (0),
    .SD_SPI_ENABLE               (1),
    .SDRAM_COL_WIDTH             (SOC_SDRAM_COLUMN_WIDTH),
    .SDRAM_CACHE_DEPTH           (SOC_SDRAM_CACHE_DEPTH),
    .SDRAM_CACHE_TAG_PRELOAD     (SOC_SDRAM_CACHE_TAG_PRELOAD),
`ifdef HAS_REGISTERED_READ_HITS
    .SDRAM_CACHE_REGISTERED_READ_HITS (1),
`endif
    .SDRAM_UNCACHED_LOW_MASK     (SOC_SDRAM_UNCACHED_LOW_MASK),
    .SDRAM_UNCACHED_LOW_BASE     (SOC_SDRAM_UNCACHED_LOW_BASE),
    .SDRAM_VIDEO_APERTURE_BASE   (SOC_VIDEO_APERTURE_BASE),
    .EXTENSION_M                 (1),
    .EXTENSION_A                 (0),
    .EXTENSION_C                 (1),
    .EXTENSION_ZBA               (1),
    .EXTENSION_ZBB               (1),
    .EXTENSION_ZBC               (0),
    .EXTENSION_ZBS               (1),
    .EXTENSION_ZBKB              (0),
    .EXTENSION_ZIFENCEI          (1),
    .EXTENSION_XH3BEXTM          (0),
    .EXTENSION_XH3PMPM           (0),
    .EXTENSION_XH3POWER          (0),
    .CSR_COUNTER                 (1),
    .MUL_FAST                    (1),
    .MUL_FASTER                  (1),
    .MULH_FAST                   (1),
    .MULDIV_UNROLL               (4),
    .FAST_BRANCHCMP              (1),
    .BRANCH_PREDICTOR            (1)
) soc_u (
    .clk                         (clk_sys),
    .rst_n                       (rst_n_sys),

    /* Keep the standard DTM in reset until GateMate CPU JTAG is added. */
    .tck                         (1'b0),
    .trst_n                      (1'b0),
    .tms                         (1'b0),
    .tdi                         (1'b0),
    .tdo                         (unused_tdo),

    .uart_tx                     (uart_tx),
    .uart_rx                     (uart_rx),
    .gpio_out                    (gpio_out),
    .gpio_in                     (8'h00),

    .sao_sda_i                   (1'b1),
    .sao_scl_i                   (1'b1),
    .sao_sda_drive_low           (unused_sao_sda_drive_low),
    .sao_scl_drive_low           (unused_sao_scl_drive_low),
    .sao_gpio1_i                 (1'b1),
    .sao_gpio1_o                 (unused_sao_gpio1_o),
    .sao_gpio1_oe                (unused_sao_gpio1_oe),
    .sao_gpio2_i                 (1'b1),
    .sao_gpio2_o                 (unused_sao_gpio2_o),
    .sao_gpio2_oe                (unused_sao_gpio2_oe),
    .esp_sao_uart_rx             (1'b1),
    .esp_sao_uart_tx             (unused_esp_sao_uart_tx),
    .esp_sao_uart_tx_oe          (unused_esp_sao_uart_tx_oe),

    .sd_clk                      (sd_clk),
    .sd_mosi                     (sd_mosi),
    .sd_miso                     (sd_miso),
    .sd_csn                      (sd_csn),

    .sdram_a                     (sdram_a),
    .sdram_ba                    (sdram_ba),
    .sdram_d                     (sdram_d),
    .sdram_dqm                   (sdram_dqm),
    .sdram_cke                   (sdram_cke),
    .sdram_csn                   (sdram_csn),
    .sdram_rasn                  (sdram_rasn),
    .sdram_casn                  (sdram_casn),
    .sdram_wen                   (sdram_wen),

    .litedram_ref_clk            (1'b0),
    .ddram_a                     (unused_ddram_a),
    .ddram_ba                    (unused_ddram_ba),
    .ddram_cas_n                 (unused_ddram_cas_n),
    .ddram_cke                   (unused_ddram_cke),
    .ddram_clk_n                 (unused_ddram_clk_n),
    .ddram_clk_p                 (unused_ddram_clk_p),
    .ddram_cs_n                  (unused_ddram_cs_n),
    .ddram_dm                    (unused_ddram_dm),
    .ddram_dq                    (unused_ddram_dq),
    .ddram_dqs_n                 (unused_ddram_dqs_n),
    .ddram_dqs_p                 (unused_ddram_dqs_p),
    .ddram_odt                   (unused_ddram_odt),
    .ddram_ras_n                 (unused_ddram_ras_n),
    .ddram_reset_n               (unused_ddram_reset_n),
    .ddram_we_n                  (unused_ddram_we_n),
    .ddr3_calib_complete         (unused_ddr3_calib_complete),
    .ddr3_debug_status           (unused_ddr3_debug_status),

    /* No video master in phase 1. */
    .video_sdram_req_valid       (1'b0),
    .video_sdram_req_ready       (video_sdram_req_ready),
    .video_sdram_req_addr        (25'd0),
    .video_sdram_rsp_valid       (video_sdram_rsp_valid),
    .video_sdram_rsp_rdata       (video_sdram_rsp_rdata),
    .video_sdram_init_done       (video_sdram_init_done),

    .video_apb_psel              (video_apb_psel),
    .video_apb_penable           (video_apb_penable),
    .video_apb_pwrite            (video_apb_pwrite),
    .video_apb_paddr             (video_apb_paddr),
    .video_apb_pwdata            (video_apb_pwdata),
    .video_apb_prdata            (video_apb_prdata),
    .video_apb_pready            (video_apb_pready),
    .video_apb_pslverr           (video_apb_pslverr)
);

endmodule
`default_nettype wire
