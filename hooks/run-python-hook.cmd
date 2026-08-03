: << 'CMDBLOCK'
@echo off
REM Cross-platform polyglot launcher for Python hook scripts.
REM
REM On Windows: cmd.exe runs the batch portion below, which resolves a working
REM Python interpreter and executes the named script with it.
REM On Unix: the shell sees `: << 'CMDBLOCK' ... CMDBLOCK` as a no-op heredoc
REM and falls through to the POSIX tail at the bottom of this file.
REM
REM Why this exists: invoking `python3` directly is not portable to Windows.
REM Windows ships a Microsoft Store alias stub named python3.exe that is always
REM present on PATH but fails with exit code 9009 unless the user installed
REM Python from the Store. Because Claude Code treats a failed PreToolUse hook
REM as a non-blocking error and lets the tool call proceed, a guard launched via
REM bare `python3` silently enforces nothing on those machines.
REM
REM Presence checks (`where python3`) are NOT sufficient -- the stub exists on
REM PATH and `where` finds it. The interpreter must actually be run and its exit
REM code checked. Probe order puts `python3` last precisely because it is the
REM name most likely to be the stub.
REM
REM Usage: run-python-hook.cmd <script-path-relative-to-this-file>
REM Hook input arrives on stdin, so no arguments are forwarded to the script.

setlocal
if "%~1"=="" (
    echo run-python-hook.cmd: missing script name >&2
    exit /b 1
)

set "HOOK_DIR=%~dp0"
set "HOOK_SCRIPT=%HOOK_DIR%%~1"

if not exist "%HOOK_SCRIPT%" (
    echo run-python-hook.cmd: script not found: %HOOK_SCRIPT% >&2
    exit /b 1
)

REM Probe interpreters by executing them, not by testing for their presence.
for %%I in ("py -3" "python" "python3") do (
    call :try_interp %%~I
    if not errorlevel 1 goto :found
)

REM No usable interpreter. Report loudly on stderr so the failure is visible
REM instead of silently degrading into an unenforced guard.
echo run-python-hook.cmd: no working Python 3 interpreter found (tried py -3, python, python3). >&2
echo run-python-hook.cmd: this guard is NOT enforcing. Install Python 3 and ensure it is on PATH. >&2
exit /b 1

:found
%INTERP% "%HOOK_SCRIPT%"
exit /b %ERRORLEVEL%

:try_interp
set "CANDIDATE=%*"
%CANDIDATE% -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >nul 2>nul
if errorlevel 1 exit /b 1
set "INTERP=%CANDIDATE%"
exit /b 0
CMDBLOCK

# --- POSIX path -------------------------------------------------------------
# Resolve this file's directory, then run the requested script with whichever
# Python 3 actually works.
#
# Interpreters are probed by EXECUTION, not with `command -v`. Presence is not
# usability: under Git Bash / MSYS2 on Windows, `command -v python3` happily
# resolves the Microsoft Store alias stub, which then fails at run time. So this
# path has the same trap as cmd.exe and needs the same defence.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$1"

if [ ! -f "${SCRIPT_DIR}/${SCRIPT_NAME}" ]; then
    echo "run-python-hook.cmd: script not found: ${SCRIPT_DIR}/${SCRIPT_NAME}" >&2
    exit 1
fi

for interp in python3 python; do
    command -v "$interp" >/dev/null 2>&1 || continue
    if "$interp" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' \
        >/dev/null 2>&1; then
        exec "$interp" "${SCRIPT_DIR}/${SCRIPT_NAME}"
    fi
done

echo "run-python-hook.cmd: no working Python 3 interpreter found (tried python3, python)." >&2
echo "run-python-hook.cmd: this guard is NOT enforcing. Install Python 3 and ensure it is on PATH." >&2
exit 1
