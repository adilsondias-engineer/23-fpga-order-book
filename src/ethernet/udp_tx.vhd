----------------------------------------------------------------------------------
-- Generic UDP TX Module (Working Structure)
-- Based on proven udp_hello_world_tx structure but with modular parameters
-- Uses single SEND_FRAME state like working version
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity udp_tx is
    Generic (
        SRC_MAC       : STD_LOGIC_VECTOR(47 downto 0) := x"00_0A_35_01_FE_C0";
        DST_MAC       : STD_LOGIC_VECTOR(47 downto 0) := x"FF_FF_FF_FF_FF_FF";
        SRC_IP        : STD_LOGIC_VECTOR(31 downto 0) := x"C0_A8_00_D4";
        DST_IP        : STD_LOGIC_VECTOR(31 downto 0) := x"FF_FF_FF_FF";
        SRC_PORT      : STD_LOGIC_VECTOR(15 downto 0) := x"1388";
        DST_PORT      : STD_LOGIC_VECTOR(15 downto 0) := x"1389";
        PAYLOAD_LEN   : integer := 18
    );
    Port (
        clk          : in  STD_LOGIC;
        rst          : in  STD_LOGIC;
        tx_start     : in  STD_LOGIC;
        tx_busy      : out STD_LOGIC;
        payload_data : in  STD_LOGIC_VECTOR(7 downto 0);
        payload_rd   : out STD_LOGIC;
        tx_data      : out STD_LOGIC_VECTOR(7 downto 0);
        tx_valid     : out STD_LOGIC;
        packets_sent : out STD_LOGIC_VECTOR(31 downto 0)
    );
end udp_tx;

architecture Behavioral of udp_tx is

    -- Packet structure sizes
    constant ETH_HEADER_SIZE : integer := 14;
    constant IP_HEADER_SIZE  : integer := 20;
    constant UDP_HEADER_SIZE : integer := 8;
    constant FCS_SIZE        : integer := 4;
    constant MIN_FRAME_SIZE  : integer := 60;
    constant DATA_SIZE       : integer := ETH_HEADER_SIZE + IP_HEADER_SIZE + UDP_HEADER_SIZE + PAYLOAD_LEN;
    constant FRAME_SIZE      : integer := DATA_SIZE when DATA_SIZE >= MIN_FRAME_SIZE else MIN_FRAME_SIZE;

    -- Calculated lengths for headers (use PAYLOAD_LEN generic)
    constant UDP_LEN        : unsigned(15 downto 0) := to_unsigned(UDP_HEADER_SIZE + PAYLOAD_LEN, 16);
    constant IP_TOTAL_LEN   : unsigned(15 downto 0) := to_unsigned(IP_HEADER_SIZE + UDP_HEADER_SIZE + PAYLOAD_LEN, 16);

    -- IP Header Checksum calculation (pre-computed since header is constant)
    -- Sum of all 16-bit words in IP header (excluding checksum field itself)
    -- Word 0: Version(4) + IHL(5) + TOS(0) = 0x4500
    -- Word 1: Total Length = IP_TOTAL_LEN
    -- Word 2: Identification = 0x0001
    -- Word 3: Flags + Fragment = 0x0000
    -- Word 4: TTL(64) + Protocol(17/UDP) = 0x4011
    -- Word 5: Checksum = 0x0000 (excluded from calculation)
    -- Word 6-7: Source IP (2 words)
    -- Word 8-9: Dest IP (2 words)
    function calc_ip_checksum return std_logic_vector is
        variable sum : unsigned(31 downto 0) := (others => '0');
        variable folded : unsigned(16 downto 0);
        variable checksum : unsigned(15 downto 0);
    begin
        -- Add all 16-bit words (except checksum field)
        sum := sum + x"00004500";                                    -- Version + IHL + TOS
        sum := sum + resize(IP_TOTAL_LEN, 32);                       -- Total Length
        sum := sum + x"00000001";                                    -- Identification
        sum := sum + x"00000000";                                    -- Flags + Fragment
        sum := sum + x"00004011";                                    -- TTL + Protocol (64 + UDP)
        sum := sum + unsigned(x"0000" & SRC_IP(31 downto 16));       -- Source IP high word
        sum := sum + unsigned(x"0000" & SRC_IP(15 downto 0));        -- Source IP low word
        sum := sum + unsigned(x"0000" & DST_IP(31 downto 16));       -- Dest IP high word
        sum := sum + unsigned(x"0000" & DST_IP(15 downto 0));        -- Dest IP low word

        -- Fold 32-bit sum to 16 bits (add carry bits) - two iterations is enough
        folded := ('0' & sum(15 downto 0)) + ('0' & sum(31 downto 16));
        folded := ('0' & folded(15 downto 0)) + ("0000000000000000" & folded(16));

        -- One's complement
        checksum := not folded(15 downto 0);

        return std_logic_vector(checksum);
    end function;

    constant IP_CHECKSUM : std_logic_vector(15 downto 0) := calc_ip_checksum;

    -- Payload read signal (directly driven from byte counter position)
    signal payload_rd_int : std_logic := '0';

    -- Timer for periodic transmission
    signal send_trigger : std_logic := '0';

    -- State machine (same states as working version)
    type state_type is (IDLE, SEND_PREAMBLE, SEND_SFD, SEND_FRAME, SEND_FCS, SEND_IFG);
    signal state : state_type := IDLE;

    -- CRC signals (using simple combinatorial crc32_calc)
    signal crc_reg      : std_logic_vector(31 downto 0) := (others => '1');
    signal crc_next     : std_logic_vector(31 downto 0);
    signal frame_byte   : std_logic_vector(7 downto 0);  -- Combinatorial frame byte selection

    -- Byte counter
    signal byte_cnt : unsigned(10 downto 0) := (others => '0');

    -- Packet counter
    signal packet_counter : unsigned(31 downto 0) := (others => '0');

begin

    packets_sent <= std_logic_vector(packet_counter);
    tx_busy <= '0' when state = IDLE else '1';
    payload_rd <= payload_rd_int;

    -- Payload read signal - asserted during payload bytes to advance external source
    payload_rd_int <= '1' when state = SEND_FRAME and byte_cnt >= 42 and byte_cnt < 42 + PAYLOAD_LEN else '0';

    -- CRC32 combinatorial calculator (pure XOR logic, no control signals)
    -- Uses reflected polynomial 0xEDB88320 - data goes in naturally, no bit reversal needed
    crc32_inst: entity work.crc32_calc
        port map (
            crcIn  => crc_reg,
            data   => frame_byte,  -- Feed frame_byte directly (combinatorial)
            crcOut => crc_next
        );

    -- Combinatorial frame byte selection based on byte counter
    -- This allows crc_next to be computed before the clock edge
    frame_byte_proc: process(byte_cnt, payload_data)
    begin
        if byte_cnt < 6 then
            -- DST MAC
            frame_byte <= DST_MAC(47 - to_integer(byte_cnt)*8 downto 40 - to_integer(byte_cnt)*8);
        elsif byte_cnt < 12 then
            -- SRC MAC
            frame_byte <= SRC_MAC(47 - to_integer(byte_cnt-6)*8 downto 40 - to_integer(byte_cnt-6)*8);
        elsif byte_cnt = 12 then
            frame_byte <= x"08";  -- EtherType IP MSB
        elsif byte_cnt = 13 then
            frame_byte <= x"00";  -- EtherType IP LSB
        elsif byte_cnt = 14 then
            frame_byte <= x"45";  -- IP Version + IHL
        elsif byte_cnt = 15 then
            frame_byte <= x"00";  -- TOS
        elsif byte_cnt = 16 then
            frame_byte <= std_logic_vector(IP_TOTAL_LEN(15 downto 8));
        elsif byte_cnt = 17 then
            frame_byte <= std_logic_vector(IP_TOTAL_LEN(7 downto 0));
        elsif byte_cnt = 18 then
            frame_byte <= x"00";  -- Identification MSB
        elsif byte_cnt = 19 then
            frame_byte <= x"01";  -- Identification LSB
        elsif byte_cnt = 20 then
            frame_byte <= x"00";  -- Flags
        elsif byte_cnt = 21 then
            frame_byte <= x"00";  -- Fragment offset
        elsif byte_cnt = 22 then
            frame_byte <= x"40";  -- TTL = 64
        elsif byte_cnt = 23 then
            frame_byte <= x"11";  -- Protocol = UDP
        elsif byte_cnt = 24 then
            frame_byte <= IP_CHECKSUM(15 downto 8);  -- IP Checksum MSB
        elsif byte_cnt = 25 then
            frame_byte <= IP_CHECKSUM(7 downto 0);   -- IP Checksum LSB
        elsif byte_cnt < 30 then
            -- SRC IP
            frame_byte <= SRC_IP(31 - to_integer(byte_cnt-26)*8 downto 24 - to_integer(byte_cnt-26)*8);
        elsif byte_cnt < 34 then
            -- DST IP
            frame_byte <= DST_IP(31 - to_integer(byte_cnt-30)*8 downto 24 - to_integer(byte_cnt-30)*8);
        elsif byte_cnt = 34 then
            frame_byte <= SRC_PORT(15 downto 8);
        elsif byte_cnt = 35 then
            frame_byte <= SRC_PORT(7 downto 0);
        elsif byte_cnt = 36 then
            frame_byte <= DST_PORT(15 downto 8);
        elsif byte_cnt = 37 then
            frame_byte <= DST_PORT(7 downto 0);
        elsif byte_cnt = 38 then
            frame_byte <= std_logic_vector(UDP_LEN(15 downto 8));
        elsif byte_cnt = 39 then
            frame_byte <= std_logic_vector(UDP_LEN(7 downto 0));
        elsif byte_cnt = 40 then
            frame_byte <= x"00";  -- UDP Checksum MSB
        elsif byte_cnt = 41 then
            frame_byte <= x"00";  -- UDP Checksum LSB
        elsif byte_cnt < 42 + PAYLOAD_LEN then
            -- External payload from payload_data input
            frame_byte <= payload_data;
        else
            -- Padding
            frame_byte <= x"00";
        end if;
    end process;

    -- Timer process (same structure as working version)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                send_trigger <= '0';
            else
                send_trigger <= '0';
                if state = IDLE then
                   if tx_start = '1' then
                      send_trigger <= '1';
                   end if;
                end if;
            end if;
        end if;
    end process;

    -- Main state machine using simple combinatorial CRC
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                tx_valid <= '0';
                tx_data <= (others => '0');
                byte_cnt <= (others => '0');
                packet_counter <= (others => '0');
                crc_reg <= (others => '1');
            else
                -- Default outputs
                tx_valid <= '0';

                case state is
                    when IDLE =>
                        byte_cnt <= (others => '0');
                        crc_reg <= (others => '1');  -- Initialize CRC to 0xFFFFFFFF
                        if send_trigger = '1' then
                            state <= SEND_PREAMBLE;
                        end if;

                    when SEND_PREAMBLE =>
                        tx_data <= x"55";
                        tx_valid <= '1';
                        if byte_cnt = 6 then
                            byte_cnt <= (others => '0');
                            state <= SEND_SFD;
                        else
                            byte_cnt <= byte_cnt + 1;
                        end if;

                    when SEND_SFD =>
                        tx_data <= x"D5";
                        tx_valid <= '1';
                        byte_cnt <= (others => '0');
                        state <= SEND_FRAME;

                    when SEND_FRAME =>
                        tx_valid <= '1';
                        tx_data <= frame_byte;       -- Output current frame byte
                        crc_reg <= crc_next;         -- Update CRC with next value (computed combinatorially)

                        if byte_cnt = FRAME_SIZE - 1 then
                            byte_cnt <= (others => '0');
                            state <= SEND_FCS;
                        else
                            byte_cnt <= byte_cnt + 1;
                        end if;

                    when SEND_FCS =>
                        tx_valid <= '1';
                        -- Output complemented CRC bytes, LSB first (standard Ethernet FCS order)
                        case to_integer(byte_cnt) is
                            when 0 => tx_data <= not crc_reg(7 downto 0);
                            when 1 => tx_data <= not crc_reg(15 downto 8);
                            when 2 => tx_data <= not crc_reg(23 downto 16);
                            when 3 => tx_data <= not crc_reg(31 downto 24);
                            when others => tx_data <= x"00";
                        end case;

                        if byte_cnt = 3 then
                            byte_cnt <= (others => '0');
                            state <= SEND_IFG;
                            packet_counter <= packet_counter + 1;
                        else
                            byte_cnt <= byte_cnt + 1;
                        end if;

                    when SEND_IFG =>
                        if byte_cnt = 11 then
                            state <= IDLE;
                        else
                            byte_cnt <= byte_cnt + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
