#!/bin/bash
# Headless supervisor for Kady.app — spawned by KadySupervisor.app (the hidden
# helper applet), owns the services and the native UI window. Reports progress
# to the outer applet through $STATE and watches $REOPEN so a click on the
# Dock icon brings the window back. Exiting kills everything.
set -u

BUNDLE="$(cd "$(dirname "$0")/../../.." && pwd)"   # …/Kady.app
PARENT="$(dirname "$BUNDLE")"

SUPPORT="$HOME/Library/Application Support/Kady"
STATE="$SUPPORT/state"
REOPEN="$SUPPORT/reopen"
POINTER="$SUPPORT/repo-path.txt"
mkdir -p "$SUPPORT"

say() { printf '%s\n' "$1" > "$STATE"; }

# Launch lock: a second supervisor must not double-start services. noclobber
# makes the pid file itself the atomic lock; a stale lock is only cleared when
# its recorded process is gone.
LOCK="$SUPPORT/supervise.lock"
while true; do
	if (set -o noclobber; echo $$ > "$LOCK") 2>/dev/null; then
		break
	fi
	LOCK_PID="$(cat "$LOCK" 2>/dev/null || true)"
	if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
		exit 0
	fi
	rm -f "$LOCK"
done
echo $$ > "$SUPPORT/supervise.pid"
rm -f "$REOPEN"
say "starting"

# Killed directly (applet quit, logout): make sure the children go too.
NODE_PID=""
WINDOW_PID=""
cleanup() {
	[ -n "$WINDOW_PID" ] && kill "$WINDOW_PID" 2>/dev/null
	[ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null
	rm -f "$SUPPORT/node.pid" "$SUPPORT/supervise.pid" "$LOCK"
}
trap 'cleanup; exit 0' TERM INT HUP

is_repo() {
	[ -f "$1/start.mjs" ] && [ -d "$1/server" ] && [ -d "$1/web" ]
}

alert() {
	/usr/bin/osascript - "$1" <<'OSA' >/dev/null 2>&1
on run argv
	display dialog (item 1 of argv) with title "Kady" buttons {"OK"} default button 1 with icon caution
end run
OSA
}

# --- Resolve the repo -----------------------------------------------------
ROOT=""
if is_repo "$PARENT"; then
	ROOT="$PARENT"
elif [ -f "$POINTER" ]; then
	SAVED="$(head -n 1 "$POINTER" | tr -d '\r\n')"
	is_repo "$SAVED" && ROOT="$SAVED"
# Pointer used to live inside the bundle; pick it up on first headless run.
elif [ -f "$BUNDLE/Contents/Resources/repo-path.txt" ]; then
	SAVED="$(head -n 1 "$BUNDLE/Contents/Resources/repo-path.txt" | tr -d '\r\n')"
	is_repo "$SAVED" && ROOT="$SAVED"
fi

while [ -z "$ROOT" ]; do
	CHOSEN="$(/usr/bin/osascript <<'OSA' 2>/dev/null
try
	POSIX path of (choose folder with prompt "Where is the k-dense-byok folder? Select the folder containing start.mjs.")
on error
	""
end try
OSA
)"
	if [ -z "$CHOSEN" ]; then
		say "error no repo folder selected"
		exit 1
	fi
	CHOSEN="${CHOSEN%/}"
	if is_repo "$CHOSEN"; then
		ROOT="$CHOSEN"
	else
		alert "\"$(basename "$CHOSEN")\" is not the k-dense-byok folder — start.mjs was not found in it."
	fi
done
printf '%s\n' "$ROOT" > "$POINTER" 2>/dev/null || true

# --- Environment ----------------------------------------------------------
# No shell profile is loaded in a GUI-launched process, so make the usual
# Node install locations visible before start.sh runs. ServBay in particular
# keeps node outside Homebrew's paths.
for d in \
	"$HOME/.local/bin" \
	/opt/homebrew/bin \
	/usr/local/bin \
	/Applications/ServBay/package/node/current/bin \
	/Applications/ServBay/script/alias \
	"$HOME/.volta/bin" \
	"$HOME/.asdf/shims" \
	"$HOME/.local/share/mise/shims" \
	/opt/local/bin; do
	[ -d "$d" ] && PATH="$d:$PATH"
done
export PATH
export VOLTA_HOME="${VOLTA_HOME:-$HOME/.volta}"
if [ -s "$HOME/.nvm/nvm.sh" ]; then
	# shellcheck disable=SC1091
	. "$HOME/.nvm/nvm.sh"
fi
command -v fnm >/dev/null 2>&1 && eval "$(fnm env 2>/dev/null)"

cd "$ROOT" || { say "error cannot cd to $ROOT"; exit 1; }

env_file_val() {
	# Last uncommented VAR=value line in .env; first word, unquoted.
	grep -E "^[[:space:]]*$1[[:space:]]*=" "$ROOT/.env" 2>/dev/null \
		| grep -vE '^[[:space:]]*#' | tail -n 1 | cut -d= -f2- \
		| awk '{print $1}' | tr -d '"'"'"'\r'
}

probe_url() { curl -sS -o /dev/null --max-time 2 "$1" 2>/dev/null; }

# --- Provider reachability ---------------------------------------------------
# A *set* env var doesn't mean the endpoint is up — a dead local model server
# is the difference between a working app and "replies never load". Log it
# before the window opens without blocking startup.
WARNINGS=""
OCB="$(env_file_val OPENAI_COMPATIBLE_BASE_URL)"
OCB="${OCB:-${OPENAI_COMPATIBLE_BASE_URL:-}}"
if [ -n "$OCB" ] && ! probe_url "${OCB%/}/v1/models"; then
	WARNINGS="Your OpenAI-compatible model endpoint ($OCB) is not responding."
fi
OB="$(env_file_val OLLAMA_BASE_URL)"
OB="${OB:-${OLLAMA_BASE_URL:-}}"
if [ -n "$OB" ] && ! probe_url "${OB%/}/api/tags"; then
	WARNINGS="${WARNINGS:+$WARNINGS$'\n'}Your Ollama endpoint ($OB) is not responding."
fi
if [ -n "$WARNINGS" ]; then
	# Log it for troubleshooting, but never block startup: the model picker
	# already shows a disconnected provider and the run route reports the
	# concrete endpoint error if the user tries to chat anyway.
	printf '%b\n' "$WARNINGS" >&2
fi

# --- Ports -----------------------------------------------------------------
# The defaults (8000/3000) are crowded; scan upward from dedicated bases so
# another program holding them can't block startup. An explicit
# KADY_PORT / KADY_FRONTEND_PORT / NEXT_PUBLIC_ADK_API_URL in .env still wins
# (start.mjs's applyEnvFile overrides ambient env with .env), so read the
# same precedence it will use.

# start.mjs's freePort reaps listeners whose cwd is inside this repo, so only
# a port held by a FOREIGN process is a real obstacle — move past those and
# let the launcher's own cleanup reclaim stale Kady leftovers on our port.
port_held_by_foreign() {
	local pids pid cwd foreign=0
	pids="$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null)"
	[ -z "$pids" ] && return 1
	for pid in $pids; do
		cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
		case "$cwd" in
			"$ROOT"|"$ROOT"/*) ;;
			*) foreign=1 ;;
		esac
	done
	[ "$foreign" -eq 1 ]
}

find_free_port() {
	local p="$1"
	while port_held_by_foreign "$p"; do p=$((p + 1)); done
	printf '%s' "$p"
}

BACKEND_PORT="$(env_file_val KADY_PORT)"
BACKEND_PORT="${BACKEND_PORT:-${KADY_PORT:-$(find_free_port 8200)}}"
FRONTEND_PORT="$(env_file_val KADY_FRONTEND_PORT)"
FRONTEND_PORT="${FRONTEND_PORT:-${KADY_FRONTEND_PORT:-$(find_free_port 3200)}}"
export KADY_PORT="$BACKEND_PORT" KADY_FRONTEND_PORT="$FRONTEND_PORT"

# The web app calls the backend at NEXT_PUBLIC_ADK_API_URL, defaulting to
# :8000 — it must follow the port we actually chose.
API_URL="$(env_file_val NEXT_PUBLIC_ADK_API_URL)"
API_URL="${API_URL:-${NEXT_PUBLIC_ADK_API_URL:-http://localhost:$BACKEND_PORT}}"
export NEXT_PUBLIC_ADK_API_URL="$API_URL"

# Reclaim our ports from stale Kady instances now — same rule start.mjs's
# freePort applies later (cwd inside the repo = ours). Doing it here also
# keeps the readiness check honest: it can't curl a leftover frontend and
# report ready before the new services are actually up.
for p in "$BACKEND_PORT" "$FRONTEND_PORT"; do
	for pid in $(lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null); do
		cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
		case "$cwd" in "$ROOT"|"$ROOT"/*) kill "$pid" 2>/dev/null ;; esac
	done
done

UI_URL="http://localhost:$FRONTEND_PORT"
TOKEN="$(env_file_val KADY_AUTH_TOKEN)"
TOKEN="${TOKEN:-${KADY_AUTH_TOKEN:-}}"
[ -n "$TOKEN" ] && UI_URL="$UI_URL/#kady-token=$TOKEN"
# Caveat: with KADY_REQUIRE_AUTH=1 and no pinned token, the tokenized link is
# printed in the log instead.

# --- Services ---------------------------------------------------------------
# A Dock click during startup can leave a reopen request behind; the initial
# window below is the response to that click, so do not replay it afterwards.
rm -f "$REOPEN"
./start.sh --no-browser &
NODE_PID=$!
echo "$NODE_PID" > "$SUPPORT/node.pid"

# Wait for BOTH services (npm installs make the first launch slow). Checking
# the backend too keeps the window from opening on a UI whose API is still
# booting — that half-up state is what shows "listProjects 404". Any HTTP
# response counts (the backend has no / route — it answers 404, which is up).
UP=0
for _ in $(seq 1 600); do
	kill -0 "$NODE_PID" 2>/dev/null || { say "dead services exited during startup — see log"; exit 1; }
	if curl -sS -o /dev/null --max-time 2 "$UI_URL" 2>/dev/null \
		&& curl -sS -o /dev/null --max-time 2 "http://localhost:$BACKEND_PORT/" 2>/dev/null; then
		UP=1; break
	fi
	sleep 1
done
if [ "$UP" -eq 0 ]; then
	kill "$NODE_PID" 2>/dev/null
	say "error services did not come up within 10 minutes — see log"
	exit 1
fi

# --- UI window ---------------------------------------------------------------
# kady-window is a tiny native WKWebView binary bundled next to this script —
# a real app window, no browser profile or second-instance weirdness. The
# process lives as long as the window, so tracking its pid covers both "user
# closed the window" and "window died". No binary → default browser, and
# there is nothing to track.
WINDOW_BIN="$(dirname "$0")/kady-window"

open_window() {
	if [ -x "$WINDOW_BIN" ]; then
		if [ -n "$WINDOW_PID" ] && kill -0 "$WINDOW_PID" 2>/dev/null; then
			# The window is already alive; SIGUSR1 asks it to unminimize and come
			# forward instead of spawning a duplicate process.
			kill -USR1 "$WINDOW_PID" 2>/dev/null || true
			return
		fi
		"$WINDOW_BIN" "$UI_URL" >/dev/null 2>&1 &
		WINDOW_PID=$!
	else
		/usr/bin/open "$UI_URL"
	fi
}

open_window
say "ready"

# --- Watch loop ---------------------------------------------------------------
while true; do
	if ! kill -0 "$NODE_PID" 2>/dev/null; then
		[ -n "$WINDOW_PID" ] && kill "$WINDOW_PID" 2>/dev/null
		say "dead services stopped"
		break
	fi
	if [ -n "$WINDOW_PID" ] && ! kill -0 "$WINDOW_PID" 2>/dev/null; then
		kill "$NODE_PID" 2>/dev/null
		say "dead window closed"
		break
	fi
	if [ -f "$REOPEN" ]; then
		rm -f "$REOPEN"
		open_window
	fi
	sleep 2
done

wait "$NODE_PID" 2>/dev/null
rm -f "$SUPPORT/node.pid" "$SUPPORT/supervise.pid" "$LOCK"
exit 0
