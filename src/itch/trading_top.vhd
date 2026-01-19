----------------------------------------------------------------------------------
-- Trading Top-Level Module (SIMPLIFIED)
-- Purpose: Integrates ITCH parser and order book management
--          Pure trading logic layer - no board I/O, no UART debug
--
-- Clock Domains:
--   - rgmii_rxc (125 MHz): Ethernet RX, ITCH parsing
--   - ob_clk (125/250 MHz): Order Book, BBO output (same as PCIe clock)
--
-- Data Flow:
--   UDP payload (125 MHz) → ITCH Parser → CDC FIFO → Order Book (ob_clk) → BBO
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.itch_msg_pkg.all;
use work.order_book_pkg.all;

entity trading_top is
    Port (
        -- Clocks
        rgmii_rxc         : in  STD_LOGIC;  -- 125 MHz RGMII RX clock (ITCH parsing)
        ob_clk            : in  STD_LOGIC;  -- Order book clock (same as PCIe axi_aclk)
        ob_rst            : in  STD_LOGIC;  -- Order book reset (active high)

        -- Software reset (via AXI-Lite)
        soft_reset        : in  STD_LOGIC;

        -- Reset
        reset_n           : in  STD_LOGIC;

        -- UDP payload streaming (125 MHz RGMII domain from ethernet_top)
        udp_payload_data  : in  STD_LOGIC_VECTOR(7 downto 0);
        udp_payload_valid : in  STD_LOGIC;
        udp_payload_start : in  STD_LOGIC;
        udp_payload_end   : in  STD_LOGIC;

        -- UDP header info (for ITCH parser context)
        udp_src_port      : in  STD_LOGIC_VECTOR(15 downto 0);
        udp_dst_port      : in  STD_LOGIC_VECTOR(15 downto 0);
        ip_src_addr       : in  STD_LOGIC_VECTOR(31 downto 0);

        -- Order book outputs (ob_clk domain)
        bbo_update        : out STD_LOGIC;
        bbo_symbol        : out STD_LOGIC_VECTOR(63 downto 0);
        bbo_bid_price     : out UNSIGNED(31 downto 0);
        bbo_bid_size      : out UNSIGNED(31 downto 0);
        bbo_ask_price     : out UNSIGNED(31 downto 0);
        bbo_ask_size      : out UNSIGNED(31 downto 0);
        bbo_spread        : out UNSIGNED(31 downto 0);

        -- Backpressure from downstream (bbo_axi_stream ready signal)
        bbo_ready         : in  STD_LOGIC;

        -- Statistics outputs (125 MHz domain)
        itch_msg_count    : out STD_LOGIC_VECTOR(31 downto 0);

        -- Order book diagnostics (ob_clk domain)
        ob_msg_count      : out STD_LOGIC_VECTOR(31 downto 0);
        ob_bbo_count      : out STD_LOGIC_VECTOR(31 downto 0);

        -- FPGA Latency Timestamps (125 MHz cycle counts)
        ts_t1_out         : out STD_LOGIC_VECTOR(31 downto 0);
        ts_t2_out         : out STD_LOGIC_VECTOR(31 downto 0);

        -- Debug outputs for ILA
        dbg_bbo_state       : out STD_LOGIC_VECTOR(4 downto 0);
        dbg_bbo_spread_reg  : out STD_LOGIC_VECTOR(31 downto 0);
        dbg_arbiter_symbol  : out STD_LOGIC_VECTOR(2 downto 0);
        dbg_arbiter_counter : out STD_LOGIC_VECTOR(9 downto 0);
        dbg_ready_vec_0     : out STD_LOGIC;
        dbg_bbo_update_vec_0: out STD_LOGIC
    );
end trading_top;

architecture Behavioral of trading_top is

    -- Reset synchronization to RGMII clock domain
    signal reset_sync1 : STD_LOGIC := '0';
    signal reset_sync2 : STD_LOGIC := '0';
    signal reset_rgmii : STD_LOGIC;

    -- ITCH parser outputs
    signal itch_msg_valid_int : STD_LOGIC;
    signal itch_msg_type_int  : STD_LOGIC_VECTOR(7 downto 0);

    -- ITCH message fields
    signal itch_stock_locate  : STD_LOGIC_VECTOR(15 downto 0);
    signal itch_tracking_num  : STD_LOGIC_VECTOR(15 downto 0);
    signal itch_timestamp     : STD_LOGIC_VECTOR(47 downto 0);

    -- Order book signals (from itch_parser)
    signal ob_order_ref       : STD_LOGIC_VECTOR(63 downto 0);
    signal ob_symbol          : STD_LOGIC_VECTOR(63 downto 0);
    signal ob_side            : STD_LOGIC;
    signal ob_price           : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_shares          : STD_LOGIC_VECTOR(31 downto 0);

    -- Statistics
    signal msg_count : unsigned(31 downto 0) := (others => '0');

    -- Order book diagnostic counters (ob_clk domain)
    signal ob_msg_counter : unsigned(31 downto 0) := (others => '0');
    signal ob_bbo_counter : unsigned(31 downto 0) := (others => '0');

    -- FPGA Latency Timestamps (125 MHz RGMII domain)
    signal rgmii_cycle_counter : unsigned(31 downto 0) := (others => '0');
    signal ts_t1_125 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal ts_t2_125 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- T1/T2 passed through CDC FIFO to ob_clk domain
    signal ts_t1_ob : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal ts_t2_ob : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- T1/T2 latched when BBO update fires (captures timestamp of message that caused BBO change)
    signal ts_t1_bbo_latched : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal ts_t2_bbo_latched : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- ITCH parser message type signals
    signal add_order_valid_int : STD_LOGIC;
    signal add_order_start_int : STD_LOGIC;
    signal order_executed_valid_int : STD_LOGIC;
    signal order_cancel_valid_int : STD_LOGIC;
    signal order_delete_valid_int : STD_LOGIC;
    signal order_replace_valid_int : STD_LOGIC;
    signal exec_shares_int : STD_LOGIC_VECTOR(31 downto 0);
    signal cancel_shares_int : STD_LOGIC_VECTOR(31 downto 0);
    signal original_order_ref_int : STD_LOGIC_VECTOR(63 downto 0);
    signal new_order_ref_int : STD_LOGIC_VECTOR(63 downto 0);
    signal new_shares_int : STD_LOGIC_VECTOR(31 downto 0);
    signal new_price_int : STD_LOGIC_VECTOR(31 downto 0);

    -- ITCH Message CDC FIFO (125 MHz RGMII → ob_clk)
    -- Width: T1(32) + T2(32) + msg_type(8) + symbol(64) + order_ref(64) + side(1) +
    --        shares(32) + price(32) + new_order_ref(64) + new_shares(32) + new_price(32) = 393 bits, round to 448
    constant ITCH_CDC_FIFO_WIDTH : integer := 448;
    signal itch_cdc_fifo_wr_en : STD_LOGIC := '0';
    signal itch_cdc_fifo_wr_data : STD_LOGIC_VECTOR(ITCH_CDC_FIFO_WIDTH-1 downto 0) := (others => '0');
    signal itch_cdc_fifo_wr_full : STD_LOGIC;
    signal itch_cdc_fifo_rd_en : STD_LOGIC := '0';
    signal itch_cdc_fifo_rd_data : STD_LOGIC_VECTOR(ITCH_CDC_FIFO_WIDTH-1 downto 0);
    signal itch_cdc_fifo_rd_empty : STD_LOGIC;

    -- Unpacked ITCH message data from CDC FIFO (ob_clk domain)
    signal itch_fifo_msg_valid : STD_LOGIC := '0';
    signal itch_fifo_msg_type : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal itch_fifo_stock_symbol : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal itch_fifo_order_ref : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal itch_fifo_buy_sell : STD_LOGIC := '0';
    signal itch_fifo_shares : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal itch_fifo_price : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal itch_fifo_new_order_ref : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal itch_fifo_new_shares : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal itch_fifo_new_price : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- Order book outputs
    signal ob_bbo_update : STD_LOGIC;
    signal ob_bbo_symbol : STD_LOGIC_VECTOR(63 downto 0);
    signal ob_bbo_valid : STD_LOGIC;
    signal ob_bid_price : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_bid_shares : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_ask_price : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_ask_shares : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_spread : STD_LOGIC_VECTOR(31 downto 0);

begin

    -- =========================================================================
    -- Reset Synchronization to RGMII Clock Domain
    -- =========================================================================
    process(rgmii_rxc)
    begin
        if rising_edge(rgmii_rxc) then
            reset_sync1 <= not reset_n;
            reset_sync2 <= reset_sync1;
        end if;
    end process;

    reset_rgmii <= reset_sync2;

    -- =========================================================================
    -- ITCH Parser
    -- =========================================================================
    itch_parser_inst: entity work.itch_parser
        port map (
            clk => rgmii_rxc,
            rst => reset_rgmii,
            udp_payload_data => udp_payload_data,
            udp_payload_valid => udp_payload_valid,
            udp_payload_start => udp_payload_start,
            udp_payload_end => udp_payload_end,
            msg_valid => itch_msg_valid_int,
            msg_type => itch_msg_type_int,
            msg_error => open,
            add_order_valid => add_order_valid_int,
            add_order_start => add_order_start_int,
            stock_locate => itch_stock_locate,
            tracking_number => itch_tracking_num,
            timestamp => itch_timestamp,
            order_ref => ob_order_ref,
            buy_sell => ob_side,
            shares => ob_shares,
            stock_symbol => ob_symbol,
            price => ob_price,
            order_executed_valid => order_executed_valid_int,
            exec_shares => exec_shares_int,
            match_number => open,
            order_cancel_valid => order_cancel_valid_int,
            cancel_shares => cancel_shares_int,
            system_event_valid => open,
            event_code => open,
            stock_directory_valid => open,
            market_category => open,
            financial_status => open,
            round_lot_size => open,
            order_delete_valid => order_delete_valid_int,
            order_replace_valid => order_replace_valid_int,
            original_order_ref => original_order_ref_int,
            new_order_ref => new_order_ref_int,
            new_shares => new_shares_int,
            new_price => new_price_int,
            trade_valid => open,
            trade_price => open,
            cross_trade_valid => open,
            cross_shares => open,
            cross_price => open,
            cross_type => open,
            total_messages => open,
            filtered_messages => open,
            symbol_match => open
        );

    -- =========================================================================
    -- ITCH CDC FIFO Writer (125 MHz RGMII domain)
    -- Packs order-affecting ITCH messages for order book
    -- =========================================================================
    process(rgmii_rxc)
    begin
        if rising_edge(rgmii_rxc) then
            if reset_rgmii = '1' then
                itch_cdc_fifo_wr_en <= '0';
                itch_cdc_fifo_wr_data <= (others => '0');
                ts_t2_125 <= (others => '0');
            else
                itch_cdc_fifo_wr_en <= '0';

                -- Write order-affecting messages to CDC FIFO
                if add_order_valid_int = '1' or order_executed_valid_int = '1' or
                   order_cancel_valid_int = '1' or order_delete_valid_int = '1' or
                   order_replace_valid_int = '1' then

                    ts_t2_125 <= std_logic_vector(rgmii_cycle_counter);

                    -- Pack ITCH message (448 bits)
                    itch_cdc_fifo_wr_data(447 downto 416) <= ts_t1_125;
                    itch_cdc_fifo_wr_data(415 downto 384) <= std_logic_vector(rgmii_cycle_counter);
                    itch_cdc_fifo_wr_data(383 downto 376) <= itch_msg_type_int;
                    itch_cdc_fifo_wr_data(375 downto 312) <= ob_symbol;
                    itch_cdc_fifo_wr_data(311 downto 248) <= ob_order_ref;
                    itch_cdc_fifo_wr_data(247) <= ob_side;

                    if add_order_valid_int = '1' then
                        itch_cdc_fifo_wr_data(246 downto 215) <= ob_shares;
                        itch_cdc_fifo_wr_data(214 downto 183) <= ob_price;
                        itch_cdc_fifo_wr_data(182 downto 55) <= (others => '0');
                    elsif order_executed_valid_int = '1' then
                        itch_cdc_fifo_wr_data(246 downto 215) <= exec_shares_int;
                        itch_cdc_fifo_wr_data(214 downto 55) <= (others => '0');
                    elsif order_cancel_valid_int = '1' then
                        itch_cdc_fifo_wr_data(246 downto 215) <= cancel_shares_int;
                        itch_cdc_fifo_wr_data(214 downto 55) <= (others => '0');
                    elsif order_delete_valid_int = '1' then
                        itch_cdc_fifo_wr_data(246 downto 55) <= (others => '0');
                    elsif order_replace_valid_int = '1' then
                        itch_cdc_fifo_wr_data(246 downto 215) <= (others => '0');
                        itch_cdc_fifo_wr_data(214 downto 183) <= (others => '0');
                        itch_cdc_fifo_wr_data(182 downto 119) <= new_order_ref_int;
                        itch_cdc_fifo_wr_data(118 downto 87) <= new_shares_int;
                        itch_cdc_fifo_wr_data(86 downto 55) <= new_price_int;
                    end if;

                    itch_cdc_fifo_wr_data(54 downto 0) <= (others => '0');
                    itch_cdc_fifo_wr_en <= '1';
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- ITCH CDC FIFO (125 MHz → ob_clk)
    -- =========================================================================
    itch_cdc_fifo_inst: entity work.async_fifo
        generic map (
            DATA_WIDTH => ITCH_CDC_FIFO_WIDTH,
            FIFO_DEPTH => 2048
        )
        port map (
            wr_clk => rgmii_rxc,
            wr_rst => reset_rgmii,
            wr_en => itch_cdc_fifo_wr_en,
            wr_data => itch_cdc_fifo_wr_data,
            wr_full => itch_cdc_fifo_wr_full,
            rd_clk => ob_clk,
            rd_rst => ob_rst,
            rd_en => itch_cdc_fifo_rd_en,
            rd_data => itch_cdc_fifo_rd_data,
            rd_empty => itch_cdc_fifo_rd_empty
        );

    -- =========================================================================
    -- ITCH CDC FIFO Reader (ob_clk domain)
    -- =========================================================================
    process(ob_clk)
        variable rd_en_prev : std_logic := '0';
    begin
        if rising_edge(ob_clk) then
            if ob_rst = '1' then
                itch_cdc_fifo_rd_en <= '0';
                itch_fifo_msg_valid <= '0';
                itch_fifo_msg_type <= (others => '0');
                itch_fifo_stock_symbol <= (others => '0');
                itch_fifo_order_ref <= (others => '0');
                itch_fifo_buy_sell <= '0';
                itch_fifo_shares <= (others => '0');
                itch_fifo_price <= (others => '0');
                itch_fifo_new_order_ref <= (others => '0');
                itch_fifo_new_shares <= (others => '0');
                itch_fifo_new_price <= (others => '0');
                ts_t1_ob <= (others => '0');
                ts_t2_ob <= (others => '0');
                rd_en_prev := '0';
            else
                itch_cdc_fifo_rd_en <= '0';
                itch_fifo_msg_valid <= '0';

                if itch_cdc_fifo_rd_empty = '0' and rd_en_prev = '0' then
                    itch_cdc_fifo_rd_en <= '1';
                elsif rd_en_prev = '1' then
                    ts_t1_ob <= itch_cdc_fifo_rd_data(447 downto 416);
                    ts_t2_ob <= itch_cdc_fifo_rd_data(415 downto 384);
                    itch_fifo_msg_type <= itch_cdc_fifo_rd_data(383 downto 376);
                    itch_fifo_stock_symbol <= itch_cdc_fifo_rd_data(375 downto 312);
                    itch_fifo_order_ref <= itch_cdc_fifo_rd_data(311 downto 248);
                    itch_fifo_buy_sell <= itch_cdc_fifo_rd_data(247);
                    itch_fifo_shares <= itch_cdc_fifo_rd_data(246 downto 215);
                    itch_fifo_price <= itch_cdc_fifo_rd_data(214 downto 183);
                    itch_fifo_new_order_ref <= itch_cdc_fifo_rd_data(182 downto 119);
                    itch_fifo_new_shares <= itch_cdc_fifo_rd_data(118 downto 87);
                    itch_fifo_new_price <= itch_cdc_fifo_rd_data(86 downto 55);
                    itch_fifo_msg_valid <= '1';
                end if;

                rd_en_prev := itch_cdc_fifo_rd_en;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Order Book Manager
    -- =========================================================================
    multi_symbol_order_book_inst : entity work.multi_symbol_order_book
        port map (
            clk => ob_clk,
            reset => ob_rst,
            soft_reset => soft_reset,
            msg_valid => itch_fifo_msg_valid,
            msg_type => itch_fifo_msg_type,
            stock_symbol => itch_fifo_stock_symbol,
            order_ref => itch_fifo_order_ref,
            buy_sell => itch_fifo_buy_sell,
            shares => itch_fifo_shares,
            price => itch_fifo_price,
            new_order_ref => itch_fifo_new_order_ref,
            new_shares => itch_fifo_new_shares,
            new_price => itch_fifo_new_price,
            bbo_update => ob_bbo_update,
            bbo_symbol => ob_bbo_symbol,
            bbo_valid => ob_bbo_valid,
            bid_price => ob_bid_price,
            bid_shares => ob_bid_shares,
            ask_price => ob_ask_price,
            ask_shares => ob_ask_shares,
            spread => ob_spread,
            bbo_ready => bbo_ready,  -- Backpressure from downstream
            -- Debug outputs for ILA
            dbg_bbo_state => dbg_bbo_state,
            dbg_bbo_spread_reg => dbg_bbo_spread_reg,
            dbg_arbiter_symbol => dbg_arbiter_symbol,
            dbg_arbiter_counter => dbg_arbiter_counter,
            dbg_ready_vec_0 => dbg_ready_vec_0,
            dbg_bbo_update_vec_0 => dbg_bbo_update_vec_0
        );

    -- =========================================================================
    -- Message Counter and T1 Timestamp (125 MHz)
    -- =========================================================================
    process(rgmii_rxc, reset_rgmii)
    begin
        if reset_rgmii = '1' then
            msg_count <= (others => '0');
            rgmii_cycle_counter <= (others => '0');
            ts_t1_125 <= (others => '0');
        elsif rising_edge(rgmii_rxc) then
            rgmii_cycle_counter <= rgmii_cycle_counter + 1;
            if itch_msg_valid_int = '1' then
                msg_count <= msg_count + 1;
            end if;
            -- Capture T1 at START of ANY order-affecting message
            -- Detect message type directly from UDP payload first byte when payload starts
            -- Message types: A(0x41)=Add, D(0x44)=Delete, E(0x45)=Executed, U(0x55)=Replace, X(0x58)=Cancel
            if udp_payload_start = '1' and udp_payload_valid = '1' then
                case udp_payload_data is
                    when x"41" | x"44" | x"45" | x"55" | x"58" =>
                        ts_t1_125 <= std_logic_vector(rgmii_cycle_counter);
                    when others =>
                        null;  -- Non-order messages: don't update T1
                end case;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Order Book Diagnostic Counters (ob_clk domain)
    -- =========================================================================
    process(ob_clk)
    begin
        if rising_edge(ob_clk) then
            if ob_rst = '1' then
                ob_msg_counter <= (others => '0');
                ob_bbo_counter <= (others => '0');
                ts_t1_bbo_latched <= (others => '0');
                ts_t2_bbo_latched <= (others => '0');
            else
                if itch_fifo_msg_valid = '1' then
                    ob_msg_counter <= ob_msg_counter + 1;
                end if;
                if ob_bbo_update = '1' then
                    ob_bbo_counter <= ob_bbo_counter + 1;
                    -- Latch T1/T2 when BBO update fires
                    -- Captures timestamp of message that caused this BBO change
                    ts_t1_bbo_latched <= ts_t1_ob;
                    ts_t2_bbo_latched <= ts_t2_ob;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Output Assignments
    -- =========================================================================
    itch_msg_count <= std_logic_vector(msg_count);
    ob_msg_count <= std_logic_vector(ob_msg_counter);
    ob_bbo_count <= std_logic_vector(ob_bbo_counter);

    bbo_update <= ob_bbo_update;
    bbo_symbol <= ob_bbo_symbol;
    bbo_bid_price <= unsigned(ob_bid_price);
    bbo_bid_size <= unsigned(ob_bid_shares);
    bbo_ask_price <= unsigned(ob_ask_price);
    bbo_ask_size <= unsigned(ob_ask_shares);
    bbo_spread <= unsigned(ob_spread);

    -- Output T1/T2 latched at BBO update time (not continuous ts_t1_ob/ts_t2_ob)
    -- This ensures timestamp reflects the message that caused the BBO change
    ts_t1_out <= ts_t1_bbo_latched;
    ts_t2_out <= ts_t2_bbo_latched;

end Behavioral;
