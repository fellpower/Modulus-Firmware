# Merge existing release files only. Never invokes a firmware build or downloads files.
[CmdletBinding()]
param(
    [string]$Version = '3.1.3-ota',
    [string]$SourceRoot = '',
    [string]$OutRoot = '',
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RepoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$Tag = 'v' + ($Version -replace '^v', '')
if (-not $SourceRoot) { $SourceRoot = Join-Path $RepoRoot "dist/flash-images/$Tag-source" }
if (-not $OutRoot) { $OutRoot = Join-Path $RepoRoot "dist/flash-images/$Tag-full" }
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$OutRoot = [IO.Path]::GetFullPath($OutRoot)
$manifest = Get-Content -LiteralPath (Join-Path $SourceRoot 'MANIFEST.json') -Raw | ConvertFrom-Json
if ($manifest.release -ne $Tag) { throw 'Release manifest does not match Version.' }
$targets = @(
    @{ Name = 'tab5-p4'; Chip = 'esp32p4'; Output = 'tab5-p4' },
    @{ Name = 'tab5-c6'; Chip = 'esp32c6'; Output = 'tab5-c6' },
    @{ Name = 's3-xiao'; Chip = 'esp32s3'; Output = 'xiao-s3' }
)
# Validate every input before producing any output; never silently skip a target.
$plans = foreach ($target in $targets) {
    $configs = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -Filter flasher_args.json |
        Where-Object { $_.Directory.Name -eq $target.Name })
    if ($configs.Count -ne 1) { throw "Expected exactly one flasher_args.json for $($target.Name)." }
    $dir = $configs[0].Directory.FullName
    $config = Get-Content -LiteralPath $configs[0].FullName -Raw | ConvertFrom-Json
    if ($config.extra_esptool_args.chip -ne $target.Chip) { throw "Wrong chip for $($target.Name)." }
    $records = @($manifest.targets | Where-Object name -eq $target.Name)
    if ($records.Count -ne 1) { throw "Missing or duplicate manifest target $($target.Name)." }
    $entries = @($config.flash_files.PSObject.Properties)
    if ($entries.Count -ne @($records[0].flash_files).Count) { throw 'Flash file count differs from manifest.' }
    $end = 0L
    $mergeArgs = @()
    foreach ($entry in ($entries | Sort-Object { [Convert]::ToInt64($_.Name, 16) })) {
        $path = [IO.Path]::GetFullPath((Join-Path $dir $entry.Value))
        if (-not $path.StartsWith($dir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Input path escapes target folder.' }
        $record = @($records[0].flash_files | Where-Object file -eq $entry.Value)
        if ($record.Count -ne 1) { throw "File missing or duplicated in manifest: $path" }
        $file = Get-Item -LiteralPath $path
        if ($file.Length -ne $record[0].bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $record[0].sha256) { throw "Input checksum/size mismatch: $path" }
        $offset = [Convert]::ToInt64($entry.Name, 16)
        if ($offset -lt $end) { throw "Overlapping flash regions: $path" }
        $end = $offset + $file.Length
        $mergeArgs += @($entry.Name, $path)
    }
    if ($config.flash_settings.flash_size -notmatch '^(\d+)MB$') { throw 'Unsupported flash size.' }
    if ($end -gt ([long]$Matches[1] * 1MB)) { throw 'Image exceeds flash capacity.' }
    $output = Join-Path $OutRoot "modulus-$($target.Output)-full-$Tag.bin"
    if (Test-Path -LiteralPath $output) { throw "Output already exists: $output. Choose a fresh OutRoot." }
    @{ Target = $target; Config = $config; Args = $mergeArgs; Output = $output }
}
New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null
$sums = @()
$commands = @()
foreach ($plan in $plans) {
    # No flash-header overrides: retain the released bytes and fill gaps with 0xFF.
    $arguments = @('-m', 'esptool', '--chip', $plan.Target.Chip, 'merge-bin', '--format', 'raw', '--target-offset', '0x0', '-o', $plan.Output) + $plan.Args
    & $Python @arguments
    if ($LASTEXITCODE -ne 0) { throw "esptool merge failed for $($plan.Target.Name)." }
    $name = Split-Path -Leaf $plan.Output
    $hash = (Get-FileHash -LiteralPath $plan.Output -Algorithm SHA256).Hash.ToLowerInvariant()
    $sums += "$hash  $name"
    $settings = $plan.Config.flash_settings
    $commands += "python -m esptool --chip $($plan.Target.Chip) -p PORT write-flash --flash-mode $($settings.flash_mode) --flash-freq $($settings.flash_freq) --flash-size $($settings.flash_size) 0x0 $name"
}
$sums | Set-Content -LiteralPath (Join-Path $OutRoot 'SHA256SUMS-full.txt') -Encoding utf8
@(
    "# Full images: $Tag", '',
    "Source commit: $($manifest.source_commit). Inputs verified against MANIFEST.json. No rebuild.", '',
    'USB installation/recovery only. Replace PORT with the target serial port.',
    'Write exactly one BIN at 0x0. Never select a full image in a C6/S3 OTA menu.',
    'Gaps contain 0xFF; flashing can reset settings/NVS and OTA selection within the image range.', '',
    '```text'
) + $commands + @('```', '', 'Checksums: SHA256SUMS-full.txt') |
    Set-Content -LiteralPath (Join-Path $OutRoot 'FLASH-full.md') -Encoding utf8
Write-Host "Full images and checksums: $OutRoot"
