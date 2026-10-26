# Serial NAT gateway, rev 4: Windows sees only a COM port

```
 Network A                BRIDGE PC (Windows 11)                            ESP32-S3                 Network B
┌─────────┐   ┌───────────────────────────────────────┐  USB CDC-ACM  ┌─────────────────────┐ Wi-Fi STA ┌───────┐
│ clients │──►│ Python: NAT table (DNAT/SNAT), SOCKS5 │◄── COM port ─►│ socket gateway      │──────────►│ hosts │
│ (A)     │   │ mux + flow control over the serial    │  inbox usbser │ lwIP, own B-side IP │◄──────────│ (B)   │
└─────────┘   └───────────────────────────────────────┘               └─────────────────────┘           └───────┘
```

## Hard constraint, stated plainly
No network adapter + no driver means Windows has **no IP interface** into the bridge, and it cannot hand
arbitrary IP packets to Python (no TUN/TAP, no Npcap/WinDivert, and Windows raw sockets cannot send TCP). So a
*packet-level* transparent NAT or L2 bridge is impossible under these rules. What is possible is a **NAT at
connection level**, implemented in Python (PC) and the ESP32: traffic is translated per TCP connection / UDP flow,
but clients must address the PC (or use SOCKS5); it is not "any program, any destination, no configuration".
Any packet-level design needs either a USB network adapter (rev 2/3) or a driver.

## NAT semantics
* **Source NAT (A to B)**: every connection to network B leaves from the ESP32's Wi-Fi IP. Network B never learns
  the PC's or network A clients' addresses.
* **Destination NAT (A to B)**: a mapping table on the PC: `PC:listen_port -> B_host:port` (TCP/UDP). Any client of
  network A (or the PC itself) connects to the PC's port and is carried to the target on B. Optional **SOCKS5**
  front end for dynamic destinations (names resolved on the ESP32, so DNS follows network B).
* **Inbound (B to A)**: mapping on the ESP32: `ESP_wifi_ip:port -> A_target:port` (carried back over serial to the PC and
  connected to the target there). Opt-in with a source allow-list.
* **Hidden ESP32**: network A sees only the PC's mapped ports; the ESP32's B-side IP (DHCP, unknown in advance) is never
  exposed to A. Windows sees one COM port, no adapter.
* Flow entries have NAT-style idle timeouts (TCP closed on FIN/RST, UDP ~30-60 s).

## Components
* **ESP32-S3 firmware (ESP-IDF)**: TinyUSB **CDC-ACM only** (no JTAG/other interfaces, so Windows shows exactly one
  "USB Serial Device"; the chip's built-in USB-Serial/JTAG peripheral also exposes a JTAG interface that can show as an
  unknown device). Tasks: USB rx/deframe, single USB tx queue, a `select()` loop over up to 16 sockets, Wi-Fi manager
  with credentials in NVS, 10 s host-silence watchdog.
* **Python (3.10+, `pip install pyserial`, asyncio)**: serial link with auto-reconnect (finds VID 0x303A or `--port`),
  channel mux, NAT/mapping table, SOCKS5, Wi-Fi provisioning, status. Config via CLI/TOML.

## Wire protocol (implemented and tested in `host/serialbridge/protocol.py`)
`COBS(type | flags | chan u16 | payload<=1024 | crc32) 0x00`: instant resync, corruption detected.
Types: HELLO, PING/PONG, WIFI_SET/WIFI_STATUS, OPEN_TCP/OPEN_UDP/LISTEN, OPEN_RES, ACCEPT, DATA, CREDIT, CLOSE,
RESOLVE, DGRAM. **Per-channel credit flow control** (8 KiB initial window) so one slow peer cannot stall the others.

## Performance
USB full speed: ~0.8-1 MB/s total, shared both ways, +2-5 ms latency. Wi-Fi 2.4 GHz only. 16 concurrent connections
(lwIP socket limit, configurable). TCP and UDP only: no ping, no broadcast/multicast discovery, no other IP protocols.

## Build plan
1. Done: framing + tests. 2. Host link, mux, credit flow control. 3. Firmware: CDC + framing + Wi-Fi + TCP.
4. DNAT table + SOCKS5. 5. UDP, DNS, inbound mappings. 6. Soak and hot-unplug tests.
