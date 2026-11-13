# tmux-bg

`tmux-bg` runs programs in a dedicated tmux session, with one managed
window per executable and working directory. It includes an fzf picker with
a terminal preview and commands for switching, killing, listing and cleaning
up managed windows.

The default session is `programs`. It is created automatically when the first
program is launched. Launches are detached/backgrounded by default: the
current tmux client stays where it is.

## Requirements

- tmux
- Bash 4+
- fzf
- `readlink` with `-f` support (the intended platform is Linux)

## Installation

Copy `tmux-bg` somewhere on your `PATH`, for example:

```sh
mkdir -p ~/.local/bin
cp tmux-bg ~/.local/bin/
chmod +x ~/.local/bin/tmux-bg
```

Make sure `~/.local/bin` is on your `PATH`.

## Launching programs

Run a program from the project directory:

```sh
cd ~/src/project-a
tmux-bg run htop

cd ~/src/project-b
tmux-bg run lazygit

cd ~/src/project-a
tmux-bg run nvim .
```

Each program gets a window in the `programs` session. The window title is
`program - directory`, for example `lazygit - project-b`.

The script creates the session if necessary. It does not switch the current
client to the background session.

### Duplicate detection

A managed window is identified by:

- the resolved executable path;
- the canonical current working directory (`pwd -P`).

If that executable is already managed in that directory, another window is
not created. Arguments are deliberately not part of the identity, so
`nvim .` and `nvim file.txt` count as the same program/directory instance.

The script stores identity in tmux window user options:

- `@managed_program`
- `@managed_directory`
- `@managed_title`
- `@managed_version`

These options are the source of truth. The visible window title is for humans
and can be renamed without breaking duplicate detection.

To switch to the existing instance when launching, use:

```sh
tmux-bg --attach run htop
```

The equivalent command-local form is:

```sh
tmux-bg run --attach htop
```

## Commands

Global options go before the command:

```text
tmux-bg [--session NAME] COMMAND
```

### `run PROGRAM [ARG...]`

Start a program in the background:

```sh
tmux-bg run htop
tmux-bg run nvim .
tmux-bg --session dev-tools run lazygit
```

Use `--attach` to switch to the new or already-existing window after launch:

```sh
tmux-bg --attach run htop
tmux-bg --session dev-tools --attach run lazygit
```

`--attach` is optional. Background execution is the default.

### `switch`

Open fzf and choose a managed program:

```sh
tmux-bg switch
tmux-bg --session dev-tools switch
```

The picker displays the window title, directory and executable. The preview
uses `tmux capture-pane` to show the currently visible terminal contents of
the highlighted window.

If the client is already in the selected manager session, `switch` returns
the client to its previous session using `switch-client -l`. Otherwise it
switches to the manager session and selects the chosen window.

`pick` is an alias for `switch`.

### `kill`

Open the same picker, mark one or more entries with Tab, then press Enter:

```sh
tmux-bg kill
tmux-bg --session dev-tools kill
```

Only selected managed windows are killed. Unmanaged windows in the session
are not listed and are not affected.

### `list`

Print managed windows without opening fzf:

```sh
tmux-bg list
```

### `clean-up`

Remove managed windows whose panes have exited:

```sh
tmux-bg clean-up
```

`cleanup` is accepted as an alias. The command does not kill live programs
and does not remove unmanaged windows.

Normally tmux closes a window when its command exits. If the tmux
`remain-on-exit` option is enabled, an exited program can leave a dead pane;
`clean-up` removes those dead managed windows.

## tmux key binding

Add this to `~/.tmux.conf`:

```tmux
bind-key P display-popup -E -w 95% -h 90%  "tmux-bg switch"
```

Reload the configuration:

```sh
tmux source-file ~/.tmux.conf
```

Press `prefix` then `P` to open the picker.

You can bind kill separately:

```tmux
bind-key K display-popup -E -w 90% -h 80% "tmux-bg kill"
```

## fzf preview

The preview command is:

```sh
tmux capture-pane -p -e -t WINDOW_ID
```

`-p` prints captured content and `-e` preserves escape sequences for terminal
formatting. fzf refreshes the preview as the highlighted entry changes. This
is a refreshed snapshot, not a continuously streamed video.

## tmux window user options

Tmux supports user-defined options whose names begin with `@`. They are
string-valued metadata attached to a tmux object. Window options are set with
`set-option -w` and read with `show-option -w`.

For example:

```sh
tmux set-option -w -t @3 @managed_program /usr/bin/nvim
tmux show-option -w -t @3 @managed_program
tmux show-options -w -t @3
tmux set-option -wu -t @3 @managed_program
```

The `@3` above is an example window ID; use an actual target from
`tmux list-windows -F '#{window_id}'`.

User options are stored by the running tmux server. They are not durable
storage across a complete server restart. This script therefore treats them
as runtime metadata, not as a persistent registry.

## Design and limitations

- The manager uses a single tmux window per program/directory pair.
- Different programs can run in the same directory.
- The same executable can run in different directories.
- Arguments do not distinguish instances.
- Identity is based on the resolved executable path, not a process-tree scan.
- Programs are launched with `exec`, so the pane's main process becomes the
  requested executable.
- The picker preview shows the active pane in each window. It does not render
  an entire multi-pane layout as one composite image.
- The script expects Linux-style `readlink -f`.
- The default session name is `programs`; use `--session NAME` to select a
  different manager session.

## Troubleshooting

Check whether the session exists:

```sh
tmux has-session -t '=programs'
```

List its windows and metadata:

```sh
tmux list-windows -t '=programs' -F '#{window_id} #{window_name}'
tmux show-options -w -t @WINDOW_ID
```

List managed programs:

```sh
tmux-bg list
```

Check that dependencies are available:

```sh
command -v tmux
command -v fzf
command -v readlink
```
