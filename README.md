# GateMate FPGA Internship — Cologne Chip CCGM1A1

**Author:** Erta Tershana  
**Institution:** University of Padova  
**Board:** Cologne Chip GateMate CCGM1A1 Evaluation Board V3.2A  
**Toolchain:** OSS CAD Suite (Yosys + nextpnr-himbaechel + openFPGALoader)  

---

## Repository Structure

```
.
├── 00_uart_echo/            Phase 0 — First UART echo test (10 MHz, no PLL)
├── 01_uart_cmd/             Phase 1 — UART commands + LED + counter (50 MHz PLL)
├── 02_hyperram/             Phase 2 — HyperRAM read/write interface
├── 03_serdes_loopback_early/ Phase 3a — Early SerDes loopback attempt
├── 03_serdes_loopback/      Phase 3b — Working SerDes loopback (status LEDs + UART)
├── 04_serdes_cmd/           Phase 3c — Final: interactive UART commands + auto status
└── docs/                    Oscilloscope photos and measurements
```

---

## Hardware Requirements

| Component | Details |
|-----------|---------|
| FPGA Board | Cologne Chip GateMate CCGM1A1 Evaluation Board **V3.2A** |
| UART Adapter | USB-TTL PL2303 or CH340, **3.3V logic level** |
| SMA Cables (Phase 3) | 2× SMA-to-SMA cables for loopback: J15↔J13 and J14↔J12 |
| Oscilloscope (optional) | Keysight InfiniiVision DSOX6004A used in experiments (any >1 GHz bandwidth scope works) |

### Board Jumper Settings

| Jumper | Setting | Purpose |
|--------|---------|---------|
| JP14 | Pins 2-3 (3V3) | NB bank voltage for UART Pmod |
| JP6 | Installed | Powers SerDes PMA analog section — **required for Phase 3** |
| JP8 | Installed | External clock enable — move back if removed |

---

## Software Requirements

### OSS CAD Suite (WSL2 on Windows or native Linux)

Download from: https://github.com/YosysHQ/oss-cad-suite-build

**Tested versions:**
- Yosys: `0.62+55` (git sha1 ac96f318e)
- nextpnr-himbaechel: `nextpnr-0.9-65-g06ae973a`
- OSS CAD Suite build date: **February 17, 2026**

Activate the suite in your shell:
```bash
source ~/oss-cad-suite/environment
```

### usbipd-win (Windows only, for WSL2)

Required to forward USB devices from Windows to WSL2.  
Download from: https://github.com/dorssel/usbipd-win

---

## Setup — Attaching USB Devices to WSL2

Run this every session from **Windows PowerShell (Administrator)**:

```powershell
# List USB devices
usbipd list

# Attach GateMate JTAG programmer (FT2232H — usually BUSID 2-2)
usbipd bind --busid 2-2
usbipd attach --wsl --busid 2-2

# Attach UART adapter (PL2303 — usually BUSID 2-8)
usbipd bind --busid 2-8
usbipd attach --wsl --busid 2-8
```

Then verify in WSL2:
```bash
ls /dev/ttyUSB*
# Expected:
# /dev/ttyUSB0  — GateMate FT2232H channel A (JTAG)
# /dev/ttyUSB1  — GateMate FT2232H channel B
# /dev/ttyUSB2  — PL2303 UART adapter
```

> **Note:** BUSIDs can vary. Always check with `usbipd list`. Port assignments
> (ttyUSB0/1/2) can change after reconnect — verify with `dmesg | grep ttyUSB`.

---

## UART Adapter Wiring (J17A Pmod Connector)

Connect the USB-TTL adapter to the **top row** of J17A (PMODA):

```
J17A Top Row:  [Pin1] [Pin2] [Pin3] [Pin4] [Pin5=GND] [Pin6=VDD]
                  ↑       ↑                     ↑
               Grey    Orange                 Black
              (RX←TX) (TX→RX)                (GND)
```

| Wire Color | Adapter Pin | J17A Pin | Signal |
|------------|-------------|----------|--------|
| Grey | RXD | Pin 1 | FPGA TX → Adapter RX |
| Orange | TXD | Pin 2 | Adapter TX → FPGA RX |
| Black | GND | Pin 5 | Ground |

**UART parameters:** 57,600 baud, 8N1, no flow control

Open terminal:
```bash
picocom -b 57600 --omap crcrlf /dev/ttyUSB2
```

---

## Build Pipeline (all projects)

```bash
# 1. Synthesis
yosys -p "read_verilog <top>.v; synth_gatemate -top <top> -luttree -nomx8; write_json <top>.json"

# 2. Place and Route
nextpnr-himbaechel --device=CCGM1A1 --json <top>.json \
  -o ccf=<top>.ccf -o out=<top>.txt \
  --router router2 --timing-allow-fail

# 3. Bitstream
gmpack <top>.txt <top>.bit

# 4. Program
openFPGALoader -c gatemate_evb_jtag -r <top>.bit
```

Or use the provided `build.sh` in each project directory.

---

## Phase 0 — UART Echo Test (`00_uart_echo/`)

This was the very first working design — a simple UART echo that runs directly
from the 10 MHz oscillator without a PLL. Used to verify the basic UART
connection and baud rate before adding the PLL.

### Files
| File | Description |
|------|-------------|
| `uart_tx_test.v` | Simple UART echo — RX character echoed back on TX |
| `uart_tx_test.ccf` | Pin constraints |
| `build.sh` | One-command build and flash |

### Parameters
| Parameter | Value |
|-----------|-------|
| Clock input | 10 MHz direct (no PLL) |
| UART baud rate | 57,600 |
| Bit period | 173 cycles (10 MHz / 57600) |

### Quick Start
```bash
cd 00_uart_echo
./build.sh
picocom -b 57600 --omap crcrlf /dev/ttyUSB2
# Type any character — it should be echoed back
```

---

## Phase 1 — UART Command Interface (`01_uart_cmd/`)

### Files
| File | Description |
|------|-------------|
| `uart_cmd_V1.v` | Top-level Verilog — PLL, UART RX/TX, command parser, LED, counter |
| `uart_cmd_V1.ccf` | Pin constraints |
| `build.sh` | One-command build and flash |

### Parameters
| Parameter | Value |
|-----------|-------|
| Clock input | 10 MHz (IO_SB_A8) |
| Fabric clock | 50 MHz (via CC_PLL ECONOMY mode) |
| UART baud rate | 57,600 |
| Bit period | 868 clock cycles |

### Commands
```
LED ON / LED OFF        — Control D1 LED
BLINK SLOW / FAST / OFF — Blink at 1 Hz / 10 Hz / off
COUNT                   — Print elapsed seconds
STATUS                  — Returns "GateMate OK"
CLKINFO                 — Returns "CLK: 50MHz - PLL LOCKED"
HELP                    — List all commands
```

### Quick Start
```bash
cd 01_uart_cmd
./build.sh
picocom -b 57600 --omap crcrlf /dev/ttyUSB2
# Type: status
# Expected: GateMate OK
#
# Type: blink slow
# Expected: LED D1 blinks at 1 Hz
#
# Type: count
# Expected: prints elapsed seconds
```

---

## Phase 2 — HyperRAM Interface (`02_hyperram/`)

### Files
| File | Description |
|------|-------------|
| `uart_cmd.v` | Same as Phase 1 + HyperRAM controller added |
| `uart_cmd.ccf` | Pin constraints including WB bank HyperRAM pins |
| `build.sh` | One-command build and flash |

### Parameters
| Parameter | Value |
|-----------|-------|
| HyperRAM chip | Infineon S27KS0641 (U10/U11) |
| HyperRAM voltage | 1.8V (WB bank fixed) |
| HyperRAM clock | CLK90 from PLL (90° phase shift required) |
| IO primitives | CC_IOBUF #(.V_IO("1.8")) on all WB pins |
| Latency count | 12 cycles |

### Commands
```
WRITE XX YY   — Write byte 0xYY to address 0xXX  (e.g. WRITE 00 AB)
READ XX       — Read byte from address 0xXX       (e.g. READ 00)
```

### Known Issue
Reads return 0xFF correctly (erased-state default). **Writes do not persist** — 
root cause is DDR timing: HyperBus requires write data center-aligned with clock 
transitions. Requires CC_ODDR primitive or precise phase offset. 
See [Cologne Chip forum](https://colognechip.com/mygatemate) for updates.

### Quick Start
```bash
cd 02_hyperram
./build.sh
picocom -b 57600 --omap crcrlf /dev/ttyUSB2
# Type: write 00 ab
# Expected: Written: 0xAB
# Type: read 00
# Expected: Read: 0xFF  (writes not yet persistent)
```

---

## Phase 3a — SerDes Early Loopback (`03_serdes_loopback_early/`)

This was the first SerDes attempt — before the physical reset pins were added.
It uses `SERDES_AUTO_INIT=1` and does not have the pullup reset pins.
**Included for reference only** — it does not reliably initialise after a cold reset.
Use `03_serdes_loopback/` or `04_serdes_cmd/` for actual experiments.

### Files
| File | Description |
|------|-------------|
| `serdes_loopback.v` | Early SerDes test — no pullup resets, SERDES_AUTO_INIT=1 |
| `serdes_loopback.ccf` | Pin constraints |
| `build.sh` | Build script |

---

## Phase 3b — SerDes Basic Loopback (`03_serdes_loopback/`)

### Hardware Setup (required before flashing)

> **Replication note:** The SerDes will NOT initialise if any of these are missing:
> JP6 jumper installed, X3 oscillator soldered, SMA cables connected, SW3 pressed after flash.

1. Solder SMA connectors J9, J11–J15 to the board
2. Solder SerDes reference clock oscillator X3 (LVDS, 125 MHz) near J9
3. Install jumper on **JP6** (powers SerDes PMA)
4. Connect loopback cables: **J15 ↔ J13** and **J14 ↔ J12**

### Files
| File | Description |
|------|-------------|
| `serdes_top.v` | SerDes loopback with status LEDs |
| `serdes_top.ccf` | Pin constraints |
| `build.sh` | One-command build and flash |

### Parameters
| Parameter | Value |
|-----------|-------|
| Fabric clock | 50 MHz (CC_PLL SPEED mode) |
| SerDes datapath | 80-bit |
| Line encoding | 8B10B enabled |
| TX pattern | K28.5 comma characters (0xBC) |
| TX_PMA_LOOPBACK | 2'b00 (external SMA cables) |
| PLL_FCNTRL | 6'h3A |
| PLL_MAIN_DIVSEL | 6'h1B |
| PLL_OUT_DIVSEL | 2'b11 |
| Reference clock | LVDS X3 oscillator (PLL_REF_SEL=1) |
| SERDES_AUTO_INIT | 0 (manual init via parameters) |

### LED Status
| LED | Signal | Meaning |
|-----|--------|---------|
| D1 | RX_RESET_DONE_O_N | ON = SerDes RX initialised |
| D2 | TX_RESET_DONE_O_N | ON = SerDes TX initialised |
| D3 | TX_DETECT_RX_DONE_O_N | ON = Receiver detected |
| D8 | Status (fabric) | Fast blink = loopback pass |

### Expected Result After Flash + Reset
D1, D2, D3 all ON → SerDes fully initialised and loopback active.

### Quick Start
```bash
cd 03_serdes_loopback
./build.sh
# Observe LEDs: D1, D2, D3 should all turn ON
# D8 should blink fast
```

> **Important:** Press SW3 (user button, IO_EB_B0) after programming if LEDs 
> do not light up. The SerDes requires a clean reset edge from the pullup pins.

---

## Phase 3c — SerDes Interactive Commands (`04_serdes_cmd/`)

This is the main SerDes demo with full UART command interface, automatic 
status reporting every 2 seconds, and oscilloscope-ready test patterns.

### Files
| File | Description |
|------|-------------|
| `serdes_cmd.v` | SerDes + UART commands + auto status reporting |
| `serdes_cmd.ccf` | Pin constraints |
| `build.sh` | One-command build and flash |

### Parameters
Same SerDes parameters as Phase 3a, plus:

| Parameter | Value |
|-----------|-------|
| UART baud rate | 57,600 |
| Auto-report interval | 2 seconds (100,000,000 cycles at 50 MHz) |
| Default TX pattern | COMMA (K28.5, 8B10B) |

### Commands
```
COMMA   — K28.5 comma pattern with 8B10B encoding (default, use for basic test)
PRBS    — PRBS-7 pseudo-random pattern (use for eye diagram / oscilloscope)
COUNT   — 64-bit incrementing counter
IDLE    — Electrical idle (signal goes flat)
STATUS  — Print "SerDes: READY" or "SerDes: NOT READY"
HELP    — List all commands
```

### Terminal Status Output (automatic every 2 seconds)
```
[OK] Mode: COMMA    — SerDes ready, loopback passing
[--] Mode: PRBS-7   — SerDes ready, no comma detected (normal for PRBS)
[!!] Mode: COMMA    — SerDes not initialised
```

### Oscilloscope Connection (to replicate measurements)

Connect probe to **J15 (TX+)** and GND.

| Setting | Value |
|---------|-------|
| Probe connection | J15 (TX+) to GND — single ended |
| Probe impedance | **50Ω** |
| Vertical scale | **50 mV/div** |
| Horizontal scale | **200 ps/div** |
| Trigger | Auto |
| Mode | Persistence (for eye diagram) |
| Pattern to use | `prbs` command |

**Approximate line rate:** ~1 Gbit/s  
(125 MHz LVDS reference × internal ADPLL multiplier, 80-bit datapath)

**Measured peak-to-peak voltage:** 181.17 mV  
**Oscilloscope used:** Keysight InfiniiVision DSOX6004A, 20 GSa/s  
**Date:** May 4, 2026

| Mode | What you see | Use for |
|------|-------------|---------|
| COMMA | Regular repeating pattern | Triggering, bit period measurement |
| PRBS | Pseudo-random transitions | **Eye diagram** (persistence mode) |
| IDLE | Near-zero differential voltage | Confirming electrical idle |
| COUNT | Structured incrementing pattern | Pattern recognition |

### Quick Start
```bash
cd 04_serdes_cmd
./build.sh
picocom -b 57600 --omap crcrlf /dev/ttyUSB2
# Expected automatic output every 2 seconds:
# [OK] Mode: COMMA
#
# Try commands:
# status  -> SerDes: READY
# prbs    -> Mode: PRBS-7  (connect oscilloscope to J15 for eye diagram)
# comma   -> Mode: COMMA
```

### Cable Disconnect Test (verify loopback is genuine)
```
1. Type: comma
2. Confirm: [OK] Mode: COMMA
3. Disconnect one SMA cable (J13 or J15)
4. Observe: output changes to [--] Mode: COMMA
5. Reconnect cable
6. Observe: returns to [OK] Mode: COMMA
```

---

## Replication Checklist

Follow this order to replicate all experiments from scratch:

- [ ] Install OSS CAD Suite and activate environment
- [ ] Install usbipd-win (Windows) and attach USB devices
- [ ] Verify `/dev/ttyUSB0`, `/dev/ttyUSB1`, `/dev/ttyUSB2` appear in WSL2
- [ ] Wire UART adapter to J17A (grey=pin1, orange=pin2, black=pin5)
- [ ] **Phase 0:** Flash `00_uart_echo`, type any character → echoed back
- [ ] **Phase 1:** Flash `01_uart_cmd`, type `status` → `GateMate OK`
- [ ] **Phase 2:** Flash `02_hyperram`, test `write 00 ab` and `read 00`
- [ ] Solder SMA connectors and X3 oscillator
- [ ] Install JP6 jumper
- [ ] Connect loopback cables J15↔J13 and J14↔J12
- [ ] **Phase 3a:** Flash `03_serdes_loopback`, verify D1+D2+D3 ON
- [ ] **Phase 3b:** Flash `04_serdes_cmd`, verify `[OK] Mode: COMMA` in terminal
- [ ] (Optional) Connect oscilloscope to J15, type `prbs`, capture eye diagram

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `fail to read data usb bulk read failed` | USB device disconnected from WSL2 | Re-run `usbipd attach` in PowerShell |
| UART shows nothing | Wrong ttyUSB port | Check `dmesg | grep ttyUSB`, try ttyUSB0/1/2 |
| UART shows garbage | Wrong baud rate or wiring | Confirm 57600 baud, check orange/grey swap |
| D1/D2/D3 not lighting (SerDes) | JP6 missing or clean reset needed | Check JP6 jumper, press SW3 after flash |
| SerDes never initialises | SERDES_AUTO_INIT=1 | Must be 0 — see serdes_top.v |
| `[--]` stuck in COMMA mode | SMA cable disconnected | Check J15↔J13 and J14↔J12 |
| HyperRAM reads return 0x00 | CLK90 not used | CLK90 from PLL must drive hram_clk_p/n |
| Kernel update breaks usbipd | WSL2 kernel updated | Reinstall linux-tools for new kernel version |

---

## Key Design Notes

### PLL Configuration
Both fabric PLL (50 MHz) and SerDes use `PERF_MD("SPEED")` without filter 
constants. The ECONOMY mode with filter constants produces wrong dividers in 
some toolchain versions.

### SerDes Critical Parameters
```verilog
.SERDES_AUTO_INIT(1'h0)  // MUST be 0
.PLL_CONFIG_SEL(1'h1)    // use register file
.PLL_REF_SEL(1'h1)       // LVDS reference from X3
.TX_CLK_I(PLL_CLK_O)     // use SerDes own ADPLL output
.RX_CLK_I(RX_CLK_O)      // use CDR recovered clock
```

### GateMate-Specific Rules
- Only one `always` block may drive any register (single-driver rule)
- No division/modulo in `always` blocks — use `localparam` or subtraction loops
- Use `CC_IOBUF` for bidirectional pins, not `CC_TOBUF` + `CC_IBUF`
- WB bank IO voltage: set via `#(.V_IO("1.8"))` in Verilog, NOT in CCF

---

## References

- [Cologne Chip GateMate Datasheet](https://colognechip.com/docs/ds1001-gatemate1-datasheet-latest.pdf)
- [GateMate Evaluation Board Datasheet](https://colognechip.com/docs/ds1003-gatemate1-evalboard-3v1-latest.pdf)
- [GateMate Primitives Library](https://colognechip.com/docs/ug1001-gatemate1-primitives-library-latest.pdf)
- [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
- [Project Peppercorn Test Cases](https://github.com/YosysHQ/prjpeppercorn-test-cases) — `084-serdes-loopback` was used as the SerDes reference
- [Cologne Chip Support Forum](https://colognechip.com/mygatemate)
- [Infineon S27KS0641 HyperRAM](https://www.infineon.com)
