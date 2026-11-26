# Reads one pane's raw output. Records split at ESC, BEL and newline, a class every awk but mawk ends at once, so
# a report is read as its terminator arrives. Only a body with a mac of the right shape and a time inside the
# window reaches accept, at most 5 a second
BEGIN { cmd = "'" accept "' '%" pane "'" }

substr($0, 1, 6) == "]7577;" {
  body = substr($0, 7)
  if (length(body) > 4096 || body !~ /:mac=[0-9a-f]+$/ || length(body) < 70) next
  if (substr(body, length(body) - 68, 5) != ":mac=") next
  if (!match(":" body, /:time=[0-9]+:/)) next
  t = substr(":" body, RSTART + 6, RLENGTH - 7) + 0
  srand(); now = srand()
  if (t < now - 60 || t > now + 60) next
  if (now != second) { second = now; sent = 0 }
  if (++sent > 5) next
  printf "%s", body | cmd
  close(cmd)
}
