----------------------------------------------------------------------------------
-- CRC32 Module (converted from vendor demo crc.v)
-- Description: Ethernet CRC32 calculation module
-- Used by MAC parser for frame CRC verification
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity crc32 is
    Port (
        Clk      : in  STD_LOGIC;
        Reset    : in  STD_LOGIC;
        Data_in  : in  STD_LOGIC_VECTOR(7 downto 0);
        Enable   : in  STD_LOGIC;
        Crc      : out STD_LOGIC_VECTOR(31 downto 0);
        CrcNext  : out STD_LOGIC_VECTOR(31 downto 0)
    );
end crc32;

architecture Behavioral of crc32 is
    signal Crc_reg : STD_LOGIC_VECTOR(31 downto 0) := (others => '1');
    signal Data_reversed : STD_LOGIC_VECTOR(7 downto 0);
    signal CrcNext_int : STD_LOGIC_VECTOR(31 downto 0);
begin
    -- Reverse bit order of input data (as per vendor demo)
    Data_reversed <= Data_in(0) & Data_in(1) & Data_in(2) & Data_in(3) & 
                     Data_in(4) & Data_in(5) & Data_in(6) & Data_in(7);
    
    -- CRC32 calculation (converted from vendor demo)
    CrcNext_int(0)  <= Crc_reg(24) XOR Crc_reg(30) XOR Data_reversed(0) XOR Data_reversed(6);
    CrcNext_int(1)  <= Crc_reg(24) XOR Crc_reg(25) XOR Crc_reg(30) XOR Crc_reg(31) XOR Data_reversed(0) XOR Data_reversed(1) XOR Data_reversed(6) XOR Data_reversed(7);
    CrcNext_int(2)  <= Crc_reg(24) XOR Crc_reg(25) XOR Crc_reg(26) XOR Crc_reg(30) XOR Crc_reg(31) XOR Data_reversed(0) XOR Data_reversed(1) XOR Data_reversed(2) XOR Data_reversed(6) XOR Data_reversed(7);
    CrcNext_int(3)  <= Crc_reg(25) XOR Crc_reg(26) XOR Crc_reg(27) XOR Crc_reg(31) XOR Data_reversed(1) XOR Data_reversed(2) XOR Data_reversed(3) XOR Data_reversed(7);
    CrcNext_int(4)  <= Crc_reg(24) XOR Crc_reg(26) XOR Crc_reg(27) XOR Crc_reg(28) XOR Crc_reg(30) XOR Data_reversed(0) XOR Data_reversed(2) XOR Data_reversed(3) XOR Data_reversed(4) XOR Data_reversed(6);
    CrcNext_int(5)  <= Crc_reg(24) XOR Crc_reg(25) XOR Crc_reg(27) XOR Crc_reg(28) XOR Crc_reg(29) XOR Crc_reg(30) XOR Crc_reg(31) XOR Data_reversed(0) XOR Data_reversed(1) XOR Data_reversed(3) XOR Data_reversed(4) XOR Data_reversed(5) XOR Data_reversed(6) XOR Data_reversed(7);
    CrcNext_int(6)  <= Crc_reg(25) XOR Crc_reg(26) XOR Crc_reg(28) XOR Crc_reg(29) XOR Crc_reg(30) XOR Crc_reg(31) XOR Data_reversed(1) XOR Data_reversed(2) XOR Data_reversed(4) XOR Data_reversed(5) XOR Data_reversed(6) XOR Data_reversed(7);
    CrcNext_int(7)  <= Crc_reg(24) XOR Crc_reg(26) XOR Crc_reg(27) XOR Crc_reg(29) XOR Crc_reg(31) XOR Data_reversed(0) XOR Data_reversed(2) XOR Data_reversed(3) XOR Data_reversed(5) XOR Data_reversed(7);
    CrcNext_int(8)  <= Crc_reg(0) XOR Crc_reg(24) XOR Crc_reg(25) XOR Crc_reg(27) XOR Crc_reg(28) XOR Data_reversed(0) XOR Data_reversed(1) XOR Data_reversed(3) XOR Data_reversed(4);
    CrcNext_int(9)  <= Crc_reg(1) XOR Crc_reg(25) XOR Crc_reg(26) XOR Crc_reg(28) XOR Crc_reg(29) XOR Data_reversed(1) XOR Data_reversed(2) XOR Data_reversed(4) XOR Data_reversed(5);
    CrcNext_int(10) <= Crc_reg(2) XOR Crc_reg(24) XOR Crc_reg(26) XOR Crc_reg(27) XOR Crc_reg(29) XOR Data_reversed(0) XOR Data_reversed(2) XOR Data_reversed(3) XOR Data_reversed(5);
    CrcNext_int(11) <= Crc_reg(3) XOR Crc_reg(24) XOR Crc_reg(25) XOR Crc_reg(27) XOR Crc_reg(28) XOR Data_reversed(0) XOR Data_reversed(1) XOR Data_reversed(3) XOR Data_reversed(4);
    CrcNext_int(12) <= Crc_reg(4) XOR Crc_reg(24) XOR Crc_reg(25) XOR Crc_reg(26) XOR Crc_reg(28) XOR Crc_reg(29) XOR Crc_reg(30) XOR Data_reversed(0) XOR Data_reversed(1) XOR Data_reversed(2) XOR Data_reversed(4) XOR Data_reversed(5) XOR Data_reversed(6);
    CrcNext_int(13) <= Crc_reg(5) XOR Crc_reg(25) XOR Crc_reg(26) XOR Crc_reg(27) XOR Crc_reg(29) XOR Crc_reg(30) XOR Crc_reg(31) XOR Data_reversed(1) XOR Data_reversed(2) XOR Data_reversed(3) XOR Data_reversed(5) XOR Data_reversed(6) XOR Data_reversed(7);
    CrcNext_int(14) <= Crc_reg(6) XOR Crc_reg(26) XOR Crc_reg(27) XOR Crc_reg(28) XOR Crc_reg(30) XOR Crc_reg(31) XOR Data_reversed(2) XOR Data_reversed(3) XOR Data_reversed(4) XOR Data_reversed(6) XOR Data_reversed(7);
    CrcNext_int(15) <= Crc_reg(7) XOR Crc_reg(27) XOR Crc_reg(28) XOR Crc_reg(29) XOR Crc_reg(31) XOR Data_reversed(3) XOR Data_reversed(4) XOR Data_reversed(5) XOR Data_reversed(7);
    CrcNext_int(16) <= Crc_reg(8) XOR Crc_reg(24) XOR Crc_reg(28) XOR Crc_reg(29) XOR Data_reversed(0) XOR Data_reversed(4) XOR Data_reversed(5);
    CrcNext_int(17) <= Crc_reg(9) XOR Crc_reg(25) XOR Crc_reg(29) XOR Crc_reg(30) XOR Data_reversed(1) XOR Data_reversed(5) XOR Data_reversed(6);
    CrcNext_int(18) <= Crc_reg(10) XOR Crc_reg(26) XOR Crc_reg(30) XOR Crc_reg(31) XOR Data_reversed(2) XOR Data_reversed(6) XOR Data_reversed(7);
    CrcNext_int(19) <= Crc_reg(11) XOR Crc_reg(27) XOR Crc_reg(31) XOR Data_reversed(3) XOR Data_reversed(7);
    CrcNext_int(20) <= Crc_reg(12) XOR Crc_reg(28) XOR Data_reversed(4);
    CrcNext_int(21) <= Crc_reg(13) XOR Crc_reg(29) XOR Data_reversed(5);
    CrcNext_int(22) <= Crc_reg(14) XOR Crc_reg(24) XOR Data_reversed(0);
    CrcNext_int(23) <= Crc_reg(15) XOR Crc_reg(24) XOR Crc_reg(25) XOR Crc_reg(30) XOR Data_reversed(0) XOR Data_reversed(1) XOR Data_reversed(6);
    CrcNext_int(24) <= Crc_reg(16) XOR Crc_reg(25) XOR Crc_reg(26) XOR Crc_reg(31) XOR Data_reversed(1) XOR Data_reversed(2) XOR Data_reversed(7);
    CrcNext_int(25) <= Crc_reg(17) XOR Crc_reg(26) XOR Crc_reg(27) XOR Data_reversed(2) XOR Data_reversed(3);
    CrcNext_int(26) <= Crc_reg(18) XOR Crc_reg(24) XOR Crc_reg(27) XOR Crc_reg(28) XOR Crc_reg(30) XOR Data_reversed(0) XOR Data_reversed(3) XOR Data_reversed(4) XOR Data_reversed(6);
    CrcNext_int(27) <= Crc_reg(19) XOR Crc_reg(25) XOR Crc_reg(28) XOR Crc_reg(29) XOR Crc_reg(31) XOR Data_reversed(1) XOR Data_reversed(4) XOR Data_reversed(5) XOR Data_reversed(7);
    CrcNext_int(28) <= Crc_reg(20) XOR Crc_reg(26) XOR Crc_reg(29) XOR Crc_reg(30) XOR Data_reversed(2) XOR Data_reversed(5) XOR Data_reversed(6);
    CrcNext_int(29) <= Crc_reg(21) XOR Crc_reg(27) XOR Crc_reg(30) XOR Crc_reg(31) XOR Data_reversed(3) XOR Data_reversed(6) XOR Data_reversed(7);
    CrcNext_int(30) <= Crc_reg(22) XOR Crc_reg(28) XOR Crc_reg(31) XOR Data_reversed(4) XOR Data_reversed(7);
    CrcNext_int(31) <= Crc_reg(23) XOR Crc_reg(29) XOR Data_reversed(5);
    
    CrcNext <= CrcNext_int;
    
    process(Clk)
    begin
        if rising_edge(Clk) then
            if Reset = '1' then
                Crc_reg <= (others => '1');
            elsif Enable = '1' then
                Crc_reg <= CrcNext_int;
            end if;
        end if;
    end process;
    
    Crc <= Crc_reg;
end Behavioral;
