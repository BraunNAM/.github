#Requires -Version 5.1
<#
.SYNOPSIS
    Generic puller for the shared "release sync" system: downloads a release artifact (and its
    published .sha256 checksum) from a per-app Azure Blob Storage container, verifies integrity,
    and stages it locally for a PDQ Deploy "Install" step to consume.

.DESCRIPTION
    This script is intentionally app-agnostic. Every onboarded app gets its own container in the
    shared stnamreleasesync storage account (see README.md next to this script for the full
    onboarding checklist and architecture). A PDQ package per app calls this same script with that
    app's own -StorageAccount/-Container/-BlobName/-OnePasswordItem values, so there is exactly one
    copy of the sync/verify logic to maintain no matter how many apps use it.

    Authentication uses a read-only, container-scoped SAS token tied to that container's "reader"
    stored access policy (no Entra app registration or Azure identity required on this machine).
    The token itself is never hard-coded in a PDQ package or script: it is resolved at run time
    from 1Password via 'op'/'op-skip', matching the pattern already used for this app's own
    Snowflake/GitHub secrets.

.PARAMETER StorageAccount
    Azure Storage account name hosting the shared release-sync containers, e.g. stnamreleasesync.

.PARAMETER Container
    The blob container dedicated to this app, e.g. eng-admin-diag-tool.

.PARAMETER BlobName
    The blob name to pull, e.g. EngAdminDiagTool-Prod.msi. A sibling "<BlobName>.sha256" blob
    (containing just the hex SHA-256 digest) must also exist in the same container; it is what
    the publish-release-to-blob.yml reusable workflow publishes alongside the artifact itself.

.PARAMETER DestinationPath
    Local path to stage the verified file at, e.g. C:\PDQStaging\EngAdminDiagTool\EngAdminDiagTool-Prod.msi.
    If a file already there has a matching hash, the download is skipped (no-op) and the existing
    file is left in place untouched.

.PARAMETER OnePasswordItem
    Title of the 1Password item holding the reader SAS token for this app's container.

.PARAMETER OnePasswordVault
    1Password vault containing that item. Defaults to svc-baa-applications.

.PARAMETER OnePasswordField
    Field name within the item holding the raw SAS query string (no leading '?'). Defaults to
    'credential' (the default field name for an "API Credential" category item).

.EXAMPLE
    .\Sync-ReleaseFromBlob.ps1 `
        -StorageAccount stnamreleasesync -Container eng-admin-diag-tool `
        -BlobName EngAdminDiagTool-Prod.msi `
        -DestinationPath C:\PDQStaging\EngAdminDiagTool\EngAdminDiagTool-Prod.msi `
        -OnePasswordItem eng-admin-diag-tool-pdq-reader-sas

    Run as the first step of a PDQ Deploy package; a subsequent "Install" step then runs
    msiexec against the staged -DestinationPath.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StorageAccount,
    [Parameter(Mandatory)][string]$Container,
    [Parameter(Mandatory)][string]$BlobName,
    [Parameter(Mandatory)][string]$DestinationPath,
    [Parameter(Mandatory)][string]$OnePasswordItem,
    [string]$OnePasswordVault = "svc-baa-applications",
    [string]$OnePasswordField = "credential"
)

$ErrorActionPreference = "Stop"

function Resolve-OpCommand {
    # Prefer op-skip (auto-signin wrapper for non-interactive shells) if present on PATH; this
    # script normally runs under PDQ Deploy's service account, which never sources $PROFILE.
    $opSkip = Get-Command op-skip -ErrorAction SilentlyContinue
    if ($opSkip) { return $opSkip.Source }

    $op = Get-Command op -ErrorAction SilentlyContinue
    if ($op) { return $op.Source }

    throw "Neither 'op-skip' nor 'op' was found on PATH. Install the 1Password CLI (and ideally op-skip) on this machine before running this script."
}

function Get-ReaderSasToken {
    param([string]$OpCommand, [string]$Vault, [string]$Item, [string]$Field)

    $sas = & $OpCommand item get $Item --vault $Vault --fields $Field --reveal 2>$null
    if (-not $sas) {
        throw "Could not resolve field '$Field' from 1Password item '$Item' in vault '$Vault'. Check the item exists and this machine's 1Password session/service-account token has read access to that vault."
    }
    return $sas.Trim()
}

function Get-RemoteText {
    param([string]$Url)
    # On Windows PowerShell 5.1, Invoke-WebRequest's .Content is a byte[] (not a string)
    # when the response's Content-Type isn't a recognized text MIME type - as is the case
    # for the .sha256 sidecar blob, which Azure serves as application/octet-stream. PowerShell
    # 7+ doesn't have this quirk, so handle both to keep this script PS 5.1-compatible for
    # PDQ Deploy servers that haven't been upgraded off Windows PowerShell.
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
    if ($response.Content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($response.Content).Trim()
    }
    return $response.Content.Trim()
}

$opCommand = Resolve-OpCommand
$sasToken = Get-ReaderSasToken -OpCommand $opCommand -Vault $OnePasswordVault -Item $OnePasswordItem -Field $OnePasswordField

$blobBaseUrl = "https://$StorageAccount.blob.core.windows.net/$Container/$BlobName"
$blobUrl = "$blobBaseUrl`?$sasToken"
$checksumUrl = "$blobBaseUrl.sha256`?$sasToken"

Write-Host "Checking for latest release: $Container/$BlobName"
$expectedHash = (Get-RemoteText -Url $checksumUrl).ToUpperInvariant()
if ($expectedHash -notmatch '^[0-9A-F]{64}$') {
    throw "Unexpected checksum content retrieved from $Container/$BlobName.sha256 (expected a 64-char hex SHA-256 digest)."
}

if (Test-Path $DestinationPath) {
    $currentHash = (Get-FileHash -Path $DestinationPath -Algorithm SHA256).Hash
    if ($currentHash -eq $expectedHash) {
        Write-Host "Already up to date (SHA-256 $expectedHash). Skipping download."
        exit 0
    }
}

$destDir = Split-Path -Parent $DestinationPath
if ($destDir -and -not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

$tempPath = "$DestinationPath.downloading"
try {
    Write-Host "Downloading new version to $DestinationPath ..."
    Invoke-WebRequest -Uri $blobUrl -OutFile $tempPath -UseBasicParsing

    $downloadedHash = (Get-FileHash -Path $tempPath -Algorithm SHA256).Hash
    if ($downloadedHash -ne $expectedHash) {
        throw "Checksum mismatch after download: expected $expectedHash but got $downloadedHash. Discarding download."
    }

    Move-Item -Path $tempPath -Destination $DestinationPath -Force
    Write-Host "Updated $DestinationPath (SHA-256 $expectedHash)."
}
finally {
    if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
}
