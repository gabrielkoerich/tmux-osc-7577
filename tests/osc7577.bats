#!/usr/bin/env bats

# A private tmux server on its own socket with the plugin loaded, so nothing reaches the server you work in
setup() {
  root="$BATS_TEST_DIRNAME/.."
  sock="$BATS_TEST_TMPDIR/t.sock"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
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
  "$root/osc-7577.tmux"
  wait_for listener
}

# Waits up to 5 seconds for a condition
wait_for() {
  local i
  for i in $(seq 50); do
    case $1 in
      (listener) ls "$XDG_STATE_HOME"/tmux-osc-7577/server-*/listeners/*/pid >/dev/null 2>&1 && return 0 ;;
      (record) ls "$XDG_STATE_HOME"/tmux-osc-7577/server-*/records/"$2".* >/dev/null 2>&1 && return 0 ;;
      (file) [ -s "$2" ] && return 0 ;;
    esac
    sleep 0.1
  done
  return 1
}

# A new shell pane, its id on stdout
pane() {
  tmux_real -S "$sock" new-window -d -P -F '#{pane_id}' -t main "bash --norc --noprofile"
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
  body="pid=\$\$:time=\$(( \$(date +%s) - 300 )):argv=cHJvYmU="
  type_in "$p" "b=\"$body\"; m=\$(printf '%s:%s' \"\$b\" \"\$OSC7577_TOKEN\" | shasum -a 256 | cut -d' ' -f1); printf '\\033]7577;%s:mac=%s\\033\\\\' \"\$b\" \"\$m\""
  sleep 1.5
  [ "$(records "$p")" -eq 0 ]
}

@test "a genuine report that breaks a rule clears the program's earlier record" {
  p=$(pane)
  type_in "$p" "'$root/scripts/report' -- probe"
  wait_for record "${p#%}"
  body="pid=\$\$:time=\$(date +%s):argv=cHJvYmU=:argv=cHJvYmU="
  type_in "$p" "b=\"$body\"; m=\$(printf '%s:%s' \"\$b\" \"\$OSC7577_TOKEN\" | shasum -a 256 | cut -d' ' -f1); printf '\\033]7577;%s:mac=%s\\033\\\\' \"\$b\" \"\$m\""
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
  for i in $(seq "$idx"); do
    tmux_real -S "$sock" new-window -d -t main "bash --norc --noprofile"
  done
  sleep 0.5
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
