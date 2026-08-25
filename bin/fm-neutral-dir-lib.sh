#!/usr/bin/env bash
# Own the shared device+inode path-identity predicates, and authorize verifier
# neutral-directory use and removal by durable path and filesystem identity
# while excluding repository, operational-home, and other caller-supplied
# protected path trees in either ancestor direction.

# Do two paths name the same directory? Decided by device+inode identity, never
# by comparing strings: a case-insensitive volume, a symlink prefix, a hard link
# and a bind mount each name one directory two ways, and lowercasing is not a
# substitute because it would false-positive on genuinely distinct paths on a
# case-sensitive volume. Fails closed - a missing or unreadable path is never
# reported as the same directory.
fm_path_is_same_dir() {  # <a> <b>
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ -d "$1" ] && [ -d "$2" ] || return 1
  [ "$1" -ef "$2" ]
}

fm_path_is_same_or_descendant_by_identity() {
  local current=$1 ancestor=$2 parent
  [ -d "$current" ] && [ -d "$ancestor" ] || return 1
  current=$(CDPATH='' cd -- "$current" && pwd -P) || return 1
  ancestor=$(CDPATH='' cd -- "$ancestor" && pwd -P) || return 1
  while :; do
    [ "$current" -ef "$ancestor" ] && return 0
    parent=$(CDPATH='' cd -- "$current/.." && pwd -P) || return 1
    [ "$parent" -ef "$current" ] && return 1
    current=$parent
  done
}

# The ONE device:inode helper. Every producer and every consumer of a neutral
# directory identity must go through this function, because the two identities
# that fm_neutral_directory_is_authorized compares (the one recorded at build
# time and the one expected at launch/teardown time) are only comparable if a
# single stat flavor produced both. Flavor is probed, never inferred from
# `uname`: GNU coreutils stat is routinely ahead of /usr/bin/stat on a macOS
# PATH, and there `-f` means --file-system, so a BSD-style `stat -f %i` reports
# something entirely unrelated to an inode.
fm_neutral_filesystem_identity() {
  local identity
  identity=$(stat -c '%d:%i' "$1" 2>/dev/null) \
    || identity=$(stat -f '%d:%i' "$1" 2>/dev/null) \
    || return 1
  case "$identity" in ''|:*|*:) return 1 ;; esac
  printf '%s\n' "$identity"
}

fm_neutral_binding_value() {
  local binding=$1 key=$2
  [ -f "$binding" ] && [ ! -L "$binding" ] || return 1
  awk -v key="$key" '
    index($0, key "=") == 1 { value = substr($0, length(key) + 2) }
    END { if (value != "") print value; else exit 1 }
  ' "$binding"
}

fm_neutral_directory_conflicts_with_protected_path() {
  local target=$1 protected
  shift
  for protected in "$@"; do
    [ -d "$protected" ] || continue
    if fm_path_is_same_or_descendant_by_identity "$target" "$protected" \
       || fm_path_is_same_or_descendant_by_identity "$protected" "$target"; then
      return 0
    fi
  done
  return 1
}

fm_neutral_directory_is_authorized() {
  local target=$1 expected_identity=$2 binding=$3
  local recorded_path recorded_identity current_identity
  shift 3
  [ -d "$target" ] && [ ! -L "$target" ] || {
    echo "REFUSED: neutral directory is not an ordinary directory: ${target:-<missing>}" >&2
    return 1
  }
  recorded_path=$(fm_neutral_binding_value "$binding" neutral_cleanup_path) || {
    echo "REFUSED: neutral directory has no matching verifier ownership binding: $target" >&2
    return 1
  }
  recorded_identity=$(fm_neutral_binding_value "$binding" neutral_cleanup_identity) || {
    echo "REFUSED: neutral directory has no matching verifier ownership binding: $target" >&2
    return 1
  }
  current_identity=$(fm_neutral_filesystem_identity "$target") || {
    echo "REFUSED: neutral directory filesystem identity cannot be read: $target" >&2
    return 1
  }
  [ -n "$expected_identity" ] || {
    echo "REFUSED: neutral directory has no recorded filesystem identity: $target" >&2
    return 1
  }
  [ "$current_identity" = "$expected_identity" ] || {
    echo "REFUSED: neutral directory filesystem identity changed for $target (recorded $expected_identity, current $current_identity)" >&2
    return 1
  }
  [ "$recorded_identity" = "$expected_identity" ] \
    && [ -d "$recorded_path" ] \
    && [ "$target" -ef "$recorded_path" ] || {
      echo "REFUSED: neutral directory does not match its verifier ownership binding: $target" >&2
      return 1
    }
  [ ! "$target" -ef / ] || {
    echo "REFUSED: neutral directory is the filesystem root: $target" >&2
    return 1
  }
  if [ -n "${HOME:-}" ] && [ -d "$HOME" ] && [ "$target" -ef "$HOME" ]; then
    echo "REFUSED: neutral directory is the operator home: $target" >&2
    return 1
  fi
  if fm_neutral_directory_conflicts_with_protected_path "$target" "$@"; then
    echo "REFUSED: neutral directory conflicts with a protected path: $target" >&2
    return 1
  fi
}
