# Runs the powerup self-play simulation on this PC and shows a progress window.
# Usage (PowerShell):  .\Utilities\Simulation\run_sim.ps1 -Workers 8
param(
	[int]$Workers = 8,
	[string]$Godot = "C:\Aziz\Programs\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe"
)
$proj = (Resolve-Path "$PSScriptRoot\..\..").Path
$data = Join-Path $PSScriptRoot "data"
$jobs = Join-Path $data "jobs.json"

for ($i = 0; $i -lt $Workers; $i++) {
	Start-Process -FilePath $Godot -WindowStyle Hidden `
		-ArgumentList @("--headless", "--path", $proj, "-s", "res://Utilities/Simulation/sim.gd", "--",
			$jobs, (Join-Path $data "out_$i.jsonl"), $i, $Workers) `
		-RedirectStandardOutput (Join-Path $data "log_$i.txt") `
		-RedirectStandardError (Join-Path $data "err_$i.txt")
}
Start-Process powershell -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
	(Join-Path $PSScriptRoot "monitor_sim.ps1"))
