--------------------------------------------------------------------------------
-- Module: udp_payload_dumper
-- Description: Dumps UDP payload bytes to UART in hex format for debugging
--              Outputs each byte as 2 hex digits followed by space
--              Example: "41 00 0d 00 00 0d 5a af bb e0 ..."
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity udp_payload_dumper is
    Port (
        clk : in std_logic;
        reset : in std_logic;

        -- UDP payload input (125MHz domain from ethernet_top)
        udp_payload_data : in std_logic_vector(7 downto 0);
        udp_payload_valid : in std_logic;
        udp_payload_start : in std_logic;
        udp_payload_end : in std_logic;

        -- UART output interface
        uart_tx_data : out std_logic_vector(7 downto 0);
        uart_tx_valid : out std_logic;
        uart_tx_ready : in std_logic
    );
end udp_payload_dumper;

architecture Behavioral of udp_payload_dumper is
    -- State machine
    type state_t is (IDLE, WAIT_START, CAPTURE_BYTE, SEND_HEX_HIGH, SEND_HEX_LOW, SEND_SPACE, SEND_NEWLINE);
    signal state : state_t := IDLE;

    -- Captured byte
    signal captured_byte : std_logic_vector(7 downto 0);
    signal byte_count : unsigned(7 downto 0) := (others => '0');

    -- Synchronizers for 125MHz -> 200MHz CDC
    signal udp_start_sync1 : std_logic := '0';
    signal udp_start_sync2 : std_logic := '0';
    signal udp_end_sync1 : std_logic := '0';
    signal udp_end_sync2 : std_logic := '0';
    signal udp_valid_sync1 : std_logic := '0';
    signal udp_valid_sync2 : std_logic := '0';
    signal udp_data_sync1 : std_logic_vector(7 downto 0) := (others => '0');
    signal udp_data_sync2 : std_logic_vector(7 downto 0) := (others => '0');

    -- Function to convert 4-bit nibble to ASCII hex
    function nibble_to_hex(nibble : std_logic_vector(3 downto 0)) return std_logic_vector is
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
            when others => result := x"3F";  -- '?'
        end case;
        return result;
    end function;

begin

    -- Main state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                uart_tx_valid <= '0';
                byte_count <= (others => '0');
                udp_start_sync1 <= '0';
                udp_start_sync2 <= '0';
                udp_end_sync1 <= '0';
                udp_end_sync2 <= '0';
                udp_valid_sync1 <= '0';
                udp_valid_sync2 <= '0';
                udp_data_sync1 <= (others => '0');
                udp_data_sync2 <= (others => '0');
            else
                -- Synchronize UDP signals (125MHz -> 200MHz)
                udp_start_sync1 <= udp_payload_start;
                udp_start_sync2 <= udp_start_sync1;
                udp_end_sync1 <= udp_payload_end;
                udp_end_sync2 <= udp_end_sync1;
                udp_valid_sync1 <= udp_payload_valid;
                udp_valid_sync2 <= udp_valid_sync1;
                udp_data_sync1 <= udp_payload_data;
                udp_data_sync2 <= udp_data_sync1;

                -- Default: no UART output
                uart_tx_valid <= '0';

                case state is
                    when IDLE =>
                        byte_count <= (others => '0');
                        if udp_start_sync2 = '1' then
                            state <= WAIT_START;
                        end if;

                    when WAIT_START =>
                        -- Wait for valid data byte
                        if udp_valid_sync2 = '1' then
                            captured_byte <= udp_data_sync2;
                            state <= CAPTURE_BYTE;
                        elsif udp_end_sync2 = '1' then
                            state <= SEND_NEWLINE;
                        end if;

                    when CAPTURE_BYTE =>
                        -- Send high nibble as hex
                        state <= SEND_HEX_HIGH;

                    when SEND_HEX_HIGH =>
                        uart_tx_data <= nibble_to_hex(captured_byte(7 downto 4));
                        uart_tx_valid <= '1';
                        if uart_tx_ready = '1' then
                            state <= SEND_HEX_LOW;
                        end if;

                    when SEND_HEX_LOW =>
                        uart_tx_data <= nibble_to_hex(captured_byte(3 downto 0));
                        uart_tx_valid <= '1';
                        if uart_tx_ready = '1' then
                            state <= SEND_SPACE;
                        end if;

                    when SEND_SPACE =>
                        uart_tx_data <= x"20";  -- Space
                        uart_tx_valid <= '1';
                        if uart_tx_ready = '1' then
                            byte_count <= byte_count + 1;
                            -- Check for end of payload or max bytes
                            if udp_end_sync2 = '1' or byte_count >= 63 then
                                state <= SEND_NEWLINE;
                            else
                                state <= WAIT_START;
                            end if;
                        end if;

                    when SEND_NEWLINE =>
                        uart_tx_data <= x"0A";  -- Newline '\n'
                        uart_tx_valid <= '1';
                        if uart_tx_ready = '1' then
                            state <= IDLE;
                        end if;

                    when others =>
                        state <= IDLE;
                end case;
            end if;
        end if;
    end process;

end Behavioral;
