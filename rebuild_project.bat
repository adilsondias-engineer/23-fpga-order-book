@echo off
REM Rebuild Project 23: Integrated Order Book with PCIe Output
REM Full integration of ITCH Parser + Order Book + PCIe BBO Streaming
REM
REM Usage: rebuild_project.bat [incremental]
REM   No args     - Full rebuild (deletes vivado_project and rebuilds from scratch)
REM   incremental - Incremental build (keeps existing project, just re-runs synthesis)

echo ============================================
echo Project 23: Order Book with PCIe Output
echo ============================================
echo.
echo This project integrates:
echo   - Ethernet RGMII (1 Gbps ITCH feed input)
echo   - ITCH Parser and Order Book
echo   - PCIe Gen1 x4 BBO streaming output
echo.
echo Data flow: Ethernet --^> ITCH --^> Order Book --^> BBO --^> PCIe --^> Host
echo.

set PATH=C:\Xilinx\2025.1\Vivado\bin;%PATH%

REM Check for Vivado
where vivado >nul 2>&1
if errorlevel 1 goto no_vivado

REM Check for incremental build argument
if /i "%1"=="incremental" goto check_incremental

REM === FULL BUILD ===
echo FULL REBUILD - removing old project directory...
if exist vivado_project rmdir /s /q vivado_project

echo.
echo Running Vivado to create new project...
echo This will take 15-20 minutes for full synthesis and implementation.
echo.

vivado -mode batch -source scripts/build.tcl -log rebuild.log -journal rebuild.jou
goto done

:check_incremental
REM === INCREMENTAL BUILD ===
echo INCREMENTAL BUILD - keeping existing project
echo.
if not exist vivado_project goto no_project

echo Running Vivado incremental build...
echo This will re-run synthesis and implementation on existing project.
echo.

vivado -mode batch -source scripts/incremental_build.tcl -log rebuild_incr.log -journal rebuild_incr.jou
goto done

:no_vivado
echo ERROR: Vivado not found in PATH.
echo Please run this from Vivado command prompt or add Vivado to PATH.
exit /b 1

:no_project
echo ERROR: No existing project found. Run full build first.
exit /b 1

:done
echo.
echo ============================================
echo Build Complete!
echo ============================================
echo.
echo Check timing summary in:
echo   vivado_project\23-order-book.runs\impl_1\order_book_top_timing_summary_routed.rpt
echo.
echo Bitstream location:
echo   vivado_project\23-order-book.runs\impl_1\order_book_top.bit
echo.
