/*****************************************************************************\
|                        Copyright (C) 2026 gojimmypi                        |
|                         SPDX-License-Identifier: MIT                       |
\*****************************************************************************/

`default_nettype none

// Resource-lean 320x200 HDMI source for compact ULX3S targets.
//
// Completed frames remain in the uncached external-SDRAM video aperture. The
// display engine fetches one 320-pixel source line at a time through the SoC's
// native SDRAM read port. One DP16KD holds two alternating 320-byte line
// buffers, and one DP16KD holds the two 256-entry RGB332 palettes. This avoids
// the two full-frame EBR banks used by the 85F performance target.
//
// CONTROL/PRESENT keeps the existing software contract. A present request is
// acknowledged only when the selected SDRAM source buffer becomes active at
// vertical blank, so software cannot reuse the old front buffer too early.
// Direct-EBR, 400x240 and 512x300 capabilities intentionally report disabled.
module ulx3s_hdmi_sdram_scanout #(
    parameter [24:0] FRAMEBUFFER0_HALFWORD_BASE = 25'h1e00000,
    parameter [24:0] FRAMEBUFFER1_HALFWORD_BASE = 25'h1e08000
) (
    input  wire        clk_sys,
    input  wire        rst_n_sys,
    input  wire        clk_pix,
    input  wire        rst_n_pix,
    input  wire        clk_tmds_x5,
    input  wire        rst_n_tmds_x5,

    output wire        sdram_req_valid,
    input  wire        sdram_req_ready,
    output wire [24:0] sdram_req_addr,
    input  wire        sdram_rsp_valid,
    input  wire [15:0] sdram_rsp_rdata,
    input  wire        sdram_init_done,

    input  wire        apbs_psel,
    input  wire        apbs_penable,
    input  wire        apbs_pwrite,
    input  wire [15:0] apbs_paddr,
    input  wire [31:0] apbs_pwdata,
    output reg  [31:0] apbs_prdata,
    output wire        apbs_pready,
    output wire        apbs_pslverr,

    output wire [3:0]  gpdi_dp
);

localparam H_ACTIVE = 1024;
localparam H_FRONT  = 48;
localparam H_SYNC   = 96;
localparam H_BACK   = 144;
localparam H_TOTAL  = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;

localparam V_ACTIVE = 600;
localparam V_FRONT  = 3;
localparam V_SYNC   = 10;
localparam V_BACK   = 11;
localparam V_TOTAL  = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;

localparam SOURCE_WIDTH = 320;
localparam SOURCE_HEIGHT = 200;
localparam SOURCE_WORDS_PER_LINE = SOURCE_WIDTH / 2;

localparam [3:0]
    REG_STATUS         = 4'h0,
    REG_CONTROL        = 4'h1,
    REG_PALETTE_INDEX  = 4'h2,
    REG_PALETTE_DATA   = 4'h3,
    REG_FRAME_COUNT    = 4'h4,
    REG_DMA_CYCLES     = 4'h5,
    REG_PRESENT_COUNT  = 4'h6,
    REG_DIRECT_ADDRESS = 4'hb,
    REG_DIRECT_DATA    = 4'hc;

localparam CONTROL_INDEXED = 0;
localparam CONTROL_BUFFER  = 1;
localparam CONTROL_PRESENT = 2;

wire [3:0] apb_word_address = apbs_paddr[5:2];
assign apbs_pready = 1'b1;
assign apbs_pslverr = 1'b0;
wire apb_write = apbs_psel && apbs_penable && apbs_pwrite;

// ----------------------------------------------------------------------------
// Palette RAM. Bit 8 selects the palette associated with SDRAM buffer 0 or 1.

reg  [8:0] palette_address_sys;
wire       palette_write_enable = apb_write &&
    apb_word_address == REG_PALETTE_DATA;
wire [8:0] palette_read_address;
wire [7:0] palette_read_data;

ulx3s_palette_ram palette_ram_u (
    .write_clk     (clk_sys),
    .write_enable  (palette_write_enable),
    .write_address (palette_address_sys),
    .write_data    (apbs_pwdata[7:0]),
    .read_clk      (clk_pix),
    .read_address  (palette_read_address),
    .read_data     (palette_read_data)
);

// ----------------------------------------------------------------------------
// Two 320-byte line buffers packed into one 1024x16 DP16KD.

wire        line_write_enable;
wire [9:0]  line_write_address;
wire [15:0] line_write_data;
wire [9:0]  line_read_address;
wire [15:0] line_read_data;

ulx3s_dp16kd_1024x16 line_ram_u (
    .write_clk     (clk_sys),
    .write_enable  (line_write_enable),
    .write_address (line_write_address),
    .write_data    (line_write_data),
    .read_clk      (clk_pix),
    .read_address  (line_read_address),
    .read_data     (line_read_data)
);

// ----------------------------------------------------------------------------
// Pixel-to-system line request CDC and external-SDRAM line fetcher.

reg        line_req_toggle_pix;
reg [7:0]  line_req_number_pix;
reg        line_req_bank_pix;
reg        line_req_source_pix;

(* async_reg = "true" *) reg line_req_toggle_sync0;
(* async_reg = "true" *) reg line_req_toggle_sync1;
reg [7:0] line_req_number_sync0;
reg [7:0] line_req_number_sync1;
reg line_req_bank_sync0;
reg line_req_bank_sync1;
reg line_req_source_sync0;
reg line_req_source_sync1;

reg line_ack_toggle_sys;
reg [7:0] line_ack_number_sys;
reg line_ack_bank_sys;

localparam [1:0]
    FETCH_WAIT_INIT = 2'd0,
    FETCH_IDLE      = 2'd1,
    FETCH_REQUEST   = 2'd2,
    FETCH_RESPONSE  = 2'd3;

reg [1:0] fetch_state;
reg line_req_seen_sys;
reg [7:0] fetch_line;
reg fetch_bank;
reg fetch_source;
reg [7:0] fetch_word;

wire [24:0] fetch_source_base = fetch_source
    ? FRAMEBUFFER1_HALFWORD_BASE : FRAMEBUFFER0_HALFWORD_BASE;
wire [24:0] fetch_line_word_base =
    ({17'd0, fetch_line} << 7) + ({17'd0, fetch_line} << 5);

assign sdram_req_valid = fetch_state == FETCH_REQUEST;
assign sdram_req_addr = fetch_source_base + fetch_line_word_base +
    {17'd0, fetch_word};

assign line_write_enable = fetch_state == FETCH_RESPONSE && sdram_rsp_valid;
assign line_write_address = {fetch_bank, 1'b0, fetch_word};
assign line_write_data = sdram_rsp_rdata;

always @ (posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        line_req_toggle_sync0 <= 1'b0;
        line_req_toggle_sync1 <= 1'b0;
        line_req_number_sync0 <= 8'd0;
        line_req_number_sync1 <= 8'd0;
        line_req_bank_sync0 <= 1'b0;
        line_req_bank_sync1 <= 1'b0;
        line_req_source_sync0 <= 1'b0;
        line_req_source_sync1 <= 1'b0;
    end else begin
        line_req_toggle_sync0 <= line_req_toggle_pix;
        line_req_toggle_sync1 <= line_req_toggle_sync0;
        line_req_number_sync0 <= line_req_number_pix;
        line_req_number_sync1 <= line_req_number_sync0;
        line_req_bank_sync0 <= line_req_bank_pix;
        line_req_bank_sync1 <= line_req_bank_sync0;
        line_req_source_sync0 <= line_req_source_pix;
        line_req_source_sync1 <= line_req_source_sync0;
    end
end

always @ (posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        fetch_state <= FETCH_WAIT_INIT;
        line_req_seen_sys <= 1'b0;
        fetch_line <= 8'd0;
        fetch_bank <= 1'b0;
        fetch_source <= 1'b0;
        fetch_word <= 8'd0;
        line_ack_toggle_sys <= 1'b0;
        line_ack_number_sys <= 8'd0;
        line_ack_bank_sys <= 1'b0;
    end else begin
        case (fetch_state)
        FETCH_WAIT_INIT: begin
            if (sdram_init_done)
                fetch_state <= FETCH_IDLE;
        end

        FETCH_IDLE: begin
            if (line_req_toggle_sync1 != line_req_seen_sys) begin
                line_req_seen_sys <= line_req_toggle_sync1;
                fetch_line <= line_req_number_sync1;
                fetch_bank <= line_req_bank_sync1;
                fetch_source <= line_req_source_sync1;
                fetch_word <= 8'd0;
                fetch_state <= FETCH_REQUEST;
            end
        end

        FETCH_REQUEST: begin
            if (sdram_req_ready)
                fetch_state <= FETCH_RESPONSE;
        end

        FETCH_RESPONSE: begin
            if (sdram_rsp_valid) begin
                if (fetch_word == SOURCE_WORDS_PER_LINE - 1) begin
                    line_ack_number_sys <= fetch_line;
                    line_ack_bank_sys <= fetch_bank;
                    line_ack_toggle_sys <= line_req_seen_sys;
                    fetch_state <= FETCH_IDLE;
                end else begin
                    fetch_word <= fetch_word + 1'b1;
                    fetch_state <= FETCH_REQUEST;
                end
            end
        end

        default:
            fetch_state <= FETCH_WAIT_INIT;
        endcase
    end
end

// ----------------------------------------------------------------------------
// APB presentation command and system-domain status synchronization.

reg control_indexed_sys;
reg control_buffer_sys;
reg swap_toggle_sys;
reg swap_source_sys;
reg swap_indexed_sys;
reg [31:0] present_count_sys;
reg swap_ack_seen_sys;

reg swap_ack_pix;
reg current_source_buffer_pix;
reg current_indexed_pix;
reg frame_valid_pix;
reg [31:0] frame_count_pix;
wire vblank_pix;

(* async_reg = "true" *) reg swap_ack_sync0;
(* async_reg = "true" *) reg swap_ack_sync1;
(* async_reg = "true" *) reg current_source_sync0;
(* async_reg = "true" *) reg current_source_sync1;
(* async_reg = "true" *) reg current_indexed_sync0;
(* async_reg = "true" *) reg current_indexed_sync1;
(* async_reg = "true" *) reg frame_valid_sync0;
(* async_reg = "true" *) reg frame_valid_sync1;
(* async_reg = "true" *) reg vblank_sync0;
(* async_reg = "true" *) reg vblank_sync1;
reg [31:0] frame_count_sync0;
reg [31:0] frame_count_sync1;

wire present_pending_sys = swap_ack_sync1 != swap_toggle_sys;
wire present_command = apb_write && apb_word_address == REG_CONTROL &&
    apbs_pwdata[CONTROL_PRESENT];

always @ (posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        swap_ack_sync0 <= 1'b0;
        swap_ack_sync1 <= 1'b0;
        current_source_sync0 <= 1'b0;
        current_source_sync1 <= 1'b0;
        current_indexed_sync0 <= 1'b0;
        current_indexed_sync1 <= 1'b0;
        frame_valid_sync0 <= 1'b0;
        frame_valid_sync1 <= 1'b0;
        vblank_sync0 <= 1'b0;
        vblank_sync1 <= 1'b0;
        frame_count_sync0 <= 32'd0;
        frame_count_sync1 <= 32'd0;
    end else begin
        swap_ack_sync0 <= swap_ack_pix;
        swap_ack_sync1 <= swap_ack_sync0;
        current_source_sync0 <= current_source_buffer_pix;
        current_source_sync1 <= current_source_sync0;
        current_indexed_sync0 <= current_indexed_pix;
        current_indexed_sync1 <= current_indexed_sync0;
        frame_valid_sync0 <= frame_valid_pix;
        frame_valid_sync1 <= frame_valid_sync0;
        vblank_sync0 <= vblank_pix;
        vblank_sync1 <= vblank_sync0;
        frame_count_sync0 <= frame_count_pix;
        frame_count_sync1 <= frame_count_sync0;
    end
end

always @ (posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        palette_address_sys <= 9'd0;
        control_indexed_sys <= 1'b0;
        control_buffer_sys <= 1'b0;
        swap_toggle_sys <= 1'b0;
        swap_source_sys <= 1'b0;
        swap_indexed_sys <= 1'b0;
        present_count_sys <= 32'd0;
        swap_ack_seen_sys <= 1'b0;
    end else begin
        if (apb_write && apb_word_address == REG_PALETTE_INDEX)
            palette_address_sys <= apbs_pwdata[8:0];
        else if (palette_write_enable)
            palette_address_sys <=
                {palette_address_sys[8], palette_address_sys[7:0] + 1'b1};

        if (apb_write && apb_word_address == REG_CONTROL) begin
            control_indexed_sys <= apbs_pwdata[CONTROL_INDEXED];
            control_buffer_sys <= apbs_pwdata[CONTROL_BUFFER];
        end

        if (present_command && sdram_init_done && !present_pending_sys) begin
            swap_source_sys <= apbs_pwdata[CONTROL_BUFFER];
            swap_indexed_sys <= apbs_pwdata[CONTROL_INDEXED];
            swap_toggle_sys <= !swap_toggle_sys;
        end

        if (swap_ack_sync1 != swap_ack_seen_sys) begin
            swap_ack_seen_sys <= swap_ack_sync1;
            present_count_sys <= present_count_sys + 1'b1;
        end
    end
end

always @ (*) begin
    apbs_prdata = 32'd0;
    case (apb_word_address)
    REG_STATUS: begin
        apbs_prdata[0] = current_source_sync1;
        apbs_prdata[1] = present_pending_sys;
        apbs_prdata[2] = current_indexed_sync1;
        apbs_prdata[3] = vblank_sync1;
        apbs_prdata[4] = sdram_init_done;
        apbs_prdata[5] = frame_valid_sync1;
        apbs_prdata[6] = 1'b0; // no full-frame internal bank
        apbs_prdata[7] = 1'b0; // no presentation DMA
        apbs_prdata[8] = present_pending_sys;
        apbs_prdata[9] = 1'b0; // direct EBR writes unsupported
        apbs_prdata[10] = 1'b0;
        apbs_prdata[11] = 1'b0; // 400x240 unsupported on compact target
        apbs_prdata[12] = 1'b0;
        apbs_prdata[13] = 1'b0; // 512x300 GUI unsupported
        apbs_prdata[14] = 1'b0;
    end
    REG_CONTROL:
        apbs_prdata = {30'd0, control_buffer_sys, control_indexed_sys};
    REG_PALETTE_INDEX:
        apbs_prdata = {23'd0, palette_address_sys};
    REG_PALETTE_DATA:
        apbs_prdata = 32'd0;
    REG_FRAME_COUNT:
        apbs_prdata = frame_count_sync1;
    REG_DMA_CYCLES:
        apbs_prdata = 32'd0;
    REG_PRESENT_COUNT:
        apbs_prdata = present_count_sys;
    REG_DIRECT_ADDRESS, REG_DIRECT_DATA:
        apbs_prdata = 32'd0;
    default:
        apbs_prdata = 32'd0;
    endcase
end

// ----------------------------------------------------------------------------
// System-to-pixel presentation CDC.

(* async_reg = "true" *) reg swap_toggle_sync0;
(* async_reg = "true" *) reg swap_toggle_sync1;
reg swap_toggle_seen_pix;
reg swap_source_sync0;
reg swap_source_sync1;
reg swap_indexed_sync0;
reg swap_indexed_sync1;

(* async_reg = "true" *) reg line_ack_toggle_sync0;
(* async_reg = "true" *) reg line_ack_toggle_sync1;
reg [7:0] line_ack_number_sync0;
reg [7:0] line_ack_number_sync1;
reg line_ack_bank_sync0;
reg line_ack_bank_sync1;
reg line_ack_seen_pix;
reg [1:0] line_ready_valid_pix;
reg [7:0] line_ready_number0_pix;
reg [7:0] line_ready_number1_pix;
reg line_req_pending_pix;

always @ (posedge clk_pix or negedge rst_n_pix) begin
    if (!rst_n_pix) begin
        swap_toggle_sync0 <= 1'b0;
        swap_toggle_sync1 <= 1'b0;
        swap_source_sync0 <= 1'b0;
        swap_source_sync1 <= 1'b0;
        swap_indexed_sync0 <= 1'b0;
        swap_indexed_sync1 <= 1'b0;
        line_ack_toggle_sync0 <= 1'b0;
        line_ack_toggle_sync1 <= 1'b0;
        line_ack_number_sync0 <= 8'd0;
        line_ack_number_sync1 <= 8'd0;
        line_ack_bank_sync0 <= 1'b0;
        line_ack_bank_sync1 <= 1'b0;
    end else begin
        swap_toggle_sync0 <= swap_toggle_sys;
        swap_toggle_sync1 <= swap_toggle_sync0;
        swap_source_sync0 <= swap_source_sys;
        swap_source_sync1 <= swap_source_sync0;
        swap_indexed_sync0 <= swap_indexed_sys;
        swap_indexed_sync1 <= swap_indexed_sync0;
        line_ack_toggle_sync0 <= line_ack_toggle_sys;
        line_ack_toggle_sync1 <= line_ack_toggle_sync0;
        line_ack_number_sync0 <= line_ack_number_sys;
        line_ack_number_sync1 <= line_ack_number_sync0;
        line_ack_bank_sync0 <= line_ack_bank_sys;
        line_ack_bank_sync1 <= line_ack_bank_sync0;
    end
end

// ----------------------------------------------------------------------------
// 1024x600 timing and source-line scheduling.

reg [10:0] pixel_x;
reg [9:0] pixel_y;
reg [8:0] source_x;
reg [7:0] source_y;
reg [1:0] vertical_repeat;
reg [10:0] horizontal_phase;
reg active_line_bank_pix;
reg pixel_toggle;

wire active_video_now = pixel_x < H_ACTIVE && pixel_y < V_ACTIVE;
wire hsync_now = pixel_x >= H_ACTIVE + H_FRONT &&
    pixel_x < H_ACTIVE + H_FRONT + H_SYNC;
wire vsync_now = pixel_y >= V_ACTIVE + V_FRONT &&
    pixel_y < V_ACTIVE + V_FRONT + V_SYNC;
wire vblank_start = pixel_x == 0 && pixel_y == V_ACTIVE;
assign vblank_pix = pixel_y >= V_ACTIVE;

wire active_line_ready = active_line_bank_pix
    ? (line_ready_valid_pix[1] && line_ready_number1_pix == source_y)
    : (line_ready_valid_pix[0] && line_ready_number0_pix == source_y);

assign line_read_address = {active_line_bank_pix, 1'b0, source_x[8:1]};

// Issue only one native SDRAM line request at a time. Requests occur at the
// start of the first displayed repetition of each source line; the following
// source line then has almost three complete 1312-pixel rows to arrive.
task request_line;
    input [7:0] request_number;
    input       request_bank;
    input       request_source;
    begin
        line_req_number_pix <= request_number;
        line_req_bank_pix <= request_bank;
        line_req_source_pix <= request_source;
        line_req_toggle_pix <= !line_req_toggle_pix;
        line_req_pending_pix <= 1'b1;
    end
endtask

always @ (posedge clk_pix or negedge rst_n_pix) begin
    if (!rst_n_pix) begin
        pixel_x <= 11'd0;
        pixel_y <= 10'd0;
        source_x <= 9'd0;
        source_y <= 8'd0;
        vertical_repeat <= 2'd0;
        horizontal_phase <= 11'd0;
        active_line_bank_pix <= 1'b0;
        pixel_toggle <= 1'b0;
        frame_count_pix <= 32'd0;
        frame_valid_pix <= 1'b0;
        current_source_buffer_pix <= 1'b0;
        current_indexed_pix <= 1'b0;
        swap_toggle_seen_pix <= 1'b0;
        swap_ack_pix <= 1'b0;
        line_req_toggle_pix <= 1'b0;
        line_req_number_pix <= 8'd0;
        line_req_bank_pix <= 1'b0;
        line_req_source_pix <= 1'b0;
        line_ack_seen_pix <= 1'b0;
        line_ready_valid_pix <= 2'b00;
        line_ready_number0_pix <= 8'd0;
        line_ready_number1_pix <= 8'd0;
        line_req_pending_pix <= 1'b0;
    end else begin
        pixel_toggle <= !pixel_toggle;

        if (line_ack_toggle_sync1 != line_ack_seen_pix) begin
            line_ack_seen_pix <= line_ack_toggle_sync1;
            line_req_pending_pix <= 1'b0;
            if (line_ack_bank_sync1) begin
                line_ready_valid_pix[1] <= 1'b1;
                line_ready_number1_pix <= line_ack_number_sync1;
            end else begin
                line_ready_valid_pix[0] <= 1'b1;
                line_ready_number0_pix <= line_ack_number_sync1;
            end
        end

        if (vblank_start) begin
            // Every 60 Hz panel frame must refill line 0 even when software
            // has not presented a new Doom frame. Doom typically presents at
            // a substantially lower rate than the HDMI refresh rate.
            line_ready_valid_pix <= 2'b00;
            if (swap_toggle_sync1 != swap_toggle_seen_pix) begin
                current_source_buffer_pix <= swap_source_sync1;
                current_indexed_pix <= swap_indexed_sync1;
                frame_valid_pix <= 1'b1;
                swap_toggle_seen_pix <= swap_toggle_sync1;
                swap_ack_pix <= swap_toggle_sync1;
                if (!line_req_pending_pix)
                    request_line(8'd0, 1'b0, swap_source_sync1);
            end else if (frame_valid_pix && !line_req_pending_pix) begin
                request_line(8'd0, 1'b0, current_source_buffer_pix);
            end
        end

        // If an unusually delayed final-line request crossed into vblank, issue
        // the line-0 refill as soon as that request completes. The 24-line
        // blanking interval normally leaves ample time before active video.
        if (!vblank_start && vblank_pix && frame_valid_pix &&
            !line_req_pending_pix && !line_ready_valid_pix[0]) begin
            request_line(8'd0, 1'b0, current_source_buffer_pix);
        end

        if (pixel_x == 0 && pixel_y < V_ACTIVE && vertical_repeat == 0 &&
            frame_valid_pix && !line_req_pending_pix) begin
            // Normally the current line arrived during the preceding three
            // display rows, so prefetch the next source line. If line 0 was
            // delayed across vblank (or any line missed its deadline), fetch
            // the current line first instead of skipping it permanently.
            if (!active_line_ready) begin
                request_line(source_y, active_line_bank_pix,
                    current_source_buffer_pix);
            end else if (source_y < SOURCE_HEIGHT - 1) begin
                request_line(source_y + 1'b1, !active_line_bank_pix,
                    current_source_buffer_pix);
            end
        end

        if (pixel_x == H_TOTAL - 1) begin
            pixel_x <= 11'd0;
            source_x <= 9'd0;
            horizontal_phase <= 11'd0;

            if (pixel_y == V_TOTAL - 1) begin
                pixel_y <= 10'd0;
                source_y <= 8'd0;
                vertical_repeat <= 2'd0;
                active_line_bank_pix <= 1'b0;
                frame_count_pix <= frame_count_pix + 1'b1;
            end else begin
                pixel_y <= pixel_y + 1'b1;
                if (pixel_y < V_ACTIVE - 1) begin
                    if (vertical_repeat == 2) begin
                        vertical_repeat <= 2'd0;
                        source_y <= source_y + 1'b1;
                        active_line_bank_pix <= !active_line_bank_pix;
                    end else begin
                        vertical_repeat <= vertical_repeat + 1'b1;
                    end
                end
            end
        end else begin
            pixel_x <= pixel_x + 1'b1;
            if (pixel_x < H_ACTIVE - 1) begin
                if (horizontal_phase + SOURCE_WIDTH >= H_ACTIVE) begin
                    horizontal_phase <= horizontal_phase +
                        SOURCE_WIDTH - H_ACTIVE;
                    source_x <= source_x + 1'b1;
                end else begin
                    horizontal_phase <= horizontal_phase + SOURCE_WIDTH;
                end
            end
        end
    end
end

// ----------------------------------------------------------------------------
// Line-RAM read pipeline, palette lookup and RGB332 expansion.

reg source_byte_select_stage1;
reg image_region_stage1;
reg frame_valid_stage1;
reg active_video_stage1;
reg hsync_stage1;
reg vsync_stage1;
reg indexed_stage1;
reg source_buffer_stage1;

wire [7:0] frame_pixel_stage1 = source_byte_select_stage1
    ? line_read_data[15:8] : line_read_data[7:0];
assign palette_read_address = {source_buffer_stage1, frame_pixel_stage1};

reg [7:0] frame_pixel_stage2;
reg image_region_stage2;
reg frame_valid_stage2;
reg active_video_stage2;
reg hsync_stage2;
reg vsync_stage2;
reg indexed_stage2;

always @ (posedge clk_pix or negedge rst_n_pix) begin
    if (!rst_n_pix) begin
        source_byte_select_stage1 <= 1'b0;
        image_region_stage1 <= 1'b0;
        frame_valid_stage1 <= 1'b0;
        active_video_stage1 <= 1'b0;
        hsync_stage1 <= 1'b0;
        vsync_stage1 <= 1'b0;
        indexed_stage1 <= 1'b0;
        source_buffer_stage1 <= 1'b0;
        frame_pixel_stage2 <= 8'd0;
        image_region_stage2 <= 1'b0;
        frame_valid_stage2 <= 1'b0;
        active_video_stage2 <= 1'b0;
        hsync_stage2 <= 1'b0;
        vsync_stage2 <= 1'b0;
        indexed_stage2 <= 1'b0;
    end else begin
        source_byte_select_stage1 <= source_x[0];
        image_region_stage1 <= active_video_now;
        frame_valid_stage1 <= frame_valid_pix && active_line_ready;
        active_video_stage1 <= active_video_now;
        hsync_stage1 <= hsync_now;
        vsync_stage1 <= vsync_now;
        indexed_stage1 <= current_indexed_pix;
        source_buffer_stage1 <= current_source_buffer_pix;

        frame_pixel_stage2 <= frame_pixel_stage1;
        image_region_stage2 <= image_region_stage1;
        frame_valid_stage2 <= frame_valid_stage1;
        active_video_stage2 <= active_video_stage1;
        hsync_stage2 <= hsync_stage1;
        vsync_stage2 <= vsync_stage1;
        indexed_stage2 <= indexed_stage1;
    end
end

wire [7:0] display_pixel = indexed_stage2
    ? palette_read_data : frame_pixel_stage2;
wire [7:0] framebuffer_red = {
    display_pixel[7:5], display_pixel[7:5], display_pixel[7:6]
};
wire [7:0] framebuffer_green = {
    display_pixel[4:2], display_pixel[4:2], display_pixel[4:3]
};
wire [7:0] framebuffer_blue = {
    display_pixel[1:0], display_pixel[1:0], display_pixel[1:0], display_pixel[1:0]
};

reg [7:0] red;
reg [7:0] green;
reg [7:0] blue;

always @ (*) begin
    red = 8'h00;
    green = 8'h00;
    blue = 8'h00;

    if (active_video_stage2 && image_region_stage2 && frame_valid_stage2) begin
        red = framebuffer_red;
        green = framebuffer_green;
        blue = framebuffer_blue;
    end
end

wire [9:0] tmds_red;
wire [9:0] tmds_green;
wire [9:0] tmds_blue;

tmds_encode encode_red_u (
    .clk   (clk_pix),
    .rst_n (rst_n_pix),
    .c     (2'b00),
    .d     (red),
    .den   (active_video_stage2),
    .q     (tmds_red)
);

tmds_encode encode_green_u (
    .clk   (clk_pix),
    .rst_n (rst_n_pix),
    .c     (2'b00),
    .d     (green),
    .den   (active_video_stage2),
    .q     (tmds_green)
);

tmds_encode encode_blue_u (
    .clk   (clk_pix),
    .rst_n (rst_n_pix),
    .c     ({vsync_stage2, hsync_stage2}),
    .d     (blue),
    .den   (active_video_stage2),
    .q     (tmds_blue)
);

(* async_reg = "true" *) reg [2:0] pixel_toggle_sync;

always @ (posedge clk_tmds_x5 or negedge rst_n_tmds_x5) begin
    if (!rst_n_tmds_x5)
        pixel_toggle_sync <= 3'b000;
    else
        pixel_toggle_sync <= {pixel_toggle_sync[1:0], pixel_toggle};
end

wire load_symbol = pixel_toggle_sync[2] ^ pixel_toggle_sync[1];

ulx3s_tmds_ddr_serialiser serialise_red_u (
    .clk_tmds_x5 (clk_tmds_x5),
    .rst_n        (rst_n_tmds_x5),
    .load_symbol  (load_symbol),
    .symbol       (tmds_red),
    .serial_out   (gpdi_dp[2])
);

ulx3s_tmds_ddr_serialiser serialise_green_u (
    .clk_tmds_x5 (clk_tmds_x5),
    .rst_n        (rst_n_tmds_x5),
    .load_symbol  (load_symbol),
    .symbol       (tmds_green),
    .serial_out   (gpdi_dp[1])
);

ulx3s_tmds_ddr_serialiser serialise_blue_u (
    .clk_tmds_x5 (clk_tmds_x5),
    .rst_n        (rst_n_tmds_x5),
    .load_symbol  (load_symbol),
    .symbol       (tmds_blue),
    .serial_out   (gpdi_dp[0])
);

ulx3s_tmds_ddr_serialiser serialise_clock_u (
    .clk_tmds_x5 (clk_tmds_x5),
    .rst_n        (rst_n_tmds_x5),
    .load_symbol  (load_symbol),
    .symbol       (10'b0000011111),
    .serial_out   (gpdi_dp[3])
);

endmodule

`ifndef YOSYS
`default_nettype wire
`endif
