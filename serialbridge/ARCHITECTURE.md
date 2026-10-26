# LAN over serial: architecture

```
 Network A                BRIDGE PC (Windows 11)                       Network B
┌──────────┐   ┌───────────────────────────────────────┐        ┌────────────────────┐
│ apps /   │   │ Python (asyncio)                      │  USB   │ ESP32-S3           │   Wi-Fi   ┌───────┐
│ clients  ├──►│ SOCKS5 + port forwards (127.0.0.1/LAN)├──CDC──►│ socket gateway     ├──────────►│ hosts │
│          │   │ mux/demux, flow control, reconnect    │ serial │ lwIP, Wi-Fi STA    │ (net B)   └───────┘
└──────────┘   └───────────────────────────────────────┘        └────────────────────┘
```

## Constraints and what they force

| Constraint | Consequence |
|---|---|
| Windows 11, **no additional drivers** | The ESP32-S3 must use its **native USB port** (GPIO19/20), which enumerates as a standard CDC-ACM device. Windows binds its inbox `usbser.sys` automatically; it appears as a COM port. Boards' UART-bridge port (CP210x/CH340) needs a vendor driver: do not use it. `pyserial` is a pip package, not a driver. |
| No driver means **no virtual NIC** | TAP/Wintun/Npcap cannot be installed, so the PC cannot get a tunnel interface or inject raw frames. "LAN over serial" is therefore built at **L4 (TCP/UDP), in user space**: the PC runs a proxy, the ESP32 is the egress onto network B. |
| ESP32-S3 joins a different network | It is a Wi-Fi **station** on network B with its own IP there. All traffic leaves network A's side as the ESP32's IP (NAT-like). Network B hosts see the ESP32, not the PC. |

Not provided (inherent to the no-driver choice): ping/ICMP from the PC, broadcast/multicast discovery (mDNS, SSDP, DHCP), non-TCP/UDP protocols, and apps that cannot use a SOCKS5 proxy or a configured port forward. A true L2/L3 bridge would need a driver on the PC and is out of scope.

## Components

### 1. PC side (`host/serialbridge`, Python 3.10+, `pip install pyserial`)

* **Serial link**: opens the COM port (auto-detect by USB VID 0x303A, or `--port COM7`). A reader thread feeds the `Deframer`; a writer queue serialises frames. Reconnects when the device is replugged or reset (the ESP32-S3 re-enumerates), then re-sends Wi-Fi config and re-opens listeners.
* **Mux**: every proxied connection is a *channel* (u16). The PC allocates channel ids for outbound opens, the ESP32 for inbound accepts (high bit set to avoid collisions).
* **Front ends** (all asyncio servers):
  * **SOCKS5** (CONNECT, UDP ASSOCIATE, domain names resolved *on the ESP32* so DNS follows network B). Point browsers, `curl --socks5-hostname`, and most tools at it.
  * **Static forwards**: `-L 127.0.0.1:8080=192.168.50.10:80` for apps without proxy support (RDP, SSH, databases).
  * **Reverse forwards**: `-R 2222=127.0.0.1:22` makes the ESP32 listen on network B port 2222 and tunnel connections to a service on the PC / network A.
* **Config/CLI**: `python -m serialbridge --wifi-ssid ... --socks 1080 -L ... -R ...`; Wi-Fi credentials are sent over the link and stored in the ESP32's NVS, so the firmware never needs reflashing to change networks.

### 2. ESP32-S3 firmware (ESP-IDF, FreeRTOS)

* **USB**: TinyUSB CDC-ACM on the native port (or the built-in USB-Serial/JTAG peripheral as the simplest start). Full speed 12 Mbit/s: roughly 0.8-1 MB/s real throughput, above typical ESP32 Wi-Fi throughput, so USB is not the bottleneck.
* **Tasks**: `usb_rx` (deframe, dispatch) → per-channel state; `usb_tx` (single queue so frames never interleave); `net` task running `select()` over all channel sockets.
* **Channel table**: up to 16 sockets (raise `LWIP_MAX_SOCKETS`/`CONFIG_LWIP_MAX_SOCKETS`). Each holds an fd, the PC-granted send credit, and a small TX ring.
* **Wi-Fi manager**: STA with auto-reconnect; reports state/IP/RSSI via `WIFI_STATUS`. Optional fallback SoftAP is not needed.
* **Watchdog**: if no `PING` arrives for 10 s, close all channels and wait for the host (prevents orphaned sockets after the PC app dies).

## Protocol (implemented in `host/serialbridge/protocol.py`)

Framing: `COBS(type u8 | flags u8 | chan u16 | payload | crc32) 0x00`. The 0x00 delimiter gives instant resync after garbage or a mid-frame reset; the CRC catches corruption (USB itself is reliable, this guards against firmware bugs and noisy true-UART use). Payload ≤ 1024 B.

| Type | Direction | Purpose |
|---|---|---|
| HELLO / PING / PONG | both | version/capabilities, 2 s keepalive, RTT |
| WIFI_SET / WIFI_STATUS | PC→ESP / ESP→PC | provision and observe network B link |
| OPEN_TCP / OPEN_UDP / LISTEN | PC→ESP | create channel to `host:port` on net B, or listen there |
| OPEN_RES / ACCEPT | ESP→PC | result (errno-like status) / inbound connection |
| DATA | both | stream bytes |
| CREDIT | both | **flow control**: receiver grants N more bytes |
| CLOSE | both | half/full close with reason in flags |
| RESOLVE / RESOLVE_RES | PC↔ESP | DNS on network B |
| DGRAM | both | UDP datagram (`ip:port` + data) |

**Flow control** is per channel and credit-based (initial window 8 KiB, topped up as the consumer drains). A slow TCP peer on one channel therefore never blocks the others or overflows the ESP32's few hundred KB of RAM; this is the one property that makes multiplexing over a single serial pipe safe.

## Data flow example (browser → host on network B)

1. Browser connects to PC `127.0.0.1:1080` (SOCKS5), asks for `intranet.local:80`.
2. Python allocates channel 5, sends `OPEN_TCP(5, 80, "intranet.local")`.
3. ESP32 resolves via network B's DNS, `connect()`s, replies `OPEN_RES(5, ok, credit)`.
4. Python answers the SOCKS5 success; bytes now flow as `DATA` frames both ways, throttled by `CREDIT`.
5. Either side closing sends `CLOSE(5)`; the other side shuts its socket.

## Failure behaviour

* USB unplug/reset: host drops all channels (clients see a normal TCP reset), reconnects the COM port, re-provisions Wi-Fi, restores listeners.
* Wi-Fi loss: `WIFI_STATUS` pushed; new opens fail fast with a status code; existing channels reset.
* Host crash: ESP32 watchdog closes sockets.

## Security

The link is physically point-to-point, but anything on network B can reach reverse-forward listeners and anything on the PC can use the SOCKS port. Bind the SOCKS/forwards to `127.0.0.1` by default, make reverse-forward listeners opt-in with a source allow-list, and keep Wi-Fi credentials only in ESP32 NVS (enable flash encryption for production).

## Build plan

1. **Done here**: wire protocol + tests (`python tests/test_protocol.py`).
2. Host: serial link with reconnect, channel mux with credit flow control, SOCKS5 front end.
3. Firmware skeleton: TinyUSB CDC + framing + Wi-Fi + TCP channels.
4. UDP, DNS, reverse forwards.
5. Throughput/soak tests (target: ≥ 1 MB/s aggregate, 16 concurrent channels, hot-unplug recovery).

## Open choices for you

* **Native USB CDC (recommended)** vs. a WinUSB vendor interface (faster/cleaner, still driver-free on Win10+ via MS OS 2.0 descriptors, but needs `libusb`/`pyusb` DLLs on the PC).
* Whether UDP and reverse forwards are needed in v1.
