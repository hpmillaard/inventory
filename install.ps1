clear
If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { Start powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; exit }
$title = (gi $PSScriptRoot).Name
$host.ui.RawUI.WindowTitle = "Installing $title"

Function Log($Content) { Write-Host -f Green $content; ac $ENV:WINDIR\AppInstall.txt "$(Get-Date -UF '%a %d-%m-%G %X') $title - $content" }
trap { Log "ERROR: $($_.Exception.Message)"; continue }
Log "Installation started"

Log "Aanmaken share"
$dst = 'D:\Inventory'
$null = md $dst -EA 0

Log "Kopieren bestanden"
$copyList = @('Inventory.ps1', 'index.html', 'view-Inventory.ps1')
foreach ($f in $copyList) { cp "$PSScriptRoot\$f" $dst -Force -EA 0 }

Log "Share permissions instellen"
$dom = (Get-CimInstance Win32_ComputerSystem -EA 0).Domain
if ($dom -and $dom -ne $env:COMPUTERNAME) { $admins = "$dom\Administrators"; $dc = "$dom\Domain Computers" } else { $admins = 'BUILTIN\Administrators'; $dc = 'Domain Computers' }

$null = New-SmbShare -Name 'Inventory$' -Path $dst -Description 'Inventory share' -FullAccess 'BUILTIN\Administrators' -Change $dc -EA 0

Log "NTFS permissions instellen (icacls)"
$null = icacls $dst /grant "$($ENV:USERNAME):(OI)(CI)F" /C
$null = icacls $dst /grant "BUILTIN\Administrators:(OI)(CI)F" /C
$null = icacls $dst /grant "$($dc):(OI)(CI)M" /C
$null = icacls $dst /inheritance:r /C

Log "Share klaar: $dst (Inventory$). Kopieer voltooid. Zet GPO startup script naar \\$env:COMPUTERNAME\Inventory$\Inventory.ps1"

Log "Finished installation"
exit 0