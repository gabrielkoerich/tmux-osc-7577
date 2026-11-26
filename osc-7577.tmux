#!/usr/bin/env bash
# TPM entry: a token and a reader for every new pane, and restore through tmux-resurrect
dir=$(cd "$(dirname "$0")" && pwd)
source "$dir/scripts/lib.sh"

# Never pass on a token tmux got from the terminal it runs in, also when the plugin is off
tmux set-environment -gu OSC7577_TOKEN
if [[ $(option @osc7577 on) != on || $dir == *\'* ]]; then
  for hook in after-new-session after-new-window after-split-window; do
    tmux set-hook -gu "${hook}[7577]"
  done
  exit 0
fi

set_token "$(new_token)"

# A fixed index replaces the hook on a reload instead of adding it twice
for hook in after-new-session after-new-window after-split-window; do
  tmux set-hook -g "${hook}[7577]" "run-shell \"'$dir/scripts/pane' '#{pane_id}'\""
done

# After a reload, panes that already have a token get their reader back, the rest never had one
for pane in $(tmux list-panes -a -F '#{pane_id}'); do
  if [[ -s "$(server_dir)/tokens/${pane#%}" ]]; then
    "$dir/scripts/pane" "$pane"
  fi
done

# resurrect runs each hook with eval, so ours goes on its own line after one already there, once
for kind in save:post-save-all before:pre-restore-all restore:post-restore-all; do
  name="@resurrect-hook-${kind#*:}"
  cmd="'$dir/scripts/resume' ${kind%%:*}"
  cur=$(tmux show -gqv "$name")
  if [[ $cur != *"$cmd"* ]]; then
    tmux set -g "$name" "${cur:+$cur$'\n'}$cmd"
  fi
done
