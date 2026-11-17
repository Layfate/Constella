<#
.SYNOPSIS
	Runs Constella's load or soak test with real Roblox Studio clients.

.DESCRIPTION
	Builds load.project.json, then uses Studio's RunScript CLI and
	StudioTestService:ExecuteMultiplayerTestAsync to start one server and
	-Clients real client processes connected through Roblox's network
	replicator. The result (every phase, every client) is written as JSON to
	-Out; .github/scripts/load_report.py turns it into Markdown.

.EXAMPLE
	.github/scripts/studio_load.ps1 -Clients 8
	.github/scripts/studio_load.ps1 -Mode Soak -Clients 4 -Minutes 120
#>
param(
	[ValidateSet("Load", "Soak")][string]$Mode = "Load",
	[int]$Clients = 4,
	[int]$PhaseSeconds = 20,
	[int]$WarmupSeconds = 6,
	[int]$Rate = 10,
	[int]$RequestsPerSecond = 20,
	[double]$Minutes = 60,
	[int]$SampleSeconds = 30,
	# Soak only: -NoWorkload runs a control (clients connected, no Constella work).
	[switch]$NoWorkload,
	[string]$Out = "",
	[string]$StudioPath = $env:ROBLOX_STUDIO_EXE,
	[string]$Rojo = "build/tools/rojo.exe"
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $root
if (-not $Out) { $Out = "build/load-$($Mode.ToLower())-$Clients.json" }
if (-not $StudioPath) {
	$StudioPath = Get-ChildItem "$env:LOCALAPPDATA/Roblox/Versions" -Filter RobloxStudioBeta.exe -Recurse |
		Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $StudioPath -or -not (Test-Path -LiteralPath $StudioPath)) { throw "Roblox Studio executable not found" }
if (-not (Get-Command $Rojo -ErrorAction SilentlyContinue)) { $Rojo = "rojo" }

New-Item -ItemType Directory -Path build -Force | Out-Null
# Per-run file names, so runs can go side by side.
$name = [System.IO.Path]::GetFileNameWithoutExtension($Out)
& $Rojo build load.project.json -o "build/$name.rbxl"
if ($LASTEXITCODE -ne 0) { throw "rojo build failed" }

# The runner executes at command-bar level inside Studio. Results leave
# Studio through print, so the JSON is printed in numbered chunks (long
# lines can be cut in the output log) and reassembled here.
$runner = @"
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local results = StudioTestService:ExecuteMultiplayerTestAsync($Clients, {
	Suite = "ConstellaLoad",
	Mode = "$Mode",
	Clients = $Clients,
	PhaseSeconds = $PhaseSeconds,
	WarmupSeconds = $WarmupSeconds,
	Rate = $Rate,
	RequestsPerSecond = $RequestsPerSecond,
	Minutes = $Minutes,
	SampleSeconds = $SampleSeconds,
	Workload = $(if ($NoWorkload) { 'false' } else { 'true' }),
})
local json = HttpService:JSONEncode(results)
local size = 3000
for index = 1, math.ceil(#json / size) do
	print(("CONSTELLA_LOAD_JSON %06d %s"):format(index, json:sub((index - 1) * size + 1, index * size)))
end
print(if type(results) == "table" and results.Passed == true then "CONSTELLA_LOAD_PASS" else "CONSTELLA_LOAD_FAIL")
"@
$runnerPath = Join-Path $root "build/$name-runner.luau"
[System.IO.File]::WriteAllText($runnerPath, $runner, (New-Object System.Text.UTF8Encoding $false))
$place = (Resolve-Path "build/$name.rbxl").Path
$log = Join-Path $root "build/$name-output.log"
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }

if ($Mode -eq "Soak") { $timeout = [int]($Minutes * 60 + 600) } else { $timeout = $PhaseSeconds * 8 + 3 * 2 + 300 }
$arguments = @("--task", "RunScript", "--localPlaceFile", "`"$place`"", "--runScriptFile", "`"$runnerPath`"", "--outputFile", "`"$log`"", "--quitAfterExecution")
$started = Get-Date
$process = Start-Process -FilePath $StudioPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
try {
	$deadline = $started.AddSeconds($timeout)
	while (-not $process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; $process.Refresh() }
	if (-not $process.HasExited) { throw "Load test timed out after $timeout seconds" }
} finally {
	if (-not $process.HasExited) { Stop-Process -Id $process.Id }
}
if (-not (Test-Path -LiteralPath $log)) { throw "Studio produced no output log" }
$lines = Get-Content -LiteralPath $log
$chunks = $lines | Where-Object { $_ -match '^CONSTELLA_LOAD_JSON (\d{6}) (.*)$' } | ForEach-Object {
	$null = $_ -match '^CONSTELLA_LOAD_JSON (\d{6}) (.*)$'; [pscustomobject]@{ Index = [int]$Matches[1]; Text = $Matches[2] }
} | Sort-Object Index
if (-not $chunks) {
	$lines | Select-Object -Last 40 | Write-Output
	throw "No results in the Studio output"
}
$json = ($chunks | ForEach-Object { $_.Text }) -join ""
[System.IO.File]::WriteAllText((Join-Path $root $Out), $json, (New-Object System.Text.UTF8Encoding $false))
$elapsed = [int]((Get-Date) - $started).TotalSeconds
$result = $json | ConvertFrom-Json
Write-Output "$Mode with $Clients clients: Passed=$($result.Passed) ($($result.Message)) in ${elapsed}s -> $Out"
if (-not $result.Passed) { exit 1 }
