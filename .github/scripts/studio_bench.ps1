<#
.SYNOPSIS
	Runs Constella's benchmark suite in a local Roblox Studio, headless.

.DESCRIPTION
	Builds -Project (see fetch_bench_libs.py, which writes it with the pinned
	comparison libraries and an optional baseline build), runs RunBenchmarks
	through Studio's RunScript CLI in Edit mode, and writes the Markdown
	report to -Out. With a baseline in the place, both builds are measured in
	the same session, alternating case by case.

.EXAMPLE
	python .github/scripts/fetch_bench_libs.py
	.github/scripts/studio_bench.ps1 -Runs 7

	.github/scripts/studio_bench.ps1 -Runs 9 -Groups Signal -Out build/signal-ab.md
#>
param(
	[int]$Runs = 7,
	[string[]]$Groups = @(),
	[string]$Project = "bench.generated.project.json",
	[string]$Out = "build/bench-report.md",
	[int]$TimeoutSeconds = 3600,
	[string]$StudioPath = $env:ROBLOX_STUDIO_EXE,
	[string]$Rojo = "build/tools/rojo.exe"
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $root
if (-not $StudioPath) {
	$StudioPath = Get-ChildItem "$env:LOCALAPPDATA/Roblox/Versions" -Filter RobloxStudioBeta.exe -Recurse |
		Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $StudioPath -or -not (Test-Path -LiteralPath $StudioPath)) { throw "Roblox Studio executable not found" }
if (-not (Get-Command $Rojo -ErrorAction SilentlyContinue)) { $Rojo = "rojo" }
if (-not (Test-Path -LiteralPath $Project)) { throw "$Project not found; run .github/scripts/fetch_bench_libs.py first" }

New-Item -ItemType Directory -Path build -Force | Out-Null
& $Rojo build $Project -o build/bench.rbxl
if ($LASTEXITCODE -ne 0) { throw "rojo build failed" }

$groupList = if ($Groups.Count -gt 0) { "{ " + (($Groups | ForEach-Object { "`"$_`"" }) -join ", ") + " }" } else { "nil" }
$runner = @"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local packages = ReplicatedStorage.Packages
local builds = { { Name = "this build", Module = packages.Constella } }
if packages:FindFirstChild("ConstellaBaseline") then
	table.insert(builds, { Name = "baseline", Module = packages.ConstellaBaseline })
end
local report = require(ServerStorage.ConstellaBenchmarks.RunBenchmarks)({ Runs = $Runs, Packages = builds, Groups = $groupList })
local size = 3000
for index = 1, math.ceil(#report / size) do
	print(("CONSTELLA_BENCH_MD %06d %s"):format(index, report:sub((index - 1) * size + 1, index * size)))
end
print("CONSTELLA_BENCH_DONE")
"@
$runnerPath = Join-Path $root "build/studio_bench_runner.luau"
[System.IO.File]::WriteAllText($runnerPath, $runner, (New-Object System.Text.UTF8Encoding $false))
$place = (Resolve-Path "build/bench.rbxl").Path
$log = Join-Path $root "build/bench-output.log"
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }

$arguments = @("--task", "RunScript", "--localPlaceFile", "`"$place`"", "--runScriptFile", "`"$runnerPath`"", "--outputFile", "`"$log`"", "--quitAfterExecution")
$started = Get-Date
$process = Start-Process -FilePath $StudioPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
try {
	$deadline = $started.AddSeconds($TimeoutSeconds)
	while (-not $process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; $process.Refresh() }
	if (-not $process.HasExited) { throw "Benchmarks timed out after $TimeoutSeconds seconds" }
} finally {
	if (-not $process.HasExited) { Stop-Process -Id $process.Id }
}
$text = [System.IO.File]::ReadAllText($log)
# Chunks are split at fixed sizes, so they can contain newlines: rebuild
# them from the raw log rather than line by line.
$pattern = [regex]'CONSTELLA_BENCH_MD (\d{6}) ([\s\S]*?)(?=\r?\nCONSTELLA_BENCH_(?:MD \d{6} |DONE))'
$parts = $pattern.Matches($text) | ForEach-Object { [pscustomobject]@{ Index = [int]$_.Groups[1].Value; Text = $_.Groups[2].Value } } | Sort-Object Index
if (-not $parts) {
	Get-Content -LiteralPath $log | Select-Object -Last 40 | Write-Output
	throw "No benchmark report in the Studio output"
}
$report = ($parts | ForEach-Object { $_.Text }) -join ""
$report = $report -replace "`r`n", "`n"
$header = "<!-- Local Studio run: $(Get-Date -Format 'yyyy-MM-dd HH:mm'), $((Get-CimInstance Win32_Processor).Name.Trim()), Studio $((Get-Item $StudioPath).VersionInfo.ProductVersion), Runs=$Runs -->`n"
[System.IO.File]::WriteAllText((Join-Path $root $Out), $header + $report, (New-Object System.Text.UTF8Encoding $false))
Write-Output "Benchmarks finished in $([int]((Get-Date) - $started).TotalSeconds)s -> $Out"
if ($report -match '(?m)^REGRESSION \|') { Write-Output "Regressions reported:"; ($report -split "`n") | Where-Object { $_ -match '^REGRESSION \|' } }
