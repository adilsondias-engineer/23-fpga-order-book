----------------------------------------------------------------------------------
-- Ethernet Top-Level Module
-- Purpose: Integrates RGMII receiver, MAC parser, and IP parser
--          Provides clean interface for upper layers (UDP parser, etc.)
--
-- Gen2 Migration: Removed 200 MHz oscillator clock.
--   The 200 MHz clock was causing Gen2 PCIe to freeze (AX7203 board issue).
--   Now uses RGMII RX clock (125 MHz) for all internal synchronization.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity ethernet_top is
    Port (
        -- Reset
        reset_n           : in  STD_LOGIC;
        
        -- RGMII Port 1 Interface
        -- RX
        rgmii1_rxc        : in  STD_LOGIC;
        rgmii1_rxctl      : in  STD_LOGIC;
        rgmii1_rxd        : in  STD_LOGIC_VECTOR(3 downto 0);
        -- TX
        rgmii1_txc        : out STD_LOGIC;
        rgmii1_txctl      : out STD_LOGIC;
        rgmii1_txd        : out STD_LOGIC_VECTOR(3 downto 0);

        -- BBO UDP TX Interface (125 MHz RGMII domain - synchronized by async FIFO in upper layer)
        bbo_update        : in  STD_LOGIC;
        bbo_symbol        : in  STD_LOGIC_VECTOR(63 downto 0);
        bbo_bid_price     : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_bid_size      : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_price     : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_size      : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_spread        : in  STD_LOGIC_VECTOR(31 downto 0);
        -- 4-point FPGA Latency Timestamps (for latency measurement)
        -- All timestamps use 125 MHz cycle counts (8 ns per cycle)
        -- T1: ITCH parse START (125 MHz RGMII RX domain, passed through itch_cdc_fifo and bbo_fifo)
        -- T2: ITCH parse COMPLETE (125 MHz RGMII RX domain, passed through itch_cdc_fifo and bbo_fifo)
        -- T3: bbo_fifo read (125 MHz TX domain, captured at FIFO read in simple_top)
        -- T4: UDP TX start (125 MHz TX domain, captured in bbo_payload_source)
        bbo_ts_t1         : in  STD_LOGIC_VECTOR(31 downto 0);  -- T1: ITCH parse START (125 MHz)
        bbo_ts_t2         : in  STD_LOGIC_VECTOR(31 downto 0);  -- T2: ITCH parse COMPLETE (125 MHz)
        bbo_ts_t3         : in  STD_LOGIC_VECTOR(31 downto 0);  -- T3: bbo_fifo read (125 MHz)
        tx_cycle_counter_in : in  STD_LOGIC_VECTOR(31 downto 0);  -- 125 MHz TX cycle counter (for T4)

        -- All outputs synchronized to 200MHz via FIFO (no synchronization needed in upper layers)
        frame_valid       : out STD_LOGIC;  -- Frame valid (pulse)
        ip_rx_req         : out STD_LOGIC;  -- IP frame detected (pulse)
        udp_rx_req        : out STD_LOGIC;  -- UDP frame detected (pulse)
        frame_count       : out STD_LOGIC_VECTOR(31 downto 0);  -- Frame counter
        mac_src           : out STD_LOGIC_VECTOR(47 downto 0);  -- Source MAC address
        mac_dest          : out STD_LOGIC_VECTOR(47 downto 0);  -- Destination MAC address
        ethertype         : out STD_LOGIC_VECTOR(15 downto 0);  -- EtherType
        mac_rec_error     : out STD_LOGIC;  -- MAC receive error
        ip_rx_end         : out STD_LOGIC;  -- IP receive end (pulse)
        icmp_rx_req       : out STD_LOGIC;  -- ICMP frame detected (pulse)
        ip_addr_check_error : out STD_LOGIC;  -- IP address check error
        ip_checksum_error : out STD_LOGIC;  -- IP checksum error
        upper_layer_data_length : out STD_LOGIC_VECTOR(15 downto 0);  -- Upper layer data length
        ip_total_data_length : out STD_LOGIC_VECTOR(15 downto 0);  -- IP total length
        net_protocol     : out STD_LOGIC_VECTOR(7 downto 0);  -- Network protocol
        ip_rec_source_addr : out STD_LOGIC_VECTOR(31 downto 0);  -- IP source address
        ip_rec_destination_addr : out STD_LOGIC_VECTOR(31 downto 0);  -- IP destination address

        -- UDP header fields (200MHz synchronized)
        udp_src_port     : out STD_LOGIC_VECTOR(15 downto 0);  -- UDP source port
        udp_dst_port     : out STD_LOGIC_VECTOR(15 downto 0);  -- UDP destination port
        udp_data_length  : out STD_LOGIC_VECTOR(15 downto 0);  -- UDP data length
        udp_rec_data_valid : out STD_LOGIC;  -- UDP data valid
        udp_checksum_error : out STD_LOGIC;  -- UDP checksum error

        -- UDP payload streaming (125MHz RGMII domain - for ITCH parser)
        -- IMPORTANT: These signals are in the RGMII clock domain (125MHz)
        -- Upper layers using these signals must run in RGMII clock domain or implement CDC
        rgmii_rxc_out     : out STD_LOGIC;  -- RGMII RX clock (125MHz) - for upper layer synchronization
        clk_txd_out       : out STD_LOGIC;  -- TX clock (125MHz from MMCM) - for BBO FIFO synchronization
        udp_payload_data  : out STD_LOGIC_VECTOR(7 downto 0);  -- UDP payload data byte
        udp_payload_valid : out STD_LOGIC;  -- UDP payload data valid (1 byte per cycle)
        udp_payload_start : out STD_LOGIC;  -- UDP payload start pulse (first byte)
        udp_payload_end   : out STD_LOGIC;  -- UDP payload end pulse (last byte)

        -- Gen2: sys_clk_200mhz removed (was causing PCIe Gen2 to freeze)

        -- Diagnostic outputs
        fifo_empty        : out STD_LOGIC;  -- FIFO empty flag (for debugging)
        fifo_full         : out STD_LOGIC;   -- FIFO full flag (for debugging)

        -- Diagnostic outputs (RGMII layer)
        rx_valid_out      : out STD_LOGIC;  -- RGMII rx_valid
        frame_start_out   : out STD_LOGIC;  -- RGMII frame_start
        frame_end_out     : out STD_LOGIC;  -- RGMII frame_end
        frame_valid_mac_out : out STD_LOGIC;   -- MAC frame_valid

        -- TX Diagnostic outputs
        tx_valid_out      : out STD_LOGIC;  -- TX data valid signal
        tx_packets_sent   : out STD_LOGIC_VECTOR(31 downto 0);  -- TX packet counter
        tx_reset_out      : out STD_LOGIC;  -- TX reset state

        -- RGMII TX Debug outputs
        tx_byte_count     : out STD_LOGIC_VECTOR(31 downto 0);  -- Total bytes transmitted
        tx_valid_seen     : out STD_LOGIC;                      -- Sticky: tx_valid was asserted
        last_tx_byte      : out STD_LOGIC_VECTOR(7 downto 0);   -- Last byte transmitted

        -- BBO Packet Builder Debug outputs
        bbo_update_count  : out STD_LOGIC_VECTOR(31 downto 0);  -- Times bbo_update seen by packet builder
        bbo_tx_state      : out STD_LOGIC_VECTOR(3 downto 0);   -- Packet builder state
        bbo_max_state     : out STD_LOGIC_VECTOR(3 downto 0);   -- Max state ever reached (sticky)
        bbo_reset_count   : out STD_LOGIC_VECTOR(15 downto 0)   -- Times reset was asserted

    );
end ethernet_top;

architecture Behavioral of ethernet_top is

    -- ILA Debug Component Declaration (DISABLED - causes timing violations)
    -- Generate using: create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0
    -- Configure: 1 probe, 16 bits wide, 4096 depth
    -- component ila_0
    --     port (
    --         clk : in std_logic;
    --         probe0 : in std_logic_vector(15 downto 0)
    --     );
    -- end component;

    -- Clock signals (Gen2: 200 MHz removed, all logic uses RGMII 125 MHz)
    -- signal sys_clk_200mhz_int : STD_LOGIC;  -- Gen2: removed
    -- signal sys_clk_200mhz_bufg : STD_LOGIC;  -- Gen2: removed

    -- Reset signals
    signal reset_sync1 : STD_LOGIC := '0';
    signal reset_sync2 : STD_LOGIC := '0';
    signal reset : STD_LOGIC;
    
    -- RGMII receiver signals
    signal rx_data : STD_LOGIC_VECTOR(7 downto 0);
    signal rx_valid : STD_LOGIC;
    signal rx_error : STD_LOGIC;
    signal frame_start : STD_LOGIC;
    signal frame_end : STD_LOGIC;
    
    -- MAC parser signals
    signal handler_frame_valid : STD_LOGIC;
    signal handler_frame_count : STD_LOGIC_VECTOR(31 downto 0);
    signal handler_ip_rx_req : STD_LOGIC;
    signal handler_mac_rec_error : STD_LOGIC;
    signal handler_mac_src : STD_LOGIC_VECTOR(47 downto 0);
    signal handler_mac_dest : STD_LOGIC_VECTOR(47 downto 0);
    signal handler_ethertype : STD_LOGIC_VECTOR(15 downto 0);

    -- IP parser signals
    signal handler_ip_rx_end : STD_LOGIC := '0';
    signal handler_udp_rx_req : STD_LOGIC := '0';
    signal handler_icmp_rx_req : STD_LOGIC := '0';
    signal handler_ip_addr_check_error : STD_LOGIC := '0';
    signal handler_ip_checksum_error : STD_LOGIC := '0';
    signal handler_upper_layer_data_length : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_ip_total_data_length : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_net_protocol : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal handler_ip_rec_source_addr : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal handler_ip_rec_destination_addr : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- UDP parser signals (125MHz domain)
    signal handler_udp_src_port : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_udp_dst_port : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_udp_data_length : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_udp_rec_data_valid : STD_LOGIC := '0';
    signal handler_udp_checksum_error : STD_LOGIC := '0';
    -- UDP payload streaming signals (not passed through FIFO - for future ITCH parser)
    signal handler_udp_payload_data : STD_LOGIC_VECTOR(7 downto 0);
    signal handler_udp_payload_valid : STD_LOGIC;
    signal handler_udp_payload_start : STD_LOGIC;
    signal handler_udp_payload_end : STD_LOGIC;

    -- MAC parser data output (for IP and UDP parsers)
    signal mac_rx_dataout : STD_LOGIC_VECTOR(7 downto 0);

    -- Reset signal for handler (inverted reset)
    signal handler_rst_n : STD_LOGIC;
    
    -- Reset synchronized to RGMII clock domain
    signal reset_rgmii_sync1 : STD_LOGIC := '1';
    signal reset_rgmii_sync2 : STD_LOGIC := '1';
    signal reset_rgmii : STD_LOGIC;

    -- TX Reset synchronizer (RGMII -> clk_txd domain)
    signal reset_tx_sync1 : STD_LOGIC := '1';
    signal reset_tx_sync2 : STD_LOGIC := '1';
    signal reset_tx : STD_LOGIC := '1';

    -- ASYNC_REG attribute for TX reset synchronizer
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of reset_tx_sync1 : signal is "TRUE";
    attribute ASYNC_REG of reset_tx_sync2 : signal is "TRUE";

    -- Configuration
    constant MY_MAC_ADDR : STD_LOGIC_VECTOR(47 downto 0) := x"00_0A_35_01_FE_C0";
    constant MY_IP_ADDR  : STD_LOGIC_VECTOR(31 downto 0) := x"C0_A8_00_D4";  -- 192.168.0.212
    
    -- Async FIFO for handler signals (Gen2: now 125MHz -> 125MHz, same domain)
    -- Note: FIFO is still used for buffering but no longer crosses clock domains
    -- FIFO width: frame_valid(1) + ip_rx_req(1) + udp_rx_req(1) + frame_count(32) +
    --            mac_src(48) + mac_dest(48) + ethertype(16) + mac_rec_error(1) +
    --            ip_rx_end(1) + icmp_rx_req(1) + ip_addr_check_error(1) + ip_checksum_error(1) +
    --            upper_layer_data_length(16) + ip_total_data_length(16) + net_protocol(8) +
    --            ip_rec_source_addr(32) + ip_rec_destination_addr(32) +
    --            udp_src_port(16) + udp_dst_port(16) + udp_data_length(16) +
    --            udp_rec_data_valid(1) + udp_checksum_error(1) = 323 bits -> round to 384 for alignment
    constant HANDLER_FIFO_WIDTH : integer := 384;
    signal handler_fifo_wr_en : STD_LOGIC := '0';
    signal handler_fifo_wr_data : STD_LOGIC_VECTOR(HANDLER_FIFO_WIDTH-1 downto 0) := (others => '0');
    signal handler_fifo_wr_full : STD_LOGIC;
    signal handler_fifo_rd_en : STD_LOGIC := '0';
    signal handler_fifo_rd_data : STD_LOGIC_VECTOR(HANDLER_FIFO_WIDTH-1 downto 0);
    signal handler_fifo_rd_empty : STD_LOGIC;
    
    -- Unpacked signals from FIFO (200MHz domain)
    signal handler_frame_valid_fifo : STD_LOGIC := '0';
    signal handler_ip_rx_req_fifo : STD_LOGIC := '0';
    signal handler_udp_rx_req_fifo : STD_LOGIC := '0';
    signal handler_frame_count_fifo : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal handler_mac_src_fifo : STD_LOGIC_VECTOR(47 downto 0) := (others => '0');
    signal handler_mac_dest_fifo : STD_LOGIC_VECTOR(47 downto 0) := (others => '0');
    signal handler_ethertype_fifo : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_mac_rec_error_fifo : STD_LOGIC := '0';
    signal handler_ip_rx_end_fifo : STD_LOGIC := '0';
    signal handler_icmp_rx_req_fifo : STD_LOGIC := '0';
    signal handler_ip_addr_check_error_fifo : STD_LOGIC := '0';
    signal handler_ip_checksum_error_fifo : STD_LOGIC := '0';
    signal handler_upper_layer_data_length_fifo : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_ip_total_data_length_fifo : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_net_protocol_fifo : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal handler_ip_rec_source_addr_fifo : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal handler_ip_rec_destination_addr_fifo : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal handler_udp_src_port_fifo : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_udp_dst_port_fifo : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_udp_data_length_fifo : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal handler_udp_rec_data_valid_fifo : STD_LOGIC := '0';
    signal handler_udp_checksum_error_fifo : STD_LOGIC := '0';

    -- Previous handler signals for edge detection (125MHz domain)
    signal handler_frame_valid_prev : STD_LOGIC := '0';
    signal handler_ip_rx_req_prev : STD_LOGIC := '0';
    signal handler_ip_rx_end_prev_125 : STD_LOGIC := '0';
    signal frame_end_prev_125 : STD_LOGIC := '0';
    
    -- Simple frame control for MAC parser
    signal rx_dv_handler : STD_LOGIC := '0';
    signal frame_start_prev : STD_LOGIC := '0';
    signal frame_end_prev : STD_LOGIC := '0';

    -- =========================================================================
    -- BBO UDP TX Signals (125 MHz RGMII domain)
    -- =========================================================================
    signal tx_data : STD_LOGIC_VECTOR(7 downto 0);
    signal tx_valid : STD_LOGIC;
    signal packets_sent : STD_LOGIC_VECTOR(31 downto 0);

    -- TX debug signals (local copies for ILA access)
    signal tx_byte_count_int : STD_LOGIC_VECTOR(31 downto 0);
    signal tx_valid_seen_int : STD_LOGIC;
    signal last_tx_byte_int : STD_LOGIC_VECTOR(7 downto 0);

    -- BBO packet builder debug signals
    signal bbo_update_count_int : STD_LOGIC_VECTOR(31 downto 0);
    signal bbo_tx_state_int : STD_LOGIC_VECTOR(3 downto 0);
    signal bbo_max_state_int : STD_LOGIC_VECTOR(3 downto 0);
    signal bbo_reset_count_int : STD_LOGIC_VECTOR(15 downto 0);

    -- RGMII TX clock generation
    signal tx_pll_locked : STD_LOGIC;
    signal tx_pll_clkfb : STD_LOGIC;
    signal clk_txd_unbuf : STD_LOGIC;   -- 0° phase for TXD
    signal clk_txc_unbuf : STD_LOGIC;   -- 90° phase for TXC
    signal clk_txd : STD_LOGIC;         -- Buffered 0° clock
    signal clk_txc : STD_LOGIC;         -- Buffered 90° clock

    -- Modular UDP TX signals
    signal udp_tx_start : STD_LOGIC;
    signal udp_tx_busy : STD_LOGIC;
    signal payload_data : STD_LOGIC_VECTOR(7 downto 0);
    signal payload_rd : STD_LOGIC;

    -- Clock test counter (to verify clk_txd is running)
    signal clk_test_cnt : unsigned(27 downto 0) := (others => '0');
    signal tx_test_active : STD_LOGIC := '0';
    signal tx_test_byte_cnt : unsigned(7 downto 0) := (others => '0');

    -- FPGA Latency Timestamp: tx_cycle_counter_in is passed from simple_top.vhd
    -- This ensures T3 and T4 use the same 125 MHz cycle counter
    -- Note: rx_timestamp is already stable when bbo_update pulses, so multi-bit CDC is safe

begin

    -- Note: TX Cycle Counter is now passed in via tx_cycle_counter_in from simple_top.vhd
    -- This ensures T3 and T4 use the same 125 MHz cycle counter

    -- =========================================================================
    -- Clock Management (Gen2: 200 MHz IBUFDS removed)
    -- =========================================================================
    -- Gen2: Removed IBUFGDS and BUFG for 200 MHz clock
    -- The 200 MHz Ethernet oscillator clock was causing Gen2 PCIe to freeze
    -- All synchronization now uses RGMII 125 MHz clock

    -- =========================================================================
    -- Reset Synchronization (Gen2: now uses RGMII 125 MHz domain)
    -- =========================================================================
    process(rgmii1_rxc)
    begin
        if rising_edge(rgmii1_rxc) then
            reset_sync1 <= not reset_n;
            reset_sync2 <= reset_sync1;
        end if;
    end process;

    reset <= reset_sync2;
    handler_rst_n <= not reset;
    
    -- Gen2: reset_rgmii now directly uses reset (already in RGMII domain)
    reset_rgmii <= reset;

    -- TX clock generation with 90-degree phase shift for RGMII timing
    -- Generate 125 MHz with 0° phase for TXD and 90° phase for TXC
    -- This ensures proper setup/hold time at PHY regardless of PHY internal delay mode
    -- MMCM for TX clock generation (matches project 100)
    -- Input: 125 MHz (PHY RX clock)
    -- Output 0: 125 MHz @ 0° phase (for TXD/TXCTL ODDRs)
    -- Output 1: 125 MHz @ 90° phase (for TXC ODDR)
    tx_clk_mmcm : MMCME2_BASE
        generic map (
            BANDWIDTH => "OPTIMIZED",
            CLKIN1_PERIOD => 8.0,           -- 125 MHz input (8ns period)
            CLKFBOUT_MULT_F => 8.0,         -- VCO = 125 * 8 = 1000 MHz
            CLKFBOUT_PHASE => 0.0,
            CLKOUT0_DIVIDE_F => 8.0,        -- 1000 / 8 = 125 MHz
            CLKOUT0_PHASE => 0.0,           -- 0° phase for TXD
            CLKOUT0_DUTY_CYCLE => 0.5,
            CLKOUT1_DIVIDE => 8,            -- 1000 / 8 = 125 MHz
            CLKOUT1_PHASE => 90.0,          -- 90° phase for TXC (2ns delay)
            CLKOUT1_DUTY_CYCLE => 0.5,
            DIVCLK_DIVIDE => 1,
            REF_JITTER1 => 0.010,
            STARTUP_WAIT => FALSE
        )
        port map (
            CLKIN1 => rgmii1_rxc,           -- PHY RX clock (125 MHz)
            CLKFBIN => tx_pll_clkfb,
            CLKFBOUT => tx_pll_clkfb,
            CLKOUT0 => clk_txd_unbuf,       -- 0° for TXD
            CLKOUT1 => clk_txc_unbuf,       -- 90° for TXC
            CLKOUT2 => open,
            CLKOUT3 => open,
            CLKOUT4 => open,
            CLKOUT5 => open,
            CLKOUT0B => open,
            CLKOUT1B => open,
            CLKOUT2B => open,
            CLKOUT3B => open,
            LOCKED => tx_pll_locked,
            PWRDWN => '0',
            RST => reset
        );

    -- Buffer the clocks
    tx_clk_bufg : BUFG
        port map (
            I => clk_txd_unbuf,
            O => clk_txd
        );

    tx_clk_90_bufg : BUFG
        port map (
            I => clk_txc_unbuf,
            O => clk_txc
        );

    -- TX Reset synchronizer (wait for MMCM lock, synchronized to clk_txd domain)
    process(clk_txd)
    begin
        if rising_edge(clk_txd) then
            reset_tx_sync1 <= reset or (not tx_pll_locked);
            reset_tx_sync2 <= reset_tx_sync1;
            reset_tx <= reset_tx_sync2;
        end if;
    end process;

    -- =========================================================================
    -- RGMII Receiver
    -- =========================================================================
    rgmii_rx_inst : entity work.rgmii_rx
        port map (
            rgmii_rxc    => rgmii1_rxc,
            reset        => reset_rgmii,
            rgmii_rxd    => rgmii1_rxd,
            rgmii_rx_ctl => rgmii1_rxctl,
            rx_data      => rx_data,
            rx_valid     => rx_valid,
            rx_error     => rx_error,
            frame_start  => frame_start,
            frame_end    => frame_end
        );
    
    -- =========================================================================
    -- Frame control for MAC parser (rx_dv_handler)
    -- =========================================================================
    process(rgmii1_rxc, reset_rgmii)
    begin
        if reset_rgmii = '1' then
            rx_dv_handler <= '0';
            frame_start_prev <= '0';
            frame_end_prev <= '0';
        elsif rising_edge(rgmii1_rxc) then
            -- Detect frame_start rising edge
            if frame_start = '1' and frame_start_prev = '0' then
                rx_dv_handler <= '1';
            -- Detect frame_end rising edge
            elsif frame_end = '1' and frame_end_prev = '0' then
                rx_dv_handler <= '0';
            end if;
            
            frame_start_prev <= frame_start;
            frame_end_prev <= frame_end;
        end if;
    end process;

    -- =========================================================================
    -- MAC Parser (RGMII-compatible, runs on 125MHz RGMII clock)
    -- =========================================================================
    mac_parser_inst : entity work.mac_parser_rgmii
        generic map (
            CRC_BYPASS => false  -- CRC checking enabled (PHY filtering fixed via MDIO)
        )
        port map (
            clk                         => rgmii1_rxc,
            rst_n                       => handler_rst_n,

            -- Input from RGMII receiver
            rx_data                     => rx_data,
            rx_valid                    => rx_valid,
            frame_start                 => frame_start,
            frame_end                   => frame_end,

            -- Inputs from IP layer
            checksum_err                => handler_ip_checksum_error,
            ip_rx_end                   => handler_ip_rx_end,
            arp_rx_end                  => '0',

            -- Outputs
            ip_rx_req                   => handler_ip_rx_req,
            arp_rx_req                  => open,
            mac_rx_dataout              => mac_rx_dataout,
            mac_rec_error               => handler_mac_rec_error,
            mac_rx_destination_mac_addr => handler_mac_dest,
            mac_rx_source_mac_addr      => handler_mac_src,
            frame_valid                 => handler_frame_valid,
            dest_mac                    => open,
            src_mac                     => open,
            ethertype                   => handler_ethertype,
            frame_count                 => handler_frame_count,
            data_out                    => open,
            byte_counter                => open
        );

    -- =========================================================================
    -- IP Parser (RGMII-compatible, runs on 125MHz RGMII clock)
    -- =========================================================================
    ip_parser_rgmii_inst: entity work.ip_parser_rgmii
        port map (
            clk => rgmii1_rxc,
            rst_n => handler_rst_n,
            local_ip_addr => MY_IP_ADDR,
            local_mac_addr => MY_MAC_ADDR,
            mac_rx_destination_mac_addr => handler_mac_dest,
            ip_rx_data => mac_rx_dataout,
            ip_rx_req => handler_ip_rx_req,
            udp_rx_req => handler_udp_rx_req,
            icmp_rx_req => handler_icmp_rx_req,
            ip_addr_check_error => handler_ip_addr_check_error,
            upper_layer_data_length => handler_upper_layer_data_length,
            ip_total_data_length => handler_ip_total_data_length,
            net_protocol => handler_net_protocol,
            ip_rec_source_addr => handler_ip_rec_source_addr,
            ip_rec_destination_addr => handler_ip_rec_destination_addr,
            ip_rx_end => handler_ip_rx_end,
            ip_checksum_error => handler_ip_checksum_error
        );

    -- =========================================================================
    -- UDP Parser (125MHz RGMII domain)
    -- =========================================================================
    udp_parser_rgmii_inst: entity work.udp_parser_rgmii
        port map (
            clk => rgmii1_rxc,
            rst_n => handler_rst_n,
            -- Input from MAC parser (same data stream as IP parser)
            udp_rx_data => mac_rx_dataout,
            udp_rx_req => handler_udp_rx_req,
            -- IP layer status
            mac_rec_error => handler_mac_rec_error,
            net_protocol => handler_net_protocol,
            ip_rec_source_addr => handler_ip_rec_source_addr,
            ip_rec_destination_addr => handler_ip_rec_destination_addr,
            ip_checksum_error => handler_ip_checksum_error,
            ip_addr_check_error => handler_ip_addr_check_error,
            upper_layer_data_length => handler_upper_layer_data_length,
            -- UDP header fields
            udp_src_port => handler_udp_src_port,
            udp_dst_port => handler_udp_dst_port,
            udp_data_length => handler_udp_data_length,
            -- Payload streaming (for future ITCH parser)
            udp_payload_data => handler_udp_payload_data,
            udp_payload_valid => handler_udp_payload_valid,
            udp_payload_start => handler_udp_payload_start,
            udp_payload_end => handler_udp_payload_end,
            -- Status
            udp_rec_data_valid => handler_udp_rec_data_valid,
            udp_checksum_error_out => handler_udp_checksum_error
        );

    -- =========================================================================
    -- Async FIFO for Handler Signals (125MHz -> 200MHz)
    -- =========================================================================
    handler_fifo_inst: entity work.async_fifo
        generic map (
            DATA_WIDTH => HANDLER_FIFO_WIDTH,
            FIFO_DEPTH => 2048
        )
        port map (
            wr_clk => rgmii1_rxc,
            wr_rst => reset_rgmii,
            wr_en => handler_fifo_wr_en,
            wr_data => handler_fifo_wr_data,
            wr_full => handler_fifo_wr_full,
            rd_clk => rgmii1_rxc,  -- Gen2: same clock domain (was sys_clk_200mhz_bufg)
            rd_rst => reset_rgmii,
            rd_en => handler_fifo_rd_en,
            rd_data => handler_fifo_rd_data,
            rd_empty => handler_fifo_rd_empty
        );
    
    -- =========================================================================
    -- FIFO Write Logic (125MHz domain)
    -- Write on frame_valid pulse (successful frame) OR ip_rx_req rising edge (IP frame detected)
    -- This ensures activity is visible even if frames don't complete successfully
    -- =========================================================================
    process(rgmii1_rxc, reset_rgmii)
    begin
        if reset_rgmii = '1' then
            handler_frame_valid_prev <= '0';
            handler_ip_rx_req_prev <= '0';
            handler_ip_rx_end_prev_125 <= '0';
            frame_end_prev_125 <= '0';
            handler_fifo_wr_en <= '0';
            handler_fifo_wr_data <= (others => '0');
        elsif rising_edge(rgmii1_rxc) then
            handler_fifo_wr_en <= '0';  -- Default: no write
            handler_ip_rx_end_prev_125 <= handler_ip_rx_end;
            frame_end_prev_125 <= frame_end;
            
            -- Write on frame_valid pulse (successful frame completion)
            -- OR on ip_rx_end pulse (IP frame parsed completely, header fields available)
            -- OR on frame_end pulse (any frame received, for diagnostics - may have incomplete IP data)
            -- Note: Don't write on ip_rx_req rising edge - IP header not parsed yet
            if (handler_frame_valid = '1' and handler_frame_valid_prev = '0') or
               (handler_ip_rx_end = '1' and handler_ip_rx_end_prev_125 = '0') or
               (frame_end = '1' and frame_end_prev_125 = '0') then
                -- Pack all signals into FIFO data
                -- Bit assignments:
                --   0: frame_valid
                --   1: ip_rx_req
                --   2: udp_rx_req
                --   34 downto 3: frame_count (32 bits)
                --   82 downto 35: mac_src (48 bits)
                --   130 downto 83: mac_dest (48 bits)
                --   146 downto 131: ethertype (16 bits)
                --   147: mac_rec_error
                --   148: ip_rx_end
                --   149: icmp_rx_req
                --   150: ip_addr_check_error
                --   151: ip_checksum_error
                --   167 downto 152: upper_layer_data_length (16 bits)
                --   183 downto 168: ip_total_data_length (16 bits)
                --   191 downto 184: net_protocol (8 bits)
                --   223 downto 192: ip_rec_source_addr (32 bits)
                --   255 downto 224: ip_rec_destination_addr (32 bits)
                --   271 downto 256: udp_src_port (16 bits)
                --   287 downto 272: udp_dst_port (16 bits)
                --   303 downto 288: udp_data_length (16 bits)
                --   304: udp_rec_data_valid
                --   305: udp_checksum_error
                handler_fifo_wr_data(0) <= handler_frame_valid;
                handler_fifo_wr_data(1) <= handler_ip_rx_req;
                handler_fifo_wr_data(2) <= handler_udp_rx_req;
                handler_fifo_wr_data(34 downto 3) <= handler_frame_count;
                handler_fifo_wr_data(82 downto 35) <= handler_mac_src;
                handler_fifo_wr_data(130 downto 83) <= handler_mac_dest;
                handler_fifo_wr_data(146 downto 131) <= handler_ethertype;
                handler_fifo_wr_data(147) <= handler_mac_rec_error;
                handler_fifo_wr_data(148) <= handler_ip_rx_end;
                handler_fifo_wr_data(149) <= handler_icmp_rx_req;
                handler_fifo_wr_data(150) <= handler_ip_addr_check_error;
                handler_fifo_wr_data(151) <= handler_ip_checksum_error;
                handler_fifo_wr_data(167 downto 152) <= handler_upper_layer_data_length;
                handler_fifo_wr_data(183 downto 168) <= handler_ip_total_data_length;
                handler_fifo_wr_data(191 downto 184) <= handler_net_protocol;
                handler_fifo_wr_data(223 downto 192) <= handler_ip_rec_source_addr;
                handler_fifo_wr_data(255 downto 224) <= handler_ip_rec_destination_addr;
                handler_fifo_wr_data(271 downto 256) <= handler_udp_src_port;
                handler_fifo_wr_data(287 downto 272) <= handler_udp_dst_port;
                handler_fifo_wr_data(303 downto 288) <= handler_udp_data_length;
                handler_fifo_wr_data(304) <= handler_udp_rec_data_valid;
                handler_fifo_wr_data(305) <= handler_udp_checksum_error;
                
                if handler_fifo_wr_full = '0' then
                    handler_fifo_wr_en <= '1';
                else
                    handler_fifo_wr_en <= '0';
                end if;
            end if;

            handler_frame_valid_prev <= handler_frame_valid;
            handler_ip_rx_req_prev <= handler_ip_rx_req;
        end if;
    end process;
    
        -- =========================================================================
    -- FIFO Read Logic (Gen2: 125MHz domain) - Output single-cycle pulses
    -- =========================================================================
    process(rgmii1_rxc, reset_rgmii)
        variable rd_en_prev : STD_LOGIC := '0';
    begin
        if reset_rgmii = '1' then
            handler_fifo_rd_en <= '0';
            handler_frame_valid_fifo <= '0';
            handler_ip_rx_req_fifo <= '0';
            handler_udp_rx_req_fifo <= '0';
            handler_frame_count_fifo <= (others => '0');
            handler_mac_src_fifo <= (others => '0');
            handler_mac_dest_fifo <= (others => '0');
            handler_ethertype_fifo <= (others => '0');
            handler_mac_rec_error_fifo <= '0';
            handler_ip_rx_end_fifo <= '0';
            handler_icmp_rx_req_fifo <= '0';
            handler_ip_addr_check_error_fifo <= '0';
            handler_ip_checksum_error_fifo <= '0';
            handler_upper_layer_data_length_fifo <= (others => '0');
            handler_ip_total_data_length_fifo <= (others => '0');
            handler_net_protocol_fifo <= (others => '0');
            handler_ip_rec_source_addr_fifo <= (others => '0');
            handler_ip_rec_destination_addr_fifo <= (others => '0');
            rd_en_prev := '0';
        elsif rising_edge(rgmii1_rxc) then
            -- Default: clear single-cycle pulse signals
            handler_fifo_rd_en <= '0';
            handler_frame_valid_fifo <= '0';
            handler_ip_rx_req_fifo <= '0';
            handler_udp_rx_req_fifo <= '0';

            -- Continuously read from FIFO when not empty
            if handler_fifo_rd_empty = '0' and rd_en_prev = '0' then
                handler_fifo_rd_en <= '1';
            end if;

            -- FIFO read data is available one cycle after rd_en
            if rd_en_prev = '1' then
                -- Unpack ALL signals from FIFO (single-cycle pulses)
                handler_frame_valid_fifo <= handler_fifo_rd_data(0);
                handler_ip_rx_req_fifo <= handler_fifo_rd_data(1);
                handler_udp_rx_req_fifo <= handler_fifo_rd_data(2);
                handler_frame_count_fifo <= handler_fifo_rd_data(34 downto 3);
                handler_mac_src_fifo <= handler_fifo_rd_data(82 downto 35);
                handler_mac_dest_fifo <= handler_fifo_rd_data(130 downto 83);
                handler_ethertype_fifo <= handler_fifo_rd_data(146 downto 131);
                handler_mac_rec_error_fifo <= handler_fifo_rd_data(147);
                handler_ip_rx_end_fifo <= handler_fifo_rd_data(148);
                handler_icmp_rx_req_fifo <= handler_fifo_rd_data(149);
                handler_ip_addr_check_error_fifo <= handler_fifo_rd_data(150);
                handler_ip_checksum_error_fifo <= handler_fifo_rd_data(151);
                handler_upper_layer_data_length_fifo <= handler_fifo_rd_data(167 downto 152);
                handler_ip_total_data_length_fifo <= handler_fifo_rd_data(183 downto 168);
                handler_net_protocol_fifo <= handler_fifo_rd_data(191 downto 184);
                handler_ip_rec_source_addr_fifo <= handler_fifo_rd_data(223 downto 192);
                handler_ip_rec_destination_addr_fifo <= handler_fifo_rd_data(255 downto 224);
                handler_udp_src_port_fifo <= handler_fifo_rd_data(271 downto 256);
                handler_udp_dst_port_fifo <= handler_fifo_rd_data(287 downto 272);
                handler_udp_data_length_fifo <= handler_fifo_rd_data(303 downto 288);
                handler_udp_rec_data_valid_fifo <= handler_fifo_rd_data(304);
                handler_udp_checksum_error_fifo <= handler_fifo_rd_data(305);
            end if;
            
            rd_en_prev := handler_fifo_rd_en;
        end if;
    end process;


    
    -- =========================================================================
    -- Output assignments (Gen2: all in 125MHz RGMII domain via FIFO buffering)
    -- =========================================================================
    frame_valid <= handler_frame_valid_fifo;
    ip_rx_req <= handler_ip_rx_req_fifo;
    udp_rx_req <= handler_udp_rx_req_fifo;
    frame_count <= handler_frame_count_fifo;
    mac_src <= handler_mac_src_fifo;
    mac_dest <= handler_mac_dest_fifo;
    ethertype <= handler_ethertype_fifo;
    mac_rec_error <= handler_mac_rec_error_fifo;
    ip_rx_end <= handler_ip_rx_end_fifo;
    icmp_rx_req <= handler_icmp_rx_req_fifo;
    ip_addr_check_error <= handler_ip_addr_check_error_fifo;
    ip_checksum_error <= handler_ip_checksum_error_fifo;
    upper_layer_data_length <= handler_upper_layer_data_length_fifo;
    ip_total_data_length <= handler_ip_total_data_length_fifo;
    net_protocol <= handler_net_protocol_fifo;
    ip_rec_source_addr <= handler_ip_rec_source_addr_fifo;
    ip_rec_destination_addr <= handler_ip_rec_destination_addr_fifo;

    -- UDP outputs (Gen2: 125MHz RGMII domain via FIFO buffering)
    udp_src_port <= handler_udp_src_port_fifo;
    udp_dst_port <= handler_udp_dst_port_fifo;
    udp_data_length <= handler_udp_data_length_fifo;
    udp_rec_data_valid <= handler_udp_rec_data_valid_fifo;
    udp_checksum_error <= handler_udp_checksum_error_fifo;

    -- UDP payload streaming outputs (125MHz RGMII domain - NOT synchronized)
    rgmii_rxc_out <= rgmii1_rxc;  -- Pass through RGMII RX clock for upper layer sync
    clk_txd_out <= clk_txd;       -- Pass through TX clock (MMCM) for BBO FIFO sync
    udp_payload_data <= handler_udp_payload_data;
    udp_payload_valid <= handler_udp_payload_valid;
    udp_payload_start <= handler_udp_payload_start;
    udp_payload_end <= handler_udp_payload_end;

    -- Diagnostic outputs
    fifo_empty <= handler_fifo_rd_empty;
    fifo_full <= handler_fifo_wr_full;
    -- Diagnostic outputs
    rx_valid_out <= rx_valid;
    frame_start_out <= frame_start;
    frame_end_out <= frame_end;
    frame_valid_mac_out <= handler_frame_valid;

    -- =========================================================================
    -- BBO UDP TX DISABLED - Simplifying design for PCIe-only output
    -- Keep clock infrastructure but disable RGMII TX path
    -- =========================================================================

    -- Tie TX data signals to idle (no UDP TX)
    tx_data <= (others => '0');
    tx_valid <= '0';
    packets_sent <= (others => '0');

    -- RGMII TXC - DDR output of 125 MHz clock (keep clock running for PHY)
    -- Use 90° phase-shifted clock for proper RGMII timing
    txc_idle_oddr: ODDR
        generic map (
           DDR_CLK_EDGE => "SAME_EDGE",
           INIT => '0',
           SRTYPE => "ASYNC"
        )
        port map (
            Q  => rgmii1_txc,
            C  => clk_txc,  -- 90-degree phase shift for center alignment
            CE => '1',
            D1 => '1',
            D2 => '0',
            R  => '0',   -- No reset - clock always runs
            S  => '0'
        );

    -- RGMII TXCTL - DDR output (idle = 0)
    txctl_idle_oddr: ODDR
        generic map (
           DDR_CLK_EDGE => "SAME_EDGE",
           INIT => '0',
           SRTYPE => "ASYNC"
        )
        port map (
            Q  => rgmii1_txctl,
            C  => clk_txd,
            CE => '1',
            D1 => '0',  -- No valid data
            D2 => '0',  -- No error
            R  => reset_tx,
            S  => '0'
        );

    -- RGMII TXD[3:0] - DDR outputs (idle = 0)
    gen_txd_idle: for i in 0 to 3 generate
        txd_idle_oddr: ODDR
            generic map (
               DDR_CLK_EDGE => "SAME_EDGE",
               INIT => '0',
               SRTYPE => "ASYNC"
            )
            port map (
                Q  => rgmii1_txd(i),
                C  => clk_txd,
                CE => '1',
                D1 => '0',
                D2 => '0',
                R  => reset_tx,
                S  => '0'
            );
    end generate;

    -- Debug outputs: cleared since TX is disabled
    bbo_update_count_int <= (others => '0');
    bbo_tx_state_int <= (others => '0');
    bbo_max_state_int <= (others => '0');
    bbo_reset_count_int <= (others => '0');
    tx_byte_count_int <= (others => '0');
    tx_valid_seen_int <= '0';
    last_tx_byte_int <= (others => '0');

    -- Connect internal debug signals to output ports
    tx_byte_count <= tx_byte_count_int;
    tx_valid_seen <= tx_valid_seen_int;
    last_tx_byte <= last_tx_byte_int;

    -- =========================================================================
    -- TX Diagnostic Output Assignments
    -- =========================================================================
    tx_valid_out <= tx_valid;
    tx_packets_sent <= packets_sent;
    tx_reset_out <= reset_tx;

    -- BBO Packet Builder Debug Outputs
    bbo_update_count <= bbo_update_count_int;
    bbo_tx_state <= bbo_tx_state_int;
    bbo_max_state <= bbo_max_state_int;
    bbo_reset_count <= bbo_reset_count_int;

    -- =========================================================================
    -- ILA Debug Core for TX Path Analysis (DISABLED - causes timing violations)
    -- =========================================================================
    -- Uncomment to enable ILA debugging (may require timing constraint adjustments)
    -- ila_tx_debug : component ila_0
    --     port map (
    --         clk => clk_txd,
    --         probe0(7 downto 0) => tx_data,
    --         probe0(8) => tx_valid,
    --         probe0(9) => reset_tx,
    --         probe0(10) => tx_pll_locked,
    --         probe0(14 downto 11) => tx_byte_count_int(3 downto 0),
    --         probe0(15) => '0'
    --     );

end Behavioral;
