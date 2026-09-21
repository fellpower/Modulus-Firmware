# Shared ESP-IDF python-env pin. Dot-source before calling export.ps1.
#
# export.ps1 picks its venv from whichever `python` resolves first on PATH.
# On a box with Python 3.15 installed that lands on an env where IDF 6's
# pinned tree_sitter / bitarray have no wheels and cannot build from source,
# so activation dies at "Checking python dependencies ... FAILED".
# Pin the env idf_tools built against a supported interpreter instead.

function Set-IdfPythonEnv {
    # idf.py and a few component messages contain Unicode.  Set both knobs
    # before export.ps1 starts Python, even when a venv was already selected.
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    if (-not [string]::IsNullOrWhiteSpace($env:IDF_PYTHON_ENV_PATH)) { return }
    $envRoots = @(
        (Join-Path $env:USERPROFILE ".espressif\python_env"),
        "C:\Espressif\python_env"
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $pinned = Get-ChildItem -Path $envRoots -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '_py3\.(9|10|11|12|13|14)_env$' -and
            (Test-Path (Join-Path $_.FullName "Scripts\python.exe"))
        } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($pinned) {
        $env:IDF_PYTHON_ENV_PATH = $pinned.FullName
        Write-Host "==> IDF_PYTHON_ENV_PATH: $env:IDF_PYTHON_ENV_PATH"
    } else {
        Write-Warning "No ESP-IDF Python environment found under $($envRoots -join ', ')"
    }
}
