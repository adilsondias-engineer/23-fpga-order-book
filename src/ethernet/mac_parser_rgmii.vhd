----------------------------------------------------------------------------------
-- MAC Parser RGMII (converted from vendor demo mac_rx.v)
-- Description: RGMII-compatible MAC parser with CRC verification
-- Ported from AX7203 demo mac_rx.v (proven RGMII implementation)
-- Initially without MAC filtering (will be added after parsing works)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mac_parser_rgmii is
    Generic (
        CRC_BYPASS                  : boolean := true  -- Bypass CRC checking (for debugging)
    );
    Port (
        clk                         : in  STD_LOGIC;
        rst_n                       : in  STD_LOGIC;
        
        -- Input from RGMII receiver
        rx_data                     : in  STD_LOGIC_VECTOR(7 downto 0);
        rx_valid                    : in  STD_LOGIC;
        frame_start                 : in  STD_LOGIC;  -- Frame start pulse (from RGMII receiver)
        frame_end                   : in  STD_LOGIC;  -- Frame end pulse (from RGMII receiver)
        
        -- Inputs from IP layer
        checksum_err                : in  STD_LOGIC;  -- Checksum error from IP layer
        ip_rx_end                   : in  STD_LOGIC;  -- IP receive end
        arp_rx_end                  : in  STD_LOGIC;  -- ARP receive end (not used, tie to '0')
        
        -- Outputs
        ip_rx_req                   : out STD_LOGIC;  -- IP RX request (pulse when IPv4 detected)
        arp_rx_req                  : out STD_LOGIC;  -- ARP RX request (pulse when ARP detected)
        mac_rx_dataout              : out STD_LOGIC_VECTOR(7 downto 0);  -- Data output (2-cycle delayed)
        mac_rec_error               : out STD_LOGIC;  -- MAC receive error
        mac_rx_destination_mac_addr : out STD_LOGIC_VECTOR(47 downto 0);  -- Destination MAC address
        mac_rx_source_mac_addr      : out STD_LOGIC_VECTOR(47 downto 0);   -- Source MAC address

        -- Frame information (for compatibility with existing interface)
        frame_valid                 : out STD_LOGIC;  -- Valid frame received (no CRC error)
        dest_mac                    : out STD_LOGIC_VECTOR(47 downto 0);  -- Alias for mac_rx_destination_mac_addr
        src_mac                     : out STD_LOGIC_VECTOR(47 downto 0);  -- Alias for mac_rx_source_mac_addr
        ethertype                   : out STD_LOGIC_VECTOR(15 downto 0);  -- Frame type (EtherType)
        frame_count                 : out STD_LOGIC_VECTOR(31 downto 0);  -- Frame counter
        
        -- Data passthrough for IP parser (compatibility)
        data_out                    : out STD_LOGIC_VECTOR(7 downto 0);  -- Alias for mac_rx_dataout
        byte_counter                : out unsigned(10 downto 0)  -- Byte counter (for IP parser)
    );
end mac_parser_rgmii;

architecture Behavioral of mac_parser_rgmii is
    
    -- State machine (one-hot encoding as per vendor demo)
    constant IDLE         : STD_LOGIC_VECTOR(7 downto 0) := "00000001";
    constant REC_MAC_HEAD : STD_LOGIC_VECTOR(7 downto 0) := "00000010";
    constant REC_IDENTIFY : STD_LOGIC_VECTOR(7 downto 0) := "00000100";
    constant REC_DATA     : STD_LOGIC_VECTOR(7 downto 0) := "00001000";
    constant REC_CRC      : STD_LOGIC_VECTOR(7 downto 0) := "00010000";
    constant REC_ERROR    : STD_LOGIC_VECTOR(7 downto 0) := "00100000";
    constant REC_END      : STD_LOGIC_VECTOR(7 downto 0) := "01000000";
   -- constant REC_END      : STD_LOGIC_VECTOR(7 downto 0) := "10000000";
    
    signal rec_state      : STD_LOGIC_VECTOR(7 downto 0) := IDLE;
    signal rec_next_state : STD_LOGIC_VECTOR(7 downto 0) := IDLE;
    
    -- Counters
    signal mac_rx_cnt     : unsigned(4 downto 0) := (others => '0');
    signal mac_crc_cnt    : unsigned(15 downto 0) := (others => '0');
    signal timeout        : unsigned(15 downto 0) := (others => '0');
    

    
    -- Frame type (EtherType)
    signal frame_type     : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    

    -- Frame start detection: frame_start is already a pulse from RGMII receiver
    -- Use it directly (no edge detection needed)
    
    -- CRC signals
    signal crcen          : STD_LOGIC := '0';
    signal crcre          : STD_LOGIC := '1';
    signal crc_din        : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal crc_result     : STD_LOGIC_VECTOR(31 downto 0);
    signal crc_result_d0  : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal crc            : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal crc_check      : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal crc_rec        : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal crc_error      : STD_LOGIC := '0';
    
    -- Frame counter
    signal frame_cnt      : unsigned(31 downto 0) := (others => '0');
    
    -- Byte counter for IP parser
    signal global_byte_count : unsigned(10 downto 0) := (others => '0');
    
    -- MAC addresses (internal)
    signal mac_rx_destination_mac_addr_int : STD_LOGIC_VECTOR(47 downto 0) := (others => '0');
    signal mac_rx_source_mac_addr_int      : STD_LOGIC_VECTOR(47 downto 0) := (others => '0');
    
    -- MAC receive error (internal)
    signal mac_rec_error_int : STD_LOGIC := '0';
    
begin

    -- CRC32 instance 
    crc32_inst: entity work.crc32
        port map (
            Clk      => clk,
            Reset    => crcre,
            Data_in  => crc_din,
            Enable   => crcen,
            Crc      => crc_result,
            CrcNext  => open
        );
    
    -- Frame start is already a pulse from RGMII receiver, use it directly
    
    -- Data output 
    mac_rx_dataout <= rx_data;
    data_out <= rx_data;  -- Compatibility alias
    
    -- MAC address outputs
    mac_rx_destination_mac_addr <= mac_rx_destination_mac_addr_int;
    mac_rx_source_mac_addr <= mac_rx_source_mac_addr_int;
    dest_mac <= mac_rx_destination_mac_addr_int;  -- Compatibility alias
    src_mac <= mac_rx_source_mac_addr_int;  -- Compatibility alias
   -- preamble_out <= preamble;
   -- preamble_cnt_out <= preamble_cnt;

    -- EtherType output
    ethertype <= frame_type;
    
    -- Frame counter output
    frame_count <= STD_LOGIC_VECTOR(frame_cnt);
    
    -- Byte counter output (for IP parser)
    byte_counter <= global_byte_count;
    
    -- State machine: current state register
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            rec_state <= IDLE;
        elsif rising_edge(clk) then
            rec_state <= rec_next_state;
        end if;
    end process;
    
    -- State machine: next state logic
    -- Note: frame_start is already a pulse from RGMII receiver
    process(rec_state, frame_start, frame_end, mac_rx_cnt, checksum_err, ip_rx_end, arp_rx_end, timeout, crc_error, frame_type)
    begin
        case rec_state is
            when IDLE =>
                if frame_start = '1' then
                    rec_next_state <= REC_MAC_HEAD;
                else
                    rec_next_state <= IDLE;
                end if;
                

                
            when REC_MAC_HEAD =>

                if mac_rx_cnt = 13 then
                    rec_next_state <= REC_IDENTIFY;
                else
                    rec_next_state <= REC_MAC_HEAD;
                end if;
                
            when REC_IDENTIFY =>
                -- Allow all frame types to proceed to REC_DATA
                -- Only generate ip_rx_req/arp_rx_req for IP/ARP frames
                -- This ensures frames can complete even if not IP/ARP
                rec_next_state <= REC_DATA;
                
            when REC_DATA =>
                if checksum_err = '1' then
                    rec_next_state <= REC_ERROR;
                elsif ip_rx_end = '1' or arp_rx_end = '1' then
                    rec_next_state <= REC_CRC;
                elsif frame_end = '1' then
                    -- Fallback: use frame_end from RGMII receiver if ip_rx_end doesn't come
                    -- This ensures frames can still be processed even if IP parser doesn't generate ip_rx_end
                    rec_next_state <= REC_CRC;
                elsif timeout = x"FFFF" then
                    rec_next_state <= REC_ERROR;
                else
                    rec_next_state <= REC_DATA;
                end if;
                
            when REC_CRC =>
                if crc_error = '1' then
                    rec_next_state <= REC_ERROR;
                elsif mac_rx_cnt = 8 then
                    rec_next_state <= REC_END;
                else
                    rec_next_state <= REC_CRC;
                end if;
                
            when REC_ERROR =>
                rec_next_state <= IDLE;
                
            when REC_END =>
                rec_next_state <= IDLE;
                
            when others =>
                rec_next_state <= IDLE;
        end case;
    end process;
    
    
    -- CRC enable/reset control
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            crcen <= '0';
            crcre <= '1';
            crc_din <= (others => '0');
        elsif rising_edge(clk) then
            if rec_state = REC_MAC_HEAD or rec_state = REC_IDENTIFY or rec_state = REC_DATA then
                crcen <= '1';
                crcre <= '0';
                crc_din <= rx_data;
            else
                crcen <= '0';
                crcre <= '1';
                crc_din <= (others => '0');
            end if;
        end if;
    end process;
    
    -- IP RX request generation
    -- Keep ip_rx_req high during REC_DATA for IP frames so IP parser can start immediately
    -- This ensures IP parser starts reading from the correct byte (byte 14, first IP header byte)
    -- Assert ip_rx_req early (when mac_rx_cnt>=11) so IP parser is ready when IP data arrives at byte 14
    -- Don't check frame_type at mac_rx_cnt=11 because EtherType isn't captured until mac_rx_cnt=12-13
    -- Check frame_type only in REC_IDENTIFY/REC_DATA states where it's valid
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ip_rx_req <= '0';
        elsif rising_edge(clk) then
            if (rec_state = REC_MAC_HEAD and mac_rx_cnt >= 11) or
               ((rec_state = REC_IDENTIFY or rec_state = REC_DATA) and frame_type = x"0800") then
                ip_rx_req <= '1';
            else
                ip_rx_req <= '0';
            end if;
        end if;
    end process;
    
    -- ARP RX request generation
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            arp_rx_req <= '0';
        elsif rising_edge(clk) then
            if rec_state = REC_IDENTIFY and frame_type = x"0806" then
                arp_rx_req <= '1';
            else
                arp_rx_req <= '0';
            end if;
        end if;
    end process;
    
    -- Timeout counter
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            timeout <= (others => '0');
        elsif rising_edge(clk) then
            if rec_state = REC_DATA then
                timeout <= timeout + 1;
            else
                timeout <= (others => '0');
            end if;
        end if;
    end process;
    
    -- MAC RX counter (for preamble, MAC header, and CRC)
    -- Increment every cycle when in these states (as per vendor demo)
    -- Note: rx_valid should be high during frame, but counter increments regardless
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            mac_rx_cnt <= (others => '0');
        elsif rising_edge(clk) then
            if  rec_state = REC_MAC_HEAD or rec_state = REC_CRC then -- rec_state = REC_PREAMBLE or
                mac_rx_cnt <= mac_rx_cnt + 1;
            else
                mac_rx_cnt <= (others => '0');
            end if;
        end if;
    end process;
    
    -- MAC CRC counter (counts all valid data bytes)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            mac_crc_cnt <= (others => '0');
        elsif rising_edge(clk) then
            if rx_valid = '1' then
                mac_crc_cnt <= mac_crc_cnt + 1;
            else
                mac_crc_cnt <= (others => '0');
            end if;
        end if;
    end process;
    
    -- MAC receive error
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            mac_rec_error_int <= '0';
        elsif rising_edge(clk) then
            if frame_start = '1' then
                mac_rec_error_int <= '0';
            elsif rec_state = REC_ERROR then
                mac_rec_error_int <= '1';
            end if;
        end if;
    end process;
    
    mac_rec_error <= mac_rec_error_int;
    
    -- CRC result register
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            crc <= (others => '0');
        elsif rising_edge(clk) then
            if crcen = '1' then
                crc <= crc_result_d0;
            end if;
        end if;
    end process;
    
    -- CRC result delay register
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            crc_result_d0 <= (others => '0');
        elsif rising_edge(clk) then
            crc_result_d0 <= crc_result;
        end if;
    end process;
    
    -- CRC check calculation (bit-reversed and inverted)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            crc_check <= (others => '0');
        elsif rising_edge(clk) then
            if rec_state = REC_CRC then
                case mac_rx_cnt is
                    when "00001" =>
                        crc_check(31 downto 24) <= not (crc(24) & crc(25) & crc(26) & crc(27) & crc(28) & crc(29) & crc(30) & crc(31));
                    when "00010" =>
                        crc_check(23 downto 16) <= not (crc(16) & crc(17) & crc(18) & crc(19) & crc(20) & crc(21) & crc(22) & crc(23));
                    when "00011" =>
                        crc_check(15 downto 8) <= not (crc(8) & crc(9) & crc(10) & crc(11) & crc(12) & crc(13) & crc(14) & crc(15));
                    when "00100" =>
                        crc_check(7 downto 0) <= not (crc(0) & crc(1) & crc(2) & crc(3) & crc(4) & crc(5) & crc(6) & crc(7));
                    when others =>
                        crc_check <= crc_check;
                end case;
            else
                crc_check <= (others => '0');
            end if;
        end if;
    end process;
    
    -- Received CRC data
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            crc_rec <= (others => '0');
        elsif rising_edge(clk) then
            if rec_state = REC_CRC then
                case mac_rx_cnt is
                    when "00000" =>
                        crc_rec(31 downto 24) <= rx_data;
                    when "00001" =>
                        crc_rec(23 downto 16) <= rx_data;
                    when "00010" =>
                        crc_rec(15 downto 8) <= rx_data;
                    when "00011" =>
                        crc_rec(7 downto 0) <= rx_data;
                    when others =>
                        crc_rec <= crc_rec;
                end case;
            end if;
        end if;
    end process;
    
    -- CRC error check
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            crc_error <= '0';
        elsif rising_edge(clk) then
            if CRC_BYPASS then
                -- Bypass CRC checking: always report no CRC error
                crc_error <= '0';
            elsif rec_state = REC_CRC and mac_rx_cnt = 5 then
                if crc_check = crc_rec then
                    crc_error <= '0';
                else
                    crc_error <= '1';
                end if;
            else
                crc_error <= '0';
            end if;
        end if;
    end process;
    
   
    
    -- Destination MAC address capture
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            mac_rx_destination_mac_addr_int <= (others => '0');
        elsif rising_edge(clk) then
            if rec_state = REC_MAC_HEAD then
                case mac_rx_cnt is
                    when "00000" => mac_rx_destination_mac_addr_int(47 downto 40) <= rx_data;
                    when "00001" => mac_rx_destination_mac_addr_int(39 downto 32) <= rx_data;
                    when "00010" => mac_rx_destination_mac_addr_int(31 downto 24) <= rx_data;
                    when "00011" => mac_rx_destination_mac_addr_int(23 downto 16) <= rx_data;
                    when "00100" => mac_rx_destination_mac_addr_int(15 downto 8) <= rx_data;
                    when "00101" => mac_rx_destination_mac_addr_int(7 downto 0) <= rx_data;
                    when others => null;
                end case;
            end if;
        end if;
    end process;
    
    -- Source MAC address capture 
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            mac_rx_source_mac_addr_int <= (others => '0');
        elsif rising_edge(clk) then
            if rec_state = REC_MAC_HEAD then
                case mac_rx_cnt is
                    when "00110" => mac_rx_source_mac_addr_int(47 downto 40) <= rx_data;
                    when "00111" => mac_rx_source_mac_addr_int(39 downto 32) <= rx_data;
                    when "01000" => mac_rx_source_mac_addr_int(31 downto 24) <= rx_data;
                    when "01001" => mac_rx_source_mac_addr_int(23 downto 16) <= rx_data;
                    when "01010" => mac_rx_source_mac_addr_int(15 downto 8) <= rx_data;
                    when "01011" => mac_rx_source_mac_addr_int(7 downto 0) <= rx_data;
                    when others => null;
                end case;
            end if;
        end if;
    end process;
    
    -- Frame type (EtherType) capture
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            frame_type <= (others => '0');
        elsif rising_edge(clk) then
            if rec_state = REC_MAC_HEAD then
                case mac_rx_cnt is
                    when "01100" => frame_type(15 downto 8) <= rx_data; -- 10100 
                    when "01101" => frame_type(7 downto 0) <= rx_data;
                    when others => null;
                end case;
            end if;
        end if;
    end process;
    
    -- Global byte counter (for IP parser compatibility)
    -- When ip_rx_req is generated (at EtherType detection), IP parser starts at IP header (byte 14)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            global_byte_count <= (others => '0');
        elsif rising_edge(clk) then
            if frame_start = '1' then
                global_byte_count <= (others => '0');
            elsif rx_valid = '1' then
                -- For now, just count normally - IP parser has its own internal counter
                global_byte_count <= global_byte_count + 1;
           end if;
        end if;
    end process;
    
    -- Frame valid and frame counter (set when frame completes successfully)
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            frame_valid <= '0';
            frame_cnt <= (others => '0');
        elsif rising_edge(clk) then
            frame_valid <= '0';  -- Default: pulse only
            if rec_state = REC_END and (CRC_BYPASS or crc_error = '0') and mac_rec_error_int = '0' then
                frame_valid <= '1';
                frame_cnt <= frame_cnt + 1;
            end if;
        end if;
    end process;
    
end Behavioral;
