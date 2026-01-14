----------------------------------------------------------------------------------
-- Order Book Top - Integrated ITCH to PCIe BBO Streaming (SIMPLIFIED)
-- Project 23: Full integration of Order Book (Project 20) with PCIe (Project 22)
--
-- SIMPLIFIED VERSION: Only 2 clock domains (ETH 125 MHz, PCIe 125/250 MHz)
-- Trading logic runs on PCIe clock to eliminate CDC FIFO complexity.
--
-- Data Flow:
--   Ethernet (1Gbps) → ITCH Parser → CDC FIFO → Order Book → BBO → PCIe (to Host)
--
-- Clock Domains:
--   - rgmii_rxc (125 MHz): Ethernet RX, ITCH parsing
--   - axi_aclk (125/250 MHz): Trading logic, Order Book, PCIe/XDMA
--
-- Gen2 Migration: Removed 200 MHz Ethernet oscillator clock.
--   The 200 MHz clock was causing Gen2 PCIe to freeze (AX7203 board issue).
--   PHY reset now uses axi_aclk instead.
--
-- Target: AX7203 (XC7A200T-2FBG484I)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity order_book_top is
    Port (
        -- System Reset (active LOW)
        reset_n           : in  STD_LOGIC;

        -- RGMII Ethernet Port 1 (ITCH feed input)
        rgmii1_rxc        : in  STD_LOGIC;
        rgmii1_rxctl      : in  STD_LOGIC;
        rgmii1_rxd        : in  STD_LOGIC_VECTOR(3 downto 0);
        rgmii1_txc        : out STD_LOGIC;
        rgmii1_txctl      : out STD_LOGIC;
        rgmii1_txd        : out STD_LOGIC_VECTOR(3 downto 0);

        -- PHY Control (directly managed - no MDIO in this version)
        e1_reset          : out STD_LOGIC;

        -- PCIe Interface
        pcie_mgt_rxn      : in  STD_LOGIC_VECTOR(3 downto 0);
        pcie_mgt_rxp      : in  STD_LOGIC_VECTOR(3 downto 0);
        pcie_mgt_txn      : out STD_LOGIC_VECTOR(3 downto 0);
        pcie_mgt_txp      : out STD_LOGIC_VECTOR(3 downto 0);
        pcie_refclk_clk_n : in  STD_LOGIC_VECTOR(0 downto 0);
        pcie_refclk_clk_p : in  STD_LOGIC_VECTOR(0 downto 0);
        pcie_perst_n      : in  STD_LOGIC;

        -- Status LEDs
        led               : out STD_LOGIC_VECTOR(3 downto 0);

        -- Debug Button (unused but keep port for constraints)
        debug_btn         : in  STD_LOGIC
    );
end order_book_top;

architecture Behavioral of order_book_top is

    ---------------------------------------------------------------------------
    -- Internal Signals
    ---------------------------------------------------------------------------

    -- Clock signals (Gen2: no 200 MHz clock, use axi_aclk for everything)
    signal axi_aclk       : STD_LOGIC;
    signal axi_aresetn    : STD_LOGIC;
    signal rgmii_rxc_buf  : STD_LOGIC;
    signal clk_txd        : STD_LOGIC;

    -- Reset signals
    signal reset          : STD_LOGIC;
    signal rst_trading    : STD_LOGIC;

    -- Soft reset for AXI domain (synchronized from user reset button)
    signal reset_axi_sync1 : STD_LOGIC := '1';
    signal reset_axi_sync2 : STD_LOGIC := '1';
    signal axi_aresetn_combined : STD_LOGIC;

    -- Ethernet signals
    signal udp_payload_data  : STD_LOGIC_VECTOR(7 downto 0);
    signal udp_payload_valid : STD_LOGIC;
    signal udp_payload_start : STD_LOGIC;
    signal udp_payload_end   : STD_LOGIC;
    signal udp_src_port      : STD_LOGIC_VECTOR(15 downto 0);
    signal udp_dst_port      : STD_LOGIC_VECTOR(15 downto 0);
    signal ip_src_addr       : STD_LOGIC_VECTOR(31 downto 0);
    signal frame_valid       : STD_LOGIC;
    signal frame_count       : STD_LOGIC_VECTOR(31 downto 0);

    -- Additional ethernet signals (most not used, just need for port mapping)
    signal fifo_empty        : STD_LOGIC;

    -- BBO signals from trading_top
    signal bbo_update    : STD_LOGIC;
    signal bbo_symbol    : STD_LOGIC_VECTOR(63 downto 0);
    signal bbo_bid_price : UNSIGNED(31 downto 0);
    signal bbo_bid_size  : UNSIGNED(31 downto 0);
    signal bbo_ask_price : UNSIGNED(31 downto 0);
    signal bbo_ask_size  : UNSIGNED(31 downto 0);
    signal bbo_spread    : UNSIGNED(31 downto 0);
    signal ts_t1         : STD_LOGIC_VECTOR(31 downto 0);
    signal ts_t2         : STD_LOGIC_VECTOR(31 downto 0);

    -- PCIe/AXI-Stream signals
    signal c2h_tdata     : STD_LOGIC_VECTOR(63 downto 0);
    signal c2h_tkeep     : STD_LOGIC_VECTOR(7 downto 0);
    signal c2h_tvalid    : STD_LOGIC;
    signal c2h_tready    : STD_LOGIC;
    signal c2h_tlast     : STD_LOGIC;
    signal pcie_link_up  : STD_LOGIC;

    -- Statistics
    signal itch_msg_count    : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_msg_count      : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_bbo_count      : STD_LOGIC_VECTOR(31 downto 0);

    -- LED signals
    signal led_streaming  : STD_LOGIC;
    signal led_overflow   : STD_LOGIC;

    -- PCIe debug signals (minimal set)
    signal pcie_axis_tx_count : STD_LOGIC_VECTOR(31 downto 0);
    signal pcie_stream_ready  : STD_LOGIC;
    signal pcie_tready_now    : STD_LOGIC;

    -- Software reset from AXI-Lite GPIO (via /dev/xdma0_user)
    signal soft_reset_reg     : STD_LOGIC_VECTOR(31 downto 0);
    signal soft_reset         : STD_LOGIC;
    signal pcie_axi_state     : STD_LOGIC_VECTOR(3 downto 0);

    -- Heartbeat counter
    signal heartbeat_counter : unsigned(26 downto 0) := (others => '0');

    -- PHY reset counter (hold reset for some cycles after power-on)
    signal phy_reset_counter : unsigned(23 downto 0) := (others => '0');
    signal phy_reset_done    : STD_LOGIC := '0';

    -- ILA Debug signals (DISABLED - not needed in production)
    -- Uncomment these if re-enabling ILA debug core
    signal dbg_bbo_state       : STD_LOGIC_VECTOR(4 downto 0);
    signal dbg_bbo_spread_reg  : STD_LOGIC_VECTOR(31 downto 0);
    signal dbg_arbiter_symbol  : STD_LOGIC_VECTOR(2 downto 0);
    signal dbg_arbiter_counter : STD_LOGIC_VECTOR(9 downto 0);
    signal dbg_ready_vec_0     : STD_LOGIC;
    signal dbg_bbo_update_vec_0: STD_LOGIC;

begin

    ---------------------------------------------------------------------------
    -- Reset Logic
    ---------------------------------------------------------------------------
    reset <= not reset_n;
    rst_trading <= reset;

    ---------------------------------------------------------------------------
    -- PHY Reset Logic (hold for ~100ms using axi_aclk)
    -- Gen2: Uses axi_aclk (125/250 MHz) instead of 200 MHz oscillator
    -- At 125 MHz: 0xFFFFFF = 16.7M cycles = 134 ms (sufficient for PHY reset)
    -- At 250 MHz: 0xFFFFFF = 16.7M cycles = 67 ms (still sufficient)
    ---------------------------------------------------------------------------
    process(axi_aclk)
    begin
        if rising_edge(axi_aclk) then
            if axi_aresetn = '0' then
                phy_reset_counter <= (others => '0');
                phy_reset_done <= '0';
            elsif phy_reset_done = '0' then
                if phy_reset_counter = x"FFFFFF" then
                    phy_reset_done <= '1';
                else
                    phy_reset_counter <= phy_reset_counter + 1;
                end if;
            end if;
        end if;
    end process;

    -- PHY reset active LOW - hold low until counter expires
    e1_reset <= phy_reset_done;

    ---------------------------------------------------------------------------
    -- AXI Domain Soft Reset (synchronize user reset to AXI clock)
    -- This allows the reset button to also reset the PCIe BBO logic
    ---------------------------------------------------------------------------
    process(axi_aclk)
    begin
        if rising_edge(axi_aclk) then
            reset_axi_sync1 <= reset;
            reset_axi_sync2 <= reset_axi_sync1;
        end if;
    end process;

    -- Combined reset: either XDMA reset OR user button reset
    -- Active LOW: '0' = reset, '1' = running
    axi_aresetn_combined <= axi_aresetn and (not reset_axi_sync2);

    ---------------------------------------------------------------------------
    -- Ethernet Top Instance
    -- Gen2: No 200 MHz clock - removed sys_clk_p/n ports
    ---------------------------------------------------------------------------
    ethernet_inst : entity work.ethernet_top
        port map (
            -- Reset
            reset_n           => reset_n,
            -- RGMII interface
            rgmii1_rxc        => rgmii1_rxc,
            rgmii1_rxctl      => rgmii1_rxctl,
            rgmii1_rxd        => rgmii1_rxd,
            rgmii1_txc        => rgmii1_txc,
            rgmii1_txctl      => rgmii1_txctl,
            rgmii1_txd        => rgmii1_txd,
            -- BBO UDP TX Interface (enabled for testing)
            bbo_update        => bbo_update,
            bbo_symbol        => bbo_symbol,
            bbo_bid_price     => std_logic_vector(bbo_bid_price),
            bbo_bid_size      => std_logic_vector(bbo_bid_size),
            bbo_ask_price     => std_logic_vector(bbo_ask_price),
            bbo_ask_size      => std_logic_vector(bbo_ask_size),
            bbo_spread        => std_logic_vector(bbo_spread),
            bbo_ts_t1         => ts_t1,
            bbo_ts_t2         => ts_t2,
            bbo_ts_t3         => (others => '0'),  -- T3 generated inside ethernet_top
            tx_cycle_counter_in => (others => '0'),
            -- Status outputs (unused - tie off)
            frame_valid       => frame_valid,
            ip_rx_req         => open,
            udp_rx_req        => open,
            frame_count       => frame_count,
            mac_src           => open,
            mac_dest          => open,
            ethertype         => open,
            mac_rec_error     => open,
            ip_rx_end         => open,
            icmp_rx_req       => open,
            ip_addr_check_error => open,
            ip_checksum_error => open,
            upper_layer_data_length => open,
            ip_total_data_length => open,
            net_protocol      => open,
            ip_rec_source_addr => ip_src_addr,
            ip_rec_destination_addr => open,
            -- UDP header fields
            udp_src_port      => udp_src_port,
            udp_dst_port      => udp_dst_port,
            udp_data_length   => open,
            udp_rec_data_valid => open,
            udp_checksum_error => open,
            -- UDP payload streaming (125MHz RGMII domain)
            rgmii_rxc_out     => rgmii_rxc_buf,
            clk_txd_out       => clk_txd,
            udp_payload_data  => udp_payload_data,
            udp_payload_valid => udp_payload_valid,
            udp_payload_start => udp_payload_start,
            udp_payload_end   => udp_payload_end,
            -- System clock output (Gen2: removed, no longer used)
            -- Diagnostic outputs (unused - tie off)
            fifo_empty        => fifo_empty,
            fifo_full         => open,
            rx_valid_out      => open,
            frame_start_out   => open,
            frame_end_out     => open,
            frame_valid_mac_out => open,
            tx_valid_out      => open,
            tx_packets_sent   => open,
            tx_reset_out      => open,
            tx_byte_count     => open,
            tx_valid_seen     => open,
            last_tx_byte      => open,
            bbo_update_count  => open,
            bbo_tx_state      => open,
            bbo_max_state     => open,
            bbo_reset_count   => open
        );

    ---------------------------------------------------------------------------
    -- Trading Top Instance (ITCH + Order Book + BBO)
    -- Now uses axi_aclk for order book (same clock as PCIe, eliminating CDC)
    ---------------------------------------------------------------------------
    trading_inst : entity work.trading_top
        port map (
            rgmii_rxc         => rgmii_rxc_buf,
            ob_clk            => axi_aclk,  -- Order book runs on PCIe clock
            ob_rst            => not axi_aresetn_combined,  -- Active high reset
            soft_reset        => soft_reset,
            reset_n           => reset_n,
            udp_payload_data  => udp_payload_data,
            udp_payload_valid => udp_payload_valid,
            udp_payload_start => udp_payload_start,
            udp_payload_end   => udp_payload_end,
            udp_src_port      => udp_src_port,
            udp_dst_port      => udp_dst_port,
            ip_src_addr       => ip_src_addr,
            bbo_update        => bbo_update,
            bbo_symbol        => bbo_symbol,
            bbo_bid_price     => bbo_bid_price,
            bbo_bid_size      => bbo_bid_size,
            bbo_ask_price     => bbo_ask_price,
            bbo_ask_size      => bbo_ask_size,
            bbo_spread        => bbo_spread,
            bbo_ready         => pcie_stream_ready,  -- Backpressure from bbo_axi_stream
            itch_msg_count    => itch_msg_count,
            ob_msg_count      => ob_msg_count,
            ob_bbo_count      => ob_bbo_count,
            ts_t1_out         => ts_t1,
            ts_t2_out         => ts_t2,
            -- Debug outputs for ILA
            dbg_bbo_state       => dbg_bbo_state,
            dbg_bbo_spread_reg  => dbg_bbo_spread_reg,
            dbg_arbiter_symbol  => dbg_arbiter_symbol,
            dbg_arbiter_counter => dbg_arbiter_counter,
            dbg_ready_vec_0     => dbg_ready_vec_0,
            dbg_bbo_update_vec_0 => dbg_bbo_update_vec_0
        );

    ---------------------------------------------------------------------------
    -- PCIe BBO Bridge Instance (SIMPLIFIED - same clock domain as trading)
    ---------------------------------------------------------------------------
    pcie_bbo_inst : entity work.pcie_bbo_top
        generic map (
            C_AXI_DATA_WIDTH      => 64,
            C_AXI_LITE_DATA_WIDTH => 32,
            C_AXI_LITE_ADDR_WIDTH => 6
        )
        port map (
            -- BBO input from order book (same clock domain as axi_aclk)
            bbo_update     => bbo_update,
            bbo_symbol     => bbo_symbol,
            bbo_bid_price  => std_logic_vector(bbo_bid_price),
            bbo_bid_size   => std_logic_vector(bbo_bid_size),
            bbo_ask_price  => std_logic_vector(bbo_ask_price),
            bbo_ask_size   => std_logic_vector(bbo_ask_size),
            bbo_spread     => std_logic_vector(bbo_spread),
            ts_t1          => ts_t1,
            ts_t2          => ts_t2,
            ts_t3          => (others => '0'),  -- T3 generated later
            ts_t4          => (others => '0'),  -- T4 generated later
            -- AXI clock domain
            axi_aclk       => axi_aclk,
            axi_aresetn    => axi_aresetn_combined,
            -- AXI-Stream to XDMA
            m_axis_tdata   => c2h_tdata,
            m_axis_tkeep   => c2h_tkeep,
            m_axis_tvalid  => c2h_tvalid,
            m_axis_tready  => c2h_tready,
            m_axis_tlast   => c2h_tlast,
            -- AXI-Lite not connected (directly to block design)
            S_AXI_AWADDR   => (others => '0'),
            S_AXI_AWVALID  => '0',
            S_AXI_AWREADY  => open,
            S_AXI_WDATA    => (others => '0'),
            S_AXI_WSTRB    => (others => '0'),
            S_AXI_WVALID   => '0',
            S_AXI_WREADY   => open,
            S_AXI_BRESP    => open,
            S_AXI_BVALID   => open,
            S_AXI_BREADY   => '0',
            S_AXI_ARADDR   => (others => '0'),
            S_AXI_ARVALID  => '0',
            S_AXI_ARREADY  => open,
            S_AXI_RDATA    => open,
            S_AXI_RRESP    => open,
            S_AXI_RVALID   => open,
            S_AXI_RREADY   => '0',
            -- Status LEDs
            led_link_up    => open,
            led_streaming  => led_streaming,
            led_overflow   => led_overflow,
            -- Debug
            dbg_bbo_count     => pcie_axis_tx_count,
            dbg_tready_seen   => open,
            dbg_stream_ready  => pcie_stream_ready,
            dbg_tready_now    => pcie_tready_now,
            dbg_tvalid_now    => open,
            dbg_axi_state     => pcie_axi_state
        );

    ---------------------------------------------------------------------------
    -- PCIe System Instance (XDMA Block Design)
    ---------------------------------------------------------------------------
    pcie_system_inst : entity work.pcie_system_wrapper
        port map (
            pcie_mgt_rxn      => pcie_mgt_rxn,
            pcie_mgt_rxp      => pcie_mgt_rxp,
            pcie_mgt_txn      => pcie_mgt_txn,
            pcie_mgt_txp      => pcie_mgt_txp,
            pcie_refclk_clk_n => pcie_refclk_clk_n,
            pcie_refclk_clk_p => pcie_refclk_clk_p,
            reset_rtl_0       => pcie_perst_n,
            axi_aclk          => axi_aclk,
            axi_aresetn       => axi_aresetn,
            s_axis_c2h_tdata  => c2h_tdata,
            s_axis_c2h_tkeep  => c2h_tkeep,
            s_axis_c2h_tlast  => c2h_tlast,
            s_axis_c2h_tready => c2h_tready,
            s_axis_c2h_tvalid => c2h_tvalid,
            soft_reset_reg    => soft_reset_reg,
            user_lnk_up       => pcie_link_up
        );

    -- Extract soft_reset bit from control register
    soft_reset <= soft_reset_reg(0);

    ---------------------------------------------------------------------------
    -- LED Status Indicators
    -- LED active LOW on AX7203
    ---------------------------------------------------------------------------
    process(axi_aclk)
    begin
        if rising_edge(axi_aclk) then
            -- Heartbeat (toggles at ~1 Hz at 125 MHz)
            heartbeat_counter <= heartbeat_counter + 1;
        end if;
    end process;

    -- LED assignments (active LOW)
    led(0) <= not pcie_link_up;           -- PCIe Link Up
    led(1) <= not phy_reset_done;         -- PHY Reset Complete
    led(2) <= not led_streaming;          -- BBO Streaming Active
    led(3) <= not heartbeat_counter(26);  -- Heartbeat

    ---------------------------------------------------------------------------
    -- ILA Debug Core for Spread Timing Analysis (DISABLED - not needed in production)
    -- To re-enable: uncomment the instantiation below and regenerate ila_spread_debug IP
    ---------------------------------------------------------------------------
    -- ila_spread_debug_inst : entity work.ila_spread_debug
    --     port map (
    --         clk     => axi_aclk,
    --         probe0  => dbg_bbo_state,
    --         probe1  => dbg_bbo_spread_reg,
    --         probe2  => dbg_arbiter_symbol,
    --         probe3  => dbg_arbiter_counter,
    --         probe4(0) => dbg_ready_vec_0,
    --         probe5(0) => dbg_bbo_update_vec_0,
    --         probe6(0) => bbo_update,
    --         probe7  => std_logic_vector(bbo_spread)
    --     );

end Behavioral;
