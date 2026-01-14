--------------------------------------------------------------------------------
-- Module: udp_parser_rgmii
-- Description: RGMII-compatible UDP parser with sequential byte processing
--              Ported from AX7203 demo udp_rx.v (proven RGMII implementation)
--              Adapted for direct payload streaming (no RAM buffer)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity udp_parser_rgmii is
    Port (
        clk                     : in  STD_LOGIC;
        rst_n                   : in  STD_LOGIC;

        -- Input from IP parser
        udp_rx_data             : in  STD_LOGIC_VECTOR(7 downto 0);
        udp_rx_req              : in  STD_LOGIC;

        -- IP layer status
        mac_rec_error           : in  STD_LOGIC;
        net_protocol            : in  STD_LOGIC_VECTOR(7 downto 0);
        ip_rec_source_addr      : in  STD_LOGIC_VECTOR(31 downto 0);
        ip_rec_destination_addr : in  STD_LOGIC_VECTOR(31 downto 0);
        ip_checksum_error       : in  STD_LOGIC;
        ip_addr_check_error     : in  STD_LOGIC;
        upper_layer_data_length : in  STD_LOGIC_VECTOR(15 downto 0);

        -- UDP header fields
        udp_src_port            : out STD_LOGIC_VECTOR(15 downto 0);
        udp_dst_port            : out STD_LOGIC_VECTOR(15 downto 0);
        udp_data_length         : out STD_LOGIC_VECTOR(15 downto 0);

        -- Payload output (direct streaming)
        udp_payload_data        : out STD_LOGIC_VECTOR(7 downto 0);
        udp_payload_valid       : out STD_LOGIC;
        udp_payload_start       : out STD_LOGIC;
        udp_payload_end         : out STD_LOGIC;

        -- Status
        udp_rec_data_valid      : out STD_LOGIC;
        udp_checksum_error_out  : out STD_LOGIC
    );
end udp_parser_rgmii;

architecture Behavioral of udp_parser_rgmii is

    -- State machine
    type state_type is (
        IDLE,
        REC_HEAD,
        REC_DATA,
        REC_ODD_DATA,
        VERIFY_CHECKSUM,
        REC_ERROR,
        REC_END_WAIT,
        REC_END
    );
    signal state, next_state : state_type;

    -- Sequential counter (RGMII-compatible)
    signal udp_rx_cnt : unsigned(15 downto 0);

    -- UDP header fields
    signal udp_data_length_int  : unsigned(15 downto 0);
    signal udp_src_port_reg     : STD_LOGIC_VECTOR(15 downto 0);
    signal udp_dst_port_reg     : STD_LOGIC_VECTOR(15 downto 0);

    -- Data pipeline (udp_rx_data_d0 needed for checksum calculation - combines previous+current byte)
    signal udp_rx_data_d0       : STD_LOGIC_VECTOR(7 downto 0);

    -- Status signals
    signal verify_end           : STD_LOGIC;
    signal udp_checksum_error   : STD_LOGIC;

    -- Checksum verification
    signal checksum_tmp0        : unsigned(16 downto 0);
    signal checksum_tmp1        : unsigned(16 downto 0);
    signal checksum_tmp2        : unsigned(16 downto 0);
    signal checksum_tmp3        : unsigned(17 downto 0);
    signal checksum_tmp4        : unsigned(18 downto 0);
    signal checksum_tmp5        : unsigned(31 downto 0);
    signal checksum_buf         : unsigned(31 downto 0);
    signal check_out            : unsigned(31 downto 0);
    signal checkout_buf         : unsigned(31 downto 0);
    signal checksum             : unsigned(15 downto 0);
    signal checksum_cnt         : unsigned(2 downto 0);

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

    -- UDP port filtering for ITCH (defense in depth)
    constant ITCH_UDP_PORT : unsigned(15 downto 0) := to_unsigned(12345, 16);
    signal port_is_itch : STD_LOGIC;

    -- Internal payload signals (before filtering)
    signal udp_payload_valid_int : STD_LOGIC;
    signal udp_payload_start_int : STD_LOGIC;
    signal udp_payload_end_int : STD_LOGIC;

begin

    -- =========================================================================
    -- UDP Port Filtering (125MHz RGMII domain)
    -- Only pass ITCH packets (port 12345) to upper layers
    -- Purely combinational - no registered state to avoid timing issues
    -- =========================================================================
    -- Check if UDP destination port matches ITCH port (use internal reg, not output)
    port_is_itch <= '1' when unsigned(udp_dst_port_reg) = ITCH_UDP_PORT else '0';

    -- Filter payload signals: only pass through if destination port is 12345
    udp_payload_valid <= udp_payload_valid_int when port_is_itch = '1' else '0';
    udp_payload_start <= udp_payload_start_int when port_is_itch = '1' else '0';
    udp_payload_end   <= udp_payload_end_int when port_is_itch = '1' else '0';


    -- Output assignments
    udp_data_length <= std_logic_vector(udp_data_length_int);
    udp_src_port <= udp_src_port_reg;
    udp_dst_port <= udp_dst_port_reg;
    udp_checksum_error_out <= udp_checksum_error;

    -- State machine register
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state <= IDLE;
        elsif rising_edge(clk) then
            state <= next_state;
        end if;
    end process;

    -- State machine logic
    process(state, udp_rx_req, ip_checksum_error, udp_rx_cnt, udp_data_length_int,
            ip_addr_check_error, udp_checksum_error, verify_end)
    begin
        case state is
            when IDLE =>
                if udp_rx_req = '1' then
                    next_state <= REC_HEAD;
                else
                    next_state <= IDLE;
                end if;

            when REC_HEAD =>
                if ip_checksum_error = '1' then
                    next_state <= REC_ERROR;
                elsif udp_rx_cnt = 7 then
                    if udp_data_length_int = 9 then
                        next_state <= REC_ODD_DATA;
                    else
                        next_state <= REC_DATA;
                    end if;
                elsif ip_addr_check_error = '1' then
                    next_state <= REC_ERROR;
                else
                    next_state <= REC_HEAD;
                end if;

            when REC_DATA =>
                if ip_checksum_error = '1' then
                    next_state <= REC_ERROR;
                elsif udp_data_length_int(0) = '1' and udp_rx_cnt = udp_data_length_int - 2 then
                    next_state <= REC_ODD_DATA;
                elsif udp_data_length_int(0) = '0' and udp_rx_cnt = udp_data_length_int - 1 then
                    next_state <= VERIFY_CHECKSUM;
                else
                    next_state <= REC_DATA;
                end if;

            when REC_ODD_DATA =>
                if ip_checksum_error = '1' then
                    next_state <= REC_ERROR;
                elsif udp_rx_cnt = udp_data_length_int - 1 then
                    next_state <= VERIFY_CHECKSUM;
                else
                    next_state <= REC_ODD_DATA;
                end if;

            when VERIFY_CHECKSUM =>
                if udp_checksum_error = '1' then
                    next_state <= REC_ERROR;
                elsif verify_end = '1' then
                    next_state <= REC_END_WAIT;
                elsif udp_rx_cnt = 65535 then
                    next_state <= IDLE;
                else
                    next_state <= VERIFY_CHECKSUM;
                end if;

            when REC_ERROR =>
                next_state <= IDLE;

            when REC_END_WAIT =>
                if udp_rx_cnt = 63 then
                    next_state <= REC_END;
                else
                    next_state <= REC_END_WAIT;
                end if;

            when REC_END =>
                next_state <= IDLE;

            when others =>
                next_state <= IDLE;
        end case;
    end process;

    -- Payload output control
    -- CRITICAL TIMING: Registered outputs lag by 1 cycle!
    -- Assert when udp_rx_cnt=7 in REC_HEAD so outputs become '1' when udp_rx_cnt=8 in REC_DATA
    -- This synchronizes the registered control signals with the combinational udp_payload_data
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_payload_valid_int <= '0';
        elsif rising_edge(clk) then
            -- Assert one cycle BEFORE first payload byte to compensate for register delay
            -- When state=REC_HEAD and cnt=7, outputs will be visible when state=REC_DATA and cnt=8
            if (state = REC_HEAD and udp_rx_cnt = 7) or
               ((state = REC_DATA or state = REC_ODD_DATA) and udp_rx_cnt >= 8 and udp_rx_cnt < udp_data_length_int) then
                udp_payload_valid_int <= '1';
            else
                udp_payload_valid_int <= '0';
            end if;
        end if;
    end process;

    -- Payload start pulse
    -- Assert when udp_rx_cnt=7 in REC_HEAD so output becomes '1' when udp_rx_cnt=8 in REC_DATA
    -- This ensures start/valid are both high when first payload byte is on udp_payload_data
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_payload_start_int <= '0';
        elsif rising_edge(clk) then
            if state = REC_HEAD and udp_rx_cnt = 7 then
                udp_payload_start_int <= '1';
            else
                udp_payload_start_int <= '0';
            end if;
        end if;
    end process;

    -- Payload end pulse
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_payload_end_int <= '0';
        elsif rising_edge(clk) then
            if (state = REC_DATA or state = REC_ODD_DATA) and
               udp_rx_cnt = udp_data_length_int - 1 then
                udp_payload_end_int <= '1';
            else
                udp_payload_end_int <= '0';
            end if;
        end if;
    end process;

    -- Payload data output (use udp_rx_data directly - no delay needed)
    -- udp_rx_data_d0 is only needed for checksum calculation (combines previous+current byte)
    -- For payload, udp_rx_data is used directly to align with udp_payload_valid
    udp_payload_data <= udp_rx_data;

    -- IP address check - use directly (same clock domain, no delay needed)
    -- Both IP and UDP parsers run on same RGMII clock - no delay required
    -- Use ip_addr_check_error directly in state machine

    -- UDP data length
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_data_length_int <= (others => '0');
        elsif rising_edge(clk) then
            if state = IDLE then
                udp_data_length_int <= unsigned(upper_layer_data_length);
            end if;
        end if;
    end process;

    -- Sequential counter
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_rx_cnt <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEAD or state = REC_DATA or state = REC_END_WAIT then
                udp_rx_cnt <= udp_rx_cnt + 1;
            else
                udp_rx_cnt <= (others => '0');
            end if;
        end if;
    end process;

    -- Data pipeline
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_rx_data_d0 <= (others => '0');
        elsif rising_edge(clk) then
            udp_rx_data_d0 <= udp_rx_data;
        end if;
    end process;

    -- UDP header parsing: Source port
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_src_port_reg <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEAD and udp_rx_cnt = 0 then
                udp_src_port_reg(15 downto 8) <= udp_rx_data;
            elsif state = REC_HEAD and udp_rx_cnt = 1 then
                udp_src_port_reg(7 downto 0) <= udp_rx_data;
            end if;
        end if;
    end process;

    -- UDP header parsing: Destination port
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_dst_port_reg <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEAD and udp_rx_cnt = 2 then
                udp_dst_port_reg(15 downto 8) <= udp_rx_data;
            elsif state = REC_HEAD and udp_rx_cnt = 3 then
                udp_dst_port_reg(7 downto 0) <= udp_rx_data;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- Checksum verification (UDP pseudo-header + UDP header + payload)
    ------------------------------------------------------------------------

    -- Pseudo-header checksum (IP addresses + protocol + length)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            checksum_tmp0 <= (others => '0');
            checksum_tmp1 <= (others => '0');
            checksum_tmp2 <= (others => '0');
            checksum_tmp3 <= (others => '0');
            checksum_tmp4 <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEAD then
                checksum_tmp0 <= resize(unsigned(ip_rec_source_addr(31 downto 16)), 17) +
                                resize(unsigned(ip_rec_source_addr(15 downto 0)), 17);
                checksum_tmp1 <= resize(unsigned(ip_rec_destination_addr(31 downto 16)), 17) +
                                resize(unsigned(ip_rec_destination_addr(15 downto 0)), 17);
                checksum_tmp2 <= resize(unsigned(x"00" & net_protocol), 17) +
                                resize(udp_data_length_int, 17);
                checksum_tmp3 <= resize(checksum_tmp0, 18) + resize(checksum_tmp1, 18);
                checksum_tmp4 <= resize(checksum_tmp2, 19) + resize(checksum_tmp3, 19);
            elsif state = IDLE then
                checksum_tmp0 <= (others => '0');
                checksum_tmp1 <= (others => '0');
                checksum_tmp2 <= (others => '0');
                checksum_tmp3 <= (others => '0');
                checksum_tmp4 <= (others => '0');
            end if;
        end if;
    end process;

    -- UDP header + payload checksum
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            checksum_tmp5 <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEAD or state = REC_DATA then
                if udp_rx_cnt(0) = '1' then
                    checksum_tmp5 <= checksum_adder(
                        resize(unsigned(udp_rx_data_d0 & udp_rx_data), 32),
                        checksum_buf
                    );
                end if;
            elsif state = REC_ODD_DATA then
                checksum_tmp5 <= checksum_adder(
                    resize(unsigned(udp_rx_data & x"00"), 32),
                    checksum_tmp5
                );
            elsif state = IDLE then
                checksum_tmp5 <= (others => '0');
            end if;
        end if;
    end process;

    -- Checksum counter
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            checksum_cnt <= (others => '0');
        elsif rising_edge(clk) then
            if state = VERIFY_CHECKSUM then
                checksum_cnt <= checksum_cnt + 1;
            else
                checksum_cnt <= (others => '0');
            end if;
        end if;
    end process;

    -- Final checksum calculation
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            check_out <= (others => '0');
        elsif rising_edge(clk) then
            if state = VERIFY_CHECKSUM then
                if checksum_cnt = 0 then
                    check_out <= checksum_adder(
                        resize(checksum_tmp4, 32),
                        checksum_tmp5
                    );
                elsif checksum_cnt = 1 then
                    check_out <= checksum_out_fn(check_out);
                elsif checksum_cnt = 2 then
                    check_out <= checksum_out_fn(check_out);
                end if;
            end if;
        end if;
    end process;

    -- Checksum buffer
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            checksum_buf <= (others => '0');
        elsif rising_edge(clk) then
            if state = REC_HEAD or state = REC_DATA then
                checksum_buf <= checksum_tmp5;
            else
                checksum_buf <= (others => '0');
            end if;
        end if;
    end process;

    -- Checkout buffer
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            checkout_buf <= (others => '0');
        elsif rising_edge(clk) then
            if state = VERIFY_CHECKSUM then
                checkout_buf <= check_out;
            else
                checkout_buf <= (others => '0');
            end if;
        end if;
    end process;

    checksum <= not checkout_buf(15 downto 0);

    -- Checksum error and verify_end
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_checksum_error <= '0';
            verify_end <= '0';
        elsif rising_edge(clk) then
            if state = VERIFY_CHECKSUM and checksum_cnt = 4 then
                if checksum = 0 then
                    udp_checksum_error <= '0';
                    verify_end <= '1';
                else
                    udp_checksum_error <= '1';
                    verify_end <= '0';
                end if;
            else
                udp_checksum_error <= '0';
                verify_end <= '0';
            end if;
        end if;
    end process;

    -- UDP receive data valid
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            udp_rec_data_valid <= '0';
        elsif rising_edge(clk) then
            if state = REC_END_WAIT then
                udp_rec_data_valid <= '0';
            elsif state = REC_END then
                if mac_rec_error = '1' then
                    udp_rec_data_valid <= '0';
                else
                    udp_rec_data_valid <= '1';
                end if;
            end if;
        end if;
    end process;

end Behavioral;
