----------------------------------------------------------------------------------
-- PCIe Debug Formatter - Minimal UART debug output for PCIe/XDMA debugging
--
-- Outputs a simple status line every ~500ms:
--   "PCIe: wr=XXXXXXXX rd=XXXXXXXX tx=XXXXXXXX tv=X tr=X st=X\r\n"
--
-- Much simpler than debug_formatter to reduce timing complexity
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pcie_debug_formatter is
    Port (
        clk                 : in  STD_LOGIC;  -- 200MHz system clock
        reset               : in  STD_LOGIC;

        -- PCIe debug signals (directly from pcie_bbo_top, same clock domain)
        pcie_cdc_wr_count   : in  STD_LOGIC_VECTOR(31 downto 0);
        pcie_cdc_rd_count   : in  STD_LOGIC_VECTOR(31 downto 0);
        pcie_axis_tx_count  : in  STD_LOGIC_VECTOR(31 downto 0);
        pcie_tvalid_now     : in  STD_LOGIC;
        pcie_tready_now     : in  STD_LOGIC;
        pcie_axi_state      : in  STD_LOGIC_VECTOR(3 downto 0);
        pcie_link_up        : in  STD_LOGIC;

        -- UART TX interface
        uart_tx_data        : out STD_LOGIC_VECTOR(7 downto 0);
        uart_tx_start       : out STD_LOGIC;
        uart_tx_busy        : in  STD_LOGIC
    );
end pcie_debug_formatter;

architecture Behavioral of pcie_debug_formatter is

    -- Helper function to convert 4-bit nibble to ASCII hex
    function nibble_to_hex(nibble : unsigned(3 downto 0)) return std_logic_vector is
    begin
        if nibble < 10 then
            return std_logic_vector(x"30" + resize(nibble, 8));  -- '0'-'9'
        else
            return std_logic_vector(x"37" + resize(nibble, 8));  -- 'A'-'F'
        end if;
    end function;

    -- State machine
    type state_t is (IDLE, SEND_CHAR, WAIT_BUSY);
    signal state : state_t := IDLE;
    signal char_index : unsigned(6 downto 0) := (others => '0');

    -- Timer for periodic output (~500ms at 200MHz)
    signal timer : unsigned(26 downto 0) := (others => '0');
    constant TIMER_MAX : unsigned(26 downto 0) := to_unsigned(100_000_000, 27);  -- 500ms

    -- Sampled values (latch at start of transmission)
    signal wr_count_s : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal rd_count_s : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal tx_count_s : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal tvalid_s   : STD_LOGIC := '0';
    signal tready_s   : STD_LOGIC := '0';
    signal axi_state_s: STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal link_up_s  : STD_LOGIC := '0';

    -- Message: "PCIe: wr=XXXXXXXX rd=XXXXXXXX tx=XXXXXXXX tv=X tr=X st=X lk=X\r\n"
    -- Length: 64 characters
    constant MSG_LEN : integer := 64;

    signal uart_data_int : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal uart_start_int : STD_LOGIC := '0';

begin

    uart_tx_data <= uart_data_int;
    uart_tx_start <= uart_start_int;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                char_index <= (others => '0');
                timer <= (others => '0');
                uart_start_int <= '0';
            else
                case state is
                    when IDLE =>
                        uart_start_int <= '0';
                        timer <= timer + 1;

                        if timer >= TIMER_MAX then
                            timer <= (others => '0');
                            -- Sample current values
                            wr_count_s <= pcie_cdc_wr_count;
                            rd_count_s <= pcie_cdc_rd_count;
                            tx_count_s <= pcie_axis_tx_count;
                            tvalid_s <= pcie_tvalid_now;
                            tready_s <= pcie_tready_now;
                            axi_state_s <= pcie_axi_state;
                            link_up_s <= pcie_link_up;
                            char_index <= (others => '0');
                            state <= SEND_CHAR;
                        end if;

                    when SEND_CHAR =>
                        if uart_tx_busy = '0' then
                            uart_start_int <= '1';

                            case to_integer(char_index) is
                                -- "PCIe: "
                                when 0 => uart_data_int <= x"50";  -- 'P'
                                when 1 => uart_data_int <= x"43";  -- 'C'
                                when 2 => uart_data_int <= x"49";  -- 'I'
                                when 3 => uart_data_int <= x"65";  -- 'e'
                                when 4 => uart_data_int <= x"3A";  -- ':'
                                when 5 => uart_data_int <= x"20";  -- ' '

                                -- "wr="
                                when 6 => uart_data_int <= x"77";  -- 'w'
                                when 7 => uart_data_int <= x"72";  -- 'r'
                                when 8 => uart_data_int <= x"3D";  -- '='
                                -- wr_count hex (8 chars)
                                when 9  => uart_data_int <= nibble_to_hex(unsigned(wr_count_s(31 downto 28)));
                                when 10 => uart_data_int <= nibble_to_hex(unsigned(wr_count_s(27 downto 24)));
                                when 11 => uart_data_int <= nibble_to_hex(unsigned(wr_count_s(23 downto 20)));
                                when 12 => uart_data_int <= nibble_to_hex(unsigned(wr_count_s(19 downto 16)));
                                when 13 => uart_data_int <= nibble_to_hex(unsigned(wr_count_s(15 downto 12)));
                                when 14 => uart_data_int <= nibble_to_hex(unsigned(wr_count_s(11 downto 8)));
                                when 15 => uart_data_int <= nibble_to_hex(unsigned(wr_count_s(7 downto 4)));
                                when 16 => uart_data_int <= nibble_to_hex(unsigned(wr_count_s(3 downto 0)));

                                when 17 => uart_data_int <= x"20";  -- ' '

                                -- "rd="
                                when 18 => uart_data_int <= x"72";  -- 'r'
                                when 19 => uart_data_int <= x"64";  -- 'd'
                                when 20 => uart_data_int <= x"3D";  -- '='
                                -- rd_count hex (8 chars)
                                when 21 => uart_data_int <= nibble_to_hex(unsigned(rd_count_s(31 downto 28)));
                                when 22 => uart_data_int <= nibble_to_hex(unsigned(rd_count_s(27 downto 24)));
                                when 23 => uart_data_int <= nibble_to_hex(unsigned(rd_count_s(23 downto 20)));
                                when 24 => uart_data_int <= nibble_to_hex(unsigned(rd_count_s(19 downto 16)));
                                when 25 => uart_data_int <= nibble_to_hex(unsigned(rd_count_s(15 downto 12)));
                                when 26 => uart_data_int <= nibble_to_hex(unsigned(rd_count_s(11 downto 8)));
                                when 27 => uart_data_int <= nibble_to_hex(unsigned(rd_count_s(7 downto 4)));
                                when 28 => uart_data_int <= nibble_to_hex(unsigned(rd_count_s(3 downto 0)));

                                when 29 => uart_data_int <= x"20";  -- ' '

                                -- "tx="
                                when 30 => uart_data_int <= x"74";  -- 't'
                                when 31 => uart_data_int <= x"78";  -- 'x'
                                when 32 => uart_data_int <= x"3D";  -- '='
                                -- tx_count hex (8 chars)
                                when 33 => uart_data_int <= nibble_to_hex(unsigned(tx_count_s(31 downto 28)));
                                when 34 => uart_data_int <= nibble_to_hex(unsigned(tx_count_s(27 downto 24)));
                                when 35 => uart_data_int <= nibble_to_hex(unsigned(tx_count_s(23 downto 20)));
                                when 36 => uart_data_int <= nibble_to_hex(unsigned(tx_count_s(19 downto 16)));
                                when 37 => uart_data_int <= nibble_to_hex(unsigned(tx_count_s(15 downto 12)));
                                when 38 => uart_data_int <= nibble_to_hex(unsigned(tx_count_s(11 downto 8)));
                                when 39 => uart_data_int <= nibble_to_hex(unsigned(tx_count_s(7 downto 4)));
                                when 40 => uart_data_int <= nibble_to_hex(unsigned(tx_count_s(3 downto 0)));

                                when 41 => uart_data_int <= x"20";  -- ' '

                                -- "tv="
                                when 42 => uart_data_int <= x"74";  -- 't'
                                when 43 => uart_data_int <= x"76";  -- 'v'
                                when 44 => uart_data_int <= x"3D";  -- '='
                                when 45 => uart_data_int <= x"30" or ("0000000" & tvalid_s);

                                when 46 => uart_data_int <= x"20";  -- ' '

                                -- "tr="
                                when 47 => uart_data_int <= x"74";  -- 't'
                                when 48 => uart_data_int <= x"72";  -- 'r'
                                when 49 => uart_data_int <= x"3D";  -- '='
                                when 50 => uart_data_int <= x"30" or ("0000000" & tready_s);

                                when 51 => uart_data_int <= x"20";  -- ' '

                                -- "st="
                                when 52 => uart_data_int <= x"73";  -- 's'
                                when 53 => uart_data_int <= x"74";  -- 't'
                                when 54 => uart_data_int <= x"3D";  -- '='
                                when 55 => uart_data_int <= x"30" or ("0000" & axi_state_s);

                                when 56 => uart_data_int <= x"20";  -- ' '

                                -- "lk="
                                when 57 => uart_data_int <= x"6C";  -- 'l'
                                when 58 => uart_data_int <= x"6B";  -- 'k'
                                when 59 => uart_data_int <= x"3D";  -- '='
                                when 60 => uart_data_int <= x"30" or ("0000000" & link_up_s);

                                -- "\r\n"
                                when 61 => uart_data_int <= x"0D";  -- CR
                                when 62 => uart_data_int <= x"0A";  -- LF

                                when others => uart_data_int <= x"20";
                            end case;

                            state <= WAIT_BUSY;
                        end if;

                    when WAIT_BUSY =>
                        uart_start_int <= '0';
                        if uart_tx_busy = '1' then
                            -- Byte accepted, advance
                            if char_index >= MSG_LEN - 1 then
                                state <= IDLE;
                            else
                                char_index <= char_index + 1;
                                state <= SEND_CHAR;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

end Behavioral;
