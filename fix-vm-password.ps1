#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Resets an expired password for a user on the cc-cache-fix Hyper-V VM.

.DESCRIPTION
    Connects to the VM via Hyper-V PowerShell Direct and resets the specified
    user's password, removes expiry, and unlocks the account.

.PARAMETER VMName
    Name of the VM (default: cc-cache-fix)

.PARAMETER TargetUser
    The VM user whose password needs resetting (default: tahir)

.PARAMETER NewPassword
    New password to set (default: CacheFix2026!)

.PARAMETER AdminUser
    VM admin user for PowerShell Direct login (default: dev)

.PARAMETER AdminPassword
    VM admin password (default: CacheFix2026!)

.EXAMPLE
    .\fix-vm-password.ps1
    .\fix-vm-password.ps1 -TargetUser tahir -NewPassword "MyNewPass123!"
#>

param(
    [string]$VMName       = "cc-cache-fix",
    [string]$TargetUser   = "tahir",
    [string]$NewPassword  = "CacheFix2026!",
    [string]$AdminUser    = "dev",
    [string]$AdminPassword = "CacheFix2026!"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  VM Password Fix: $TargetUser@$VMName" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check VM exists and is running
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "[!] VM '$VMName' not found." -ForegroundColor Red
    exit 1
}
if ($vm.State -ne "Running") {
    Write-Host "[*] VM is not running. Starting it..."
    Start-VM -Name $VMName
    Write-Host "[*] Waiting for VM to boot..."
    Start-Sleep -Seconds 30
}

# Get VM IP address
$vmIP = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1

if (-not $vmIP) {
    Write-Host "[!] Could not determine VM IP. Trying direct console approach..." -ForegroundColor Yellow
    Write-Host ""

    # Fallback: use Invoke-Command via PowerShell Direct (requires VM integration services)
    $secAdminPass = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($AdminUser, $secAdminPass)

    try {
        Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
            param($User, $Pass)

            # Check if user exists
            if (-not (id $User 2>/dev/null)) {
                # Create the user
                sudo useradd -m -s /bin/bash -G sudo $User
                Write-Output "[*] Created user: $User"
            }

            # Set password
            echo "${User}:${Pass}" | sudo chpasswd
            # Remove password expiry
            sudo chage -I -1 -m 0 -M 99999 -E -1 $User
            # Unlock account
            sudo passwd -u $User 2>/dev/null

            Write-Output "[*] Password reset and expiry removed for: $User"
            # Verify
            sudo chage -l $User
        } -ArgumentList $TargetUser, $NewPassword

        Write-Host ""
        Write-Host "Done!" -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "[!] PowerShell Direct failed: $_" -ForegroundColor Red
        Write-Host ""
    }
}

# SSH approach
Write-Host "[*] VM IP: $vmIP" -ForegroundColor Green
Write-Host "[*] Resetting password for '$TargetUser' via SSH..."
Write-Host ""

# Build the remote commands
$remoteScript = @"
# Create user if they don't exist
if ! id "$TargetUser" &>/dev/null; then
    sudo useradd -m -s /bin/bash -G sudo "$TargetUser"
    echo "[*] Created user: $TargetUser"
fi

# Reset password
echo "$($TargetUser):$($NewPassword)" | sudo chpasswd

# Remove password expiry entirely
sudo chage -I -1 -m 0 -M 99999 -E -1 "$TargetUser"

# Unlock account in case it was locked
sudo passwd -u "$TargetUser" 2>/dev/null

echo "[*] Password reset and expiry disabled for: $TargetUser"
sudo chage -l "$TargetUser"
"@

# Try SSH with sshpass if available, otherwise guide the user
$sshpass = Get-Command "sshpass" -ErrorAction SilentlyContinue
if ($sshpass) {
    $remoteScript | & sshpass -p $AdminPassword ssh -o StrictHostKeyChecking=no "${AdminUser}@${vmIP}" "bash -s"
} else {
    # Use ssh with password via stdin
    Write-Host "[*] Running fix commands via SSH..." -ForegroundColor Yellow
    Write-Host "    If prompted for password, enter: $AdminPassword" -ForegroundColor Yellow
    Write-Host ""
    $remoteScript | ssh -o StrictHostKeyChecking=no "${AdminUser}@${vmIP}" "bash -s"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Password fixed!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Tahir can now log in with:" -ForegroundColor Yellow
Write-Host "  ssh ${TargetUser}@${vmIP}"
Write-Host "  Password: $NewPassword"
Write-Host ""
Write-Host "Password expiry has been disabled for this account."
