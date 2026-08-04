#!/usr/bin/env bash
# Authorize verifier neutral-directory use and removal by durable path and
# filesystem identity while excluding repository, operational-home, and other
# caller-supplied protected path trees in either ancestor direction.

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

fm_neutral_filesystem_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
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
