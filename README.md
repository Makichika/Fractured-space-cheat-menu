# Fractured Space Solo Trainer v20

Trainer designed for the local/single-player `spserver.exe` server used by Fractured Space.

## IMPORTANT — before extracting the ZIP

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

## Why Windows may still show a warning

The trainer interacts with the memory of `spserver.exe` and uses Windows APIs such as `OpenProcess`, `ReadProcessMemory`, `WriteProcessMemory`, `VirtualAllocEx`, `VirtualProtectEx`, and `CreateRemoteThread`.
