-- KadySupervisor.app — hidden helper inside Kady.app.
-- Spawned via `open`, so launchd is its parent and it survives the outer
-- applet's do shell script teardown. Blocks on supervise.sh for its whole
-- life; when that exits, the applet exits too (not a stay-open app).
on run
	set sup to (POSIX path of (path to me)) & "Contents/Resources/supervise.sh"
	set logFile to (POSIX path of (path to library folder from user domain)) & "Logs/Kady.log"
	do shell script "mkdir -p " & quoted form of ((POSIX path of (path to library folder from user domain)) & "Logs")
	do shell script "bash " & quoted form of sup & " >> " & quoted form of logFile & " 2>&1"
end run
