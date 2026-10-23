-- Kady.app — headless launcher for K-Dense BYOK.
-- The applet only provides the Dock icon, Cmd+Q, and reopen handling. The
-- services and the native UI window are owned by a hidden helper app
-- (Contents/Resources/KadySupervisor.app) which `open` spawns detached —
-- launchd becomes its parent, so nothing here can take it down accidentally.

global stateFile, reopenFlag, logFile, supPidFile, nodePidFile
property uiReady : false
property slowNoticeShown : false
property ticks : 0

on appSupportDir()
	return (POSIX path of (path to application support from user domain)) & "Kady/"
end appSupportDir

on run
	set resDir to (POSIX path of (path to me)) & "Contents/Resources/"
	set supportDir to my appSupportDir()
	set stateFile to supportDir & "state"
	set reopenFlag to supportDir & "reopen"
	set supPidFile to supportDir & "supervise.pid"
	set nodePidFile to supportDir & "node.pid"
	set logFile to (POSIX path of (path to library folder from user domain)) & "Logs/Kady.log"
	do shell script "mkdir -p " & quoted form of supportDir & " " & quoted form of (POSIX path of (path to library folder from user domain)) & "Logs"

	-- Already running? Just pop the UI window back up.
	set supPid to my readFile(supPidFile)
	if supPid is not "" and my alive(supPid) then
		do shell script "touch " & quoted form of reopenFlag
		return
	end if

	-- Clear artifacts from a previous run so idle doesn't read them as ours.
	do shell script "rm -f " & quoted form of stateFile & " " & quoted form of supPidFile & " " & quoted form of nodePidFile & " " & quoted form of reopenFlag
	set uiReady to false
	set slowNoticeShown to false
	set ticks to 0
	display notification "Starting services — the first launch can take a minute…" with title "Kady"
	do shell script "open -a " & quoted form of (resDir & "KadySupervisor.app")
end run

on reopen
	-- Dock icon clicked while running: bring the UI window back.
	do shell script "mkdir -p " & quoted form of my appSupportDir() & " && touch " & quoted form of (my appSupportDir() & "reopen")
end reopen

on idle
	set ticks to ticks + 1
	set cur to my readFile(stateFile)
	if cur is "quitting" then return 2
	if cur starts with "ready" and not uiReady then
		set uiReady to true
		display notification "Kady is ready" with title "Kady"
	else if cur starts with "dead window closed" then
		-- Closing the Kady window is a normal quit, not a failure worth reporting.
		tell me to quit
	else if cur starts with "dead" or cur starts with "error" then
		display dialog "Kady stopped — " & cur & return & return & "Details are in " & logFile buttons {"OK"} default button 1 with icon caution
		tell me to quit
	else
		-- Long startups (package installs) are normal — say so once.
		if not slowNoticeShown and ticks > 10 then
			set slowNoticeShown to true
			display notification "Still starting — checking packages and bringing services up…" with title "Kady"
		end if
		-- The supervisor vanished without writing a terminal state: it died.
		set supPid to my readFile(supPidFile)
		if supPid is not "" and not my alive(supPid) then
			display dialog "Kady failed to start — the supervisor exited unexpectedly." & return & return & "Details are in " & logFile buttons {"OK"} default button 1 with icon caution
			tell me to quit
		end if
	end if
	return 2
end idle

on quit
	set supportDir to my appSupportDir()
	-- Mark intent before tearing down so a late idle doesn't report the
	-- shutdown as a crash.
	do shell script "printf 'quitting' > " & quoted form of (supportDir & "state") & " 2>/dev/null; true"
	try
		-- Killing the node process unwinds everything: supervise.sh notices,
		-- stops the window, and exits (its own TERM trap covers the reverse
		-- order). pkill catches the early-startup case with no node.pid yet.
		do shell script "kill $(cat " & quoted form of (supportDir & "node.pid") & " 2>/dev/null) 2>/dev/null; sleep 1; pkill -f 'KadySupervisor.app' 2>/dev/null; pkill -f 'Resources/supervise.sh' 2>/dev/null; pkill -f 'Resources/kady-window' 2>/dev/null; true"
	end try
	continue quit
end quit

on readFile(f)
	try
		return do shell script "cat " & quoted form of f & " 2>/dev/null"
	on error
		return ""
	end try
end readFile

on alive(p)
	try
		return (do shell script "kill -0 " & p & " 2>/dev/null && echo yes || echo no") is "yes"
	on error
		return false
	end try
end alive
