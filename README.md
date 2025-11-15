# How to install
1. Download `install-pack.ps1`
2. Open PowerShell
3. cd <folder where you saved install-pack.ps1>
4. powershell -ExecutionPolicy Bypass -File .\install-pack.ps1

## Optional Flags
- -Isolate → installs to %APPDATA%\.bubus-minecraft (keeps their normal .minecraft untouched)

- -Clean → backs up & clears mods/ + config/ before syncing (good to avoid leftover mods)

- -UpdateOnly → skip Fabric install; only refresh the modpack

## Example
```bash
powershell -ExecutionPolicy Bypass -File .\install-pack.ps1 -Isolate -Clean
```