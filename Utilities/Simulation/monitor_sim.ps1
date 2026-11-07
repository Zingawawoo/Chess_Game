# Progress window for the powerup simulation (opened by run_sim.ps1).
$data = Join-Path $PSScriptRoot "data"
$total = (Get-Content (Join-Path $data "jobs.json") -Raw | ConvertFrom-Json).Count
$host.UI.RawUI.WindowTitle = "Pixel Chess - powerup simulation"
$start = Get-Date
while ($true) {
	$done = 0
	Get-ChildItem $data -Filter "out_*.jsonl" -ErrorAction SilentlyContinue | ForEach-Object {
		$done += (Get-Content $_.FullName | Measure-Object -Line).Lines
	}
	$running = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%'" |
		Where-Object { $_.CommandLine -like "*Simulation/sim.gd*" }).Count
	$pct = [math]::Min(100, [math]::Round(100 * $done / [math]::Max($total, 1), 1))
	$elapsed = (Get-Date) - $start
	$eta = "--"
	if ($done -gt 20) {
		$left = $elapsed.TotalSeconds / $done * ($total - $done)
		$eta = [TimeSpan]::FromSeconds([math]::Round($left)).ToString("hh\:mm\:ss")
	}
	$status = "$done / $total games  ($pct%)   workers running: $running   time left: ~$eta"
	Write-Progress -Activity "Fairy-Stockfish vs itself with powerups" -Status $status -PercentComplete $pct
	Clear-Host
	Write-Host ""
	Write-Host "  Pixel Chess - powerup simulation" -ForegroundColor Yellow
	Write-Host ""
	$bar = ("#" * [math]::Floor($pct / 2.5)).PadRight(40, ".")
	Write-Host "  [$bar] $pct%"
	Write-Host "  $status"
	if ($running -eq 0 -and ($elapsed.TotalSeconds -gt 15)) {
		Write-Host ""
		if ($done -ge $total) {
			Write-Host "  Finished in $($elapsed.ToString('hh\:mm\:ss')). You can close this window." -ForegroundColor Green
		} else {
			Write-Host "  Stopped early: $done of $total games. Check the err_*.txt files in Utilities\Simulation\data." -ForegroundColor Red
		}
		break
	}
	Start-Sleep -Seconds 2
}
Read-Host "  Press Enter to close"
