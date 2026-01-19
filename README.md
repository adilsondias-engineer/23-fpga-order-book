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
- **Magic header packet framing (0xBB0BB048) for reliable packet synchronization**

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
|   (250 MHz)       |     |   (7-beat FSM)    |     |   (Gen2 x1)       |
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

## BBO Packet Format (56 bytes with Magic Header)

The packet format was updated from 48 bytes to 56 bytes in January 2026 to include a magic header for reliable packet synchronization over PCIe DMA.

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0-3 | 4 | Magic Header | 0xBB0BB048 (packet sync marker) |
| 4-7 | 4 | Packet Length | 0x00000038 (56 bytes) |
| 8-15 | 8 | Symbol | Stock ticker (ASCII, space-padded) |
| 16-19 | 4 | Bid Price | Fixed-point (4 decimal places) |
| 20-23 | 4 | Bid Size | Number of shares |
| 24-27 | 4 | Ask Price | Fixed-point (4 decimal places) |
| 28-31 | 4 | Ask Size | Number of shares |
| 32-35 | 4 | Spread | Ask - Bid (4 decimal places) |
| 36-39 | 4 | T1 | ITCH parse timestamp (cycles) |
| 40-43 | 4 | T2 | CDC FIFO write timestamp (cycles) |
| 44-47 | 4 | T3 | BBO ready for PCIe (250 MHz cycles) |
| 48-51 | 4 | T4 | AXI-Stream TX start (250 MHz cycles) |
| 52-55 | 4 | Reserved | Padding (0x00000000) |

### Magic Header Details

- **Value:** 0xBB0BB048 (mnemonic: "BBO" + "48" for original 48-byte payload)
- **Purpose:** Enables reliable packet boundary detection in streaming DMA
- **Byte order in memory:** `BB 0B B0 48` (FPGA uses byte_swap_64 for little-endian AXI)
- **Host detection:** Read as uint32_t = 0x48B00BBB (little-endian)

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

# Incremental rebuild (faster)
./rebuild_project.sh incremental

# Program FPGA
vivado -mode batch -source scripts/program.tcl

# Build host tools
cd host
gcc -O2 -o bbo_verify bbo_verify.c
```

## Testing

```bash
# Verify PCIe link
lspci -d 10ee: -vvv | grep -E "LnkSta|Speed"

# Run BBO packet verification (56-byte format with magic header)
cd host
./bbo_verify 10

# Expected output:
# BBO Packet Verification (Project 23 - 56-byte format with magic header)
# ======================================================================
# Device: /dev/xdma0_c2h_0
# Packet size: 56 bytes (7 beats x 8 bytes)
# Magic header: 0xBB0BB048
#
# Raw data dump (560 bytes):
#   0000: bb 0b b0 48 00 00 00 38  53 50 59 20 20 20 20 20  |...H...8SPY     |
#   0010: 00 00 00 00 00 00 00 00  d8 91 31 00 2c 01 00 00  |..........1.,...|
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
|   |   +-- bbo_axi_stream.vhd       # 7-beat AXI-Stream FSM with magic header
|   +-- fifo/
|       +-- async_fifo.vhd           # Gray-code CDC FIFO
+-- constraints/
|   +-- ax7203_order_book.xdc        # Pin assignments and timing constraints
+-- scripts/
|   +-- build.tcl                    # Vivado build script
|   +-- rebuild_project.sh           # Incremental build helper
+-- host/
|   +-- bbo_verify.c                 # BBO packet verification tool (56-byte format)
+-- docs/
    +-- PCIE_DEBUG_CONTEXT.md        # Detailed PCIe debugging notes
```

## Bug Fixes Applied

### Spread Calculation Always Zero (Dec 2025)

**Symptom:** Spread field showed 0x00000000 in all BBO packets.

**Root Cause:** The COMPUTE_SPREAD state in bbo_tracker.vhd used `best_bid_found` and `best_ask_found` flags which reset each scan cycle.

**Fix:** Changed to use persistent register values:
```vhdl
-- Before (broken)
if best_bid_found = '1' and best_ask_found = '1' then

-- After (fixed)
if (best_bid_price_reg /= x"00000000") and (best_ask_price_reg /= x"FFFFFFFF") then
```

### Gen2 Clock Constraint Path Mismatch (Dec 2025)

**Symptom:** 26,418 unconstrained registers at Gen2 (250 MHz), causing data corruption.

**Root Cause:** XDC constraints used path pattern `pcie2_ip_i/*/inst/` but actual hierarchy was `pcie2_ip_i/U0/inst/`.

**Fix:** Added explicit path patterns matching actual design hierarchy in ax7203_order_book.xdc.

### T3/T4 Timestamps Not Captured (Dec 2025)

**Symptom:** T3 and T4 fields always showed 0x00000000.

**Root Cause:** bbo_axi_stream.vhd passed through upstream zeros instead of capturing local timestamps.

**Fix:** Added local cycle counter and timestamp capture in bbo_axi_stream.vhd:
- T3: Captured when bbo_valid pulse received
- T4: Captured when BEAT1 AXI-Stream handshake completes

### Magic Header for Packet Synchronization (Jan 2026)

**Symptom:** Host software occasionally lost packet alignment due to DMA transfer boundaries not aligning with 48-byte packets.

**Root Cause:** PCIe DMA streaming mode delivers data in arbitrary chunks without packet framing.

**Fix:** Added 8-byte magic header (0xBB0BB048 + packet length) to each packet:
- bbo_axi_stream.vhd: Added BEAT0 state for header, changed from 6-beat to 7-beat FSM
- Packet size increased from 48 to 56 bytes
- Host software scans for magic header to find packet boundaries

**VHDL Changes:**
```vhdl
-- New constants
constant MAGIC_HEADER  : STD_LOGIC_VECTOR(31 downto 0) := x"BB0BB048";
constant PACKET_LENGTH : STD_LOGIC_VECTOR(31 downto 0) := x"00000038";

-- State machine: IDLE + 7 beats (BEAT0 is new header beat)
type state_type is (IDLE, BEAT0, BEAT1, BEAT2, BEAT3, BEAT4, BEAT5, BEAT6);

-- In IDLE, preload header with byte swap for little-endian AXI
tdata_int <= byte_swap_64(MAGIC_HEADER & PACKET_LENGTH);
```

## Implementation Details

### Startup Delay

The bbo_axi_stream module implements a ~4.2ms startup delay (at 250 MHz) after reset before accepting BBO data. This ensures the XDMA core has fully initialized before data transmission begins. The delay uses a 20-bit counter that must saturate before `bbo_ready` is asserted.

### Host-Side FPGA Reset

The bbo_verify.c host tool includes an FPGA state reset function that writes to `/dev/xdma0_user` at offset 0x0000. This clears any stale BBO state in the FPGA before starting a new capture session.

## Known Issues

### Occasional Packet Resync Required

**Status:** Not fixed (will not affect Phase 3 architecture)

**Symptom:** Host software occasionally loses sync and needs to rescan for magic header.

**Observations:**
- Occurs even with IOMMU disabled
- More frequent with high packet rates
- Recovery via magic header scan works correctly

**Analysis:** Likely timing-related issue in AXI-Stream handshaking between FPGA and XDMA when tvalid stays high across beat transitions. The Phase 3 multi-FPGA architecture uses Aurora GTX links instead of PCIe, so this issue will not be pursued further.

## Hardware Requirements

- FPGA Board: AX7203 (Kintex-7 XC7K325T)
- External 12V power (required for GTP transceivers)
- PCIe slot or Thunderbolt 4 dock
- Gigabit Ethernet connection for ITCH feed
- **Recommended:** Disable IOMMU for PCIe DMA (`intel_iommu=off` kernel parameter)

## Dependencies

- Vivado 2019.1+
- Xilinx dma_ip_drivers (XDMA Linux driver)
- GCC for host tools

---

**Status:** Completed and tested on hardware

**Created:** December 2025

**Last Updated:** January 2026

**Author:** Adilson Dias

**Project:** https://github.com/adilsondias-engineer/fpga-trading-systems
