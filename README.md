<p align="center">
  <img src="site/assets/logo.png" alt="WinToolify logo" width="120" />
</p>

# WinToolify

**Windows Management Harness**

WinToolify is a comprehensive PowerShell script that brings together the settings, services, applications, and system repair commands that users would otherwise have to configure individually from various sources on Windows 10 and 11, all within a single keyboard-navigable terminal interface.

[![CI](https://github.com/burakarslan0110/WinToolify/actions/workflows/ci.yml/badge.svg)](https://github.com/burakarslan0110/WinToolify/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Windows 10 and 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4)
![Windows PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![Languages: EN and TR](https://img.shields.io/badge/UI-English%20%7C%20T%C3%BCrk%C3%A7e-lightgrey)

Türkçe: [README.tr.md](README.tr.md) · Site and docs: [wintoolify.app](https://wintoolify.app/)

<p align="center">
  <img src="site/assets/wintoolify-tour-en-1920x1080.gif" width="900" alt="WinToolify running: on the Windows Services screen two services are marked in turn and applied, and both go from running to stopped and disabled. On the Privacy and Telemetry screen three settings are marked one at a time and applied together. The Undo Last Change screen then holds both applies as records. It ends in the assistant, which is asked what caused the last blue screen, reads the crash topic, searches the web, reads Microsoft's page on the stop code, and offers the matching report as suggestion one." />
</p>

## Quick start

Open PowerShell and run:

```powershell
irm https://github.com/burakarslan0110/WinToolify/releases/latest/download/WinToolify.ps1 | iex
```

That pulls the latest release into memory and starts it. If you're not an administrator, WinToolify relaunches itself elevated and picks up where it left off. Nothing touches disk until you actually apply a change.

Prefer to keep the file around? Grab `WinToolify.ps1` from the [latest release](https://github.com/burakarslan0110/WinToolify/releases/latest) and run it with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinToolify.ps1
```

Add `-Assistant` to open straight into the AI assistant. Every release ships a SHA-256 hash and a signed build attestation, so you can check what you downloaded before running it:

```powershell
(Get-FileHash .\WinToolify.ps1 -Algorithm SHA256).Hash.ToLower()
gh attestation verify .\WinToolify.ps1 --repo burakarslan0110/WinToolify
```

You'll need Windows 10 or 11, Windows PowerShell 5.1 or PowerShell 7, and administrator rights. The script elevates itself if you forget. winget and a local or remote OpenAI-compatible endpoint are optional, for the store and the assistant.

Building from source needs nothing but PowerShell itself, no modules, no network:

```powershell
.\build.cmd
```

## Requirements

| | |
|---|---|
| Operating system | Windows 10 or Windows 11 |
| PowerShell | Windows PowerShell 5.1 (PowerShell 7 also works) |
| Rights | Administrator. The script relaunches itself elevated if you start it without. |
| Optional | winget, for the store and the software actions. WinToolify offers to install App Installer if it is missing. |
| Optional | A local or remote OpenAI compatible LLM server, for the assistant. |

## Menu map

```
WinToolify
│
├── Tools and Settings
│   │
│   ├── Basic Tools
│   │   ├── Action Tools ......... 51 repair and maintenance commands
│   │   └── Information Tools .... 50 read-only reports
│   │
│   ├── Windows Services ......... 43 services, start type per row
│   ├── System Settings .......... 8 sections of persistent settings
│   ├── Privacy Settings ......... 7 screens, 242 registry settings
│   │   └── Per-App Permissions .. camera, microphone, location, and the rest
│   ├── Remove Bloatware Apps .... 122 preinstalled apps
│   ├── Winget Store ............. 252 programs in 10 categories
│   ├── Language ................. English / Türkçe
│   ├── Create Restore Point ..... your call, never automatic
│   ├── Undo Last Change ......... every recorded change, newest first
│   └── Config Profiles .......... export your settings, replay them elsewhere
│
└── WinToolify AI Assistant ...... console chat harness, 7 read-only tools
```

## What's inside

The main menu splits into Tools and Settings and the AI Assistant. Tools and Settings covers repair and diagnostic commands, 43 Windows services with a start type per row, 242 privacy and system settings filtered by Windows version, 122 preinstalled apps you can remove individually, and a winget-backed store of 252 programs sorted by category. A restore point is yours to take whenever you want one, WinToolify never takes one on its own. Every reversible change lands in an undo list you can replay in reverse, and a section's applied state exports to a profile you can carry to another machine.

The assistant is a console chat harness that talks to any OpenAI-compatible endpoint, local or remote. Its tools are read-only: it can search WinToolify's own catalogue, read about the machine, search the web, and save itself a note, nothing more. It never applies anything by itself. When it wants to suggest a fix, it hands you a numbered card, and running it goes through the same confirmation and undo record as picking it from a menu yourself.

## How it works

Every screen is the same list: arrows move, `Enter` opens or runs, `Esc` goes back. Screens that change something in Windows work in two steps, `Space` marks a row and `Enter` applies everything marked, so nothing gets applied just by wandering through a menu. Each row carries a risk tag: `SAFE` needs no warning, `CAUTION` says what changes, and `ADVANCED` spells out the consequence and asks you to type a word to confirm it.

## Repository layout

Sources sit in numbered layers under `src/` and get concatenated in that order, so a call always points downward, never up:

```
src/
  00-core/       storage, registry, errors, elevation, restore points
  10-i18n/       English and Turkish strings
  20-tui/        console, frames, lists, panels, the REPL
  30-engine/     apply records, commit plan, guarded change, undo
  40-catalogs/   the data: services, packages, privacy rows, DNS, store, tools
  50-apply/      one applier per catalog
  60-actions/    the Action Tools commands, the assistant client and agent
  70-info/       the read-only reports
  80-screens/    one file per screen
  90-main/       elevation and the entry point
tests/           Pester specs, one file per area
tools/           the builder and the check runner
```

`dist/WinToolify.ps1` is generated by the build and isn't checked in.

## Building and testing

```powershell
.\tools\Invoke-WtChecks.ps1
```

This is the one gate, and CI runs exactly this: build, parse, check PowerShell 5.1/7.0 compatibility, then run the full Pester suite, close to 3,000 tests. Run it instead of calling `Invoke-Pester` yourself, since the tests are written against the built file, not the sources.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the setup steps and the rules the build and tests actually enforce.

## Security

WinToolify runs elevated and changes system state, so please report anything that looks like a vulnerability privately rather than in a public issue. [SECURITY.md](SECURITY.md) has the reporting route and the scope.

## License

[MIT](LICENSE). Copyright (c) 2025-2026 Burak Arslan.
