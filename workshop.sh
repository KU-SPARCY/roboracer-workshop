#!/usr/bin/env bash
# Start, pause, restart, evaluate or stop the workshop on Linux/macOS (or Git Bash).
# The containers match workshop.ps1; the simulator is not downloaded here, so pass
# --simulator PATH to launch one, or start the simulator yourself.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime="$root/.runtime"
session="$runtime/session.env"
compose=(docker compose --project-name autodrive-workshop --project-directory "$root"
         -f "$root/compose.yaml")

usage() {
    cat <<'EOF'
Start Docker with Linux containers, then:
  ./workshop.sh start                        Start the bridge and your controller.py
  ./workshop.sh start --controller example   Run the supplied teaching example
  ./workshop.sh pause                        Stop the controller; leave simulator open
  ./workshop.sh restart --controller starter Reload your code and resume
  ./workshop.sh evaluate                     Reset the car, drive 3 laps (or until a crash)
                                             and report lap times and speeds
  ./workshop.sh stop                         Stop workshop containers and its simulator
  ./workshop.sh status                       Inspect containers
  ./workshop.sh logs --follow                Follow controller and bridge logs
  ./workshop.sh test                         Run launcher checks, then Python checks in a container
  ./workshop.sh test --launcher              Run only the launcher checks (no Docker needed)
start also accepts --simulator PATH to launch the simulator executable.
evaluate also accepts --laps 3 and --timeout 300 (seconds); results go to .runtime/results.
Save edits before restart. Without --controller, the previous selection is reused.
EOF
}

fail() { echo "$*" >&2; exit 1; }

action="${1:-start}"
[ $# -gt 0 ] && shift
controller="" simulator="" laps=3 timeout=300 follow=0 launcher_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --controller) controller="${2:-}"; shift 2 ;;
        --simulator) simulator="${2:-}"; shift 2 ;;
        --laps) laps="${2:-}"; shift 2 ;;
        --timeout) timeout="${2:-}"; shift 2 ;;
        --follow) follow=1; shift ;;
        --launcher) launcher_only=1; shift ;;
        *) fail "Unknown option: $1 (see ./workshop.sh help)" ;;
    esac
done
case "$action" in
    start|pause|restart|evaluate|stop|status|logs|test) ;;
    help|-h|--help) usage; exit 0 ;;
    *) fail "Unknown action: $action (see ./workshop.sh help)" ;;
esac
case "$controller" in ""|starter|example) ;; *) fail "--controller must be starter or example" ;; esac
[[ "$laps" =~ ^[0-9]+$ ]] && [ "$laps" -ge 1 ] && [ "$laps" -le 100 ] \
    || fail "--laps must be 1-100"
[[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -ge 10 ] && [ "$timeout" -le 3600 ] \
    || fail "--timeout must be 10-3600 seconds"

saved() { [ -f "$session" ] && sed -n "s/^$1=//p" "$session" | head -n 1 || true; }
saved_controller="$(saved controller)"
executable="$(saved executable)"
process_id="$(saved process_id)"
controller="${controller:-${saved_controller:-starter}}"
case "$controller" in starter|example) ;; *) fail "Invalid workshop session file." ;; esac
if [ "$controller" = example ]; then
    export WORKSHOP_CONTROLLER=examples.follow_the_gap
else
    export WORKSHOP_CONTROLLER=controller
fi

save_session() {
    mkdir -p "$runtime"
    printf 'controller=%s\nexecutable=%s\nprocess_id=%s\n' \
        "$controller" "$executable" "$process_id" > "$session"
}
simulator_running() { [ -n "$process_id" ] && kill -0 "$process_id" 2>/dev/null; }
bridge_running() { [ -n "$("${compose[@]}" ps --status running -q bridge)" ]; }
stop_controller() {
    # Keep the bridge alive long enough to transmit stopped commands or expire them.
    "${compose[@]}" stop controller
    sleep 0.7
}
reload_controller() {
    bridge_running || fail "Start the workshop first: ./workshop.sh start"
    stop_controller
    "${compose[@]}" up -d --no-deps --force-recreate controller
    save_session
}

# Exercise this launcher against a fake docker in a throwaway copy; nothing real runs.
# The port 4567 check is not mocked, so another bridge on that port fails the start check.
launcher_selftest() (
    fixture_root="$runtime/launcher-tests/$$-$RANDOM"
    fixture="$fixture_root/folder with spaces"
    sim_pid=""
    trap '[ -z "$sim_pid" ] || kill "$sim_pid" 2>/dev/null || true; rm -rf "$fixture_root"' EXIT
    mkdir -p "$fixture/bin"
    cp "$root/workshop.sh" "$root/compose.yaml" "$fixture/"
    export SELFTEST_DIR="$fixture" PATH="$fixture/bin:$PATH" WORKSHOP_CONTROLLER=previous-value
    cat > "$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$WORKSHOP_CONTROLLER" "$*" >> "$SELFTEST_DIR/docker.log"
[ -f "$SELFTEST_DIR/docker-fails" ] && exit 1
case " $* " in
    " info "*) echo linux ;;
    *" run "*) exit "$(cat "$SELFTEST_DIR/eval-exit" 2>/dev/null || echo 0)" ;;
    *" ps "*" -q "*) [ -f "$SELFTEST_DIR/bridge" ] && echo fixture-bridge ;;
    *" up "*) touch "$SELFTEST_DIR/bridge" ;;
    *" down "*) rm -f "$SELFTEST_DIR/bridge" ;;
esac
exit 0
EOF
    sim="$fixture/AutoDRIVE Simulator"
    printf '#!/bin/sh\nexec sleep 60\n' > "$sim"
    chmod +x "$fixture/bin/docker" "$sim"
    log="$fixture/docker.log"
    launch() { bash "$fixture/workshop.sh" "$@" >/dev/null 2>&1; }
    check() { eval "$1" || fail "FAIL: $2"; }
    saved_value() { sed -n "s/^$1=//p" "$fixture/.runtime/session.env"; }
    : > "$log"

    check 'launch help' "Help failed"
    check '[ ! -s "$log" ]' "Help contacted Docker"
    check '! launch restart' "Restart created a missing bridge"
    check '! launch evaluate' "Evaluate ran without a bridge"
    check '! launch start --bogus' "Unknown option was accepted"

    check 'launch start --simulator "$sim" --controller example' "Start failed"
    sim_pid="$(saved_value process_id)"
    check '[ "$(saved_value controller)" = example ]' "Controller selection was not saved"
    check '[ "$(saved_value executable)" = "$sim" ]' "Simulator path was not saved"
    check 'kill -0 "$sim_pid" 2>/dev/null' "Simulator was not launched"

    : > "$log"
    check 'launch restart' "Restart failed"
    check 'grep -E " (stop|up) " "$log" | head -n 1 | grep -q " stop "' "Reload did not stop old controller first"
    check 'grep " up " "$log" | grep -q -- "--no-deps"' "Reload could replace bridge"
    check 'grep " up " "$log" | grep -q "^examples.follow_the_gap|"' "Reload forgot selected example"

    : > "$log"
    check 'launch evaluate --laps 2' "Evaluate failed"
    run="$(grep " run " "$log")"
    check '[ "$(printf "%s\n" "$run" | wc -l)" -eq 1 ]' "Evaluate did not run the evaluator once"
    check 'case "$run" in *"--no-deps evaluator"*) ;; *) false ;; esac' "Evaluate did not run the evaluator alone"
    check 'case "$run" in *"--controller examples.follow_the_gap"*) ;; *) false ;; esac' "Evaluate used the wrong controller"
    check 'case "$run" in *"--laps 2 "*) ;; *) false ;; esac' "Evaluate ignored --laps"
    check 'tail -n 1 "$log" | grep -q " stop controller"' "Evaluate left the controller driving"
    echo 3 > "$fixture/eval-exit"
    check 'launch evaluate' "Unfinished run was reported as a failure"
    echo 2 > "$fixture/eval-exit"
    check '! launch evaluate' "Evaluation setup failure was hidden"
    check 'tail -n 1 "$log" | grep -q " stop controller"' "Failed evaluation left the controller driving"
    rm -f "$fixture/eval-exit"

    check 'launch restart --controller starter' "Switching controller failed"
    check '[ "$(saved_value controller)" = starter ]' "Could not switch back to participant code"
    check 'launch pause' "Pause failed"
    check 'kill -0 "$sim_pid" 2>/dev/null' "Pause closed the simulator"
    check 'launch stop' "Stop failed"
    sleep 0.2
    check '! kill -0 "$sim_pid" 2>/dev/null' "Stop left owned simulator open"
    touch "$fixture/docker-fails"
    check '! launch status' "Docker errors were hidden"
    echo "PASS: paths, reload, evaluate, selection, pause, stop and Docker failures"
)

case "$action" in
    test)
        launcher_selftest
        [ "$launcher_only" = 1 ] && exit 0 ;;
    status) "${compose[@]}" ps -a; exit 0 ;;
    logs)
        options=(--tail 100)
        [ "$follow" = 1 ] && options+=(--follow)
        "${compose[@]}" logs "${options[@]}" controller bridge
        exit 0 ;;
    pause|stop)
        stop_controller
        if [ "$action" = stop ]; then
            simulator_running && kill "$process_id" 2>/dev/null || true
            "${compose[@]}" down
            process_id=""
            save_session
        fi
        echo "Workshop controller stopped."
        exit 0 ;;
esac

[ "$(docker info --format '{{.OSType}}' 2>/dev/null)" = linux ] \
    || fail "Start Docker and select Linux containers, then retry."

case "$action" in
    test)
        echo "Running Python checks in a container..."
        docker run --rm --network none --env PYTHONDONTWRITEBYTECODE=1 \
            --volume "$root:/workshop:ro" --workdir /workshop --entrypoint python3 \
            autodriveecosystem/autodrive_roboracer_api:2026-icra-practice \
            -m unittest discover -s tests -v || fail "Workshop tests failed."
        exit 0 ;;
    restart)
        reload_controller
        echo "Reloaded $controller. Driving resumes when Autonomous is selected."
        exit 0 ;;
    evaluate)
        reload_controller
        mkdir -p "$runtime/results"
        # Leave the car stopped after every run, including Ctrl+C.
        trap '"${compose[@]}" stop controller >/dev/null 2>&1' EXIT
        status=0
        "${compose[@]}" --profile evaluate run --rm --no-deps evaluator \
            python3 -m runtime.evaluate --controller "$WORKSHOP_CONTROLLER" \
            --laps "$laps" --timeout "$timeout" || status=$?
        if [ "$status" = 3 ]; then
            echo "Run ended before all laps were completed."
        elif [ "$status" != 0 ]; then
            fail "Evaluation failed; check ./workshop.sh logs."
        fi
        exit 0 ;;
esac

# start
if ! bridge_running && (exec 3<>/dev/tcp/127.0.0.1/4567) 2>/dev/null; then
    fail "Port 4567 is in use. Stop the main project or other simulator bridge first."
fi
if [ -n "$simulator" ]; then
    [ -f "$simulator" ] || fail "Simulator executable not found: $simulator"
    simulator="$(cd "$(dirname "$simulator")" && pwd)/$(basename "$simulator")"
    if simulator_running && [ "$simulator" != "$executable" ]; then
        fail "Stop the workshop before selecting another simulator executable."
    fi
    executable="$simulator"
fi
"${compose[@]}" up -d bridge controller
if [ -n "$executable" ] && ! simulator_running; then
    [ -f "$executable" ] || fail "Saved simulator path is missing. Supply --simulator PATH."
    mkdir -p "$runtime"
    (cd "$(dirname "$executable")" && exec "$executable" -screen-fullscreen 0 \
        -screen-width 1280 -screen-height 720 -ip 127.0.0.1 -port 4567 \
        -logFile "$runtime/simulator.log") >/dev/null 2>&1 &
    process_id=$!
fi
save_session
echo "Workshop running with $controller. In the simulator select Connection (127.0.0.1:4567) and Autonomous."
[ -z "$executable" ] && echo "No simulator launched; start it yourself or pass --simulator PATH."
echo "The starter stays stopped until you implement controller.py. Pause with ./workshop.sh pause."
