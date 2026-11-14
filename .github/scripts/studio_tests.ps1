param(
	[string]$StudioPath = $env:ROBLOX_STUDIO_EXE,
	[string]$PlacePath = "build/multiplayer.rbxl",
	[string]$RunnerPath = (Join-Path $PSScriptRoot "studio_tests.luau"),
	[string]$SuccessMarker = "CONSTELLA_MULTIPLAYER_PASS",
	[int]$TimeoutSeconds = 180
)
$ErrorActionPreference = "Stop"
if (-not $StudioPath) {
	$StudioPath = Get-ChildItem "$env:LOCALAPPDATA/Roblox/Versions" -Filter RobloxStudioBeta.exe -Recurse |
		Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $StudioPath -or -not (Test-Path -LiteralPath $StudioPath)) { throw "Roblox Studio executable not found" }
$place = (Resolve-Path -LiteralPath $PlacePath).Path
$runner = (Resolve-Path -LiteralPath $RunnerPath).Path
$output = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $place) "studio-results.log"))
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output }
$arguments = @("--task", "RunScript", "--localPlaceFile", "`"$place`"", "--runScriptFile", "`"$runner`"", "--outputFile", "`"$output`"", "--quitAfterExecution")
$process = Start-Process -FilePath $StudioPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
try {
	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
	while (-not $process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1; $process.Refresh() }
	if (-not $process.HasExited) { throw "Studio integration tests timed out after $TimeoutSeconds seconds" }
	if (-not (Test-Path -LiteralPath $output)) { throw "Studio produced no test report" }
	$report = Get-Content -LiteralPath $output -Raw
	Write-Output $report
	if ($report -notmatch ('(?m)^' + [regex]::Escape($SuccessMarker) + '\r?$')) { throw "Studio tests did not pass" }
} finally {
	if (-not $process.HasExited) { Stop-Process -Id $process.Id }
}
