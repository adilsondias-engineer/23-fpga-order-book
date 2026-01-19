###################################################################################
## Vivado Block Design TCL Script for PCIe Order Book BBO Streaming
## Target: AX7203 (XC7A200T-2FBG484I)
## PCIe: Gen2 x4 with XDMA IP (250 MHz AXI-Stream)
##
## NOTE: Gen2 configured - PCIe link will auto-negotiate to highest common speed.
##       If connected to Gen1 slot, will negotiate down to Gen1 automatically.
##       Gen2 x4 provides 2 GB/s bandwidth (Gen1 x4 = 1 GB/s if negotiated down).
##
## Usage: vivado -mode batch -source scripts/create_block_design.tcl
###################################################################################

# Project settings
set project_name "23-order-book"
set project_dir "./vivado_project"
set part_name "xc7a200tfbg484-2"
set board_part ""
set_param general.maxThreads 4

# Create project
create_project $project_name $project_dir -part $part_name -force

# Set project properties
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

###################################################################################
## Add Custom RTL Source Files
## Integrates Project 20 (Order Book) with Project 22 (PCIe) functionality
###################################################################################
puts "Adding custom RTL source files..."

# Add all source directories recursively
add_files -norecurse {
    src/order_book_top.vhd
}
# PCIe bridge components
add_files -norecurse [glob -nocomplain src/pcie/*.vhd]

# Ethernet components
add_files -norecurse [glob -nocomplain src/ethernet/*.vhd]

# ITCH parser components
add_files -norecurse [glob -nocomplain src/itch/*.vhd]
# Order book components
add_files -norecurse [glob -nocomplain src/order_book/*.vhd]

# FIFO components
add_files -norecurse [glob -nocomplain src/fifo/*.vhd]

# UART components (for debug)
#add_files -norecurse [glob -nocomplain src/uart/*.vhd]

# Set VHDL 2008 for files that use VHDL-2008 constructs (conditional signal assignment)
#set_property file_type {VHDL 2008} [get_files *debug_formatter.vhd]
#set_property file_type {VHDL 2008} [get_files *pcie_debug_formatter.vhd]

# Button debouncer
#add_files -norecurse [glob -nocomplain src/btn/*.vhd]

# Formatter components
#add_files -norecurse [glob -nocomplain src/formatter/*.vhd]

#add_files -norecurse [glob -nocomplain src/i2c_master/*.v]

#add_files -norecurse [glob -nocomplain src/video/*.v]

update_compile_order -fileset sources_1
puts "Custom RTL files added."

###################################################################################
## Create Block Design
###################################################################################
create_bd_design "pcie_system"

# Add XDMA IP (DMA/Bridge Subsystem for PCIe)
create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.2 xdma_0

# Configure XDMA IP for Gen2 x4 with AXI-Stream mode
# Gen2 configured at 250 MHz - PCIe will auto-negotiate to highest common speed
# If connected to Gen1-only slot, link will negotiate down to Gen1 (125 MHz effective)
# Gen2 x4 bandwidth = 2 GB/s, Gen1 x4 = 1 GB/s (both sufficient for BBO streaming)
#
# Finds configuring XDMA on UI:
#  If Speed=2.5GT/s axi data width must be 64_bit and AXI Clock Frequency can be either 125Mhz or 250Mhz  
#        Tested: 125Mhz and 64_bit -->  no PC freeze
#        Tested: 250Mhz and 64_bit --> No device on device manager -> rescan doesn't detect the board. LED0 off, LED1 ON, LED2 OFF, LED3 flashing
#  If speed=5GT/s and axi data width 128_bit, AXI Clock Frequency must be 125Mhz - didn't compile with port mismatch
#  If speed=5GT/s and axi data width 64_bit,  AXI Clock Frequency must be 250Mhz - Doesn't work, PC crashed, after PC reboot, reprogramed and XDMA doesn't detect the board despite it shows up on device manager, gets the "unknown Module". However, as this speed works on project 22, the other modules seems to be interfering with PCIe speed.

# CRITICAL: select_quad must be GTH_Quad_128 for AX7203 board
# Lane locations from vendor demo:
#   Lane 0 -> GTPE2_CHANNEL_X0Y5
#   Lane 1 -> GTPE2_CHANNEL_X0Y4
#   Lane 2 -> GTPE2_CHANNEL_X0Y6
#   Lane 3 -> GTPE2_CHANNEL_X0Y7
#   Common -> GTPE2_COMMON_X0Y1
set_property -dict [list \
    CONFIG.pcie_blk_locn {X0Y0} \
    CONFIG.select_quad {GTH_Quad_128} \
    CONFIG.pl_link_cap_max_link_width {X4} \
    CONFIG.pl_link_cap_max_link_speed {5.0_GT/s} \
    CONFIG.axi_data_width {64_bit} \
    CONFIG.axisten_freq {250} \
    CONFIG.pf0_device_id {7024} \
    CONFIG.pf0_subsystem_id {0007} \
    CONFIG.pf0_subsystem_vendor_id {10EE} \
    CONFIG.pf0_class_code_base {05} \
    CONFIG.pf0_class_code_sub {80} \
    CONFIG.pf0_class_code_interface {00} \
    CONFIG.xdma_num_usr_irq {4} \
    CONFIG.pf0_msi_enabled {true} \
    CONFIG.pf0_msix_enabled {false} \
    CONFIG.cfg_mgmt_if {false} \
    CONFIG.plltype {QPLL1} \
    CONFIG.dma_reset_source_sel {User_Reset} \
    CONFIG.en_gt_selection {true} \
    CONFIG.mode_selection {Advanced} \
    CONFIG.pcie_extended_tag {true} \
    CONFIG.c_s_axi_supports_narrow_burst {false} \
    CONFIG.xdma_axi_intf_mm {AXI_Stream} \
    CONFIG.xdma_rnum_chnl {1} \
    CONFIG.xdma_wnum_chnl {1} \
    CONFIG.axilite_master_en {false} \
    CONFIG.axisten_if_enable_client_tag {false} \
    CONFIG.xdma_sts_ports {false} \
] [get_bd_cells xdma_0]

# Configure BAR0 for XDMA control registers (128 KB minimum for XDMA IP)
set_property -dict [list \
    CONFIG.pf0_bar0_enabled {true} \
    CONFIG.pf0_bar0_type {Memory} \
    CONFIG.pf0_bar0_64bit {false} \
    CONFIG.pf0_bar0_prefetchable {false} \
    CONFIG.pf0_bar0_scale {Kilobytes} \
    CONFIG.pf0_bar0_size {128} \
] [get_bd_cells xdma_0]

# Enable AXI-Lite Master for user control registers (BAR1 -> /dev/xdma0_user)
# This creates a memory-mapped interface for software-triggered reset
set_property -dict [list \
    CONFIG.axilite_master_en {true} \
    CONFIG.axilite_master_size {4} \
    CONFIG.axilite_master_scale {Kilobytes} \
] [get_bd_cells xdma_0]

# Configure BAR1 for user control space (accessed via /dev/xdma0_user)
# Size: 4KB (sufficient for reset register and future expansion)
set_property -dict [list \
    CONFIG.pf0_bar1_enabled {true} \
    CONFIG.pf0_bar1_type {Memory} \
    CONFIG.pf0_bar1_64bit {false} \
    CONFIG.pf0_bar1_prefetchable {false} \
    CONFIG.pf0_bar1_scale {Kilobytes} \
    CONFIG.pf0_bar1_size {4} \
] [get_bd_cells xdma_0]

###################################################################################
## Create External Ports
###################################################################################

# PCIe interface
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_mgt
connect_bd_intf_net [get_bd_intf_pins xdma_0/pcie_mgt] [get_bd_intf_ports pcie_mgt]

# Manual PCIe clock infrastructure (instead of automation)
# Create external ports first
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 pcie_refclk
create_bd_port -dir I -type rst reset_rtl_0
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports reset_rtl_0]

# Create utility differential buffer for PCIe reference clock (100 MHz)
# Using IBUFDS_GTE2 primitive for GTP reference clock
create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_0
set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} [get_bd_cells util_ds_buf_0]

# Connect differential clock to buffer
connect_bd_intf_net [get_bd_intf_ports pcie_refclk] [get_bd_intf_pins util_ds_buf_0/CLK_IN_D]

# Connect single-ended output to XDMA
connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_OUT] [get_bd_pins xdma_0/sys_clk]

# Connect reset
connect_bd_net [get_bd_ports reset_rtl_0] [get_bd_pins xdma_0/sys_rst_n]

# Print XDMA interface information for debugging
puts ""
puts "=== XDMA Interface Debug ==="
puts "M_AXI interface pins:"
foreach pin [get_bd_intf_pins -quiet -of_objects [get_bd_cells xdma_0] -filter {VLNV =~ "*axi*"}] {
    puts "  $pin"
}
puts ""
puts "XDMA configuration:"
foreach prop {axi_data_width xdma_axi_intf_mm} {
    puts "  $prop = [get_property CONFIG.$prop [get_bd_cells xdma_0]]"
}
puts "============================="
puts ""

# Rename the auto-created differential clock port for clarity
# The automation creates: diff_clock_rtl_0 -> util_ds_buf -> xdma_0/sys_clk
# Also creates: pcie_perstn port -> xdma_0/sys_rst_n

# Get reference to auto-created ports for documentation
# diff_clock_rtl_0: PCIe reference clock (100 MHz differential)
# pcie_perstn: PCIe reset (directly connected by automation)

###################################################################################
## Tie Off Unused AXI Stream Interfaces
## For initial testing, S_AXIS_C2H is tied off to prevent hanging
###################################################################################

# List available interfaces for debugging
puts "Available XDMA interfaces (AXI Stream mode):"
foreach intf [get_bd_intf_pins -of_objects [get_bd_cells xdma_0]] {
    puts "  $intf"
}
puts ""

###################################################################################
## Expose S_AXIS_C2H as External Ports (Phase 2)
## Custom RTL wrapper (order_book_pcie_top) will connect pcie_bbo_top to these
###################################################################################

puts "Exposing S_AXIS_C2H_0 as external ports for custom RTL integration..."

# Create external ports for S_AXIS_C2H (Card-to-Host input from custom logic)
create_bd_port -dir I -from 63 -to 0 s_axis_c2h_tdata
create_bd_port -dir I -from 7 -to 0 s_axis_c2h_tkeep
create_bd_port -dir I s_axis_c2h_tvalid
create_bd_port -dir O s_axis_c2h_tready
create_bd_port -dir I s_axis_c2h_tlast

# Connect external ports to XDMA S_AXIS_C2H_0
connect_bd_net [get_bd_ports s_axis_c2h_tdata] [get_bd_pins xdma_0/s_axis_c2h_tdata_0]
connect_bd_net [get_bd_ports s_axis_c2h_tkeep] [get_bd_pins xdma_0/s_axis_c2h_tkeep_0]
connect_bd_net [get_bd_ports s_axis_c2h_tvalid] [get_bd_pins xdma_0/s_axis_c2h_tvalid_0]
connect_bd_net [get_bd_pins xdma_0/s_axis_c2h_tready_0] [get_bd_ports s_axis_c2h_tready]
connect_bd_net [get_bd_ports s_axis_c2h_tlast] [get_bd_pins xdma_0/s_axis_c2h_tlast_0]

# Expose XDMA clock and reset for custom logic
create_bd_port -dir O axi_aclk
create_bd_port -dir O axi_aresetn
connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_ports axi_aclk]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_ports axi_aresetn]

puts "S_AXIS_C2H_0 exposed as external ports:"
puts "  s_axis_c2h_tdata[63:0]  - Input from custom logic"
puts "  s_axis_c2h_tkeep[7:0]   - Input"
puts "  s_axis_c2h_tvalid       - Input"
puts "  s_axis_c2h_tready       - Output to custom logic"
puts "  s_axis_c2h_tlast        - Input"
puts "  axi_aclk                - Clock output"
puts "  axi_aresetn             - Reset output"

###################################################################################
## AXI-Lite Control Registers for Software Reset
## Creates /dev/xdma0_user device for host software to trigger FPGA reset
###################################################################################

puts "Creating AXI-Lite GPIO for software reset..."

# Create AXI GPIO IP for control registers
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_ctrl

# Configure GPIO:
# - Channel 1: 32-bit output (control register)
#   - Bit 0: soft_reset (write 1 to reset, auto-clears)
#   - Bits 1-31: Reserved for future use
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {32} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {0} \
] [get_bd_cells axi_gpio_ctrl]

# Connect AXI GPIO to XDMA M_AXI_LITE interface
connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI_LITE] [get_bd_intf_pins axi_gpio_ctrl/S_AXI]

# Connect clocks
connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins axi_gpio_ctrl/s_axi_aclk]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins axi_gpio_ctrl/s_axi_aresetn]

# Expose GPIO output as external port for custom logic
create_bd_port -dir O -from 31 -to 0 soft_reset_reg
connect_bd_net [get_bd_pins axi_gpio_ctrl/gpio_io_o] [get_bd_ports soft_reset_reg]

puts "AXI-Lite GPIO configured:"
puts "  Address: 0x0000 (BAR1 offset 0)"
puts "  soft_reset_reg[31:0] - Output to custom logic"
puts "  soft_reset_reg[0]    - Software reset bit"

###################################################################################
## Tie Off M_AXIS_H2C (Host-to-Card) Interface
## CRITICAL: Without this, H2C transfers hang and cause PC stuttering!
## The design accepts and discards any data sent from host to card
###################################################################################

# Create constant 1 for TREADY (always ready to accept H2C data)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_h2c_tready
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells const_h2c_tready]

# Connect TREADY high - accept and discard all H2C data
connect_bd_net [get_bd_pins const_h2c_tready/dout] [get_bd_pins xdma_0/m_axis_h2c_tready_0]

puts "M_AXIS_H2C_0 tied off (TREADY=1, data discarded)"

###################################################################################
## Clock and Reset Infrastructure
###################################################################################

# Processor System Reset for XDMA clock domain
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_xdma
connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins rst_xdma/slowest_sync_clk]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins rst_xdma/ext_reset_in]

# Tie dcm_locked high - no external PLL to monitor
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_one
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells const_one]
connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins rst_xdma/dcm_locked]

# No BRAM in AXI Stream mode - all clocks managed by XDMA IP

###################################################################################
## External Ports for User Logic
###################################################################################

# Tie off user interrupts (not used in basic design)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero_4
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] [get_bd_cells const_zero_4]
connect_bd_net [get_bd_pins const_zero_4/dout] [get_bd_pins xdma_0/usr_irq_req]

# LED output for link status (directly from XDMA, active high)
create_bd_port -dir O user_lnk_up
connect_bd_net [get_bd_pins xdma_0/user_lnk_up] [get_bd_ports user_lnk_up]

# Note: Additional LEDs (led_streaming, led_overflow) will be added in Phase 2
# when pcie_bbo_top is integrated

###################################################################################
## Address Map Configuration
###################################################################################
# AXI Stream mode has no memory-mapped address space (no M_AXI interface)
# Streaming data flows through S_AXIS_C2H_0 and M_AXIS_H2C_0
assign_bd_address

puts ""
puts "=== AXI Stream Configuration ==="
puts "XDMA configured for pure streaming mode (no M_AXI)"
puts "Available AXI-Stream interfaces:"
foreach intf [get_bd_intf_pins -quiet -of_objects [get_bd_cells xdma_0] -filter {MODE == Slave && VLNV =~ "*axis*"}] {
    puts "  Input: $intf"
}
foreach intf [get_bd_intf_pins -quiet -of_objects [get_bd_cells xdma_0] -filter {MODE == Master && VLNV =~ "*axis*"}] {
    puts "  Output: $intf"
}
puts "================================"
puts ""

###################################################################################
## Validate and Save Block Design
###################################################################################

# Regenerate layout
regenerate_bd_layout

# Validate design
validate_bd_design

# Save block design
save_bd_design

# Migrate utility IPs to inline HDL for improved performance and reduced disk space
# See UG994 for more information
puts "Migrating utility IPs to inline HDL..."
upgrade_project -migrate_to_inline_hdl

# Generate HDL wrapper for block design (not set as top - order_book_top is top)
make_wrapper -files [get_files $project_dir/$project_name.srcs/sources_1/bd/pcie_system/pcie_system.bd] -top
add_files -norecurse $project_dir/$project_name.gen/sources_1/bd/pcie_system/hdl/pcie_system_wrapper.vhd

# Set order_book_top as the top module (integrated Ethernet + Order Book + PCIe)
set_property top order_book_top [current_fileset]
puts "Set order_book_top as top module"

###################################################################################
## Add Constraints
###################################################################################

# Add constraints file (merged Ethernet + PCIe constraints)
add_files -fileset constrs_1 -norecurse constraints/ax7203_order_book.xdc

###################################################################################
## Generate Output Products
###################################################################################

# Generate block design output products
generate_target all [get_files $project_dir/$project_name.srcs/sources_1/bd/pcie_system/pcie_system.bd]

###################################################################################
## Disable Auto-Generated GTP Constraints (CRITICAL for AX7203)
###################################################################################
# The XDMA IP auto-generates a constraint file with WRONG GTP lane order:
#   Auto-generated: Lane0=X0Y7, Lane1=X0Y6, Lane2=X0Y5, Lane3=X0Y4
#   AX7203 correct: Lane0=X0Y5, Lane1=X0Y4, Lane2=X0Y6, Lane3=X0Y7
#
# The auto-generated file must be disabled; ax7203_order_book.xdc is used instead.

# Find and disable the auto-generated PCIE_X0Y0.xdc constraint file
set auto_gen_xdc [get_files -quiet *pcie2_ip-PCIE_X0Y0.xdc]
if {[llength $auto_gen_xdc] > 0} {
    puts "Disabling auto-generated GTP constraint file: $auto_gen_xdc"
    set_property IS_ENABLED false [get_files $auto_gen_xdc]
    # Also set USED_IN to none to prevent it from being processed
    set_property USED_IN {} [get_files $auto_gen_xdc]
} else {
    puts "WARNING: Auto-generated PCIE_X0Y0.xdc not found - may need manual disable"
}

# Disable any xdma IP-level constraint files that have wrong LOC constraints
set xdma_xdc_files [get_files -quiet -of_objects [get_ips -quiet *xdma*] *.xdc]
foreach xdc_file $xdma_xdc_files {
    # Get the file name/path - the object itself can be used as a string
    set file_name [get_property NAME $xdc_file]
    if {[string match "*PCIE_X0Y0*" $file_name] || [string match "*pcie2_ip*" $file_name]} {
        puts "Disabling XDMA IP constraint file: $xdc_file"
        set_property IS_ENABLED false $xdc_file
        set_property USED_IN {} $xdc_file
    }
}

# Also check for any other auto-generated transceiver constraints
set auto_gen_gt_xdc [get_files -quiet *_gt.xdc]
if {[llength $auto_gen_gt_xdc] > 0} {
    foreach xdc_file $auto_gen_gt_xdc {
        puts "Found auto-generated GT constraint file: $xdc_file"
        # Only disable if it conflicts with the project constraints
        # set_property IS_ENABLED false [get_files $xdc_file]
    }
}

# Ensure custom constraints have higher priority
set_property PROCESSING_ORDER LATE [get_files constraints/ax7203_order_book.xdc]

###################################################################################
## ILA Debug Core for Spread Timing Analysis
## Captures: bbo_tracker FSM state, internal spread register, arbiter state,
##           and output spread. Triggered on bbo_update rising edge.
###################################################################################

# Create ILA IP core
#create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_spread_debug

# Configure ILA:
# - 8192 sample depth (good balance of memory vs capture time)
# - Trigger position at 1024 (captures ~1000 samples before trigger)
# - 8 probes covering all debug signals
# set_property -dict [list \
#     CONFIG.C_DATA_DEPTH {8192} \
#     CONFIG.C_TRIGIN_EN {false} \
#     CONFIG.C_TRIGOUT_EN {false} \
#     CONFIG.C_ADV_TRIGGER {true} \
#     CONFIG.C_INPUT_PIPE_STAGES {1} \
#     CONFIG.C_NUM_OF_PROBES {8} \
#     CONFIG.C_PROBE0_WIDTH {5} \
#     CONFIG.C_PROBE1_WIDTH {32} \
#     CONFIG.C_PROBE2_WIDTH {3} \
#     CONFIG.C_PROBE3_WIDTH {10} \
#     CONFIG.C_PROBE4_WIDTH {1} \
#     CONFIG.C_PROBE5_WIDTH {1} \
#     CONFIG.C_PROBE6_WIDTH {1} \
#     CONFIG.C_PROBE7_WIDTH {32} \
# ] [get_ips ila_spread_debug]

# Probe assignments (matching order_book_top.vhd signals):
# probe0[4:0]  = dbg_bbo_state (bbo_tracker FSM state)
# probe1[31:0] = dbg_bbo_spread_reg (internal spread before output)
# probe2[2:0]  = dbg_arbiter_symbol (current symbol being checked)
# probe3[9:0]  = dbg_arbiter_counter (arbiter cycle counter)
# probe4[0]    = dbg_ready_vec_0 (ready signal from symbol 0)
# probe5[0]    = dbg_bbo_update_vec_0 (update pulse from symbol 0)
# probe6[0]    = bbo_update (output update pulse)
# probe7[31:0] = bbo_spread (output spread value)

#generate_target all [get_ips ila_spread_debug]

# puts "ILA debug core 'ila_spread_debug' created and configured"
# puts "Probes:"
# puts "  probe0[4:0]  - bbo_tracker FSM state"
# puts "  probe1[31:0] - internal spread register"
# puts "  probe2[2:0]  - arbiter symbol index"
# puts "  probe3[9:0]  - arbiter counter"
# puts "  probe4       - ready_vec[0]"
# puts "  probe5       - bbo_update_vec[0]"
# puts "  probe6       - bbo_update output"
# puts "  probe7[31:0] - spread output"

###################################################################################
## Configure Implementation Strategy for Timing Closure
###################################################################################

# Set aggressive implementation directives for timing closure
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
# Aggressive timing optimization settings to fix timing violations
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
#set_property STEPS.OPT_DESIGN.ARGS.RETIMING true [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]


# Run synthesis
# puts "Starting synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1

# Check synthesis status
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    return
}
puts "Synthesis completed successfully."

# Run implementation through bitstream
puts "Starting implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1

# Check implementation status
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    return
}
puts "Implementation completed successfully."

# Generate bitstream
puts "Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1


set bit_files [glob -nocomplain ${project_dir}/*.runs/impl_1/*.bit]
if { [llength $bit_files] == 0 } {
    puts "ERROR: No bitstream (.bit) file found in: ${project_dir}/*.runs/impl_1/"
    puts "Has the build script been run first?"
    exit 1
}

set bitstream [lindex $bit_files 0]

puts "=========================================="
puts "Programming FPGA"
puts "Project: $project_dir"
puts "Bitstream: $bitstream"
puts "=========================================="

# Open hardware manager
open_hw_manager

# Connect to hardware server
connect_hw_server -allow_non_jtag

# Get the first available hardware target
set hw_target [lindex [get_hw_targets] 0]
if {$hw_target == ""} {
    puts "ERROR: No hardware targets found!"
    puts "Is the FPGA board connected and powered on?"
    disconnect_hw_server
    close_hw_manager
    exit 1
}

puts "\n>>> Found hardware target: $hw_target"
current_hw_target $hw_target
open_hw_target

# Get the first device
set hw_device [lindex [get_hw_devices] 0]
if {$hw_device == ""} {
    puts "ERROR: No hardware devices found!"
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    exit 1
}

puts ">>> Found hardware device: $hw_device"
current_hw_device $hw_device

# Program the device with the bitstream
puts ">>> Programming device with: $bitstream"
set_property PROGRAM.FILE $bitstream $hw_device
program_hw_devices $hw_device

puts "\n=========================================="
puts "FPGA programmed successfully!"
puts "=========================================="

# Close connections
close_hw_target
disconnect_hw_server
close_hw_manager

puts ""
puts "=============================================="
puts "Build completed successfully!"
puts "=============================================="
puts ""
puts "Bitstream location:"
puts "  vivado_project/23-order-book.runs/impl_1/order_book_pcie_top.bit"
puts ""
puts "To program FPGA:"
puts "  open_hw_manager"
puts "  connect_hw_server"
puts "  open_hw_target"
puts "  set_property PROGRAM.FILE {vivado_project/23-order-book.runs/impl_1/order_book_pcie_top.bit} [current_hw_device]"
puts "  program_hw_devices"
puts ""
puts "Phase 2 - BBO Streaming Test:"
puts "  Top module: order_book_pcie_top"
puts "  Symbol: TESTAAPL (8 bytes)"
puts "  BBO updates: ~250 per second"
puts "  44-byte packets with TLAST marking boundaries"
puts "  Format: Symbol[8] | BidPrice[4] | BidSize[4] | AskPrice[4] | AskSize[4] | Spread[4] | T1-T4[16]"
puts ""
