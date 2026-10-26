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

## Primary workload: OpenAI-style HTTP(S) completions, including streaming

This fits connection-level NAT well: HTTP and SSE are plain TCP streams, so the tunnel never parses or buffers them.
* **Front ends, in priority order**
  1. **HTTP CONNECT proxy** (new, v1): point the client at it with `HTTPS_PROXY=http://127.0.0.1:3128`. The OpenAI
     Python/Node SDKs and curl honour this. TLS stays **end-to-end** between client and API, so certificates verify
     against the real hostname and the ESP32 never does TLS (no mbedTLS RAM cost, no CA store to maintain).
  2. **Mapped port** for plain-HTTP upstreams on network B (e.g. a local vLLM/llama.cpp server): set
     `base_url=http://PC:8080/v1`. A TLS upstream cannot use a mapped port (hostname mismatch); use the proxy.
  3. SOCKS5 for non-HTTP clients (later).
* **Streaming (SSE)**: no buffering anywhere. The ESP32 sets `TCP_NODELAY`, forwards each socket read as one DATA frame
  immediately, and the PC writes straight through (`drain()` only for backpressure). Added latency per token chunk is
  ~2-5 ms, invisible next to model latency.
* **Timeouts**: first-token latency can be minutes (cold GPU worker). No idle timeout on an established TCP channel;
  TCP keepalive on the ESP32 side, bridge keepalives (PING every 2 s) on the serial side. Only closed on FIN/RST,
  host-silence (watchdog), or Wi-Fi loss, after which clients see a normal connection reset and retry.
* **Bandwidth**: prompts and token streams are kilobytes; even long contexts or base64 images (MBs) take seconds
  at ~0.8 MB/s. Not a limit for this workload.
* **Connection count**: each in-flight request, and each idle keep-alive connection in the client's pool, holds
  one channel (max 16). The bridge answers CONNECT with `503` when the table is full and closes idle channels
  (default 60 s without data between requests, configurable; never during an active stream) so pools cannot starve it.
* **Resilience**: in-flight streams are lost if the USB cable is pulled or Wi-Fi drops (cannot be resumed); the
  gateway reconnects automatically and retries by the client work.

## Build plan (re-ordered for the primary workload)
1. Done: framing + tests.
2. Host: serial link with reconnect, channel mux, credit flow control.
3. Firmware: CDC-ACM + framing + Wi-Fi + TCP channels (+ DNS on ESP32).
4. HTTP CONNECT proxy and mapped ports. **End-to-end test: OpenAI SDK, streaming chat completion through the bridge.**
5. Idle-channel reaping, soak/hot-unplug tests.
6. Later/optional: SOCKS5, UDP, inbound mappings.
