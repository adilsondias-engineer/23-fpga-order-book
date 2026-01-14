#!/bin/bash
# Rebuild Project 23: Integrated Order Book with PCIe Output
# Full integration of ITCH Parser + Order Book + PCIe BBO Streaming
#
# Usage: ./rebuild_project.sh [incremental]
#   No args     - Full rebuild (deletes vivado_project and rebuilds from scratch)
#   incremental - Incremental build (keeps existing project, just re-runs synthesis)

set -e  # Exit on error

echo "============================================"
echo "Project 23: Order Book with PCIe Output"
echo "============================================"
echo ""
echo "This project integrates:"
echo "  - Ethernet RGMII (1 Gbps ITCH feed input)"
echo "  - ITCH Parser and Order Book"
echo "  - PCIe Gen1 x4 BBO streaming output"
echo ""
echo "Data flow: Ethernet -> ITCH -> Order Book -> BBO -> PCIe -> Host"
echo ""

# Check for Vivado
if ! command -v vivado &> /dev/null; then
    # Try common Vivado installation paths
    if [ -f "/tools/Xilinx/Vivado/2025.1/settings64.sh" ]; then
        source /tools/Xilinx/Vivado/2025.1/settings64.sh
    elif [ -f "/opt/Xilinx/Vivado/2025.1/settings64.sh" ]; then
        source /opt/Xilinx/Vivado/2025.1/settings64.sh
    elif [ -f "$HOME/Xilinx/Vivado/2025.1/settings64.sh" ]; then
        source "$HOME/Xilinx/Vivado/2025.1/settings64.sh"
    else
        echo "ERROR: Vivado not found in PATH."
        echo "Please source Vivado settings64.sh or add Vivado to PATH."
        echo "  Example: source /tools/Xilinx/Vivado/2025.1/settings64.sh"
        exit 1
    fi
fi

# Get script directory and change to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check for incremental build argument
if [ "$1" = "incremental" ]; then
    # === INCREMENTAL BUILD ===
    echo "INCREMENTAL BUILD - keeping existing project"
    echo ""

    if [ ! -d "vivado_project" ]; then
        echo "ERROR: No existing project found. Run full build first."
        exit 1
    fi

    echo "Running Vivado incremental build..."
    echo "This will re-run synthesis and implementation on existing project."
    echo ""

    vivado -mode batch -source scripts/incremental_build.tcl -log rebuild_incr.log -journal rebuild_incr.jou
else
    # === FULL BUILD ===
    echo "FULL REBUILD - removing old project directory..."
    if [ -d "vivado_project" ]; then
        rm -rf vivado_project
    fi

    echo ""
    echo "Running Vivado to create new project..."
    echo "This will take 15-20 minutes for full synthesis and implementation."
    echo ""

    vivado -mode batch -source scripts/build.tcl -log rebuild.log -journal rebuild.jou
fi

echo ""
echo "============================================"
echo "Build Complete!"
echo "============================================"
echo ""
echo "Check timing summary in:"
echo "  vivado_project/23-order-book.runs/impl_1/order_book_top_timing_summary_routed.rpt"
echo ""
echo "Bitstream location:"
echo "  vivado_project/23-order-book.runs/impl_1/order_book_top.bit"
echo ""
