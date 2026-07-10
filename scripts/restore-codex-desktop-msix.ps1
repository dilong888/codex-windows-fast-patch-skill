[CmdletBinding()]
param(
  [string]$MsixPath = (Join-Path $env:TEMP 'codex-remote-control-26.707-route-install-3\OpenAI.Codex_26.707.3748.0_remote-control-patched.msix'),
  [string]$StatusPath = (Join-Path $env:LOCALAPPDATA 'CodexDesktopRecovery\status.json'),
  [switch]$TrustMachineCertificate,
  [switch]$Install,
  [switch]$Launch
)

$ErrorActionPreference = 'Stop'

function Write-RecoveryStatus {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('READY_FOR_INSTALL', 'READY', 'NEEDS_ACTION', 'FAILED')][string]$State,
    [Parameter(Mandatory = $true)][string]$Message,
    [hashtable]$Details = @{}
  )

  $parent = Split-Path -Parent $StatusPath
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $payload = [ordered]@{
    state = $State
    timestamp = (Get-Date).ToString('o')
    message = $Message
    details = $Details
  }
  $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
  Write-Host "${State}: $Message"
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MsixPublisher {
  param([Parameter(Mandatory = $true)][string]$Path)

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $archive.GetEntry('AppxManifest.xml')
    if (-not $entry) {
      throw 'AppxManifest.xml was not found in the MSIX package.'
    }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      [xml]$manifest = $reader.ReadToEnd()
    } finally {
      $reader.Dispose()
    }
    return $manifest.Package.Identity.Publisher
  } finally {
    $archive.Dispose()
  }
}

function Get-CodeSigningCertificate {
  param([Parameter(Mandatory = $true)][string]$Publisher)

  $codeSigningOid = '1.3.6.1.5.5.7.3.3'
  return Get-ChildItem Cert:\CurrentUser\My -ErrorAction Stop |
    Where-Object {
      $_.Subject -eq $Publisher -and
      $_.HasPrivateKey -and
      $_.NotAfter -gt (Get-Date) -and
      (@($_.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId.ToString() }) -contains $codeSigningOid)
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
}

function Test-MachineCertificateTrust {
  param([Parameter(Mandatory = $true)][string]$Thumbprint)

  $inRoot = [bool](Get-ChildItem Cert:\LocalMachine\Root -ErrorAction Stop | Where-Object Thumbprint -eq $Thumbprint)
  $inTrustedPeople = [bool](Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction Stop | Where-Object Thumbprint -eq $Thumbprint)
  return @{ Root = $inRoot; TrustedPeople = $inTrustedPeople; Trusted = ($inRoot -and $inTrustedPeople) }
}

function Add-MachineCertificateTrust {
  param([Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

  if (-not (Test-IsAdministrator)) {
    throw 'Machine certificate trust requires an elevated PowerShell window.'
  }
  foreach ($storeName in @(
    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
    [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPeople
  )) {
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
      $storeName,
      [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    try {
      $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
      $present = $store.Certificates | Where-Object Thumbprint -eq $Certificate.Thumbprint
      if (-not $present) {
        $store.Add($Certificate)
      }
    } finally {
      $store.Close()
    }
  }
}

function Start-CodexDesktopApplication {
  param([Parameter(Mandatory = $true)]$Package)

  $manifest = Get-AppxPackageManifest -Package $Package.PackageFullName -ErrorAction Stop
  $application = $manifest.Package.Applications.Application | Select-Object -First 1
  if (-not $application -or [string]::IsNullOrWhiteSpace($application.Id)) {
    throw 'No AppX application ID was found for the installed Codex Desktop package.'
  }
  $appUserModelId = "$($Package.PackageFamilyName)!$($application.Id)"
  Start-Process -FilePath explorer.exe -ArgumentList "shell:AppsFolder\\$appUserModelId" -ErrorAction Stop
  return $appUserModelId
}

try {
  if (-not (Test-Path -LiteralPath $MsixPath -PathType Leaf)) {
    Write-RecoveryStatus -State 'FAILED' -Message 'Patched MSIX package was not found.' -Details @{ msixPath = $MsixPath }
    exit 1
  }

  $publisher = Get-MsixPublisher -Path $MsixPath
  $certificate = Get-CodeSigningCertificate -Publisher $publisher
  if (-not $certificate) {
    Write-RecoveryStatus -State 'NEEDS_ACTION' -Message 'No valid current-user code-signing certificate matches the MSIX publisher.' -Details @{ publisher = $publisher; msixPath = $MsixPath }
    exit 2
  }

  if ($TrustMachineCertificate) {
    Add-MachineCertificateTrust -Certificate $certificate
  }

  $trust = Test-MachineCertificateTrust -Thumbprint $certificate.Thumbprint
  $details = @{
    msixPath = $MsixPath
    publisher = $publisher
    certificateThumbprint = $certificate.Thumbprint
    machineRootTrusted = $trust.Root
    machineTrustedPeopleTrusted = $trust.TrustedPeople
    desktopInstalled = [bool](Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
  }
  if (-not $trust.Trusted) {
    Write-RecoveryStatus -State 'NEEDS_ACTION' -Message 'The MSIX signing certificate is not trusted at machine scope. Run this script in an elevated PowerShell window with -TrustMachineCertificate, then rerun with -Install.' -Details $details
    exit 2
  }

  $existing = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($existing) {
    $details.installedPackage = $existing.PackageFullName
    $details.installLocation = $existing.InstallLocation
    if ($Launch) {
      $details.appUserModelId = Start-CodexDesktopApplication -Package $existing
      Write-RecoveryStatus -State 'READY' -Message 'Codex Desktop is already installed and was launched through its AppX entry point.' -Details $details
      exit 0
    }
    Write-RecoveryStatus -State 'NEEDS_ACTION' -Message 'Codex Desktop is already installed. This recovery script intentionally refuses to replace an existing package.' -Details $details
    exit 2
  }

  if (-not $Install) {
    Write-RecoveryStatus -State 'READY_FOR_INSTALL' -Message 'Preflight passed. No package was installed.' -Details $details
    exit 0
  }

  Add-AppxPackage -Path $MsixPath -ErrorAction Stop
  $installed = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Select-Object -First 1
  if (-not $installed -or -not $installed.InstallLocation) {
    throw 'Add-AppxPackage completed but OpenAI.Codex was not registered.'
  }

  $details.installedPackage = $installed.PackageFullName
  $details.installLocation = $installed.InstallLocation
  if ($Launch) {
    $details.appUserModelId = Start-CodexDesktopApplication -Package $installed
  }
  Write-RecoveryStatus -State 'READY' -Message 'Patched Codex Desktop package was installed successfully.' -Details $details
} catch {
  Write-RecoveryStatus -State 'FAILED' -Message $_.Exception.Message -Details @{ msixPath = $MsixPath }
  exit 1
}
