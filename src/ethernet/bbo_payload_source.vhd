----------------------------------------------------------------------------------
-- BBO Payload Source (with 4-Point FPGA Latency Timestamps)
-- Latches BBO data on bbo_update pulse, provides payload bytes for udp_tx
--
-- BBO Message Format (44 bytes):
--   Bytes 0-7:   Symbol (8 bytes)
--   Bytes 8-11:  Bid Price (4 bytes, big endian)
--   Bytes 12-15: Bid Size (4 bytes, big endian)
--   Bytes 16-19: Ask Price (4 bytes, big endian)
--   Bytes 20-23: Ask Size (4 bytes, big endian)
--   Bytes 24-27: Spread (4 bytes, big endian)
--   Bytes 28-31: T1 - ITCH parse timestamp (125 MHz RGMII RX domain)
--   Bytes 32-35: T2 - itch_cdc_fifo write timestamp (125 MHz RGMII RX domain)
--   Bytes 36-39: T3 - bbo_fifo read timestamp (125 MHz TX domain)
--   Bytes 40-43: T4 - UDP TX start timestamp (125 MHz TX domain)
--
-- Latency Calculation (all 125 MHz = 8 ns per cycle):
--   Latency A = (T2 - T1) * 8 ns  (ITCH parse to CDC FIFO write)
--   Latency B = (T4 - T3) * 8 ns  (bbo_fifo read to TX start)
--   Total FPGA Latency = A + B
--
-- Clock Domains:
--   T1, T2: 125 MHz RGMII RX clock (8 ns per cycle)
--   T3, T4: 125 MHz TX clock (8 ns per cycle)
-- Note: T1, T2 pass through 200 MHz domain (itch_cdc_fifo -> order book -> bbo_fifo)
--       but the cycle counts themselves are from the 125 MHz domain
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity bbo_payload_source is
    Generic (
        PAYLOAD_LEN : integer := 44  -- 28 bytes BBO + 16 bytes timestamps (4 x 32-bit)
    );
    Port (
        clk           : in  STD_LOGIC;
        rst           : in  STD_LOGIC;
        -- BBO input
        bbo_update    : in  STD_LOGIC;
        bbo_symbol    : in  STD_LOGIC_VECTOR(63 downto 0);
        bbo_bid_price : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_bid_size  : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_price : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_size  : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_spread    : in  STD_LOGIC_VECTOR(31 downto 0);
        -- 4-point timestamp inputs for FPGA latency measurement
        -- All timestamps are 125 MHz cycle counts (8 ns per cycle)
        ts_t1         : in  STD_LOGIC_VECTOR(31 downto 0);  -- T1: ITCH parse (125 MHz RGMII RX)
        ts_t2         : in  STD_LOGIC_VECTOR(31 downto 0);  -- T2: itch_cdc_fifo write (125 MHz RGMII RX)
        ts_t3         : in  STD_LOGIC_VECTOR(31 downto 0);  -- T3: bbo_fifo read (125 MHz TX)
        cycle_counter : in  STD_LOGIC_VECTOR(31 downto 0);  -- Current 125 MHz TX counter (for T4)
        -- udp_tx interface
        tx_start      : out STD_LOGIC;
        tx_busy       : in  STD_LOGIC;
        payload_data  : out STD_LOGIC_VECTOR(7 downto 0);
        payload_rd    : in  STD_LOGIC
    );
end bbo_payload_source;

architecture Behavioral of bbo_payload_source is

    -- Latched BBO data
    signal symbol_latched    : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal bid_price_latched : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal bid_size_latched  : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal ask_price_latched : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal ask_size_latched  : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal spread_latched    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- 4-point latency timestamps (latched)
    -- All are 125 MHz cycle counts (8 ns per cycle)
    signal t1_latched        : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');  -- T1: ITCH parse (125 MHz RGMII RX)
    signal t2_latched        : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');  -- T2: itch_cdc_fifo write (125 MHz RGMII RX)
    signal t3_latched        : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');  -- T3: bbo_fifo read (125 MHz TX)
    signal t4_latched        : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');  -- T4: TX start (125 MHz TX)

    -- State machine
    type state_type is (IDLE, WAIT_TX_START, TRANSMITTING);
    signal state : state_type := IDLE;

    -- Byte address counter
    signal addr : unsigned(5 downto 0) := (others => '0');

    -- Pending update flag
    signal update_pending : STD_LOGIC := '0';

begin

    -- Combinatorial payload byte selection based on address
    process(addr, symbol_latched, bid_price_latched, bid_size_latched,
            ask_price_latched, ask_size_latched, spread_latched,
            t1_latched, t2_latched, t3_latched, t4_latched)
    begin
        case to_integer(addr) is
            -- Symbol (8 bytes, big endian)
            when 0 => payload_data <= symbol_latched(63 downto 56);
            when 1 => payload_data <= symbol_latched(55 downto 48);
            when 2 => payload_data <= symbol_latched(47 downto 40);
            when 3 => payload_data <= symbol_latched(39 downto 32);
            when 4 => payload_data <= symbol_latched(31 downto 24);
            when 5 => payload_data <= symbol_latched(23 downto 16);
            when 6 => payload_data <= symbol_latched(15 downto 8);
            when 7 => payload_data <= symbol_latched(7 downto 0);
            -- Bid Price (4 bytes, big endian)
            when 8  => payload_data <= bid_price_latched(31 downto 24);
            when 9  => payload_data <= bid_price_latched(23 downto 16);
            when 10 => payload_data <= bid_price_latched(15 downto 8);
            when 11 => payload_data <= bid_price_latched(7 downto 0);
            -- Bid Size (4 bytes, big endian)
            when 12 => payload_data <= bid_size_latched(31 downto 24);
            when 13 => payload_data <= bid_size_latched(23 downto 16);
            when 14 => payload_data <= bid_size_latched(15 downto 8);
            when 15 => payload_data <= bid_size_latched(7 downto 0);
            -- Ask Price (4 bytes, big endian)
            when 16 => payload_data <= ask_price_latched(31 downto 24);
            when 17 => payload_data <= ask_price_latched(23 downto 16);
            when 18 => payload_data <= ask_price_latched(15 downto 8);
            when 19 => payload_data <= ask_price_latched(7 downto 0);
            -- Ask Size (4 bytes, big endian)
            when 20 => payload_data <= ask_size_latched(31 downto 24);
            when 21 => payload_data <= ask_size_latched(23 downto 16);
            when 22 => payload_data <= ask_size_latched(15 downto 8);
            when 23 => payload_data <= ask_size_latched(7 downto 0);
            -- Spread (4 bytes, big endian)
            when 24 => payload_data <= spread_latched(31 downto 24);
            when 25 => payload_data <= spread_latched(23 downto 16);
            when 26 => payload_data <= spread_latched(15 downto 8);
            when 27 => payload_data <= spread_latched(7 downto 0);
            -- T1: BBO entry timestamp (4 bytes, big endian) - 200 MHz domain, before FIFO
            when 28 => payload_data <= t1_latched(31 downto 24);
            when 29 => payload_data <= t1_latched(23 downto 16);
            when 30 => payload_data <= t1_latched(15 downto 8);
            when 31 => payload_data <= t1_latched(7 downto 0);
            -- T2: FIFO write timestamp (4 bytes, big endian) - 200 MHz domain, at FIFO write
            when 32 => payload_data <= t2_latched(31 downto 24);
            when 33 => payload_data <= t2_latched(23 downto 16);
            when 34 => payload_data <= t2_latched(15 downto 8);
            when 35 => payload_data <= t2_latched(7 downto 0);
            -- T3: FIFO read timestamp (4 bytes, big endian) - 125 MHz domain, at FIFO read
            when 36 => payload_data <= t3_latched(31 downto 24);
            when 37 => payload_data <= t3_latched(23 downto 16);
            when 38 => payload_data <= t3_latched(15 downto 8);
            when 39 => payload_data <= t3_latched(7 downto 0);
            -- T4: TX start timestamp (4 bytes, big endian) - 125 MHz domain, at UDP TX start
            when 40 => payload_data <= t4_latched(31 downto 24);
            when 41 => payload_data <= t4_latched(23 downto 16);
            when 42 => payload_data <= t4_latched(15 downto 8);
            when 43 => payload_data <= t4_latched(7 downto 0);
            when others => payload_data <= x"00";
        end case;
    end process;

    -- Main state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                tx_start <= '0';
                addr <= (others => '0');
                update_pending <= '0';
                symbol_latched <= (others => '0');
                bid_price_latched <= (others => '0');
                bid_size_latched <= (others => '0');
                ask_price_latched <= (others => '0');
                ask_size_latched <= (others => '0');
                spread_latched <= (others => '0');
                t1_latched <= (others => '0');
                t2_latched <= (others => '0');
                t3_latched <= (others => '0');
                t4_latched <= (others => '0');
            else
                -- Default
                tx_start <= '0';

                -- Capture bbo_update pulse (set pending flag)
                -- bbo_update comes from FIFO read in 125 MHz domain
                if bbo_update = '1' then
                    update_pending <= '1';
                    -- Latch BBO data immediately
                    symbol_latched <= bbo_symbol;
                    bid_price_latched <= bbo_bid_price;
                    bid_size_latched <= bbo_bid_size;
                    ask_price_latched <= bbo_ask_price;
                    ask_size_latched <= bbo_ask_size;
                    spread_latched <= bbo_spread;
                    -- Latch timestamps (all are 125 MHz cycle counts)
                    t1_latched <= ts_t1;  -- T1: ITCH parse (125 MHz RGMII RX)
                    t2_latched <= ts_t2;  -- T2: itch_cdc_fifo write (125 MHz RGMII RX)
                    -- T3: bbo_fifo read timestamp (125 MHz TX domain)
                    t3_latched <= ts_t3;  -- T3 is captured in simple_top when bbo_fifo is read
                end if;

                case state is
                    when IDLE =>
                        addr <= (others => '0');
                        -- Wait for update and TX not busy
                        if update_pending = '1' and tx_busy = '0' then
                            update_pending <= '0';
                            tx_start <= '1';
                            -- Capture T4: TX start timestamp (125 MHz domain - NOW)
                            t4_latched <= cycle_counter;
                            state <= WAIT_TX_START;
                        end if;

                    when WAIT_TX_START =>
                        -- Wait for udp_tx to acknowledge start (tx_busy goes high)
                        if tx_busy = '1' then
                            state <= TRANSMITTING;
                        end if;

                    when TRANSMITTING =>
                        -- Advance address on each payload_rd
                        if payload_rd = '1' then
                            if addr < PAYLOAD_LEN - 1 then
                                addr <= addr + 1;
                            end if;
                        end if;
                        -- Return to IDLE when transmission completes
                        if tx_busy = '0' then
                            addr <= (others => '0');
                            state <= IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
