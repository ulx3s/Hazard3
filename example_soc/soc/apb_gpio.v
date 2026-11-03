/*****************************************************************************\
|                        Copyright (C) 2026 gojimmypi                        |
|                     SPDX-License-Identifier: Apache-2.0                    |
\*****************************************************************************/

`default_nettype none

module apb_gpio #(
    parameter GPIO_IN_WIDTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        apbs_psel,
    input  wire        apbs_penable,
    input  wire        apbs_pwrite,
    input  wire [15:0] apbs_paddr,
    input  wire [31:0] apbs_pwdata,
    output wire [31:0] apbs_prdata,
    output wire        apbs_pready,
    output wire        apbs_pslverr,

    input  wire [(GPIO_IN_WIDTH - 1):0] gpio_in,
    output reg  [7:0]  gpio_out
);

localparam [15:0] ADDR_GPIO_OUT = 16'h8000;
localparam [15:0] ADDR_GPIO_IN  = 16'h8004;

wire gpio_out_addr_hit = apbs_paddr[15:2] == ADDR_GPIO_OUT[15:2];
wire gpio_in_addr_hit  = apbs_paddr[15:2] == ADDR_GPIO_IN[15:2];

wire gpio_wen = apbs_psel && apbs_penable && apbs_pwrite && gpio_out_addr_hit;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        gpio_out <= 8'h00;
    else if (gpio_wen)
        gpio_out <= apbs_pwdata[7:0];
end

assign apbs_prdata = gpio_out_addr_hit ? {24'h000000, gpio_out} :
                     gpio_in_addr_hit  ? {{(32 - GPIO_IN_WIDTH){1'b0}}, gpio_in}  :
                                         32'h00000000;
assign apbs_pready = 1'b1;
assign apbs_pslverr = 1'b0;

endmodule
