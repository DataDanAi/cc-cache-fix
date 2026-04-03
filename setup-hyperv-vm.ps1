#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates a Hyper-V VM pre-configured for the Claude Code Cache Fix toolkit.

.DESCRIPTION
    Downloads Ubuntu 24.04 LTS cloud image, creates a Hyper-V Gen2 VM,
    provisions it with cloud-init (Node.js 20, Python 3, npm, Git),
    clones this repo, and runs the installer automatically.

.PARAMETER VMName
    Name of the VM (default: cc-cache-fix)

.PARAMETER CPUs
    Number of virtual CPUs (default: 4)

.PARAMETER MemoryGB
    Memory in GB (default: 4)

.PARAMETER DiskGB
    Disk size in GB (default: 30)

.PARAMETER VMPath
    Directory to store VM files (default: C:\HyperV\cc-cache-fix)

.PARAMETER Username
    VM login username (default: dev)

.PARAMETER Password
    VM login password (default: CacheFix2026!)

.EXAMPLE
    .\setup-hyperv-vm.ps1
    .\setup-hyperv-vm.ps1 -VMName "my-cc-vm" -CPUs 8 -MemoryGB 8
#>

param(
    [string]$VMName     = "cc-cache-fix",
    [int]$CPUs          = 4,
    [int]$MemoryGB      = 4,
    [int]$DiskGB        = 30,
    [string]$VMPath     = "C:\HyperV\cc-cache-fix",
    [string]$Username   = "dev",
    [string]$Password   = "CacheFix2026!"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ImageURL   = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
$ImageFile  = Join-Path $VMPath "ubuntu-24.04-cloudimg.img"
$VhdxFile   = Join-Path $VMPath "$VMName.vhdx"
$CloudInitISO = Join-Path $VMPath "cloud-init.iso"
$SwitchName = "cc-cache-fix-switch"

# ── Preflight checks ───────────────────────────────────────────────

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Hyper-V VM Setup: cc-cache-fix"        -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check Hyper-V is enabled
if (-not (Get-Command "New-VM" -ErrorAction SilentlyContinue)) {
    Write-Host "[!] Hyper-V is not enabled. Enable it first:" -ForegroundColor Red
    Write-Host "    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" -ForegroundColor Yellow
    exit 1
}

# Check if VM already exists
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "[!] VM '$VMName' already exists. Remove it first or choose a different name:" -ForegroundColor Red
    Write-Host "    Stop-VM -Name $VMName -Force; Remove-VM -Name $VMName -Force" -ForegroundColor Yellow
    exit 1
}

# Check for qemu-img (needed to convert cloud image)
$qemuImg = Get-Command "qemu-img" -ErrorAction SilentlyContinue
if (-not $qemuImg) {
    # Try common install locations
    $candidates = @(
        "C:\Program Files\qemu\qemu-img.exe",
        "C:\Program Files (x86)\qemu\qemu-img.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $qemuImg = $c; break }
    }
    if (-not $qemuImg) {
        Write-Host "[!] qemu-img not found. Install QEMU for Windows:" -ForegroundColor Red
        Write-Host "    winget install SoftwareFreedomConservancy.QEMU" -ForegroundColor Yellow
        Write-Host "    -- or download from https://qemu.weilnetz.de/w64/" -ForegroundColor Yellow
        exit 1
    }
}
$qemuImgPath = if ($qemuImg -is [string]) { $qemuImg } else { $qemuImg.Source }

# ── Create output directory ─────────────────────────────────────────

New-Item -ItemType Directory -Path $VMPath -Force | Out-Null
Write-Host "[1/7] Directory ready: $VMPath"

# ── Download Ubuntu cloud image ─────────────────────────────────────

if (-not (Test-Path $ImageFile)) {
    Write-Host "[2/7] Downloading Ubuntu 24.04 cloud image (~600 MB)..."
    $ProgressPreference = 'SilentlyContinue'   # speed up Invoke-WebRequest
    Invoke-WebRequest -Uri $ImageURL -OutFile $ImageFile -UseBasicParsing
    $ProgressPreference = 'Continue'
    Write-Host "      Downloaded to $ImageFile"
} else {
    Write-Host "[2/7] Cloud image already downloaded"
}

# ── Convert IMG -> VHDX and resize ──────────────────────────────────

if (-not (Test-Path $VhdxFile)) {
    Write-Host "[3/7] Converting to VHDX and resizing to ${DiskGB}GB..."
    & $qemuImgPath convert -f qcow2 -O vhdx -o subformat=dynamic $ImageFile $VhdxFile
    Resize-VHD -Path $VhdxFile -SizeBytes ($DiskGB * 1GB)
    Write-Host "      Created $VhdxFile"
} else {
    Write-Host "[3/7] VHDX already exists"
}

# ── Build cloud-init ISO ────────────────────────────────────────────

Write-Host "[4/7] Building cloud-init ISO..."

$ciDir = Join-Path $VMPath "cloud-init-data"
New-Item -ItemType Directory -Path $ciDir -Force | Out-Null

# meta-data
$metaData = @"
instance-id: $VMName
local-hostname: $VMName
"@
Set-Content -Path (Join-Path $ciDir "meta-data") -Value $metaData -NoNewline

# user-data with full provisioning
$userData = @"
#cloud-config
hostname: $VMName
manage_etc_hosts: true

users:
  - name: $Username
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "$Password"
    groups: [sudo, docker]

ssh_pwauth: true

package_update: true
package_upgrade: true

packages:
  - git
  - curl
  - wget
  - build-essential
  - python3
  - python3-pip
  - python3-venv
  - jq
  - unzip
  - ca-certificates
  - gnupg

runcmd:
  # Install Node.js 20 LTS via NodeSource
  - curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  - apt-get install -y nodejs
  # Verify installs
  - node --version > /var/log/provision-node.log 2>&1
  - npm --version >> /var/log/provision-node.log 2>&1
  - python3 --version > /var/log/provision-python.log 2>&1
  # Clone the repo
  - su - $Username -c "git clone https://github.com/datadanai/cc-cache-fix.git /home/$Username/cc-cache-fix"
  # Run the installer
  - su - $Username -c "cd /home/$Username/cc-cache-fix && bash install.sh" > /var/log/cc-install.log 2>&1
  # Add ~/.local/bin to PATH permanently
  - su - $Username -c 'echo "export PATH=\$HOME/.local/bin:\$PATH" >> /home/$Username/.bashrc'
  # Signal provisioning complete
  - touch /var/log/cloud-init-complete
  - echo "=== Provisioning complete ===" >> /var/log/provision-node.log

final_message: "Cloud-init provisioning finished at \$UPTIME seconds."
"@
Set-Content -Path (Join-Path $ciDir "user-data") -Value $userData -NoNewline

# Create ISO using oscdimg (ships with Windows ADK) or mkisofs
$oscdimg = Get-Command "oscdimg" -ErrorAction SilentlyContinue
if ($oscdimg) {
    & oscdimg -j2 -lcidata $ciDir $CloudInitISO
} else {
    # Fallback: use PowerShell to create a minimal ISO
    # We'll use a small .NET approach
    Write-Host "      oscdimg not found, building ISO via PowerShell..."
    $isoScript = @'
# Minimal ISO 9660 builder for cloud-init (label: cidata)
param([string]$SourceDir, [string]$OutputISO)

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;

public class SimpleISO {
    public static void Create(string sourceDir, string outputPath, string label) {
        var files = Directory.GetFiles(sourceDir);
        using (var fs = new FileStream(outputPath, FileMode.Create)) {
            var bw = new BinaryWriter(fs);

            // System area (32768 bytes of zeros)
            bw.Write(new byte[32768]);

            // Primary Volume Descriptor
            var pvd = new byte[2048];
            pvd[0] = 1; // type
            Encoding.ASCII.GetBytes("CD001", 0, 5, pvd, 1); // id
            pvd[6] = 1; // version
            // system id (unused)
            var volId = label.PadRight(32).Substring(0, 32);
            Encoding.ASCII.GetBytes(volId, 0, 32, pvd, 40);

            // Calculate sectors needed
            int dirSector = 18;
            int dataSector = dirSector + 1;
            int totalSectors = dataSector;

            // Read all file contents
            var fileEntries = new System.Collections.Generic.List<Tuple<string, byte[]>>();
            foreach (var f in files) {
                var content = File.ReadAllBytes(f);
                fileEntries.Add(Tuple.Create(Path.GetFileName(f).ToUpper(), content));
                totalSectors += (content.Length + 2047) / 2048;
            }

            // Volume space size (both-endian)
            WriteBothEndian32(pvd, 80, totalSectors);
            // Set size = 1
            WriteBothEndian16(pvd, 120, 1);
            // Logical block size = 2048
            WriteBothEndian16(pvd, 128, 2048);

            // Root directory record at offset 156
            var rootRec = new byte[34];
            rootRec[0] = 34;
            WriteBothEndian32(rootRec, 2, dirSector);
            WriteBothEndian32(rootRec, 10, 2048);
            rootRec[25] = 2; // flags: directory
            rootRec[28] = 1;
            rootRec[32] = 1;
            rootRec[33] = 0;
            Array.Copy(rootRec, 0, pvd, 156, 34);

            pvd[881] = 1; // file structure version
            bw.Write(pvd);

            // Volume Descriptor Set Terminator
            var term = new byte[2048];
            term[0] = 255;
            Encoding.ASCII.GetBytes("CD001", 0, 5, term, 1);
            term[6] = 1;
            bw.Write(term);

            // Pad to dir sector
            while (fs.Position < dirSector * 2048)
                bw.Write(new byte[2048]);

            // Directory records
            var dirData = new MemoryStream();
            var dw = new BinaryWriter(dirData);

            // Self entry (.)
            WriteDirEntry(dw, dirSector, 2048, 0x02, new byte[]{0});
            // Parent entry (..)
            WriteDirEntry(dw, dirSector, 2048, 0x02, new byte[]{1});

            int curSector = dataSector;
            foreach (var fe in fileEntries) {
                int sz = fe.Item2.Length;
                byte[] nameBytes = Encoding.ASCII.GetBytes(fe.Item1 + ";1");
                WriteDirEntry(dw, curSector, sz, 0x00, nameBytes);
                curSector += (sz + 2047) / 2048;
            }

            var dirBytes = dirData.ToArray();
            bw.Write(dirBytes);
            if (dirBytes.Length < 2048)
                bw.Write(new byte[2048 - dirBytes.Length]);

            // File data
            foreach (var fe in fileEntries) {
                bw.Write(fe.Item2);
                int pad = (2048 - (fe.Item2.Length % 2048)) % 2048;
                if (pad > 0) bw.Write(new byte[pad]);
            }
        }
    }

    static void WriteDirEntry(BinaryWriter w, int sector, int size, byte flags, byte[] name) {
        int len = 33 + name.Length;
        if (len % 2 != 0) len++;
        var rec = new byte[len];
        rec[0] = (byte)len;
        WriteBothEndian32(rec, 2, sector);
        WriteBothEndian32(rec, 10, size);
        rec[25] = flags;
        rec[28] = 1;
        rec[32] = (byte)name.Length;
        Array.Copy(name, 0, rec, 33, name.Length);
        w.Write(rec);
    }

    static void WriteBothEndian16(byte[] buf, int off, int val) {
        buf[off] = (byte)(val & 0xFF);
        buf[off+1] = (byte)((val >> 8) & 0xFF);
        buf[off+2] = (byte)((val >> 8) & 0xFF);
        buf[off+3] = (byte)(val & 0xFF);
    }

    static void WriteBothEndian32(byte[] buf, int off, int val) {
        buf[off]   = (byte)(val & 0xFF);
        buf[off+1] = (byte)((val >> 8) & 0xFF);
        buf[off+2] = (byte)((val >> 16) & 0xFF);
        buf[off+3] = (byte)((val >> 24) & 0xFF);
        buf[off+4] = (byte)((val >> 24) & 0xFF);
        buf[off+5] = (byte)((val >> 16) & 0xFF);
        buf[off+6] = (byte)((val >> 8) & 0xFF);
        buf[off+7] = (byte)(val & 0xFF);
    }
}
"@ -Language CSharp

[SimpleISO]::Create($SourceDir, $OutputISO, "cidata")
'@
    $isoScriptPath = Join-Path $VMPath "build-iso.ps1"
    Set-Content -Path $isoScriptPath -Value $isoScript
    & powershell -File $isoScriptPath -SourceDir $ciDir -OutputISO $CloudInitISO
}

Write-Host "      Cloud-init ISO created"

# ── Create virtual switch ───────────────────────────────────────────

Write-Host "[5/7] Configuring network..."

$existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $existingSwitch) {
    # Prefer Default Switch if it exists, otherwise create NAT switch
    $defaultSwitch = Get-VMSwitch -Name "Default Switch" -ErrorAction SilentlyContinue
    if ($defaultSwitch) {
        $SwitchName = "Default Switch"
        Write-Host "      Using Default Switch"
    } else {
        New-VMSwitch -SwitchName $SwitchName -SwitchType Internal | Out-Null
        # Set up NAT
        $ifIndex = (Get-NetAdapter | Where-Object Name -like "*$SwitchName*").ifIndex
        New-NetIPAddress -IPAddress 192.168.99.1 -PrefixLength 24 -InterfaceIndex $ifIndex | Out-Null
        New-NetNat -Name "${VMName}-nat" -InternalIPInterfaceAddressPrefix 192.168.99.0/24 -ErrorAction SilentlyContinue | Out-Null
        Write-Host "      Created NAT switch ($SwitchName)"
    }
} else {
    Write-Host "      Switch '$SwitchName' already exists"
}

# ── Create and configure VM ─────────────────────────────────────────

Write-Host "[6/7] Creating VM..."

$vm = New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -Generation 2 `
    -VHDPath $VhdxFile `
    -SwitchName $SwitchName `
    -Path $VMPath

Set-VM -Name $VMName `
    -ProcessorCount $CPUs `
    -DynamicMemory `
    -MemoryMinimumBytes 1GB `
    -MemoryMaximumBytes ($MemoryGB * 1GB) `
    -AutomaticStartAction Nothing `
    -AutomaticStopAction ShutDown `
    -CheckpointType Disabled

# Gen2 VM: disable Secure Boot for Ubuntu cloud image
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

# Attach cloud-init ISO
Add-VMDvdDrive -VMName $VMName -Path $CloudInitISO

# Set boot order: hard drive first
$bootHD = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
Set-VMFirmware -VMName $VMName -FirstBootDevice $bootHD

# Enable guest services for file copy
Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"

Write-Host "      VM created: $CPUs vCPUs, ${MemoryGB}GB RAM, ${DiskGB}GB disk"

# ── Start VM ────────────────────────────────────────────────────────

Write-Host "[7/7] Starting VM..."
Start-VM -Name $VMName

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  VM '$VMName' is booting!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Cloud-init will automatically install:" -ForegroundColor Yellow
Write-Host "  - Node.js 20 LTS + npm"
Write-Host "  - Python 3 + pip"
Write-Host "  - Git, curl, build-essential"
Write-Host "  - cc-cache-fix repo (cloned + installer run)"
Write-Host ""
Write-Host "Login credentials:" -ForegroundColor Yellow
Write-Host "  Username: $Username"
Write-Host "  Password: $Password"
Write-Host ""
Write-Host "Connect via:" -ForegroundColor Yellow
Write-Host "  vmconnect localhost $VMName"
Write-Host ""
Write-Host "Or find the VM's IP and SSH in:" -ForegroundColor Yellow
Write-Host "  ssh ${Username}@<VM-IP>"
Write-Host ""
Write-Host "Check provisioning status inside the VM:" -ForegroundColor Yellow
Write-Host "  cloud-init status --wait"
Write-Host "  cat /var/log/provision-node.log"
Write-Host "  cat /var/log/cc-install.log"
Write-Host ""
Write-Host "Once provisioned, run:" -ForegroundColor Yellow
Write-Host "  cd ~/cc-cache-fix"
Write-Host "  claude-patched --version"
Write-Host "  python3 test_cache.py claude-patched --timeout 240 --debug-transcript"
Write-Host ""
Write-Host "To get the VM IP address (run from host):" -ForegroundColor Yellow
Write-Host "  (Get-VMNetworkAdapter -VMName $VMName).IPAddresses"
