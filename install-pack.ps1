<# install-pack.ps1
   - Installs Fabric into the launcher's active .minecraft (so a profile appears)
   - Creates/updates profile "Bubus Modpack"
   - If -Isolate, sets profile Game Directory to %APPDATA%\.bubus-minecraft
   - Syncs Packwiz pack into the chosen game dir (mods/config really land there)
#>

param(
  [string]$PackUrl       = "https://raw.githubusercontent.com/jcouth/docker-mine-bubus/main/packwiz/pack.toml",
  [string]$McVersion     = "1.20.1",
  [string]$LoaderVersion = "0.17.2",
  [switch]$Isolate,
  [switch]$Clean,
  [switch]$UpdateOnly,
  [switch]$VerboseLog
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
try { chcp 65001 | Out-Null } catch {}

function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err ($m){ Write-Host "[FAIL] $m" -ForegroundColor Red }

function Get-LauncherCandidates {
  @(
    "$env:APPDATA\.minecraft",
    "$env:LOCALAPPDATA\.minecraft",
    "$env:LOCALAPPDATA\Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\.minecraft"
  )
}

# robustly pick the active launcher .minecraft
function Get-LauncherMinecraftDir {
  $c = Get-LauncherCandidates
  $withVersions = @($c | Where-Object { Test-Path (Join-Path $_ 'versions') })
  if ($withVersions.Count -gt 0) { return $withVersions[0] }
  $existing = @($c | Where-Object { Test-Path $_ })
  if ($existing.Count -gt 0) { return $existing[0] }
  return "$env:APPDATA\.minecraft"
}

function Get-LauncherProfileFiles {
  $base = Get-LauncherCandidates
  $candidates = @(
    (Join-Path $base[0] 'launcher_profiles.json'),
    (Join-Path $base[0] 'launcher_profiles_microsoft_store.json'),
    (Join-Path $base[1] 'launcher_profiles.json'),
    (Join-Path $base[2] 'launcher_profiles.json'),
    (Join-Path $base[2] 'launcher_profiles_microsoft_store.json')
  ) | Select-Object -Unique

  $existing = @($candidates | Where-Object { Test-Path $_ })
  if ($existing.Count -gt 0) { return $existing }

  # Create a classic file if none exist yet
  $primary = Get-LauncherMinecraftDir
  $target  = Join-Path $primary 'launcher_profiles.json'
  if (-not (Test-Path $primary)) { New-Item -ItemType Directory -Force $primary | Out-Null }
  if (-not (Test-Path $target)) {
    (@{ profiles = @{} } | ConvertTo-Json -Depth 5) | Set-Content -Path $target -Encoding UTF8
  }
  return @($target)
}

function Ensure-Dir([string]$path){
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force $path | Out-Null }
}

function Get-JavaPath([string]$LauncherDir){
  $java = (Get-Command java -ErrorAction SilentlyContinue).Source
  if ($java) { return $java }
  $rt = Join-Path $LauncherDir 'runtime'
  if (Test-Path $rt) {
    $j = Get-ChildItem -Path $rt -Recurse -Filter java.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($j) { return $j.FullName }
  }
  return $null
}

function Download-File([string]$Url, [string]$OutPath){
  try {
    & curl.exe -L -o $OutPath $Url | Out-Null
  } catch {
    Write-Warn "curl failed, trying Invoke-WebRequest... ($Url)"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $OutPath
  }
  if (-not (Test-Path $OutPath)) { throw "Download failed: $Url" }
}

function Backup-And-Clean([string]$Dir){
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $mods   = Join-Path $Dir 'mods'
  $config = Join-Path $Dir 'config'
  if (Test-Path $mods)   { Move-Item $mods   (Join-Path $Dir "mods_backup_$stamp")   -Force }
  if (Test-Path $config) { Move-Item $config (Join-Path $Dir "config_backup_$stamp") -Force }
  Ensure-Dir $mods; Ensure-Dir $config
  $pwState = Join-Path $Dir '.packwiz'
  if (Test-Path $pwState) { Remove-Item -Recurse -Force $pwState }
}

function Install-Fabric([string]$Java,[string]$LauncherDir,[string]$MCV,[string]$LoaderV){
  $tmp = Join-Path $env:TEMP 'packsetup'
  Ensure-Dir $tmp
  $fi = Join-Path $tmp 'fabric-installer.jar'

  Write-Info "Downloading Fabric installer (GitHub latest)..."
  $ok = $true
  try {
    Download-File 'https://github.com/FabricMC/fabric-installer/releases/latest/download/fabric-installer.jar' $fi
    if ((Get-Item $fi).Length -lt 10000) { $ok = $false }
  } catch { $ok = $false }

  if (-not $ok) {
    Write-Warn "GitHub download looks bad (tiny/corrupt). Falling back to Fabric Maven..."
    $fi = Join-Path $tmp 'fabric-installer-1.1.0.jar'
    Download-File 'https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.0/fabric-installer-1.1.0.jar' $fi
  }

  Ensure-Dir $LauncherDir
  Write-Info "Installing Fabric Loader $LoaderV for MC $MCV into $LauncherDir ..."
  & $Java -jar $fi client -dir "$LauncherDir" -mcversion $MCV -loader $LoaderV

  # FIX: checar código de saída do instalador
  if ($LASTEXITCODE -ne 0) {
    Write-Err "Fabric installer exited with code $LASTEXITCODE"
    throw "Fabric installer failed"
  }

  $verA = Join-Path $LauncherDir "versions\fabric-loader-$LoaderV-$MCV"
  $verB = Join-Path $LauncherDir "versions\fabric-loader-$MCV-$LoaderV"
  if     (Test-Path $verA) { Write-Info "Found Fabric version folder: $verA" }
  elseif (Test-Path $verB) { Write-Info "Found Fabric version folder: $verB" }
  else {
    Write-Err "Fabric version folder not found: $verA or $verB"
    throw "Fabric install did not create the expected version"
  }
}

function Set-LauncherProfileCore(
  [string]$ProfilesFile,
  [string]$ProfileName,
  [string]$VersionId,
  [string]$GameDirForProfile
){
  if (-not (Test-Path $ProfilesFile)) {
    (@{ profiles = @{} } | ConvertTo-Json -Depth 5) | Set-Content -Path $ProfilesFile -Encoding UTF8
  }

  $raw  = Get-Content $ProfilesFile -Raw
  try   { $json = $raw | ConvertFrom-Json }
  catch {
    Write-Warn "Launcher profile JSON is invalid, recreating minimal structure. ($ProfilesFile)"
    $json = [pscustomobject]@{ profiles = @{} }  # FIX: log de erro mais amigável
  }

  if (-not $json.profiles) { $json | Add-Member -NotePropertyName profiles -NotePropertyValue (@{}) -Force }

  # Find an existing slot to re-use (by versionId or name or default fabric name)
  $existingKey = $null
  foreach($prop in $json.profiles.PSObject.Properties){
    $v = $prop.Value
    if ($v.lastVersionId -eq $VersionId -or $v.name -eq $ProfileName -or ($v.name -like "fabric-loader*")) {
      $existingKey = $prop.Name; break
    }
  }
  if (-not $existingKey) {
    $existingKey = [guid]::NewGuid().ToString('N')
    $json.profiles.$existingKey = [pscustomobject]@{}
  }

  $p = $json.profiles.$existingKey
  $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffK")
  $p.name          = $ProfileName
  $p.type          = 'custom'
  $p.lastVersionId = $VersionId
  if ($GameDirForProfile) {
    $p.gameDir = $GameDirForProfile
  } elseif ($p.PSObject.Properties.Name -contains 'gameDir') {
    $p.PSObject.Properties.Remove('gameDir') | Out-Null
  }
  $p.created = $now
  $p.lastUsed = $now

  $json | ConvertTo-Json -Depth 50 | Set-Content -Path $ProfilesFile -Encoding UTF8
  Write-Info ("Launcher profile set in: {0} (name: '{1}'; versionId: {2}{3})" -f `
    $ProfilesFile, $ProfileName, $VersionId, ($(if($GameDirForProfile){"; gameDir: $GameDirForProfile"} else {""})))
}

function Set-LauncherProfileAll(
  [string]$LauncherDir,
  [string]$ProfileName,
  [string]$VersionId,
  [string]$GameDirForProfile
){
  $files = Get-LauncherProfileFiles
  foreach($f in $files){
    try { Set-LauncherProfileCore -ProfilesFile $f -ProfileName $ProfileName -VersionId $VersionId -GameDirForProfile $GameDirForProfile }
    catch { Write-Warn ("Failed to update {0}: {1}" -f $f, $_.Exception.Message) }
  }
}

function Run-Packwiz([string]$Java,[string]$Dir,[string]$Url){
  Ensure-Dir $Dir
  $bootstrap = Join-Path $Dir 'packwiz-installer-bootstrap.jar'
  Write-Info "Downloading Packwiz bootstrap..."
  Download-File 'https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest/download/packwiz-installer-bootstrap.jar' $bootstrap

  Write-Info "Installing/updating pack from $Url into $Dir ..."
  Push-Location $Dir
  $exit = 0
  try {
    & $Java -jar $bootstrap -g $Url
    $exit = $LASTEXITCODE    # FIX: capturar código de saída
  } finally {
    Pop-Location
  }

  if ($exit -ne 0) {
    Write-Err "Packwiz installer exited with code $exit"
    throw "Packwiz install failed"
  }

  $modsDir = Join-Path $Dir 'mods'
  $mods = @(Get-ChildItem -Path $modsDir -Filter *.jar -ErrorAction SilentlyContinue)
  if ($mods.Count -eq 0) {
    Write-Warn "No JARs found in $modsDir. If your pack is server-only or the URL is wrong, nothing will be downloaded for the client."
  } else {
    Write-Info ("Mods present: {0} file(s) in {1}" -f $mods.Count, $modsDir)
  }
}

# ===================== main =====================
try {
  $ProfileName = 'Bubus Modpack'
  $LauncherDir = Get-LauncherMinecraftDir
  $GameDir     = if ($Isolate) { "$env:APPDATA\.bubus-minecraft" } else { $LauncherDir }

  if ($VerboseLog) {
    Write-Info "Launcher .minecraft : $LauncherDir"
    Write-Info "Candidates         : $( (Get-LauncherCandidates) -join ', ' )"
  }
  Write-Info "Target game directory (mods/config): $GameDir"
  Ensure-Dir $GameDir

  $java = Get-JavaPath -LauncherDir $LauncherDir
  if (-not $java) {
    Write-Err "No Java found. Open the Minecraft Launcher once (so it downloads its runtime), then re-run."
    exit 1
  }
  if ($VerboseLog){ Write-Info "Using Java: $java" }

  if ($Clean) { Write-Info "Backing up and cleaning mods/config..."; Backup-And-Clean $GameDir }

  $fabricVersionIdA = "fabric-loader-$LoaderVersion-$McVersion"
  $fabricVersionIdB = "fabric-loader-$McVersion-$LoaderVersion"

  $verPathA = Join-Path $LauncherDir "versions\$fabricVersionIdA"  # FIX: evitar repetir Join-Path
  $verPathB = Join-Path $LauncherDir "versions\$fabricVersionIdB"

  # FIX: lógica melhor para UpdateOnly / install
  if (-not $UpdateOnly) {
    Install-Fabric -Java $java -LauncherDir $LauncherDir -MCV $McVersion -LoaderV $LoaderVersion
  } else {
    Write-Info "UpdateOnly: skipping Fabric installation (unless no Fabric version is found)."
  }

  # Tenta detectar a versão existente
  if     (Test-Path $verPathA) { $fabricVersionId = $fabricVersionIdA }
  elseif (Test-Path $verPathB) { $fabricVersionId = $fabricVersionIdB }
  else {
    if ($UpdateOnly) {
      Write-Warn "No Fabric version folder found for $McVersion / $LoaderVersion. Installing Fabric even though -UpdateOnly was specified..."
      Install-Fabric -Java $java -LauncherDir $LauncherDir -MCV $McVersion -LoaderV $LoaderVersion

      if     (Test-Path $verPathA) { $fabricVersionId = $fabricVersionIdA }
      elseif (Test-Path $verPathB) { $fabricVersionId = $fabricVersionIdB }
      else {
        Write-Err "Fabric version folder still not found after install."
        throw "Fabric install did not create expected version folders"
      }
    } else {
      Write-Err "Fabric version folder not found after installation."
      throw "Fabric install did not create expected version folders"
    }
  }

  $gameDirForProfile = if ($Isolate) { $GameDir } else { $null }
  Set-LauncherProfileAll -LauncherDir $LauncherDir -ProfileName $ProfileName -VersionId $fabricVersionId -GameDirForProfile $gameDirForProfile

  Run-Packwiz -Java $java -Dir $GameDir -Url $PackUrl

  Write-Host ""
  Write-Host "✅ All set!" -ForegroundColor Green
  Write-Host "Open the Minecraft Launcher → Installations → run '$ProfileName'."
  if ($Isolate) { Write-Host "Profile uses isolated Game Directory: $GameDir" -ForegroundColor Cyan }
} catch {
  Write-Err $_.Exception.Message
  if ($VerboseLog) { Write-Err $_.ScriptStackTrace }
  exit 1
}
