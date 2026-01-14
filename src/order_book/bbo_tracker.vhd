--------------------------------------------------------------------------------
-- Module: bbo_tracker
-- Description: Best Bid/Offer (BBO) tracker
--
-- Maintains:
--   - Best Bid (highest buy price)
--   - Best Ask (lowest sell price)
--   - Spread (ask - bid)
--
-- Strategy: Scan all price levels to find best bid/ask
-- Latency: BBO_SCAN_DEPTH * 7 cycles per side (6-cycle BRAM read latency + 1)
--          Total: ~7168 cycles = 35.8 µs @ 200 MHz for 512 levels per side
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.order_book_pkg.all;

entity bbo_tracker is
    Port (
        clk     : in  std_logic;
        rst     : in  std_logic;

        -- Software-triggered reset (via AXI-Lite register)
        soft_reset : in std_logic;

        -- Price level interface (reads from price_level_table)
        level_req       : out std_logic;
        level_addr      : out std_logic_vector(PRICE_ADDR_WIDTH-1 downto 0);
        level_data      : in  price_level_t;
        level_valid     : in  std_logic;

        -- Update trigger
        update_trigger  : in  std_logic;  -- Start BBO scan

        -- BBO output
        bbo             : out bbo_t;
        bbo_update      : out std_logic;  -- Strobe when BBO changes
        bbo_ready       : out std_logic;  -- BBO calculation complete

        -- Debug outputs for ILA
        dbg_state       : out std_logic_vector(4 downto 0);  -- FSM state
        dbg_spread_reg  : out std_logic_vector(31 downto 0)  -- Internal spread register
    );
end bbo_tracker;

architecture Behavioral of bbo_tracker is

    -- FSM states
    -- Note: 6-cycle latency from level_req to level_valid:
    --   Cycle 0: level_req='1' issued
    --   Cycle 1: order_book_manager sees level_req, issues price_cmd_valid
    --   Cycle 2: price_level_table captures command (pipe_cmd_valid='1')
    --   Cycle 3: BRAM read completes (bram_do valid), pipe_cmd_valid_d1='1'
    --   Cycle 4: rd_data_stage1 captures bram_do, rd_valid_stage1='1'
    --   Cycle 5: rd_data_stage2 captures stage1, rd_valid_stage2='1'
    --   Cycle 6: rd_valid='1', level_data valid
    type state_t is (IDLE, SCAN_BIDS, SCAN_BIDS_WAIT1, SCAN_BIDS_WAIT2, SCAN_BIDS_WAIT3, SCAN_BIDS_WAIT4, SCAN_BIDS_WAIT5, SCAN_BIDS_WAIT6,
                     SCAN_ASKS, SCAN_ASKS_WAIT1, SCAN_ASKS_WAIT2, SCAN_ASKS_WAIT3, SCAN_ASKS_WAIT4, SCAN_ASKS_WAIT5, SCAN_ASKS_WAIT6,
                     COMPUTE_SPREAD, DONE);
    signal state : state_t := IDLE;

    -- BBO registers
    signal best_bid_price_reg   : std_logic_vector(31 downto 0) := (others => '0');
    signal best_bid_shares_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal best_ask_price_reg   : std_logic_vector(31 downto 0) := (others => '1');
    signal best_ask_shares_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal best_spread_reg      : std_logic_vector(31 downto 0) := (others => '0');
    signal bbo_valid_reg        : std_logic := '0';

    -- Previous BBO (for change detection)
    signal prev_bid_price       : std_logic_vector(31 downto 0) := (others => '0');
    signal prev_bid_shares      : std_logic_vector(31 downto 0) := (others => '0');
    signal prev_ask_price       : std_logic_vector(31 downto 0) := (others => '1');
    signal prev_ask_shares      : std_logic_vector(31 downto 0) := (others => '0');
    signal prev_bbo_valid       : std_logic := '0';

    -- Scan state
    signal scan_counter         : integer range 0 to BBO_SCAN_DEPTH := 0;
    signal scan_addr            : unsigned(PRICE_ADDR_WIDTH-1 downto 0) := (others => '0');

    -- Bid scanning (scan from highest to lowest)
    signal best_bid_found       : std_logic := '0';

    -- Ask scanning (scan from lowest to highest)
    signal best_ask_found       : std_logic := '0';

    -- Staleness tracking to prevent crossed markets from stale data
    signal bid_last_scan        : unsigned(15 downto 0) := (others => '0');  -- Last scan where bid was updated
    signal ask_last_scan        : unsigned(15 downto 0) := (others => '0');  -- Last scan where ask was updated
    signal scan_cycle_count     : unsigned(15 downto 0) := (others => '0');  -- Total scan cycles completed
    constant STALE_THRESHOLD    : unsigned(15 downto 0) := to_unsigned(3, 16);  -- Clear after 3 scans without update (~0.05-0.2 sec)

    -- First scan flag (force update on first scan even if nothing changed)
    signal first_scan           : std_logic := '1';

begin

    -- Output BBO (all fields assigned from registers)
    bbo.bid_price   <= best_bid_price_reg;
    bbo.bid_shares  <= best_bid_shares_reg;
    bbo.ask_price   <= best_ask_price_reg;
    bbo.ask_shares  <= best_ask_shares_reg;
    bbo.valid       <= bbo_valid_reg;

    -- Spread is computed COMBINATORIALLY from current bid/ask prices
    -- This ensures spread is always in sync with prices (no pipeline delay)
    -- Crossed market or equal prices result in spread = 0
    bbo.spread <= std_logic_vector(unsigned(best_ask_price_reg) - unsigned(best_bid_price_reg))
                  when (best_bid_price_reg /= x"00000000") and
                       (best_ask_price_reg /= x"FFFFFFFF") and
                       (unsigned(best_ask_price_reg) > unsigned(best_bid_price_reg))
                  else (others => '0');

    ------------------------------------------------------------------------
    -- BBO Tracking FSM
    ------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or soft_reset = '1' then
                state <= IDLE;
                best_bid_price_reg <= (others => '0');
                best_bid_shares_reg <= (others => '0');
                best_ask_price_reg <= (others => '1');
                best_ask_shares_reg <= (others => '0');
                best_spread_reg <= (others => '0');
                bbo_valid_reg <= '0';
                bbo_update <= '0';
                bbo_ready <= '1';
                level_req <= '0';
                scan_counter <= 0;
                best_bid_found <= '0';
                best_ask_found <= '0';
                first_scan <= '1';
                -- Reset staleness tracking
                scan_cycle_count <= (others => '0');
                bid_last_scan <= (others => '0');
                ask_last_scan <= (others => '0');
            else
                -- Default outputs
                bbo_update <= '0';
                level_req <= '0';

                case state is
                    when IDLE =>
                        bbo_ready <= '1';

                        -- SAFE: Clear stale data during IDLE (no PCIe reads active, no combinatorial paths)
                        -- This prevents crossed markets from retaining old bid/ask data
                        if (scan_cycle_count > bid_last_scan) and ((scan_cycle_count - bid_last_scan) > STALE_THRESHOLD) then
                            if best_bid_price_reg /= x"00000000" then
                                -- Bid is stale, clear it
                                best_bid_price_reg <= (others => '0');
                                best_bid_shares_reg <= (others => '0');
                            end if;
                        end if;

                        if (scan_cycle_count > ask_last_scan) and ((scan_cycle_count - ask_last_scan) > STALE_THRESHOLD) then
                            if best_ask_price_reg /= x"FFFFFFFF" then
                                -- Ask is stale, clear it
                                best_ask_price_reg <= (others => '1');  -- Reset to max value
                                best_ask_shares_reg <= (others => '0');
                            end if;
                        end if;

                        if update_trigger = '1' then
                            -- Start BBO scan
                            state <= SCAN_BIDS;
                            scan_counter <= 0;
                            scan_addr <= to_unsigned(MAX_BID_LEVELS - 1, PRICE_ADDR_WIDTH);  -- Start from highest bid
                            best_bid_found <= '0';
                            best_ask_found <= '0';
                            prev_bid_price <= best_bid_price_reg;
                            prev_bid_shares <= best_bid_shares_reg;
                            prev_ask_price <= best_ask_price_reg;
                            prev_ask_shares <= best_ask_shares_reg;
                            prev_bbo_valid <= bbo_valid_reg;
                            bbo_ready <= '0';
                        end if;

                    when SCAN_BIDS =>
                        -- Scan all bid levels from high to low (addresses MAX_BID_LEVELS-1 down to 0)
                        if scan_counter < BBO_SCAN_DEPTH then
                            level_req <= '1';
                            level_addr <= std_logic_vector(scan_addr);
                            state <= SCAN_BIDS_WAIT1;
                        else
                            -- Done scanning bids
                            -- Don't clear registers if nothing found - keep previous values
                            -- Registers are only updated when valid data is found in SCAN_BIDS_WAIT2

                            -- Move to ask scanning
                            state <= SCAN_ASKS;
                            scan_counter <= 0;
                            scan_addr <= to_unsigned(MAX_BID_LEVELS, PRICE_ADDR_WIDTH);  -- Start from lowest ask
                        end if;

                    when SCAN_BIDS_WAIT1 =>
                        -- Wait cycle 1 (6-cycle read latency total)
                        level_req <= '0';
                        state <= SCAN_BIDS_WAIT2;

                    when SCAN_BIDS_WAIT2 =>
                        -- Wait cycle 2
                        level_req <= '0';
                        state <= SCAN_BIDS_WAIT3;

                    when SCAN_BIDS_WAIT3 =>
                        -- Wait cycle 3
                        level_req <= '0';
                        state <= SCAN_BIDS_WAIT4;

                    when SCAN_BIDS_WAIT4 =>
                        -- Wait cycle 4
                        level_req <= '0';
                        state <= SCAN_BIDS_WAIT5;

                    when SCAN_BIDS_WAIT5 =>
                        -- Wait cycle 5
                        level_req <= '0';
                        state <= SCAN_BIDS_WAIT6;

                    when SCAN_BIDS_WAIT6 =>
                        -- Wait cycle 6 - data should be valid now (6-cycle latency)
                        level_req <= '0';

                        -- Check if valid bid data received
                        if level_valid = '1' and level_data.valid = '1' and level_data.side = '0' then
                            -- Found valid bid level
                            if best_bid_found = '0' then
                                -- First bid found
                                best_bid_price_reg <= level_data.price;
                                best_bid_shares_reg <= level_data.total_shares;
                                best_bid_found <= '1';
                                bid_last_scan <= scan_cycle_count;  -- Update timestamp
                            elsif unsigned(level_data.price) > unsigned(best_bid_price_reg) then
                                -- Found higher bid price, update
                                best_bid_price_reg <= level_data.price;
                                best_bid_shares_reg <= level_data.total_shares;
                                bid_last_scan <= scan_cycle_count;  -- Update timestamp
                            end if;
                        end if;

                        -- Move to next level (scan down: MAX_BID_LEVELS-1 -> ... -> 0)
                        if scan_addr > 0 then
                            scan_addr <= scan_addr - 1;
                        end if;
                        scan_counter <= scan_counter + 1;
                        state <= SCAN_BIDS;

                    when SCAN_ASKS =>
                        -- Scan all ask levels from low to high (addresses MAX_BID_LEVELS up to MAX_PRICE_LEVELS-1)
                        if scan_counter < BBO_SCAN_DEPTH then
                            level_req <= '1';
                            level_addr <= std_logic_vector(scan_addr);
                            state <= SCAN_ASKS_WAIT1;
                        else
                            -- Done scanning asks
                            -- Don't clear registers if nothing found - keep previous values
                            -- Registers are only updated when valid data is found in SCAN_ASKS_WAIT2

                            state <= COMPUTE_SPREAD;
                        end if;

                    when SCAN_ASKS_WAIT1 =>
                        -- Wait cycle 1 (6-cycle read latency total)
                        level_req <= '0';
                        state <= SCAN_ASKS_WAIT2;

                    when SCAN_ASKS_WAIT2 =>
                        -- Wait cycle 2
                        level_req <= '0';
                        state <= SCAN_ASKS_WAIT3;

                    when SCAN_ASKS_WAIT3 =>
                        -- Wait cycle 3
                        level_req <= '0';
                        state <= SCAN_ASKS_WAIT4;

                    when SCAN_ASKS_WAIT4 =>
                        -- Wait cycle 4
                        level_req <= '0';
                        state <= SCAN_ASKS_WAIT5;

                    when SCAN_ASKS_WAIT5 =>
                        -- Wait cycle 5
                        level_req <= '0';
                        state <= SCAN_ASKS_WAIT6;

                    when SCAN_ASKS_WAIT6 =>
                        -- Wait cycle 6 - data should be valid now (6-cycle latency)
                        level_req <= '0';

                        -- Check if valid ask data received
                        if level_valid = '1' and level_data.valid = '1' and level_data.side = '1' then
                            -- Found valid ask level
                            if best_ask_found = '0' then
                                -- First ask found
                                best_ask_price_reg <= level_data.price;
                                best_ask_shares_reg <= level_data.total_shares;
                                best_ask_found <= '1';
                                ask_last_scan <= scan_cycle_count;  -- Update timestamp
                            elsif unsigned(level_data.price) < unsigned(best_ask_price_reg) then
                                -- Found lower ask price, update
                                best_ask_price_reg <= level_data.price;
                                best_ask_shares_reg <= level_data.total_shares;
                                ask_last_scan <= scan_cycle_count;  -- Update timestamp
                            end if;
                        end if;

                        -- Move to next level (scan up: MAX_BID_LEVELS -> ... -> MAX_PRICE_LEVELS-1)
                        if scan_addr < MAX_PRICE_LEVELS - 1 then
                            scan_addr <= scan_addr + 1;
                        end if;
                        scan_counter <= scan_counter + 1;
                        state <= SCAN_ASKS;

                    when COMPUTE_SPREAD =>
                        -- Check for valid bid/ask data in registers (not just from current scan)
                        -- Bid is valid if non-zero, Ask is valid if not 0xFFFFFFFF (initial value)
                        -- This allows spread to be calculated even if only one side updated in this scan
                        if (best_bid_price_reg /= x"00000000") or (best_ask_price_reg /= x"FFFFFFFF") then
                            bbo_valid_reg <= '1';

                            -- Calculate spread only if BOTH sides exist in registers
                            if (best_bid_price_reg /= x"00000000") and (best_ask_price_reg /= x"FFFFFFFF") then
                                -- Both sides exist, calculate spread
                                if unsigned(best_ask_price_reg) > unsigned(best_bid_price_reg) then
                                    best_spread_reg <= std_logic_vector(unsigned(best_ask_price_reg) - unsigned(best_bid_price_reg));
                                else
                                    best_spread_reg <= (others => '0');  -- Crossed market or equal
                                end if;
                            else
                                -- Only one side exists, spread is zero/undefined
                                best_spread_reg <= (others => '0');
                            end if;
                        else
                            -- No valid bid or ask data - mark BBO as invalid
                            bbo_valid_reg <= '0';
                            best_spread_reg <= (others => '0');
                        end if;

                        state <= DONE;

                    when DONE =>
                        -- Pulse bbo_update if BBO changed (price, shares, or valid status)
                        -- OR if this is the first scan (to initialize output)
                        if first_scan = '1' or
                           (best_bid_price_reg /= prev_bid_price) or
                           (best_bid_shares_reg /= prev_bid_shares) or
                           (best_ask_price_reg /= prev_ask_price) or
                           (best_ask_shares_reg /= prev_ask_shares) or
                           (bbo_valid_reg /= prev_bbo_valid) then
                            bbo_update <= '1';  -- BBO changed!
                        end if;

                        -- Clear first_scan flag after first scan completes
                        first_scan <= '0';

                        -- Increment scan cycle counter for staleness tracking
                        scan_cycle_count <= scan_cycle_count + 1;

                        state <= IDLE;
                        bbo_ready <= '1';

                    when others =>
                        state <= IDLE;
                end case;
            end if;
        end if;
    end process;

    -- Debug outputs for ILA (use combinatorial spread to match bbo.spread)
    dbg_spread_reg <= std_logic_vector(unsigned(best_ask_price_reg) - unsigned(best_bid_price_reg))
                      when (best_bid_price_reg /= x"00000000") and
                           (best_ask_price_reg /= x"FFFFFFFF") and
                           (unsigned(best_ask_price_reg) > unsigned(best_bid_price_reg))
                      else (others => '0');

    -- Encode FSM state as 5-bit value for ILA
    with state select dbg_state <=
        "00000" when IDLE,
        "00001" when SCAN_BIDS,
        "00010" when SCAN_BIDS_WAIT1,
        "00011" when SCAN_BIDS_WAIT2,
        "00100" when SCAN_BIDS_WAIT3,
        "00101" when SCAN_BIDS_WAIT4,
        "00110" when SCAN_BIDS_WAIT5,
        "00111" when SCAN_BIDS_WAIT6,
        "01000" when SCAN_ASKS,
        "01001" when SCAN_ASKS_WAIT1,
        "01010" when SCAN_ASKS_WAIT2,
        "01011" when SCAN_ASKS_WAIT3,
        "01100" when SCAN_ASKS_WAIT4,
        "01101" when SCAN_ASKS_WAIT5,
        "01110" when SCAN_ASKS_WAIT6,
        "01111" when COMPUTE_SPREAD,
        "10000" when DONE,
        "11111" when others;

end Behavioral;
