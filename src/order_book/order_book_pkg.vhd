--------------------------------------------------------------------------------
-- Package: order_book_pkg
-- Description: Constants, types, and functions for hardware order book
--
-- Phase 1: Single symbol (AAPL)
-- Phase 2: Multi-symbol support (scalable to 8 symbols)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package order_book_pkg is

    ------------------------------------------------------------------------
    -- Configuration Constants
    ------------------------------------------------------------------------

    -- Phase 1: Single symbol configuration
    constant TARGET_SYMBOL      : std_logic_vector(63 downto 0) := x"4141504C20202020";  -- "AAPL    "
    constant ENABLE_ORDER_BOOK  : boolean := true;

    -- Order storage configuration
    constant MAX_ORDERS         : integer := 1024;  -- Max concurrent orders per symbol
    constant ORDER_ADDR_WIDTH   : integer := 10;    -- log2(MAX_ORDERS) = 10 bits

    -- Price level configuration
    -- Expanded from 256 to 1024 levels to reduce hash collisions
    -- Previous 7-bit mapping (bits 31:25) caused all prices <$200 to collide
    -- New 10-bit mapping (bits 22:13 XOR 12:3) provides better distribution
    constant MAX_PRICE_LEVELS   : integer := 1024;  -- 512 bids + 512 asks
    constant PRICE_ADDR_WIDTH   : integer := 10;    -- log2(MAX_PRICE_LEVELS) = 10 bits
    constant MAX_BID_LEVELS     : integer := 512;
    constant MAX_ASK_LEVELS     : integer := 512;

    -- BBO tracking configuration
    constant BBO_SCAN_DEPTH     : integer := 512;   -- Scan all bid/ask levels for BBO

    ------------------------------------------------------------------------
    -- Data Structure Types
    ------------------------------------------------------------------------

    -- Order Entry (stored in BRAM)
    -- Total: 130 bits (fits in dual 36Kb BRAM with width=130)
    type order_entry_t is record
        order_ref   : std_logic_vector(63 downto 0);  -- Unique order ID
        price       : std_logic_vector(31 downto 0);  -- 4-byte fixed point
        shares      : std_logic_vector(31 downto 0);  -- Remaining shares
        side        : std_logic;                      -- 0=Buy, 1=Sell
        valid       : std_logic;                      -- Order exists?
    end record;

    -- Convert order_entry_t to std_logic_vector for BRAM storage
    function order_to_slv(order : order_entry_t) return std_logic_vector;
    function slv_to_order(slv : std_logic_vector(129 downto 0)) return order_entry_t;

    -- Price Level Entry (stored in BRAM)
    -- Total: 66 bits
    type price_level_t is record
        price           : std_logic_vector(31 downto 0);  -- Price level
        total_shares    : std_logic_vector(31 downto 0);  -- Aggregated shares
        order_count     : std_logic_vector(15 downto 0);  -- Number of orders
        side            : std_logic;                      -- 0=Buy, 1=Sell
        valid           : std_logic;                      -- Level has orders?
    end record;

    -- Convert price_level_t to std_logic_vector for BRAM storage
    -- Updated to 82 bits to store full 32-bit price
    function price_level_to_slv(level : price_level_t) return std_logic_vector;
    function slv_to_price_level(slv : std_logic_vector(81 downto 0)) return price_level_t;

    -- BBO (Best Bid/Offer) Output
    type bbo_t is record
        bid_price       : std_logic_vector(31 downto 0);
        bid_shares      : std_logic_vector(31 downto 0);
        ask_price       : std_logic_vector(31 downto 0);
        ask_shares      : std_logic_vector(31 downto 0);
        spread          : std_logic_vector(31 downto 0);  -- ask - bid
        valid           : std_logic;                      -- BBO available?
    end record;

    constant BBO_INVALID : bbo_t := (
        bid_price   => (others => '0'),
        bid_shares  => (others => '0'),
        ask_price   => (others => '1'),  -- Max value (no ask)
        ask_shares  => (others => '0'),
        spread      => (others => '1'),
        valid       => '0'
    );

    ------------------------------------------------------------------------
    -- Order Book Statistics
    ------------------------------------------------------------------------

    type order_book_stats_t is record
        total_orders        : unsigned(15 downto 0);  -- Total active orders
        bid_order_count     : unsigned(15 downto 0);  -- Active buy orders
        ask_order_count     : unsigned(15 downto 0);  -- Active sell orders
        bid_level_count     : unsigned(8 downto 0);   -- Active bid levels (9 bits for 512 max)
        ask_level_count     : unsigned(8 downto 0);   -- Active ask levels (9 bits for 512 max)
        add_count           : unsigned(31 downto 0);  -- Lifetime adds
        execute_count       : unsigned(31 downto 0);  -- Lifetime executions
        cancel_count        : unsigned(31 downto 0);  -- Lifetime cancels
        delete_count        : unsigned(31 downto 0);  -- Lifetime deletes
        replace_count       : unsigned(31 downto 0);   -- Lifetime replaces
    end record;

    ------------------------------------------------------------------------
    -- Helper Functions
    ------------------------------------------------------------------------

    -- Price comparison (fixed-point)
    function price_greater_than(a, b : std_logic_vector(31 downto 0)) return boolean;
    function price_less_than(a, b : std_logic_vector(31 downto 0)) return boolean;
    function price_equal(a, b : std_logic_vector(31 downto 0)) return boolean;

    -- Shares arithmetic (prevent underflow)
    function shares_subtract(
        current : std_logic_vector(31 downto 0);
        amount  : std_logic_vector(31 downto 0)
    ) return std_logic_vector;

    -- Order reference hash (for BRAM addressing)
    -- Simple hash: Take lower 10 bits for 1024-entry table
    function hash_order_ref(order_ref : std_logic_vector(63 downto 0))
        return std_logic_vector;

    -- Price to address mapping
    -- Map price to BRAM address for price level table
    -- For Phase 1: Simple modulo addressing
    function price_to_addr(
        price : std_logic_vector(31 downto 0);
        side  : std_logic
    ) return std_logic_vector;

end package order_book_pkg;

package body order_book_pkg is

    ------------------------------------------------------------------------
    -- Order Entry Conversion Functions
    ------------------------------------------------------------------------

    function order_to_slv(order : order_entry_t) return std_logic_vector is
        variable slv : std_logic_vector(129 downto 0);
    begin
        slv(129)          := order.valid;
        slv(128)          := order.side;
        slv(127 downto 96) := order.shares;
        slv(95 downto 64)  := order.price;
        slv(63 downto 0)   := order.order_ref;
        return slv;
    end function;

    function slv_to_order(slv : std_logic_vector(129 downto 0)) return order_entry_t is
        variable order : order_entry_t;
    begin
        order.valid     := slv(129);
        order.side      := slv(128);
        order.shares    := slv(127 downto 96);
        order.price     := slv(95 downto 64);
        order.order_ref := slv(63 downto 0);
        return order;
    end function;

    ------------------------------------------------------------------------
    -- Price Level Conversion Functions
    ------------------------------------------------------------------------

    function price_level_to_slv(level : price_level_t) return std_logic_vector is
        variable slv : std_logic_vector(81 downto 0);
    begin
        slv(81)          := level.valid;
        slv(80)          := level.side;
        slv(79 downto 64) := level.order_count;
        slv(63 downto 32) := level.total_shares;
        slv(31 downto 0)  := level.price;  -- Store FULL 32-bit price
        return slv;
    end function;

    function slv_to_price_level(slv : std_logic_vector(81 downto 0)) return price_level_t is
        variable level : price_level_t;
    begin
        level.valid        := slv(81);
        level.side         := slv(80);
        level.order_count  := slv(79 downto 64);
        level.total_shares := slv(63 downto 32);
        level.price        := slv(31 downto 0);  -- Read FULL 32-bit price
        return level;
    end function;

    ------------------------------------------------------------------------
    -- Price Comparison Functions
    ------------------------------------------------------------------------

    function price_greater_than(a, b : std_logic_vector(31 downto 0)) return boolean is
    begin
        return unsigned(a) > unsigned(b);
    end function;

    function price_less_than(a, b : std_logic_vector(31 downto 0)) return boolean is
    begin
        return unsigned(a) < unsigned(b);
    end function;

    function price_equal(a, b : std_logic_vector(31 downto 0)) return boolean is
    begin
        return a = b;
    end function;

    ------------------------------------------------------------------------
    -- Shares Arithmetic
    ------------------------------------------------------------------------

    function shares_subtract(
        current : std_logic_vector(31 downto 0);
        amount  : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable result : unsigned(31 downto 0);
    begin
        if unsigned(current) >= unsigned(amount) then
            result := unsigned(current) - unsigned(amount);
        else
            result := (others => '0');  -- Prevent underflow
        end if;
        return std_logic_vector(result);
    end function;

    ------------------------------------------------------------------------
    -- Addressing Functions
    ------------------------------------------------------------------------

    function hash_order_ref(order_ref : std_logic_vector(63 downto 0))
        return std_logic_vector is
    begin
        -- Simple hash: Use lower 10 bits as address
        -- For Phase 1: Collisions possible but acceptable
        -- Phase 2: Implement better hash or linked list
        return order_ref(ORDER_ADDR_WIDTH-1 downto 0);
    end function;

    function price_to_addr(
        price : std_logic_vector(31 downto 0);
        side  : std_logic
    ) return std_logic_vector is
        variable addr : unsigned(PRICE_ADDR_WIDTH-1 downto 0);
        variable price_bits : unsigned(8 downto 0);
        variable upper_bits : unsigned(9 downto 0);
        variable lower_bits : unsigned(9 downto 0);
        variable hash_bits : unsigned(9 downto 0);
    begin
        -- Improved price-to-address mapping with XOR folding
        -- Previous version used bits 31:25 which are zero for prices <$200
        -- causing massive collisions.
        --
        -- New approach: XOR fold bits 22:13 with bits 12:3 for better distribution
        -- This handles typical stock prices ($50-$2000) effectively.
        --
        -- Price examples (4 decimal fixed-point):
        --   $150.00 = 1,500,000 = 0x0016E360 -> hash ~= 370
        --   $152.00 = 1,520,000 = 0x00173180 -> hash ~= 396
        --   $200.00 = 2,000,000 = 0x001E8480 -> hash ~= 488
        --   $321.72 = 3,217,200 = 0x00311730 -> hash ~= 289
        --   $1355   = 13,550,000 = 0x00CEC2DC -> hash ~= 307
        --
        upper_bits := unsigned(price(22 downto 13));
        lower_bits := unsigned(price(12 downto 3));
        hash_bits := upper_bits xor lower_bits;

        -- Take lower 9 bits of hash for 512-entry table per side
        price_bits := hash_bits(8 downto 0);

        if side = '0' then
            -- Buy: Map to [0-511]
            addr := resize(price_bits, PRICE_ADDR_WIDTH);
        else
            -- Sell: Map to [512-1023]
            -- FIX: Must resize price_bits BEFORE adding 512, otherwise 9-bit overflow
            -- occurs (512 = 2^9 wraps to 0 in 9-bit arithmetic)
            addr := resize(price_bits, PRICE_ADDR_WIDTH) + to_unsigned(512, PRICE_ADDR_WIDTH);
        end if;

        return std_logic_vector(addr);
    end function;

end package body order_book_pkg;
