####################################################################################
## AX7203 Constraints for Project 23 (Order Book with PCIe Output)
## Board: ALINX AX7203B (XC7A200T-2FBG484I)
##
## Merged constraints from:
##   - Project 20: Order Book (ITCH parsing, order book, BBO tracking)
##   - Project 22: PCIe XDMA (BBO streaming to host)
##
## Interfaces:
##   - RGMII Ethernet (1 Gbps ITCH feed input)
##   - PCIe Gen1 x4 (BBO streaming output)
##   - UART (debug output)
##   - LEDs (status indication)
####################################################################################

####################################################################################
## System Configuration
####################################################################################
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

####################################################################################
## System Clock (200 MHz Differential) - Gen2: DISABLED
## The 200 MHz Ethernet oscillator clock was causing Gen2 PCIe to freeze.
## All trading logic now uses PCIe axi_aclk (125/250 MHz) instead.
####################################################################################
# Gen2: Removed - 200 MHz clock disabled to enable Gen2 PCIe operation
# create_clock -period 5.000 -name sys_clk_p [get_ports sys_clk_p]
# set_property PACKAGE_PIN R4 [get_ports sys_clk_p]
# set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]

####################################################################################
## PCIe Reference Clock (100 MHz Differential)
## From PCIe edge connector via buffer to FPGA GTP
####################################################################################
set_property PACKAGE_PIN F10 [get_ports {pcie_refclk_clk_p[0]}]
set_property PACKAGE_PIN E10 [get_ports {pcie_refclk_clk_n[0]}]
create_clock -period 10.000 -name pcie_refclk [get_ports {pcie_refclk_clk_p[0]}]

####################################################################################
## Reset Signals
####################################################################################

## PCIe PERST# (Active Low, from PCIe slot)
set_property PACKAGE_PIN J20 [get_ports pcie_perst_n]
set_property IOSTANDARD LVCMOS33 [get_ports pcie_perst_n]
set_property PULLUP TRUE [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]

## System Reset Button (T6, active LOW)
set_property PACKAGE_PIN T6 [get_ports reset_n]
set_property IOSTANDARD LVCMOS15 [get_ports reset_n]
set_false_path -from [get_ports reset_n]

## Debug Button (KEY2, E13, active LOW - cycles UART debug modes)
set_property PACKAGE_PIN E13 [get_ports debug_btn]
set_property IOSTANDARD LVCMOS33 [get_ports debug_btn]
set_false_path -from [get_ports debug_btn]

####################################################################################
## LEDs (4 Red LEDs for status)
## LED[0]: PCIe Link Up
## LED[1]: Ethernet Link Up / PHY Ready
## LED[2]: BBO Streaming Active
## LED[3]: ITCH Message Activity
####################################################################################
set_property PACKAGE_PIN B13 [get_ports {led[0]}]
set_property PACKAGE_PIN C13 [get_ports {led[1]}]
set_property PACKAGE_PIN D14 [get_ports {led[2]}]
set_property PACKAGE_PIN D15 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
set_false_path -to [get_ports {led[*]}]

####################################################################################
## RGMII Ethernet Port 1 (JL2121 PHY)
## 1 Gbps ITCH feed input
####################################################################################

## RGMII RX Interface (PHY -> FPGA)
create_clock -period 8.000 [get_ports rgmii1_rxc]
set_property PACKAGE_PIN B17 [get_ports rgmii1_rxc]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii1_rxc]

set_property PACKAGE_PIN A15 [get_ports rgmii1_rxctl]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii1_rxctl]

set_property PACKAGE_PIN A16 [get_ports {rgmii1_rxd[0]}]
set_property PACKAGE_PIN B18 [get_ports {rgmii1_rxd[1]}]
set_property PACKAGE_PIN C18 [get_ports {rgmii1_rxd[2]}]
set_property PACKAGE_PIN C19 [get_ports {rgmii1_rxd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii1_rxd[*]}]

## RGMII TX Interface (FPGA -> PHY) - for future TX support
set_property PACKAGE_PIN E18 [get_ports rgmii1_txc]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii1_txc]
set_property SLEW FAST [get_ports rgmii1_txc]
set_property DRIVE 8 [get_ports rgmii1_txc]

set_property PACKAGE_PIN F18 [get_ports rgmii1_txctl]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii1_txctl]
set_property SLEW FAST [get_ports rgmii1_txctl]
set_property DRIVE 8 [get_ports rgmii1_txctl]

set_property PACKAGE_PIN C20 [get_ports {rgmii1_txd[0]}]
set_property PACKAGE_PIN D20 [get_ports {rgmii1_txd[1]}]
set_property PACKAGE_PIN A19 [get_ports {rgmii1_txd[2]}]
set_property PACKAGE_PIN A18 [get_ports {rgmii1_txd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii1_txd[*]}]
set_property SLEW FAST [get_ports {rgmii1_txd[*]}]
set_property DRIVE 8 [get_ports {rgmii1_txd[*]}]

## MDIO Management Interface (not used - ethernet_top handles PHY internally)
## The PHY will auto-negotiate without explicit MDIO configuration
## set_property PACKAGE_PIN B16 [get_ports e1_mdc]
## set_property PACKAGE_PIN B15 [get_ports e1_mdio]

## PHY Reset (active LOW)
set_property PACKAGE_PIN D16 [get_ports e1_reset]
set_property IOSTANDARD LVCMOS33 [get_ports e1_reset]

####################################################################################
## UART Interface (Debug Output) - Gen2: DISABLED (UART removed for PCIe-only output)
####################################################################################
# set_property PACKAGE_PIN P20 [get_ports uart_rxd]
# set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]
# set_property PACKAGE_PIN N15 [get_ports uart_txd]
# set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]

####################################################################################
## PCIe GTP Transceiver Lanes (Gen1 x4)
## AX7203 lane ordering: Lane0=X0Y5, Lane1=X0Y4, Lane2=X0Y6, Lane3=X0Y7
####################################################################################

## GTP Channel LOC Constraints
set_property LOC GTPE2_CHANNEL_X0Y5 [get_cells -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/*/inst/gt_top_i/pipe_wrapper_i/pipe_lane[0].gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property LOC GTPE2_CHANNEL_X0Y4 [get_cells -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/*/inst/gt_top_i/pipe_wrapper_i/pipe_lane[1].gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property LOC GTPE2_CHANNEL_X0Y6 [get_cells -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/*/inst/gt_top_i/pipe_wrapper_i/pipe_lane[2].gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property LOC GTPE2_CHANNEL_X0Y7 [get_cells -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/*/inst/gt_top_i/pipe_wrapper_i/pipe_lane[3].gt_wrapper_i/gtp_channel.gtpe2_channel_i}]

## GTP Common (QPLL) Placement
set_property LOC GTPE2_COMMON_X0Y1 [get_cells -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/*/inst/gt_top_i/pipe_wrapper_i/pipe_lane[0].pipe_quad.gt_common_enabled.gt_common_int.gt_common_i/qpll_wrapper_i/gtp_common.gtpe2_common_i}]

## PCIe Block Placement
set_property LOC PCIE_X0Y0 [get_cells -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/*/inst/pcie_top_i/pcie_7x_i/pcie_block_i}]

## Suppress DRC for MGT ports (constrained by GTP LOC, not PACKAGE_PIN)
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
create_waiver -quiet -type DRC -id {UCIO-1} -description {PCIe MGT ports constrained by GTPE2_CHANNEL LOC} \
    -objects [get_ports -quiet {pcie_mgt_txp[*] pcie_mgt_txn[*] pcie_mgt_rxp[*] pcie_mgt_rxn[*]}]

####################################################################################
## Clock Domain Definitions
####################################################################################

## RGMII RX clock (buffered)
create_generated_clock -name rgmii_rxc_buf -source [get_ports rgmii1_rxc] -divide_by 1 [get_pins -quiet rgmii_rxc_bufg/O]

## PCIe TXOUTCLK (multiple patterns for different XDMA wrapper naming)
## Pattern 1: Explicit path matching actual design hierarchy (U0/inst format)
create_clock -period 10.000 -name txoutclk_x0y0 [get_pins -quiet {pcie_system_inst/pcie_system_i/xdma_0/inst/pcie_system_xdma_0_0_pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_lane[0].gt_wrapper_i/gtp_channel.gtpe2_channel_i/TXOUTCLK}]
## Pattern 2: Wildcard path with U0/inst
create_clock -period 10.000 -name txoutclk_x0y0 [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_lane[0].gt_wrapper_i/gtp_channel.gtpe2_channel_i/TXOUTCLK}]
## Pattern 3: Wildcard path with inst/inst (older format)
create_clock -period 10.000 -name txoutclk_x0y0 [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_lane[0].gt_wrapper_i/gtp_channel.gtpe2_channel_i/TXOUTCLK}]

## PCIe MMCM generated clocks (multiple patterns)
# U0/inst format
create_generated_clock -quiet -name clk_125mhz_x0y0 [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/mmcm_i/CLKOUT0}]
create_generated_clock -quiet -name clk_250mhz_x0y0 [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/mmcm_i/CLKOUT1}]
# inst/inst format (older)
create_generated_clock -quiet -name clk_125mhz_x0y0 [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/mmcm_i/CLKOUT0}]
create_generated_clock -quiet -name clk_250mhz_x0y0 [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/mmcm_i/CLKOUT1}]

## PCIe clock mux generated clocks (multiple patterns)
# U0/inst format
create_generated_clock -quiet -name clk_125mhz_mux_x0y0 \
    -source [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/I0}] \
    -divide_by 1 \
    [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/O}]

create_generated_clock -quiet -name clk_250mhz_mux_x0y0 \
    -source [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/I1}] \
    -divide_by 1 -add -master_clock clk_250mhz_x0y0 \
    [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/O}]

# inst/inst format (older)
create_generated_clock -quiet -name clk_125mhz_mux_x0y0 \
    -source [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/I0}] \
    -divide_by 1 \
    [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/O}]

create_generated_clock -quiet -name clk_250mhz_mux_x0y0 \
    -source [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/I1}] \
    -divide_by 1 -add -master_clock clk_250mhz_x0y0 \
    [get_pins -quiet {*/xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/O}]

####################################################################################
## Clock Groups (Asynchronous Domains)
####################################################################################

## Main clock groups (Gen2: sys_clk_p removed)
set_clock_groups -asynchronous \
    -group [get_clocks rgmii1_rxc] \
    -group [get_clocks -quiet rgmii_rxc_buf] \
    -group [get_clocks -include_generated_clocks pcie_refclk]

## PCIe Gen1/Gen2 clock mux (physically exclusive)
set_clock_groups -quiet -physically_exclusive \
    -group [get_clocks -quiet clk_125mhz_mux_x0y0] \
    -group [get_clocks -quiet clk_250mhz_mux_x0y0]

set_clock_groups -quiet -physically_exclusive \
    -group [get_clocks -quiet clk_125mhz_x0y0] \
    -group [get_clocks -quiet clk_250mhz_x0y0]

####################################################################################
## PCIe Timing Constraints
####################################################################################

## PCIe PIPE clock mux false paths (multiple patterns for different XDMA wrapper naming)
# U0/inst format
set_false_path -quiet -to [get_pins -quiet {*xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/S0}]
set_false_path -quiet -to [get_pins -quiet {*xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/U0/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/S1}]
# inst/inst format (older)
set_false_path -quiet -to [get_pins -quiet {*xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/S0}]
set_false_path -quiet -to [get_pins -quiet {*xdma_0/inst/*pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/pclk_i1_bufgctrl.pclk_i1/S1}]

## False path from pclk_sel_reg (async clock mux control)
set_false_path -quiet -from [get_cells -quiet -hierarchical -filter {NAME =~ *pipe_clock_i/pclk_sel_reg*}]

####################################################################################
## XDMA Internal Timing Relaxation for Gen2 (250 MHz)
## The XDMA IP has internal timing issues at 250 MHz that cannot be fixed by RTL.
## These constraints help the tools optimize the critical paths.
####################################################################################

## False path on XDMA user reset - it's async and has high fanout
set_false_path -quiet -from [get_cells -quiet -hierarchical -filter {NAME =~ *xdma_0/inst/*user_reset_out_reg*}]
set_false_path -quiet -from [get_cells -quiet -hierarchical -filter {NAME =~ *xdma_0/inst/*user_rst*}]

## Relax timing on XDMA DMA engine internal paths (these are marginal at 250 MHz)
## The actual data path still meets timing - only control logic is affected
set_multicycle_path -quiet 2 -setup -from [get_cells -quiet -hierarchical -filter {NAME =~ *xdma_0/inst/udma_wrapper/dma_top/*}] \
                                    -to   [get_cells -quiet -hierarchical -filter {NAME =~ *xdma_0/inst/udma_wrapper/dma_top/*}]
set_multicycle_path -quiet 1 -hold  -from [get_cells -quiet -hierarchical -filter {NAME =~ *xdma_0/inst/udma_wrapper/dma_top/*}] \
                                    -to   [get_cells -quiet -hierarchical -filter {NAME =~ *xdma_0/inst/udma_wrapper/dma_top/*}]

## PCIe async signals
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~PLPHYLNKUPN} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ *}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~PLRECEIVEDHOTRST} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ *}]]

## GTP transceiver async signals
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~RXELECIDLE} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~TXPHINITDONE} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~TXPHALIGNDONE} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~TXDLYSRESETDONE} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~RXDLYSRESETDONE} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~RXPHALIGNDONE} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~RXCDRLOCK} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~CFGMSGRECEIVEDPMETO} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ *}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~PLL0LOCK} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~RXPMARESETDONE} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~RXSYNCDONE} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]
set_false_path -through [get_pins -quiet -filter {REF_PIN_NAME=~TXSYNCDONE} -of_objects [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ IO.gt.*}]]

####################################################################################
## Trading Logic CDC Constraints (Gen2: Now RGMII 125 MHz <-> PCIe axi_aclk)
## The 200 MHz domain was removed. Trading logic runs on PCIe clock.
####################################################################################

# Gen2: Removed - 200 MHz clock no longer used
# set_max_delay -from [get_clocks -quiet rgmii_rxc_buf] -to [get_clocks sys_clk_p] 10.0
# set_min_delay -from [get_clocks -quiet rgmii_rxc_buf] -to [get_clocks sys_clk_p] 2.0

## ITCH FIFO CDC (gray-coded pointers)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*itch_fifo*/*rd_ptr_gray_reg*"}] \
               -to   [get_cells -hierarchical -filter {NAME =~ "*itch_fifo*/*rd_ptr_gray_wr_sync*"}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*itch_fifo*/*wr_ptr_gray_reg*"}] \
               -to   [get_cells -hierarchical -filter {NAME =~ "*itch_fifo*/*wr_ptr_gray_rd_sync*"}]

## Reset synchronizers
set_property ASYNC_REG TRUE [get_cells -hier -quiet *mdio_rst_rgmii_sync*]
set_property DONT_TOUCH TRUE [get_cells -hier -quiet *mdio_rst_rgmii_sync*]
set_false_path -to [get_cells -hier -quiet *mdio_rst_rgmii_sync1*]

####################################################################################
## BBO CDC Constraints (Gen2: Trading on PCIe axi_aclk - no CDC needed for BBO)
## With 200 MHz removed, trading runs on same clock as PCIe.
## ITCH FIFO still needs CDC (RGMII 125 MHz -> PCIe axi_aclk).
####################################################################################

## BBO FIFO CDC (gray-coded pointers)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*bbo_fifo*/*rd_ptr_gray_reg*"}] \
               -to   [get_cells -hierarchical -filter {NAME =~ "*bbo_fifo*/*rd_ptr_gray_wr_sync*"}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*bbo_fifo*/*wr_ptr_gray_reg*"}] \
               -to   [get_cells -hierarchical -filter {NAME =~ "*bbo_fifo*/*wr_ptr_gray_rd_sync*"}]

## pcie_bbo_top CDC FIFO
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*bbo_cdc_fifo*/*wr_ptr_gray_reg*"}] \
               -to   [get_cells -hierarchical -filter {NAME =~ "*bbo_cdc_fifo*/*wr_ptr_gray_rd*"}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*bbo_cdc_fifo*/*rd_ptr_gray_reg*"}] \
               -to   [get_cells -hierarchical -filter {NAME =~ "*bbo_cdc_fifo*/*rd_ptr_gray_wr*"}]

####################################################################################
## General Synchronizer False Paths
####################################################################################

## Any signal going to 2-FF synchronizers
set_false_path -to [get_cells -hierarchical -filter {NAME =~ "*_sync1_reg*"}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ "*_sync2_reg*"}]

## Reset distribution
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*reset_reg*"}] \
               -to   [get_cells -hierarchical -filter {NAME =~ "*reset_*_sync*"}]

####################################################################################
## Order Book Multicycle Paths (designed for 25 MHz, running at 200 MHz)
####################################################################################

set_multicycle_path -setup 3 -from [get_cells -hier -filter {NAME =~ *multi_symbol_order_book_inst/*}]
set_multicycle_path -hold 2 -from [get_cells -hier -filter {NAME =~ *multi_symbol_order_book_inst/*}]
set_multicycle_path -setup 3 -to [get_cells -hier -filter {NAME =~ *multi_symbol_order_book_inst/*}]
set_multicycle_path -hold 2 -to [get_cells -hier -filter {NAME =~ *multi_symbol_order_book_inst/*}]

set_multicycle_path -setup 3 -from [get_cells -hier -filter {NAME =~ *order_book_manager/*}]
set_multicycle_path -hold 2 -from [get_cells -hier -filter {NAME =~ *order_book_manager/*}]
set_multicycle_path -setup 3 -to [get_cells -hier -filter {NAME =~ *order_book_manager/*}]
set_multicycle_path -hold 2 -to [get_cells -hier -filter {NAME =~ *order_book_manager/*}]

####################################################################################
## High Fanout Constraints
####################################################################################

set_property MAX_FANOUT 32 [get_cells -hierarchical -filter {NAME =~ "*reset_sync2*"}]
set_property MAX_FANOUT 32 [get_cells -hierarchical -filter {NAME =~ "*reset_sync1*"}]
set_property MAX_FANOUT 32 [get_cells -hierarchical -filter {NAME =~ "*reset_reg*"}]
set_property MAX_FANOUT 50 [get_cells -hierarchical -filter {NAME =~ "*wr_ptr_gray_rd_reg*"}]
set_property MAX_FANOUT 50 [get_cells -hierarchical -filter {NAME =~ "*handler_fifo*"}]

####################################################################################
## Ethernet TX Clock (clk_txd_unbuf) CDC Constraints
## This clock is generated inside ethernet_top for RGMII TX at 125 MHz
## It is asynchronous to sys_clk_p (200 MHz trading domain)
####################################################################################

## Gen2: clk_txd is now derived from RGMII RX clock via MMCM (not sys_clk_p)
## The TX clock is already asynchronous to PCIe clocks
# create_generated_clock -quiet -name clk_txd_unbuf \
#     -source [get_ports sys_clk_p] \
#     -divide_by 1 \
#     [get_pins -quiet ethernet_inst/clk_125mhz_oddr/Q]

## Gen2: sys_clk_p no longer used
# set_clock_groups -asynchronous \
#     -group [get_clocks -quiet clk_txd_unbuf] \
#     -group [get_clocks sys_clk_p]

## Alternative: If the generated clock approach doesn't work, use false paths
## for the specific debug formatter sampling paths
set_false_path -from [get_clocks -quiet clk_txd_unbuf] -to [get_cells -quiet debug_formatter_inst/*_sampled_reg*]
set_false_path -from [get_cells -quiet ethernet_inst/rgmii_tx_inst/*] -to [get_cells -quiet debug_formatter_inst/*_sampled_reg*]
set_false_path -from [get_cells -quiet ethernet_inst/udp_tx_inst/*] -to [get_cells -quiet debug_formatter_inst/*_sampled_reg*]

## Gen2: BBO payload source CDC - sys_clk_p no longer used
# set_false_path -from [get_clocks sys_clk_p] -to [get_cells -quiet ethernet_inst/bbo_payload_source_inst/*_latched_reg*]

####################################################################################
## Debug Formatter Multicycle Paths
## Debug output is non-critical - sampled values don't need cycle-accurate timing
####################################################################################

## Allow extra cycles for debug signal sampling
set_multicycle_path -quiet 2 -setup -to [get_cells -quiet debug_formatter_inst/*_sampled_reg*]
set_multicycle_path -quiet 1 -hold -to [get_cells -quiet debug_formatter_inst/*_sampled_reg*]

####################################################################################
## BRAM Placement Hints for Trading/PCIe FIFOs
## Reduces net delay between related BRAMs by suggesting co-location
####################################################################################

## Set BRAM cascading property to allow better placement
set_property RAM_STYLE BLOCK [get_cells -quiet -hier -filter {NAME =~ "*itch_cdc_fifo*fifo_mem*"}]
set_property RAM_STYLE BLOCK [get_cells -quiet -hier -filter {NAME =~ "*pcie_bbo*cdc_fifo*fifo_mem*"}]

####################################################################################
