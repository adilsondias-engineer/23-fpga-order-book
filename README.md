# Project 23: Order Book with PCIe Gen2 Output

## Part of FPGA Trading Systems Portfolio

This project is part of a complete end-to-end trading system:
- **Main Repository:** [fpga-trading-systems](https://github.com/adilsondias-engineer/fpga-trading-systems)
- **Project Number:** 23 of 30
- **Category:** FPGA Core
- **Dependencies:** Project 20 (Gigabit Ethernet Order Book), Project 21 (PCIe infrastructure)

---

## Overview

Complete FPGA trading system integrating Ethernet ITCH feed reception, order book management, and PCIe Gen2 BBO streaming. This project combines the Ethernet/ITCH/Order Book pipeline from Project 20 with PCIe output for low-latency host communication.

Key features:
- RGMII Gigabit Ethernet reception (125 MHz)
- ITCH 5.0 protocol parsing with Add/Execute/Delete/Replace message handling
- Hardware order book with BRAM-based price level storage
- BBO (Best Bid/Offer) extraction with spread calculation
- PCIe Gen2 x1 streaming output (5.0 GT/s, 250 MHz AXI clock)
- 4-point latency timestamps (T1-T4) for end-to-end measurement

## Architecture

```
Ethernet PHY (RGMII 125 MHz)
    |
    v
+-------------------+     +-------------------+     +-------------------+
|   ITCH Parser     | --> |   Order Book      | --> |   BBO Tracker     |
|   (125 MHz)       |     |   (250 MHz)       |     |   (250 MHz)       |
+-------------------+     +-------------------+     +-------------------+
    |                                                       |
    | CDC FIFO (125 -> 250 MHz)                            |
    v                                                       v
+-------------------+     +-------------------+     +-------------------+
|   Trading Logic   | --> | bbo_axi_stream    | --> |   XDMA C2H        |
|   (250 MHz)       |     |   (6-beat FSM)    |     |   (Gen2 x1)       |
+-------------------+     +-------------------+     +-------------------+
                                                            |
                                                            v
                                                    Host Application
                                                    (/dev/xdma0_c2h_0)
```

## Clock Domains

| Domain | Frequency | Components |
|--------|-----------|------------|
| RGMII RX | 125 MHz | Ethernet PHY, ITCH parser, CDC FIFO write |
| AXI/PCIe | 250 MHz | Order book, BBO tracker, AXI-Stream, XDMA |

## BBO Packet Format (48 bytes)

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0-7 | 8 | Symbol | Stock ticker (ASCII, space-padded) |
| 8-11 | 4 | Bid Price | Fixed-point (4 decimal places) |
| 12-15 | 4 | Bid Size | Number of shares |
| 16-19 | 4 | Ask Price | Fixed-point (4 decimal places) |
| 20-23 | 4 | Ask Size | Number of shares |
| 24-27 | 4 | Spread | Ask - Bid (4 decimal places) |
| 28-31 | 4 | T1 | ITCH parse timestamp (125 MHz cycles) |
| 32-35 | 4 | T2 | CDC FIFO write timestamp (125 MHz cycles) |
| 36-39 | 4 | T3 | BBO ready for PCIe (250 MHz cycles) |
| 40-43 | 4 | T4 | AXI-Stream TX start (250 MHz cycles) |
| 44-47 | 4 | Reserved | Padding |

## XDMA Configuration

```
PCIe Link:
  - Max Link Speed: 5.0 GT/s (Gen2)
  - Negotiated Width: x1 (via TB4 dock)
  - Device ID: 0x7024
  - Vendor ID: 0x10EE (Xilinx)

AXI Interface:
  - Data Width: 64-bit
  - Clock Frequency: 250 MHz
  - Mode: AXI-Stream (C2H streaming)
```

## Building

```bash
cd 23-order-book

# Build bitstream
vivado -mode batch -source scripts/build.tcl

# Program FPGA
vivado -mode batch -source scripts/program.tcl

# Build host tools
cd host
make
```

## Testing

```bash
# Verify PCIe link
lspci -d 10ee: -vvv | grep -E "LnkSta|Speed"

# Run BBO packet verification
cd host
./bbo_verify 10

# Expected output:
# BBO Packet Verification (Project 23 - 48-byte format)
# ====================================================
# Device: /dev/xdma0_c2h_0
# PCIe mode: Gen2 250MHz (4 ns/cycle)
#
# BBO #1:
#   Symbol:    'AAPL    '
#   Bid:       $321.0100 x 30 shares
#   Ask:       $321.7900 x 30 shares
#   Spread:    $0.7800
```

## Key Files

```
23-order-book/
+-- src/
|   +-- order_book_top.vhd           # Top-level integration
|   +-- ethernet/
|   |   +-- ethernet_top.vhd         # RGMII receiver
|   |   +-- rgmii_rx.vhd             # RGMII to parallel conversion
|   +-- itch/
|   |   +-- itch_parser.vhd          # ITCH 5.0 message parser
|   +-- order_book/
|   |   +-- order_book_manager.vhd   # Order book with BRAM storage
|   |   +-- bbo_tracker.vhd          # BBO extraction and spread calculation
|   +-- pcie/
|   |   +-- bbo_axi_stream.vhd       # 6-beat AXI-Stream FSM with T3/T4 capture
|   +-- fifo/
|       +-- async_fifo.vhd           # Gray-code CDC FIFO
+-- constraints/
|   +-- ax7203_order_book.xdc        # Pin assignments and timing constraints
+-- scripts/
|   +-- build.tcl                    # Vivado build script
+-- host/
|   +-- bbo_verify.c                 # BBO packet verification tool
+-- docs/
    +-- PCIE_DEBUG_CONTEXT.md        # Detailed PCIe debugging notes
```

## Bug Fixes Applied

### Spread Calculation Always Zero

**Symptom:** Spread field showed 0x00000000 in all BBO packets.

**Root Cause:** The COMPUTE_SPREAD state in bbo_tracker.vhd used `best_bid_found` and `best_ask_found` flags which reset each scan cycle.

**Fix:** Changed to use persistent register values:
```vhdl
-- Before (broken)
if best_bid_found = '1' and best_ask_found = '1' then

-- After (fixed)
if (best_bid_price_reg /= x"00000000") and (best_ask_price_reg /= x"FFFFFFFF") then
```

### Gen2 Clock Constraint Path Mismatch

**Symptom:** 26,418 unconstrained registers at Gen2 (250 MHz), causing data corruption.

**Root Cause:** XDC constraints used path pattern `pcie2_ip_i/*/inst/` but actual hierarchy was `pcie2_ip_i/U0/inst/`.

**Fix:** Added explicit path patterns matching actual design hierarchy in ax7203_order_book.xdc.

### T3/T4 Timestamps Not Captured

**Symptom:** T3 and T4 fields always showed 0x00000000.

**Root Cause:** bbo_axi_stream.vhd passed through upstream zeros instead of capturing local timestamps.

**Fix:** Added local cycle counter and timestamp capture in bbo_axi_stream.vhd:
- T3: Captured when bbo_valid pulse received
- T4: Captured when BEAT1 AXI-Stream handshake completes

## Hardware Requirements

- FPGA Board: AX7203 (Kintex-7 XC7K325T)
- External 12V power (required for GTP transceivers)
- PCIe slot or Thunderbolt 4 dock
- Gigabit Ethernet connection for ITCH feed

## Dependencies

- Vivado 2019.1+
- Xilinx dma_ip_drivers (XDMA Linux driver)
- GCC for host tools

---

**Status:** Completed and tested on hardware

**Created:** December 2025

**Last Updated:** December 2025

**Author:** Adilson Dias

**Project:** https://github.com/adilsondias-engineer/fpga-trading-systems
