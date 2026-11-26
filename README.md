# tmux-osc-7577

A tmux plugin that implements the [OSC 7577 Program Resume Protocol](https://www.superlogical.com/rex/docs/build/program-resume) on the terminal side. A program in a pane prints a signed escape sequence with the command that brings it back. After tmux restarts, the plugin runs that command again in the same pane, through [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect).

tmux drops OSC sequences it does not know, so a program cannot reach tmux with one today. This plugin reads each pane's raw output before tmux parses it and handles the reports itself. It needs no wrapper around programs, no hook in them, and no change to `default-command`.

## Install

With [TPM](https://github.com/tmux-plugins/tpm), after tmux-resurrect:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'gabrielkoerich/tmux-osc-7577'
```

The plugin builds its reader with `cc` the first time it loads. Without a compiler it falls back to one awk process per pane.

## How it works

| Step | What happens |
|---|---|
| A pane starts | A tmux hook stores the token tmux copied into the pane's `OSC7577_TOKEN`, then puts a fresh one in the global environment for the next pane |
| The pane prints | `pipe-pane` hands the pane's output to one shared reader, which looks for `ESC ] 7577 ;` |
| A report arrives | `scripts/accept` checks it in the order the spec gives: the mac against the pane's token, the time window, the order for that pid, strict syntax, then the owner pid, which must be the pane's process or one it started and run by you. It then keeps or clears the record |
| resurrect saves | Each pane's best live record is saved, the one owned by the process closest to the pane |
| resurrect restores | A fixed command goes into each pane that restore created, and `scripts/run` decodes the saved argv and runs it with `exec`, every element one argument, never parsed by a shell |

Any program can report itself with the helper:

```sh
scripts/report -- nvim -S /path/to/session.vim     # bring this back after a restart
scripts/report -C ~/src/app -- npm run dev          # in this folder
scripts/report --clear                              # do not bring it back
```

Without `OSC7577_TOKEN` in its environment the helper sends nothing, as the spec says.

## The reader

`pipe-pane` runs `osc7577 pass`, which hands the pane's pipe to the hub over a Unix socket with `SCM_RIGHTS` and exits. tmux keeps writing to the pipe, since it tracks only the file descriptor and not the process. One hub process per tmux server reads every pane.

| Reader | Processes per pane | Memory, measured on macOS |
|---|---|---|
| `osc7577 hub` (default) | 0 | 1.4 MB in total with 30 panes |
| awk, the fallback | 1 | 1.5 MB per pane |

The hub passes `accept` only a body that has a mac of the right shape last and a time inside the window, at most 5 a second for each pane and one check at a time. Text from `cat`, `tail` or ssh cannot forge a report, since it would need the pane's token. Fake reports that fail the filter start no process, however many arrive.

## Why it is built this way

| Choice | Rejected | Why |
|---|---|---|
| `pipe-pane` | A control-mode client (`tmux -C`) per session | A control client always counts as focused, so panes lose focus events. It also stops `destroy-unattached` and `exit-unattached`, and it takes `display-message` and popups run from outside a client |
| One hub that receives fds | A process per pane | Every process costs about 1.2 to 1.4 MB on macOS, so even a small C reader saves almost nothing over awk |
| A C hub | Lua or LuaJIT | Lua scans faster than awk but costs as much memory per process. A shared hub needs fd passing, which plain Lua cannot do |
| Tokens from tmux hooks | A `default-command` wrapper | A wrapper would take over a setting many people set themselves |
| Restore through tmux-resurrect | A save and restore of its own | resurrect already brings back the panes, so the plugin only adds the commands |
| A plugin | Native support in tmux | Native support would cost nothing, but tmux adds an OSC only once terminals and programs use it, as it did with OSC 7501 |

## Costs and limits

- The plugin takes the pane's only `pipe-pane`, so it does not work next to tmux-logging or a `pipe-pane` of your own. With `-o` it leaves an existing pipe alone.
- tmux has no hook for `respawn-pane`. A respawned pane keeps its old token, so its reports are ignored until it is recreated.
- Panes that existed before the plugin loaded have no token. Their reports are ignored.
- Popups and `run-shell` jobs inherit the token meant for the next pane. Only processes running as you can see it, which the spec's threat model already allows.
- Each new pane runs a short script from the hook, which adds about 30 to 40 ms to creating it.
- If the hub dies, every pane's pipe closes. The next new pane or a config reload starts it again and gives the pipes back.
- On Debian and Ubuntu without gawk, the awk fallback uses mawk, which reads a report only once a newline follows it.
- Restore skips a pane where tmux-resurrect starts a program itself, by resurrect's own `@resurrect-processes` rules. Take a program that reports itself off that list so this plugin restores it.
- Tested with tmux 3.8 on macOS and the tmux in Ubuntu's current release on Linux.

## Options

| Option | Default | |
|---|---|---|
| `@osc7577` | `on` | `off` removes the hooks and unsets any token tmux inherited |
| `@osc7577-reader` | `auto` | `hub` where it builds, or `awk` |
| `@osc7577-allow` | empty | Program names or absolute paths allowed on restore, empty allows any |
| `@osc7577-shells` | `zsh bash fish sh dash ksh tcsh` | Shells restore will type into |
| `@osc7577-root` | `off` | Accept and restore while running as root |

## Works with tmux-agents

[tmux-agents](https://github.com/gabrielkoerich/tmux-agents) restores Claude, Codex and OpenCode by reading their session files, since they do not send OSC 7577 yet. It skips any pane whose program reported itself here, so a pane never gets two commands. Its `connect` sends a report of its own, so a pane attached to a server comes back to the same remote session.

## Tests

```sh
bats tests
READER=awk bats tests
cc -g -fsanitize=address,undefined -o /tmp/fuzz tests/fuzz.c && /tmp/fuzz 1 50000
```

The tests start their own tmux server on a private socket and never touch the one you work in.
