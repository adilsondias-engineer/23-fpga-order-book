----------------------------------------------------------------------------------
-- PCIe BBO Top - Custom Logic Wrapper for PCIe GPU Bridge
-- Integrates BBO streaming with XDMA block design
--
-- SIMPLIFIED VERSION: No CDC FIFO needed!
-- The order book now runs on axi_aclk (same as PCIe), so BBO data is already
-- in the correct clock domain. This eliminates the problematic CDC handshaking.
--
-- This module handles:
--   1. BBO to AXI-Stream conversion for C2H DMA
--   2. Latency calculation from 4-point timestamps
--   3. Control registers (via AXI-Lite)
--
-- Interfaces:
--   - BBO data + timestamps from order book (axi_aclk domain)
--   - AXI-Stream for C2H, AXI-Lite for control (axi_aclk)
--
-- Target: AX7203 (XC7A200T-2FBG484I)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pcie_bbo_top is
    Generic (
        C_AXI_DATA_WIDTH      : integer := 64;   -- 64-bit for XDMA C2H
        C_AXI_LITE_DATA_WIDTH : integer := 32;
        C_AXI_LITE_ADDR_WIDTH : integer := 6
    );
    Port (
        -- BBO input from order book (now on axi_aclk domain - same clock!)
        bbo_update     : in  STD_LOGIC;
        bbo_symbol     : in  STD_LOGIC_VECTOR(63 downto 0);
        bbo_bid_price  : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_bid_size   : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_price  : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_size   : in  STD_LOGIC_VECTOR(31 downto 0);
        bbo_spread     : in  STD_LOGIC_VECTOR(31 downto 0);

        -- 4-point timestamps
        ts_t1          : in  STD_LOGIC_VECTOR(31 downto 0);
        ts_t2          : in  STD_LOGIC_VECTOR(31 downto 0);
        ts_t3          : in  STD_LOGIC_VECTOR(31 downto 0);
        ts_t4          : in  STD_LOGIC_VECTOR(31 downto 0);

        -- XDMA clock domain (from block design)
        axi_aclk       : in  STD_LOGIC;
        axi_aresetn    : in  STD_LOGIC;

        -- AXI-Stream Master Interface (to C2H FIFO in block design)
        m_axis_tdata   : out STD_LOGIC_VECTOR(C_AXI_DATA_WIDTH-1 downto 0);
        m_axis_tkeep   : out STD_LOGIC_VECTOR(C_AXI_DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid  : out STD_LOGIC;
        m_axis_tready  : in  STD_LOGIC;
        m_axis_tlast   : out STD_LOGIC;

        -- AXI-Lite Slave Interface (from block design interconnect)
        S_AXI_AWADDR   : in  STD_LOGIC_VECTOR(C_AXI_LITE_ADDR_WIDTH-1 downto 0);
        S_AXI_AWVALID  : in  STD_LOGIC;
        S_AXI_AWREADY  : out STD_LOGIC;
        S_AXI_WDATA    : in  STD_LOGIC_VECTOR(C_AXI_LITE_DATA_WIDTH-1 downto 0);
        S_AXI_WSTRB    : in  STD_LOGIC_VECTOR(C_AXI_LITE_DATA_WIDTH/8-1 downto 0);
        S_AXI_WVALID   : in  STD_LOGIC;
        S_AXI_WREADY   : out STD_LOGIC;
        S_AXI_BRESP    : out STD_LOGIC_VECTOR(1 downto 0);
        S_AXI_BVALID   : out STD_LOGIC;
        S_AXI_BREADY   : in  STD_LOGIC;
        S_AXI_ARADDR   : in  STD_LOGIC_VECTOR(C_AXI_LITE_ADDR_WIDTH-1 downto 0);
        S_AXI_ARVALID  : in  STD_LOGIC;
        S_AXI_ARREADY  : out STD_LOGIC;
        S_AXI_RDATA    : out STD_LOGIC_VECTOR(C_AXI_LITE_DATA_WIDTH-1 downto 0);
        S_AXI_RRESP    : out STD_LOGIC_VECTOR(1 downto 0);
        S_AXI_RVALID   : out STD_LOGIC;
        S_AXI_RREADY   : in  STD_LOGIC;

        -- Status LEDs
        led_link_up    : out STD_LOGIC;
        led_streaming  : out STD_LOGIC;
        led_overflow   : out STD_LOGIC;

        -- Debug outputs
        dbg_bbo_count     : out STD_LOGIC_VECTOR(31 downto 0);
        dbg_tready_seen   : out STD_LOGIC;
        dbg_stream_ready  : out STD_LOGIC;
        dbg_tready_now    : out STD_LOGIC;
        dbg_tvalid_now    : out STD_LOGIC;
        dbg_axi_state     : out STD_LOGIC_VECTOR(3 downto 0)
    );
end pcie_bbo_top;

architecture Behavioral of pcie_bbo_top is

    ---------------------------------------------------------------------------
    -- Vivado X_INTERFACE attributes for block design module reference
    ---------------------------------------------------------------------------

    attribute X_INTERFACE_INFO : string;
    attribute X_INTERFACE_PARAMETER : string;

    -- Clock interface: axi_aclk drives m_axis and S_AXI
    attribute X_INTERFACE_INFO of axi_aclk : signal is "xilinx.com:signal:clock:1.0 axi_aclk CLK";
    attribute X_INTERFACE_PARAMETER of axi_aclk : signal is "ASSOCIATED_BUSIF m_axis:S_AXI, ASSOCIATED_RESET axi_aresetn";

    -- Reset interface: axi_aresetn (active low)
    attribute X_INTERFACE_INFO of axi_aresetn : signal is "xilinx.com:signal:reset:1.0 axi_aresetn RST";
    attribute X_INTERFACE_PARAMETER of axi_aresetn : signal is "POLARITY ACTIVE_LOW";

    -- AXI-Stream Master interface (m_axis)
    attribute X_INTERFACE_INFO of m_axis_tdata : signal is "xilinx.com:interface:axis:1.0 m_axis TDATA";
    attribute X_INTERFACE_INFO of m_axis_tkeep : signal is "xilinx.com:interface:axis:1.0 m_axis TKEEP";
    attribute X_INTERFACE_INFO of m_axis_tvalid : signal is "xilinx.com:interface:axis:1.0 m_axis TVALID";
    attribute X_INTERFACE_INFO of m_axis_tready : signal is "xilinx.com:interface:axis:1.0 m_axis TREADY";
    attribute X_INTERFACE_INFO of m_axis_tlast : signal is "xilinx.com:interface:axis:1.0 m_axis TLAST";
    attribute X_INTERFACE_PARAMETER of m_axis_tdata : signal is "TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 1, HAS_TLAST 1";

    -- AXI-Lite Slave interface (S_AXI)
    attribute X_INTERFACE_INFO of S_AXI_AWADDR : signal is "xilinx.com:interface:aximm:1.0 S_AXI AWADDR";
    attribute X_INTERFACE_INFO of S_AXI_AWVALID : signal is "xilinx.com:interface:aximm:1.0 S_AXI AWVALID";
    attribute X_INTERFACE_INFO of S_AXI_AWREADY : signal is "xilinx.com:interface:aximm:1.0 S_AXI AWREADY";
    attribute X_INTERFACE_INFO of S_AXI_WDATA : signal is "xilinx.com:interface:aximm:1.0 S_AXI WDATA";
    attribute X_INTERFACE_INFO of S_AXI_WSTRB : signal is "xilinx.com:interface:aximm:1.0 S_AXI WSTRB";
    attribute X_INTERFACE_INFO of S_AXI_WVALID : signal is "xilinx.com:interface:aximm:1.0 S_AXI WVALID";
    attribute X_INTERFACE_INFO of S_AXI_WREADY : signal is "xilinx.com:interface:aximm:1.0 S_AXI WREADY";
    attribute X_INTERFACE_INFO of S_AXI_BRESP : signal is "xilinx.com:interface:aximm:1.0 S_AXI BRESP";
    attribute X_INTERFACE_INFO of S_AXI_BVALID : signal is "xilinx.com:interface:aximm:1.0 S_AXI BVALID";
    attribute X_INTERFACE_INFO of S_AXI_BREADY : signal is "xilinx.com:interface:aximm:1.0 S_AXI BREADY";
    attribute X_INTERFACE_INFO of S_AXI_ARADDR : signal is "xilinx.com:interface:aximm:1.0 S_AXI ARADDR";
    attribute X_INTERFACE_INFO of S_AXI_ARVALID : signal is "xilinx.com:interface:aximm:1.0 S_AXI ARVALID";
    attribute X_INTERFACE_INFO of S_AXI_ARREADY : signal is "xilinx.com:interface:aximm:1.0 S_AXI ARREADY";
    attribute X_INTERFACE_INFO of S_AXI_RDATA : signal is "xilinx.com:interface:aximm:1.0 S_AXI RDATA";
    attribute X_INTERFACE_INFO of S_AXI_RRESP : signal is "xilinx.com:interface:aximm:1.0 S_AXI RRESP";
    attribute X_INTERFACE_INFO of S_AXI_RVALID : signal is "xilinx.com:interface:aximm:1.0 S_AXI RVALID";
    attribute X_INTERFACE_INFO of S_AXI_RREADY : signal is "xilinx.com:interface:aximm:1.0 S_AXI RREADY";
    attribute X_INTERFACE_PARAMETER of S_AXI_AWADDR : signal is "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 6";

    ---------------------------------------------------------------------------

    -- AXI-Stream signals from bbo_axi_stream
    signal stream_ready     : STD_LOGIC;
    signal stream_bbo_count : STD_LOGIC_VECTOR(31 downto 0);
    signal stream_overflow  : STD_LOGIC;
    signal tvalid_int       : STD_LOGIC;
    signal tlast_int        : STD_LOGIC;
    signal stream_state     : STD_LOGIC_VECTOR(3 downto 0);

    -- Control signals from AXI-Lite registers
    signal ctrl_enable      : STD_LOGIC;
    signal ctrl_reset       : STD_LOGIC;
    signal filter_enable    : STD_LOGIC;
    signal filter_symbol    : STD_LOGIC_VECTOR(63 downto 0);

    -- Status signals
    signal status_running   : STD_LOGIC;
    signal status_overflow  : STD_LOGIC;

    -- Latency calculator signals
    signal last_latency_ns  : STD_LOGIC_VECTOR(31 downto 0);
    signal max_latency_ns   : STD_LOGIC_VECTOR(31 downto 0);
    signal min_latency_ns   : STD_LOGIC_VECTOR(31 downto 0);
    signal last_rx_ts       : STD_LOGIC_VECTOR(31 downto 0);
    signal last_tx_ts       : STD_LOGIC_VECTOR(31 downto 0);

    -- LED blink counter
    signal led_counter      : unsigned(23 downto 0) := (others => '0');
    signal led_blink        : STD_LOGIC := '0';

    -- Reset synchronizer
    signal rst_sync1        : STD_LOGIC := '1';
    signal rst_sync2        : STD_LOGIC := '1';
    signal axi_rst          : STD_LOGIC;

    -- Debug
    signal tready_seen_reg  : STD_LOGIC := '0';

begin

    -- Reset synchronization
    process(axi_aclk)
    begin
        if rising_edge(axi_aclk) then
            rst_sync1 <= not axi_aresetn;
            rst_sync2 <= rst_sync1;
        end if;
    end process;
    axi_rst <= rst_sync2;

    -- Status signals
    status_running <= ctrl_enable;
    status_overflow <= stream_overflow;

    -- LED outputs
    led_link_up <= '1';  -- Will be connected to PCIe link status
    led_streaming <= ctrl_enable and led_blink;
    led_overflow <= status_overflow;

    -- LED blink process
    process(axi_aclk)
    begin
        if rising_edge(axi_aclk) then
            if axi_rst = '1' then
                led_counter <= (others => '0');
                led_blink <= '0';
            else
                led_counter <= led_counter + 1;
                if led_counter = 0 then
                    led_blink <= not led_blink;
                end if;
            end if;
        end if;
    end process;

    -- Track if tready was ever seen (for debug)
    process(axi_aclk)
    begin
        if rising_edge(axi_aclk) then
            if axi_rst = '1' then
                tready_seen_reg <= '0';
            elsif m_axis_tready = '1' then
                tready_seen_reg <= '1';
            end if;
        end if;
    end process;

    -- Debug output assignments
    dbg_bbo_count <= stream_bbo_count;
    dbg_tready_seen <= tready_seen_reg;
    dbg_stream_ready <= stream_ready;
    dbg_tready_now <= m_axis_tready;
    dbg_tvalid_now <= tvalid_int;
    dbg_axi_state <= stream_state;

    -- Pass through AXI-Stream signals
    m_axis_tvalid <= tvalid_int;
    m_axis_tlast  <= tlast_int;

    -- AXI-Stream converter instance
    -- SIMPLIFIED: BBO data comes directly, no CDC FIFO needed!
    -- bbo_update pulse triggers transmission, data is latched immediately
    axi_stream_inst : entity work.bbo_axi_stream
        generic map (
            C_AXI_DATA_WIDTH => C_AXI_DATA_WIDTH,
            C_BBO_SIZE       => 44
        )
        port map (
            aclk           => axi_aclk,
            aresetn        => axi_aresetn,
            bbo_valid      => bbo_update,  -- Direct pulse from order book (same clock!)
            bbo_ready      => stream_ready,
            bbo_fifo_empty => '1',  -- No FIFO - always "empty" (data comes as pulses)
            bbo_symbol     => bbo_symbol,
            bbo_bid_price  => bbo_bid_price,
            bbo_bid_size   => bbo_bid_size,
            bbo_ask_price  => bbo_ask_price,
            bbo_ask_size   => bbo_ask_size,
            bbo_spread     => bbo_spread,
            bbo_ts_t1      => ts_t1,
            bbo_ts_t2      => ts_t2,
            bbo_ts_t3      => ts_t3,
            bbo_ts_t4      => ts_t4,
            m_axis_tdata   => m_axis_tdata,
            m_axis_tkeep   => m_axis_tkeep,
            m_axis_tvalid  => tvalid_int,
            m_axis_tready  => m_axis_tready,
            m_axis_tlast   => tlast_int,
            bbo_count      => stream_bbo_count,
            fifo_overflow  => stream_overflow,
            dbg_state      => stream_state
        );

    -- Control registers instance
    ctrl_regs_inst : entity work.control_registers
        generic map (
            C_S_AXI_DATA_WIDTH => C_AXI_LITE_DATA_WIDTH,
            C_S_AXI_ADDR_WIDTH => C_AXI_LITE_ADDR_WIDTH
        )
        port map (
            S_AXI_ACLK     => axi_aclk,
            S_AXI_ARESETN  => axi_aresetn,
            S_AXI_AWADDR   => S_AXI_AWADDR,
            S_AXI_AWVALID  => S_AXI_AWVALID,
            S_AXI_AWREADY  => S_AXI_AWREADY,
            S_AXI_WDATA    => S_AXI_WDATA,
            S_AXI_WSTRB    => S_AXI_WSTRB,
            S_AXI_WVALID   => S_AXI_WVALID,
            S_AXI_WREADY   => S_AXI_WREADY,
            S_AXI_BRESP    => S_AXI_BRESP,
            S_AXI_BVALID   => S_AXI_BVALID,
            S_AXI_BREADY   => S_AXI_BREADY,
            S_AXI_ARADDR   => S_AXI_ARADDR,
            S_AXI_ARVALID  => S_AXI_ARVALID,
            S_AXI_ARREADY  => S_AXI_ARREADY,
            S_AXI_RDATA    => S_AXI_RDATA,
            S_AXI_RRESP    => S_AXI_RRESP,
            S_AXI_RVALID   => S_AXI_RVALID,
            S_AXI_RREADY   => S_AXI_RREADY,
            ctrl_enable    => ctrl_enable,
            ctrl_reset     => ctrl_reset,
            filter_enable  => filter_enable,
            filter_symbol  => filter_symbol,
            status_running => status_running,
            status_overflow => status_overflow,
            bbo_count      => stream_bbo_count,
            last_rx_ts     => last_rx_ts,
            last_tx_ts     => last_tx_ts,
            latency_ns     => last_latency_ns,
            max_latency_ns => max_latency_ns,
            min_latency_ns => min_latency_ns
        );

    -- Latency calculator instance
    latency_calc_inst : entity work.latency_calculator
        port map (
            clk            => axi_aclk,
            rst            => axi_rst,
            ts_valid       => bbo_update,  -- Direct pulse from order book
            ts_t1          => ts_t1,
            ts_t2          => ts_t2,
            ts_t3          => ts_t3,
            ts_t4          => ts_t4,
            stats_reset    => ctrl_reset,
            last_latency_ns => last_latency_ns,
            max_latency_ns => max_latency_ns,
            min_latency_ns => min_latency_ns,
            last_rx_ts     => last_rx_ts,
            last_tx_ts     => last_tx_ts
        );

end Behavioral;
