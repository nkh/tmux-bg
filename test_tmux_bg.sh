# End-to-end tests for the patched tmux-bg, driven through a fake tmux
# binary that records every call (no real tmux/fzf needed in the sandbox).
set -u

SCRIPT=/home/z/my-project/download/tmux-bg
WORK=/tmp/tmuxbg
FAKEBIN=$WORK/fakebin
LOG=$WORK/tmux.log

mkdir -p "$FAKEBIN" "$WORK/fakehome" "$WORK/rundir"
cd "$WORK" || exit 1

# --- fake tmux binary ------------------------------------------------
cat > "$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
LOG=${FAKE_TMUX_LOG:-/dev/null}
printf '%s\n' "$*" >> "$LOG"
case "${1:-}" in
    has-session)
        exit 0
        ;;
    display-message)
        if [[ "$*" == *-p* ]]; then
            printf '%s\n' "${FAKE_SESSION_NAME:-work}"
        fi
        exit 0
        ;;
    list-windows)
        local_w=${FAKE_WINDOWS:-}
        for w in $local_w; do printf '%s\n' "$w"; done
        exit 0
        ;;
    show-option)
        case "$*" in
            *@managed_program*)   printf '%s\n' "${FAKE_OPT_PROGRAM:-}" ;;
            *@managed_directory*) printf '%s\n' "${FAKE_OPT_DIR:-}" ;;
            *@managed_title*)     printf '%s\n' "${FAKE_OPT_TITLE:-}" ;;
            *@managed_args*)      printf '%s\n' "${FAKE_OPT_ARGS:-}" ;;
            *)                    printf '\n' ;;
        esac
        exit 0
        ;;
    list-panes)
        if [[ "$*" == *pane_dead_status* ]]; then
            printf '%s\n' "${FAKE_PANE_DEAD_STATUS:-}"
        else
            printf '%s\n' "${FAKE_PANE_DEAD:-0}"
        fi
        exit 0
        ;;
    capture-pane)
        printf '%s\n' "$FAKE_CAPTURE"
        exit 0
        ;;
    new-window|new-session)
        printf '%s\n' "${FAKE_NEW_WINDOW_ID:-%9}"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
cat > "$FAKEBIN/fzf" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s' "${FAKE_FZF_SEL:-}"
exit "${FAKE_FZF_RC:-0}"
EOF
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/fzf"
printf "alias v='cat -n'\n" > "$WORK/fakehome/.bashrc"

# --- harness ---------------------------------------------------------
reset() { : > "$LOG"; }
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
assert_log() {
    if grep -qE -- "$2" "$LOG"; then ok "$1"; else bad "$1" "log missing: $2"; fi
}
refute_log() {
    if grep -qE -- "$2" "$LOG"; then bad "$1" "log unexpectedly has: $2"; else ok "$1"; fi
}
assert_out() {
    if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1" "output missing: $2 (got: [$3])"; fi
}

ENVBASE="TMUX=fake PATH=$FAKEBIN:$PATH FAKE_TMUX_LOG=$LOG"

# 1. switch, single entry: direct switch, no popup.
reset
out=$(env $ENVBASE FAKE_WINDOWS='%1' FAKE_OPT_PROGRAM=/usr/bin/vim FAKE_OPT_DIR="$WORK" \
      bash "$SCRIPT" --session programs switch 2>&1); rc=$?
assert_log  "switch/single/switch-client"   'switch-client -t =programs'
assert_log  "switch/single/select-window"   'select-window -t %1'
refute_log  "switch/single/no-popup"        'display-popup'

# 2. switch, two entries: popup with default geometry.
reset
out=$(env $ENVBASE FAKE_WINDOWS='%1 %2' FAKE_OPT_PROGRAM=/usr/bin/vim FAKE_OPT_DIR="$WORK" \
      bash "$SCRIPT" --session programs switch 2>&1); rc=$?
assert_log  "switch/multi/popup-default-geom" 'display-popup -E -w 95% -h 90%'
assert_log  "switch/multi/popup-inner-args"   'TMUX_BG_POPUP=1 .* --session programs switch'
refute_log  "switch/multi/no-direct-switch"   'switch-client'

# 3. popup size passed as tmux-bg options.
reset
out=$(env $ENVBASE FAKE_WINDOWS='%1 %2' FAKE_OPT_PROGRAM=/usr/bin/vim FAKE_OPT_DIR="$WORK" \
      bash "$SCRIPT" --popup-width 80 --popup-height 70% --session programs switch 2>&1); rc=$?
assert_log  "switch/geom/options-honored" 'display-popup -E -w 80 -h 70%'

# 4. inside the popup (marker): picker runs, selection switches.
reset
out=$(env $ENVBASE FAKE_WINDOWS='%1 %2' FAKE_OPT_PROGRAM=/usr/bin/vim FAKE_OPT_DIR="$WORK" \
      FAKE_FZF_SEL='%2' TMUX_BG_POPUP=1 \
      bash "$SCRIPT" --session programs switch 2>&1); rc=$?
assert_log  "switch/marker/selects-fzf-choice" 'select-window -t %2'
refute_log  "switch/marker/no-rewrap"          'display-popup'

# 5. kill opens the popup itself (binding may use plain run-shell).
reset
out=$(env $ENVBASE FAKE_WINDOWS='%1' FAKE_OPT_PROGRAM=/usr/bin/vim FAKE_OPT_DIR="$WORK" \
      bash "$SCRIPT" kill 2>&1); rc=$?
assert_log  "kill/self-popup"     'display-popup -E -w 95% -h 90%'
assert_log  "kill/popup-action"   '--session programs kill'
refute_log  "kill/no-direct-kill" 'kill-window'

# 6. kill already inside a popup: picker runs, selection killed.
reset
out=$(env $ENVBASE FAKE_WINDOWS='%1' FAKE_OPT_PROGRAM=/usr/bin/vim FAKE_OPT_DIR="$WORK" \
      FAKE_FZF_SEL='%1' TMUX_BG_POPUP=1 \
      bash "$SCRIPT" kill 2>&1); rc=$?
assert_log  "kill/in-popup/kills" 'kill-window -t %1'
refute_log  "kill/in-popup/no-popup" 'display-popup'

# 7. --no-popup without a terminal: clear error, no popup.
reset
out=$(env $ENVBASE FAKE_WINDOWS='%1 %2' FAKE_OPT_PROGRAM=/usr/bin/vim FAKE_OPT_DIR="$WORK" \
      bash "$SCRIPT" --no-popup switch 2>&1); rc=$?
assert_out  "nopup/no-tty/error"   'needs a terminal' "$out"
refute_log  "nopup/no-tty/no-popup" 'display-popup'
[ "$rc" = "1" ] && ok "nopup/no-tty/rc" || bad "nopup/no-tty/rc" "rc=$rc"

# 8. --no-popup on a real terminal (pty): inline picker, no popup.
reset
cat > "$WORK/inline.sh" <<EOF
export PATH="$FAKEBIN:\$PATH" TMUX=fake FAKE_TMUX_LOG="$LOG"
export FAKE_WINDOWS='%1 %2' FAKE_OPT_PROGRAM=/usr/bin/vim FAKE_OPT_DIR="$WORK"
export FAKE_FZF_SEL='%2'
exec bash "$SCRIPT" --no-popup switch
EOF
out=$(script -qec "bash $WORK/inline.sh" /dev/null); out=${out//$'\r'/}
assert_log  "nopup/tty/inline-pick"  'select-window -t %2'
refute_log  "nopup/tty/no-popup"     'display-popup'

# 9. bad option value rejected.
reset
out=$(env $ENVBASE bash "$SCRIPT" --popup-width abc switch 2>&1); rc=$?
assert_out  "geom/bad-value/error" 'expects a size' "$out"
[ "$rc" = "1" ] && ok "geom/bad-value/rc" || bad "geom/bad-value/rc" "rc=$rc"

# 10. run with an alias (v -> cat -n) and default keep-on-exit.
reset
out=$(env $ENVBASE HOME="$WORK/fakehome" bash "$SCRIPT" run v todo.txt 2>&1); rc=$?
assert_out  "run/alias/started"        'Started v in session programs: cat - ' "$out"
assert_log  "run/alias/expansion"      'exec /usr/bin/cat -n todo.txt'
assert_log  "run/alias/remain-on-exit" 'remain-on-exit on'
assert_log  "run/alias/args-stored"    '@managed_args todo.txt'

# 11. run again with different arguments: same instance, args ignored.
reset
out=$(env $ENVBASE HOME="$WORK/fakehome" FAKE_WINDOWS='%1' FAKE_OPT_PROGRAM=/usr/bin/cat FAKE_OPT_DIR="$WORK" \
      FAKE_OPT_ARGS='todo.txt' FAKE_PANE_DEAD=0 \
      bash "$SCRIPT" run v other.txt 2>&1); rc=$?
assert_out  "run/same-instance/already-running" 'Already running: v in '"$WORK" "$out"
assert_out  "run/same-instance/args-note"       'keeping the original arguments' "$out"
refute_log  "run/same-instance/no-new-window"   'new-window'

# 12. dead leftover window is not "running": fresh instance starts.
reset
out=$(env $ENVBASE HOME="$WORK/fakehome" FAKE_WINDOWS='%1' FAKE_OPT_PROGRAM=/usr/bin/cat FAKE_OPT_DIR="$WORK" \
      FAKE_PANE_DEAD=1 FAKE_PANE_DEAD_STATUS=0 \
      bash "$SCRIPT" run v todo.txt 2>&1); rc=$?
assert_out  "run/dead/fresh-start" 'Started v in session programs' "$out"
assert_log  "run/dead/new-window"  'new-window'

# 13. process that dies at once with a failure: error is displayed.
reset
out=$(env $ENVBASE HOME="$WORK/fakehome" FAKE_PANE_DEAD=1 FAKE_PANE_DEAD_STATUS=127 \
      FAKE_CAPTURE='bash: v: command not found' \
      bash "$SCRIPT" run v todo.txt 2>&1); rc=$?
assert_out  "run/fail/error-shown" 'exited immediately \(exit 127\): bash: v: command not found' "$out"
assert_log  "run/fail/status-message" 'display-message tmux-bg: v exited immediately'

# 14. unknown program: clear error.
reset
out=$(env $ENVBASE bash "$SCRIPT" run zz-no-such-program-xyz 2>&1); rc=$?
assert_out  "run/unknown/error" 'program not found' "$out"
[ "$rc" = "1" ] && ok "run/unknown/rc" || bad "run/unknown/rc" "rc=$rc"

# 15. --close-on-exit chains remain-on-exit off.
reset
out=$(env $ENVBASE bash "$SCRIPT" run --close-on-exit ls 2>&1); rc=$?
assert_log  "run/close-on-exit/off" 'remain-on-exit off'

# 16. arguments pass through to the command line.
reset
out=$(env $ENVBASE bash "$SCRIPT" run ls -la 2>&1); rc=$?
assert_log  "run/args/passthrough" 'exec /usr/bin/ls -la'

# 17. toggle inside the manager session: no popup, straight back.
reset
out=$(env $ENVBASE FAKE_SESSION_NAME=programs FAKE_WINDOWS='%1' FAKE_OPT_PROGRAM=/usr/bin/vim FAKE_OPT_DIR="$WORK" \
      bash "$SCRIPT" switch 2>&1); rc=$?
assert_log  "toggle/switch-client-l" 'switch-client -l'
refute_log  "toggle/no-popup"        'display-popup'

# 18. usage documents the new options.
out=$(bash "$SCRIPT" --help 2>&1); rc=$?
assert_out  "usage/popup-width"  '--popup-width W' "$out"
assert_out  "usage/no-popup"     '--no-popup'      "$out"
assert_out  "usage/close-on-exit" '--close-on-exit' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
