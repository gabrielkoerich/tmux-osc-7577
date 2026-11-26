# shellcheck shell=bash
# Shared by the scripts, sourced, not run
# shellcheck disable=SC2034
sep=$'\x1f'
b64_re='^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}(==)?|[A-Za-z0-9+/]{3}=?)?$'

state_dir() {
  local d="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-osc-7577"
  (umask 077 && mkdir -p "$d")
  printf '%s' "$d"
}

# Pane ids start again at %0 on a new server, so tokens and records live in a folder for each server
server_dir() {
  local d
  d="$(state_dir)/server-$(tmux display -p '#{pid}-#{start_time}')"
  (umask 077 && mkdir -p "$d/tokens" "$d/records" "$d/times")
  printf '%s' "$d"
}

# One saved set for each tmux socket, so two servers never restore each other's programs
resume_dir() {
  printf '%s/resume-%s' "$(state_dir)" "$(tmux display -p '#{socket_path}' | sha256 | cut -c1-12)"
}

option() {
  local v
  v=$(tmux show -gqv "$1")
  printf '%s' "${v:-$2}"
}

# 43 characters of [A-Za-z0-9_-] from 32 random bytes, past the spec's 22 character minimum
new_token() {
  head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' | cut -c1-43
}

# Sets the token for the next pane through a private file, so it never shows on a command line
set_token() {
  local f
  f=$(mktemp "$(state_dir)/.env.XXXXXX") || return 1
  printf 'set-environment -g OSC7577_TOKEN %s\n' "$1" >"$f"
  tmux source-file "$f"
  rm -f "$f"
}

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Strict UTF-8, since macOS iconv passes code points past U+10FFFF
utf8_ok() {
  if command -v perl >/dev/null; then
    perl -MEncode -0777 -ne 'decode("UTF-8", $_, Encode::FB_CROAK); END { exit 0 }' <"$1" 2>/dev/null
  else
    iconv -f UTF-8 -t UTF-8 <"$1" >/dev/null 2>&1
  fi
}

# Decodes one base64 element to stdout, or fails when it is not base64 or not text without control characters
decode() {
  local s=$1 tmp size
  if [[ ! $s =~ $b64_re ]]; then
    return 1
  fi

  while (( ${#s} % 4 )); do
    s+='='
  done
  tmp=$(mktemp) || return 1
  # tr drops every C0 control and DEL, a size change means there was one, grep finds C1 in its UTF-8 form
  if ! printf '%s' "$s" | base64 -d >"$tmp" 2>/dev/null || ! utf8_ok "$tmp" \
    || LC_ALL=C grep -q $'\xc2[\x80-\x9f]' "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  size=$(wc -c <"$tmp")
  if (( $(LC_ALL=C tr -d '\000-\037\177' <"$tmp" | wc -c) != size )); then
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp"
  rm -f "$tmp"
}

# A command is an absolute path or a bare name, and a bare name never starts with -
command_ok() {
  [[ $1 == /* || ( $1 != */* && $1 != -* && -n $1 ) ]]
}

# The start time of a pid, so a pid the system gave to a new process does not pass for the old one
started() {
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '
}

# The working directory of a process, read from the system
cwd_of() {
  if [[ -d /proc/$1 ]]; then
    readlink "/proc/$1/cwd" 2>/dev/null
  else
    lsof -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p'
  fi
}

# The awk that reads pane output. mawk holds pipe input until EOF, so another awk is used when there is one
awk_cmd() {
  local a
  for a in awk original-awk nawk gawk busybox; do
    if command -v "$a" >/dev/null && ! "$a" -W version 2>&1 | grep -q mawk; then
      if [[ $a == busybox ]]; then
        echo 'busybox awk'
      else
        echo "$a"
      fi
      return
    fi
  done
  echo 'awk -W interactive'
}
