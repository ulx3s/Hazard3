/*****************************************************************************\
|                        Copyright (C) 2026 gojimmypi                        |
|                         SPDX-License-Identifier: MIT                       |
\*****************************************************************************/

// AHB-Lite/video adapter for the ULX4M-LD LiteDRAM ECP5 DDR3 core.
//
// PERFORMANCE-R5 keeps the proven LiteDRAM/ECP5DDRPHY implementation and
// crosses between a 50 MHz Hazard3/AHB domain and LiteDRAM's 75 MHz user port.
//
// DDR3 IMPLEMENTATION: ULX4M-LD-LITEDRAM-PERFORMANCE-R5-20260716
//   LiteDRAM 2024.12
//   LiteX    2024.12
//   PHY      ECP5DDRPHY, 75 MHz system clock, DDR3-300 data rate
//   Memory   MT41K512M16HA-125, 8 Gbit x16, 1 GiB
//
// The LiteDRAM core contains a small VexRiscv BIOS that performs JEDEC DDR3
// initialization, read leveling and a memory test. The external Wishbone port
// is enabled only after that BIOS reports successful initialization.
//
// ULX4M routes DM0/DM1 outside their associated DQS groups. The proven board
// workaround is to hold both physical DM pins low. To preserve byte, halfword
// and word writes, this adapter converts every AHB write to an atomic 128-bit
// read/modify/write operation and then performs an unmasked full-burst write.

`default_nettype none

module ahb_litedram #(
    parameter W_ADDR = 32,
    parameter W_DATA = 32
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              litedram_ref_clk,

    output wire              ahbls_hready_resp,
    input  wire              ahbls_hready,
    output wire              ahbls_hresp,
    input  wire [W_ADDR-1:0] ahbls_haddr,
    input  wire              ahbls_hwrite,
    input  wire [1:0]        ahbls_htrans,
    input  wire [2:0]        ahbls_hsize,
    input  wire [2:0]        ahbls_hburst,
    input  wire [3:0]        ahbls_hprot,
    input  wire              ahbls_hmastlock,
    input  wire [W_DATA-1:0] ahbls_hwdata,
    output wire [W_DATA-1:0] ahbls_hrdata,

    input  wire              video_req_valid,
    output wire              video_req_ready,
    input  wire [24:0]       video_req_addr,
    output reg               video_rsp_valid,
    output reg  [15:0]       video_rsp_rdata,
    output wire              video_init_done,

    output wire [15:0]       ddram_a,
    output wire [2:0]        ddram_ba,
    output wire              ddram_cas_n,
    output wire              ddram_cke,
    output wire              ddram_clk_n,
    output wire              ddram_clk_p,
    output wire              ddram_cs_n,
    output wire [1:0]        ddram_dm,
    inout  wire [15:0]       ddram_dq,
    inout  wire [1:0]        ddram_dqs_n,
    inout  wire [1:0]        ddram_dqs_p,
    output wire              ddram_odt,
    output wire              ddram_ras_n,
    output wire              ddram_reset_n,
    output wire              ddram_we_n,

    output wire              calib_complete,
    output wire [31:0]       debug_status
);

localparam [2:0]
    ST_IDLE          = 3'd0,
    ST_WRITE_CAPTURE = 3'd1,
    ST_CDC_REQUEST   = 3'd2,
    ST_CDC_WAIT      = 3'd3;

reg [2:0] state;
reg       request_owner_video;
reg       request_write;
reg [25:0] request_line_addr;
reg [1:0] request_word_index;
reg [2:0] request_halfword_index;
reg [3:0] request_byte_offset;
reg [2:0] request_hsize;
reg [127:0] request_wdata;
reg [15:0] request_sel;
reg [31:0] read_data;
reg last_grant_video;
reg rmw_active;
reg request_toggle;
reg response_toggle_sync0;
reg response_toggle_sync1;
reg response_toggle_seen;
reg wb_error_sticky;

wire ahb_request_present = ahbls_htrans[1];

// -------------------------------------------------------------------------
// LiteDRAM core and status synchronization.

wire litedram_init_done;
wire litedram_init_error;
wire litedram_pll_locked;
wire litedram_user_clk;
wire litedram_user_rst;
wire [1:0] litedram_dm_unused;
wire [7:0] litedram_uart_tx_data_unused;
wire litedram_uart_tx_valid_unused;
wire litedram_uart_rx_ready_unused;

wire litedram_wb_ack;
wire [127:0] litedram_wb_dat_r;
wire litedram_wb_err;
reg [25:0] user_wb_adr;
reg [127:0] user_wb_dat_w;
reg [15:0] user_wb_sel;
reg user_wb_we;
reg user_wb_cyc;
reg user_wb_stb;
reg user_wb_busy;
reg request_toggle_sync0;
reg request_toggle_sync1;
reg request_toggle_seen;
reg response_toggle;
reg [127:0] response_data_hold;
reg response_error_hold;

reg init_done_sync0;
reg init_done_sync1;
reg init_error_sync0;
reg init_error_sync1;
reg pll_locked_sync0;
reg pll_locked_sync1;
reg user_rst_sync0;
reg user_rst_sync1;
reg user_wb_busy_sync0;
reg user_wb_busy_sync1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        init_done_sync0 <= 1'b0;
        init_done_sync1 <= 1'b0;
        init_error_sync0 <= 1'b0;
        init_error_sync1 <= 1'b0;
        pll_locked_sync0 <= 1'b0;
        pll_locked_sync1 <= 1'b0;
        user_rst_sync0 <= 1'b1;
        user_rst_sync1 <= 1'b1;
        user_wb_busy_sync0 <= 1'b0;
        user_wb_busy_sync1 <= 1'b0;
    end else begin
        init_done_sync0 <= litedram_init_done;
        init_done_sync1 <= init_done_sync0;
        init_error_sync0 <= litedram_init_error;
        init_error_sync1 <= init_error_sync0;
        pll_locked_sync0 <= litedram_pll_locked;
        pll_locked_sync1 <= pll_locked_sync0;
        user_rst_sync0 <= litedram_user_rst;
        user_rst_sync1 <= user_rst_sync0;
        user_wb_busy_sync0 <= user_wb_busy;
        user_wb_busy_sync1 <= user_wb_busy_sync0;
    end
end

assign calib_complete = init_done_sync1 && !init_error_sync1 &&
    pll_locked_sync1 && !user_rst_sync1;
assign video_init_done = calib_complete;

// -------------------------------------------------------------------------
// One-request-at-a-time bundled-data clock-domain crossing.
//
// Request address/data/control remain unchanged from request_toggle until the
// matching response toggle returns. The response data likewise remains stable
// until the next transaction. Two-flop toggle synchronization therefore gives
// each multi-bit bundle more than one destination-clock period to settle.

always @(posedge litedram_user_clk) begin
    if (litedram_user_rst) begin
        user_wb_adr <= 26'd0;
        user_wb_dat_w <= 128'd0;
        user_wb_sel <= 16'd0;
        user_wb_we <= 1'b0;
        user_wb_cyc <= 1'b0;
        user_wb_stb <= 1'b0;
        user_wb_busy <= 1'b0;
        request_toggle_sync0 <= 1'b0;
        request_toggle_sync1 <= 1'b0;
        request_toggle_seen <= 1'b0;
        response_toggle <= 1'b0;
        response_data_hold <= 128'd0;
        response_error_hold <= 1'b0;
    end else begin
        request_toggle_sync0 <= request_toggle;
        request_toggle_sync1 <= request_toggle_sync0;

        if (!user_wb_busy && request_toggle_sync1 != request_toggle_seen) begin
            request_toggle_seen <= request_toggle_sync1;
            user_wb_adr <= request_line_addr;
            user_wb_dat_w <= request_wdata;
            user_wb_sel <= request_sel;
            user_wb_we <= request_write;
            user_wb_cyc <= 1'b1;
            user_wb_stb <= 1'b1;
            user_wb_busy <= 1'b1;
        end

        if (user_wb_busy && (litedram_wb_ack || litedram_wb_err)) begin
            response_data_hold <= litedram_wb_dat_r;
            response_error_hold <= litedram_wb_err;
            response_toggle <= ~response_toggle;
            user_wb_cyc <= 1'b0;
            user_wb_stb <= 1'b0;
            user_wb_busy <= 1'b0;
        end
    end
end

// MT41K512M16 geometry is 16 row bits, 10 column bits and 3 bank bits.
// The generated LiteDRAM port is one 128-bit Wishbone word per DDR3 BL8 burst.
// Its 1 GiB geometry exposes a 26-bit Wishbone word address. The current
// Hazard3/Doom 64 MiB window keeps the upper four word-address bits at zero.
litedram_ulx4m_cpu litedram_u (
    .clk                  (litedram_ref_clk),
    .rst                  (!rst_n),

    .ddram_a              (ddram_a),
    .ddram_ba             (ddram_ba),
    .ddram_cas_n          (ddram_cas_n),
    .ddram_cke            (ddram_cke),
    .ddram_clk_n          (1'b0),
    .ddram_clk_p          (ddram_clk_p),
    .ddram_cs_n           (ddram_cs_n),
    .ddram_dm             (litedram_dm_unused),
    .ddram_dq             (ddram_dq),
    .ddram_dqs_n          (2'b00),
    .ddram_dqs_p          (ddram_dqs_p),
    .ddram_odt            (ddram_odt),
    .ddram_ras_n          (ddram_ras_n),
    .ddram_reset_n        (ddram_reset_n),
    .ddram_we_n           (ddram_we_n),

    .init_done            (litedram_init_done),
    .init_error           (litedram_init_error),
    .pll_locked           (litedram_pll_locked),
    .user_clk             (litedram_user_clk),
    .user_rst             (litedram_user_rst),

    .user_port_wb_ack     (litedram_wb_ack),
    .user_port_wb_adr     (user_wb_adr),
    .user_port_wb_cyc     (user_wb_cyc),
    .user_port_wb_dat_r   (litedram_wb_dat_r),
    .user_port_wb_dat_w   (user_wb_dat_w),
    .user_port_wb_err     (litedram_wb_err),
    .user_port_wb_sel     (user_wb_sel),
    .user_port_wb_stb     (user_wb_stb),
    .user_port_wb_we      (user_wb_we),

    // Drain the embedded BIOS FIFO output silently. It is used only for DDR3
    // initialization, not for the Hazard3 console UART.
    .uart_rx_data         (8'd0),
    .uart_rx_ready        (litedram_uart_rx_ready_unused),
    .uart_rx_valid        (1'b0),
    .uart_tx_data         (litedram_uart_tx_data_unused),
    .uart_tx_ready        (1'b1),
    .uart_tx_valid        (litedram_uart_tx_valid_unused)
);

// The differential negative pins are supplied automatically by the ECP5
// differential I/O cells selected on ddram_clk_p and ddram_dqs_p in the LPF.
// These legacy ports remain only to avoid changing example_soc's interface.
assign ddram_clk_n = 1'b0;
assign ddram_dqs_n = 2'bzz;

// ULX4M board workaround: do not serialize the misplaced physical DM pins.
assign ddram_dm = 2'b00;

// -------------------------------------------------------------------------
// 50 MHz AHB/video request state machine.

wire grant_video = state == ST_IDLE && calib_complete && video_req_valid &&
    (!ahb_request_present || !last_grant_video);
wire accept_ahb = state == ST_IDLE && calib_complete && ahbls_hready &&
    ahb_request_present && !grant_video;
wire accept_video = grant_video;

assign ahbls_hready_resp = state == ST_IDLE && calib_complete && !grant_video;
assign ahbls_hresp = 1'b0;
assign ahbls_hrdata = read_data;
assign video_req_ready = accept_video;

// Expand the saved byte-select bits into a 128-bit merge mask.
wire [127:0] request_byte_mask = {
    {8{request_sel[15]}}, {8{request_sel[14]}},
    {8{request_sel[13]}}, {8{request_sel[12]}},
    {8{request_sel[11]}}, {8{request_sel[10]}},
    {8{request_sel[9]}},  {8{request_sel[8]}},
    {8{request_sel[7]}},  {8{request_sel[6]}},
    {8{request_sel[5]}},  {8{request_sel[4]}},
    {8{request_sel[3]}},  {8{request_sel[2]}},
    {8{request_sel[1]}},  {8{request_sel[0]}}
};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= ST_IDLE;
        request_owner_video <= 1'b0;
        request_write <= 1'b0;
        request_line_addr <= 26'd0;
        request_word_index <= 2'd0;
        request_halfword_index <= 3'd0;
        request_byte_offset <= 4'd0;
        request_hsize <= 3'd0;
        request_wdata <= 128'd0;
        request_sel <= 16'd0;
        read_data <= 32'd0;
        video_rsp_valid <= 1'b0;
        video_rsp_rdata <= 16'd0;
        last_grant_video <= 1'b1;
        rmw_active <= 1'b0;
        request_toggle <= 1'b0;
        response_toggle_sync0 <= 1'b0;
        response_toggle_sync1 <= 1'b0;
        response_toggle_seen <= 1'b0;
        wb_error_sticky <= 1'b0;
    end else begin
        response_toggle_sync0 <= response_toggle;
        response_toggle_sync1 <= response_toggle_sync0;
        video_rsp_valid <= 1'b0;

        case (state)
        ST_IDLE: begin
            if (accept_video) begin
                request_owner_video <= 1'b1;
                request_write <= 1'b0;
                request_line_addr <= {4'b0000, video_req_addr[24:3]};
                request_halfword_index <= video_req_addr[2:0];
                request_wdata <= 128'd0;
                request_sel <= 16'd0;
                last_grant_video <= 1'b1;
                rmw_active <= 1'b0;
                state <= ST_CDC_REQUEST;
            end else if (accept_ahb) begin
                request_owner_video <= 1'b0;
                request_write <= ahbls_hwrite;
                request_line_addr <= {4'b0000, ahbls_haddr[25:4]};
                request_word_index <= ahbls_haddr[3:2];
                request_byte_offset <= ahbls_haddr[3:0];
                request_hsize <= ahbls_hsize;
                request_wdata <= 128'd0;
                request_sel <= 16'd0;
                last_grant_video <= 1'b0;
                rmw_active <= 1'b0;

                if (ahbls_hwrite) begin
                    state <= ST_WRITE_CAPTURE;
                end else begin
                    state <= ST_CDC_REQUEST;
                end
            end
        end

        ST_WRITE_CAPTURE: begin
            // AHB write data follows the accepted address/control phase by one
            // cycle. Position the complete 32-bit bus word in its burst lane.
            case (request_word_index)
            2'd0: request_wdata <= {96'd0, ahbls_hwdata};
            2'd1: request_wdata <= {64'd0, ahbls_hwdata, 32'd0};
            2'd2: request_wdata <= {32'd0, ahbls_hwdata, 64'd0};
            default: request_wdata <= {ahbls_hwdata, 96'd0};
            endcase

            case (request_hsize)
            3'b000: request_sel <= 16'h0001 << request_byte_offset;
            3'b001: request_sel <= 16'h0003 <<
                {request_byte_offset[3:1], 1'b0};
            default: request_sel <= 16'h000f <<
                {request_byte_offset[3:2], 2'b00};
            endcase

            // First read the complete burst. The response is merged below and
            // sent back as a second, fully selected write transaction.
            request_write <= 1'b0;
            rmw_active <= 1'b1;
            state <= ST_CDC_REQUEST;
        end

        ST_CDC_REQUEST: begin
            request_toggle <= ~request_toggle;
            state <= ST_CDC_WAIT;
        end

        ST_CDC_WAIT: begin
            if (response_toggle_sync1 != response_toggle_seen) begin
                response_toggle_seen <= response_toggle_sync1;
                if (response_error_hold) begin
                    wb_error_sticky <= 1'b1;
                    rmw_active <= 1'b0;
                    state <= ST_IDLE;
                end else if (rmw_active && !request_write) begin
                    request_wdata <=
                        (response_data_hold & ~request_byte_mask) |
                        (request_wdata & request_byte_mask);
                    request_sel <= 16'hffff;
                    request_write <= 1'b1;
                    state <= ST_CDC_REQUEST;
                end else begin
                    if (request_owner_video) begin
                        case (request_halfword_index)
                        3'd0: video_rsp_rdata <= response_data_hold[15:0];
                        3'd1: video_rsp_rdata <= response_data_hold[31:16];
                        3'd2: video_rsp_rdata <= response_data_hold[47:32];
                        3'd3: video_rsp_rdata <= response_data_hold[63:48];
                        3'd4: video_rsp_rdata <= response_data_hold[79:64];
                        3'd5: video_rsp_rdata <= response_data_hold[95:80];
                        3'd6: video_rsp_rdata <= response_data_hold[111:96];
                        default: video_rsp_rdata <= response_data_hold[127:112];
                        endcase
                        video_rsp_valid <= 1'b1;
                    end else if (!request_write) begin
                        case (request_word_index)
                        2'd0: read_data <= response_data_hold[31:0];
                        2'd1: read_data <= response_data_hold[63:32];
                        2'd2: read_data <= response_data_hold[95:64];
                        default: read_data <= response_data_hold[127:96];
                        endcase
                    end
                    rmw_active <= 1'b0;
                    state <= ST_IDLE;
                end
            end
        end

        default: state <= ST_IDLE;
        endcase
    end
end

// Status register layout:
// [31:16] 0x4c44 ("LD" marker)
// [15] request toggle, [14] response pending, [13] write, [12] video owner
// [11] RMW active, [10:8] adapter state
// [7] Wishbone error sticky, [6] user-port busy, [5] adapter busy
// [4] ready, [3] user clock out of reset, [2] PLL lock, [1] init error,
// [0] init done.
assign debug_status = {
    16'h4c44,
    request_toggle,
    response_toggle_sync1 != response_toggle_seen,
    request_write,
    request_owner_video,
    rmw_active,
    state,
    wb_error_sticky,
    user_wb_busy_sync1,
    state != ST_IDLE,
    calib_complete,
    !user_rst_sync1,
    pll_locked_sync1,
    init_error_sync1,
    init_done_sync1
};

// LiteDRAM generates its 75/150 MHz domains from litedram_ref_clk. Remaining
// AHB attributes are not required by this one-request-at-a-time adapter.
wire unused = &{1'b0, ahbls_hburst, ahbls_hprot,
    ahbls_hmastlock, litedram_dm_unused, litedram_uart_tx_data_unused,
    litedram_uart_tx_valid_unused, litedram_uart_rx_ready_unused};

endmodule

`default_nettype wire
