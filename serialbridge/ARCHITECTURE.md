# USB NAT bridge (ESP32-S3): architecture, rev 2

Supersedes the serial/proxy design (removed): a proxy needs every app to cooperate, and without a
PC driver there is no way to capture arbitrary IP traffic and push it down a serial line.
The only driver-free way to get *transparent* connectivity is for the ESP32 to **be** a network adapter.

```
 BRIDGE PC (Windows 11)                    ESP32-S3                                  Network B
┌──────────────────────┐   USB (NCM,     ┌─────────────────────────────┐  Wi-Fi STA  ┌───────────┐
│ "USB Ethernet" NIC   │◄── inbox drv ──►│ lwIP netif "usb" 10.254.77.1│  (DHCP, IP  │ router,   │
│ 10.254.77.2 (DHCP)   │   12 Mbit/s     │   DHCP server, DNS relay    │   unknown   │ hosts     │
│ Python control client│── HTTP :80 ────►│   NAPT ──────────────────►  │   in advance)──►         │
└──────────────────────┘                 │ netif "wifi" x.x.x.x (B)    │             └───────────┘
                                         └─────────────────────────────┘
```

## How it works

* **USB**: the ESP32-S3 native USB port (GPIO19/20, TinyUSB) enumerates as a CDC-**NCM** Ethernet device
  (RNDIS selectable as fallback). Windows 11 binds its inbox class driver; no installation. (CDC-ECM is *not*
  supported by Windows, so don't use it.)
* **NAT**: lwIP **NAPT** on the ESP32 translates everything from the USB side to the ESP32's Wi-Fi address.
  Network B only ever sees the ESP32's DHCP-assigned IP, which nobody has to know in advance. The PC (the
  "bridge's network") sees only the fixed private USB subnet.
* **Addressing**: ESP32 runs a DHCP server on the USB side (default `10.254.77.0/24`, unusual on purpose; the
  firmware must pick another /24 if network B's learned subnet collides, otherwise NAT breaks). DHCP hands out
  the ESP32's own address as DNS server, which relays to the DNS learned from network B.
* **Routing on the PC**: by default the ESP32 offers **no default gateway**, so Windows keeps using its normal
  uplink for everything else. Destinations on network B are added as routes via `10.254.77.1` (DHCP option 121
  from the ESP32, or `route add`/`New-NetRoute` by the Python helper; both built into Windows, admin needed
  only for the latter). A "full tunnel" mode (ESP32 gives a default gateway, lower metric) is optional.
* **Inbound from network B**: NAT is outbound-only. Reachability of PC services from B is by explicit
  port mappings (NAPT port-forward: ESP32 `wifi_ip:port` → `10.254.77.2:port`), managed from Python.
* **Optional**: other hosts on the PC's LAN A can use the PC as a gateway (Windows IP forwarding, built in:
  `Set-NetIPInterface -Forwarding Enabled` on both NICs, plus a route to B via the PC on those hosts). They are
  then double-NATed (their source IPs also get translated by the ESP32).

## Components

### ESP32-S3 firmware (ESP-IDF; start from Espressif's `esp-iot-bridge` component)
`esp-iot-bridge` already implements "Wi-Fi station as WAN + USB (NCM/RNDIS) as LAN with NAT, DHCP server and DNS
forwarding" for ESP32-S2/S3. Verify the NCM option and the IDF version in its current docs; otherwise build the
same from `esp_tinyusb` + `esp_netif` + `CONFIG_LWIP_IPV4_NAPT`.
Additions on top:
* Control REST API on `http://10.254.77.1/` (USB side only, never exposed on Wi-Fi): `PUT /wifi {ssid,psk}`,
  `GET /status` (Wi-Fi state, B-side IP/GW/DNS, RSSI, NAT table size, USB/WiFi byte counters),
  `GET/POST/DELETE /portmap`, `POST /reboot`. Credentials live in NVS.
* Subnet-conflict handling, link watchdog (reconnect Wi-Fi with backoff), NAT table sizing and entry timeouts.

### PC side (Python 3.10+, standard library only)
No serial port and no `pyserial` any more; the PC talks to the ESP32 over the network it provides.
* `bridgectl`: discovers the adapter (by name/MAC via PowerShell `Get-NetAdapter`), waits for `10.254.77.1`,
  provisions Wi-Fi, reads status, manages port mappings, and installs/removes routes to the chosen network-B
  prefixes (`route add`). `bridgectl status|wifi|route|portmap`.
* Optional small tray/service loop that re-applies routes after the adapter re-enumerates.

## Performance (estimates)

USB full speed (the S3 has no high-speed USB) caps at ~1.2 MB/s total; expect **~0.8-1 MB/s, shared both ways**,
added latency ~2-5 ms. Wi-Fi (single-stream 2.4 GHz n) and NAPT on the S3 can each carry more, so USB remains the
limit. Concurrent connections are bounded by the NAT table (default few hundred; configure) and RAM.

## Limitations

* 2.4 GHz Wi-Fi only; captive-portal or enterprise networks need extra firmware work (WPA2-Enterprise is supported by IDF).
* lwIP NAPT handles TCP/UDP/ICMP echo only; no IPv6, no protocols such as GRE/IPsec ESP passthrough.
* The ESP32 is not a full firewall; anything from the PC is NATed out. Keep the REST API USB-side only.
* Windows classifies the adapter as a new "unidentified" network; set it to Private/ignore as needed.

## Build plan
1. Firmware: Wi-Fi STA + USB NCM + DHCP + NAPT working (ping/HTTP from the PC to network B).
2. Verify Windows 11 binding with no manual driver step; fall back to RNDIS if a target PC lacks NCM.
3. REST control API + NVS credentials + subnet-conflict logic.
4. `bridgectl` (routes, Wi-Fi, portmaps).
5. Soak: throughput ≥ 0.8 MB/s, many connections, hot-unplug, Wi-Fi drop recovery.

## Open question
Should only the bridge PC use the link (default), or should other hosts on its LAN A also route through it?
