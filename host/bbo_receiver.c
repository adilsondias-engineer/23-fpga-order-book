/*
 * BBO Receiver - Reads BBO packets from XDMA C2H stream
 *
 * Build (from VS Developer Command Prompt):
 *   cl /O2 bbo_receiver.c /Fe:bbo_receiver.exe setupapi.lib
 *
 * Usage: bbo_receiver.exe [count] [debug|regs]
 *        count = number of BBO packets to receive (default: 10)
 *        debug = if present, use large buffer debug mode
 *        regs  = if present, dump XDMA registers and exit
 *
 * BBO Packet Format (64 bytes to meet XDMA streaming requirement):
 *   Bytes 0-7:   Symbol (8 ASCII chars, null-padded)
 *   Bytes 8-11:  Bid Price (uint32, little-endian)
 *   Bytes 12-15: Bid Size (uint32)
 *   Bytes 16-19: Ask Price (uint32)
 *   Bytes 20-23: Ask Size (uint32)
 *   Bytes 24-27: Spread (uint32)
 *   Bytes 28-31: T1 timestamp (ITCH parse, cycles)
 *   Bytes 32-35: T2 timestamp (CDC FIFO write)
 *   Bytes 36-39: T3 timestamp (BBO FIFO read)
 *   Bytes 40-43: T4 timestamp (TX start)
 *   Bytes 44-47: Padding (0xDEADBEEF)
 *   Bytes 48-63: Extra padding (0x00000000) - required for XDMA 64-byte alignment
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <SetupAPI.h>
#include <INITGUID.H>
#include <strsafe.h>

#pragma comment(lib, "setupapi.lib")

#define BBO_PACKET_SIZE 64 // Changed from 48 to 64 to meet XDMA streaming requirement
#define DEBUG_BUFFER_SIZE 65536

// XDMA device interface GUID (from xdma_public.h)
// {74c7e4a9-6d5d-4a70-bc0d-20691dff9e9d}
DEFINE_GUID(GUID_DEVINTERFACE_XDMA,
            0x74c7e4a9, 0x6d5d, 0x4a70, 0xbc, 0x0d, 0x20, 0x69, 0x1d, 0xff, 0x9e, 0x9d);

#pragma pack(push, 1)
typedef struct
{
    char symbol[8];        // 0-7
    uint32_t bid_price;    // 8-11
    uint32_t bid_size;     // 12-15
    uint32_t ask_price;    // 16-19
    uint32_t ask_size;     // 20-23
    uint32_t spread;       // 24-27
    uint32_t ts_t1;        // 28-31: ITCH parse timestamp
    uint32_t ts_t2;        // 32-35: CDC FIFO write
    uint32_t ts_t3;        // 36-39: BBO FIFO read
    uint32_t ts_t4;        // 40-43: TX start
    uint32_t padding;      // 44-47: Should be 0xDEADBEEF
    uint32_t extra_pad[4]; // 48-63: Extra padding (0x00000000) - XDMA 64-byte alignment requirement
} BboPacket;
#pragma pack(pop)

// Find XDMA device and return base path
int find_xdma_device(char *devpath, size_t len_devpath)
{
    HDEVINFO dev_info;
    SP_DEVICE_INTERFACE_DATA dev_interface;
    DWORD index;
    int found = 0;

    dev_info = SetupDiGetClassDevs((LPGUID)&GUID_DEVINTERFACE_XDMA, NULL, NULL,
                                   DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (dev_info == INVALID_HANDLE_VALUE)
    {
        fprintf(stderr, "SetupDiGetClassDevs failed: %lu\n", GetLastError());
        return 0;
    }

    dev_interface.cbSize = sizeof(SP_DEVICE_INTERFACE_DATA);

    // Enumerate devices
    for (index = 0; SetupDiEnumDeviceInterfaces(dev_info, NULL,
                                                (LPGUID)&GUID_DEVINTERFACE_XDMA, index, &dev_interface);
         ++index)
    {

        ULONG detail_size = 0;

        // Get required buffer size
        SetupDiGetDeviceInterfaceDetail(dev_info, &dev_interface, NULL, 0,
                                        &detail_size, NULL);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER)
        {
            continue;
        }

        // Allocate detail buffer
        PSP_DEVICE_INTERFACE_DETAIL_DATA dev_detail =
            (PSP_DEVICE_INTERFACE_DETAIL_DATA)HeapAlloc(GetProcessHeap(),
                                                        HEAP_ZERO_MEMORY, detail_size);
        if (!dev_detail)
        {
            continue;
        }
        dev_detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA);

        // Get device interface detail
        if (SetupDiGetDeviceInterfaceDetail(dev_info, &dev_interface, dev_detail,
                                            detail_size, NULL, NULL))
        {
            StringCchCopyA(devpath, len_devpath, dev_detail->DevicePath);
            found = 1;
        }

        HeapFree(GetProcessHeap(), 0, dev_detail);

        if (found)
            break;
    }

    SetupDiDestroyDeviceInfoList(dev_info);
    return found ? (int)(index + 1) : 0;
}

void print_bbo(const BboPacket *bbo, int index)
{
    char symbol[9] = {0};
    memcpy(symbol, bbo->symbol, 8);

    printf("[%4d] Symbol: %-8s | Bid: %8u @ %8u | Ask: %8u @ %8u | Spread: %u\n",
           index,
           symbol,
           bbo->bid_price, bbo->bid_size,
           bbo->ask_price, bbo->ask_size,
           bbo->spread);

    // Calculate latency if timestamps are valid
    if (bbo->ts_t4 > bbo->ts_t1 && bbo->ts_t1 != 0)
    {
        uint32_t latency_cycles = bbo->ts_t4 - bbo->ts_t1;
        // Assuming 125 MHz clock: 1 cycle = 8 ns
        uint32_t latency_ns = latency_cycles * 8;
        printf("       Timestamps: T1=%u T2=%u T3=%u T4=%u | Latency: %u ns\n",
               bbo->ts_t1, bbo->ts_t2, bbo->ts_t3, bbo->ts_t4, latency_ns);
    }

    // Verify padding
    if (bbo->padding != 0xDEADBEEF)
    {
        printf("       WARNING: Invalid padding 0x%08X (expected 0xDEADBEEF)\n", bbo->padding);
    }
}

void hexdump(const unsigned char *data, size_t len)
{
    for (size_t i = 0; i < len; i += 16)
    {
        printf("%04zx: ", i);
        for (size_t j = 0; j < 16 && i + j < len; j++)
        {
            printf("%02x ", data[i + j]);
        }
        printf(" ");
        for (size_t j = 0; j < 16 && i + j < len; j++)
        {
            char c = data[i + j];
            printf("%c", (c >= 32 && c < 127) ? c : '.');
        }
        printf("\n");
    }
}

// Read XDMA register via control device
DWORD read_xdma_reg(HANDLE hControl, long offset)
{
    DWORD value = 0;
    DWORD bytesRead;
    if (SetFilePointer(hControl, offset, NULL, FILE_BEGIN) != INVALID_SET_FILE_POINTER)
    {
        if (!ReadFile(hControl, &value, 4, &bytesRead, NULL))
        {
            printf("ReadFile failed for offset 0x%lX: error %lu\n", offset, GetLastError());
        }
    }
    else
    {
        printf("SetFilePointer failed for offset 0x%lX: error %lu\n", offset, GetLastError());
    }
    return value;
}

// Dump XDMA registers for debugging
void dump_xdma_registers(HANDLE hControl)
{
    printf("\n=== XDMA Register Dump ===\n\n");

    // H2C Engine 0 registers
    DWORD h2c_id = read_xdma_reg(hControl, 0x0000);
    DWORD h2c_ctrl = read_xdma_reg(hControl, 0x0004);
    DWORD h2c_status = read_xdma_reg(hControl, 0x0040);

    printf("H2C Engine 0:\n");
    printf("  Identifier (0x0000): 0x%08lX  [Streaming=%d]\n", h2c_id, (h2c_id >> 15) & 1);
    printf("  Control    (0x0004): 0x%08lX\n", h2c_ctrl);
    printf("  Status     (0x0040): 0x%08lX\n", h2c_status);
    printf("\n");

    // C2H Engine 0 registers
    DWORD c2h_id = read_xdma_reg(hControl, 0x1000);
    DWORD c2h_ctrl = read_xdma_reg(hControl, 0x1004);
    DWORD c2h_status = read_xdma_reg(hControl, 0x1040);
    DWORD c2h_cmp_lo = read_xdma_reg(hControl, 0x1048);
    DWORD c2h_cmp_hi = read_xdma_reg(hControl, 0x104C);

    printf("C2H Engine 0:\n");
    printf("  Identifier (0x1000): 0x%08lX  [Streaming=%d]\n", c2h_id, (c2h_id >> 15) & 1);
    printf("  Control    (0x1004): 0x%08lX\n", c2h_ctrl);
    printf("  Status     (0x1040): 0x%08lX\n", c2h_status);
    printf("  Completed  (0x1048): 0x%08lX%08lX\n", c2h_cmp_hi, c2h_cmp_lo);
    printf("\n");

    // Decode C2H status register bits
    printf("C2H Status decode:\n");
    printf("  Busy:              %lu\n", (c2h_status >> 0) & 1);
    printf("  Descriptor Stopped: %lu\n", (c2h_status >> 1) & 1);
    printf("  Descriptor Complete:%lu\n", (c2h_status >> 2) & 1);
    printf("  Align Mismatch:    %lu\n", (c2h_status >> 3) & 1);
    printf("  Magic Stopped:     %lu\n", (c2h_status >> 4) & 1);
    printf("  Invalid Length:    %lu\n", (c2h_status >> 5) & 1);
    printf("  Idle Stopped:      %lu\n", (c2h_status >> 6) & 1);
    printf("\n");

    // SGDMA Common registers
    DWORD sgdma_id = read_xdma_reg(hControl, 0x4000);
    DWORD sgdma_ctrl = read_xdma_reg(hControl, 0x4004);

    printf("SGDMA Common:\n");
    printf("  Identifier (0x4000): 0x%08lX\n", sgdma_id);
    printf("  Control    (0x4004): 0x%08lX\n", sgdma_ctrl);
    printf("\n");

    printf("=== End Register Dump ===\n\n");
}

int main(int argc, char *argv[])
{
    HANDLE hDevice;
    DWORD bytesRead;
    BboPacket bbo;
    int count = 10;
    int received = 0;
    char base_path[MAX_PATH + 1];
    char c2h_path[MAX_PATH + 1];
    char control_path[MAX_PATH + 1];
    int num_devices;
    int debug_mode = 0;
    int regs_mode = 0;

    if (argc > 1)
    {
        count = atoi(argv[1]);
        if (count <= 0)
            count = 10;
    }
    if (argc > 2 && strcmp(argv[2], "debug") == 0)
    {
        debug_mode = 1;
        printf("DEBUG MODE: Using %d byte buffer\n", DEBUG_BUFFER_SIZE);
    }
    if (argc > 2 && strcmp(argv[2], "regs") == 0)
    {
        regs_mode = 1;
        printf("REGISTER MODE: Dumping XDMA registers\n");
    }

    printf("BBO Receiver - Searching for XDMA devices...\n");

    // Find XDMA device using SetupAPI
    num_devices = find_xdma_device(base_path, sizeof(base_path));
    if (num_devices == 0)
    {
        printf("ERROR: No XDMA devices found.\n");
        printf("  Check that XDMA driver is installed and FPGA is programmed.\n");
        return 1;
    }

    printf("Found %d XDMA device(s).\n", num_devices);
    printf("Base path: %s\n", base_path);

    // Construct control path
    StringCchCopyA(control_path, sizeof(control_path), base_path);
    StringCchCatA(control_path, sizeof(control_path), "\\control");

    // If regs mode, dump registers and exit
    if (regs_mode)
    {
        HANDLE hControl = CreateFileA(
            control_path,
            GENERIC_READ | GENERIC_WRITE,
            0,
            NULL,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            NULL);

        if (hControl == INVALID_HANDLE_VALUE)
        {
            DWORD err = GetLastError();
            printf("ERROR: Failed to open control device (error %lu)\n", err);
            printf("Control path: %s\n", control_path);
            return 1;
        }

        dump_xdma_registers(hControl);
        CloseHandle(hControl);
        return 0;
    }

    // Construct C2H path
    StringCchCopyA(c2h_path, sizeof(c2h_path), base_path);
    StringCchCatA(c2h_path, sizeof(c2h_path), "\\c2h_0");

    printf("C2H path: %s\n", c2h_path);
    printf("Waiting for %d BBO packets...\n\n", count);

    // Open XDMA C2H device
    hDevice = CreateFileA(
        c2h_path,
        GENERIC_READ,
        0,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);

    if (hDevice == INVALID_HANDLE_VALUE)
    {
        DWORD err = GetLastError();
        printf("ERROR: Failed to open C2H device (error %lu)\n", err);
        return 1;
    }

    printf("Device opened successfully.\n\n");

    if (debug_mode)
    {
        // Debug mode: read larger buffer
        unsigned char *debug_buf = (unsigned char *)malloc(DEBUG_BUFFER_SIZE);
        if (!debug_buf)
        {
            printf("ERROR: Failed to allocate debug buffer\n");
            CloseHandle(hDevice);
            return 1;
        }

        printf("Reading up to %d bytes from C2H stream...\n", DEBUG_BUFFER_SIZE);
        printf("This will BLOCK until data arrives. Send ITCH data now!\n\n");

        // Simple blocking read
        if (ReadFile(hDevice, debug_buf, DEBUG_BUFFER_SIZE, &bytesRead, NULL))
        {
            printf("ReadFile succeeded! Read %lu bytes:\n", bytesRead);
            if (bytesRead > 0)
            {
                hexdump(debug_buf, bytesRead > 256 ? 256 : bytesRead);
                if (bytesRead > 256)
                {
                    printf("... (%lu more bytes)\n", bytesRead - 256);
                }
            }
            else
            {
                printf("Read 0 bytes - XDMA returned immediately with no data\n");
            }
        }
        else
        {
            DWORD err = GetLastError();
            printf("ReadFile failed with error %lu\n", err);
        }
        free(debug_buf);
    }
    else
    {
        // Normal mode: simple synchronous reads
        printf("Waiting for BBO packets...\n\n");

        while (received < count)
        {
            if (ReadFile(hDevice, &bbo, BBO_PACKET_SIZE, &bytesRead, NULL))
            {
                if (bytesRead == 0)
                {
                    printf("Read returned 0 bytes, waiting...\n");
                    Sleep(100);
                    continue;
                }

                if (bytesRead != BBO_PACKET_SIZE)
                {
                    printf("WARNING: Partial read %lu bytes (expected %d)\n", bytesRead, BBO_PACKET_SIZE);
                    hexdump((unsigned char *)&bbo, bytesRead);
                    continue;
                }

                received++;
                print_bbo(&bbo, received);
            }
            else
            {
                DWORD err = GetLastError();
                printf("ERROR: ReadFile failed (error %lu)\n", err);
                break;
            }
        }

        printf("\n");
        printf("Received %d BBO packets.\n", received);
    }

    CloseHandle(hDevice);
    return 0;
}
