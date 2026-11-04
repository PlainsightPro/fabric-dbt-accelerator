<#
.SYNOPSIS
    One-shot setup of the Fabric side of the accelerator.

.DESCRIPTION
    Thin wrapper around scripts/bootstrap.py: finds an interpreter, forwards
    every argument. All the behaviour and the --help text live in the Python.

.EXAMPLE
    .\infra\bootstrap.ps1
    .\infra\bootstrap.ps1 --dry-run
    .\infra\bootstrap.ps1 --sp-mode existing --sp-id <appId>
#>

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootstrap = Join-Path $scriptDir 'scripts\bootstrap.py'

# The repo's venv first, so a machine where `python` is the Windows Store stub
# still works. bootstrap.py itself is stdlib-only and runs under either.
$venvPython = Join-Path (Split-Path -Parent $scriptDir) '.venv\Scripts\python.exe'

if (Test-Path $venvPython) {
    $python = $venvPython
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $python = 'python'
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $python = 'py'
} else {
    throw "No Python interpreter found. Install Python 3.11+ or create the venv: python -m venv .venv"
}

& $python $bootstrap @args
exit $LASTEXITCODE
