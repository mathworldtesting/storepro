#!/usr/bin/env bash
#
# _setup_inventory.sh - bootstrap, build, start and health-check the "ReadIt!" inventory app.
#
#   ./_setup_inventory.sh              # full setup + start on port 5002 (or next free one)
#   PORT=8080 ./_setup_inventory.sh    # start on a specific port
#   ./_setup_inventory.sh --stop       # stop an app previously started by this script
#
# What it does, in order:
#   1. checks project dependencies (.NET 8 SDK, ASP.NET Core 8 runtime, NuGet packages)
#      and installs what is missing
#   2. checks the condition of the project
#   3. builds it (one clean restore + rebuild if the first build fails)
#   4. starts it in the background, health-checks it and prints the home page URL
#
set -uo pipefail

# ---------------------------------------------------------------- configuration
APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$APP_DIR/inventory.csproj"
DOTNET_CHANNEL="8.0"                     # TargetFramework is net8.0
REQUIRED_RUNTIME="Microsoft.AspNetCore.App 8."
PORT="${PORT:-5002}"
HEALTH_TIMEOUT=90                        # seconds to wait for the home page
HEALTH_MARKER="Manage Inventory"         # string rendered by Pages/Index.cshtml
RUN_DIR="$APP_DIR/.setup"
LOG="$RUN_DIR/app.log"
PID_FILE="$RUN_DIR/app.pid"
PORT_FILE="$RUN_DIR/app.port"
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
    (exec 3<>"/dev/tcp/127.0.0.1/${p}") >/dev/null 2>&1 && return 0
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

is_inventory_app() {            # does the app on this port look like our inventory app?
    local body
    body="$(http_body "http://localhost:$1/")" || return 1
    [[ "$body" == *"$HEALTH_MARKER"* ]]
}

# ------------------------------------------------------------------ --stop mode
stop_app() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid; pid="$(cat "$PID_FILE")"
        info "Stopping app (pid $pid)..."
        kill "$pid" 2>/dev/null
        for _ in {1..10}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$pid" 2>/dev/null
        ok "Stopped."
    else
        info "No app started by this script is running."
    fi
    rm -f "$PID_FILE" "$PORT_FILE"
}

if [[ "${1:-}" == "--stop" ]]; then
    stop_app
    exit 0
fi

# ============================================================ 1. DEPENDENCIES ==
install_dotnet() {
    local installer="$RUN_DIR/dotnet-install.sh"
    local manual="Install the .NET ${DOTNET_CHANNEL} SDK manually: https://dotnet.microsoft.com/download"
    if have curl; then
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$installer" \
            || die "Could not download the .NET installer. $manual"
    elif have wget; then
        wget -qO "$installer" https://dot.net/v1/dotnet-install.sh \
            || die "Could not download the .NET installer. $manual"
    else
        die "Neither curl nor wget is available; cannot install the .NET SDK automatically. $manual"
    fi

    chmod +x "$installer"
    "$installer" --channel "$DOTNET_CHANNEL" --install-dir "$HOME/.dotnet" \
        || die "The .NET SDK installer failed. See the output above."

    PATH="$HOME/.dotnet:$PATH"; export PATH
    have dotnet || die ".NET SDK still not on PATH after install."
    info "Add this to your shell profile to keep it on PATH: export PATH=\"\$HOME/.dotnet:\$PATH\""
}

ensure_dotnet() {
    step "Checking project dependencies"

    # ~/.dotnet is where dotnet-install.sh puts a user-local SDK
    [[ -x "$HOME/.dotnet/dotnet" ]] && PATH="$HOME/.dotnet:$PATH"
    export PATH
    export DOTNET_CLI_TELEMETRY_OPTOUT=1
    export DOTNET_NOLOGO=1

    if have dotnet && grep -q "^${DOTNET_CHANNEL}\." <<<"$(dotnet --list-sdks 2>/dev/null)"; then
        ok ".NET ${DOTNET_CHANNEL} SDK is installed ($(dotnet --version 2>/dev/null))"
    else
        warn ".NET ${DOTNET_CHANNEL} SDK is not installed (project targets net8.0). Installing it..."
        install_dotnet
        ok ".NET SDK installed ($(dotnet --version 2>/dev/null))"
    fi

    # The app self-hosts Kestrel, so "the server" is the ASP.NET Core runtime
    # that ships with the SDK - there is no separate IIS/nginx to install.
    if grep -q "$REQUIRED_RUNTIME" <<<"$(dotnet --list-runtimes 2>/dev/null)"; then
        ok "ASP.NET Core 8 runtime is installed"
    else
        warn "ASP.NET Core 8 runtime is missing. Installing the .NET ${DOTNET_CHANNEL} SDK to provide it..."
        install_dotnet
        grep -q "$REQUIRED_RUNTIME" <<<"$(dotnet --list-runtimes 2>/dev/null)" \
            || die "ASP.NET Core 8 runtime still not available."
        ok "ASP.NET Core 8 runtime installed"
    fi
}

packages_restored() {
    local assets="$APP_DIR/obj/project.assets.json"
    [[ -f "$assets" && "$assets" -nt "$PROJECT" ]]
}

ensure_packages() {
    # NuGet is the only package manager this project uses - no Node/npm tooling.
    if packages_restored; then
        ok "NuGet packages are restored"
        return 0
    fi

    warn "NuGet packages are not restored. Restoring..."
    if dotnet restore "$PROJECT" >"$RUN_DIR/restore.log" 2>&1; then
        ok "NuGet packages restored"
    else
        tail -n 25 "$RUN_DIR/restore.log" >&2
        die "dotnet restore failed (full log: $RUN_DIR/restore.log)"
    fi
}

# ====================================================== 2. PROJECT CONDITION ==
check_project_condition() {
    step "Checking the condition of the project"

    [[ -f "$PROJECT" ]] || die "Project file not found: $PROJECT"
    ok "Project file found: ${PROJECT##*/}"

    have curl || have wget || warn "Neither curl nor wget found - the health check will fall back to a TCP probe."

    # Known, non-blocking quirks of this app.
    grep -q '"BooksDB"[[:space:]]*:[[:space:]]*"<' "$APP_DIR/appsettings.json" 2>/dev/null \
        && warn "appsettings.json holds a placeholder BooksDB connection string - the page renders, but saving needs SQL Server."
    grep -qE '^[[:space:]]*//[[:space:]]*books=_context\.Books\.ToList' "$APP_DIR/Pages/Index.cshtml.cs" 2>/dev/null \
        && info "The book list read is still commented out (UNCOMMENT AFTER SETTING THE CONNECTION STRING) - the page shows no books."
}

check_already_running() {
    step "Checking whether the app is already running"

    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid running_port
        pid="$(cat "$PID_FILE")"
        running_port="$(cat "$PORT_FILE" 2>/dev/null || printf '%s' "$PORT")"
        if is_inventory_app "$running_port"; then
            PORT="$running_port"
            ok "The inventory app is already running (pid $pid)"
            print_success
            exit 0
        fi
        warn "A previous app process (pid $pid) is alive but not answering. Stopping it."
        stop_app
    fi

    if port_in_use "$PORT"; then
        if is_inventory_app "$PORT"; then
            ok "The inventory app is already running on port $PORT (not started by this script)"
            print_success
            exit 0
        fi
        warn "Port $PORT is taken by something else."
        local free; free="$(find_free_port "$((PORT + 1))")" \
            || die "No free port found near $PORT. Re-run with PORT=<port> ./_setup_inventory.sh"
        PORT="$free"
        info "Using port $PORT instead."
    else
        info "Not running yet - it will be started below."
    fi
}

# ================================================================== 3. BUILD ==
print_build_errors() {
    local errors
    errors="$(grep -oE 'error [A-Z]+[0-9]+:.*' "$LOG" 2>/dev/null | sort -u | head -n 12)"
    if [[ -n "$errors" ]]; then
        printf '%s\n' "$errors" >&2
    else
        tail -n 15 "$LOG" >&2 2>/dev/null || true
    fi
}

build_project() {
    step "Building the project"

    if dotnet build "$PROJECT" --nologo >"$LOG" 2>&1; then
        ok "Build succeeded"
        return 0
    fi

    # A compile error needs a code fix; a clean restore will not help.
    if grep -qE 'error CS[0-9]+' "$LOG"; then
        print_build_errors
        die "Build failed with compile errors (full log: $LOG)"
    fi

    warn "Build failed. Clearing bin/obj and retrying with a clean restore..."
    rm -rf "$APP_DIR/bin" "$APP_DIR/obj"
    if dotnet restore "$PROJECT" --force >"$LOG" 2>&1 && dotnet build "$PROJECT" --nologo >>"$LOG" 2>&1; then
        ok "Build succeeded after a clean restore"
        return 0
    fi

    print_build_errors
    die "Build failed (full log: $LOG)"
}

# ================================================================= 4. LAUNCH ==
start_app() {
    step "Starting the app"
    info "Launching on http://localhost:$PORT ..."
    (
        cd "$APP_DIR" || exit 1
        ASPNETCORE_ENVIRONMENT=Development \
        ASPNETCORE_URLS="http://localhost:$PORT" \
        nohup dotnet run --project "$PROJECT" --no-launch-profile --no-build >>"$LOG" 2>&1 &
        echo $! >"$PID_FILE"
    )
    printf '%s' "$PORT" >"$PORT_FILE"
    sleep 1
    APP_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$APP_PID" ]] || die "Could not launch the app process."
}

health_check() {
    step "Checking the health of the app"
    local waited=0 body
    while (( waited < HEALTH_TIMEOUT )); do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            fail "The app process exited while starting up."
            return 1
        fi
        if body="$(http_body "http://localhost:$PORT/")"; then
            if [[ "$body" == *"$HEALTH_MARKER"* ]]; then
                ok "Home page responded with the expected content"
                return 0
            fi
            fail "The server answered but the page content was unexpected."
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

print_success() {
    printf '\n%s================================================================%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    printf '%s  The inventory app is healthy and running.%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    printf '\n  Home page:  %shttp://localhost:%s/%s\n' "$C_BOLD" "$PORT" "$C_RESET"
    printf '\n  Tip: the page stays empty until BooksDB is set and the read in Pages/Index.cshtml.cs is uncommented.\n'
    printf '  Logs:  %s\n' "$LOG"
    printf '  Stop:  ./_setup_inventory.sh --stop\n'
    printf '%s================================================================%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
}

# ==================================================================== main ====
printf '%sReadIt! inventory - setup%s\n' "$C_BOLD" "$C_RESET"
info "Project: $APP_DIR"

ensure_dotnet
ensure_packages
check_project_condition
check_already_running
build_project
start_app

if health_check; then
    print_success
    exit 0
fi

printf '\n%sLast lines of the build/run output (%s):%s\n' "$C_BOLD" "$LOG" "$C_RESET" >&2
tail -n 20 "$LOG" >&2 2>/dev/null || true
stop_app >/dev/null 2>&1
die "The inventory app could not be started."
