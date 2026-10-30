#!/bin/sh
# Resolves the host's templates into one env file, on stdout. Runs on the VM (render-env, `op` from its image) and on
# a laptop (`make env`, `op` as installed). Needs: sh, awk, sed, and OP_INJECT, the command that runs `op inject`.
#   inject-env.sh <template>...   the image's templates first, the local ones after; a missing file is skipped
# A file's name says which service account resolves it, and nothing else does:
#   <x>.tpl          (.env.tpl, env.tpl)  the account `op` already has: the host's, or the person's own on a laptop
#   <x>.<name>.tpl   (.env.acme.tpl)      the token OP_SERVICE_ACCOUNT_TOKEN_<NAME>, a line of the first ones
# Files of one name are concatenated in argument order, and the last line of a variable wins across all of them.
# One failed file fails the whole, and nothing is printed: the host must not start on part of its environment.
set -eu
: "${OP_INJECT:=op inject}"

# the account part of a template's name: empty for <x>.tpl, <name> for <x>.<name>.tpl
account() { b=${1##*/}; b=${b#.}; b=${b%.tpl}; case $b in *.*) echo "${b#*.}" ;; esac; }

# the templates of one account, concatenated
templates() {
  want=$1; shift
  for f; do
    if [ -f "$f" ] && [ "$(account "$f")" = "$want" ]; then cat "$f"; echo; fi
  done
}

# `op inject` on stdin; an empty result is a failure too, whatever op's status
inject() {
  out=$($OP_INJECT) || { echo "$1: op inject failed" >&2; return 1; }
  [ -n "$out" ] || { echo "$1 rendered empty: an expired token, or an item it cannot read" >&2; return 1; }
  printf '%s\n' "$out"
}

[ -n "$(templates "" "$@")" ] || { echo "no .env.tpl among: $*" >&2; exit 1; }
rendered=$(templates "" "$@" | inject .env.tpl)

accounts=$(for f; do [ ! -f "$f" ] || account "$f"; done | sort -u)
for a in $accounts; do
  case $a in *[!a-z0-9_]*) echo ".env.$a.tpl: an account name is lowercase letters, digits and _" >&2; exit 1 ;; esac
  var=OP_SERVICE_ACCOUNT_TOKEN_$(echo "$a" | tr '[:lower:]' '[:upper:]')
  token=$(printf '%s\n' "$rendered" | sed -n "s/^$var=//p" | tail -n 1)
  [ -n "$token" ] || { echo ".env.$a.tpl: no $var in .env.tpl, the token it is resolved with" >&2; exit 1; }
  part=$(templates "$a" "$@" | (OP_SERVICE_ACCOUNT_TOKEN=$token; export OP_SERVICE_ACCOUNT_TOKEN; inject ".env.$a.tpl"))
  rendered=$(printf '%s\n%s\n' "$rendered" "$part")
done

printf '%s\n' "$rendered" \
  | awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { if (!($1 in v)) k[n++] = $1; v[$1] = $0 }
             END { for (i = 0; i < n; i++) print v[k[i]] }'
