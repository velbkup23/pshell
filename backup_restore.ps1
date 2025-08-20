#Requires -Module Az.Storage
#Requires -Module Az.RecoveryServices

<#
.SYNOPSIS
    Azure File Share Backup Restoration Tool
.DESCRIPTION
    PowerShell tool to manage restoration from Azure File Share backups with options to:
    - Choose recovery point
    - Restore specific files or entire file share
    - Select destination location
    - Handle overwrite/skip conflicts
.AUTHOR
    Azure Backup Management Tool
.VERSION
    1.0.0
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string]$VaultName
)

# Import required modules
function Initialize-AzureModules {
    $requiredModules = @('Az.Storage', 'Az.RecoveryServices', 'Az.Accounts')
    
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "Installing $module module..." -ForegroundColor Yellow
            Install-Module -Name $module -Force -AllowClobber -Scope CurrentUser
        }
        Import-Module $module -ErrorAction Stop
    }
}

# Connect to Azure
function Connect-AzureEnvironment {
    param(
        [string]$SubscriptionId
    )
    
    Write-Host "`n=== Azure Authentication ===" -ForegroundColor Cyan
    
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Host "Please login to Azure..." -ForegroundColor Yellow
            Connect-AzAccount
        }
        
        if ($SubscriptionId) {
            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        }
        
        $currentContext = Get-AzContext
        Write-Host "Connected to subscription: $($currentContext.Subscription.Name)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to connect to Azure: $_"
        return $false
    }
}

# Get Recovery Services Vault
function Get-RecoveryVault {
    param(
        [string]$ResourceGroupName,
        [string]$VaultName
    )
    
    Write-Host "`n=== Recovery Services Vault Selection ===" -ForegroundColor Cyan
    
    if ($VaultName -and $ResourceGroupName) {
        $vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName -ErrorAction SilentlyContinue
        if ($vault) {
            return $vault
        }
    }
    
    # List all vaults
    $vaults = Get-AzRecoveryServicesVault
    if ($vaults.Count -eq 0) {
        Write-Error "No Recovery Services Vaults found in the subscription"
        return $null
    }
    
    Write-Host "`nAvailable Recovery Services Vaults:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $vaults.Count; $i++) {
        Write-Host "$($i+1). $($vaults[$i].Name) (RG: $($vaults[$i].ResourceGroupName))"
    }
    
    do {
        $selection = Read-Host "`nSelect vault number"
        $index = [int]$selection - 1
    } while ($index -lt 0 -or $index -ge $vaults.Count)
    
    return $vaults[$index]
}

# Get protected file shares
function Get-ProtectedFileShares {
    param(
        [Microsoft.Azure.Commands.RecoveryServices.ARSVault]$Vault
    )
    
    Write-Host "`n=== Protected File Shares ===" -ForegroundColor Cyan
    
    Set-AzRecoveryServicesVaultContext -Vault $Vault
    
    $backupItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles
    
    if ($backupItems.Count -eq 0) {
        Write-Error "No protected file shares found in vault: $($Vault.Name)"
        return $null
    }
    
    Write-Host "`nProtected File Shares:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $backupItems.Count; $i++) {
        $item = $backupItems[$i]
        Write-Host "$($i+1). $($item.FriendlyName)"
        Write-Host "   Storage Account: $($item.ContainerName.Split(';')[2])" -ForegroundColor Gray
        Write-Host "   Protection Status: $($item.ProtectionStatus)" -ForegroundColor Gray
        Write-Host "   Last Backup: $($item.LastBackupTime)" -ForegroundColor Gray
    }
    
    do {
        $selection = Read-Host "`nSelect file share number"
        $index = [int]$selection - 1
    } while ($index -lt 0 -or $index -ge $backupItems.Count)
    
    return $backupItems[$index]
}

# Get recovery points
function Get-RecoveryPoints {
    param(
        [Microsoft.Azure.Commands.RecoveryServices.Models.PSAzureRmRecoveryServicesBackupItem]$BackupItem
    )
    
    Write-Host "`n=== Recovery Points ===" -ForegroundColor Cyan
    Write-Host "Fetching recovery points..." -ForegroundColor Yellow
    
    $endDate = Get-Date
    $startDate = $endDate.AddDays(-30)
    
    $recoveryPoints = Get-AzRecoveryServicesBackupRecoveryPoint -Item $BackupItem -StartDate $startDate -EndDate $endDate
    
    if ($recoveryPoints.Count -eq 0) {
        Write-Error "No recovery points found for the selected file share"
        return $null
    }
    
    Write-Host "`nAvailable Recovery Points:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $recoveryPoints.Count; $i++) {
        $rp = $recoveryPoints[$i]
        Write-Host "$($i+1). Recovery Time: $($rp.RecoveryPointTime)"
        Write-Host "   Recovery Point Type: $($rp.RecoveryPointType)" -ForegroundColor Gray
        Write-Host "   Recovery Point ID: $($rp.RecoveryPointId.Split('/')[(-1)])" -ForegroundColor Gray
    }
    
    do {
        $selection = Read-Host "`nSelect recovery point number"
        $index = [int]$selection - 1
    } while ($index -lt 0 -or $index -ge $recoveryPoints.Count)
    
    return $recoveryPoints[$index]
}

# Select restore type
function Get-RestoreType {
    Write-Host "`n=== Restore Type Selection ===" -ForegroundColor Cyan
    Write-Host "1. Restore entire file share"
    Write-Host "2. Restore specific files/folders"
    
    do {
        $selection = Read-Host "`nSelect restore type (1 or 2)"
    } while ($selection -ne "1" -and $selection -ne "2")
    
    return $selection
}

# Get files to restore
function Get-FilesToRestore {
    param(
        [Microsoft.Azure.Commands.RecoveryServices.Models.PSAzureRmRecoveryServicesBackupRecoveryPoint]$RecoveryPoint,
        [Microsoft.Azure.Commands.RecoveryServices.Models.PSAzureRmRecoveryServicesBackupItem]$BackupItem
    )
    
    Write-Host "`n=== File Selection ===" -ForegroundColor Cyan
    
    $files = @()
    $continue = $true
    
    Write-Host "Enter file/folder paths to restore (relative to file share root)" -ForegroundColor Yellow
    Write-Host "Example: folder1/file.txt or folder1/*" -ForegroundColor Gray
    Write-Host "Press Enter with empty input when done" -ForegroundColor Gray
    
    while ($continue) {
        $path = Read-Host "`nFile/Folder path"
        if ([string]::IsNullOrWhiteSpace($path)) {
            if ($files.Count -eq 0) {
                Write-Host "At least one file/folder must be specified" -ForegroundColor Red
            }
            else {
                $continue = $false
            }
        }
        else {
            $files += $path
            Write-Host "Added: $path" -ForegroundColor Green
        }
    }
    
    return $files
}

# Get restore destination
function Get-RestoreDestination {
    Write-Host "`n=== Restore Destination ===" -ForegroundColor Cyan
    Write-Host "1. Original location (same file share)"
    Write-Host "2. Alternate location (different file share or storage account)"
    
    do {
        $selection = Read-Host "`nSelect destination (1 or 2)"
    } while ($selection -ne "1" -and $selection -ne "2")
    
    if ($selection -eq "2") {
        $destInfo = @{
            StorageAccountName = Read-Host "Enter destination storage account name"
            FileShareName = Read-Host "Enter destination file share name"
            TargetFolder = Read-Host "Enter target folder path (leave empty for root)"
        }
        return @{
            Type = "Alternate"
            Details = $destInfo
        }
    }
    
    return @{
        Type = "Original"
        Details = $null
    }
}

# Get conflict resolution strategy
function Get-ConflictResolution {
    Write-Host "`n=== Conflict Resolution ===" -ForegroundColor Cyan
    Write-Host "How should conflicts be handled?"
    Write-Host "1. Overwrite existing files"
    Write-Host "2. Skip existing files"
    
    do {
        $selection = Read-Host "`nSelect option (1 or 2)"
    } while ($selection -ne "1" -and $selection -ne "2")
    
    return $(if ($selection -eq "1") { "Overwrite" } else { "Skip" })
}

# Perform restore operation
function Start-FileShareRestore {
    param(
        [Microsoft.Azure.Commands.RecoveryServices.Models.PSAzureRmRecoveryServicesBackupItem]$BackupItem,
        [Microsoft.Azure.Commands.RecoveryServices.Models.PSAzureRmRecoveryServicesBackupRecoveryPoint]$RecoveryPoint,
        [string]$RestoreType,
        [array]$FilesToRestore,
        [hashtable]$Destination,
        [string]$ConflictResolution
    )
    
    Write-Host "`n=== Starting Restore Operation ===" -ForegroundColor Cyan
    
    try {
        $restoreRequest = @{
            RecoveryPoint = $RecoveryPoint
            ResolveConflict = $ConflictResolution
        }
        
        if ($RestoreType -eq "2") {
            # Specific files restore
            $restoreRequest['SourceFilePath'] = $FilesToRestore
            $restoreRequest['SourceFileType'] = "File"
        }
        
        if ($Destination.Type -eq "Alternate") {
            $restoreRequest['TargetStorageAccountName'] = $Destination.Details.StorageAccountName
            $restoreRequest['TargetFileShareName'] = $Destination.Details.FileShareName
            if (-not [string]::IsNullOrWhiteSpace($Destination.Details.TargetFolder)) {
                $restoreRequest['TargetFolder'] = $Destination.Details.TargetFolder
            }
        }
        
        Write-Host "Initiating restore job..." -ForegroundColor Yellow
        $restoreJob = Restore-AzRecoveryServicesBackupItem @restoreRequest
        
        Write-Host "Restore job initiated successfully!" -ForegroundColor Green
        Write-Host "Job ID: $($restoreJob.JobId)" -ForegroundColor Gray
        
        # Monitor job progress
        Monitor-RestoreJob -JobId $restoreJob.JobId
        
        return $restoreJob
    }
    catch {
        Write-Error "Failed to initiate restore: $_"
        return $null
    }
}

# Monitor restore job
function Monitor-RestoreJob {
    param(
        [string]$JobId
    )
    
    Write-Host "`nMonitoring restore job progress..." -ForegroundColor Cyan
    
    $completed = $false
    while (-not $completed) {
        $job = Get-AzRecoveryServicesBackupJob -JobId $JobId
        
        Write-Progress -Activity "Restore in Progress" -Status "$($job.Status)" -PercentComplete $(if ($job.Status -eq "InProgress") { 50 } else { 100 })
        
        switch ($job.Status) {
            "Completed" {
                Write-Host "`nRestore completed successfully!" -ForegroundColor Green
                $completed = $true
            }
            "Failed" {
                Write-Host "`nRestore failed!" -ForegroundColor Red
                Write-Host "Error: $($job.ErrorDetails)" -ForegroundColor Red
                $completed = $true
            }
            "Cancelled" {
                Write-Host "`nRestore was cancelled" -ForegroundColor Yellow
                $completed = $true
            }
            default {
                Start-Sleep -Seconds 10
            }
        }
    }
    
    # Display job details
    Write-Host "`nJob Details:" -ForegroundColor Cyan
    Write-Host "Status: $($job.Status)"
    Write-Host "Start Time: $($job.StartTime)"
    Write-Host "End Time: $($job.EndTime)"
    if ($job.Status -eq "Completed") {
        Write-Host "Duration: $($job.Duration)"
    }
}

# Main execution function
function Start-AzureFileShareRestore {
    Write-Host "==================================" -ForegroundColor Cyan
    Write-Host " Azure File Share Restore Tool" -ForegroundColor Cyan
    Write-Host "==================================" -ForegroundColor Cyan
    
    # Initialize modules
    Initialize-AzureModules
    
    # Connect to Azure
    if (-not (Connect-AzureEnvironment -SubscriptionId $SubscriptionId)) {
        return
    }
    
    # Get Recovery Vault
    $vault = Get-RecoveryVault -ResourceGroupName $ResourceGroupName -VaultName $VaultName
    if (-not $vault) {
        return
    }
    
    # Get protected file share
    $backupItem = Get-ProtectedFileShares -Vault $vault
    if (-not $backupItem) {
        return
    }
    
    # Get recovery point
    $recoveryPoint = Get-RecoveryPoints -BackupItem $backupItem
    if (-not $recoveryPoint) {
        return
    }
    
    # Get restore type
    $restoreType = Get-RestoreType
    
    # Get files to restore (if specific files)
    $filesToRestore = $null
    if ($restoreType -eq "2") {
        $filesToRestore = Get-FilesToRestore -RecoveryPoint $recoveryPoint -BackupItem $backupItem
    }
    
    # Get destination
    $destination = Get-RestoreDestination
    
    # Get conflict resolution
    $conflictResolution = Get-ConflictResolution
    
    # Display summary
    Write-Host "`n=== Restore Summary ===" -ForegroundColor Cyan
    Write-Host "File Share: $($backupItem.FriendlyName)"
    Write-Host "Recovery Point: $($recoveryPoint.RecoveryPointTime)"
    Write-Host "Restore Type: $(if ($restoreType -eq '1') { 'Full Share' } else { 'Specific Files' })"
    if ($filesToRestore) {
        Write-Host "Files to Restore:"
        $filesToRestore | ForEach-Object { Write-Host "  - $_" }
    }
    Write-Host "Destination: $($destination.Type)"
    if ($destination.Type -eq "Alternate") {
        Write-Host "  Storage Account: $($destination.Details.StorageAccountName)"
        Write-Host "  File Share: $($destination.Details.FileShareName)"
        if ($destination.Details.TargetFolder) {
            Write-Host "  Target Folder: $($destination.Details.TargetFolder)"
        }
    }
    Write-Host "Conflict Resolution: $conflictResolution"
    
    # Confirm restore
    $confirm = Read-Host "`nProceed with restore? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Restore cancelled by user" -ForegroundColor Yellow
        return
    }
    
    # Perform restore
    $restoreJob = Start-FileShareRestore -BackupItem $backupItem `
                                         -RecoveryPoint $recoveryPoint `
                                         -RestoreType $restoreType `
                                         -FilesToRestore $filesToRestore `
                                         -Destination $destination `
                                         -ConflictResolution $conflictResolution
    
    if ($restoreJob) {
        Write-Host "`n=== Restore Operation Complete ===" -ForegroundColor Green
        
        # Ask if user wants to export job details
        $export = Read-Host "`nExport job details to file? (Y/N)"
        if ($export -eq 'Y' -or $export -eq 'y') {
            $exportPath = Read-Host "Enter export file path (e.g., C:\temp\restore-job.json)"
            $restoreJob | ConvertTo-Json -Depth 10 | Out-File -FilePath $exportPath
            Write-Host "Job details exported to: $exportPath" -ForegroundColor Green
        }
    }
}

# Script entry point
if ($MyInvocation.InvocationName -ne '.') {
    Start-AzureFileShareRestore
}
