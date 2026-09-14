# Read only the port-related function definitions; never start the menu/flash.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modulus.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-SystemComPortNames', 'Get-ModulusComPorts', 'Select-ComPort')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing function: $name" }
    Invoke-Expression $definition.Extent.Text
}

function Get-PnpDevice {
    param([switch]$PresentOnly, $Class, $ErrorAction)
    if (-not $PresentOnly -or $Class -ne 'Ports') { throw 'Expected present Ports devices only' }
    if ($script:failPnp) { throw 'PnpDevice unavailable' }
    $script:pnpRows
}
function Get-CimInstance {
    param($ClassName, $Filter, $ErrorAction)
    if ($script:failCim) { throw 'CIM unavailable' }
    if ($ClassName -eq 'Win32_SerialPort') { $script:serialRows }
    elseif ($ClassName -eq 'Win32_PnPEntity') {
        if ($Filter -notmatch 'Present = TRUE') { throw 'Missing presence filter' }
        $script:cimPnpRows
    } else { throw "Unexpected CIM class: $ClassName" }
}
function Get-SystemComPortNames { $script:systemPorts }
function Assert-Ports([string]$Expected) {
    $actual = @((Get-ModulusComPorts).Port) -join ','
    if ($actual -ne $Expected) { throw "Expected '$Expected', got '$actual'" }
}
$script:failPnp = $false
$script:failCim = $false
$script:serialRows = @([PSCustomObject]@{ DeviceID='COM1'; Name='Communications Port (COM1)'; PNPDeviceID='ACPI\PNP0501' })
$script:pnpRows = @(
    [PSCustomObject]@{ FriendlyName='USB-SERIAL CH340 (COM5)'; InstanceId='USB\VID_1A86&PID_7523' },
    [PSCustomObject]@{ FriendlyName='USB JTAG/serial (COM14)'; InstanceId='USB\VID_303A&PID_1001' },
    [PSCustomObject]@{ FriendlyName='Printer (LPT1)'; InstanceId='ACPI\PRINTER' }
)
$script:cimPnpRows = @([PSCustomObject]@{ Name='USB-SERIAL CH340 (COM5)'; PNPDeviceID='USB\VID_1A86&PID_7523' })
$script:systemPorts = @('COM14','COM5','COM1','COM5')
Assert-Ports 'COM1,COM5,COM14'
$ports = @(Get-ModulusComPorts)
if ($ports[1].Name -ne 'USB-SERIAL CH340 (COM5)' -or $ports[1].IsEspressif -or -not $ports[2].IsEspressif) { throw 'Adapter names/vendor tags incorrect' }
function Read-Host { '2' }
if ((Select-ComPort) -ne 'COM5') { throw 'Menu did not select automatically discovered CH340' }
Write-Host 'PASS: CH340 missing from Win32_SerialPort is discovered and selectable; numeric order, deduplication and vendor tags.'
$script:failPnp = $true
$script:systemPorts = @()
Assert-Ports 'COM1,COM5'
Write-Host 'PASS: CIM PnP fallback without PnpDevice module.'
$script:failCim = $true
$script:systemPorts = @('COM5')
Assert-Ports 'COM5'
Write-Host 'PASS: system port fallback when both Windows queries fail.'
$script:systemPorts = @()
Assert-Ports ''
try { Select-ComPort; throw 'Expected no-ports error' }
catch { if ($_.Exception.Message -ne 'No COM ports found.') { throw } }
Write-Host 'PASS: no devices, no accidental flash.'
