#!/bin/bash

# CBS - Clyso Build System
# Copyright (C) 2025  Clyso GmbH
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

_CHECKMARK="\u2713"
_INFOMARK="\u2139"

[[ ! -e ".git" ]] && {
  echo "error: must be run from the repository's root" >&2
  exit 1
}

default_remote="$(git remote -v 2>/dev/null | grep 'push' | head -n 1 | cut -f1)"

usage() {
  default_remote_str="${default_remote:-N/A}"
  cat <<EOF >&2
usage: $(basename "$0") <version> [options...]

Add an annotated tag to the current branch with the provided version.
The tag will be pushed to the specified upstream repository, or the first
available remote.

Versions must always be in the format 'vMAJOR.minor.patch', where 'MAJOR',
'minor', and 'patch', are integers greater or equal to zero.

Options:
  -p | --push           Push to remote repository (default: false)
  -r | --remote NAME    Name of remote to push to (default: ${default_remote_str})
  -h | --help           Show this message

EOF
}

do_push=0
push_remote="${default_remote}"
positional_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p | --push)
      do_push=1
      ;;
    -r | --remote)
      [[ -z $2 ]] \
        && echo "error: missing argument for '--remote'" >&2 \
        && exit 1
      push_remote="${2}"
      shift 1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown argument '${1}'" >&2
      exit 1
      ;;
    *)
      positional_args+=("${1}")
      ;;
  esac

  shift 1
done

cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[[ -z ${cur_branch} ]] && {
  echo "error: unable to obtain current git branch" >&2
  exit 1
}

[[ ${cur_branch} != "main" ]] && {
  echo "error: can only release while on 'main' branch" >&2
  exit 1
}

[[ ${do_push} -eq 1 && -z ${push_remote} ]] && {
  echo "error: missing push remote" >&2
  usage
  exit 1
}

[[ ${#positional_args[@]} -eq 0 ]] && {
  echo "error: missing 'version' argument" >&2
  usage
  exit 1
}

[[ ${#positional_args[@]} -gt 1 ]] && {
  echo "error: too many arguments provided" >&2
  usage
  exit 1
}

version="${positional_args[0]}"

version_regex='^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+[0-9]+)?$'
[[ ! ${version} =~ ${version_regex} ]] && {
  echo "error: malformed version, should be in format vMAJOR.minor.patch" >&2
  exit 1
}

echo -e "${_INFOMARK} update current main branch from remote '${push_remote}'"
if ! git remote update "${push_remote}" >/dev/null 2>&1; then
  echo "error: unable to update remote '${push_remote}'" >&2
  exit 1
fi

if ! git pull "${push_remote}" main:main >/dev/null 2>&1; then
  echo "error: unable to pull latest remote main from '${push_remote}'" >&2
  exit 1
fi

tag_found="$(git tag -l "${version}" 2>/dev/null)"
[[ -n ${tag_found} && ${tag_found} == "${version}" ]] && {
  echo "error: version '${version}' already exists" >&2
  exit 1
}

git_user="$(git config user.name 2>/dev/null)"
git_email="$(git config user.email 2>/dev/null)"
git_signing_key="$(git config user.signingkey 2>/dev/null)"

[[ -z ${git_user} ]] && {
  echo "error: missing git user name, must be set before releasing" >&2
  exit 1
}

[[ -z ${git_email} ]] && {
  echo "error: missing git user email, must be set before releasing" >&2
  exit 1
}

[[ -z ${git_signing_key} ]] && {
  echo "error: missing git user signing key, must be set before releasing" >&2
  exit 1
}

tag_msg="$(
  cat <<EOF
Release CBS components ${version}

Signed-off-by: ${git_user} <${git_email}>
EOF
)"

if ! git tag -s -F - "${version}" >&/dev/null <<<"${tag_msg}"; then
  echo "error: unable to tag with version '${version}'" >&2
  exit 1
fi

echo -e "${_CHECKMARK} created tag '${version}'"

if [[ ${do_push} -eq 1 ]]; then
  echo -e "${_INFOMARK} pushing to remote '${push_remote}'..."

  if ! git push "${push_remote}" tag "${version}" >&/dev/null; then
    echo "error: unable to push tag '${version}' to remote '${push_remote}'" >&2
    exit 1
  fi

  echo -e "${_CHECKMARK} pushed tag '${version}' to '${push_remote}'"
fi
exit 0
