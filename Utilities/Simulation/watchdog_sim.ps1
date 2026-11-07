# Watches a running simulation: restarts any worker that crashed or got stuck (it carries on
# from where it stopped), keeps the PC awake (the screen can still turn off) and logs to
# data\watchdog.txt. With -Endless, each time a batch finishes it is moved to data\batch_N and a
# new batch of random loadouts starts. Stop it all with stop_sim.ps1.
# Usage: .\Utilities\Simulation\watchdog_sim.ps1 -Workers 4
param(
	[int]$Workers = 4,
	[string]$Godot = "C:\Aziz\Programs\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe",
	[int]$StuckMinutes = 10,
	[switch]$Endless,
	[int]$BatchSize = 65000
)
$proj = (Resolve-Path "$PSScriptRoot\..\..").Path
$data = Join-Path $PSScriptRoot "data"
$jobs = Join-Path $data "jobs.json"
$log = Join-Path $data "watchdog.txt"
Add-Type -Namespace W -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
[W.Power]::SetThreadExecutionState(0x80000001) | Out-Null   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
function Note($t) { Add-Content $log ("{0:HH:mm:ss} {1}" -f (Get-Date), $t) }
Note "watchdog started ($Workers workers)"
$restarts = @{}
while ($true) {
	$finished = 0
	$procs = Get-CimInstance Win32_Process | Where-Object { $_.Name -like "Godot*" -and $_.CommandLine -like "*sim.gd*" }
	for ($i = 0; $i -lt $Workers; $i++) {
		$logs = Get-ChildItem $data -Filter "log_${i}*.txt" -ErrorAction SilentlyContinue
		if ($logs | Where-Object { Select-String -Path $_.FullName -Pattern "worker $i done" -Quiet }) { $finished++; continue }
		$out = Join-Path $data "out_$i.jsonl"
		$p = $procs | Where-Object { $_.CommandLine -like "*out_$i.jsonl*" }
		if ($p -and (Test-Path $out) -and ((Get-Date) - (Get-Item $out).LastWriteTime).TotalMinutes -gt $StuckMinutes) {
			Note "worker $i stuck, killing it"
			foreach ($q in $p) {
				Get-CimInstance Win32_Process -Filter "ParentProcessId=$($q.ProcessId)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
				Stop-Process -Id $q.ProcessId -Force -ErrorAction SilentlyContinue
			}
			$p = $null
			Start-Sleep 3
		}
		if (-not $p) {
			$restarts[$i] = 1 + [int]$restarts[$i]
			$n = $restarts[$i]
			Note "worker $i not running, restart #$n"
			$np = Start-Process -FilePath $Godot -WindowStyle Hidden -PassThru `
				-ArgumentList @("--headless", "--path", $proj, "-s", "res://Utilities/Simulation/sim.gd", "--",
					$jobs, $out, $i, $Workers) `
				-RedirectStandardOutput (Join-Path $data "log_${i}_r$n.txt") `
				-RedirectStandardError (Join-Path $data "err_${i}_r$n.txt")
			Start-Sleep 5
			try { $np.PriorityClass = 'BelowNormal' } catch {}
		}
	}
	if ($finished -ge $Workers) {
		Note "all workers finished"
		if (-not $Endless) { break }
		$b = 1
		while (Test-Path (Join-Path $data "batch_$b")) { $b++ }
		$dest = Join-Path $data "batch_$b"
		New-Item -ItemType Directory $dest | Out-Null
		Move-Item (Join-Path $data "out_*.jsonl"), (Join-Path $data "log_*.txt"), (Join-Path $data "err_*.txt"), $jobs $dest
		python (Join-Path $PSScriptRoot "make_jobs.py") $BatchSize $jobs (9000000 + 100000 * $b) (Join-Path $PSScriptRoot "..\Powerups\powerups.gd")
		Note "saved batch $b, starting a new one"
		$restarts = @{}
		continue
	}
	Start-Sleep 60
}
[W.Power]::SetThreadExecutionState(0x80000000) | Out-Null
