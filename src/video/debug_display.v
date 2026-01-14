//////////////////////////////////////////////////////////////////////////////////
//   Debug Display Module for Order Book Project
//   Displays order book statistics on HDMI monitor
//
//   Displays:
//   - Order Count
//   - BBO Count
//   - Current Symbol
//   - Bid/Ask Prices
//   - Spread
//   - Debug Mode
//////////////////////////////////////////////////////////////////////////////////

module debug_display(
        input                       rst_n,
        input                       pclk,
        input                       i_hs,
        input                       i_vs,
        input                       i_de,
        input[23:0]                 i_data,
        // Debug data inputs (synchronized to pclk domain)
        input[31:0]                 order_count,
        input[31:0]                 bbo_count,
        input[63:0]                 current_symbol,
        input[31:0]                 bid_price,
        input[31:0]                 ask_price,
        input[31:0]                 spread,
        input                       bbo_valid,
        input[1:0]                  debug_mode,
        output                      o_hs,
        output                      o_vs,
        output                      o_de,
        output[23:0]                o_data
    );

    parameter OSD_X_START = 12'd50;
    parameter OSD_Y_START = 12'd50;
    parameter CHAR_WIDTH  = 12'd8;
    parameter CHAR_HEIGHT = 12'd16;
    parameter LINE_SPACING = 12'd20;

    wire[11:0]                  pos_x;
    wire[11:0]                  pos_y;
    wire                        pos_hs;
    wire                        pos_vs;
    wire                        pos_de;
    wire[23:0]                  pos_data;
    reg[23:0]                   v_data;

    // Text display region detection
    reg                         region_active;
    reg                         region_active_d0;

    assign o_data = v_data;
    assign o_hs = pos_hs;
    assign o_vs = pos_vs;
    assign o_de = pos_de;

    // Detect text display region (top-left area)
    always@(posedge pclk) begin
        if(pos_y >= OSD_Y_START && pos_y < OSD_Y_START + 12'd300 &&
                pos_x >= OSD_X_START && pos_x < OSD_X_START + 12'd600)
            region_active <= 1'b1;
        else
            region_active <= 1'b0;
    end

    always@(posedge pclk) begin
        region_active_d0 <= region_active;
    end

    // Counter visualization - show as colored squares
    // Different colors for different ranges to make changes visible
    wire [23:0] order_count_color;
    wire [23:0] bbo_count_color;

    // Map counter ranges to colors (helps visualize counter changes)
    assign order_count_color =
        (order_count == 32'd0) ? 24'hff0000 :  // RED = zero (problem!)
        (order_count < 32'd100) ? 24'h00ff00 : // GREEN = 1-99
        (order_count < 32'd1000) ? 24'h00ffff : // CYAN = 100-999
        (order_count < 32'd10000) ? 24'hffff00 : // YELLOW = 1k-9k
        24'hff00ff;  // MAGENTA = 10k+

    assign bbo_count_color =
        (bbo_count == 32'd0) ? 24'hff0000 :
        (bbo_count < 32'd100) ? 24'h00ff00 :
        (bbo_count < 32'd1000) ? 24'h00ffff :
        (bbo_count < 32'd10000) ? 24'hffff00 :
        24'hff00ff;

    always@(posedge pclk) begin
        if(region_active_d0 == 1'b1)
            // Show counter values as colored squares
            if((pos_x[3:0] == 4'b0000) || (pos_y[3:0] == 4'b0000))
                v_data <= 24'hffffff;  // White grid
            else if((pos_x >= 12'd50 && pos_x < 12'd300) && (pos_y >= 12'd50 && pos_y < 12'd120))
                // Large square: ITCH counter (25MHz domain)
                v_data <= order_count_color;
            else if((pos_x >= 12'd320 && pos_x < 12'd570) && (pos_y >= 12'd50 && pos_y < 12'd120))
                // Large square: BBO counter (for comparison)
                v_data <= bbo_count_color;
            else if((pos_x >= 12'd50 && pos_x < 12'd200) && (pos_y >= 12'd140 && pos_y < 12'd156))
                // Debug mode indicator
                v_data <= (debug_mode[0] || debug_mode[1]) ? 24'h00ff00 : 24'h808080;
            else if((pos_x >= 12'd50 && pos_x < 12'd200) && (pos_y >= 12'd170 && pos_y < 12'd186))
                // BBO valid indicator
                v_data <= bbo_valid ? 24'h00ff00 : 24'hff0000;
            else
                v_data <= pos_data;    // Background
        else
            v_data <= pos_data;
    end

    // Timing generator for pixel position
    timing_gen_xy timing_gen_xy_m0
                  (
                      .rst_n                      (rst_n                  ),
                      .clk                        (pclk                   ),
                      .i_hs                       (i_hs                   ),
                      .i_vs                       (i_vs                   ),
                      .i_de                       (i_de                   ),
                      .i_data                     (i_data                 ),
                      .o_hs                       (pos_hs                 ),
                      .o_vs                       (pos_vs                 ),
                      .o_de                       (pos_de                 ),
                      .o_data                     (pos_data               ),
                      .x                          (pos_x                  ),
                      .y                          (pos_y                  )
                  );

endmodule
