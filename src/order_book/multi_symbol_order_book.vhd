--------------------------------------------------------------------------------
-- Module: multi_symbol_order_book
-- Description: Multi-symbol order book wrapper
--              Instantiates 8 order book managers (one per symbol)
--              Routes ITCH messages based on symbol matching
--              Arbitrates BBO outputs using round-robin scheduling
--
-- Supported Symbols: AAPL, TSLA, SPY, QQQ, GOOGL, MSFT, AMZN, NVDA
--
-- Resource Usage: ~32 RAMB36 tiles (24% of Artix-7 100T capacity)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.order_book_pkg.all;
use work.symbol_filter_pkg.all;

entity multi_symbol_order_book is
    port (
        clk                 : in  std_logic;
        reset               : in  std_logic;

        -- Software-triggered reset (via AXI-Lite register)
        soft_reset          : in std_logic;

        -- ITCH message inputs (from parser)
        msg_valid           : in  std_logic;
        msg_type            : in  std_logic_vector(7 downto 0);
        stock_symbol        : in  std_logic_vector(63 downto 0);
        order_ref           : in  std_logic_vector(63 downto 0);
        buy_sell            : in  std_logic;
        shares              : in  std_logic_vector(31 downto 0);
        price               : in  std_logic_vector(31 downto 0);

        -- Additional fields for Execute, Cancel, Replace messages
        -- Note: shares field is reused for exec_shares (E) and cancel_shares (X)
        new_order_ref       : in  std_logic_vector(63 downto 0);  -- For Replace ('U')
        new_shares          : in  std_logic_vector(31 downto 0);  -- For Replace ('U')
        new_price           : in  std_logic_vector(31 downto 0);  -- For Replace ('U')

        -- BBO output (round-robin through symbols)
        bbo_update          : out std_logic;
        bbo_symbol          : out std_logic_vector(63 downto 0);
        bbo_valid           : out std_logic;
        bid_price           : out std_logic_vector(31 downto 0);
        bid_shares          : out std_logic_vector(31 downto 0);
        ask_price           : out std_logic_vector(31 downto 0);
        ask_shares          : out std_logic_vector(31 downto 0);
        spread              : out std_logic_vector(31 downto 0);

        -- Backpressure from downstream (bbo_axi_stream ready signal)
        bbo_ready           : in  std_logic;

        -- Debug outputs for ILA (from symbol 0 = AAPL)
        dbg_bbo_state       : out std_logic_vector(4 downto 0);
        dbg_bbo_spread_reg  : out std_logic_vector(31 downto 0);
        dbg_arbiter_symbol  : out std_logic_vector(2 downto 0);
        dbg_arbiter_counter : out std_logic_vector(9 downto 0);
        dbg_ready_vec_0     : out std_logic;
        dbg_bbo_update_vec_0: out std_logic
    );
end multi_symbol_order_book;

architecture rtl of multi_symbol_order_book is

    -- Number of symbols (matches symbol_filter_pkg)
    constant NUM_SYMBOLS : integer := MAX_SYMBOLS;  -- 8

    -- Symbol match signals
    signal symbol_match : std_logic_vector(NUM_SYMBOLS-1 downto 0);

    -- Per-symbol message valid signals
    type msg_valid_array is array (0 to NUM_SYMBOLS-1) of std_logic;
    signal book_msg_valid : msg_valid_array;

    -- Per-symbol BBO outputs (using bbo_t record type from order_book_pkg)
    type bbo_update_array is array (0 to NUM_SYMBOLS-1) of std_logic;
    type bbo_data_array is array (0 to NUM_SYMBOLS-1) of bbo_t;
    type stats_array is array (0 to NUM_SYMBOLS-1) of order_book_stats_t;
    type ready_array is array (0 to NUM_SYMBOLS-1) of std_logic;

    signal bbo_update_vec  : bbo_update_array;
    signal bbo_data_vec    : bbo_data_array;
    signal stats_vec       : stats_array;
    signal ready_vec       : ready_array;

    -- BBO arbiter
    signal current_symbol  : integer range 0 to NUM_SYMBOLS-1 := 0;
    signal arbiter_counter : unsigned(9 downto 0) := (others => '0');

    -- Previous BBO state (for change detection per symbol)
    type prev_bbo_array is array (0 to NUM_SYMBOLS-1) of bbo_t;
    signal prev_bbo : prev_bbo_array;

    -- Polarity inversion for ITCH side (ITCH: '1'=Buy, '0'=Sell → OB: '0'=Buy, '1'=Sell)
    signal itch_side_inverted : std_logic;

    -- Debug signals from order_book_manager instances
    type dbg_state_array is array (0 to NUM_SYMBOLS-1) of std_logic_vector(4 downto 0);
    type dbg_spread_array is array (0 to NUM_SYMBOLS-1) of std_logic_vector(31 downto 0);
    signal dbg_bbo_state_vec : dbg_state_array;
    signal dbg_bbo_spread_vec : dbg_spread_array;

begin

    -- Invert buy_sell polarity for order book managers
    itch_side_inverted <= not buy_sell;

    ----------------------------------------------------------------------------
    -- Symbol Demultiplexer
    -- Routes incoming ITCH messages to correct order book based on symbol match
    ----------------------------------------------------------------------------
    process(stock_symbol)
    begin
        symbol_match <= (others => '0');
        for i in 0 to NUM_SYMBOLS-1 loop
            if stock_symbol = FILTER_SYMBOL_LIST(i) then
                symbol_match(i) <= '1';
            end if;
        end loop;
    end process;

    -- Route msg_valid to matched order book
    gen_msg_valid: for i in 0 to NUM_SYMBOLS-1 generate
        book_msg_valid(i) <= msg_valid when symbol_match(i) = '1' else '0';
    end generate;

    ----------------------------------------------------------------------------
    -- Order Book Instances (one per symbol)
    ----------------------------------------------------------------------------
    gen_order_books: for i in 0 to NUM_SYMBOLS-1 generate
        book_inst: entity work.order_book_manager
            generic map (
                TARGET_SYMBOL => FILTER_SYMBOL_LIST(i)
            )
            port map (
                clk => clk,
                rst => reset,
                soft_reset => soft_reset,

                -- ITCH message inputs (Note: order_book_manager needs ALL ITCH inputs)
                itch_valid          => book_msg_valid(i),
                itch_msg_type       => msg_type,
                itch_order_ref      => order_ref,
                itch_symbol         => stock_symbol,
                itch_side           => itch_side_inverted,  -- Inverted polarity signal
                itch_shares         => shares,
                itch_price          => price,
                -- For Execute ('E') and Cancel ('X'), shares field carries exec_shares/cancel_shares
                -- Order book manager uses itch_shares directly for these (based on msg_type)
                itch_exec_shares    => shares,  -- Shares field carries exec_shares for 'E'
                itch_cancel_shares  => shares,  -- Shares field carries cancel_shares for 'X'
                -- For Replace ('U'), pass new order fields
                itch_new_order_ref  => new_order_ref,
                itch_new_price      => new_price,
                itch_new_shares     => new_shares,

                -- BBO output
                bbo                 => bbo_data_vec(i),
                bbo_update          => bbo_update_vec(i),

                -- Statistics
                stats               => stats_vec(i),

                -- Ready signal
                ready               => ready_vec(i),

                -- Debug outputs
                dbg_bbo_state       => dbg_bbo_state_vec(i),
                dbg_bbo_spread_reg  => dbg_bbo_spread_vec(i)
            );
    end generate;

    ----------------------------------------------------------------------------
    -- BBO Arbiter (Round-Robin with Change Detection and Backpressure)
    -- Cycles through 8 symbols at ~10 µs per symbol (80 µs full cycle)
    -- Only outputs BBO when:
    --   1. BBO has changed for current symbol, AND
    --   2. Order book manager is ready (not in middle of BBO scan), AND
    --   3. Downstream (bbo_axi_stream) is ready (bbo_ready = '1')
    --
    -- TIMING: bbo_update and all data outputs (bid/ask/spread) are registered
    -- on the SAME clock edge. The downstream (bbo_axi_stream) samples all signals
    -- on the next clock edge, when all outputs are stable.
    --
    -- IMPORTANT: Must wait for ready_vec to ensure spread calculation is complete!
    -- The BBO scan updates bid/ask prices during scanning, but spread is only
    -- calculated at the end (COMPUTE_SPREAD state). Outputting before ready
    -- results in stale spread values.
    ----------------------------------------------------------------------------
    process(clk)
        variable change_detected : boolean := false;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                current_symbol <= 0;
                arbiter_counter <= (others => '0');
                bbo_update <= '0';

                -- Initialize previous BBO state (match bbo_tracker initialization)
                for i in 0 to NUM_SYMBOLS-1 loop
                    prev_bbo(i).valid <= '0';
                    prev_bbo(i).bid_price <= (others => '0');
                    prev_bbo(i).bid_shares <= (others => '0');
                    prev_bbo(i).ask_price <= (others => '1');
                    prev_bbo(i).ask_shares <= (others => '0');
                    prev_bbo(i).spread <= (others => '0');
                end loop;

            else
                -- Default: no BBO update
                bbo_update <= '0';

                -- Round-robin arbiter: cycle every 1000 clock cycles (8 µs @ 125 MHz)
                -- BUT only advance if downstream is ready (backpressure)
                if arbiter_counter = 999 then
                    -- Check if current symbol has changed AND order book is ready
                    -- ready_vec indicates the BBO tracker has completed its scan,
                    -- ensuring spread calculation is up-to-date
                    change_detected :=
                       (bbo_data_vec(current_symbol).valid /= prev_bbo(current_symbol).valid) or
                       (bbo_data_vec(current_symbol).bid_price /= prev_bbo(current_symbol).bid_price) or
                       (bbo_data_vec(current_symbol).bid_shares /= prev_bbo(current_symbol).bid_shares) or
                       (bbo_data_vec(current_symbol).ask_price /= prev_bbo(current_symbol).ask_price) or
                       (bbo_data_vec(current_symbol).ask_shares /= prev_bbo(current_symbol).ask_shares) or
                       (bbo_data_vec(current_symbol).spread /= prev_bbo(current_symbol).spread);

                    if change_detected and ready_vec(current_symbol) = '1' then
                        -- BBO changed AND order book is ready (spread calculated)!
                        -- Check if downstream is ready
                        if bbo_ready = '1' then
                            -- Downstream ready, latch the BBO data
                            -- Output bbo_update NOW (same cycle as data)
                            -- Data outputs are registered, so they're stable when sampled
                            bbo_update <= '1';
                            bbo_symbol <= FILTER_SYMBOL_LIST(current_symbol);
                            bbo_valid <= bbo_data_vec(current_symbol).valid;
                            bid_price <= bbo_data_vec(current_symbol).bid_price;
                            bid_shares <= bbo_data_vec(current_symbol).bid_shares;
                            ask_price <= bbo_data_vec(current_symbol).ask_price;
                            ask_shares <= bbo_data_vec(current_symbol).ask_shares;
                            spread <= bbo_data_vec(current_symbol).spread;

                            -- Update previous state
                            prev_bbo(current_symbol) <= bbo_data_vec(current_symbol);

                            -- Move to next symbol and reset counter
                            arbiter_counter <= (others => '0');
                            if current_symbol = NUM_SYMBOLS-1 then
                                current_symbol <= 0;
                            else
                                current_symbol <= current_symbol + 1;
                            end if;
                        -- else: downstream busy, hold counter at 999 and wait
                        end if;
                    elsif not change_detected then
                        -- No change, move to next symbol
                        arbiter_counter <= (others => '0');
                        if current_symbol = NUM_SYMBOLS-1 then
                            current_symbol <= 0;
                        else
                            current_symbol <= current_symbol + 1;
                        end if;
                    -- else: change detected but order book busy, hold and wait
                    end if;

                else
                    arbiter_counter <= arbiter_counter + 1;
                end if;

            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Debug Output Assignments (for ILA probing)
    -- Track the CURRENTLY ACTIVE symbol from arbiter, not hardcoded symbol 0
    -- This allows ILA to see the actual data being output when bbo_update fires
    ----------------------------------------------------------------------------
    dbg_bbo_state       <= dbg_bbo_state_vec(current_symbol);
    dbg_bbo_spread_reg  <= dbg_bbo_spread_vec(current_symbol);
    dbg_arbiter_symbol  <= std_logic_vector(to_unsigned(current_symbol, 3));
    dbg_arbiter_counter <= std_logic_vector(arbiter_counter);
    dbg_ready_vec_0     <= ready_vec(current_symbol);
    dbg_bbo_update_vec_0 <= bbo_update_vec(current_symbol);

end rtl;
