# Installing OpenWrt on ZyXEL EX3301-T0

This guide covers everything needed to install OpenWrt on the EX3301-T0
from scratch using the UART serial port and Ethernet.

---

## What you need

- ZyXEL EX3301-T0 device
- USB-to-UART serial adapter (3.3V logic level — **not 5V**)
  - Common: CH340, CP2102, FT232R
  - 3 wires needed: TX, RX, GND
- Ethernet cable (standard RJ45)
- Linux PC with USB port (or WSL2 on Windows with USB passthrough)
- The files in this folder: `flash.sh`, `flash_image.py`, the `.trx` image

---

## 1. Open the device

The EX3301-T0 case is held by 4 Phillips screws under the rubber feet on
the bottom. Remove the feet, unscrew, then lift the lid.

---

## 2. Connect the UART serial adapter

The UART header is a 4-pin unpopulated footprint on the PCB near the CPU,
labelled **J1** or **CON1** depending on board revision.

Pin layout (looking at the board with the header closest to you):

```
[ GND ] [ TX ] [ RX ] [ 3.3V ]
  1       2      3      4
```

Connect:
- **GND** (pin 1) → GND on your adapter
- **TX** (pin 2)  → RX on your adapter  *(device transmits, adapter receives)*
- **RX** (pin 3)  → TX on your adapter  *(device receives, adapter transmits)*
- **3.3V** (pin 4) → **do not connect** — power the device from its own supply

Settings: **115200 baud, 8N1, no flow control**

To verify the connection before flashing, attach screen and power on:
```
sudo screen /dev/ttyUSB0 115200
```
You should see boot messages within 2 seconds of powering on.
Press Ctrl+A then K to exit screen when done.

> **Tip**: If you see garbage characters, try swapping TX and RX wires.
> If you see nothing, check GND is connected.

---

## 3. Connect Ethernet

Connect an Ethernet cable from **any LAN port (LAN1–LAN4)** on the back
of the device to your PC's Ethernet port or a USB Ethernet adapter.

> Do **not** use the WAN/DSL port during flashing.

---

## 4. Set your host IP address

During flashing the device becomes a TFTP server at **192.168.1.1**.
Your host must be on the same subnet.

Find the name of your Ethernet interface:
```
ip link show
```
Look for the interface that changed state when you plugged in the cable
(e.g. `eth0`, `enp3s0`, `ethd0`). Then set a static IP:

```bash
sudo ip addr flush dev <interface>
sudo ip addr add 192.168.1.2/24 dev <interface>
sudo ip link set <interface> up
```

Verify:
```
ip addr show <interface>
# Should show: inet 192.168.1.2/24
```

---

## 5. Install dependencies

```bash
# Debian / Ubuntu
sudo apt install screen expect python3

# Arch Linux
sudo pacman -S screen expect python
```

---

## 6. Flash OpenWrt

All three files must be in the same directory:
- `flash.sh`
- `flash_image.py`
- `openwrt-econet-en751627-zyxel_ex3301-t0-squashfs-tclinux.trx`

Run the flash script as root:
```bash
sudo bash flash.sh
```

When prompted, **power cycle the device** (unplug, wait 2 seconds, plug back in).
The script catches the bootloader automatically — do not press any keys.

The script will:
1. Intercept the ZHAL bootloader over UART
2. Start a TFTP server on the device
3. Transfer the image over Ethernet
4. Wait for the NAND write to complete
5. Watch the boot log for 90 seconds

If your serial adapter is not at `/dev/ttyUSB0`, pass it as an argument:
```bash
sudo bash flash.sh /dev/ttyUSB1
```

---

## 7. First boot

After flashing, OpenWrt boots in about 20–25 seconds.

| Access method | Details |
|---------------|---------|
| SSH | `ssh root@192.168.1.1` — no password on first boot |
| Web UI (LuCI) | `http://192.168.1.1` |
| Serial console | `sudo screen /dev/ttyUSB0 115200` |

**Set a root password immediately:**
```bash
ssh root@192.168.1.1
passwd
```

---

## Hardware overview

| Component | Details |
|-----------|---------|
| SoC | EcoNet EN751627, MIPS 1004Kc, 800 MHz, 4 VPEs |
| RAM | 256 MB DDR3 |
| Flash | 128 MB SPI NAND |
| Switch | MediaTek MT7530, 4× GbE LAN |
| WiFi | MT7915 (2.4 GHz 4×4) + MT7916 (5 GHz 4×4) via PCIe |
| USB | xHCI (USB 2.0 HS confirmed; USB 3.0 SS requires PHY driver) |
| WAN | RJ45 GbE (DSL modem not supported under OpenWrt) |

---

## Known limitations

- **Front-panel LEDs**: SGPIO serial shift register — dark until a dedicated
  driver is written.
- **RJ45 port LEDs**: MT7530 in MCM mode, LED control not yet initialised.
- **USB SuperSpeed (3.0)**: PHY driver not yet written; USB 2.0 HS works.
- **DSL/WAN**: The DSL modem is proprietary. RJ45 WAN port works normally.

---

## Troubleshooting

**Script says "Device not responding"**
- Check the UART wires are connected correctly (TX↔RX crossed).
- Make sure you power-cycled the device *after* starting the script.
- Try `sudo screen /dev/ttyUSB0 115200` to verify you see boot output.

**Transfer fails at 0% or stalls**
- Confirm your host IP is `192.168.1.2/24` on the correct interface.
- Check the Ethernet cable is in a **LAN** port, not WAN.
- Disable any firewall rules that may block UDP port 69 (TFTP).

**Device boots back into original firmware**
- The image was written to slot 1. If BL2 boots slot 0 by default, run:
  `ATUR openwrt.trx,0` instead (edit `flash.sh` line with `ATUR`).
- This should not be needed on EX3301-T0 but may vary by firmware version.

**Checksum mismatch**
- Re-download the image. The file was corrupted during download.
