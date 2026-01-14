--------------------------------------------------------------------------------
-- Module: ip_parser_rgmii
-- Description: RGMII-compatible IP parser with sequential byte processing
--              Ported from AX7203 demo ip_rx.v (proven RGMII implementation)
--              Uses local sequential counter instead of byte_index for timing
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ip_parser_rgmii is
    Port (
        clk                         : in  STD_LOGIC;
        rst_n                       : in  STD_LOGIC;

        -- Configuration
        local_ip_addr               : in  STD_LOGIC_VECTOR(31 downto 0);
        local_mac_addr              : in  STD_LOGIC_VECTOR(47 downto 0);

        -- Input from MAC parser
        ip_rx_data                  : in  STD_LOGIC_VECTOR(7 downto 0);
        ip_rx_req                   : in  STD_LOGIC;
        mac_rx_destination_mac_addr : in  STD_LOGIC_VECTOR(47 downto 0);

        -- Output to upper layer parsers
        udp_rx_req                  : out STD_LOGIC;
        icmp_rx_req                 : out STD_LOGIC;
        ip_addr_check_error         : out STD_LOGIC;

        -- IP header fields
        upper_layer_data_length     : out STD_LOGIC_VECTOR(15 downto 0);
        ip_total_data_length        : out STD_LOGIC_VECTOR(15 downto 0);
        net_protocol                : out STD_LOGIC_VECTOR(7 downto 0);
        ip_rec_source_addr          : out STD_LOGIC_VECTOR(31 downto 0);
        ip_rec_destination_addr     : out STD_LOGIC_VECTOR(31 downto 0);

        -- Status
        ip_rx_end                   : out STD_LOGIC;
        ip_checksum_error           : out STD_LOGIC
    );
end ip_parser_rgmii;

architecture Behavioral of ip_parser_rgmii is

    -- State machine
    type state_type is (IDLE, REC_HEADER0, REC_HEADER1, REC_DATA, REC_END);
    signal state, next_state : state_type;
    signal state_prev : state_type := IDLE;

    -- Sequential counter (RGMII-compatible)
    signal ip_rx_cnt : unsigned(15 downto 0);

    -- IP header fields
    signal ip_rec_data_length : unsigned(15 downto 0);
    signal header_length_buf  : unsigned(3 downto 0);
    signal header_length      : unsigned(5 downto 0);

    -- Data pipeline (ip_rx_data_d0 needed for checksum calculation - combines previous+current byte)
    signal ip_rx_data_d0      : STD_LOGIC_VECTOR(7 downto 0);

    -- Internal registers
    signal ip_rec_checksum           : STD_LOGIC_VECTOR(15 downto 0);
    signal ip_total_data_length_reg  : unsigned(15 downto 0);
    signal net_protocol_reg          : STD_LOGIC_VECTOR(7 downto 0);
    signal ip_rec_source_addr_reg    : STD_LOGIC_VECTOR(31 downto 0);
    signal ip_rec_destination_addr_reg : STD_LOGIC_VECTOR(31 downto 0);
    signal ip_checksum_error_reg     : STD_LOGIC;
    signal ip_rx_end_reg             : STD_LOGIC;

    -- Checksum verification
    signal checksum_tmp     : unsigned(31 downto 0);
    signal checksum_buf     : unsigned(31 downto 0);
    signal check_out        : unsigned(31 downto 0);
    signal checkout_buf     : unsigned(31 downto 0);
    signal checksum         : unsigned(15 downto 0);
    signal checksum_cnt     : unsigned(2 downto 0);

    -- Functions for checksum calculation
    function checksum_adder(dataina : unsigned(31 downto 0);
                           datainb : unsigned(31 downto 0))
                           return unsigned is
    begin
        return dataina + datainb;
    end function;

    function checksum_out_fn(dataina : unsigned(31 downto 0))
                            return unsigned is
    begin
        return resize(dataina(15 downto 0), 32) + resize(dataina(31 downto 16), 32);
    end function;

begin

    -- Calculate header length (IHL * 4)
    header_length <= resize(header_length_buf & "00", 6);  -- multiply by 4

    -- State machine register
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state <= IDLE;
            state_prev <= IDLE;
        elsif rising_edge(clk) then
            state_prev <= state;
            state <= next_state;
        end if;
    end process;

    -- State machine logic
    process(state, ip_rx_req, ip_rx_cnt, header_length, ip_checksum_error_reg, ip_rx_end_reg)
    begin
        case state is
            when IDLE =>
                if ip_rx_req = '1' then
                    next_state <= REC_HEADER0;
                else
                    next_state <= IDLE;
                end if;

            when REC_HEADER0 =>
                if ip_rx_cnt = 3 then
                    next_state <= REC_HEADER1;
                else
                    next_state <= REC_HEADER0;
                end if;

            when REC_HEADER1 =>
                if ip_rx_cnt = header_length - 1 then
                    next_state <= REC_DATA;
                else
                    next_state <= REC_HEADER1;
                end if;

            when REC_DATA =>
                if ip_checksum_error_reg = '1' or ip_rx_end_reg = '1' then
                    next_state <= REC_END;
                elsif ip_rx_cnt = 65535 then
                    next_state <= REC_END;
                else
                    next_state <= REC_DATA;
                end if;

            when REC_END =>
                next_state <= IDLE;

            when others =>
                next_state <= IDLE;
        end case;
    end process;

    -- IP RX end signal
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_rx_end_reg <= '0';
        elsif rising_edge(clk) then
            if state = REC_DATA and ip_rx_cnt = ip_total_data_length_reg - 2 then
                ip_rx_end_reg <= '1';
            else
                ip_rx_end_reg <= '0';
            end if;
        end if;
    end process;

    -- Assign internal signal to output
    ip_rx_end <= ip_rx_end_reg;

    -- MAC/IP address check
    -- If local_ip_addr = 0.0.0.0, accept all IPs (accept all mode)
    -- Broadcast MAC (FF:FF:FF:FF:FF:FF): accept all packets
    -- Multicast MAC (01:00:5E:xx:xx:xx): accept if destination IP matches
    -- Unicast MAC: both MAC and IP must match
    -- Note: Check happens after IP destination address is captured (at end of REC_HEADER1 or start of REC_DATA)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_addr_check_error <= '0';
        elsif rising_edge(clk) then
            -- Perform check in REC_DATA state (after IP destination address is fully captured and stable)
            -- CRITICAL: Must check in REC_DATA, not REC_HEADER1, because signal updates happen on next clock cycle
            if state = REC_DATA then
                -- Accept all mode: if local_ip_addr is 0.0.0.0, accept any destination IP
                if local_ip_addr = x"00000000" then
                    -- Accept all IPs when in accept-all mode
                    ip_addr_check_error <= '0';
                -- Broadcast MAC: accept all packets (no IP check needed for broadcast)
                elsif mac_rx_destination_mac_addr = x"FFFFFFFFFFFF" then
                    ip_addr_check_error <= '0';
                -- Multicast MAC (01:00:5E:xx:xx:xx): accept all multicast for ITCH feeds
                elsif mac_rx_destination_mac_addr(47 downto 24) = x"01005E" then
                    ip_addr_check_error <= '0';
                -- Unicast MAC: check both MAC and IP match
                elsif mac_rx_destination_mac_addr = local_mac_addr and
                      ip_rec_destination_addr_reg = local_ip_addr then
                    ip_addr_check_error <= '0';
                else
                    ip_addr_check_error <= '1';
                end if;
            else
                -- Outside REC_DATA: default to no error (accept)
                ip_addr_check_error <= '0';
            end if;
        end if;
    end process;

    -- Generate UDP RX request
    -- Assert early (at header_length-2) so UDP parser has time to transition and be ready for UDP byte 0
    -- Similar to ip_rx_req early assertion in MAC parser to avoid timing offset
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_rx_req <= '0';
        elsif rising_edge(clk) then
            if ((state = REC_HEADER1 and ip_rx_cnt >= header_length - 2) or state = REC_DATA) and net_protocol_reg = x"11" then
                udp_rx_req <= '1';
            else
                udp_rx_req <= '0';
            end if;
        end if;
    end process;

    -- Generate ICMP RX request
    -- Hold high during REC_DATA so it's captured when FIFO write happens at ip_rx_end
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            icmp_rx_req <= '0';
        elsif rising_edge(clk) then
            if ((state = REC_HEADER1 and ip_rx_cnt = header_length - 1) or state = REC_DATA) and net_protocol_reg = x"01" then
                icmp_rx_req <= '1';
            else
                icmp_rx_req <= '0';
            end if;
        end if;
    end process;

    -- Upper layer data length
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            upper_layer_data_length <= (others => '0');
        elsif rising_edge(clk) then
            upper_layer_data_length <= std_logic_vector(ip_rec_data_length - header_length);
        end if;
    end process;

    -- Data pipeline register (needed for checksum calculation - combines previous+current byte)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_rx_data_d0 <= (others => '0');
        elsif rising_edge(clk) then
            ip_rx_data_d0 <= ip_rx_data;
        end if;
    end process;

    -- Sequential counter (RGMII timing)
    -- Counter increments when in REC_HEADER0/REC_HEADER1/REC_DATA states
    -- Counter represents the byte position in the IP header (0 = first byte)
    -- When ip_rx_req goes high, ip_rx_data already contains byte 0, so it is captured at counter 0
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_rx_cnt <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEADER0 or state = REC_HEADER1 or state = REC_DATA then
                -- When entering REC_HEADER0 from IDLE, ip_rx_data contains byte 0
                -- Set counter to 0 to capture byte 0, then increment on next cycle
                if state = REC_HEADER0 and state_prev = IDLE then
                    ip_rx_cnt <= (others => '0');  -- Capture byte 0 at counter 0
                else
                    ip_rx_cnt <= ip_rx_cnt + 1;  -- Increment for next byte
                end if;
            else
                ip_rx_cnt <= (others => '0');
            end if;
        end if;
    end process;

    -- Total data length
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_total_data_length_reg <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEADER1 then
                if ip_rec_data_length < 46 then
                    ip_total_data_length_reg <= to_unsigned(46, 16);
                else
                    ip_total_data_length_reg <= ip_rec_data_length;
                end if;
            end if;
        end if;
    end process;

    ip_total_data_length <= std_logic_vector(ip_total_data_length_reg);

    -- IP header length (IHL) - byte 0, lower 4 bits
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            header_length_buf <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEADER0 and ip_rx_cnt = 0 then
                header_length_buf <= unsigned(ip_rx_data(3 downto 0));
            end if;
        end if;
    end process;

    -- IP total data length field (bytes 2-3 of IP header)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_rec_data_length <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEADER0 and ip_rx_cnt = 2 then
                ip_rec_data_length(15 downto 8) <= unsigned(ip_rx_data);
            elsif state = REC_HEADER0 and ip_rx_cnt = 3 then
                ip_rec_data_length(7 downto 0) <= unsigned(ip_rx_data);
            end if;
        end if;
    end process;

    -- Network protocol (byte 9 of IP header, 0-indexed)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            net_protocol_reg <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEADER1 and ip_rx_cnt = 9 then
                net_protocol_reg <= ip_rx_data;
            end if;
        end if;
    end process;

    net_protocol <= net_protocol_reg;

    -- IP source address (bytes 12-15 of IP header, 0-indexed)
    -- Network byte order: MSB first (byte 12 = bits 31-24, byte 15 = bits 7-0)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_rec_source_addr_reg <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEADER1 and ip_rx_cnt = 12 then
                ip_rec_source_addr_reg(31 downto 24) <= ip_rx_data;  -- MSB
            elsif state = REC_HEADER1 and ip_rx_cnt = 13 then
                ip_rec_source_addr_reg(23 downto 16) <= ip_rx_data;
            elsif state = REC_HEADER1 and ip_rx_cnt = 14 then
                ip_rec_source_addr_reg(15 downto 8) <= ip_rx_data;
            elsif state = REC_HEADER1 and ip_rx_cnt = 15 then
                ip_rec_source_addr_reg(7 downto 0) <= ip_rx_data;  -- LSB
            end if;
        end if;
    end process;

    ip_rec_source_addr <= ip_rec_source_addr_reg;

    -- IP destination address (bytes 16-19 of IP header, 0-indexed)
    -- Network byte order: MSB first (byte 16 = bits 31-24, byte 19 = bits 7-0)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_rec_destination_addr_reg <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEADER1 and ip_rx_cnt = 16 then
                ip_rec_destination_addr_reg(31 downto 24) <= ip_rx_data;  -- MSB
            elsif state = REC_HEADER1 and ip_rx_cnt = 17 then
                ip_rec_destination_addr_reg(23 downto 16) <= ip_rx_data;
            elsif state = REC_HEADER1 and ip_rx_cnt = 18 then
                ip_rec_destination_addr_reg(15 downto 8) <= ip_rx_data;
            elsif state = REC_HEADER1 and ip_rx_cnt = 19 then
                ip_rec_destination_addr_reg(7 downto 0) <= ip_rx_data;  -- LSB
            end if;
        end if;
    end process;

    ip_rec_destination_addr <= ip_rec_destination_addr_reg;

    ------------------------------------------------------------------------
    -- Checksum verification
    ------------------------------------------------------------------------

    -- Checksum accumulation
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            checksum_tmp <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEADER0 or state = REC_HEADER1 then
                if ip_rx_cnt(0) = '1' then  -- Odd count: combine two bytes
                    checksum_tmp <= checksum_adder(
                        unsigned(ip_rx_data_d0 & ip_rx_data),
                        checksum_buf
                    );
                end if;
            elsif state = IDLE then
                checksum_tmp <= (others => '0');
            end if;
        end if;
    end process;

    -- Checksum output calculation
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            check_out <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_DATA then
                check_out <= checksum_out_fn(checksum_tmp);
            end if;
        end if;
    end process;

    -- Checksum counter
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            checksum_cnt <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_DATA then
                if checksum_cnt = 7 then
                    checksum_cnt <= checksum_cnt;
                else
                    checksum_cnt <= checksum_cnt + 1;
                end if;
            else
                checksum_cnt <= (others => '0');
            end if;
        end if;
    end process;

    -- Checksum buffer
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            checksum_buf <= (others => '0');
        elsif rising_edge(clk) then
            checksum_buf <= checksum_tmp;
        end if;
    end process;

    -- Checkout buffer
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            checkout_buf <= (others => '0');
        elsif rising_edge(clk) then
            checkout_buf <= check_out;
        end if;
    end process;

    checksum <= not checkout_buf(15 downto 0);

    -- Checksum error detection
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_checksum_error_reg <= '0';
        elsif rising_edge(clk) then
            if state = REC_DATA and checksum_cnt = 2 then
                if checksum = 0 then
                    ip_checksum_error_reg <= '0';
                else
                    ip_checksum_error_reg <= '1';
                end if;
            else
                ip_checksum_error_reg <= '0';
            end if;
        end if;
    end process;

    -- Assign internal signal to output
    ip_checksum_error <= ip_checksum_error_reg;

end Behavioral;
