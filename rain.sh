#!/usr/bin/env bash
# rain.sh — dev + simulation orchestrator for the rain tutorial.
#
# Wraps the build → init → cluster lifecycle in a small set of verbs so
# partners don't need to memorize docker compose flags. Everything under
# the hood is standard docker compose — open this file to see exactly
# what runs at each step.

set -euo pipefail

cd "$(dirname "$0")"

# --- Constants ------------------------------------------------------------

readonly PROJECT="rain-tutorial"
readonly DEV_CONTAINER="${PROJECT}-dev"
readonly SERVER_COUNT=6
readonly DIRECTORY_FILE="nodes/shared/directory"

# --- Colors (only when writing to a tty) ---------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    BOLD=$(tput bold);      DIM=$(tput dim);        RESET=$(tput sgr0)
    GREEN=$(tput setaf 2);  YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
    BLUE=$(tput setaf 4);   CYAN=$(tput setaf 6)
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""; BLUE=""; CYAN=""
fi

# --- Output helpers ------------------------------------------------------

step() { printf "${BOLD}${BLUE}➜${RESET} ${BOLD}%s${RESET}\n" "$*"; }
info() { printf "  ${DIM}%s${RESET}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*" >&2; }
die()  { printf "${RED}✗${RESET} ${BOLD}%s${RESET}\n" "$*" >&2; exit 1; }

# --- Container inspection ------------------------------------------------

is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

container_exists() {
    docker inspect "$1" >/dev/null 2>&1
}

# --- Preconditions -------------------------------------------------------

check_env() {
    [ -f .env ] || die ".env not found — copy .env.example to .env and paste your GitHub token."
}

ensure_dev_up() {
    if is_running "$DEV_CONTAINER"; then return; fi
    step "Starting dev container"
    docker compose --progress quiet up -d dev
    ok "dev is up"
}

is_initialized() {
    [ -f "$DIRECTORY_FILE" ]
}

# --- Build & init --------------------------------------------------------

do_build() {
    step "Building server + client + init in dev (release)"
    docker compose exec -T dev cargo build --release --manifest-path /work/code/Cargo.toml
    docker compose exec -T dev cp -f \
        /work/target/release/server \
        /work/target/release/client \
        /work/target/release/init \
        /work/bin/
    ok "binaries copied to bin/"
}

do_init_if_needed() {
    if is_initialized; then
        info "cluster already initialized (${DIRECTORY_FILE} present)"
        return
    fi
    step "Initializing cluster state"
    mkdir -p nodes/shared
    for i in $(seq 0 $((SERVER_COUNT - 1))); do mkdir -p "nodes/server${i}"; done
    docker compose exec -T dev /work/bin/init
    ok "cluster initialized"
}

# --- Client launcher ----------------------------------------------------

launch_client() {
    local id=$1
    shift
    local name="${PROJECT}-client${id}"

    if is_running "$name"; then
        info "client ${id} already running"
        return
    fi
    if container_exists "$name"; then
        docker rm -f "$name" >/dev/null
    fi

    mkdir -p "nodes/client${id}"

    # Use `docker run -d -it` (bypassing compose) to guarantee PTY allocation
    # even with detached mode + redirected stdio — otherwise `docker attach`
    # later would connect to a non-PTY stdin and detach keys wouldn't work.
    docker run -d -it \
        --name "$name" \
        --network "${PROJECT}_default" \
        --entrypoint "" \
        -v "${PWD}/bin:/work/bin:ro" \
        -v "${PWD}/nodes/shared:/shared:ro" \
        -v "${PWD}/nodes/client${id}:/state" \
        -e "NODE_ID=client${id}" \
        -w /state \
        rain-tutorial-dev \
        /work/bin/client "$@" >/dev/null
    ok "client ${id} started"
}

# --- Commands ------------------------------------------------------------

cmd_up() {
    check_env

    local target="${1:-}"

    if [ -n "$target" ]; then
        # Single-server path — bring one specific server up

        [[ "$target" =~ ^[0-9]+$ ]] || die "server id must be a non-negative integer (got '$target')"
        [ "$target" -lt "$SERVER_COUNT" ] || die "server id must be < ${SERVER_COUNT} (got '$target')"

        local name="${PROJECT}-server${target}"
        if is_running "$name"; then
            ok "server ${target} already running"
            printf "\n"; cmd_status
            return
        fi

        is_initialized || die "cluster not initialized — run './rain.sh up' (no arg) first"
        [ -f bin/server ] || die "no server binary — run './rain.sh up' (no arg) first"

        step "Starting server ${target}"
        docker compose --progress quiet up -d "server${target}"
        ok "server ${target} up"
        printf "\n"; cmd_status
        return
    fi

    # All-servers path — idempotent: no-op if all already running

    local all=true
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        is_running "${PROJECT}-server${i}" || { all=false; break; }
    done
    if $all; then
        ok "all ${SERVER_COUNT} servers already running — nothing to do"
        printf "\n"; cmd_status
        return
    fi

    ensure_dev_up
    do_build
    do_init_if_needed

    step "Starting ${SERVER_COUNT} servers"
    docker compose --progress quiet --profile servers up -d
    ok "servers up"
    printf "\n"; cmd_status
}

sim_container_names() {
    local names=""
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        names="$names ${PROJECT}-server${i}"
    done
    local clients
    clients=$(docker ps -a --filter "name=^${PROJECT}-client[0-9]" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
    echo "$names $clients" | xargs
}

cmd_down() {
    local target="${1:-}"

    if [ -n "$target" ]; then
        # Single-server path

        [[ "$target" =~ ^[0-9]+$ ]] || die "server id must be a non-negative integer (got '$target')"
        [ "$target" -lt "$SERVER_COUNT" ] || die "server id must be < ${SERVER_COUNT} (got '$target')"

        local name="${PROJECT}-server${target}"
        if ! container_exists "$name"; then
            info "server ${target} does not exist"
            return
        fi

        step "Gracefully stopping server ${target}"
        info "SIGTERM; up to 10s (or service's stop_grace_period) for a clean exit before SIGKILL"
        docker stop "$name" >/dev/null 2>&1 || true
        docker rm "$name" >/dev/null 2>&1 || true
        ok "server ${target} torn down"
        return
    fi

    # All-sim path

    local names; names=$(sim_container_names)
    if [ -z "$names" ]; then
        info "no sim containers to stop"
        return
    fi
    local count; count=$(echo "$names" | wc -w | tr -d ' ')
    step "Gracefully stopping ${count} sim container(s)"
    info "SIGTERM to each; up to 10s (or service's stop_grace_period) for a clean exit before SIGKILL"
    # shellcheck disable=SC2086
    docker stop $names >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    docker rm $names >/dev/null 2>&1 || true
    ok "sim torn down (dev remains up)"
}

cmd_kill() {
    local target="${1:-}"

    if [ -n "$target" ]; then
        # Single-server path

        [[ "$target" =~ ^[0-9]+$ ]] || die "server id must be a non-negative integer (got '$target')"
        [ "$target" -lt "$SERVER_COUNT" ] || die "server id must be < ${SERVER_COUNT} (got '$target')"

        local name="${PROJECT}-server${target}"
        if ! container_exists "$name"; then
            info "server ${target} does not exist"
            return
        fi

        step "Killing server ${target}"
        info "SIGKILL immediately — no graceful shutdown"
        docker rm -f "$name" >/dev/null 2>&1 || true
        ok "server ${target} killed"
        return
    fi

    # All-sim path

    local names; names=$(sim_container_names)
    if [ -z "$names" ]; then
        info "no sim containers to kill"
        return
    fi
    local count; count=$(echo "$names" | wc -w | tr -d ' ')
    step "Killing ${count} sim container(s)"
    info "SIGKILL immediately — no graceful shutdown"
    # shellcheck disable=SC2086
    docker rm -f $names >/dev/null 2>&1 || true
    ok "sim killed"
}

cmd_reset() {
    cmd_kill
    step "Wiping cluster state"
    rm -rf nodes/server* nodes/client* nodes/shared 2>/dev/null || true
    mkdir -p nodes
    touch nodes/.gitkeep
    ok "nodes/ wiped — next 'up' will re-initialize"
}

cmd_status() {
    printf "${BOLD}%-9s${RESET}" "dev"
    if is_running "$DEV_CONTAINER"; then
        printf "${GREEN}● up${RESET}\n"
    else
        printf "${DIM}○ down${RESET}\n"
    fi

    printf "${BOLD}%-9s${RESET}" "servers"
    local running=() exited=()
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local n="${PROJECT}-server${i}"
        if is_running "$n"; then
            running+=("$i")
        elif container_exists "$n"; then
            exited+=("$i")
        fi
    done
    if [ ${#running[@]} -eq 0 ]; then
        if [ ${#exited[@]} -gt 0 ]; then
            printf "${DIM}○ none running   (exited: %s)${RESET}\n" "$(IFS=' '; echo "${exited[*]}")"
        else
            printf "${DIM}○ none${RESET}\n"
        fi
    else
        printf "${GREEN}●${RESET} %s   ${DIM}(%d/%d running" \
            "$(IFS=' '; echo "${running[*]}")" "${#running[@]}" "$SERVER_COUNT"
        [ ${#exited[@]} -gt 0 ] && printf ", exited: %s" "$(IFS=' '; echo "${exited[*]}")"
        printf ")${RESET}\n"
    fi

    printf "${BOLD}%-9s${RESET}" "clients"
    local running_ids exited_ids
    running_ids=$(docker ps --filter "name=^${PROJECT}-client[0-9]" --format '{{.Names}}' 2>/dev/null \
                  | sed "s/${PROJECT}-client//" | sort -n | tr '\n' ' ')
    exited_ids=$(docker ps -a --filter "name=^${PROJECT}-client[0-9]" --filter "status=exited" --format '{{.Names}}' 2>/dev/null \
                 | sed "s/${PROJECT}-client//" | sort -n | tr '\n' ' ')
    running_ids=$(echo "$running_ids" | xargs)
    exited_ids=$(echo "$exited_ids" | xargs)
    if [ -z "$running_ids" ]; then
        if [ -n "$exited_ids" ]; then
            printf "${DIM}○ none running   (exited: %s)${RESET}\n" "$exited_ids"
        else
            printf "${DIM}○ none${RESET}\n"
        fi
    else
        local nr; nr=$(echo "$running_ids" | wc -w | tr -d ' ')
        printf "${GREEN}●${RESET} %s   ${DIM}(%d running" "$running_ids" "$nr"
        [ -n "$exited_ids" ] && printf ", exited: %s" "$exited_ids"
        printf ")${RESET}\n"
    fi

    printf "${BOLD}%-9s${RESET}" "init"
    if is_initialized; then
        printf "${GREEN}● initialized${RESET}\n"
    else
        printf "${DIM}○ not initialized${RESET}\n"
    fi
}

cmd_dev() {
    ensure_dev_up
    docker compose exec dev bash
}

cmd_client() {
    local attach=false
    if [ "${1:-}" = "-t" ]; then attach=true; shift; fi
    local id="${1:-}"
    [ -n "$id" ] || die "usage: rain.sh client [-t] N [-- ARGS]"
    case "$id" in
        *..*) die "client takes a single id. For a range, use: rain.sh clients A..B" ;;
    esac
    [[ "$id" =~ ^[0-9]+$ ]] || die "client id must be a non-negative integer (got '$id')"
    shift

    if [ "${1:-}" = "--" ]; then
        shift
    elif [ -n "${1:-}" ]; then
        die "unexpected argument '$1' — use '--' to forward args to the client"
    fi

    check_env
    ensure_dev_up
    is_initialized || die "cluster not initialized — run './rain.sh up' first"

    local name="${PROJECT}-client${id}"

    if $attach; then
        # Foreground compose run — cleaner tty + detach-key handling than
        # `run -d` followed by `docker attach`
        if is_running "$name"; then
            ok "client ${id} already running — attaching (Ctrl+P Ctrl+Q to detach)"
            docker attach --detach-keys="ctrl-p,ctrl-q" "$name" \
                2> >(grep -v 'read escape sequence' >&2)
        else
            container_exists "$name" && docker rm -f "$name" >/dev/null
            mkdir -p "nodes/client${id}"
            step "Launching client ${id} attached (Ctrl+P Ctrl+Q to detach)"
            # `docker compose run` doesn't accept --detach-keys, but its
            # foreground attach honors docker's default sequence (Ctrl+P Ctrl+Q)
            COMPOSE_IGNORE_ORPHANS=1 docker compose --progress quiet run \
                --name "$name" \
                -e "NODE_ID=client${id}" \
                -v "${PWD}/nodes/client${id}:/state" \
                client /work/bin/client "$@"
        fi
    else
        step "Launching client ${id}"
        launch_client "$id" "$@"
    fi
}

cmd_clients() {
    local range="${1:-}"
    [ -n "$range" ] || die "usage: rain.sh clients A..B [-- ARGS]"
    [[ "$range" =~ ^([0-9]+)\.\.([0-9]+)$ ]] \
        || die "range must be A..B, e.g. 0..5 (got '$range')"
    local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
    [ "$a" -le "$b" ] || die "start ($a) must be ≤ end ($b)"
    shift

    if [ "${1:-}" = "--" ]; then
        shift
    elif [ -n "${1:-}" ]; then
        die "unexpected argument '$1' — use '--' to forward args to the clients"
    fi

    check_env
    ensure_dev_up
    is_initialized || die "cluster not initialized — run './rain.sh up' first"

    step "Launching clients ${a}..${b} ($((b - a + 1)) total)"
    for i in $(seq "$a" "$b"); do launch_client "$i" "$@"; done
    ok "all clients up"
}

cmd_attach() {
    local id="${1:-}"
    [ -n "$id" ] || die "usage: rain.sh attach N"
    [[ "$id" =~ ^[0-9]+$ ]] || die "client id must be a non-negative integer (got '$id')"
    local name="${PROJECT}-client${id}"
    is_running "$name" || die "client ${id} is not running (start it: rain.sh client ${id})"
    ok "attaching to client ${id} (Ctrl+P Ctrl+Q to detach)"
    docker attach --detach-keys="ctrl-p,ctrl-q" "$name" \
        2> >(grep -v 'read escape sequence' >&2)
}

cmd_logs() {
    local kind="${1:-}"
    local id="${2:-}"
    case "$kind" in
        dev)
            container_exists "$DEV_CONTAINER" || die "dev container does not exist"
            docker logs -f "$DEV_CONTAINER"
            ;;
        server)
            [ -n "$id" ] || die "usage: rain.sh logs server N"
            [[ "$id" =~ ^[0-9]+$ ]] || die "server id must be a non-negative integer (got '$id')"
            local name="${PROJECT}-server${id}"
            container_exists "$name" || die "server ${id} does not exist (has 'rain.sh up' been run?)"
            docker logs -f "$name"
            ;;
        client)
            [ -n "$id" ] || die "usage: rain.sh logs client N"
            [[ "$id" =~ ^[0-9]+$ ]] || die "client id must be a non-negative integer (got '$id')"
            local name="${PROJECT}-client${id}"
            container_exists "$name" || die "client ${id} does not exist"
            docker logs -f "$name"
            ;;
        *)
            die "usage: rain.sh logs <dev | server N | client N>"
            ;;
    esac
}

cmd_help() {
    cat <<HELP
${BOLD}rain${RESET} — dev + simulation orchestrator for the rain tutorial

${BOLD}Usage:${RESET} ./rain.sh <command> [args]

${BOLD}Cluster${RESET}
  ${CYAN}up${RESET} ${DIM}[N]${RESET}                Build+init if needed, start all servers (or just server N)
  ${CYAN}down${RESET} ${DIM}[N]${RESET}              Gracefully stop sim containers (or just server N); dev stays
  ${CYAN}kill${RESET} ${DIM}[N]${RESET}              SIGKILL sim containers (or just server N)
  ${CYAN}reset${RESET}                  Kill sim + wipe cluster state; next 'up' re-initializes
  ${CYAN}status${RESET}                 Show what's currently running

${BOLD}Clients${RESET}
  ${CYAN}client N${RESET} ${DIM}[-- ARGS]${RESET}      Spawn client N in the background; ARGS pass to the client binary
  ${CYAN}client -t N${RESET} ${DIM}[-- ARGS]${RESET}   Spawn client N and attach interactively
  ${CYAN}clients A..B${RESET} ${DIM}[-- ARGS]${RESET}  Spawn clients A through B (inclusive), background
  ${CYAN}attach N${RESET}               Attach to already-running client N

${BOLD}Dev${RESET}
  ${CYAN}dev${RESET}                    Enter a shell inside the dev container

${BOLD}Logs${RESET}
  ${CYAN}logs dev${RESET}               Follow logs of the dev container
  ${CYAN}logs server N${RESET}          Follow logs of server N
  ${CYAN}logs client N${RESET}          Follow logs of client N

${DIM}Detach from a client:  Ctrl+P Ctrl+Q  (client keeps running)${RESET}
${DIM}Remove a single client:  docker rm -f ${PROJECT}-clientN${RESET}
HELP
}

# --- Dispatch ------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        up)             cmd_up      "$@" ;;
        down)           cmd_down    "$@" ;;
        kill)           cmd_kill    "$@" ;;
        reset)          cmd_reset   "$@" ;;
        status)         cmd_status  "$@" ;;
        dev)            cmd_dev     "$@" ;;
        client)         cmd_client  "$@" ;;
        clients)        cmd_clients "$@" ;;
        attach)         cmd_attach  "$@" ;;
        logs)           cmd_logs    "$@" ;;
        help|-h|--help) cmd_help          ;;
        *)              printf "${RED}unknown command:${RESET} %s\n\n" "$cmd" >&2; cmd_help >&2; exit 2 ;;
    esac
}

main "$@"
