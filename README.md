# System Snapshot Tool

> Built with the assistance of [Claude Code](https://claude.com/claude-code), Anthropic's AI coding
> assistant. The PowerShell GUI, data-gathering logic, and HTML report template in this repo were
> generated and iterated on with Claude.

A PowerShell GUI tool that gathers a quick, point-in-time diagnostic snapshot of a Windows machine
and produces a single self-contained, shareable HTML report — a fast starting point for
troubleshooting, not an exhaustive audit.

## Features

- **System overview** — make/model, serial number, BIOS version, CPU, RAM (per-module), GPU/driver.
- **OS info** — version/build, install date, uptime, activation status, pending-reboot check,
  recently installed updates, and recent failed/incomplete updates.
- **Hardware & drivers** — devices with problems (Device Manager errors), key driver versions
  (network, display, storage, USB, Bluetooth, media).
- **Hardware-related Event Log errors** — System log errors/warnings from the last 14 days.
- **Crash history** — unexpected shutdowns (Kernel-Power Event 41), bug check/stop error summaries,
  minidump file listing.
- **Network configuration** — adapters, IP/subnet/gateway/DNS, and Wi-Fi details (SSID, signal %,
  RSSI, band/channel, radio type, link rates, power-saving mode).
- **Connectivity test** — ping + jitter + DNS resolution timing against a few well-known targets
  plus any custom targets you add, and a basic traceroute (three probes per hop, reverse-DNS
  hostnames) to help tell whether an issue is inside your network or upstream.
- **Disk health & free space** — per-volume free space and physical disk health status.
- **Security status** — Windows Defender, firewall profiles, BitLocker.
- **Startup programs & top processes** — startup entries plus top 5 CPU/memory processes.
- **Installed software** — full list from the registry uninstall keys, with a live filter box in
  the report.

Sections you don't want can be unchecked before running. Anything that needs Administrator rights
(e.g. physical disk health details, BitLocker) is simply flagged as unavailable rather than failing
the whole run, and the tool offers a one-click restart-as-admin if you want that data.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+ (built into Windows — nothing else to install).

## Usage

Double-click **`Run SystemSnapshot.bat`**, or run directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\SystemSnapshot.ps1
```

Pick the sections you want, optionally add extra ping/traceroute targets (e.g. a specific WAN IP),
choose where to save the report, and click **Run Snapshot**. The report opens automatically in your
default browser when it's done.

## Notes

- The generated report (`SystemSnapshot_*.html`) is not tracked in this repo — see `.gitignore`.
- Some checks (disk health, BitLocker) report richer detail when run elevated.
