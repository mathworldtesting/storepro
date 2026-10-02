#!/usr/bin/env bash
#
# setup.sh - bootstrap, start and health-check the "ReadIt!" book catalog app.
#
#   ./setup.sh                 # full setup + start on port 5000 (or next free one)
#   PORT=8080 ./setup.sh       # start on a specific port
#   ./setup.sh --stop          # stop an app previously started by this script
#
# What it does, in order:
#   1. checks project dependencies (.NET 8 SDK, NuGet packages) and installs what is missing
#   2. checks whether the web server (Kestrel / ASP.NET Core runtime) is running, else installs it
#   3. checks the condition of the project, then tries to stand it up
#   4. on error, tries to fix the problem twice; if it still fails it prints the error and quits
#   5. on success, health-checks the app and prints the home page URL
#
set -uo pipefail

# ---------------------------------------------------------------- configuration
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$REPO_ROOT/catalog/catalog.csproj"
SOLUTION="$REPO_ROOT/catalog-baseline-01.sln"
DOTNET_CHANNEL="8.0"                     # TargetFramework is net8.0
REQUIRED_RUNTIME="Microsoft.AspNetCore.App 8."
PORT="${PORT:-5000}"
MAX_FIX_ATTEMPTS=2                       # "try to fix the error two times"
HEALTH_TIMEOUT=90                        # seconds to wait for the home page
HEALTH_MARKER="Our Books"                # string rendered by Pages/Index.cshtml
RUN_DIR="$REPO_ROOT/.setup"
LOG="$RUN_DIR/app.log"
PID_FILE="$RUN_DIR/app.pid"
APP_PID=""

mkdir -p "$RUN_DIR"

# --------------------------------------------------------------------- plumbing
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
ok()    { printf '%s  [ok]%s %s\n'    "$C_GREEN"  "$C_RESET" "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '%s  [warn]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
fail()  { printf '%s  [fail]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }

die() {
    fail "$*"
    printf '\n%sSetup aborted.%s\n' "$C_RED$C_BOLD" "$C_RESET" >&2
    exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------- port / http util
port_in_use() {
    local p="$1"
    if have ss; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
    elif have netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
    fi
    # last resort: try to open a connection
    (exec 3<>"/dev/tcp/127.0.0.1/${p}") >/dev/null 2>&1 && { exec 3<&- 2>/dev/null; return 0; }
    return 1
}

find_free_port() {
    local start="$1" p
    for (( p = start; p < start + 25; p++ )); do
        port_in_use "$p" || { printf '%s' "$p"; return 0; }
    done
    return 1
}

http_body() {                   # http_body <url> -> body on stdout, non-zero on failure
    local url="$1"
    if have curl; then
        curl -fsS --max-time 10 "$url" 2>/dev/null
    elif have wget; then
        wget -qO- --timeout=10 "$url" 2>/dev/null
    else
        return 2                # no http client available
    fi
}

is_catalog_app() {              # does the app on this port look like our catalog?
    local body
    body="$(http_body "http://localhost:$1/")" || return 1
    [[ "$body" == *"$HEALTH_MARKER"* || "$body" == *"ReadIt!"* ]]
}

# ------------------------------------------------------------------ --stop mode
stop_app() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid; pid="$(cat "$PID_FILE")"
        info "Stopping app (pid $pid)..."
        kill "$pid" 2>/dev/null
        for _ in {1..10}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"
        ok "Stopped."
    else
        info "No app started by this script is running."
        rm -f "$PID_FILE"
    fi
}

if [[ "${1:-}" == "--stop" ]]; then
    stop_app
    exit 0
fi

# ============================================================ 1. DEPENDENCIES ==
ensure_dotnet_sdk() {
    step "Checking project dependencies"

    # ~/.dotnet is where dotnet-install.sh puts a user-local SDK
    [[ -x "$HOME/.dotnet/dotnet" ]] && PATH="$HOME/.dotnet:$PATH"
    export PATH
    export DOTNET_CLI_TELEMETRY_OPTOUT=1
    export DOTNET_NOLOGO=1

    local sdks=""
    have dotnet && sdks="$(dotnet --list-sdks 2>/dev/null)"

    if [[ -n "$sdks" ]] && grep -q "^${DOTNET_CHANNEL}\." <<<"$sdks"; then
        ok ".NET ${DOTNET_CHANNEL} SDK is installed ($(dotnet --version 2>/dev/null))"
        return 0
    fi

    if have dotnet; then
        warn "dotnet found, but no .NET ${DOTNET_CHANNEL} SDK (project targets net8.0). Installing it..."
    else
        warn ".NET SDK is not installed. Installing .NET ${DOTNET_CHANNEL} SDK..."
    fi

    local installer="$RUN_DIR/dotnet-install.sh"
    if have curl; then
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$installer" \
            || die "Could not download the .NET installer. Install the .NET ${DOTNET_CHANNEL} SDK manually: https://dotnet.microsoft.com/download"
    elif have wget; then
        wget -qO "$installer" https://dot.net/v1/dotnet-install.sh \
            || die "Could not download the .NET installer. Install the .NET ${DOTNET_CHANNEL} SDK manually: https://dotnet.microsoft.com/download"
    else
        die "Neither curl nor wget is available; cannot install the .NET SDK automatically."
    fi

    chmod +x "$installer"
    "$installer" --channel "$DOTNET_CHANNEL" --install-dir "$HOME/.dotnet" \
        || die "The .NET SDK installer failed. See the output above."

    PATH="$HOME/.dotnet:$PATH"; export PATH
    have dotnet || die ".NET SDK still not on PATH after install."
    ok ".NET SDK installed ($(dotnet --version 2>/dev/null))"
    info "Add this to your shell profile to keep it on PATH: export PATH=\"\$HOME/.dotnet:\$PATH\""
}

packages_restored() {
    local assets="$REPO_ROOT/catalog/obj/project.assets.json"
    [[ -f "$assets" && "$assets" -nt "$PROJECT" ]]
}

ensure_packages() {
    # NuGet is the only package manager this project uses - no Node/npm tooling.
    if packages_restored; then
        ok "dependencies are installed"
        return 0
    fi

    warn "NuGet packages are not restored. Restoring..."
    if dotnet restore "$SOLUTION" >"$RUN_DIR/restore.log" 2>&1; then
        ok "NuGet packages restored"
    else
        tail -n 25 "$RUN_DIR/restore.log" >&2
        die "dotnet restore failed (full log: $RUN_DIR/restore.log)"
    fi
}

# ================================================================= 2. SERVER ==
# This app self-hosts Kestrel, so "the server" is the ASP.NET Core runtime that
# ships with the .NET SDK - there is no separate IIS/nginx to install.
ensure_server_installed() {
    local runtimes; runtimes="$(dotnet --list-runtimes 2>/dev/null)"
    if grep -q "$REQUIRED_RUNTIME" <<<"$runtimes"; then
        ok "Web server is installed (Kestrel via ${REQUIRED_RUNTIME%% *} 8.x)"
        return 0
    fi

    warn "ASP.NET Core 8 runtime is missing. Installing the .NET ${DOTNET_CHANNEL} SDK to provide it..."
    local installer="$RUN_DIR/dotnet-install.sh"
    [[ -x "$installer" ]] || {
        have curl && curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$installer" && chmod +x "$installer"
    }
    [[ -x "$installer" ]] || die "Cannot install the ASP.NET Core runtime automatically."
    "$installer" --channel "$DOTNET_CHANNEL" --install-dir "$HOME/.dotnet" \
        || die "Failed to install the ASP.NET Core runtime."
    grep -q "$REQUIRED_RUNTIME" <<<"$(dotnet --list-runtimes 2>/dev/null)" \
        || die "ASP.NET Core 8 runtime still not available."
    ok "ASP.NET Core 8 runtime installed"
}

check_server_running() {
    step "Checking whether the server is already running"

    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid; pid="$(cat "$PID_FILE")"
        if is_catalog_app "$PORT"; then
            ok "The catalog app is already running (pid $pid)"
            print_success
            exit 0
        fi
        warn "A previous app process (pid $pid) is alive but not answering. Stopping it."
        stop_app
    fi

    if port_in_use "$PORT"; then
        if is_catalog_app "$PORT"; then
            ok "The catalog app is already running on port $PORT"
            print_success
            exit 0
        fi
        warn "Port $PORT is taken by something else."
        local free; free="$(find_free_port "$((PORT + 1))")" \
            || die "No free port found near $PORT. Re-run with PORT=<port> ./setup.sh"
        PORT="$free"
        info "Using port $PORT instead."
    fi

    ensure_server_installed
    info "Server is not running yet - it will be started below."
}

# ====================================================== 3. PROJECT CONDITION ==
check_project_condition() {
    step "Checking the condition of the project"

    [[ -f "$PROJECT" ]]  || die "Project file not found: $PROJECT"
    [[ -f "$SOLUTION" ]] || warn "Solution file not found: $SOLUTION"
    ok "Project file found: ${PROJECT#$REPO_ROOT/}"

    have curl || have wget || warn "Neither curl nor wget found - the health check will fall back to a TCP probe."

    # Known, non-blocking quirks of this repo.
    grep -q '"BooksDB"[[:space:]]*:[[:space:]]*"<' "$REPO_ROOT/catalog/appsettings.json" 2>/dev/null \
        && info "appsettings.json holds placeholder connection strings - fine, the app runs on the in-memory DB."
    grep -q 'useInMemory = true' "$REPO_ROOT/catalog/Startup.cs" 2>/dev/null \
        && ok "Data provider: in-memory database (no SQL Server needed)"

    local missing_images=()
    while IFS= read -r img; do
        [[ -n "$img" ]] && [[ ! -f "$REPO_ROOT/catalog/wwwroot/images/$img" ]] && missing_images+=("$img")
    done < <(grep -rhoE 'images/[A-Za-z0-9_.-]+' "$REPO_ROOT/catalog/Pages" "$REPO_ROOT/catalog/BookLoader.cs" 2>/dev/null \
             | sed 's|images/||' | sort -u)
    if (( ${#missing_images[@]} )); then
        warn "Referenced images missing from wwwroot/images (cosmetic only, paths are case-sensitive on Linux): ${missing_images[*]}"
    fi

    grep -q 'UNCOMMENT AFTER ADDING REDIS' "$REPO_ROOT/catalog/Pages/Index.cshtml.cs" 2>/dev/null \
        && info "Redis cart code is commented out - 'add to cart' is a no-op. No Redis server required."
}

# ========================================================== 4. STAND IT UP ====
build_project() {
    info "Building..."
    # NETSDK1206 (Alpine-only SQLite runtime pack) is expected and harmless.
    dotnet build "$SOLUTION" --nologo >"$LOG" 2>&1
}

start_app() {
    info "Starting the app on http://localhost:$PORT ..."
    (
        cd "$REPO_ROOT" || exit 1
        ASPNETCORE_ENVIRONMENT=Development \
        ASPNETCORE_URLS="http://localhost:$PORT" \
        DOTNET_CLI_TELEMETRY_OPTOUT=1 \
        nohup dotnet run --project "$PROJECT" --no-launch-profile --no-build >>"$LOG" 2>&1 &
        echo $! >"$PID_FILE"
    )
    sleep 1
    APP_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$APP_PID" ]] || return 1
    return 0
}

health_check() {
    step "Checking the health of the project"
    local waited=0 body
    while (( waited < HEALTH_TIMEOUT )); do
        if [[ -n "$APP_PID" ]] && ! kill -0 "$APP_PID" 2>/dev/null; then
            fail "The app process exited while starting up."
            return 1
        fi
        if body="$(http_body "http://localhost:$PORT/")"; then
            if [[ "$body" == *"$HEALTH_MARKER"* || "$body" == *"ReadIt!"* ]]; then
                ok "Home page responded with the expected content"
                if http_body "http://localhost:$PORT/Weather" >/dev/null 2>&1; then
                    ok "Weather page responded"
                else
                    warn "The /Weather page did not respond (it needs a separate weather service)."
                fi
                return 0
            fi
            warn "The server answered but the page content was unexpected."
            return 1
        elif [[ $? -eq 2 ]]; then
            # no curl/wget: fall back to a TCP probe
            port_in_use "$PORT" && { ok "Port $PORT is accepting connections (content not verified)"; return 0; }
        fi
        sleep 2; waited=$(( waited + 2 ))
        (( waited % 10 == 0 )) && info "...still waiting (${waited}s / ${HEALTH_TIMEOUT}s)"
    done
    fail "The app did not become healthy within ${HEALTH_TIMEOUT}s."
    return 1
}

try_stand_up() {                # build + start + health check; 0 = healthy
    : >"$LOG"
    if ! build_project; then
        fail "Build failed."
        return 1
    fi
    ok "Build succeeded"
    start_app || { fail "Could not launch the app process."; return 1; }
    health_check
}

# --- error classification + the two repair attempts -------------------------
log_has() { grep -qiE "$1" "$LOG" 2>/dev/null; }

# Order matters: the most specific patterns are tested first, and only
# "error NUxxxx" counts as a NuGet problem - the word "restore" shows up in
# perfectly normal build output.
describe_error() {
    if   log_has 'address already in use|Failed to bind to address';   then echo "port $PORT is already in use"
    elif log_has 'error CS[0-9]+';                                     then echo "compile error in the project source"
    elif log_has 'error NU[0-9]{4}|unable to load the service index';  then echo "NuGet restore/package problem"
    elif log_has "project\.assets\.json|doesn't have a target for";    then echo "stale or corrupt build assets"
    elif log_has 'NETSDK1045|not support targeting';                   then echo "installed .NET SDK is too old for net8.0"
    elif log_has 'dev-certs|HTTPS development certificate';            then echo "HTTPS development certificate problem"
    elif log_has 'error MSB[0-9]+';                                    then echo "build error (MSBuild)"
    elif log_has 'Unhandled exception';                                then echo "the app crashed at startup"
    else echo "unrecognised startup error"
    fi
}

apply_fix() {                   # $1 = attempt number; 0 = a fix was applied
    local attempt="$1"
    info "Diagnosis: $(describe_error)"

    stop_app >/dev/null 2>&1

    local fixed=1

    if log_has 'address already in use|Failed to bind to address'; then
        local free; free="$(find_free_port "$((PORT + 1))")"
        if [[ -n "$free" ]]; then
            info "Fix: switching from port $PORT to $free."
            PORT="$free"; fixed=0
        fi
    fi

    if log_has "error NU[0-9]{4}|unable to load the service index|project\.assets\.json|doesn't have a target for|error MSB[0-9]+"; then
        info "Fix: clearing bin/obj and forcing a clean NuGet restore."
        rm -rf "$REPO_ROOT/catalog/bin" "$REPO_ROOT/catalog/obj"
        dotnet nuget locals http-cache --clear >>"$LOG" 2>&1
        dotnet restore "$SOLUTION" --force --no-cache >>"$LOG" 2>&1
        fixed=0
    fi

    if log_has 'NETSDK1045|not support targeting'; then
        info "Fix: installing the .NET ${DOTNET_CHANNEL} SDK."
        local installer="$RUN_DIR/dotnet-install.sh"
        [[ -x "$installer" ]] || { have curl && curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$installer" && chmod +x "$installer"; }
        [[ -x "$installer" ]] && "$installer" --channel "$DOTNET_CHANNEL" --install-dir "$HOME/.dotnet" >>"$LOG" 2>&1 \
            && { PATH="$HOME/.dotnet:$PATH"; export PATH; fixed=0; }
    fi

    if log_has 'dev-certs|HTTPS development certificate'; then
        info "Fix: trusting the HTTPS dev certificate (the app itself is served over plain HTTP)."
        dotnet dev-certs https >>"$LOG" 2>&1 && fixed=0
    fi

    if log_has 'error CS[0-9]+'; then
        warn "This is a compile error in the project's own source - it needs a code fix, not a tooling fix."
    fi

    if (( fixed != 0 )); then
        # Nothing specific matched - on the first pass a clean rebuild is the
        # broadest safe remedy; on the second there is nothing left to try.
        if (( attempt == 1 )); then
            info "Fix: no specific cause matched - doing a full clean, restore and rebuild."
            dotnet clean "$SOLUTION" >>"$LOG" 2>&1
            rm -rf "$REPO_ROOT/catalog/bin" "$REPO_ROOT/catalog/obj"
            dotnet restore "$SOLUTION" --force >>"$LOG" 2>&1
            fixed=0
        else
            fail "No further automatic fix is available for this error."
        fi
    fi

    return $fixed
}

quit_with_error() {
    printf '\n%s================ THE PROJECT COULD NOT BE STARTED ================%s\n' "$C_RED$C_BOLD" "$C_RESET" >&2
    fail "Error: $(describe_error)"
    printf '\n%sLast lines of the build/run output (%s):%s\n' "$C_BOLD" "${LOG#$REPO_ROOT/}" "$C_RESET" >&2
    printf -- '-----------------------------------------------------------------\n' >&2
    local errors
    errors="$(grep -oE '(error|warning) [A-Z]+[0-9]+:.*' "$LOG" 2>/dev/null | sort -u | head -n 12)"
    if [[ -n "$errors" ]]; then
        printf '%s\n' "$errors" >&2
    else
        tail -n 15 "$LOG" >&2 2>/dev/null || true
    fi
    printf -- '-----------------------------------------------------------------\n' >&2
    printf '\nTried to fix the error %d time(s) without success. Quitting.\n' "$MAX_FIX_ATTEMPTS" >&2
    stop_app >/dev/null 2>&1
    exit 1
}

print_success() {
    printf '\n%s================================================================%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    printf '%s  The project is healthy and running.%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    printf '\n  Home page:  %shttp://localhost:%s/%s\n' "$C_BOLD" "$PORT" "$C_RESET"
    printf '  Weather:    http://localhost:%s/Weather\n' "$PORT"
    printf '\n  Tip: the catalog starts empty - press "Load Books" on the home page to seed it.\n'
    printf '  Logs:  %s\n' "${LOG#$REPO_ROOT/}"
    printf '  Stop:  ./setup.sh --stop\n'
    printf '%s================================================================%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
}

# ==================================================================== main ====
printf '%sReadIt! catalog - setup%s\n' "$C_BOLD" "$C_RESET"
info "Repository: $REPO_ROOT"

ensure_dotnet_sdk
ensure_packages
check_server_running
check_project_condition

step "Standing up the project"
attempt=0
while true; do
    if try_stand_up; then
        print_success
        exit 0
    fi

    if (( attempt >= MAX_FIX_ATTEMPTS )); then
        quit_with_error
    fi

    attempt=$(( attempt + 1 ))
    step "Startup failed - repair attempt $attempt of $MAX_FIX_ATTEMPTS"
    if ! apply_fix "$attempt"; then
        quit_with_error
    fi
    step "Retrying startup (attempt $(( attempt + 1 )))"
done
