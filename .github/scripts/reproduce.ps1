<#
.SYNOPSIS
	Reproduces Constella's published measurements on your own machine and
	writes one report you can compare or submit.

.DESCRIPTION
	Runs, in a local Roblox Studio (headless, through the RunScript CLI):
	1. the benchmark suite against the pinned comparison libraries
	   (downloaded from GitHub at pinned commits, checked by SHA-256);
	2. the load test with real Studio clients (engine-measured traffic,
	   server time per tick, request checks);
	3. optionally a soak test (-SoakMinutes) and its control run.
	Everything goes into -Out: REPORT.md, the raw JSON and environment.json.

	Needs Windows, Roblox Studio (signed in), Python 3 and Rojo 7.4 (rokit
	install, or build/tools/rojo.exe). Each Studio client takes about 1.7 GB
	of memory, so pick -Clients for your machine.

.EXAMPLE
	powershell -ExecutionPolicy Bypass -File .github/scripts/reproduce.ps1
	powershell -ExecutionPolicy Bypass -File .github/scripts/reproduce.ps1 -Clients 8 -SoakMinutes 120
#>
param(
	[int]$Runs = 7,
	[int]$Clients = 4,
	[double]$SoakMinutes = 0,
	[string]$Out = ""
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $root
$stamp = Get-Date -Format "yyyyMMdd-HHmm"
if (-not $Out) { $Out = "build/reproduction/$stamp" }
New-Item -ItemType Directory -Path $Out -Force | Out-Null
$scripts = ".github/scripts"
function Invoke-Step([string]$label, [scriptblock]$body) {
	Write-Output "== $label"
	& $body
	if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "$label failed (exit $LASTEXITCODE)" }
}

# Environment ---------------------------------------------------------------
$studio = $env:ROBLOX_STUDIO_EXE
if (-not $studio) {
	$studio = Get-ChildItem "$env:LOCALAPPDATA/Roblox/Versions" -Filter RobloxStudioBeta.exe -Recurse |
		Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
$commit = (git rev-parse HEAD 2>$null)
$dirty = [bool](git status --porcelain 2>$null)
$cpu = Get-CimInstance Win32_Processor
$system = Get-CimInstance Win32_ComputerSystem
$environment = [ordered]@{
	Date = (Get-Date).ToString("o")
	Commit = $commit
	UncommittedChanges = $dirty
	Cpu = $cpu.Name.Trim()
	Cores = $cpu.NumberOfCores
	Threads = $cpu.NumberOfLogicalProcessors
	MemoryGB = [math]::Round($system.TotalPhysicalMemory / 1GB)
	Os = (Get-CimInstance Win32_OperatingSystem).Caption
	Studio = if ($studio) { (Get-Item $studio).VersionInfo.ProductVersion } else { $null }
	Runs = $Runs
	Clients = $Clients
	SoakMinutes = $SoakMinutes
}
$environment | ConvertTo-Json | Set-Content -LiteralPath "$Out/environment.json" -Encoding utf8

# 1. Benchmarks ---------------------------------------------------------------
Invoke-Step "Benchmarks ($Runs runs)" {
	python "$scripts/fetch_bench_libs.py"
	& "$scripts/studio_bench.ps1" -Runs $Runs -Out "$Out/benchmarks.md"
}

# 2. Load test with real clients ----------------------------------------------
Invoke-Step "Load test ($Clients real clients)" {
	& "$scripts/studio_load.ps1" -Clients $Clients -Out "$Out/load-$Clients.json"
	python "$scripts/load_report.py" "$Out/load-$Clients.json" | Set-Content -LiteralPath "$Out/load.md" -Encoding utf8
}

# 3. Soak (optional) ------------------------------------------------------------
if ($SoakMinutes -gt 0) {
	Invoke-Step "Soak ($SoakMinutes minutes) and control run" {
		& "$scripts/studio_load.ps1" -Mode Soak -Clients $Clients -Minutes $SoakMinutes -Out "$Out/soak.json"
		& "$scripts/studio_load.ps1" -Mode Soak -Clients $Clients -Minutes ([math]::Max(10, $SoakMinutes / 2)) -NoWorkload -Out "$Out/soak-control.json"
		$soak = python "$scripts/load_report.py" --soak "$Out/soak.json"
		$control = python "$scripts/load_report.py" --soak "$Out/soak-control.json"
		$global:LASTEXITCODE = 0 # a GROWTH verdict is a result, not a script failure
		(@("### Soak") + $soak + @("", "### Control (no Constella work)") + $control) -join "`n" |
			Set-Content -LiteralPath "$Out/soak.md" -Encoding utf8
	}
}

# Report ------------------------------------------------------------------------
$lines = @(
	"# Constella reproduction report",
	"",
	"| | |",
	"| --- | --- |"
)
foreach ($key in $environment.Keys) { $lines += "| $key | $($environment[$key]) |" }
$lines += @("", "## Benchmarks", "", (Get-Content -LiteralPath "$Out/benchmarks.md" -Raw))
$lines += @("", "## Real clients", "", (Get-Content -LiteralPath "$Out/load.md" -Raw))
if (Test-Path -LiteralPath "$Out/soak.md") { $lines += @("", "## Soak", "", (Get-Content -LiteralPath "$Out/soak.md" -Raw)) }
$lines -join "`n" | Set-Content -LiteralPath "$Out/REPORT.md" -Encoding utf8
Write-Output ""
Write-Output "Done: $Out/REPORT.md"
Write-Output "To submit it, open a 'Benchmark result' issue on GitHub and attach REPORT.md and the JSON files."
