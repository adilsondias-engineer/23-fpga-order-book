----------------------------------------------------------------------------------
-- BBO Clock Domain Crossing FIFO (Using Xilinx XPM_FIFO_ASYNC)
-- Transfers BBO data from trading clock (200 MHz) to XDMA clock (125-250 MHz)
--
-- Uses Xilinx XPM_FIFO_ASYNC in standard read mode with 1-cycle latency.
-- The parent module (pcie_bbo_top) uses a read_pending flag to prevent
-- double-reads that would cause packet misalignment.
--
-- FIFO depth: 2048 entries (FIFO_DEPTH_LOG2=11)
--
-- Input Clock: clk_trading (200 MHz order book domain)
-- Output Clock: axi_aclk (XDMA clock domain, 125 MHz for Gen1 x4)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Xilinx XPM library for FIFO primitive
library xpm;
use xpm.vcomponents.all;

entity bbo_cdc_fifo is
    Generic (
        FIFO_DEPTH_LOG2 : integer := 11   -- 2^11 = 2048 entries
    );
    Port (
        -- Write side (Trading clock domain - 200 MHz)
        wr_clk         : in  STD_LOGIC;
        wr_rst         : in  STD_LOGIC;
        wr_en          : in  STD_LOGIC;
        wr_full        : out STD_LOGIC;
        wr_almost_full : out STD_LOGIC;

        -- BBO data input
        wr_symbol      : in  STD_LOGIC_VECTOR(63 downto 0);
        wr_bid_price   : in  STD_LOGIC_VECTOR(31 downto 0);
        wr_bid_size    : in  STD_LOGIC_VECTOR(31 downto 0);
        wr_ask_price   : in  STD_LOGIC_VECTOR(31 downto 0);
        wr_ask_size    : in  STD_LOGIC_VECTOR(31 downto 0);
        wr_spread      : in  STD_LOGIC_VECTOR(31 downto 0);
        wr_ts_t1       : in  STD_LOGIC_VECTOR(31 downto 0);
        wr_ts_t2       : in  STD_LOGIC_VECTOR(31 downto 0);
        wr_ts_t3       : in  STD_LOGIC_VECTOR(31 downto 0);
        wr_ts_t4       : in  STD_LOGIC_VECTOR(31 downto 0);

        -- Read side (XDMA clock domain)
        rd_clk         : in  STD_LOGIC;
        rd_rst         : in  STD_LOGIC;
        rd_en          : in  STD_LOGIC;
        rd_empty       : out STD_LOGIC;
        rd_valid       : out STD_LOGIC;

        -- BBO data output
        rd_symbol      : out STD_LOGIC_VECTOR(63 downto 0);
        rd_bid_price   : out STD_LOGIC_VECTOR(31 downto 0);
        rd_bid_size    : out STD_LOGIC_VECTOR(31 downto 0);
        rd_ask_price   : out STD_LOGIC_VECTOR(31 downto 0);
        rd_ask_size    : out STD_LOGIC_VECTOR(31 downto 0);
        rd_spread      : out STD_LOGIC_VECTOR(31 downto 0);
        rd_ts_t1       : out STD_LOGIC_VECTOR(31 downto 0);
        rd_ts_t2       : out STD_LOGIC_VECTOR(31 downto 0);
        rd_ts_t3       : out STD_LOGIC_VECTOR(31 downto 0);
        rd_ts_t4       : out STD_LOGIC_VECTOR(31 downto 0);

        -- Overflow flag (sticky, in read clock domain)
        overflow       : out STD_LOGIC
    );
end bbo_cdc_fifo;

architecture Behavioral of bbo_cdc_fifo is

    constant FIFO_DEPTH : integer := 2**FIFO_DEPTH_LOG2;
    constant DATA_WIDTH : integer := 352;  -- 44 bytes * 8 bits

    -- Packed write data
    signal wr_data : STD_LOGIC_VECTOR(DATA_WIDTH-1 downto 0);

    -- Packed read data from FIFO
    signal rd_data : STD_LOGIC_VECTOR(DATA_WIDTH-1 downto 0);

    -- XPM FIFO signals
    signal fifo_full      : STD_LOGIC;
    signal fifo_empty     : STD_LOGIC;
    signal fifo_dout      : STD_LOGIC_VECTOR(DATA_WIDTH-1 downto 0);
    signal fifo_valid     : STD_LOGIC;
    signal fifo_overflow  : STD_LOGIC;
    signal fifo_wr_rst_busy : STD_LOGIC;
    signal fifo_rd_rst_busy : STD_LOGIC;

    -- Internal write enable (gated when FIFO busy after reset)
    signal wr_en_int : STD_LOGIC;
    signal rd_en_int : STD_LOGIC;

    -- Overflow latch (sticky)
    signal overflow_latch : STD_LOGIC := '0';

begin

    -- Pack write data (352 bits = 44 bytes)
    wr_data <= wr_symbol & wr_bid_price & wr_bid_size &
               wr_ask_price & wr_ask_size & wr_spread &
               wr_ts_t1 & wr_ts_t2 & wr_ts_t3 & wr_ts_t4;

    -- Gate writes when FIFO is busy after reset
    wr_en_int <= wr_en and (not fifo_wr_rst_busy) and (not fifo_full);
    rd_en_int <= rd_en and (not fifo_rd_rst_busy) and (not fifo_empty);

    -- XPM Asynchronous FIFO
    -- Documentation: UG953 - Xilinx Parameterized Macros
    xpm_fifo_async_inst : xpm_fifo_async
    generic map (
        CASCADE_HEIGHT      => 0,           -- Auto-calculate cascade height
        CDC_SYNC_STAGES     => 3,           -- 3-stage synchronizer (safe for 200->125 MHz)
        DOUT_RESET_VALUE    => "0",         -- Reset value for dout
        ECC_MODE            => "no_ecc",    -- No ECC
        FIFO_MEMORY_TYPE    => "block",     -- Use BRAM (not distributed RAM!)
        FIFO_READ_LATENCY   => 1,           -- Standard mode (1 cycle latency)
        FIFO_WRITE_DEPTH    => FIFO_DEPTH,  -- Configurable depth
        FULL_RESET_VALUE    => 0,           -- Full flag reset value
        PROG_EMPTY_THRESH   => 10,          -- Programmable empty threshold
        PROG_FULL_THRESH    => FIFO_DEPTH - 4, -- Almost full at DEPTH-4
        RD_DATA_COUNT_WIDTH => FIFO_DEPTH_LOG2 + 1,
        READ_DATA_WIDTH     => DATA_WIDTH,  -- 352 bits
        READ_MODE           => "std",       -- Standard read mode (1 cycle latency)
        RELATED_CLOCKS      => 0,           -- Clocks are NOT related
        SIM_ASSERT_CHK      => 0,           -- Disable simulation assertions
        USE_ADV_FEATURES    => "1404",      -- Enable overflow, almost_full, data_valid
        WAKEUP_TIME         => 0,           -- No wakeup time
        WRITE_DATA_WIDTH    => DATA_WIDTH,  -- 352 bits
        WR_DATA_COUNT_WIDTH => FIFO_DEPTH_LOG2 + 1
    )
    port map (
        -- Write side
        wr_clk         => wr_clk,
        wr_en          => wr_en_int,
        din            => wr_data,
        full           => fifo_full,
        almost_full    => wr_almost_full,
        overflow       => fifo_overflow,
        wr_rst_busy    => fifo_wr_rst_busy,
        wr_data_count  => open,
        prog_full      => open,
        wr_ack         => open,

        -- Read side
        rd_clk         => rd_clk,
        rd_en          => rd_en_int,
        dout           => fifo_dout,
        empty          => fifo_empty,
        almost_empty   => open,
        underflow      => open,
        rd_rst_busy    => fifo_rd_rst_busy,
        rd_data_count  => open,
        prog_empty     => open,
        data_valid     => fifo_valid,

        -- Reset (active high, synchronized internally by XPM)
        rst            => wr_rst,

        -- Unused
        sleep          => '0',
        injectdbiterr  => '0',
        injectsbiterr  => '0',
        sbiterr        => open,
        dbiterr        => open
    );

    -- Output assignments
    wr_full   <= fifo_full or fifo_wr_rst_busy;
    rd_empty  <= fifo_empty or fifo_rd_rst_busy;
    rd_valid  <= fifo_valid;
    rd_data   <= fifo_dout;

    -- Unpack read data
    rd_symbol    <= rd_data(351 downto 288);
    rd_bid_price <= rd_data(287 downto 256);
    rd_bid_size  <= rd_data(255 downto 224);
    rd_ask_price <= rd_data(223 downto 192);
    rd_ask_size  <= rd_data(191 downto 160);
    rd_spread    <= rd_data(159 downto 128);
    rd_ts_t1     <= rd_data(127 downto 96);
    rd_ts_t2     <= rd_data(95 downto 64);
    rd_ts_t3     <= rd_data(63 downto 32);
    rd_ts_t4     <= rd_data(31 downto 0);

    -- Latch overflow flag (sticky)
    process(rd_clk)
    begin
        if rising_edge(rd_clk) then
            if rd_rst = '1' then
                overflow_latch <= '0';
            elsif fifo_overflow = '1' then
                overflow_latch <= '1';
            end if;
        end if;
    end process;

    overflow <= overflow_latch;

end Behavioral;
