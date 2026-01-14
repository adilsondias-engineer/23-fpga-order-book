----------------------------------------------------------------------------------
-- BBO to AXI-Stream Converter (SIMPLIFIED)
-- Converts 44-byte BBO messages to 64-bit AXI-Stream for XDMA C2H DMA
--
-- SIMPLIFIED VERSION: No CDC FIFO, direct BBO pulse triggering.
-- BBO data arrives as a single-cycle pulse (bbo_valid) with all data stable.
-- Data is latched and transmitted as 6 beats over AXI-Stream.
--
-- BBO Message Format (48 bytes over AXI-Stream):
--   Beat 1: Symbol (8 bytes)
--   Beat 2: Bid Price (4 bytes) + Bid Size (4 bytes)
--   Beat 3: Ask Price (4 bytes) + Ask Size (4 bytes)
--   Beat 4: Spread (4 bytes) + T1 timestamp (4 bytes)
--   Beat 5: T2 timestamp (4 bytes) + T3 timestamp (4 bytes)
--   Beat 6: T4 timestamp (4 bytes) + Reserved/Padding (4 bytes)
--
-- AXI-Stream Output:
--   64-bit data width (8 bytes per beat)
--   6 beats per BBO message (48 bytes)
--   TLAST asserted on Beat 6 (final beat)
--
-- Clock Domain: axi_aclk (XDMA clock, 250 MHz for Gen2 x1)
--
-- T3/T4 Timestamp Implementation:
--   T3: Captured when bbo_valid pulse received (BBO ready for PCIe TX)
--   T4: Captured when BEAT1 handshake completes (first AXI-Stream beat accepted)
--   Both timestamps use local cycle_counter running at axi_aclk frequency
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity bbo_axi_stream is
    Generic (
        C_AXI_DATA_WIDTH : integer := 64;   -- 64-bit AXI-Stream (XDMA default)
        C_BBO_SIZE       : integer := 44    -- BBO message size in bytes
    );
    Port (
        -- AXI clock and reset
        aclk           : in  STD_LOGIC;
        aresetn        : in  STD_LOGIC;

        -- BBO Input Interface (from order book - same clock domain)
        bbo_valid      : in  STD_LOGIC;  -- Single-cycle pulse when BBO data is valid
        bbo_ready      : out STD_LOGIC;  -- HIGH when ready to accept new BBO
        bbo_fifo_empty : in  STD_LOGIC;  -- Not used in simplified version
        bbo_symbol     : in  STD_LOGIC_VECTOR(63 downto 0);
        bbo_bid_price  : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_bid_size   : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_price  : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_size   : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_spread     : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ts_t1      : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ts_t2      : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ts_t3      : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ts_t4      : in  STD_LOGIC_VECTOR(31 downto 0);

        -- AXI-Stream Master Interface (to XDMA C2H)
        m_axis_tdata   : out STD_LOGIC_VECTOR(C_AXI_DATA_WIDTH-1 downto 0);
        m_axis_tkeep   : out STD_LOGIC_VECTOR(C_AXI_DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid  : out STD_LOGIC;
        m_axis_tready  : in  STD_LOGIC;
        m_axis_tlast   : out STD_LOGIC;

        -- Status outputs
        bbo_count      : out STD_LOGIC_VECTOR(31 downto 0);
        fifo_overflow  : out STD_LOGIC;

        -- Debug: State machine state (0=IDLE, 1-6=BEAT1-6)
        dbg_state      : out STD_LOGIC_VECTOR(3 downto 0)
    );
end bbo_axi_stream;

architecture Behavioral of bbo_axi_stream is

    -- State machine: IDLE + 6 beats
    type state_type is (IDLE, BEAT1, BEAT2, BEAT3, BEAT4, BEAT5, BEAT6);
    signal state : state_type := IDLE;

    -- Latched BBO data (352 bits = 44 bytes)
    signal bbo_latched : STD_LOGIC_VECTOR(351 downto 0) := (others => '0');

    -- Counter for transmitted BBOs
    signal bbo_counter : unsigned(31 downto 0) := (others => '0');

    -- Startup delay counter - wait for XDMA to fully initialize before sending data
    -- At 125 MHz, 2^20 cycles = ~8.4 ms delay after reset
    -- At 250 MHz (Gen2), 2^20 cycles = ~4.2 ms delay after reset
    signal startup_counter : unsigned(19 downto 0) := (others => '0');
    signal startup_done    : std_logic := '0';

    -- Cycle counter for T3/T4 timestamps (runs on axi_aclk)
    -- At 125 MHz: wraps every ~34 seconds
    -- At 250 MHz: wraps every ~17 seconds
    signal cycle_counter : unsigned(31 downto 0) := (others => '0');

    -- T3: Captured when bbo_valid is received (BBO ready for PCIe transmission)
    -- T4: Captured when BEAT1 transmission starts (first AXI-Stream beat)
    signal ts_t3_captured : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal ts_t4_captured : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- Internal signals
    signal tdata_int  : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal tvalid_int : STD_LOGIC := '0';
    signal tlast_int  : STD_LOGIC := '0';
    signal tkeep_int  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal ready_int  : STD_LOGIC := '1';

    -- Function to byte-swap a 64-bit value for little-endian memory layout
    function byte_swap_64(data : STD_LOGIC_VECTOR(63 downto 0)) return STD_LOGIC_VECTOR is
    begin
        return data(7 downto 0) & data(15 downto 8) & data(23 downto 16) & data(31 downto 24) &
               data(39 downto 32) & data(47 downto 40) & data(55 downto 48) & data(63 downto 56);
    end function;

begin

    -- Output assignments
    m_axis_tdata  <= tdata_int;
    m_axis_tvalid <= tvalid_int;
    m_axis_tlast  <= tlast_int;
    m_axis_tkeep  <= tkeep_int;
    bbo_ready     <= ready_int;
    bbo_count     <= std_logic_vector(bbo_counter);

    -- No overflow in simplified version
    fifo_overflow <= '0';

    -- State debug output (0=IDLE, 1-6=BEAT1-6)
    dbg_state <= "0000" when state = IDLE else
                 "0001" when state = BEAT1 else
                 "0010" when state = BEAT2 else
                 "0011" when state = BEAT3 else
                 "0100" when state = BEAT4 else
                 "0101" when state = BEAT5 else
                 "0110";  -- BEAT6

    -- Cycle counter process (free-running, for T3/T4 timestamps)
    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                cycle_counter <= (others => '0');
            else
                cycle_counter <= cycle_counter + 1;
            end if;
        end if;
    end process;

    -- Main state machine
    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state <= IDLE;
                tvalid_int <= '0';
                tlast_int <= '0';
                tkeep_int <= (others => '0');
                tdata_int <= (others => '0');
                bbo_latched <= (others => '0');
                bbo_counter <= (others => '0');
                ready_int <= '0';  -- Not ready during startup
                startup_counter <= (others => '0');
                startup_done <= '0';
                ts_t3_captured <= (others => '0');
                ts_t4_captured <= (others => '0');
            else
                -- Startup delay counter - wait ~8 ms after reset before accepting BBOs
                if startup_done = '0' then
                    if startup_counter = (startup_counter'range => '1') then
                        startup_done <= '1';
                        ready_int <= '1';  -- Now ready to accept BBOs
                    else
                        startup_counter <= startup_counter + 1;
                    end if;
                end if;
                case state is
                    when IDLE =>
                        tvalid_int <= '0';
                        tlast_int <= '0';
                        tkeep_int <= (others => '0');
                        -- ready_int is set by startup logic above

                        -- Check for BBO valid pulse (only after startup delay)
                        if bbo_valid = '1' and startup_done = '1' then
                            -- Capture T3: BBO ready for PCIe transmission (NOW)
                            ts_t3_captured <= std_logic_vector(cycle_counter);

                            -- Latch all BBO data (must be done BEFORE using it)
                            -- Note: T3/T4 slots will be filled with captured values later
                            bbo_latched <= bbo_symbol &
                                          bbo_bid_price & bbo_bid_size &
                                          bbo_ask_price & bbo_ask_size &
                                          bbo_spread &
                                          bbo_ts_t1 & bbo_ts_t2 & bbo_ts_t3 & bbo_ts_t4;

                            -- Pre-load Beat 1 data (Symbol) - use direct input since latch
                            -- won't be available until next cycle
                            tdata_int <= byte_swap_64(bbo_symbol);
                            tkeep_int <= (others => '1');
                            ready_int <= '0';  -- Busy transmitting
                            state <= BEAT1;
                        end if;

                    when BEAT1 =>
                        -- Beat 1: Symbol (bytes 0-7)
                        -- tdata was pre-loaded in IDLE with the correct symbol value
                        -- IMPORTANT: Don't modify tdata here - it holds the symbol
                        tvalid_int <= '1';
                        tlast_int <= '0';

                        if tvalid_int = '1' and m_axis_tready = '1' then
                            -- Capture T4: First AXI-Stream beat accepted (TX started)
                            ts_t4_captured <= std_logic_vector(cycle_counter);
                            -- Handshake complete for beat 1
                            -- Pre-load beat 2 data for next cycle
                            tdata_int <= bbo_latched(255 downto 224) & bbo_latched(287 downto 256);
                            state <= BEAT2;
                        end if;

                    when BEAT2 =>
                        -- Beat 2: BidPrice (bytes 8-11) + BidSize (bytes 12-15)
                        -- Data was pre-loaded in BEAT1
                        tvalid_int <= '1';
                        tlast_int <= '0';

                        if tvalid_int = '1' and m_axis_tready = '1' then
                            -- Pre-load beat 3 data
                            tdata_int <= bbo_latched(191 downto 160) & bbo_latched(223 downto 192);
                            state <= BEAT3;
                        end if;

                    when BEAT3 =>
                        -- Beat 3: AskPrice (bytes 16-19) + AskSize (bytes 20-23)
                        tvalid_int <= '1';
                        tlast_int <= '0';

                        if tvalid_int = '1' and m_axis_tready = '1' then
                            -- Pre-load beat 4 data
                            tdata_int <= bbo_latched(127 downto 96) & bbo_latched(159 downto 128);
                            state <= BEAT4;
                        end if;

                    when BEAT4 =>
                        -- Beat 4: Spread (bytes 24-27) + T1 (bytes 28-31)
                        tvalid_int <= '1';
                        tlast_int <= '0';

                        if tvalid_int = '1' and m_axis_tready = '1' then
                            -- Pre-load beat 5 data: T2 (from latched) + T3 (captured locally)
                            tdata_int <= ts_t3_captured & bbo_latched(95 downto 64);
                            state <= BEAT5;
                        end if;

                    when BEAT5 =>
                        -- Beat 5: T2 (bytes 32-35) + T3 (bytes 36-39, captured locally)
                        tvalid_int <= '1';
                        tlast_int <= '0';

                        if tvalid_int = '1' and m_axis_tready = '1' then
                            -- Pre-load beat 6 data: T4 (captured locally) + Padding
                            tdata_int <= x"00000000" & ts_t4_captured;
                            state <= BEAT6;
                        end if;

                    when BEAT6 =>
                        -- Beat 6: T4 (bytes 40-43, captured locally) + Padding (bytes 44-47)
                        -- Data was pre-loaded in BEAT5
                        tvalid_int <= '1';
                        tlast_int <= '1';

                        if tvalid_int = '1' and m_axis_tready = '1' then
                            -- Transaction complete
                            bbo_counter <= bbo_counter + 1;
                            -- Deassert valid/last and return to IDLE
                            tvalid_int <= '0';
                            tlast_int <= '0';
                            ready_int <= '1';
                            state <= IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
