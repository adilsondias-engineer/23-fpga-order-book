###################################################################################
## Incremental Build Script for Project 23
## Opens existing project and re-runs synthesis/implementation
##
## Usage: vivado -mode batch -source scripts/incremental_build.tcl
###################################################################################

set project_dir "./vivado_project"
set project_name "23-order-book"
set_param general.maxThreads 4
puts "=============================================="
puts "Incremental Build - Opening existing project"
puts "=============================================="

# Open existing project
open_project $project_dir/$project_name.xpr

# Update source files (in case any were modified)
puts "Updating source files..."
update_compile_order -fileset sources_1

# Set VHDL 2008 for files that use VHDL-2008 constructs
#set_property file_type {VHDL 2008} [get_files *debug_formatter.vhd]

# Reset synthesis run (to pick up changes)
puts "Resetting synthesis run..."
reset_run synth_1

# Run synthesis
puts "Starting synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1

# Check synthesis status
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    close_project
    exit 1
}
puts "Synthesis completed successfully."

# Reset and run implementation
puts "Resetting implementation run..."
reset_run impl_1

puts "Starting implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1

# Check implementation status
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    close_project
    exit 1
}
puts "Implementation completed successfully."

# Generate bitstream
puts "Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# Find and program bitstream
set bit_files [glob -nocomplain ${project_dir}/*.runs/impl_1/*.bit]
if { [llength $bit_files] == 0 } {
    puts "ERROR: No bitstream (.bit) file found!"
    close_project
    exit 1
}

set bitstream [lindex $bit_files 0]

puts "=========================================="
puts "Programming FPGA"
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
    disconnect_hw_server
    close_hw_manager
    close_project
    exit 1
}

puts ">>> Found hardware target: $hw_target"
current_hw_target $hw_target
open_hw_target

# Get the first device
set hw_device [lindex [get_hw_devices] 0]
if {$hw_device == ""} {
    puts "ERROR: No hardware devices found!"
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    close_project
    exit 1
}

puts ">>> Found hardware device: $hw_device"
current_hw_device $hw_device

# Program the device
puts ">>> Programming device with: $bitstream"
set_property PROGRAM.FILE $bitstream $hw_device
program_hw_devices $hw_device

puts ""
puts "=========================================="
puts "FPGA programmed successfully!"
puts "=========================================="

# Close connections
close_hw_target
disconnect_hw_server
close_hw_manager
close_project

puts ""
puts "Incremental build completed successfully!"
