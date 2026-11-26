#!/usr/bin/env bats

# A private tmux server on its own socket with the plugin loaded, so nothing reaches the server you work in
setup() {
  root="$BATS_TEST_DIRNAME/.."
  sock="$BATS_TEST_TMPDIR/t.sock"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
  unset TMUX_PLUGIN_MANAGER_PATH
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/out"
  # The scripts call plain tmux, this sends them to the private socket
  printf '#!/bin/sh\nexec %s -S %s "$@"\n' "$(command -v tmux)" "$sock" >"$BATS_TEST_TMPDIR/bin/tmux"
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # Records what it was started with, one argument a line
  printf '#!/bin/sh\npwd >%s/out/args\nprintf "%%s\\n" "$@" >>%s/out/args\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/probe"
  chmod +x "$BATS_TEST_TMPDIR/bin/probe"
  start
}

teardown() {
  "$(command -v -p tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)" -S "$sock" kill-server 2>/dev/null || true
  tmux_real -S "$sock" kill-server 2>/dev/null || true
}

tmux_real() {
  local t
  t=$(type -a -p tmux | grep -v "$BATS_TEST_TMPDIR" | head -1)
  "$t" "$@"
}

start() {
  tmux_real -S "$sock" -f /dev/null new -d -s main -x 120 -y 40 "bash --norc --noprofile"
  tmux_real -S "$sock" set -g @resurrect-hook-post-save-all ''
  tmux_real -S "$sock" set -g @osc7577-reader "${READER:-auto}"
  "$root/osc-7577.tmux"
}

# Waits up to 5 seconds for a condition
wait_for() {
  local i
  for i in $(seq 50); do
    case $1 in
      (pipe) [ "$(tmux_real -S "$sock" display -p -t "$2" '#{pane_pipe}')" = 1 ] && return 0 ;;
      (record) ls "$XDG_STATE_HOME"/tmux-osc-7577/server-*/records/"$2".* >/dev/null 2>&1 && return 0 ;;
      (file) [ -s "$2" ] && return 0 ;;
    esac
    sleep 0.1
  done
  return 1
}

# A new shell pane with its reader running, its id on stdout
pane() {
  local p
  p=$(tmux_real -S "$sock" new-window -d -P -F '#{pane_id}' -t main "bash --norc --noprofile")
  wait_for pipe "$p"
  echo "$p"
}

# Prints a report signed with the pane's token, from inside the pane, with any body
signed() {
  type_in "$1" "b=\"$2\"; m=\$(printf '%s:%s' \"\$b\" \"\$OSC7577_TOKEN\" | shasum -a 256 | cut -d' ' -f1); printf '\\033]7577;%s:mac=%s\\033\\\\' \"\$b\" \"\$m\""
}

# Types a line into a pane
type_in() {
  tmux_real -S "$sock" send-keys -t "$1" -l "$2"
  tmux_real -S "$sock" send-keys -t "$1" Enter
}

records() {
  ls "$XDG_STATE_HOME"/tmux-osc-7577/server-*/records/ 2>/dev/null | grep -c "^${1#%}\." || true
}

@test "each new pane gets its own token, and the plugin knows which" {
  a=$(pane) b=$(pane)
  type_in "$a" "printf %s \"\$OSC7577_TOKEN\" >$BATS_TEST_TMPDIR/out/a"
  type_in "$b" "printf %s \"\$OSC7577_TOKEN\" >$BATS_TEST_TMPDIR/out/b"
  wait_for file "$BATS_TEST_TMPDIR/out/a"
  wait_for file "$BATS_TEST_TMPDIR/out/b"
  [ "$(cat "$BATS_TEST_TMPDIR/out/a")" != "$(cat "$BATS_TEST_TMPDIR/out/b")" ]
  [ "$(cat "$BATS_TEST_TMPDIR/out/a")" = "$(cat "$XDG_STATE_HOME"/tmux-osc-7577/server-*/tokens/"${a#%}")" ]
  [[ $(cat "$BATS_TEST_TMPDIR/out/a") =~ ^[A-Za-z0-9_-]{43}$ ]]
}

@test "a report signed with the pane's token becomes a record, and clear removes it" {
  p=$(pane)
  type_in "$p" "'$root/scripts/report' -C /tmp -- probe one"
  wait_for record "${p#%}"
  [ "$(records "$p")" -eq 1 ]
  type_in "$p" "'$root/scripts/report' --clear"
  sleep 1
  [ "$(records "$p")" -eq 0 ]
}

@test "a wrong token, an old time or a report printed as text is ignored" {
  p=$(pane)
  type_in "$p" "OSC7577_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxx '$root/scripts/report' -- probe"
  type_in "$p" "printf '%s' '\\033]7577;pid=1:time=1:argv=cHJvYmU=:mac=0000000000000000000000000000000000000000000000000000000000000000\\033\\\\'"
  signed "$p" "pid=\$\$:time=\$(( \$(date +%s) - 300 )):argv=cHJvYmU="
  sleep 1.5
  [ "$(records "$p")" -eq 0 ]
}

@test "a genuine report that breaks a rule clears the program's earlier record" {
  p=$(pane)
  type_in "$p" "'$root/scripts/report' -- probe"
  wait_for record "${p#%}"
  signed "$p" "pid=\$\$:time=\$(date +%s):argv=cHJvYmU=:argv=cHJvYmU="
  sleep 1.5
  [ "$(records "$p")" -eq 0 ]
}

@test "a pid outside the pane is rejected" {
  p=$(pane)
  type_in "$p" "'$root/scripts/report' -p 1 -- probe"
  sleep 1.5
  [ "$(records "$p")" -eq 0 ]
}

@test "after a restart each argument reaches the program unchanged, and nothing runs as shell text" {
  p=$(pane)
  idx=$(tmux_real -S "$sock" display -p -t "$p" '#{window_index}')
  type_in "$p" "'$root/scripts/report' -C '$BATS_TEST_TMPDIR' -- probe 'a b' '\$(touch $BATS_TEST_TMPDIR/pwned)' ';ls'"
  wait_for record "${p#%}"
  "$root/scripts/resume" save
  tmux_real -S "$sock" kill-server
  sleep 0.3

  start
  "$root/scripts/resume" before
  for i in $(seq "$idx"); do
    tmux_real -S "$sock" new-window -d -t main "bash --norc --noprofile"
  done
  "$root/scripts/resume" restore
  wait_for file "$BATS_TEST_TMPDIR/out/args"
  sleep 0.3
  run cat "$BATS_TEST_TMPDIR/out/args"
  [ "${lines[0]}" = "$(cd "$BATS_TEST_TMPDIR" && pwd -P)" ] || [ "${lines[0]}" = "$BATS_TEST_TMPDIR" ]
  [ "${lines[1]}" = "a b" ]
  [ "${lines[2]}" = "\$(touch $BATS_TEST_TMPDIR/pwned)" ]
  [ "${lines[3]}" = ";ls" ]
  [ "${#lines[@]}" -eq 4 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "a relative command, a command starting with -, or a newline in an argument is rejected" {
  p=$(pane)
  signed "$p" "pid=\$\$:time=\$(date +%s):argv=Li9ydW4uc2g="
  signed "$p" "pid=\$\$:time=\$(date +%s):argv=LWE=,eA==,L2Jpbi9zaA=="
  signed "$p" "pid=\$\$:time=\$(date +%s):argv=cHJvYmU=,YQpi"
  sleep 1.5
  [ "$(records "$p")" -eq 0 ]
}

@test "a report sent again after a clear does not bring the record back" {
  p=$(pane)
  type_in "$p" "t=\$(date +%s); b=\"pid=\$\$:time=\$t:argv=cHJvYmU=\"; m=\$(printf '%s:%s' \"\$b\" \"\$OSC7577_TOKEN\" | shasum -a 256 | cut -d' ' -f1); printf '\\033]7577;%s:mac=%s\\033\\\\' \"\$b\" \"\$m\" | tee $BATS_TEST_TMPDIR/out/old"
  wait_for record "${p#%}"
  sleep 1.1
  type_in "$p" "'$root/scripts/report' --clear"
  sleep 1
  [ "$(records "$p")" -eq 0 ]
  type_in "$p" "cat $BATS_TEST_TMPDIR/out/old"
  sleep 1.5
  [ "$(records "$p")" -eq 0 ]
}

@test "a grouped session leaves the token of the pane it shares alone" {
  p=$(pane)
  before=$(cat "$XDG_STATE_HOME"/tmux-osc-7577/server-*/tokens/"${p#%}")
  tmux_real -S "$sock" new-session -d -t main -s view
  sleep 0.5
  [ "$(cat "$XDG_STATE_HOME"/tmux-osc-7577/server-*/tokens/"${p#%}")" = "$before" ]
  [ "$(cat "$XDG_STATE_HOME"/tmux-osc-7577/server-*/tokens/0)" != "$(cat "$XDG_STATE_HOME"/tmux-osc-7577/server-*/tokens/"${p#%}")" ]
}

@test "restore leaves panes that existed before it, and panes with a job in front of the shell" {
  p=$(pane)
  q=$(pane)
  type_in "$p" "'$root/scripts/report' -- probe"
  type_in "$q" "'$root/scripts/report' -- probe"
  wait_for record "${p#%}"
  wait_for record "${q#%}"
  "$root/scripts/resume" save
  "$root/scripts/resume" before
  "$root/scripts/resume" restore
  sleep 1
  [ ! -e "$BATS_TEST_TMPDIR/out/args" ]
}

@test "a flood of fake reports printed as text calls accept for none of them" {
  p=$(pane)
  now=$(date +%s)
  for i in $(seq 2000); do
    printf '\033]7577;pid=1:time=1:argv=eA==:mac=%064d\033\\' 0
  done >"$BATS_TEST_TMPDIR/out/flood"
  start=$(date +%s)
  type_in "$p" "cat $BATS_TEST_TMPDIR/out/flood; echo done >$BATS_TEST_TMPDIR/out/flooded"
  wait_for file "$BATS_TEST_TMPDIR/out/flooded"
  [ $(( $(date +%s) - start )) -lt 4 ]
}

@test "with the hub, panes have no process of their own, and a new pane brings a killed hub back" {
  [ "${READER:-auto}" = auto ] || skip "the hub is not the reader"
  a=$(pane) b=$(pane)
  srv=$(tmux_real -S "$sock" display -p '#{pid}')
  hub=$(cat "${TMUX_TMPDIR:-/tmp}/tmux-osc7577-$EUID/$srv.sock.pid")
  kill -0 "$hub"
  [ "$(pgrep -f 'osc7577 pass' | wc -l | tr -d ' ')" -eq 0 ]
  ! pgrep -f "$root/scripts/scan.awk"
  kill "$hub"
  type_in "$a" true
  type_in "$b" true
  sleep 0.5
  c=$(pane)
  sleep 0.5
  [ "$(tmux_real -S "$sock" display -p -t "$a" '#{pane_pipe}')" = 1 ]
  type_in "$a" "'$root/scripts/report' -- probe"
  wait_for record "${a#%}"
}
