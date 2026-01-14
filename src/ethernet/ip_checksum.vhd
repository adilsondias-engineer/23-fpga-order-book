----------------------------------------------------------------------------------
-- IP Header Checksum Calculator
-- Description: Calculates RFC 791 compliant IP header checksum
-- Algorithm: One's complement sum of all 16-bit words in header
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ip_checksum is
    Generic (
        -- Fixed IP header values for BBO UDP packets
        SRC_IP  : STD_LOGIC_VECTOR(31 downto 0) := x"C0_A8_00_D4";  -- 192.168.0.212
        DST_IP  : STD_LOGIC_VECTOR(31 downto 0) := x"C0_A8_00_61";  -- 192.168.0.97
        UDP_PAYLOAD_SIZE : integer := 28  -- BBO payload size
    );
    Port (  
        checksum : out STD_LOGIC_VECTOR(15 downto 0)
    );
end ip_checksum;

architecture Behavioral of ip_checksum is

    -- IP header fields (fixed for this application)
    constant IP_VERSION_IHL : STD_LOGIC_VECTOR(15 downto 0) := x"4500";  -- Version=4, IHL=5, TOS=0
    constant IP_TOTAL_LEN   : STD_LOGIC_VECTOR(15 downto 0) := std_logic_vector(to_unsigned(20 + 8 + UDP_PAYLOAD_SIZE, 16));  -- IP+UDP+Payload
    constant IP_ID          : STD_LOGIC_VECTOR(15 downto 0) := x"0001";  -- Identification
    constant IP_FLAGS_FRAG  : STD_LOGIC_VECTOR(15 downto 0) := x"0000";  -- Flags + Fragment offset
    constant IP_TTL_PROTO   : STD_LOGIC_VECTOR(15 downto 0) := x"4011";  -- TTL=64, Protocol=17(UDP)

    -- Checksum calculation (sum all 16-bit words, then take one's complement)
    signal sum : unsigned(31 downto 0);
    signal sum_fold1 : unsigned(16 downto 0);  -- 17 bits to capture carry
    signal sum_fold2 : unsigned(15 downto 0);  -- Final 16-bit result

begin

    -- Calculate sum of all 16-bit words in IP header (excluding checksum field)
    -- IP header format (10 x 16-bit words):
    -- Word 0: Version/IHL + TOS
    -- Word 1: Total Length
    -- Word 2: Identification
    -- Word 3: Flags + Fragment Offset
    -- Word 4: TTL + Protocol
    -- Word 5: Checksum (set to 0 for calculation)
    -- Word 6-7: Source IP (2 words)
    -- Word 8-9: Destination IP (2 words)

    sum <=
        unsigned("0000000000000000" & IP_VERSION_IHL) +
        unsigned("0000000000000000" & IP_TOTAL_LEN) +
        unsigned("0000000000000000" & IP_ID) +
        unsigned("0000000000000000" & IP_FLAGS_FRAG) +
        unsigned("0000000000000000" & IP_TTL_PROTO) +
        -- Checksum field is 0 during calculation
        unsigned("0000000000000000" & SRC_IP(31 downto 16)) +
        unsigned("0000000000000000" & SRC_IP(15 downto 0)) +
        unsigned("0000000000000000" & DST_IP(31 downto 16)) +
        unsigned("0000000000000000" & DST_IP(15 downto 0));

    -- Fold carry bits back into the sum (first fold with 17-bit intermediate)
    sum_fold1 <= ('0' & sum(15 downto 0)) + ('0' & sum(31 downto 16));

    -- Second fold to handle any carry from first fold
    sum_fold2 <= sum_fold1(15 downto 0) + ("000000000000000" & sum_fold1(16));

    -- Take one's complement
    checksum <= not std_logic_vector(sum_fold2);

end Behavioral;
