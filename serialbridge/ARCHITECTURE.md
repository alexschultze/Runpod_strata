# USB-to-Wi-Fi L2 bridge (ESP32-S3), rev 3: the ESP32 has no IP address

```
 BRIDGE PC (Windows 11)                  ESP32-S3 (no netif, no lwIP, no IP)             Network B
┌──────────────────────┐  USB composite  ┌──────────────────────────────┐   Wi-Fi STA   ┌─────────┐
│ "USB Ethernet" NIC   │◄─ NCM (frames) ►│ raw Ethernet frame pump      │◄─────────────►│ AP /    │
│  MAC = X, IP from B  │   inbox driver  │  USB NCM  <──>  Wi-Fi STA    │  STA MAC = X  │ DHCP    │
│ Python provisioning  │◄─ CDC-ACM ─────►│ control channel (Wi-Fi creds)│               └─────────┘
└──────────────────────┘  inbox usbser   └──────────────────────────────┘
```

## Why this shape
* "ESP32 shows up as no network device with an IP" means no NAT/router on the ESP32 (that needs an address on
  the inside) and no proxy. The ESP32 only moves Ethernet frames. The PC's USB adapter is the sole IP endpoint,
  and it gets its address **from network B's DHCP** through the bridge.
* **Wi-Fi limitation**: a station may only transmit frames with its own MAC. Solution: **MAC cloning**. The
  firmware sets the Wi-Fi STA MAC (`esp_wifi_set_mac`) to the same address X that it advertises to Windows in the
  NCM descriptor, so frames pass unmodified: DHCP, ARP, mDNS, ping, any IP protocol work, and the router sees one
  device (the PC) with MAC X. The ESP32 itself never appears at layer 3 anywhere.
* Supports **one** PC/MAC behind the bridge (typical for a client bridge). More than one needs MAC translation
  (proxy-ARP / relayd-style) and is out of scope.
* IPv6 works as far as it works for a single cloned MAC; broadcast/multicast over Wi-Fi are subject to the AP's rules.

## Components
* **Firmware (ESP-IDF)**: TinyUSB composite device = **CDC-NCM** (network) + **CDC-ACM** (control). Data path is
  raw frames between the NCM driver and the Wi-Fi driver (Wi-Fi internal rx/tx hooks such as
  `esp_wifi_internal_reg_rxcb`/`esp_wifi_internal_tx`; `esp-iot-bridge`'s bridge mode is a reference, verify
  availability and IDF version). No lwIP netif is created on either side, so the chip answers no ARP/ICMP/DHCP.
  Wi-Fi credentials, MAC X and settings live in NVS.
* **Windows 11**: NCM binds to the inbox network class driver, ACM to inbox `usbser.sys`. No driver install.
  (If the NCM driver is missing on a PC, RNDIS is the fallback.)
* **Python (`pip install pyserial`)**: only provisioning/diagnostics over the COM port: `wifi set`, `status`
  (link state, RSSI, frame/byte counters, drops), `mac`, `reboot`. It is not in the data path. Line-based
  JSON commands, so it can be tested with any terminal.

## Performance and limits
~0.8-1 MB/s total (USB full speed), +2-5 ms latency; the data path is zero-copy-ish frame forwarding, so the CPU
is not the limit. 2.4 GHz only. Wi-Fi networks that bind clients to a MAC (802.1X, captive portal needing a
browser on the PC) work only if the PC can complete them itself. Unlike NAT, network B hosts can reach the PC directly,
so use the PC's firewall.

## Note on the earlier NAT design
NAT hid the PC behind the ESP32 but required the ESP32 to own IP addresses on both sides, which this requirement
excludes. If address translation is still needed, it would have to happen on the PC (Windows ICS/NetNat) on top
of this bridge.

## Build plan
1. Composite USB (NCM + ACM) enumerates on Windows 11 with no manual driver step.
2. Wi-Fi STA with cloned MAC; frame pump both ways; DHCP from network B reaches the PC.
3. Serial control + NVS provisioning; Python tool.
4. Soak: throughput, hot-unplug, Wi-Fi drop/reassociate, AP roaming.
