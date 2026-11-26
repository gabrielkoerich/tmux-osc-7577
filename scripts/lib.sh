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
  (umask 077 && mkdir -p "$d/tokens" "$d/records" "$d/listeners")
  printf '%s' "$d"
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

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Decodes one base64 element to stdout, or fails when it is not base64 or not text without control characters
decode() {
  local s=$1 tmp n
  if [[ ! $s =~ $b64_re ]]; then
    return 1
  fi

  while (( ${#s} % 4 )); do
    s+='='
  done
  tmp=$(mktemp) || return 1
  if ! printf '%s' "$s" | base64 -d >"$tmp" 2>/dev/null \
    || ! iconv -f UTF-8 -t UTF-8 <"$tmp" >/dev/null 2>&1 \
    || LC_ALL=C grep -q $'[\x01-\x1f\x7f]\|\xc2[\x80-\x9f]' "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  n=$(LC_ALL=C tr -d '\000' <"$tmp" | wc -c)
  if (( n != $(wc -c <"$tmp") )); then
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp"
  rm -f "$tmp"
}

# The start time of a pid, so a pid the system gave to a new process does not pass for the old one
started() {
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '
}
