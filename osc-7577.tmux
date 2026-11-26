#!/usr/bin/env bash
# TPM entry: a token for every new pane, a listener for every session, and restore through tmux-resurrect
dir=$(cd "$(dirname "$0")" && pwd)
source "$dir/scripts/lib.sh"

if [[ $(option @osc7577 on) != on || $dir == *\'* ]]; then
  exit 0
fi

"$dir/scripts/token" seed

# A fixed index replaces the hook on a reload instead of adding it twice
assign="run-shell \"'$dir/scripts/token' assign '#{pane_id}'\""
for hook in after-new-session after-new-window after-split-window; do
  tmux set-hook -g "${hook}[7577]" "$assign"
done
tmux set-hook -g 'session-created[7577]' "run-shell -b \"'$dir/scripts/listen' '#{session_id}'\""

for sid in $(tmux list-sessions -F '#{session_id}'); do
  tmux run-shell -b "'$dir/scripts/listen' '$sid'"
done

# resurrect runs each hook with eval, so ours goes after one already there, once
for kind in save:post-save-all restore:post-restore-all; do
  name="@resurrect-hook-${kind#*:}"
  cmd="'$dir/scripts/resume' ${kind%%:*}"
  cur=$(tmux show -gqv "$name")
  if [[ $cur != *"$cmd"* ]]; then
    tmux set -g "$name" "${cur:+$cur; }$cmd"
  fi
done
