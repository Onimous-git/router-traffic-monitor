# Router Traffic Monitor

Real-time per-device network traffic monitor for OpenWrt routers.  
Displays live bandwidth on an ESP32 + SSD1306 OLED display.

## Features

- **Hybrid mode** — Ethernet devices via switch MIB (includes LAN-to-LAN traffic) + WiFi devices auto-detected via nftables
- **Auto mode** — All devices automatically detected the moment they generate traffic
- **ESP32 Web UI** — Set device names, priorities, and endpoint from browser
- **Boot persistent** — Survives router reboots automatically
- **Internet safe** — Does not interfere with firewall4 or NAT masquerade

## Requirements

- OpenWrt 21.02 or newer
- ESP32 development board
- SSD1306 128x64 I2C OLED display
- Arduino IDE with: Adafruit SSD1306, Adafruit GFX, ArduinoJson, WebServer

## Quick Install

SSH into your router and run:

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/Onimous-git/router-traffic-monitor/main/install.sh
sh /tmp/install.sh
```

## Quick Uninstall

```sh
wget -O /tmp/uninstall.sh https://raw.githubusercontent.com/Onimous-git/router-traffic-monitor/main/uninstall.sh
sh /tmp/uninstall.sh
```

## How It Works

```
ESP32 → HTTP GET → Router CGI → swconfig MIB + nft sets → JSON → ESP32 → OLED
```

- **swconfig MIB** (hybrid/swconfig routers): reads hardware byte counters directly from switch chip — catches all traffic including LAN-to-LAN file transfers
- **DSA sysfs** (hybrid/DSA routers): reads per-port byte counters from `/sys/class/net/`
- **nft dynamic sets**: automatically tracks any WiFi device the moment it sends or receives a packet

## Supported Router Types

| Switch Type | Detection | Hybrid | Auto |
|---|---|---|---|
| swconfig (older routers) | Automatic | ✅ | ✅ |
| DSA (newer routers) | Automatic | ✅ | ✅ |
| No managed switch | Automatic | ❌ | ✅ |

## ESP32 Wiring

| OLED Pin | ESP32 Pin |
|---|---|
| VCC | 3.3V |
| GND | GND |
| SDA | GPIO 21 |
| SCL | GPIO 22 |

## OLED Layout

```
> NET-MON v1.0    [3]     [█]
────────────────────────────────
WIN   ↓ 2.3M   ↑128K
LIN   ↓ 512K   ↑ 64K
153   ↓  12K   ↑  8K
────────────────────────────────
00:02:14  [════════░░░░░░░░░░░]
```

## File Structure

```
router-traffic-monitor/
├── install.sh          — interactive installer
├── uninstall.sh        — clean removal
└── esp32/
    └── traffic_monitor/
        └── traffic_monitor.ino
```

## Adding a New Ethernet Device (Hybrid Mode)

Re-run the installer — it will detect the new port automatically during the port mapping step.

## License

MIT
