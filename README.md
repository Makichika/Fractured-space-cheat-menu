# Fractured Space Solo Trainer v20

Trainer designed for the local/single-player `spserver.exe` server used by Fractured Space.

## IMPORTANT — before extracting the ZIP

If you download the trainer as a ZIP file and Windows shows an **Unblock** option:

1. **Before extracting the ZIP**, right-click the ZIP file → **Properties**.
2. In the **General** tab, at the bottom, check **Unblock**.
3. Click **Apply**, then **OK**.
4. Only then extract the contents of the ZIP.

Only do this for an archive downloaded from the official repository/release and after verifying its source. This removes Windows' “downloaded from the Internet” mark from the ZIP; it does **not** disable Microsoft Defender or Smart App Control.

## Usage

1. Launch Fractured Space.
2. Start a local/single-player match so that `spserver.exe` is running.
3. Launch `RUN_V20.bat`.
4. Use the trainer as usual.

## Changes in this distribution

- The trainer's core logic has not been modified.
- `FracturedSpaceSoloTrainer_v20.ps1` is unchanged.
- `Sandbox_v20.ps1` is unchanged.
- `data/ship-systems.json` is unchanged.
- The launcher no longer forces `-ExecutionPolicy Bypass`.
- `data/trainer-debug.log` is no longer distributed; the trainer recreates it locally when needed.
- SHA-256 checksums are provided in `SHA256SUMS.txt`.

## Why Windows may still show a warning

The trainer interacts with the memory of `spserver.exe` and uses Windows APIs such as `OpenProcess`, `ReadProcessMemory`, `WriteProcessMemory`, `VirtualAllocEx`, `VirtualProtectEx`, and `CreateRemoteThread`.

These techniques are also used by some malicious software, so heuristic security systems may still display a warning even when the project is open source.

This distribution does not attempt to disable Defender, Smart App Control, or AMSI, and does not attempt to hide these operations.

## Important

Do not disable Windows Defender or Smart App Control to run the trainer.

For a public distribution with fewer warnings, the proper next step is to sign the scripts/releases with a code-signing certificate and keep reproducible builds with published checksums.
