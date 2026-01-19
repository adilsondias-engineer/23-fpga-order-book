/*
 * BBO Packet Verification Tool (Linux)
 * Reads from XDMA C2H channel and verifies BBO packet format
 *
 * BBO Packet Format (56 bytes = 7 x 64-bit beats):
 *   Beat 1 (bytes 0-7):   Magic (0xBB0BB048) | Length (0x00000038)
 *   Beat 2 (bytes 8-15):  Symbol (8 ASCII chars, e.g., "TESTAAPL")
 *   Beat 3 (bytes 16-23): BidPrice[31:0] | BidSize[63:32]
 *   Beat 4 (bytes 24-31): AskPrice[31:0] | AskSize[63:32]
 *   Beat 5 (bytes 32-39): Spread[31:0]   | T1[63:32]
 *   Beat 6 (bytes 40-47): T2[31:0]       | T3[63:32]
 *   Beat 7 (bytes 48-55): T4[31:0]       | Reserved[63:32] (0x00000000)
 *
 * Magic Header: 0xBB0BB048 (mnemonic: "BBO" + "48" for original 48-byte payload)
 * Packet Length: 0x00000038 (56 bytes total including header)
 *
 * Build: gcc -O2 -o bbo_verify bbo_verify.c
 *
 * Usage: ./bbo_verify [device] [count] [-v] [-raw]
 *   device: XDMA device path (default: /dev/xdma0_c2h_0)
 *   count: Number of BBO packets to read (default: 10)
 *   -v: Verbose mode (show raw beats)
 *   -raw: Just dump raw data without parsing
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/time.h>
#include <errno.h>

#define DEFAULT_DEVICE "/dev/xdma0_c2h_0"
#define DEFAULT_COUNT 10
#define BBO_PACKET_SIZE 56  /* 7 beats x 8 bytes */

/* Magic header for packet synchronization (must match FPGA byte order) */
/* FPGA sends bytes: BB 0B B0 48 -> little-endian uint32 = 0x48B00BBB */
#define BBO_MAGIC_HEADER  0x48B00BBB
#define BBO_PACKET_LENGTH 0x38000000  /* 56 bytes, byte-swapped */

/* Known symbols for packet boundary detection */
static const char *KNOWN_SYMBOLS[] = {
    "AAPL    ", "TSLA    ", "SPY     ", "QQQ     ",
    "GOOGL   ", "MSFT    ", "AMZN    ", "NVDA    ",
    "TESTAAPL", "TEST    "  /* Test symbols from FPGA test pattern generator */
};
#define NUM_KNOWN_SYMBOLS 10

/* BBO Packet structure (packed, 56 bytes) */
typedef struct __attribute__((packed)) {
    uint32_t magic;          /* Bytes 0-3: Magic header (0xBB0BB048) */
    uint32_t length;         /* Bytes 4-7: Packet length (0x00000038 = 56) */
    char     symbol[8];      /* Bytes 8-15: ASCII symbol */
    uint32_t bid_price;      /* Bytes 16-19: Bid price (fixed-point, /10000 for dollars) */
    uint32_t bid_size;       /* Bytes 20-23: Bid size (shares) */
    uint32_t ask_price;      /* Bytes 24-27: Ask price */
    uint32_t ask_size;       /* Bytes 28-31: Ask size */
    uint32_t spread;         /* Bytes 32-35: Spread (ask - bid) */
    uint32_t ts_t1;          /* Bytes 36-39: T1 timestamp (ITCH parse) */
    uint32_t ts_t2;          /* Bytes 40-43: T2 timestamp (CDC FIFO write) */
    uint32_t ts_t3;          /* Bytes 44-47: T3 timestamp (BBO FIFO read) */
    uint32_t ts_t4;          /* Bytes 48-51: T4 timestamp (TX start) */
    uint32_t reserved;       /* Bytes 52-55: Reserved/padding */
} BboPacket;

/*
 * Check if a symbol matches one of the known symbols
 */
int is_known_symbol(const char *symbol) {
    for (int i = 0; i < NUM_KNOWN_SYMBOLS; i++) {
        if (memcmp(symbol, KNOWN_SYMBOLS[i], 8) == 0) {
            return 1;
        }
    }
    return 0;
}

/*
 * Find the first valid packet boundary by searching for magic header.
 * XDMA may have residual data from previous runs, causing initial misalignment.
 * Returns offset to first valid packet, or -1 if not found.
 */
int find_packet_boundary(const uint8_t *buf, size_t len) {
    /* Search for magic header at the start of a potential packet */
    for (size_t i = 0; i <= len - BBO_PACKET_SIZE; i++) {
        const BboPacket *pkt = (const BboPacket *)(buf + i);
        if (pkt->magic == BBO_MAGIC_HEADER && pkt->length == BBO_PACKET_LENGTH) {
            /* Found magic header - this looks like a valid packet */
            /* Additional check: verify next packet also has valid header if there's room */
            if (i + 2 * BBO_PACKET_SIZE <= len) {
                const BboPacket *next_pkt = (const BboPacket *)(buf + i + BBO_PACKET_SIZE);
                if (next_pkt->magic == BBO_MAGIC_HEADER && next_pkt->length == BBO_PACKET_LENGTH) {
                    return i;  /* Two consecutive valid headers - high confidence */
                }
            } else {
                return i;  /* Only one packet fits, assume it's valid */
            }
        }
    }
    return -1;
}

void print_bbo(const BboPacket *pkt, int index, int gen2_mode) {
    char symbol[9];
    memcpy(symbol, pkt->symbol, 8);
    symbol[8] = '\0';

    /* Calculate latency in nanoseconds
     * T1/T2: RGMII RX domain - ALWAYS 125 MHz (8 ns per cycle)
     * T3/T4: AXI/XDMA domain - Gen2 (250 MHz, 4 ns) or Gen1 (125 MHz, 8 ns)
     */
    uint32_t ns_per_cycle_rgmii = 8;  /* T1/T2: always 125 MHz */
    uint32_t ns_per_cycle_axi = gen2_mode ? 4 : 8;  /* T3/T4: Gen2=250MHz */

    /* Latency A: ITCH parse to CDC FIFO write (T1 to T2) */
    uint32_t delta_a = (pkt->ts_t2 >= pkt->ts_t1) ? (pkt->ts_t2 - pkt->ts_t1) : 0;
    uint32_t latency_a_ns = delta_a * ns_per_cycle_rgmii;

    /* Latency B: BBO FIFO read to AXI TX start (T3 to T4) */
    uint32_t delta_b = (pkt->ts_t4 >= pkt->ts_t3) ? (pkt->ts_t4 - pkt->ts_t3) : 0;
    uint32_t latency_b_ns = delta_b * ns_per_cycle_axi;

    /* Total latency */
    uint32_t total_latency_ns = latency_a_ns + latency_b_ns;

    /* Calculate correct spread locally (FPGA spread may be stale) */
    uint32_t calculated_spread;
    int is_crossed = 0;
    if (pkt->ask_price > pkt->bid_price) {
        calculated_spread = pkt->ask_price - pkt->bid_price;
    } else {
        calculated_spread = 0;
        is_crossed = 1;
    }

    printf("BBO #%d:\n", index);
    printf("  Magic:     0x%08X (len=%u)%s\n", pkt->magic, pkt->length,
           (pkt->magic == BBO_MAGIC_HEADER && pkt->length == BBO_PACKET_LENGTH) ? " [OK]" : " [INVALID]");
    printf("  Symbol:    '%s'\n", symbol);
    printf("  Bid:       $%.4f x %u shares\n",
           pkt->bid_price / 10000.0, pkt->bid_size);
    printf("  Ask:       $%.4f x %u shares\n",
           pkt->ask_price / 10000.0, pkt->ask_size);
    printf("  Spread:    $%.4f%s\n", calculated_spread / 10000.0,
           is_crossed ? " [CROSSED]" : "");
    if (pkt->spread != calculated_spread) {
        printf("  (FPGA spread: $%.4f - stale)\n", pkt->spread / 10000.0);
    }
    printf("  Timestamps: T1=%u T2=%u T3=%u T4=%u\n",
           pkt->ts_t1, pkt->ts_t2, pkt->ts_t3, pkt->ts_t4);
    printf("  Latency A: %u cycles (%u ns) [RGMII 125MHz]\n", delta_a, latency_a_ns);
    printf("  Latency B: %u cycles (%u ns) [AXI %s]\n", delta_b, latency_b_ns,
           gen2_mode ? "250MHz" : "125MHz");
    printf("  Total:     %u ns (%.3f us)\n", total_latency_ns, total_latency_ns / 1000.0);
    printf("\n");
}

void print_raw_beats(const uint64_t *beats, int num_beats) {
    printf("  Raw beats:\n");
    for (int i = 0; i < num_beats; i++) {
        printf("    Beat %d: 0x%016lx\n", i + 1, beats[i]);
    }
}

void print_raw_dump(const uint8_t *buf, size_t len) {
    printf("Raw data dump (%zu bytes):\n", len);
    for (size_t i = 0; i < len; i++) {
        if (i % 16 == 0) {
            printf("  %04zx: ", i);
        }
        printf("%02x ", buf[i]);
        if (i % 16 == 7) printf(" ");
        if (i % 16 == 15 || i == len - 1) {
            /* Print ASCII representation */
            int padding = 15 - (i % 16);
            for (int j = 0; j < padding; j++) printf("   ");
            if (padding > 7) printf(" ");
            printf(" |");
            size_t line_start = i - (i % 16);
            for (size_t j = line_start; j <= i; j++) {
                char c = buf[j];
                printf("%c", (c >= 0x20 && c <= 0x7e) ? c : '.');
            }
            printf("|\n");
        }
    }
    printf("\n");
}

int verify_bbo(const BboPacket *pkt, int *errors) {
    int local_errors = 0;

    /* Check magic header */
    if (pkt->magic != BBO_MAGIC_HEADER) {
        printf("  ERROR: Invalid magic header: 0x%08X (expected 0x%08X)\n",
               pkt->magic, BBO_MAGIC_HEADER);
        local_errors++;
    }

    /* Check packet length */
    if (pkt->length != BBO_PACKET_LENGTH) {
        printf("  ERROR: Invalid packet length: %u (expected %u)\n",
               pkt->length, BBO_PACKET_LENGTH);
        local_errors++;
    }

    /* Check for valid symbol (warning only - magic header is authoritative) */
    if (!is_known_symbol(pkt->symbol)) {
        char sym[9];
        memcpy(sym, pkt->symbol, 8);
        sym[8] = '\0';
        printf("  WARNING: Unknown symbol '%s'\n", sym);
    }

    /* Check for reasonable price values (non-zero, less than $1M) */
    if (pkt->bid_price == 0 || pkt->bid_price > 10000000000UL) {
        printf("  WARNING: Unusual bid price: %u\n", pkt->bid_price);
    }
    if (pkt->ask_price == 0 || pkt->ask_price > 10000000000UL) {
        printf("  WARNING: Unusual ask price: %u\n", pkt->ask_price);
    }

    /* Check spread = ask - bid (handle crossed markets) */
    uint32_t expected_spread;
    if (pkt->ask_price > pkt->bid_price) {
        /* Normal market: spread = ask - bid */
        expected_spread = pkt->ask_price - pkt->bid_price;
    } else {
        /* Crossed market (bid >= ask): spread = 0 */
        expected_spread = 0;
    }
    if (pkt->spread != expected_spread) {
        printf("  WARNING: Spread mismatch (expected %u, got %u)\n",
               expected_spread, pkt->spread);
    }

    *errors += local_errors;
    return local_errors == 0;
}

/*
 * Reset FPGA state to ensure deterministic behavior across runs.
 * This clears BBO registers so each run starts from a clean state.
 *
 * NOTE: This requires /dev/xdma0_user access (AXI-Lite BAR).
 * If the device doesn't exist or reset fails, we continue anyway
 * (for backward compatibility with older FPGA designs).
 */
void reset_fpga_state(void) {
    const char *user_dev = "/dev/xdma0_user";
    int fd = open(user_dev, O_RDWR);

    if (fd < 0) {
        /* Not a fatal error - older FPGA designs don't have reset register */
        if (errno == ENOENT) {
            /* Device doesn't exist - expected for older FPGA versions */
            return;
        }
        fprintf(stderr, "Warning: Cannot open %s for reset: %s\n",
                user_dev, strerror(errno));
        fprintf(stderr, "         BBO state may persist from previous run.\n");
        return;
    }

    /* Write 1 to reset register at offset 0x0000 */
    uint32_t reset_val = 0x00000001;
    ssize_t ret = pwrite(fd, &reset_val, sizeof(reset_val), 0x0000);

    if (ret != sizeof(reset_val)) {
        fprintf(stderr, "Warning: Reset register write failed: %s\n", strerror(errno));
        fprintf(stderr, "         BBO state may persist from previous run.\n");
        close(fd);
        return;
    }

    /* Wait for reset to propagate (1ms) */
    usleep(1000);

    /* Clear reset bit (optional - depends on FPGA auto-clear) */
    reset_val = 0x00000000;
    pwrite(fd, &reset_val, sizeof(reset_val), 0x0000);

    close(fd);
    printf("FPGA state reset complete\n");
}

void print_usage(const char *prog) {
    printf("Usage: %s [options] [device] [count]\n", prog);
    printf("\nOptions:\n");
    printf("  -v, --verbose   Show raw beats for each packet\n");
    printf("  -raw            Dump raw data without parsing\n");
    printf("  -gen2           Use Gen2 timing (250 MHz, 4 ns/cycle)\n");
    printf("  -gen1           Use Gen1 timing (125 MHz, 8 ns/cycle) [default]\n");
    printf("  --no-reset      Skip FPGA state reset (for debugging)\n");
    printf("\nArguments:\n");
    printf("  device          XDMA device path (default: %s)\n", DEFAULT_DEVICE);
    printf("  count           Number of BBO packets to read (default: %d)\n", DEFAULT_COUNT);
    printf("\nExamples:\n");
    printf("  %s                          # Read 10 packets from default device\n", prog);
    printf("  %s 5                        # Read 5 packets\n", prog);
    printf("  %s -v 3                     # Read 3 packets with raw beats\n", prog);
    printf("  %s /dev/xdma1_c2h_0 10      # Read from different device\n", prog);
    printf("  %s -gen2 -v 5               # Gen2 mode with verbose\n", prog);
}

int main(int argc, char **argv) {
    const char *device = DEFAULT_DEVICE;
    int count = DEFAULT_COUNT;
    int verbose = 0;
    int raw_dump = 0;
    int gen2_mode = 0;  /* Default to Gen1 (125 MHz) for Project 23 */
    int do_reset = 1;   /* Reset FPGA state by default for deterministic behavior */

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0) {
            verbose = 1;
        } else if (strcmp(argv[i], "-raw") == 0) {
            raw_dump = 1;
        } else if (strcmp(argv[i], "-gen2") == 0) {
            gen2_mode = 1;
        } else if (strcmp(argv[i], "-gen1") == 0) {
            gen2_mode = 0;
        } else if (strcmp(argv[i], "--no-reset") == 0) {
            do_reset = 0;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (argv[i][0] == '/') {
            device = argv[i];
        } else if (argv[i][0] >= '0' && argv[i][0] <= '9') {
            count = atoi(argv[i]);
            if (count <= 0) count = DEFAULT_COUNT;
        }
    }

    /* Reset FPGA state before opening device (ensures clean start) */
    if (do_reset) {
        reset_fpga_state();
    }

    printf("BBO Packet Verification (Project 23 - 56-byte format with magic header)\n");
    printf("======================================================================\n");
    printf("Device: %s\n", device);
    printf("Packet size: %d bytes (7 beats x 8 bytes)\n", BBO_PACKET_SIZE);
    printf("Magic header: 0x%08X\n", BBO_MAGIC_HEADER);
    printf("Packets to read: %d (%d bytes)\n", count, count * BBO_PACKET_SIZE);
    printf("PCIe mode: %s (%d ns/cycle)\n", gen2_mode ? "Gen2 250MHz" : "Gen1 125MHz",
           gen2_mode ? 4 : 8);
    printf("Verbose: %s\n", verbose ? "yes" : "no");
    printf("\n");

    /* Open device - use O_NONBLOCK to avoid blocking if no data */
    int fd = open(device, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("Failed to open device");
        printf("\nHint: Check that:\n");
        printf("  1. XDMA driver is loaded (lsmod | grep xdma)\n");
        printf("  2. Device exists (ls -la /dev/xdma*)\n");
        printf("  3. Read permissions are set (try with sudo)\n");
        return 1;
    }

    /* Allocate buffer (aligned for DMA) */
    size_t buf_size = count * BBO_PACKET_SIZE + 256;  /* Extra for partial packet detection */
    uint8_t *buf = (uint8_t *)aligned_alloc(4096, buf_size);
    if (!buf) {
        perror("Failed to allocate buffer");
        close(fd);
        return 1;
    }
    memset(buf, 0, buf_size);

    /* Read data - non-blocking with retry loop */
    printf("Reading BBO packets from FPGA (non-blocking)...\n");
    printf("Note: If you see DMAR errors in dmesg, IOMMU may be blocking DMA.\n");
    printf("      Check: dmesg | grep -i dmar\n");
    printf("      If IOMMU is enabled, you may need to disable it or configure it properly.\n\n");

    struct timeval start, end;
    gettimeofday(&start, NULL);

    ssize_t bytes_read = 0;
    ssize_t total_read = 0;
    int retry_count = 0;
    const int max_retries = 50;  /* 50 * 100ms = 5 seconds max wait */

    while (total_read < (ssize_t)buf_size && retry_count < max_retries) {
        bytes_read = read(fd, buf + total_read, buf_size - total_read);

        if (bytes_read > 0) {
            total_read += bytes_read;
            retry_count = 0;  /* Reset retry count on successful read */
            printf("\r  Received %zd bytes (%zd packets)...", total_read, total_read / BBO_PACKET_SIZE);
            fflush(stdout);
            /* Keep reading until no more data */
        } else if (bytes_read == 0 || (bytes_read < 0 && errno == EAGAIN)) {
            /* No data available */
            if (total_read > 0) {
                /* Have some data, wait longer for more packets */
                usleep(50000);  /* 50ms between retries */
                retry_count++;
                if (retry_count >= 20) break;  /* Exit after 1 second with no new data */
            } else {
                /* No data yet, wait longer */
                usleep(100000);  /* 100ms */
                retry_count++;
            }
        } else {
            /* Real error - print detailed error information */
            int errno_save = errno;
            printf("\nRead failed: errno=%d (%s)\n", errno_save, strerror(errno_save));
            if (errno_save == EIO) {
                printf("  EIO: I/O error - check XDMA driver and PCIe link status\n");
                printf("       This may indicate DMA transfer failure or FPGA not sending data\n");
            } else if (errno_save == ENODEV) {
                printf("  ENODEV: Device not found - check XDMA driver is loaded\n");
            } else if (errno_save == EINVAL) {
                printf("  EINVAL: Invalid argument - check buffer alignment\n");
            } else {
                printf("  Unknown error code - check XDMA driver logs: dmesg | tail -20\n");
            }
            printf("\n  If you see DMAR errors in dmesg:\n");
            printf("    1. Check IOMMU status: dmesg | grep -i \"DMAR\\|IOMMU\"\n");
            printf("    2. If IOMMU is blocking DMA, you may need to:\n");
            printf("       - Disable IOMMU in BIOS/UEFI, OR\n");
            printf("       - Add kernel parameter: intel_iommu=off (for Intel) or iommu=off\n");
            printf("    3. Check if FPGA is actually sending data (state machine may be stuck)\n");
            break;
        }
    }
    printf("\n");  /* Newline after progress */

    bytes_read = total_read;

    gettimeofday(&end, NULL);

    if (bytes_read <= 0) {
        printf("No data received after %d retries.\n", max_retries);
        printf("\nDiagnostics:\n");
        printf("  1. Check XDMA driver: lsmod | grep xdma\n");
        printf("  2. Check device exists: ls -la %s\n", device);
        printf("  3. Check device permissions: ls -l %s\n", device);
        printf("  4. Check XDMA status: dmesg | grep -i xdma | tail -10\n");
        printf("  5. Check DMAR/IOMMU errors: dmesg | grep -i dmar\n");
        printf("     If IOMMU is blocking DMA, add kernel parameter: intel_iommu=off\n");
        printf("  6. Make sure to send ITCH data to the FPGA before running this tool.\n");
        printf("  7. If XDMA transfer times out, FPGA state machine may be stuck.\n");
        printf("     Check FPGA debug outputs (dbg_state, dbg_tvalid_now, dbg_tready_now).\n");
        printf("  8. Try with -raw flag to see any data that might be present.\n");
        free(buf);
        close(fd);
        return 1;
    }

    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_usec - start.tv_usec) / 1000000.0;
    double throughput = elapsed > 0 ? (bytes_read / 1024.0 / 1024.0) / elapsed : 0;

    printf("Read %zd bytes in %.3f seconds (%.2f MB/s)\n\n",
           bytes_read, elapsed, throughput);

    /* Raw dump mode */
    if (raw_dump) {
        print_raw_dump(buf, bytes_read);
        free(buf);
        close(fd);
        return 0;
    }

    /* Find packet boundary - XDMA may have residual data from previous runs */
    int packet_offset = find_packet_boundary(buf, bytes_read);
    if (packet_offset < 0) {
        printf("ERROR: Could not find valid packet boundary \n");
        printf("Raw data dump:\n");
        print_raw_dump(buf, bytes_read > 256 ? 256 : bytes_read);
        free(buf);
        close(fd);
        return 1;
    }

    if (packet_offset > 0) {
        printf("NOTE: Found %d bytes of garbage before first valid packet (XDMA residual)\n", packet_offset);
        printf("      Skipping to offset %d for packet parsing.\n\n", packet_offset);
    }

    /* Verify packets */
    uint8_t *data_start = buf + packet_offset;
    size_t data_len = bytes_read - packet_offset;
    int packets_read = data_len / BBO_PACKET_SIZE;
    int errors = 0;
    int valid_packets = 0;

    printf("Parsing %d BBO packets:\n", packets_read);
    printf("========================\n\n");

    for (int i = 0; i < packets_read; i++) {
        BboPacket *pkt = (BboPacket *)(data_start + i * BBO_PACKET_SIZE);

        // Skip packets without valid magic header (garbage/residual data)
        if (pkt->magic != BBO_MAGIC_HEADER) {
            printf("BBO #%d: Skipping (invalid magic: 0x%08X)\n\n", i + 1, pkt->magic);
            continue;
        }

        // Skip initial BBO with uninitialized ask price (0xFFFFFFFF from reset)
        // After software reset, best_ask_price_reg initializes to all 1's until real ask data arrives
        if (pkt->ask_price == 0xFFFFFFFF) {
            printf("BBO #%d: Skipping (uninitialized ask price - waiting for real data)\n\n", i + 1);
            continue;
        }

        print_bbo(pkt, i + 1, gen2_mode);

        if (verbose) {
            print_raw_beats((uint64_t *)(data_start + i * BBO_PACKET_SIZE), 7);
            printf("\n");
        }

        if (verify_bbo(pkt, &errors)) {
            valid_packets++;
        }
    }

    /* Summary */
    printf("\n");
    printf("Results:\n");
    printf("========\n");
    printf("Bytes read:     %zd\n", bytes_read);
    printf("Packets parsed: %d\n", packets_read);
    printf("Valid packets:  %d\n", valid_packets);
    printf("Errors:         %d\n", errors);

    if (errors == 0 && packets_read > 0) {
        printf("Status: PASS - All BBO packets valid!\n");
    } else if (packets_read == 0) {
        printf("Status: NO DATA - No packets received\n");
    } else {
        printf("Status: FAIL - %d errors detected\n", errors);
    }

    /* Check for partial packet */
    int remaining = data_len % BBO_PACKET_SIZE;
    if (remaining > 0) {
        printf("\nWARNING: %d bytes remaining (partial packet)\n", remaining);
        printf("Raw remaining bytes:\n");
        print_raw_dump(data_start + packets_read * BBO_PACKET_SIZE, remaining);
    }

    free(buf);
    close(fd);
    return (errors == 0 && packets_read > 0) ? 0 : 1;
}
