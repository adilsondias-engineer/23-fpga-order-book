----------------------------------------------------------------------------------
-- Simple ITCH Debug Formatter - Simplified version for testing
-- Just outputs test characters to verify UART works
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity itch_debug_formatter is
    Port (
        clk : in STD_LOGIC;
        rst : in STD_LOGIC;

        -- Debug inputs
        build_version : in std_logic_vector(7 downto 0);  -- Build number for verification
        itch_msg_count : in std_logic_vector(31 downto 0);
        ob_update_count : in std_logic_vector(31 downto 0);
        itch_msg_type : in std_logic_vector(7 downto 0);
        bbo_valid : in std_logic;

        -- UART output
        tx_data : out STD_LOGIC_VECTOR(7 downto 0);
        tx_start : out STD_LOGIC;
        tx_busy : in STD_LOGIC
    );
end itch_debug_formatter;

architecture Behavioral of itch_debug_formatter is
    -- Simple state machine for sending debug message
    type state_type is (WAIT_READY, SEND_CHAR, WAIT_BUSY);
    signal state : state_type := WAIT_READY;

    -- Counter for delay between messages (1 second)
    constant DELAY_MAX : integer := 200_000_000;  -- 1s at 200MHz
    signal delay_counter : integer range 0 to DELAY_MAX := 0;

    -- Message format: [B:xx ITCH:xxxx OB:yyy TYP:z BBO:V]\r
    type char_array is array (0 to 39) of std_logic_vector(7 downto 0);
    signal message : char_array;
    signal char_index : integer range 0 to 39 := 0;

    -- Convert nibble to hex ASCII
    function nibble_to_hex(nibble : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        if unsigned(nibble) < 10 then
            return std_logic_vector(to_unsigned(48 + to_integer(unsigned(nibble)), 8)); -- '0'-'9'
        else
            return std_logic_vector(to_unsigned(55 + to_integer(unsigned(nibble)), 8)); -- 'A'-'F'
        end if;
    end function;

begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= WAIT_READY;
                tx_start <= '0';
                tx_data <= (others => '0');
                delay_counter <= 0;
                char_index <= 0;
            else
                -- Build message array (update every cycle so it's always current)
                -- Format: [B:xx ITCH:xxxx OB:yyy TYP:z BBO:V]\r
                message(0) <= X"5B";  -- '['
                message(1) <= X"42";  -- 'B'
                message(2) <= X"3A";  -- ':'
                message(3) <= nibble_to_hex(build_version(7 downto 4));  -- Build version high nibble
                message(4) <= nibble_to_hex(build_version(3 downto 0));  -- Build version low nibble
                message(5) <= X"20";  -- ' '
                message(6) <= X"49";  -- 'I'
                message(7) <= X"54";  -- 'T'
                message(8) <= X"43";  -- 'C'
                message(9) <= X"48";  -- 'H'
                message(10) <= X"3A";  -- ':'
                -- DEBUG: Show both sync'd and original counter values
                -- First 2 hex digits: synchronized value (may have CDC issues)
                message(11) <= nibble_to_hex(itch_msg_count(7 downto 4));
                message(12) <= nibble_to_hex(itch_msg_count(3 downto 0));
                -- Last 2 hex digits: OB count for comparison
                message(13) <= nibble_to_hex(ob_update_count(7 downto 4));
                message(14) <= nibble_to_hex(ob_update_count(3 downto 0));
                message(15) <= X"20"; -- ' '
                message(16) <= X"4F"; -- 'O'
                message(17) <= X"42"; -- 'B'
                message(18) <= X"3A"; -- ':'
                message(19) <= nibble_to_hex(ob_update_count(11 downto 8));
                message(20) <= nibble_to_hex(ob_update_count(7 downto 4));
                message(21) <= nibble_to_hex(ob_update_count(3 downto 0));
                message(22) <= X"20"; -- ' '
                message(23) <= X"54"; -- 'T'
                message(24) <= X"59"; -- 'Y'
                message(25) <= X"50"; -- 'P'
                message(26) <= X"3A"; -- ':'
                message(27) <= itch_msg_type;  -- Raw ASCII character
                message(28) <= X"20"; -- ' '
                message(29) <= X"42"; -- 'B'
                message(30) <= X"42"; -- 'B'
                message(31) <= X"4F"; -- 'O'
                message(32) <= X"3A"; -- ':'
                if bbo_valid = '1' then
                    message(33) <= X"56"; -- 'V' for valid
                else
                    message(33) <= X"4E"; -- 'N' for nodata
                end if;
                message(34) <= X"5D"; -- ']'
                message(35) <= X"0D"; -- CR
                message(36) <= X"0A"; -- LF
                -- Pad rest with spaces
                message(37) <= X"20";
                message(38) <= X"20";
                message(39) <= X"20";

                case state is
                    when WAIT_READY =>
                        tx_start <= '0';
                        -- If starting new message, wait 1 second
                        if char_index = 0 then
                            if delay_counter < DELAY_MAX - 1 then
                                delay_counter <= delay_counter + 1;
                            else
                                delay_counter <= 0;
                                if tx_busy = '0' then
                                    state <= SEND_CHAR;
                                end if;
                            end if;
                        -- Otherwise just wait for UART ready
                        elsif tx_busy = '0' then
                            state <= SEND_CHAR;
                        end if;

                    when SEND_CHAR =>
                        tx_data <= message(char_index);
                        tx_start <= '1';
                        state <= WAIT_BUSY;

                    when WAIT_BUSY =>
                        if tx_busy = '1' then
                            tx_start <= '0';
                            -- Move to next character or back to start
                            if char_index < 36 then  -- Send up to CR/LF (position 35-36)
                                char_index <= char_index + 1;
                                state <= WAIT_READY;
                            else
                                -- Message complete, reset and wait 1 second
                                char_index <= 0;
                                state <= WAIT_READY;
                            end if;
                        end if;

                    when others =>
                        state <= WAIT_READY;
                end case;
            end if;
        end if;
    end process;
end Behavioral;
