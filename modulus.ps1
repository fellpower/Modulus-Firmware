$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot

function Select-Menu {
    param(
        [string]$Title,
        [string[]]$Items
    )

    Write-Host ""
    Write-Host "=============================="
    Write-Host $Title
    Write-Host "=============================="
    Write-Host ""

    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "[$($i + 1)] $($Items[$i])"
    }

    Write-Host "[0] Back / Exit"
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Select"
        $number = 0

        if ([int]::TryParse($choice, [ref]$number)) {
            if ($number -ge 0 -and $number -le $Items.Count) {
                return $number
            }
        }

        Write-Host "Invalid selection."
    }
}

function Get-SystemComPortNames {
    [System.IO.Ports.SerialPort]::GetPortNames()
}

function Get-ModulusComPorts {
    # Win32_SerialPort alone misses some USB serial drivers (including CH340).
    # Prefer present Plug-and-Play devices, then merge the other Windows sources.
    $byPort = @{}
    function Add-Port {
        param([string]$Port, [string]$Name, [string]$DeviceId)
        if ($Port -notmatch '^COM\d+$') { return }
        $Port = $Port.ToUpperInvariant()
        if (-not $byPort.ContainsKey($Port)) {
            $byPort[$Port] = [PSCustomObject]@{
                Port = $Port
                Name = $(if ($Name) { $Name } else { 'Serial port' })
                PNPDeviceID = $DeviceId
                IsEspressif = $DeviceId -match 'VID_303A'
            }
        } elseif ($DeviceId -match 'VID_303A') {
            $byPort[$Port].IsEspressif = $true
        }
    }

    try {
        $devices = @(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction Stop)
        foreach ($device in $devices) {
            if ($device.FriendlyName -match '\((COM\d+)\)\s*$') {
                Add-Port $Matches[1] $device.FriendlyName $device.InstanceId
            }
        }
    } catch {
        Write-Verbose "Plug-and-Play port query unavailable: $($_.Exception.Message)"
        # Also works when the PnpDevice PowerShell module is not installed.
        try {
            $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass = 'Ports' AND Present = TRUE" -ErrorAction Stop)
            foreach ($device in $devices) {
                if ($device.Name -match '\((COM\d+)\)\s*$') {
                    Add-Port $Matches[1] $device.Name $device.PNPDeviceID
                }
            }
        } catch {
            Write-Verbose "CIM Plug-and-Play query unavailable: $($_.Exception.Message)"
        }
    }

    try {
        foreach ($device in @(Get-CimInstance -ClassName Win32_SerialPort -ErrorAction Stop)) {
            Add-Port $device.DeviceID $device.Name $device.PNPDeviceID
        }
    } catch {
        Write-Verbose "Legacy serial port query unavailable: $($_.Exception.Message)"
    }

    try {
        foreach ($portName in @(Get-SystemComPortNames)) {
            Add-Port $portName '' ''
        }
    } catch {
        Write-Verbose "System serial port query unavailable: $($_.Exception.Message)"
    }

    $byPort.Values | Sort-Object { [int]($_.Port.Substring(3)) }
}

function Select-ComPort {

    $ports = @(Get-ModulusComPorts)

    if ($ports.Count -eq 0) {
        throw "No COM ports found."
    }

    Write-Host ""
    Write-Host "Available COM ports:"
    Write-Host ""

    for ($i = 0; $i -lt $ports.Count; $i++) {

        $tag = ""

        if ($ports[$i].IsEspressif) {
            $tag = " [ESPRESSIF]"
        }

        Write-Host "[$($i + 1)] $($ports[$i].Port)  $($ports[$i].Name)$tag"
    }

    Write-Host ""

    while ($true) {
        $choice = Read-Host "Select COM port"
        $number = 0

        if ([int]::TryParse($choice, [ref]$number)) {
            if ($number -ge 1 -and $number -le $ports.Count) {
                return $ports[$number - 1].Port
            }
        }

        Write-Host "Invalid selection."
    }
}

function Ensure-Idf {

    if (-not $env:IDF_PATH) {
        $env:IDF_PATH = "C:\Espressif\v6.0.1\esp-idf"
    }

    $export = Join-Path $env:IDF_PATH "export.ps1"

    if (-not (Test-Path $export)) {
        throw "ESP-IDF not found: $export"
    }

    & $export | Out-Null
}

function Flash-ExistingBuild {
    param(
        [string]$ProjectPath,
        [string]$Chip
    )

    $build = Join-Path $ProjectPath "build"
    $flashArgs = Join-Path $build "flash_args"

    if (-not (Test-Path $build)) {
        throw "No build directory found: $build"
    }

    if (-not (Test-Path $flashArgs)) {
        throw "flash_args not found. Build the project first."
    }

    $port = Select-ComPort

    Ensure-Idf

    Write-Host ""
    Write-Host "=============================="
    Write-Host "FLASH"
    Write-Host "=============================="
    Write-Host "Chip : $Chip"
    Write-Host "Port : $port"
    Write-Host "Build: $build"
    Write-Host ""

    Push-Location $build

    try {

        python -m esptool `
            --chip $Chip `
            -p $port `
            -b 460800 `
            --before default-reset `
            --after hard-reset `
            write-flash `
            "@flash_args"

        if ($LASTEXITCODE -ne 0) {
            throw "Flash failed."
        }
    }
    finally {
        Pop-Location
    }
}

function Build-S3 {

    Write-Host ""
    Write-Host "==> Building S3 / XIAO"

    & "$RepoRoot\scripts\build_s3_bridge.ps1" -Board xiao
}

function Build-Tab5 {

    Write-Host ""
    Write-Host "==> Building Tab5 / P4"

    & "$RepoRoot\scripts\build_tab5.ps1"
}

function Build-H2 {

    Write-Host ""
    Write-Host "==> Building NanoH2"

    Ensure-Idf

    $project = "$RepoRoot\firmware\nanoh2"

    Push-Location $project

    try {

        if (-not (Test-Path "sdkconfig")) {
            idf.py set-target esp32h2
        }

        idf.py build
    }
    finally {
        Pop-Location
    }
}

function Build-C6 {

    Write-Host ""
    Write-Host "==> Building Tab5 C6"

    & "$RepoRoot\scripts\build_tab5_c6_modulus.ps1"
}

function Build-ZigbeeNode {

    Write-Host ""
    Write-Host "==> Building Modulus Zigbee Node"

    Ensure-Idf
    $project = "$RepoRoot\firmware\modulus-zigbee-node"

    Push-Location $project
    try {
        if (-not (Test-Path "build-node")) {
            idf.py -B build-node set-target esp32c6
        }
        idf.py -B build-node build
    }
    finally {
        Pop-Location
    }
}

function Clean-Project {
    param(
        [string]$ProjectPath
    )

    Ensure-Idf

    Push-Location $ProjectPath

    try {
        idf.py fullclean
    }
    finally {
        Pop-Location
    }
}

function Monitor-Project {
    param(
        [string]$ProjectPath
    )

    $port = Select-ComPort

    Ensure-Idf

    Push-Location $ProjectPath

    try {
        idf.py -p $port monitor
    }
    finally {
        Pop-Location
    }
}

while ($true) {

    $action = Select-Menu `
        "Modulus Firmware Tool" `
        @(
            "Build",
            "Flash",
            "Monitor",
            "Clean"
        )

    if ($action -eq 0) {
        break
    }

    $device = Select-Menu `
        "Select device" `
        @(
            "S3 / XIAO",
            "Tab5 / P4",
            "NanoH2",
            "Tab5 C6",
            "Modulus Zigbee Node / C6"
        )

    if ($device -eq 0) {
        continue
    }

    try {

        switch ($action) {

            1 {
                switch ($device) {
                    1 { Build-S3 }
                    2 { Build-Tab5 }
                    3 { Build-H2 }
                    4 { Build-C6 }
                    5 { Build-ZigbeeNode }
                }
            }

            2 {
                switch ($device) {

                    1 {
                        Flash-ExistingBuild `
                            "$RepoRoot\firmware\s3-bridge" `
                            "esp32s3"
                    }

                    2 {
                        Flash-ExistingBuild `
                            "$RepoRoot\firmware\tab5" `
                            "esp32p4"
                    }

                    3 {
                        Flash-ExistingBuild `
                            "$RepoRoot\firmware\nanoh2" `
                            "esp32h2"
                    }

                    4 {
                        $port = Select-ComPort
                        & "$RepoRoot\scripts\build_tab5_c6_modulus.ps1" -Action flash -Port $port
                    }

                    5 {
                        $port = Select-ComPort
                        Ensure-Idf
                        Push-Location "$RepoRoot\firmware\modulus-zigbee-node"
                        try { idf.py -B build-node -p $port flash }
                        finally { Pop-Location }
                    }
                }
            }

            3 {
                switch ($device) {

                    1 {
                        Monitor-Project "$RepoRoot\firmware\s3-bridge"
                    }

                    2 {
                        Monitor-Project "$RepoRoot\firmware\tab5"
                    }

                    3 {
                        Monitor-Project "$RepoRoot\firmware\nanoh2"
                    }

                    4 {
                        $port = Select-ComPort
                        & "$RepoRoot\scripts\build_tab5_c6_modulus.ps1" -Action monitor -Port $port
                    }

                    5 {
                        $port = Select-ComPort
                        Ensure-Idf
                        Push-Location "$RepoRoot\firmware\modulus-zigbee-node"
                        try { idf.py -B build-node -p $port monitor }
                        finally { Pop-Location }
                    }
                }
            }

            4 {
                switch ($device) {

                    1 {
                        Clean-Project "$RepoRoot\firmware\s3-bridge"
                    }

                    2 {
                        Clean-Project "$RepoRoot\firmware\tab5"
                    }

                    3 {
                        Clean-Project "$RepoRoot\firmware\nanoh2"
                    }

                    4 {
                        & "$RepoRoot\scripts\build_tab5_c6_modulus.ps1" -Action fullclean
                    }

                    5 {
                        Ensure-Idf
                        Push-Location "$RepoRoot\firmware\modulus-zigbee-node"
                        try { idf.py -B build-node fullclean }
                        finally { Pop-Location }
                    }
                }
            }
        }

        Write-Host ""
        Write-Host "==> Done."
    }
    catch {
        Write-Host ""
        Write-Host "ERROR: $($_.Exception.Message)"
    }

    Write-Host ""
    Read-Host "Press Enter to continue"
}
