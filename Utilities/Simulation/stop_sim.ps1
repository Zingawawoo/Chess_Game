# Stops the simulation: the watchdog, every worker and their engines. Results so far are kept.
# Your Godot editor is left alone.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*watchdog_sim*" -or $_.CommandLine -like "*run_sim*" -or $_.CommandLine -like "*monitor_sim*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Get-CimInstance Win32_Process | Where-Object { $_.Name -like "Godot*" -and $_.CommandLine -like "*sim.gd*" } | ForEach-Object {
	Get-CimInstance Win32_Process -Filter "ParentProcessId=$($_.ProcessId)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
	Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
"Simulation stopped."
