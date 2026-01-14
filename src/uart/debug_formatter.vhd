----------------------------------------------------------------------------------
-- Debug Formatter Module
-- Purpose: Formats ethernet/trading debug information for UART output
--          Extracts all debug logic from board top-level
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity debug_formatter is
    Port (
        -- Clock and Reset
        clk                 : in  STD_LOGIC;  -- 200MHz system clock
        reset               : in  STD_LOGIC;

        -- Ethernet handler outputs (200MHz synchronized from ethernet_top)
        frame_valid         : in  STD_LOGIC;
        ip_rx_req           : in  STD_LOGIC;
        udp_rx_req          : in  STD_LOGIC;
        ip_rx_end           : in  STD_LOGIC;
        frame_count         : in  STD_LOGIC_VECTOR(31 downto 0);

        -- MAC layer info
        mac_src             : in  STD_LOGIC_VECTOR(47 downto 0);
        mac_dest            : in  STD_LOGIC_VECTOR(47 downto 0);
        ethertype           : in  STD_LOGIC_VECTOR(15 downto 0);
        mac_rec_error       : in  STD_LOGIC;

        -- IP layer info
        ip_src_addr         : in  STD_LOGIC_VECTOR(31 downto 0);
        ip_dst_addr         : in  STD_LOGIC_VECTOR(31 downto 0);
        net_protocol        : in  STD_LOGIC_VECTOR(7 downto 0);
        ip_total_length     : in  STD_LOGIC_VECTOR(15 downto 0);
        ip_checksum_error   : in  STD_LOGIC;
        ip_addr_check_error : in  STD_LOGIC;

        -- UDP layer info
        udp_src_port        : in  STD_LOGIC_VECTOR(15 downto 0);
        udp_dst_port        : in  STD_LOGIC_VECTOR(15 downto 0);
        udp_data_length     : in  STD_LOGIC_VECTOR(15 downto 0);
        udp_rec_data_valid  : in  STD_LOGIC;
        udp_checksum_error  : in  STD_LOGIC;

        -- Diagnostic signals
        fifo_empty          : in  STD_LOGIC;

        -- TX diagnostic signals (RGMII/UDP TX path)
        tx_valid            : in  STD_LOGIC;
        tx_packets_sent     : in  STD_LOGIC_VECTOR(31 downto 0);
        tx_reset            : in  STD_LOGIC;

        -- RGMII TX debug signals
        tx_byte_count       : in  STD_LOGIC_VECTOR(31 downto 0);
        tx_valid_seen       : in  STD_LOGIC;
        last_tx_byte        : in  STD_LOGIC_VECTOR(7 downto 0);

        -- Order book diagnostic signals (200MHz domain)
        ob_msg_count        : in  STD_LOGIC_VECTOR(31 downto 0);
        ob_bbo_count        : in  STD_LOGIC_VECTOR(31 downto 0);

        -- BBO FIFO diagnostic signals (200MHz domain)
        bbo_fifo_wr_count   : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_fifo_rd_count   : in  STD_LOGIC_VECTOR(31 downto 0);

        -- BBO packet builder diagnostic signals (synced to 200MHz)
        bbo_update_count    : in  STD_LOGIC_VECTOR(31 downto 0);  -- Times bbo_update seen
        bbo_tx_state        : in  STD_LOGIC_VECTOR(3 downto 0);   -- Current TX state
        bbo_max_state       : in  STD_LOGIC_VECTOR(3 downto 0);   -- Max state ever reached (sticky)
        bbo_reset_count     : in  STD_LOGIC_VECTOR(15 downto 0);  -- Reset pulses counted

        -- BBO debug signals (ask side debugging)
        bbo_bid_price_dbg   : in  STD_LOGIC_VECTOR(31 downto 0);  -- Current BBO bid price
        bbo_ask_price_dbg   : in  STD_LOGIC_VECTOR(31 downto 0);  -- Current BBO ask price
        bbo_ask_size_dbg    : in  STD_LOGIC_VECTOR(31 downto 0);  -- Current BBO ask size

        -- Ask order counter debug
        ob_ask_order_cnt    : in  STD_LOGIC_VECTOR(31 downto 0);  -- Ask orders received from ITCH

        -- PCIe debug signals
        pcie_axis_tx_count  : in  STD_LOGIC_VECTOR(31 downto 0) := (others => '0');  -- AXI stream packets sent
        pcie_tready_seen    : in  STD_LOGIC := '0';               -- Has XDMA asserted tready ever
        pcie_link_up        : in  STD_LOGIC := '0';               -- PCIe link status
        pcie_cdc_wr_count   : in  STD_LOGIC_VECTOR(31 downto 0) := (others => '0');  -- CDC FIFO writes
        pcie_cdc_rd_count   : in  STD_LOGIC_VECTOR(31 downto 0) := (others => '0');  -- CDC FIFO reads
        pcie_handshake_count: in  STD_LOGIC_VECTOR(31 downto 0) := (others => '0');  -- tvalid&tready cycles (synced)
        pcie_cdc_empty      : in  STD_LOGIC := '1';               -- CDC FIFO empty flag (synced)
        pcie_stream_ready   : in  STD_LOGIC := '0';               -- bbo_axi_stream ready (synced)
        pcie_tready_now     : in  STD_LOGIC := '0';               -- Current m_axis_tready (synced)
        pcie_tvalid_now     : in  STD_LOGIC := '0';               -- Current m_axis_tvalid (synced)
        pcie_axi_state      : in  STD_LOGIC_VECTOR(2 downto 0) := "000"; -- bbo_axi_stream state (synced, 3-bit)

        -- FIFO data debug (first 2 bytes of symbol to identify garbage)
        pcie_fifo_wr_data   : in  STD_LOGIC_VECTOR(15 downto 0) := (others => '0'); -- Symbol going into FIFO
        pcie_fifo_rd_data   : in  STD_LOGIC_VECTOR(15 downto 0) := (others => '0'); -- Symbol coming out of FIFO

        -- UART TX interface
        uart_tx_data        : out STD_LOGIC_VECTOR(7 downto 0);
        uart_tx_start       : out STD_LOGIC;
        uart_tx_busy        : in  STD_LOGIC
    );
end debug_formatter;

architecture Behavioral of debug_formatter is

    -- Helper function to convert 4-bit nibble to ASCII hex character
    function nibble_to_hex(nibble : unsigned(3 downto 0)) return std_logic_vector is
        variable result : std_logic_vector(7 downto 0);
    begin
        case nibble is
            when x"0" => result := x"30";  -- '0'
            when x"1" => result := x"31";  -- '1'
            when x"2" => result := x"32";  -- '2'
            when x"3" => result := x"33";  -- '3'
            when x"4" => result := x"34";  -- '4'
            when x"5" => result := x"35";  -- '5'
            when x"6" => result := x"36";  -- '6'
            when x"7" => result := x"37";  -- '7'
            when x"8" => result := x"38";  -- '8'
            when x"9" => result := x"39";  -- '9'
            when x"A" => result := x"41";  -- 'A'
            when x"B" => result := x"42";  -- 'B'
            when x"C" => result := x"43";  -- 'C'
            when x"D" => result := x"44";  -- 'D'
            when x"E" => result := x"45";  -- 'E'
            when x"F" => result := x"46";  -- 'F'
            when others => result := x"30";  -- '0' (default)
        end case;
        return result;
    end function;

    -- Debug message state machine
    type debug_state_t is (IDLE, SEND_CHAR, WAIT_BUSY);
    signal debug_state : debug_state_t := IDLE;
    signal debug_char_index : unsigned(9 downto 0) := (others => '0');

    -- Sampled handler signals for UART debug (sticky latches)
    signal frame_valid_sampled : STD_LOGIC := '0';
    signal ip_rx_req_sampled : STD_LOGIC := '0';
    signal ip_rx_end_sampled : STD_LOGIC := '0';
    signal udp_rx_req_sampled : STD_LOGIC := '0';

    -- Sampled data signals
    signal mac_src_sampled : STD_LOGIC_VECTOR(47 downto 0) := (others => '0');
    signal mac_dest_sampled : STD_LOGIC_VECTOR(47 downto 0) := (others => '0');
    signal ethertype_sampled : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal mac_rec_error_sampled : STD_LOGIC := '0';
    signal ip_src_addr_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal ip_dst_addr_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal net_protocol_sampled : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal ip_total_length_sampled : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal ip_checksum_error_sampled : STD_LOGIC := '0';
    signal ip_addr_check_error_sampled : STD_LOGIC := '0';
    signal udp_src_port_sampled : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal udp_dst_port_sampled : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal udp_data_length_sampled : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal udp_rec_data_valid_sampled : STD_LOGIC := '0';
    signal udp_checksum_error_sampled : STD_LOGIC := '0';
    signal frame_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- TX diagnostic sampled signals
    signal tx_valid_sampled : STD_LOGIC := '0';
    signal tx_packets_sent_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal tx_reset_sampled : STD_LOGIC := '0';

    -- RGMII TX debug sampled signals
    signal tx_byte_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal tx_valid_seen_sampled : STD_LOGIC := '0';
    signal last_tx_byte_sampled : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

    -- Order book diagnostic sampled signals
    signal ob_msg_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal ob_bbo_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- BBO FIFO diagnostic sampled signals
    signal bbo_fifo_wr_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal bbo_fifo_rd_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- BBO packet builder diagnostic sampled signals
    signal bbo_update_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal bbo_tx_state_sampled : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal bbo_max_state_sampled : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal bbo_reset_count_sampled : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');

    -- BBO debug sampled signals
    signal bbo_bid_price_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal bbo_ask_price_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal bbo_ask_size_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal ob_ask_order_cnt_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- PCIe debug sampled signals
    signal pcie_axis_tx_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal pcie_tready_seen_sampled : STD_LOGIC := '0';
    signal pcie_link_up_sampled : STD_LOGIC := '0';
    signal pcie_cdc_wr_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal pcie_cdc_rd_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal pcie_handshake_count_sampled : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal pcie_cdc_empty_sampled : STD_LOGIC := '0';
    signal pcie_stream_ready_sampled : STD_LOGIC := '0';
    signal pcie_tready_now_sampled : STD_LOGIC := '0';
    signal pcie_tvalid_now_sampled : STD_LOGIC := '0';
    signal pcie_axi_state_sampled : STD_LOGIC_VECTOR(2 downto 0) := (others => '0');
    signal pcie_fifo_wr_data_sampled : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal pcie_fifo_rd_data_sampled : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');

    -- Frame end pulse detection
    signal ip_rx_end_prev : STD_LOGIC := '0';
    signal ip_rx_req_prev : STD_LOGIC := '0';
    signal frame_end_pulse : STD_LOGIC := '0';

    -- Internal UART signals
    signal uart_tx_data_int : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal uart_tx_start_int : STD_LOGIC := '0';

begin

    -- Frame end pulse detection
    process(clk, reset)
    begin
        if reset = '1' then
            ip_rx_end_prev <= '0';
            ip_rx_req_prev <= '0';
            frame_end_pulse <= '0';
        elsif rising_edge(clk) then
            ip_rx_end_prev <= ip_rx_end;
            ip_rx_req_prev <= ip_rx_req;
            if (ip_rx_end = '1' and ip_rx_end_prev = '0') or
               (ip_rx_req = '1' and ip_rx_req_prev = '0') then
                frame_end_pulse <= '1';
            else
                frame_end_pulse <= '0';
            end if;
        end if;
    end process;

    -- UART debug state machine
    process(clk, reset)
    begin
        if reset = '1' then
            debug_state <= IDLE;
            debug_char_index <= (others => '0');
            uart_tx_start_int <= '0';
            uart_tx_data_int <= (others => '0');
            frame_valid_sampled <= '0';
            ip_rx_req_sampled <= '0';
            ip_rx_end_sampled <= '0';
            udp_rx_req_sampled <= '0';
            mac_rec_error_sampled <= '0';
            mac_src_sampled <= (others => '0');
            mac_dest_sampled <= (others => '0');
            ethertype_sampled <= (others => '0');
            ip_src_addr_sampled <= (others => '0');
            ip_dst_addr_sampled <= (others => '0');
            net_protocol_sampled <= (others => '0');
            ip_checksum_error_sampled <= '0';
            ip_addr_check_error_sampled <= '0';
            ip_total_length_sampled <= (others => '0');
            udp_src_port_sampled <= (others => '0');
            udp_dst_port_sampled <= (others => '0');
            udp_data_length_sampled <= (others => '0');
            udp_rec_data_valid_sampled <= '0';
            udp_checksum_error_sampled <= '0';
            frame_count_sampled <= (others => '0');
            tx_valid_sampled <= '0';
            tx_packets_sent_sampled <= (others => '0');
            tx_reset_sampled <= '0';
            tx_byte_count_sampled <= (others => '0');
            tx_valid_seen_sampled <= '0';
            last_tx_byte_sampled <= (others => '0');
            ob_msg_count_sampled <= (others => '0');
            ob_bbo_count_sampled <= (others => '0');
            bbo_fifo_wr_count_sampled <= (others => '0');
            bbo_fifo_rd_count_sampled <= (others => '0');
            bbo_update_count_sampled <= (others => '0');
            bbo_tx_state_sampled <= (others => '0');
            bbo_max_state_sampled <= (others => '0');
            bbo_reset_count_sampled <= (others => '0');
            bbo_bid_price_sampled <= (others => '0');
            bbo_ask_price_sampled <= (others => '0');
            bbo_ask_size_sampled <= (others => '0');
            ob_ask_order_cnt_sampled <= (others => '0');
            pcie_axis_tx_count_sampled <= (others => '0');
            pcie_tready_seen_sampled <= '0';
            pcie_link_up_sampled <= '0';
            pcie_cdc_wr_count_sampled <= (others => '0');
            pcie_cdc_rd_count_sampled <= (others => '0');
            pcie_handshake_count_sampled <= (others => '0');
            pcie_cdc_empty_sampled <= '0';
            pcie_stream_ready_sampled <= '0';
            pcie_tready_now_sampled <= '0';
            pcie_tvalid_now_sampled <= '0';
            pcie_axi_state_sampled <= (others => '0');
            pcie_fifo_wr_data_sampled <= (others => '0');
            pcie_fifo_rd_data_sampled <= (others => '0');
        elsif rising_edge(clk) then
            -- Sticky sampling: Latch signals when they pulse
            if frame_valid = '1' then
                frame_valid_sampled <= '1';
            elsif debug_state = IDLE and frame_end_pulse = '0' then
                frame_valid_sampled <= '0';
            end if;

            if ip_rx_req = '1' then
                ip_rx_req_sampled <= '1';
            elsif debug_state = IDLE and frame_end_pulse = '0' then
                ip_rx_req_sampled <= '0';
            end if;

            if udp_rx_req = '1' then
                udp_rx_req_sampled <= '1';
            elsif debug_state = IDLE and frame_end_pulse = '0' then
                udp_rx_req_sampled <= '0';
            end if;

            if ip_rx_end = '1' then
                ip_rx_end_sampled <= '1';
            elsif debug_state = IDLE and frame_end_pulse = '0' then
                ip_rx_end_sampled <= '0';
            end if;

            -- Trigger STATUS output on frame_end_pulse
            if debug_state = IDLE then
                if frame_end_pulse = '1' or (fifo_empty = '0' and frame_valid = '1') then
                    debug_state <= SEND_CHAR;
                    -- Sample all data signals
                    mac_dest_sampled <= mac_dest;
                    mac_src_sampled <= mac_src;
                    ethertype_sampled <= ethertype;
                    mac_rec_error_sampled <= mac_rec_error;
                    ip_src_addr_sampled <= ip_src_addr;
                    ip_dst_addr_sampled <= ip_dst_addr;
                    net_protocol_sampled <= net_protocol;
                    ip_addr_check_error_sampled <= ip_addr_check_error;
                    ip_checksum_error_sampled <= ip_checksum_error;
                    ip_total_length_sampled <= ip_total_length;
                    udp_src_port_sampled <= udp_src_port;
                    udp_dst_port_sampled <= udp_dst_port;
                    udp_data_length_sampled <= udp_data_length;
                    udp_rec_data_valid_sampled <= udp_rec_data_valid;
                    udp_checksum_error_sampled <= udp_checksum_error;
                    frame_count_sampled <= frame_count;
                    -- TX diagnostic signals
                    tx_valid_sampled <= tx_valid;
                    tx_packets_sent_sampled <= tx_packets_sent;
                    tx_reset_sampled <= tx_reset;
                    -- RGMII TX debug signals
                    tx_byte_count_sampled <= tx_byte_count;
                    tx_valid_seen_sampled <= tx_valid_seen;
                    last_tx_byte_sampled <= last_tx_byte;
                    -- Order book diagnostic signals
                    ob_msg_count_sampled <= ob_msg_count;
                    ob_bbo_count_sampled <= ob_bbo_count;
                    -- BBO FIFO diagnostic signals
                    bbo_fifo_wr_count_sampled <= bbo_fifo_wr_count;
                    bbo_fifo_rd_count_sampled <= bbo_fifo_rd_count;
                    -- BBO packet builder diagnostic signals
                    bbo_update_count_sampled <= bbo_update_count;
                    bbo_tx_state_sampled <= bbo_tx_state;
                    bbo_max_state_sampled <= bbo_max_state;
                    bbo_reset_count_sampled <= bbo_reset_count;
                    -- BBO debug signals (ask side)
                    bbo_bid_price_sampled <= bbo_bid_price_dbg;
                    bbo_ask_price_sampled <= bbo_ask_price_dbg;
                    bbo_ask_size_sampled <= bbo_ask_size_dbg;
                    -- Ask order counter
                    ob_ask_order_cnt_sampled <= ob_ask_order_cnt;
                    -- PCIe debug signals
                    pcie_axis_tx_count_sampled <= pcie_axis_tx_count;
                    pcie_tready_seen_sampled <= pcie_tready_seen;
                    pcie_link_up_sampled <= pcie_link_up;
                    pcie_cdc_wr_count_sampled <= pcie_cdc_wr_count;
                    pcie_cdc_rd_count_sampled <= pcie_cdc_rd_count;
                    pcie_handshake_count_sampled <= pcie_handshake_count;
                    pcie_cdc_empty_sampled <= pcie_cdc_empty;
                    pcie_stream_ready_sampled <= pcie_stream_ready;
                    pcie_tready_now_sampled <= pcie_tready_now;
                    pcie_tvalid_now_sampled <= pcie_tvalid_now;
                    pcie_axi_state_sampled <= pcie_axi_state;
                    pcie_fifo_wr_data_sampled <= pcie_fifo_wr_data;
                    pcie_fifo_rd_data_sampled <= pcie_fifo_rd_data;
                end if;
            end if;

            -- State machine to send STATUS message
            -- Format: "STATUS: fv=X ip=X udp=X mac_err=X mac_src=XX:XX:XX:XX:XX:XX mac_dst=XX:XX:XX:XX:XX:XX ethertype=XXXX ip_src=XX.XX.XX.XX ip_dst=XX.XX.XX.XX ip_proto=XX ip_chk_err=X ip_addr_err=X ip_len=XXXX ip_end=X rst=X rxv=- fs=- fe=- err=- bcnt=XXXX udp_sport=XXXX udp_dport=XXXX udp_len=XXXX udp_valid=X udp_chk_err=X \r\n"
            case debug_state is
                when IDLE =>
                    uart_tx_start_int <= '0';
                    debug_char_index <= (others => '0');
                    uart_tx_data_int <= (others => '0');

                when SEND_CHAR =>
                    -- STATUS message character output (343 chars total, indices 0-342)
                    case to_integer(debug_char_index) is
                        -- "STATUS: "
                        when 0 => uart_tx_data_int <= x"53"; -- 'S'
                        when 1 => uart_tx_data_int <= x"54"; -- 'T'
                        when 2 => uart_tx_data_int <= x"41"; -- 'A'
                        when 3 => uart_tx_data_int <= x"54"; -- 'T'
                        when 4 => uart_tx_data_int <= x"55"; -- 'U'
                        when 5 => uart_tx_data_int <= x"53"; -- 'S'
                        when 6 => uart_tx_data_int <= x"3A"; -- ':'
                        when 7 => uart_tx_data_int <= x"20"; -- ' '
                        -- "fv="
                        when 8 => uart_tx_data_int <= x"66"; -- 'f'
                        when 9 => uart_tx_data_int <= x"76"; -- 'v'
                        when 10 => uart_tx_data_int <= x"3D"; -- '='
                        when 11 =>
                            if frame_valid_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 12 => uart_tx_data_int <= x"20"; -- ' '
                        -- "ip=" (IP frame detected by MAC parser)
                        when 13 => uart_tx_data_int <= x"69"; -- 'i'
                        when 14 => uart_tx_data_int <= x"70"; -- 'p'
                        when 15 => uart_tx_data_int <= x"3D"; -- '='
                        when 16 =>
                            if ip_rx_req_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 17 => uart_tx_data_int <= x"20"; -- ' '
                        -- "udp="
                        when 18 => uart_tx_data_int <= x"75"; -- 'u'
                        when 19 => uart_tx_data_int <= x"64"; -- 'd'
                        when 20 => uart_tx_data_int <= x"70"; -- 'p'
                        when 21 => uart_tx_data_int <= x"3D"; -- '='
                        when 22 =>
                            if udp_rx_req_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 23 => uart_tx_data_int <= x"20"; -- ' '
                        -- "mac_err="
                        when 24 => uart_tx_data_int <= x"6D"; -- 'm'
                        when 25 => uart_tx_data_int <= x"61"; -- 'a'
                        when 26 => uart_tx_data_int <= x"63"; -- 'c'
                        when 27 => uart_tx_data_int <= x"5F"; -- '_'
                        when 28 => uart_tx_data_int <= x"65"; -- 'e'
                        when 29 => uart_tx_data_int <= x"72"; -- 'r'
                        when 30 => uart_tx_data_int <= x"72"; -- 'r'
                        when 31 => uart_tx_data_int <= x"3D"; -- '='
                        when 32 =>
                            if mac_rec_error_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 33 => uart_tx_data_int <= x"20"; -- ' '
                        -- "mac_src=" followed by MAC address XX:XX:XX:XX:XX:XX
                        when 34 => uart_tx_data_int <= x"6D"; -- 'm'
                        when 35 => uart_tx_data_int <= x"61"; -- 'a'
                        when 36 => uart_tx_data_int <= x"63"; -- 'c'
                        when 37 => uart_tx_data_int <= x"5F"; -- '_'
                        when 38 => uart_tx_data_int <= x"73"; -- 's'
                        when 39 => uart_tx_data_int <= x"72"; -- 'r'
                        when 40 => uart_tx_data_int <= x"63"; -- 'c'
                        when 41 => uart_tx_data_int <= x"3D"; -- '='

                        -- MAC byte 0 (bits 47-40)
                        when 42 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(47 downto 44)));
                        when 43 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(43 downto 40)));
                        when 44 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC byte 1 (bits 39-32)
                        when 45 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(39 downto 36)));
                        when 46 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(35 downto 32)));
                        when 47 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC byte 2 (bits 31-24)
                        when 48 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(31 downto 28)));
                        when 49 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(27 downto 24)));
                        when 50 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC byte 3 (bits 23-16)
                        when 51 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(23 downto 20)));
                        when 52 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(19 downto 16)));
                        when 53 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC byte 4 (bits 15-8)
                        when 54 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(15 downto 12)));
                        when 55 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(11 downto 8)));
                        when 56 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC byte 5 (bits 7-0)
                        when 57 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(7 downto 4)));
                        when 58 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_src_sampled(3 downto 0)));
                        when 59 => uart_tx_data_int <= x"20"; -- ' '
                        -- MAC destination address
                        -- mac_dst= XX:XX:XX:XX:XX:XX
                        when 60 => uart_tx_data_int <= x"6D"; -- 'm'
                        when 61 => uart_tx_data_int <= x"61"; -- 'a'
                        when 62 => uart_tx_data_int <= x"63"; -- 'c'
                        when 63 => uart_tx_data_int <= x"5F"; -- '_'
                        when 64 => uart_tx_data_int <= x"64"; -- 'd'
                        when 65 => uart_tx_data_int <= x"73"; -- 's'
                        when 66 => uart_tx_data_int <= x"74"; -- 't'
                        when 67 => uart_tx_data_int <= x"3D"; -- '='
                        when 68 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(47 downto 44)));
                        when 69 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(43 downto 40)));
                        when 70 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC destination address byte 1 (bits 39-32)
                        when 71 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(39 downto 36)));
                        when 72 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(35 downto 32)));
                        when 73 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC destination address byte 2 (bits 31-24)
                        when 74 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(31 downto 28)));
                        when 75 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(27 downto 24)));
                        when 76 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC destination address byte 3 (bits 23-16)
                        when 77 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(23 downto 20)));
                        when 78 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(19 downto 16)));
                        when 79 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC destination address byte 4 (bits 15-8)
                        when 80 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(15 downto 12)));
                        when 81 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(11 downto 8)));
                        when 82 => uart_tx_data_int <= x"3A"; -- ':'
                        -- MAC destination address byte 5 (bits 7-0)
                        when 83 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(7 downto 4)));
                        when 84 => uart_tx_data_int <= nibble_to_hex(unsigned(mac_dest_sampled(3 downto 0)));
                        when 85 => uart_tx_data_int <= x"20"; -- ' '
                        -- ethertype= XXXX
                        when 86 => uart_tx_data_int <= x"65"; -- 'e'
                        when 87 => uart_tx_data_int <= x"74"; -- 't'
                        when 88 => uart_tx_data_int <= x"68"; -- 'h'
                        when 89 => uart_tx_data_int <= x"65"; -- 'e'
                        when 90 => uart_tx_data_int <= x"72"; -- 'r'
                        when 91 => uart_tx_data_int <= x"74"; -- 't'
                        when 92 => uart_tx_data_int <= x"79"; -- 'y'
                        when 93 => uart_tx_data_int <= x"70"; -- 'p'
                        when 94 => uart_tx_data_int <= x"65"; -- 'e'
                        when 95 => uart_tx_data_int <= x"3D"; -- '='
                        when 96 => uart_tx_data_int <= nibble_to_hex(unsigned(ethertype_sampled(15 downto 12)));
                        when 97 => uart_tx_data_int <= nibble_to_hex(unsigned(ethertype_sampled(11 downto 8)));
                        when 98 => uart_tx_data_int <= x"3A"; -- ':'
                        when 99 => uart_tx_data_int <= nibble_to_hex(unsigned(ethertype_sampled(7 downto 4)));
                        when 100 => uart_tx_data_int <= nibble_to_hex(unsigned(ethertype_sampled(3 downto 0)));
                        when 101 => uart_tx_data_int <= x"20"; -- ' '

                        -- IP parser debug output
                        -- "ip_src=" followed by IP address XX.XX.XX.XX
                        when 102 => uart_tx_data_int <= x"69"; -- 'i'
                        when 103 => uart_tx_data_int <= x"70"; -- 'p'
                        when 104 => uart_tx_data_int <= x"5F"; -- '_'
                        when 105 => uart_tx_data_int <= x"73"; -- 's'
                        when 106 => uart_tx_data_int <= x"72"; -- 'r'
                        when 107 => uart_tx_data_int <= x"63"; -- 'c'
                        when 108 => uart_tx_data_int <= x"3D"; -- '='
                        -- IP byte 0 (bits 31-24)
                        when 109 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_src_addr_sampled(31 downto 28)));
                        when 110 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_src_addr_sampled(27 downto 24)));
                        when 111 => uart_tx_data_int <= x"2E"; -- '.'
                        -- IP byte 1 (bits 23-16)
                        when 112 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_src_addr_sampled(23 downto 20)));
                        when 113 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_src_addr_sampled(19 downto 16)));
                        when 114 => uart_tx_data_int <= x"2E"; -- '.'
                        -- IP byte 2 (bits 15-8)
                        when 115 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_src_addr_sampled(15 downto 12)));
                        when 116 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_src_addr_sampled(11 downto 8)));
                        when 117 => uart_tx_data_int <= x"2E"; -- '.'
                        -- IP byte 3 (bits 7-0)
                        when 118 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_src_addr_sampled(7 downto 4)));
                        when 119 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_src_addr_sampled(3 downto 0)));
                        when 120 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ip_dst=" followed by IP address XX.XX.XX.XX
                        when 121 => uart_tx_data_int <= x"69"; -- 'i'
                        when 122 => uart_tx_data_int <= x"70"; -- 'p'
                        when 123 => uart_tx_data_int <= x"5F"; -- '_'
                        when 124 => uart_tx_data_int <= x"64"; -- 'd'
                        when 125 => uart_tx_data_int <= x"73"; -- 's'
                        when 126 => uart_tx_data_int <= x"74"; -- 't'
                        when 127 => uart_tx_data_int <= x"3D"; -- '='
                        -- IP destination byte 0 (bits 31-24)
                        when 128 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_dst_addr_sampled(31 downto 28)));
                        when 129 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_dst_addr_sampled(27 downto 24)));
                        when 130 => uart_tx_data_int <= x"2E"; -- '.'
                        -- IP destination byte 1 (bits 23-16)
                        when 131 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_dst_addr_sampled(23 downto 20)));
                        when 132 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_dst_addr_sampled(19 downto 16)));
                        when 133 => uart_tx_data_int <= x"2E"; -- '.'
                        -- IP destination byte 2 (bits 15-8)
                        when 134 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_dst_addr_sampled(15 downto 12)));
                        when 135 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_dst_addr_sampled(11 downto 8)));
                        when 136 => uart_tx_data_int <= x"2E"; -- '.'
                        -- IP destination byte 3 (bits 7-0)
                        when 137 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_dst_addr_sampled(7 downto 4)));
                        when 138 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_dst_addr_sampled(3 downto 0)));
                        when 139 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ip_proto=" followed by protocol XX
                        when 140 => uart_tx_data_int <= x"69"; -- 'i'
                        when 141 => uart_tx_data_int <= x"70"; -- 'p'
                        when 142 => uart_tx_data_int <= x"5F"; -- '_'
                        when 143 => uart_tx_data_int <= x"70"; -- 'p'
                        when 144 => uart_tx_data_int <= x"72"; -- 'r'
                        when 145 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 146 => uart_tx_data_int <= x"74"; -- 't'
                        when 147 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 148 => uart_tx_data_int <= x"3D"; -- '='
                        when 149 => uart_tx_data_int <= nibble_to_hex(unsigned(net_protocol_sampled(7 downto 4)));
                        when 150 => uart_tx_data_int <= nibble_to_hex(unsigned(net_protocol_sampled(3 downto 0)));
                        when 151 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ip_chk_err="
                        when 152 => uart_tx_data_int <= x"69"; -- 'i'
                        when 153 => uart_tx_data_int <= x"70"; -- 'p'
                        when 154 => uart_tx_data_int <= x"5F"; -- '_'
                        when 155 => uart_tx_data_int <= x"63"; -- 'c'
                        when 156 => uart_tx_data_int <= x"68"; -- 'h'
                        when 157 => uart_tx_data_int <= x"6B"; -- 'k'
                        when 158 => uart_tx_data_int <= x"5F"; -- '_'
                        when 159 => uart_tx_data_int <= x"65"; -- 'e'
                        when 160 => uart_tx_data_int <= x"72"; -- 'r'
                        when 161 => uart_tx_data_int <= x"72"; -- 'r'
                        when 162 => uart_tx_data_int <= x"3D"; -- '='
                        when 163 =>
                            if ip_checksum_error_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 164 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ip_addr_err="
                        when 165 => uart_tx_data_int <= x"69"; -- 'i'
                        when 166 => uart_tx_data_int <= x"70"; -- 'p'
                        when 167 => uart_tx_data_int <= x"5F"; -- '_'
                        when 168 => uart_tx_data_int <= x"61"; -- 'a'
                        when 169 => uart_tx_data_int <= x"64"; -- 'd'
                        when 170 => uart_tx_data_int <= x"64"; -- 'd'
                        when 171 => uart_tx_data_int <= x"72"; -- 'r'
                        when 172 => uart_tx_data_int <= x"5F"; -- '_'
                        when 173 => uart_tx_data_int <= x"65"; -- 'e'
                        when 174 => uart_tx_data_int <= x"72"; -- 'r'
                        when 175 => uart_tx_data_int <= x"72"; -- 'r'
                        when 176 => uart_tx_data_int <= x"3D"; -- '='
                        when 177 =>
                            if ip_addr_check_error_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 178 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ip_len=" followed by length XXXX
                        when 179 => uart_tx_data_int <= x"69"; -- 'i'
                        when 180 => uart_tx_data_int <= x"70"; -- 'p'
                        when 181 => uart_tx_data_int <= x"5F"; -- '_'
                        when 182 => uart_tx_data_int <= x"6C"; -- 'l'
                        when 183 => uart_tx_data_int <= x"65"; -- 'e'
                        when 184 => uart_tx_data_int <= x"6E"; -- 'n'
                        when 185 => uart_tx_data_int <= x"3D"; -- '='
                        when 186 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_total_length_sampled(15 downto 12)));
                        when 187 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_total_length_sampled(11 downto 8)));
                        when 188 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_total_length_sampled(7 downto 4)));
                        when 189 => uart_tx_data_int <= nibble_to_hex(unsigned(ip_total_length_sampled(3 downto 0)));
                        when 190 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ip_end="
                        when 191 => uart_tx_data_int <= x"69"; -- 'i'
                        when 192 => uart_tx_data_int <= x"70"; -- 'p'
                        when 193 => uart_tx_data_int <= x"5F"; -- '_'
                        when 194 => uart_tx_data_int <= x"65"; -- 'e'
                        when 195 => uart_tx_data_int <= x"6E"; -- 'n'
                        when 196 => uart_tx_data_int <= x"64"; -- 'd'
                        when 197 => uart_tx_data_int <= x"3D"; -- '='
                        when 198 =>
                            if ip_rx_end_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 199 => uart_tx_data_int <= x"20"; -- ' '

                        -- "rst="
                        when 200 => uart_tx_data_int <= x"72"; -- 'r'
                        when 201 => uart_tx_data_int <= x"73"; -- 's'
                        when 202 => uart_tx_data_int <= x"74"; -- 't'
                        when 203 => uart_tx_data_int <= x"3D"; -- '='
                        when 204 =>
                            if reset = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 205 => uart_tx_data_int <= x"20"; -- ' '
                        -- "rxv=" (removed - not available from ethernet_top)
                        when 206 => uart_tx_data_int <= x"72"; -- 'r'
                        when 207 => uart_tx_data_int <= x"78"; -- 'x'
                        when 208 => uart_tx_data_int <= x"76"; -- 'v'
                        when 209 => uart_tx_data_int <= x"3D"; -- '='
                        when 210 => uart_tx_data_int <= x"2D"; -- '-' (not available)
                        when 211 => uart_tx_data_int <= x"20"; -- ' '
                        -- "fs=" (removed - not available from ethernet_top)
                        when 212 => uart_tx_data_int <= x"66"; -- 'f'
                        when 213 => uart_tx_data_int <= x"73"; -- 's'
                        when 214 => uart_tx_data_int <= x"3D"; -- '='
                        when 215 => uart_tx_data_int <= x"2D"; -- '-' (not available)
                        when 216 => uart_tx_data_int <= x"20"; -- ' '
                        -- "fe=" (removed - not available from ethernet_top)
                        when 217 => uart_tx_data_int <= x"66"; -- 'f'
                        when 218 => uart_tx_data_int <= x"65"; -- 'e'
                        when 219 => uart_tx_data_int <= x"3D"; -- '='
                        when 220 => uart_tx_data_int <= x"2D"; -- '-' (not available)
                        when 221 => uart_tx_data_int <= x"20"; -- ' '
                        -- "err=" (removed - not available from ethernet_top)
                        when 222 => uart_tx_data_int <= x"65"; -- 'e'
                        when 223 => uart_tx_data_int <= x"72"; -- 'r'
                        when 224 => uart_tx_data_int <= x"72"; -- 'r'
                        when 225 => uart_tx_data_int <= x"3D"; -- '='
                        when 226 => uart_tx_data_int <= x"2D"; -- '-' (not available)
                        when 227 => uart_tx_data_int <= x"20"; -- ' '
                        -- "bcnt=" (frame count - lower 16 bits as hex)
                        when 228 => uart_tx_data_int <= x"62"; -- 'b'
                        when 229 => uart_tx_data_int <= x"63"; -- 'c'
                        when 230 => uart_tx_data_int <= x"6E"; -- 'n'
                        when 231 => uart_tx_data_int <= x"74"; -- 't'
                        when 232 => uart_tx_data_int <= x"3D"; -- '='
                        -- Hex digit 3 (bits 15-12)
                        when 233 => uart_tx_data_int <= nibble_to_hex(unsigned(frame_count_sampled(15 downto 12)));
                        -- Hex digit 2 (bits 11-8)
                        when 234 => uart_tx_data_int <= nibble_to_hex(unsigned(frame_count_sampled(11 downto 8)));
                        -- Hex digit 1 (bits 7-4)
                        when 235 => uart_tx_data_int <= nibble_to_hex(unsigned(frame_count_sampled(7 downto 4)));
                        -- Hex digit 0 (bits 3-0)
                        when 236 => uart_tx_data_int <= nibble_to_hex(unsigned(frame_count_sampled(3 downto 0)));
                        when 237 => uart_tx_data_int <= x"20"; -- ' '

                        -- UDP parser debug output
                        -- "udp_sport=" followed by port XXXX
                        when 238 => uart_tx_data_int <= x"75"; -- 'u'
                        when 239 => uart_tx_data_int <= x"64"; -- 'd'
                        when 240 => uart_tx_data_int <= x"70"; -- 'p'
                        when 241 => uart_tx_data_int <= x"5F"; -- '_'
                        when 242 => uart_tx_data_int <= x"73"; -- 's'
                        when 243 => uart_tx_data_int <= x"70"; -- 'p'
                        when 244 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 245 => uart_tx_data_int <= x"72"; -- 'r'
                        when 246 => uart_tx_data_int <= x"74"; -- 't'
                        when 247 => uart_tx_data_int <= x"3D"; -- '='
                        when 248 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_src_port_sampled(15 downto 12)));
                        when 249 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_src_port_sampled(11 downto 8)));
                        when 250 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_src_port_sampled(7 downto 4)));
                        when 251 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_src_port_sampled(3 downto 0)));
                        when 252 => uart_tx_data_int <= x"20"; -- ' '

                        -- "udp_dport=" followed by port XXXX
                        when 253 => uart_tx_data_int <= x"75"; -- 'u'
                        when 254 => uart_tx_data_int <= x"64"; -- 'd'
                        when 255 => uart_tx_data_int <= x"70"; -- 'p'
                        when 256 => uart_tx_data_int <= x"5F"; -- '_'
                        when 257 => uart_tx_data_int <= x"64"; -- 'd'
                        when 258 => uart_tx_data_int <= x"70"; -- 'p'
                        when 259 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 260 => uart_tx_data_int <= x"72"; -- 'r'
                        when 261 => uart_tx_data_int <= x"74"; -- 't'
                        when 262 => uart_tx_data_int <= x"3D"; -- '='
                        when 263 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_dst_port_sampled(15 downto 12)));
                        when 264 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_dst_port_sampled(11 downto 8)));
                        when 265 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_dst_port_sampled(7 downto 4)));
                        when 266 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_dst_port_sampled(3 downto 0)));
                        when 267 => uart_tx_data_int <= x"20"; -- ' '

                        -- "udp_len=" followed by length XXXX
                        when 268 => uart_tx_data_int <= x"75"; -- 'u'
                        when 269 => uart_tx_data_int <= x"64"; -- 'd'
                        when 270 => uart_tx_data_int <= x"70"; -- 'p'
                        when 271 => uart_tx_data_int <= x"5F"; -- '_'
                        when 272 => uart_tx_data_int <= x"6C"; -- 'l'
                        when 273 => uart_tx_data_int <= x"65"; -- 'e'
                        when 274 => uart_tx_data_int <= x"6E"; -- 'n'
                        when 275 => uart_tx_data_int <= x"3D"; -- '='
                        when 276 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_data_length_sampled(15 downto 12)));
                        when 277 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_data_length_sampled(11 downto 8)));
                        when 278 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_data_length_sampled(7 downto 4)));
                        when 279 => uart_tx_data_int <= nibble_to_hex(unsigned(udp_data_length_sampled(3 downto 0)));
                        when 280 => uart_tx_data_int <= x"20"; -- ' '

                        -- "udp_valid="
                        when 281 => uart_tx_data_int <= x"75"; -- 'u'
                        when 282 => uart_tx_data_int <= x"64"; -- 'd'
                        when 283 => uart_tx_data_int <= x"70"; -- 'p'
                        when 284 => uart_tx_data_int <= x"5F"; -- '_'
                        when 285 => uart_tx_data_int <= x"76"; -- 'v'
                        when 286 => uart_tx_data_int <= x"61"; -- 'a'
                        when 287 => uart_tx_data_int <= x"6C"; -- 'l'
                        when 288 => uart_tx_data_int <= x"69"; -- 'i'
                        when 289 => uart_tx_data_int <= x"64"; -- 'd'
                        when 290 => uart_tx_data_int <= x"3D"; -- '='
                        when 291 =>
                            if udp_rec_data_valid_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 292 => uart_tx_data_int <= x"20"; -- ' '

                        -- "udp_chk_err="
                        when 293 => uart_tx_data_int <= x"75"; -- 'u'
                        when 294 => uart_tx_data_int <= x"64"; -- 'd'
                        when 295 => uart_tx_data_int <= x"70"; -- 'p'
                        when 296 => uart_tx_data_int <= x"5F"; -- '_'
                        when 297 => uart_tx_data_int <= x"63"; -- 'c'
                        when 298 => uart_tx_data_int <= x"68"; -- 'h'
                        when 299 => uart_tx_data_int <= x"6B"; -- 'k'
                        when 300 => uart_tx_data_int <= x"5F"; -- '_'
                        when 301 => uart_tx_data_int <= x"65"; -- 'e'
                        when 302 => uart_tx_data_int <= x"72"; -- 'r'
                        when 303 => uart_tx_data_int <= x"72"; -- 'r'
                        when 304 => uart_tx_data_int <= x"3D"; -- '='
                        when 305 =>
                            if udp_checksum_error_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 306 => uart_tx_data_int <= x"20"; -- ' '

                        -- "tx_rst="
                        when 307 => uart_tx_data_int <= x"74"; -- 't'
                        when 308 => uart_tx_data_int <= x"78"; -- 'x'
                        when 309 => uart_tx_data_int <= x"5F"; -- '_'
                        when 310 => uart_tx_data_int <= x"72"; -- 'r'
                        when 311 => uart_tx_data_int <= x"73"; -- 's'
                        when 312 => uart_tx_data_int <= x"74"; -- 't'
                        when 313 => uart_tx_data_int <= x"3D"; -- '='
                        when 314 =>
                            if tx_reset_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 315 => uart_tx_data_int <= x"20"; -- ' '

                        -- "tx_val="
                        when 316 => uart_tx_data_int <= x"74"; -- 't'
                        when 317 => uart_tx_data_int <= x"78"; -- 'x'
                        when 318 => uart_tx_data_int <= x"5F"; -- '_'
                        when 319 => uart_tx_data_int <= x"76"; -- 'v'
                        when 320 => uart_tx_data_int <= x"61"; -- 'a'
                        when 321 => uart_tx_data_int <= x"6C"; -- 'l'
                        when 322 => uart_tx_data_int <= x"3D"; -- '='
                        when 323 =>
                            if tx_valid_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;
                        when 324 => uart_tx_data_int <= x"20"; -- ' '

                        -- "tx_pkt=XXXXXXXX" (8 hex digits for 32-bit counter)
                        when 325 => uart_tx_data_int <= x"74"; -- 't'
                        when 326 => uart_tx_data_int <= x"78"; -- 'x'
                        when 327 => uart_tx_data_int <= x"5F"; -- '_'
                        when 328 => uart_tx_data_int <= x"70"; -- 'p'
                        when 329 => uart_tx_data_int <= x"6B"; -- 'k'
                        when 330 => uart_tx_data_int <= x"74"; -- 't'
                        when 331 => uart_tx_data_int <= x"3D"; -- '='
                        when 332 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_packets_sent_sampled(31 downto 28)));
                        when 333 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_packets_sent_sampled(27 downto 24)));
                        when 334 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_packets_sent_sampled(23 downto 20)));
                        when 335 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_packets_sent_sampled(19 downto 16)));
                        when 336 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_packets_sent_sampled(15 downto 12)));
                        when 337 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_packets_sent_sampled(11 downto 8)));
                        when 338 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_packets_sent_sampled(7 downto 4)));
                        when 339 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_packets_sent_sampled(3 downto 0)));
                        when 340 => uart_tx_data_int <= x"20"; -- ' '

                        -- "tx_bcnt=" (byte count from RGMII TX)
                        when 341 => uart_tx_data_int <= x"74"; -- 't'
                        when 342 => uart_tx_data_int <= x"78"; -- 'x'
                        when 343 => uart_tx_data_int <= x"5F"; -- '_'
                        when 344 => uart_tx_data_int <= x"62"; -- 'b'
                        when 345 => uart_tx_data_int <= x"63"; -- 'c'
                        when 346 => uart_tx_data_int <= x"6E"; -- 'n'
                        when 347 => uart_tx_data_int <= x"74"; -- 't'
                        when 348 => uart_tx_data_int <= x"3D"; -- '='
                        when 349 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_byte_count_sampled(31 downto 28)));
                        when 350 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_byte_count_sampled(27 downto 24)));
                        when 351 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_byte_count_sampled(23 downto 20)));
                        when 352 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_byte_count_sampled(19 downto 16)));
                        when 353 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_byte_count_sampled(15 downto 12)));
                        when 354 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_byte_count_sampled(11 downto 8)));
                        when 355 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_byte_count_sampled(7 downto 4)));
                        when 356 => uart_tx_data_int <= nibble_to_hex(unsigned(tx_byte_count_sampled(3 downto 0)));
                        when 357 => uart_tx_data_int <= x"20"; -- ' '

                        -- "tx_seen=" (tx_valid was asserted)
                        when 358 => uart_tx_data_int <= x"74"; -- 't'
                        when 359 => uart_tx_data_int <= x"78"; -- 'x'
                        when 360 => uart_tx_data_int <= x"5F"; -- '_'
                        when 361 => uart_tx_data_int <= x"73"; -- 's'
                        when 362 => uart_tx_data_int <= x"65"; -- 'e'
                        when 363 => uart_tx_data_int <= x"65"; -- 'e'
                        when 364 => uart_tx_data_int <= x"6E"; -- 'n'
                        when 365 => uart_tx_data_int <= x"3D"; -- '='
                        when 366 => uart_tx_data_int <= x"30" when tx_valid_seen_sampled = '0' else x"31"; -- '0' or '1'
                        when 367 => uart_tx_data_int <= x"20"; -- ' '

                        -- "tx_last=" (last byte transmitted)
                        when 368 => uart_tx_data_int <= x"74"; -- 't'
                        when 369 => uart_tx_data_int <= x"78"; -- 'x'
                        when 370 => uart_tx_data_int <= x"5F"; -- '_'
                        when 371 => uart_tx_data_int <= x"6C"; -- 'l'
                        when 372 => uart_tx_data_int <= x"61"; -- 'a'
                        when 373 => uart_tx_data_int <= x"73"; -- 's'
                        when 374 => uart_tx_data_int <= x"74"; -- 't'
                        when 375 => uart_tx_data_int <= x"3D"; -- '='
                        when 376 => uart_tx_data_int <= nibble_to_hex(unsigned(last_tx_byte_sampled(7 downto 4)));
                        when 377 => uart_tx_data_int <= nibble_to_hex(unsigned(last_tx_byte_sampled(3 downto 0)));
                        when 378 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ob_msg="
                        when 379 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 380 => uart_tx_data_int <= x"62"; -- 'b'
                        when 381 => uart_tx_data_int <= x"5F"; -- '_'
                        when 382 => uart_tx_data_int <= x"6D"; -- 'm'
                        when 383 => uart_tx_data_int <= x"73"; -- 's'
                        when 384 => uart_tx_data_int <= x"67"; -- 'g'
                        when 385 => uart_tx_data_int <= x"3D"; -- '='
                        when 386 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_msg_count_sampled(31 downto 28)));
                        when 387 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_msg_count_sampled(27 downto 24)));
                        when 388 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_msg_count_sampled(23 downto 20)));
                        when 389 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_msg_count_sampled(19 downto 16)));
                        when 390 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_msg_count_sampled(15 downto 12)));
                        when 391 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_msg_count_sampled(11 downto 8)));
                        when 392 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_msg_count_sampled(7 downto 4)));
                        when 393 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_msg_count_sampled(3 downto 0)));
                        when 394 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ob_bbo="
                        when 395 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 396 => uart_tx_data_int <= x"62"; -- 'b'
                        when 397 => uart_tx_data_int <= x"5F"; -- '_'
                        when 398 => uart_tx_data_int <= x"62"; -- 'b'
                        when 399 => uart_tx_data_int <= x"62"; -- 'b'
                        when 400 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 401 => uart_tx_data_int <= x"3D"; -- '='
                        when 402 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_bbo_count_sampled(31 downto 28)));
                        when 403 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_bbo_count_sampled(27 downto 24)));
                        when 404 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_bbo_count_sampled(23 downto 20)));
                        when 405 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_bbo_count_sampled(19 downto 16)));
                        when 406 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_bbo_count_sampled(15 downto 12)));
                        when 407 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_bbo_count_sampled(11 downto 8)));
                        when 408 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_bbo_count_sampled(7 downto 4)));
                        when 409 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_bbo_count_sampled(3 downto 0)));
                        when 410 => uart_tx_data_int <= x"20"; -- ' '

                        -- "fifo_wr="
                        when 411 => uart_tx_data_int <= x"66"; -- 'f'
                        when 412 => uart_tx_data_int <= x"69"; -- 'i'
                        when 413 => uart_tx_data_int <= x"66"; -- 'f'
                        when 414 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 415 => uart_tx_data_int <= x"5F"; -- '_'
                        when 416 => uart_tx_data_int <= x"77"; -- 'w'
                        when 417 => uart_tx_data_int <= x"72"; -- 'r'
                        when 418 => uart_tx_data_int <= x"3D"; -- '='
                        when 419 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_wr_count_sampled(31 downto 28)));
                        when 420 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_wr_count_sampled(27 downto 24)));
                        when 421 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_wr_count_sampled(23 downto 20)));
                        when 422 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_wr_count_sampled(19 downto 16)));
                        when 423 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_wr_count_sampled(15 downto 12)));
                        when 424 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_wr_count_sampled(11 downto 8)));
                        when 425 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_wr_count_sampled(7 downto 4)));
                        when 426 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_wr_count_sampled(3 downto 0)));
                        when 427 => uart_tx_data_int <= x"20"; -- ' '

                        -- "fifo_rd="
                        when 428 => uart_tx_data_int <= x"66"; -- 'f'
                        when 429 => uart_tx_data_int <= x"69"; -- 'i'
                        when 430 => uart_tx_data_int <= x"66"; -- 'f'
                        when 431 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 432 => uart_tx_data_int <= x"5F"; -- '_'
                        when 433 => uart_tx_data_int <= x"72"; -- 'r'
                        when 434 => uart_tx_data_int <= x"64"; -- 'd'
                        when 435 => uart_tx_data_int <= x"3D"; -- '='
                        when 436 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_rd_count_sampled(31 downto 28)));
                        when 437 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_rd_count_sampled(27 downto 24)));
                        when 438 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_rd_count_sampled(23 downto 20)));
                        when 439 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_rd_count_sampled(19 downto 16)));
                        when 440 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_rd_count_sampled(15 downto 12)));
                        when 441 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_rd_count_sampled(11 downto 8)));
                        when 442 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_rd_count_sampled(7 downto 4)));
                        when 443 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_fifo_rd_count_sampled(3 downto 0)));
                        when 444 => uart_tx_data_int <= x"20"; -- ' '

                        -- "tx_upd="
                        when 445 => uart_tx_data_int <= x"74"; -- 't'
                        when 446 => uart_tx_data_int <= x"78"; -- 'x'
                        when 447 => uart_tx_data_int <= x"5F"; -- '_'
                        when 448 => uart_tx_data_int <= x"75"; -- 'u'
                        when 449 => uart_tx_data_int <= x"70"; -- 'p'
                        when 450 => uart_tx_data_int <= x"64"; -- 'd'
                        when 451 => uart_tx_data_int <= x"3D"; -- '='
                        when 452 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_update_count_sampled(31 downto 28)));
                        when 453 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_update_count_sampled(27 downto 24)));
                        when 454 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_update_count_sampled(23 downto 20)));
                        when 455 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_update_count_sampled(19 downto 16)));
                        when 456 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_update_count_sampled(15 downto 12)));
                        when 457 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_update_count_sampled(11 downto 8)));
                        when 458 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_update_count_sampled(7 downto 4)));
                        when 459 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_update_count_sampled(3 downto 0)));
                        when 460 => uart_tx_data_int <= x"20"; -- ' '

                        -- "st="
                        when 461 => uart_tx_data_int <= x"73"; -- 's'
                        when 462 => uart_tx_data_int <= x"74"; -- 't'
                        when 463 => uart_tx_data_int <= x"3D"; -- '='
                        when 464 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_tx_state_sampled));
                        when 465 => uart_tx_data_int <= x"20"; -- ' '

                        -- "mx=" (max state ever reached - sticky)
                        when 466 => uart_tx_data_int <= x"6D"; -- 'm'
                        when 467 => uart_tx_data_int <= x"78"; -- 'x'
                        when 468 => uart_tx_data_int <= x"3D"; -- '='
                        when 469 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_max_state_sampled));
                        when 470 => uart_tx_data_int <= x"20"; -- ' '

                        -- "rc=" (reset count - 4 hex digits)
                        when 471 => uart_tx_data_int <= x"72"; -- 'r'
                        when 472 => uart_tx_data_int <= x"63"; -- 'c'
                        when 473 => uart_tx_data_int <= x"3D"; -- '='
                        when 474 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_reset_count_sampled(15 downto 12)));
                        when 475 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_reset_count_sampled(11 downto 8)));
                        when 476 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_reset_count_sampled(7 downto 4)));
                        when 477 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_reset_count_sampled(3 downto 0)));
                        when 478 => uart_tx_data_int <= x"20"; -- ' '

                        -- "bid=" (BBO bid price - 8 hex digits for 32-bit)
                        when 479 => uart_tx_data_int <= x"62"; -- 'b'
                        when 480 => uart_tx_data_int <= x"69"; -- 'i'
                        when 481 => uart_tx_data_int <= x"64"; -- 'd'
                        when 482 => uart_tx_data_int <= x"3D"; -- '='
                        when 483 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_bid_price_sampled(31 downto 28)));
                        when 484 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_bid_price_sampled(27 downto 24)));
                        when 485 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_bid_price_sampled(23 downto 20)));
                        when 486 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_bid_price_sampled(19 downto 16)));
                        when 487 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_bid_price_sampled(15 downto 12)));
                        when 488 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_bid_price_sampled(11 downto 8)));
                        when 489 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_bid_price_sampled(7 downto 4)));
                        when 490 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_bid_price_sampled(3 downto 0)));
                        when 491 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ask=" (BBO ask price - 8 hex digits for 32-bit)
                        when 492 => uart_tx_data_int <= x"61"; -- 'a'
                        when 493 => uart_tx_data_int <= x"73"; -- 's'
                        when 494 => uart_tx_data_int <= x"6B"; -- 'k'
                        when 495 => uart_tx_data_int <= x"3D"; -- '='
                        when 496 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_price_sampled(31 downto 28)));
                        when 497 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_price_sampled(27 downto 24)));
                        when 498 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_price_sampled(23 downto 20)));
                        when 499 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_price_sampled(19 downto 16)));
                        when 500 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_price_sampled(15 downto 12)));
                        when 501 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_price_sampled(11 downto 8)));
                        when 502 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_price_sampled(7 downto 4)));
                        when 503 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_price_sampled(3 downto 0)));
                        when 504 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ask_sz=" (BBO ask size - 8 hex digits for 32-bit)
                        when 505 => uart_tx_data_int <= x"61"; -- 'a'
                        when 506 => uart_tx_data_int <= x"73"; -- 's'
                        when 507 => uart_tx_data_int <= x"6B"; -- 'k'
                        when 508 => uart_tx_data_int <= x"5F"; -- '_'
                        when 509 => uart_tx_data_int <= x"73"; -- 's'
                        when 510 => uart_tx_data_int <= x"7A"; -- 'z'
                        when 511 => uart_tx_data_int <= x"3D"; -- '='
                        when 512 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_size_sampled(31 downto 28)));
                        when 513 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_size_sampled(27 downto 24)));
                        when 514 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_size_sampled(23 downto 20)));
                        when 515 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_size_sampled(19 downto 16)));
                        when 516 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_size_sampled(15 downto 12)));
                        when 517 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_size_sampled(11 downto 8)));
                        when 518 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_size_sampled(7 downto 4)));
                        when 519 => uart_tx_data_int <= nibble_to_hex(unsigned(bbo_ask_size_sampled(3 downto 0)));
                        when 520 => uart_tx_data_int <= x"20"; -- ' '

                        -- "ask_cnt=" (Ask orders received from ITCH - 8 hex digits for 32-bit)
                        when 521 => uart_tx_data_int <= x"61"; -- 'a'
                        when 522 => uart_tx_data_int <= x"73"; -- 's'
                        when 523 => uart_tx_data_int <= x"6B"; -- 'k'
                        when 524 => uart_tx_data_int <= x"5F"; -- '_'
                        when 525 => uart_tx_data_int <= x"63"; -- 'c'
                        when 526 => uart_tx_data_int <= x"6E"; -- 'n'
                        when 527 => uart_tx_data_int <= x"74"; -- 't'
                        when 528 => uart_tx_data_int <= x"3D"; -- '='
                        when 529 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_ask_order_cnt_sampled(31 downto 28)));
                        when 530 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_ask_order_cnt_sampled(27 downto 24)));
                        when 531 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_ask_order_cnt_sampled(23 downto 20)));
                        when 532 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_ask_order_cnt_sampled(19 downto 16)));
                        when 533 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_ask_order_cnt_sampled(15 downto 12)));
                        when 534 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_ask_order_cnt_sampled(11 downto 8)));
                        when 535 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_ask_order_cnt_sampled(7 downto 4)));
                        when 536 => uart_tx_data_int <= nibble_to_hex(unsigned(ob_ask_order_cnt_sampled(3 downto 0)));

                        -- PCIe debug: " trdy=X lnk=X axis_tx=XXXXXXXX"
                        when 537 => uart_tx_data_int <= x"20"; -- ' '
                        when 538 => uart_tx_data_int <= x"74"; -- 't'
                        when 539 => uart_tx_data_int <= x"72"; -- 'r'
                        when 540 => uart_tx_data_int <= x"64"; -- 'd'
                        when 541 => uart_tx_data_int <= x"79"; -- 'y'
                        when 542 => uart_tx_data_int <= x"3D"; -- '='
                        when 543 => uart_tx_data_int <= x"30" or ("0000000" & pcie_tready_seen_sampled); -- '0' or '1'
                        when 544 => uart_tx_data_int <= x"20"; -- ' '
                        when 545 => uart_tx_data_int <= x"6C"; -- 'l'
                        when 546 => uart_tx_data_int <= x"6E"; -- 'n'
                        when 547 => uart_tx_data_int <= x"6B"; -- 'k'
                        when 548 => uart_tx_data_int <= x"3D"; -- '='
                        when 549 => uart_tx_data_int <= x"30" or ("0000000" & pcie_link_up_sampled); -- '0' or '1'
                        when 550 => uart_tx_data_int <= x"20"; -- ' '
                        when 551 => uart_tx_data_int <= x"61"; -- 'a'
                        when 552 => uart_tx_data_int <= x"78"; -- 'x'
                        when 553 => uart_tx_data_int <= x"69"; -- 'i'
                        when 554 => uart_tx_data_int <= x"73"; -- 's'
                        when 555 => uart_tx_data_int <= x"5F"; -- '_'
                        when 556 => uart_tx_data_int <= x"74"; -- 't'
                        when 557 => uart_tx_data_int <= x"78"; -- 'x'
                        when 558 => uart_tx_data_int <= x"3D"; -- '='
                        when 559 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_axis_tx_count_sampled(31 downto 28)));
                        when 560 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_axis_tx_count_sampled(27 downto 24)));
                        when 561 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_axis_tx_count_sampled(23 downto 20)));
                        when 562 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_axis_tx_count_sampled(19 downto 16)));
                        when 563 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_axis_tx_count_sampled(15 downto 12)));
                        when 564 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_axis_tx_count_sampled(11 downto 8)));
                        when 565 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_axis_tx_count_sampled(7 downto 4)));
                        when 566 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_axis_tx_count_sampled(3 downto 0)));

                        -- CDC FIFO counters: " wr=XXXXXXXX rd=XXXXXXXX"
                        when 567 => uart_tx_data_int <= x"20"; -- ' '
                        when 568 => uart_tx_data_int <= x"77"; -- 'w'
                        when 569 => uart_tx_data_int <= x"72"; -- 'r'
                        when 570 => uart_tx_data_int <= x"3D"; -- '='
                        when 571 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_wr_count_sampled(31 downto 28)));
                        when 572 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_wr_count_sampled(27 downto 24)));
                        when 573 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_wr_count_sampled(23 downto 20)));
                        when 574 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_wr_count_sampled(19 downto 16)));
                        when 575 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_wr_count_sampled(15 downto 12)));
                        when 576 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_wr_count_sampled(11 downto 8)));
                        when 577 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_wr_count_sampled(7 downto 4)));
                        when 578 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_wr_count_sampled(3 downto 0)));
                        when 579 => uart_tx_data_int <= x"20"; -- ' '
                        when 580 => uart_tx_data_int <= x"72"; -- 'r'
                        when 581 => uart_tx_data_int <= x"64"; -- 'd'
                        when 582 => uart_tx_data_int <= x"3D"; -- '='
                        when 583 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_rd_count_sampled(31 downto 28)));
                        when 584 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_rd_count_sampled(27 downto 24)));
                        when 585 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_rd_count_sampled(23 downto 20)));
                        when 586 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_rd_count_sampled(19 downto 16)));
                        when 587 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_rd_count_sampled(15 downto 12)));
                        when 588 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_rd_count_sampled(11 downto 8)));
                        when 589 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_rd_count_sampled(7 downto 4)));
                        when 590 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_cdc_rd_count_sampled(3 downto 0)));

                        -- Handshake counter (synced): " hshk=XXXXXXXX"
                        when 591 => uart_tx_data_int <= x"20"; -- ' '
                        when 592 => uart_tx_data_int <= x"68"; -- 'h'
                        when 593 => uart_tx_data_int <= x"73"; -- 's'
                        when 594 => uart_tx_data_int <= x"68"; -- 'h'
                        when 595 => uart_tx_data_int <= x"6B"; -- 'k'
                        when 596 => uart_tx_data_int <= x"3D"; -- '='
                        when 597 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_handshake_count_sampled(31 downto 28)));
                        when 598 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_handshake_count_sampled(27 downto 24)));
                        when 599 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_handshake_count_sampled(23 downto 20)));
                        when 600 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_handshake_count_sampled(19 downto 16)));
                        when 601 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_handshake_count_sampled(15 downto 12)));
                        when 602 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_handshake_count_sampled(11 downto 8)));
                        when 603 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_handshake_count_sampled(7 downto 4)));
                        when 604 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_handshake_count_sampled(3 downto 0)));

                        -- CDC FIFO empty flag: " emp=X"
                        when 605 => uart_tx_data_int <= x"20"; -- ' '
                        when 606 => uart_tx_data_int <= x"65"; -- 'e'
                        when 607 => uart_tx_data_int <= x"6D"; -- 'm'
                        when 608 => uart_tx_data_int <= x"70"; -- 'p'
                        when 609 => uart_tx_data_int <= x"3D"; -- '='
                        when 610 =>
                            if pcie_cdc_empty_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;

                        -- Stream ready flag: " rdy=X"
                        when 611 => uart_tx_data_int <= x"20"; -- ' '
                        when 612 => uart_tx_data_int <= x"72"; -- 'r'
                        when 613 => uart_tx_data_int <= x"64"; -- 'd'
                        when 614 => uart_tx_data_int <= x"79"; -- 'y'
                        when 615 => uart_tx_data_int <= x"3D"; -- '='
                        when 616 =>
                            if pcie_stream_ready_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;

                        -- Current tready: " tr=X"
                        when 617 => uart_tx_data_int <= x"20"; -- ' '
                        when 618 => uart_tx_data_int <= x"74"; -- 't'
                        when 619 => uart_tx_data_int <= x"72"; -- 'r'
                        when 620 => uart_tx_data_int <= x"3D"; -- '='
                        when 621 =>
                            if pcie_tready_now_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;

                        -- Current tvalid: " tv=X"
                        when 622 => uart_tx_data_int <= x"20"; -- ' '
                        when 623 => uart_tx_data_int <= x"74"; -- 't'
                        when 624 => uart_tx_data_int <= x"76"; -- 'v'
                        when 625 => uart_tx_data_int <= x"3D"; -- '='
                        when 626 =>
                            if pcie_tvalid_now_sampled = '0' then
                                uart_tx_data_int <= x"30"; -- '0'
                            else
                                uart_tx_data_int <= x"31"; -- '1'
                            end if;

                        -- State machine state: " st=X" (0=IDLE, 1-6=BEAT1-6)
                        when 627 => uart_tx_data_int <= x"20"; -- ' '
                        when 628 => uart_tx_data_int <= x"73"; -- 's'
                        when 629 => uart_tx_data_int <= x"74"; -- 't'
                        when 630 => uart_tx_data_int <= x"3D"; -- '='
                        when 631 =>
                            -- State 0-7 as ASCII '0'-'7' (3-bit state: 0=IDLE, 1-7=BEAT1-7, BEAT8=0)
                            uart_tx_data_int <= x"30" or ("00000" & pcie_axi_state_sampled);

                        -- FIFO write input data: " wi=XXXX" (first 2 bytes of symbol going in)
                        -- Should show "TE" = 0x5445 for "TESTAAPL", garbage otherwise
                        when 632 => uart_tx_data_int <= x"20"; -- ' '
                        when 633 => uart_tx_data_int <= x"77"; -- 'w'
                        when 634 => uart_tx_data_int <= x"69"; -- 'i'
                        when 635 => uart_tx_data_int <= x"3D"; -- '='
                        when 636 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_fifo_wr_data_sampled(15 downto 12)));
                        when 637 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_fifo_wr_data_sampled(11 downto 8)));
                        when 638 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_fifo_wr_data_sampled(7 downto 4)));
                        when 639 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_fifo_wr_data_sampled(3 downto 0)));

                        -- FIFO read output data: " ro=XXXX" (first 2 bytes of symbol coming out)
                        when 640 => uart_tx_data_int <= x"20"; -- ' '
                        when 641 => uart_tx_data_int <= x"72"; -- 'r'
                        when 642 => uart_tx_data_int <= x"6F"; -- 'o'
                        when 643 => uart_tx_data_int <= x"3D"; -- '='
                        when 644 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_fifo_rd_data_sampled(15 downto 12)));
                        when 645 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_fifo_rd_data_sampled(11 downto 8)));
                        when 646 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_fifo_rd_data_sampled(7 downto 4)));
                        when 647 => uart_tx_data_int <= nibble_to_hex(unsigned(pcie_fifo_rd_data_sampled(3 downto 0)));

                        -- "\r\n"
                        when 648 => uart_tx_data_int <= x"0D"; -- '\r'
                        when 649 => uart_tx_data_int <= x"0A"; -- '\n'
                        ----- ALWAYS REMEMBER TO UPDATE THE LAST CHARACTER INDEX  WHEN ADDING NEW CHARACTERS -----
                        ----- THAT SAVES 30 MINUTES OF BUILDING TIME!

                        when others =>
                            debug_state <= IDLE;
                            debug_char_index <= (others => '0');
                            uart_tx_start_int <= '0';
                            uart_tx_data_int <= (others => '0');
                    end case;

                    -- Check if UART is ready and send
                    if uart_tx_busy = '0' then
                        if debug_char_index <= to_unsigned(649, 10) then
                            uart_tx_start_int <= '1';
                            debug_state <= WAIT_BUSY;
                        else
                            debug_state <= IDLE;
                            debug_char_index <= (others => '0');
                            uart_tx_start_int <= '0';
                            uart_tx_data_int <= (others => '0');
                        end if;
                    else
                        uart_tx_start_int <= '0';
                    end if;

                when WAIT_BUSY =>
                    uart_tx_start_int <= '0';
                    if uart_tx_busy = '0' then
                        if debug_char_index < to_unsigned(649, 10) then
                            debug_char_index <= debug_char_index + 1;
                            debug_state <= SEND_CHAR;
                        else
                            debug_state <= IDLE;
                            debug_char_index <= (others => '0');
                            uart_tx_data_int <= (others => '0');
                        end if;
                    end if;

            end case;
        end if;
    end process;

    -- Output assignments
    uart_tx_data <= uart_tx_data_int;
    uart_tx_start <= uart_tx_start_int;

end Behavioral;
