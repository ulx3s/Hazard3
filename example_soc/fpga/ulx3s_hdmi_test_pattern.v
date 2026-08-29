/*****************************************************************************\
|                        Copyright (C) 2026 gojimmypi                        |
|                         SPDX-License-Identifier: MIT                       |
\*****************************************************************************/

`default_nettype none

// DVI-compatible TMDS output for the ULX3S GPDI connector. The Elecrow panel
// accepts this signal through its HDMI input; HDMI audio and data islands are
// intentionally not generated in this first video bring-up milestone.
//
// Video timing is 1024x600 with a 50 MHz pixel clock and 1312x624 total frame:
//   horizontal: 1024 active, 48 front, 96 sync, 144 back
//   vertical:    600 active,  3 front, 10 sync,  11 back
// This is approximately 61.07 Hz.
module ulx3s_hdmi_test_pattern (
	input  wire       clk_pix,
	input  wire       rst_n_pix,
	input  wire       clk_tmds_x5,
	input  wire       rst_n_tmds_x5,
	output wire [3:0] gpdi_dp
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

reg [10:0] pixel_x;
reg [9:0]  pixel_y;
reg        pixel_toggle;

always @ (posedge clk_pix or negedge rst_n_pix) begin
	if (!rst_n_pix) begin
		pixel_x <= 11'd0;
		pixel_y <= 10'd0;
		pixel_toggle <= 1'b0;
	end else begin
		pixel_toggle <= !pixel_toggle;
		if (pixel_x == H_TOTAL - 1) begin
			pixel_x <= 11'd0;
			if (pixel_y == V_TOTAL - 1)
				pixel_y <= 10'd0;
			else
				pixel_y <= pixel_y + 10'd1;
		end else begin
			pixel_x <= pixel_x + 11'd1;
		end
	end
end

wire active_video = pixel_x < H_ACTIVE && pixel_y < V_ACTIVE;
wire hsync = pixel_x >= H_ACTIVE + H_FRONT
	&& pixel_x < H_ACTIVE + H_FRONT + H_SYNC;
wire vsync = pixel_y >= V_ACTIVE + V_FRONT
	&& pixel_y < V_ACTIVE + V_FRONT + V_SYNC;

reg [7:0] red;
reg [7:0] green;
reg [7:0] blue;

wire border = pixel_x == 0 || pixel_x == H_ACTIVE - 1
	|| pixel_y == 0 || pixel_y == V_ACTIVE - 1;
wire grid = pixel_x[5:0] == 6'd0 || pixel_y[5:0] == 6'd0;

always @ (*) begin
	red = 8'h00;
	green = 8'h00;
	blue = 8'h00;

	if (active_video) begin
		case (pixel_x[9:7])
		3'd0: begin red = 8'hff; green = 8'hff; blue = 8'hff; end
		3'd1: begin red = 8'hff; green = 8'hff; blue = 8'h00; end
		3'd2: begin red = 8'h00; green = 8'hff; blue = 8'hff; end
		3'd3: begin red = 8'h00; green = 8'hff; blue = 8'h00; end
		3'd4: begin red = 8'hff; green = 8'h00; blue = 8'hff; end
		3'd5: begin red = 8'hff; green = 8'h00; blue = 8'h00; end
		3'd6: begin red = 8'h00; green = 8'h00; blue = 8'hff; end
		default: begin red = 8'h00; green = 8'h00; blue = 8'h00; end
		endcase

		if (grid) begin
			red = red >> 1;
			green = green >> 1;
			blue = blue >> 1;
		end

		if (border) begin
			red = 8'hff;
			green = 8'hff;
			blue = 8'hff;
		end
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
	.den   (active_video),
	.q     (tmds_red)
);

tmds_encode encode_green_u (
	.clk   (clk_pix),
	.rst_n (rst_n_pix),
	.c     (2'b00),
	.d     (green),
	.den   (active_video),
	.q     (tmds_green)
);

tmds_encode encode_blue_u (
	.clk   (clk_pix),
	.rst_n (rst_n_pix),
	.c     ({vsync, hsync}),
	.d     (blue),
	.den   (active_video),
	.q     (tmds_blue)
);

// Transfer a once-per-pixel toggle into the 5x serializer domain. The
// synchronizer delays each load until at least one serializer clock after the
// pixel edge, so the registered TMDS symbols are stable before capture. The
// pulse repeats exactly every five serializer clocks because both clocks come
// from the same PLL.
reg [2:0] pixel_toggle_sync;

always @ (posedge clk_tmds_x5 or negedge rst_n_tmds_x5) begin
	if (!rst_n_tmds_x5)
		pixel_toggle_sync <= 3'b000;
	else
		pixel_toggle_sync <= {pixel_toggle_sync[1:0], pixel_toggle};
end

wire load_symbol = pixel_toggle_sync[2] ^ pixel_toggle_sync[1];

ulx3s_tmds_ddr_serialiser serialise_blue_u (
	.clk_tmds_x5 (clk_tmds_x5),
	.rst_n        (rst_n_tmds_x5),
	.load_symbol  (load_symbol),
	.symbol       (tmds_blue),
	.serial_out   (gpdi_dp[0])
);

ulx3s_tmds_ddr_serialiser serialise_green_u (
	.clk_tmds_x5 (clk_tmds_x5),
	.rst_n        (rst_n_tmds_x5),
	.load_symbol  (load_symbol),
	.symbol       (tmds_green),
	.serial_out   (gpdi_dp[1])
);

ulx3s_tmds_ddr_serialiser serialise_red_u (
	.clk_tmds_x5 (clk_tmds_x5),
	.rst_n        (rst_n_tmds_x5),
	.load_symbol  (load_symbol),
	.symbol       (tmds_red),
	.serial_out   (gpdi_dp[2])
);

// The TMDS clock lane sends five ones followed by five zeroes, LSB first.
ulx3s_tmds_ddr_serialiser serialise_clock_u (
	.clk_tmds_x5 (clk_tmds_x5),
	.rst_n        (rst_n_tmds_x5),
	.load_symbol  (load_symbol),
	.symbol       (10'b00000_11111),
	.serial_out   (gpdi_dp[3])
);

endmodule

module ulx3s_tmds_ddr_serialiser (
	input  wire       clk_tmds_x5,
	input  wire       rst_n,
	input  wire       load_symbol,
	input  wire [9:0] symbol,
	output wire       serial_out
);

// 12F timing optimization: localize the serializer reset to the TMDS x5
// clock domain to reduce reset routing pressure and improve timing closure.
`ifdef HAZARD3_ULX3S_12F
    (* keep = 1'b1 *) reg rst_n_local = 1'b0;
    always @ (posedge clk_tmds_x5) begin
	    rst_n_local <= rst_n;
    end
`else
    wire rst_n_local = rst_n;
`endif

reg [9:0] shift_reg;

always @ (posedge clk_tmds_x5 or negedge rst_n_local) begin
	if (!rst_n_local)
		shift_reg <= 10'd0;
	else if (load_symbol)
		shift_reg <= symbol;
	else
		shift_reg <= {2'b00, shift_reg[9:2]};
end

// TMDS serial data is transmitted least-significant bit first. D0 appears on
// the rising edge and D1 follows on the falling edge, yielding ten bits during
// five serializer-clock periods.
ddr_out serial_ddr_u (
	.clk     (clk_tmds_x5),
	.rst_n   (rst_n),
	.d_rise  (shift_reg[0]),
	.d_fall  (shift_reg[1]),
	.e       (1'b1),
	.q       (serial_out)
);

endmodule

`default_nettype wire
