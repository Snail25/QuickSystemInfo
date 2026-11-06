# Quick System Info

> Built with the assistance of [Claude Code](https://claude.com/claude-code), Anthropic's AI coding
> assistant. The PowerShell GUI, data-gathering logic, and HTML report template in this repo were
> generated and iterated on with Claude.

A PowerShell GUI tool that gathers a quick, point-in-time diagnostic snapshot of a Windows machine
and produces a single self-contained, shareable HTML report — a fast starting point for
troubleshooting, not an exhaustive audit. Made to be easy for family and friends to run and send
back.

## Features

- **System overview** — make/model, system serial number, BIOS version, motherboard manufacturer /
  model / version / serial, CPU, RAM (per-module), GPU/driver. Placeholder values that custom-built
  PCs often report (e.g. "Default string", "To be filled by O.E.M.") are shown as
  *Not set by manufacturer* instead of as a serial.
- **OS info** — version/build, install date, uptime, activation status, pending-reboot check,
  recently installed updates, and recent failed/incomplete updates.
- **Hardware & drivers** — devices with problems (Device Manager errors), key driver versions
  (network, display, storage, USB, Bluetooth, media).
- **Hardware-related Event Log errors** — System log errors/warnings from the last 14 days.
- **Crash history** — unexpected shutdowns (Kernel-Power Event 41), bug check/stop error summaries,
  the configured crash dump type and locations (read from the registry, in case dumps go somewhere
  other than the default), and every minidump / full memory dump found, with full path, created
  and modified dates, and size.
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
(e.g. physical disk health details, BitLocker, listing minidump files) is simply flagged as
unavailable rather than failing the whole run, and the tool offers a one-click restart-as-admin if
you want that data.

## The report

- Every section starts **collapsed**. Its header shows status badges (e.g. *Reboot pending*,
  *2 problem devices*, *Low disk*, *1 bluescreen*, or *OK*), so problems are visible without
  opening anything.
- **Expand all** / **Collapse all** buttons sit above the contents list, and clicking a contents
  link opens the section it points to. Opening the file with `#SectionName` on the end of the
  address (e.g. `#Crash`) opens that section too.
- Printing (or saving as PDF) expands every section automatically, then restores the previous
  state afterwards.
- The footer shows the tool version (e.g. *Quick System Info v1.1.0*), so you can tell which copy
  someone ran.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+ (built into Windows — nothing else to install).

## Usage

Double-click **`Run Quick System Info.bat`**, or run directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\QuickSystemInfo.ps1
```

Pick the sections you want, optionally add extra ping/traceroute targets (e.g. a specific WAN IP),
choose where to save the report, and click **Run Snapshot**. The report
(`QuickSystemInfo_<PC>_<date>.html`, saved to the Desktop by default) opens automatically in the
default browser when it's done. Send that file back.

## Notes

- Bump `$script:ToolVersion` at the top of `QuickSystemInfo.ps1` whenever you change the script.
- The generated report (`QuickSystemInfo_*.html`) is not tracked in this repo — see `.gitignore`.
- Some checks (disk health, BitLocker, minidump files) report richer detail when run elevated.
