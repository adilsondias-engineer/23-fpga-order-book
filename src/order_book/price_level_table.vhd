--------------------------------------------------------------------------------
-- Module: price_level_table
-- Description: BRAM-based price level aggregation table
--
-- Storage: 1024 entries × 82 bits = ~10 KB (3 BRAM36 blocks per symbol)
-- Organization: [0-511] = Bids, [512-1023] = Asks
--
-- Operations:
--   ADD_SHARES    : Increment shares at price level (3-cycle latency)
--   REMOVE_SHARES : Decrement shares at price level (3-cycle latency)
--   LOOKUP_LEVEL  : Read price level data (4-cycle latency)
--   CLEAR_LEVEL   : Set level to zero (1-cycle latency)
--
-- BRAM Clear on Reset:
--   On rst='1', a state machine clears all 1024 BRAM entries to zero.
--   This prevents stale data from previous runs affecting BBO calculations.
--   Clear takes ~1024 clock cycles (~5.1 µs at 200 MHz).
--   Commands are ignored during clear sequence.
--
-- BRAM Template: Write-First mode (Xilinx recommended template)
--   Cycle 1: Read old data from BRAM
--   Cycle 2: Modify and write new data to BRAM
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.order_book_pkg.all;

entity price_level_table is
    Port (
        clk     : in  std_logic;
        rst     : in  std_logic;

        -- Command interface
        cmd_valid   : in  std_logic;
        cmd_type    : in  std_logic_vector(1 downto 0);  -- 00=ADD, 01=REMOVE, 10=LOOKUP, 11=CLEAR
        cmd_addr    : in  std_logic_vector(PRICE_ADDR_WIDTH-1 downto 0);
        cmd_price   : in  std_logic_vector(31 downto 0);
        cmd_shares  : in  std_logic_vector(31 downto 0);
        cmd_side    : in  std_logic;  -- 0=Buy, 1=Sell

        -- Read result (2-cycle latency for LOOKUP, ADD, REMOVE; 1-cycle for CLEAR)
        rd_level    : out price_level_t;
        rd_valid    : out std_logic;

        -- Statistics (9 bits to count up to 512 levels per side)
        bid_level_count : out unsigned(8 downto 0);  -- Active bid levels
        ask_level_count : out unsigned(8 downto 0)   -- Active ask levels
    );
end price_level_table;

architecture Behavioral of price_level_table is

    -- Command type constants
    constant CMD_ADD    : std_logic_vector(1 downto 0) := "00";
    constant CMD_REMOVE : std_logic_vector(1 downto 0) := "01";
    constant CMD_LOOKUP : std_logic_vector(1 downto 0) := "10";
    constant CMD_CLEAR  : std_logic_vector(1 downto 0) := "11";

    -- BRAM clear state machine
    -- On reset, clears all 1024 entries to prevent stale data from previous runs
    -- Takes ~1024 clock cycles (~5.1 µs at 200 MHz)
    type clear_state_t is (CLEAR_IDLE, CLEAR_ACTIVE, CLEAR_DONE);
    signal clear_state : clear_state_t := CLEAR_IDLE;
    signal clear_addr : unsigned(PRICE_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal clearing : std_logic := '0';  -- High during BRAM clear sequence

    -- BRAM storage (expanded to 82 bits for full 32-bit price)
    -- Following Xilinx Write-First template
    -- NOTE: Initialization only occurs at power-up/configuration.
    -- Reset triggers clear state machine to explicitly write zeros.
    type bram_t is array (0 to MAX_PRICE_LEVELS-1) of std_logic_vector(81 downto 0);
    signal bram : bram_t := (others => (others => '0'));

    -- BRAM output (registered, following Write-First template)
    signal bram_do : std_logic_vector(81 downto 0) := (others => '0');
    
    -- Write enable and data
    signal bram_we : std_logic := '0';
    signal bram_addr : std_logic_vector(PRICE_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal bram_di : std_logic_vector(81 downto 0) := (others => '0');

    -- Pipeline registers for read-modify-write operations
    signal pipe_cmd_valid : std_logic := '0';
    signal pipe_cmd_type : std_logic_vector(1 downto 0) := "00";
    signal pipe_cmd_addr : std_logic_vector(PRICE_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal pipe_cmd_price : std_logic_vector(31 downto 0) := (others => '0');
    signal pipe_cmd_shares : std_logic_vector(31 downto 0) := (others => '0');
    signal pipe_cmd_side : std_logic := '0';
    signal pipe_old_level : price_level_t;
    signal pipe_old_valid : std_logic := '0';

    -- Pipeline delay signals for BRAM timing
    -- FIX: Added delays to capture bram_do AFTER BRAM read completes
    -- pipe_cmd_valid_d1: Used to capture bram_do (LOOKUP) and pipe_old_level (ADD/REMOVE)
    -- pipe_cmd_valid_d2: Used to process ADD/REMOVE after pipe_old_level is valid
    signal pipe_cmd_valid_d1 : std_logic := '0';
    signal pipe_cmd_type_d1 : std_logic_vector(1 downto 0) := "00";
    signal pipe_cmd_addr_d1 : std_logic_vector(PRICE_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal pipe_cmd_price_d1 : std_logic_vector(31 downto 0) := (others => '0');
    signal pipe_cmd_shares_d1 : std_logic_vector(31 downto 0) := (others => '0');
    signal pipe_cmd_side_d1 : std_logic := '0';

    signal pipe_cmd_valid_d2 : std_logic := '0';
    signal pipe_cmd_type_d2 : std_logic_vector(1 downto 0) := "00";
    signal pipe_cmd_addr_d2 : std_logic_vector(PRICE_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal pipe_cmd_price_d2 : std_logic_vector(31 downto 0) := (others => '0');
    signal pipe_cmd_shares_d2 : std_logic_vector(31 downto 0) := (others => '0');
    signal pipe_cmd_side_d2 : std_logic := '0';

    -- Read output pipeline (for LOOKUP commands)
    signal rd_data_stage1 : std_logic_vector(81 downto 0) := (others => '0');
    signal rd_data_stage2 : std_logic_vector(81 downto 0) := (others => '0');
    signal rd_valid_stage1 : std_logic := '0';
    signal rd_valid_stage2 : std_logic := '0';

    -- Level count tracking (9 bits for up to 512 levels per side)
    signal bid_count : unsigned(8 downto 0) := (others => '0');
    signal ask_count : unsigned(8 downto 0) := (others => '0');

    -- Xilinx BRAM inference
    attribute ram_style : string;
    attribute ram_style of bram : signal is "block";

begin

    -- Outputs
    rd_level <= slv_to_price_level(rd_data_stage2);
    rd_valid <= rd_valid_stage2;
    bid_level_count <= bid_count;
    ask_level_count <= ask_count;

    ------------------------------------------------------------------------
    -- BRAM Access Process (Read-First Template)
    -- Following Xilinx rams_sp_rf.vhd template
    -- In Read-First mode, read happens after write check, returning OLD data
    ------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                bram_do <= (others => '0');
            else
                -- Read-First mode: write first (if enabled), then read
                -- The read will get the OLD data (before write) due to non-blocking assignment
                if bram_we = '1' then
                    bram(to_integer(unsigned(bram_addr))) <= bram_di;
                end if;
                -- Always read (gets old data if write occurred, new data otherwise)
                bram_do <= bram(to_integer(unsigned(bram_addr)));
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- Command Pipeline: Stage 1 - Capture command and read from BRAM
    ------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pipe_cmd_valid <= '0';
                pipe_cmd_type <= "00";
                pipe_cmd_addr <= (others => '0');
                pipe_cmd_price <= (others => '0');
                pipe_cmd_shares <= (others => '0');
                pipe_cmd_side <= '0';
                pipe_old_level <= (valid => '0', price => (others => '0'), total_shares => (others => '0'),
                                  order_count => (others => '0'), side => '0');
                pipe_old_valid <= '0';
            else
                -- Stage 1: Capture command and initiate BRAM read
                if cmd_valid = '1' then
                    if cmd_type = CMD_CLEAR then
                        -- CLEAR: No pipeline needed, handled directly in Stage 2
                        pipe_cmd_valid <= '0';
                        pipe_cmd_type <= "00";
                    else
                        -- ADD, REMOVE, LOOKUP: Store command for pipeline
                        pipe_cmd_valid <= '1';
                        pipe_cmd_type <= cmd_type;
                        pipe_cmd_addr <= cmd_addr;
                        pipe_cmd_price <= cmd_price;
                        pipe_cmd_shares <= cmd_shares;
                        pipe_cmd_side <= cmd_side;
                    end if;
                else
                    pipe_cmd_valid <= '0';
                end if;

                -- FIX: Capture old level data using DELAYED signal (pipe_cmd_valid_d1)
                -- The BRAM read takes one cycle, so bram_do is valid when pipe_cmd_valid_d1='1'
                -- This ensures the correct BRAM data is captured, not stale data
                if pipe_cmd_valid_d1 = '1' and pipe_cmd_type_d1 /= CMD_LOOKUP then
                    -- Only capture for ADD/REMOVE (LOOKUP has its own pipeline)
                    pipe_old_level <= slv_to_price_level(bram_do);
                    pipe_old_valid <= slv_to_price_level(bram_do).valid;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- Command Pipeline: Stage 2 - Modify and Write
    -- FIX: Uses pipe_cmd_valid_d2 to process ADD/REMOVE after pipe_old_level is valid
    -- This process controls BRAM write signals and processes commands
    --
    -- Timing for ADD/REMOVE:
    --   Cycle 0: cmd_valid='1', bram_addr set for read
    --   Cycle 1: pipe_cmd_valid='1', BRAM read in progress
    --   Cycle 2: pipe_cmd_valid_d1='1', bram_do valid, pipe_old_level captured
    --   Cycle 3: pipe_cmd_valid_d2='1', pipe_old_level valid, process and write
    ------------------------------------------------------------------------
    -- BRAM Clear State Machine Process
    -- Clears all 1024 entries on reset to prevent stale data
    ------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                clear_state <= CLEAR_ACTIVE;
                clear_addr <= (others => '0');
                clearing <= '1';
            else
                case clear_state is
                    when CLEAR_IDLE =>
                        clearing <= '0';

                    when CLEAR_ACTIVE =>
                        clearing <= '1';
                        if clear_addr = MAX_PRICE_LEVELS - 1 then
                            clear_state <= CLEAR_DONE;
                        else
                            clear_addr <= clear_addr + 1;
                        end if;

                    when CLEAR_DONE =>
                        clear_state <= CLEAR_IDLE;
                        clearing <= '0';
                        clear_addr <= (others => '0');
                end case;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- Command Pipeline: Stage 2 - Modify and Write
    ------------------------------------------------------------------------
    process(clk)
        variable new_level : price_level_t;
        variable new_shares : unsigned(31 downto 0);
        variable new_count : unsigned(15 downto 0);
        variable addr_int : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                bid_count <= (others => '0');
                ask_count <= (others => '0');
                bram_we <= '0';
                bram_addr <= (others => '0');
                bram_di <= (others => '0');
            else
                -- Default: no write
                bram_we <= '0';

                -- BRAM clear takes priority over all other operations
                if clearing = '1' then
                    bram_we <= '1';
                    bram_addr <= std_logic_vector(clear_addr);
                    bram_di <= (others => '0');
                -- Set BRAM address for reads (cycle 1) and writes (cycle 3)
                -- Priority: current command (read) > pipelined command (write)
                elsif cmd_valid = '1' and cmd_type /= CMD_CLEAR then
                    -- Cycle 1: Set address for BRAM read (for ADD/REMOVE/LOOKUP)
                    bram_addr <= cmd_addr;
                elsif pipe_cmd_valid_d2 = '1' and pipe_cmd_type_d2 /= CMD_LOOKUP then
                    -- Cycle 3: Use delayed address for write operations (ADD/REMOVE)
                    bram_addr <= pipe_cmd_addr_d2;
                end if;

                -- Skip normal command processing during clear
                if clearing = '0' then
                    -- Handle CLEAR command (immediate write, no pipeline)
                    if cmd_valid = '1' and cmd_type = CMD_CLEAR then
                        bram_we <= '1';
                        bram_addr <= cmd_addr;
                        bram_di <= (others => '0');
                -- Stage 2: Process read-modify-write operations using DELAYED signals
                -- FIX: Use pipe_cmd_valid_d2 to ensure pipe_old_level has valid BRAM data
                elsif pipe_cmd_valid_d2 = '1' then
                    addr_int := to_integer(unsigned(pipe_cmd_addr_d2));

                    case pipe_cmd_type_d2 is
                        when CMD_ADD =>
                            -- Add shares to level
                            if pipe_old_level.valid = '0' then
                                -- Create new level
                                new_level.price := pipe_cmd_price_d2;
                                new_level.total_shares := pipe_cmd_shares_d2;
                                new_level.order_count := x"0001";
                                new_level.side := pipe_cmd_side_d2;
                                new_level.valid := '1';

                                -- Update level count (new level created)
                                if pipe_cmd_side_d2 = '0' then
                                    bid_count <= bid_count + 1;
                                else
                                    ask_count <= ask_count + 1;
                                end if;
                            else
                                -- Add to existing level
                                -- Check if side matches
                                if pipe_old_level.side /= pipe_cmd_side_d2 then
                                    -- Side mismatch - stale data, overwrite it
                                    new_level.price := pipe_cmd_price_d2;
                                    new_level.total_shares := pipe_cmd_shares_d2;
                                    new_level.order_count := x"0001";
                                    new_level.side := pipe_cmd_side_d2;
                                    new_level.valid := '1';

                                    -- Only increment if count is 0
                                    if pipe_cmd_side_d2 = '0' and bid_count = 0 then
                                        bid_count <= bid_count + 1;
                                    elsif pipe_cmd_side_d2 = '1' and ask_count = 0 then
                                        ask_count <= ask_count + 1;
                                    end if;
                                else
                                    -- Side matches - add to existing level
                                    if (pipe_cmd_side_d2 = '0' and bid_count = 0) or (pipe_cmd_side_d2 = '1' and ask_count = 0) then
                                        -- Stale data: level exists but not counted
                                        new_level.price := pipe_cmd_price_d2;
                                        new_level.total_shares := pipe_cmd_shares_d2;
                                        new_level.order_count := x"0001";
                                        new_level.side := pipe_cmd_side_d2;
                                        new_level.valid := '1';

                                        if pipe_cmd_side_d2 = '0' then
                                            bid_count <= bid_count + 1;
                                        else
                                            ask_count <= ask_count + 1;
                                        end if;
                                    else
                                        -- Normal case: add to existing counted level
                                        new_level.side := pipe_old_level.side;
                                        new_shares := unsigned(pipe_old_level.total_shares) + unsigned(pipe_cmd_shares_d2);
                                        new_count := unsigned(pipe_old_level.order_count) + 1;

                                        new_level.price := pipe_old_level.price;
                                        new_level.total_shares := std_logic_vector(new_shares);
                                        new_level.order_count := std_logic_vector(new_count);
                                        new_level.valid := '1';
                                    end if;
                                end if;
                            end if;

                            -- Write back
                            bram_we <= '1';
                            bram_addr <= pipe_cmd_addr_d2;
                            bram_di <= price_level_to_slv(new_level);

                        when CMD_REMOVE =>
                            -- Remove shares from level
                            if pipe_old_level.valid = '1' then
                                new_shares := unsigned(pipe_old_level.total_shares);
                                if new_shares >= unsigned(pipe_cmd_shares_d2) then
                                    new_shares := new_shares - unsigned(pipe_cmd_shares_d2);
                                else
                                    new_shares := (others => '0');
                                end if;

                                new_count := unsigned(pipe_old_level.order_count);
                                if new_count > 0 then
                                    new_count := new_count - 1;
                                end if;

                                -- If no shares or orders remain, invalidate level
                                if new_shares = 0 or new_count = 0 then
                                    new_level.valid := '0';
                                    new_level.total_shares := (others => '0');
                                    new_level.order_count := (others => '0');

                                    -- Update level count
                                    if pipe_cmd_side_d2 = '0' then
                                        if bid_count > 0 then
                                            bid_count <= bid_count - 1;
                                        end if;
                                    else
                                        if ask_count > 0 then
                                            ask_count <= ask_count - 1;
                                        end if;
                                    end if;
                                else
                                    new_level.valid := '1';
                                    new_level.total_shares := std_logic_vector(new_shares);
                                    new_level.order_count := std_logic_vector(new_count);
                                end if;

                                new_level.price := pipe_old_level.price;
                                new_level.side := pipe_old_level.side;

                                -- Write back
                                bram_we <= '1';
                                bram_addr <= pipe_cmd_addr_d2;
                                bram_di <= price_level_to_slv(new_level);
                            else
                                -- Invalid level, no write
                                bram_we <= '0';
                            end if;

                        when CMD_LOOKUP =>
                            -- Read-only, no write (handled by separate LOOKUP pipeline)
                            bram_we <= '0';

                        when others =>
                            bram_we <= '0';
                    end case;
                else
                    -- No command: clear write enable
                    bram_we <= '0';
                end if;
                end if;  -- clearing = '0'
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- Pipeline Delay and Read Output Process
    -- Generates all delay signals and handles LOOKUP output pipeline
    --
    -- Timing for LOOKUP:
    --   Cycle 0: cmd_valid='1', address captured
    --   Cycle 1: pipe_cmd_valid='1', BRAM address set
    --   Cycle 2: pipe_cmd_valid_d1='1', BRAM read completes, capture to rd_data_stage1
    --   Cycle 3: rd_valid_stage1='1', capture to rd_data_stage2
    --   Cycle 4: rd_valid_stage2='1', output valid
    --
    -- Timing for ADD/REMOVE:
    --   Cycle 0: cmd_valid='1', address captured
    --   Cycle 1: pipe_cmd_valid='1', BRAM address set
    --   Cycle 2: pipe_cmd_valid_d1='1', BRAM read completes, pipe_old_level captured
    --   Cycle 3: pipe_cmd_valid_d2='1', pipe_old_level valid, process and write
    ------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                -- Reset _d1 delay signals
                pipe_cmd_valid_d1 <= '0';
                pipe_cmd_type_d1 <= "00";
                pipe_cmd_addr_d1 <= (others => '0');
                pipe_cmd_price_d1 <= (others => '0');
                pipe_cmd_shares_d1 <= (others => '0');
                pipe_cmd_side_d1 <= '0';

                -- Reset _d2 delay signals
                pipe_cmd_valid_d2 <= '0';
                pipe_cmd_type_d2 <= "00";
                pipe_cmd_addr_d2 <= (others => '0');
                pipe_cmd_price_d2 <= (others => '0');
                pipe_cmd_shares_d2 <= (others => '0');
                pipe_cmd_side_d2 <= '0';

                -- Reset read output pipeline
                rd_data_stage1 <= (others => '0');
                rd_data_stage2 <= (others => '0');
                rd_valid_stage1 <= '0';
                rd_valid_stage2 <= '0';
            else
                -- Generate _d1 delay signals (one cycle delay from pipe_cmd_*)
                pipe_cmd_valid_d1 <= pipe_cmd_valid;
                pipe_cmd_type_d1 <= pipe_cmd_type;
                pipe_cmd_addr_d1 <= pipe_cmd_addr;
                pipe_cmd_price_d1 <= pipe_cmd_price;
                pipe_cmd_shares_d1 <= pipe_cmd_shares;
                pipe_cmd_side_d1 <= pipe_cmd_side;

                -- Generate _d2 delay signals (one cycle delay from _d1)
                pipe_cmd_valid_d2 <= pipe_cmd_valid_d1;
                pipe_cmd_type_d2 <= pipe_cmd_type_d1;
                pipe_cmd_addr_d2 <= pipe_cmd_addr_d1;
                pipe_cmd_price_d2 <= pipe_cmd_price_d1;
                pipe_cmd_shares_d2 <= pipe_cmd_shares_d1;
                pipe_cmd_side_d2 <= pipe_cmd_side_d1;

                -- LOOKUP output pipeline: Capture BRAM output AFTER read completes
                if pipe_cmd_valid_d1 = '1' and pipe_cmd_type_d1 = CMD_LOOKUP then
                    rd_data_stage1 <= bram_do;
                    rd_valid_stage1 <= '1';
                else
                    rd_valid_stage1 <= '0';
                end if;

                -- Pipeline stage 2: Register stage1 data
                rd_data_stage2 <= rd_data_stage1;
                rd_valid_stage2 <= rd_valid_stage1;
            end if;
        end if;
    end process;

end Behavioral;
