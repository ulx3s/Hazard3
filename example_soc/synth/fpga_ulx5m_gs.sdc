# The board oscillator remains the 25 MHz PLL reference clock.
# nextpnr derives clk_sys from the selected CC_PLL OUT_CLK parameter.
create_clock -name clk25 -period 40.000 [get_ports clk25]
