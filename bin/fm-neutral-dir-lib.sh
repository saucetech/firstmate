#!/usr/bin/env bash

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

fm_neutral_directory_conflicts_with_protected_path() {
  local target=$1 project=$2 fm_root=$3 fm_home=$4 projects=$5 protected candidate
  for protected in "$project" "$fm_root" "$fm_home"; do
    [ -d "$protected" ] || continue
    if fm_path_is_same_or_descendant_by_identity "$target" "$protected" \
       || fm_path_is_same_or_descendant_by_identity "$protected" "$target"; then
      return 0
    fi
  done
  if [ -d "$projects" ]; then
    for candidate in "$projects"/*; do
      [ -d "$candidate" ] || continue
      if fm_path_is_same_or_descendant_by_identity "$target" "$candidate" \
         || fm_path_is_same_or_descendant_by_identity "$candidate" "$target"; then
        return 0
      fi
    done
  fi
  return 1
}
