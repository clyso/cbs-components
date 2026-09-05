#!/bin/bash

# Prefer a CES release tag; fall back to the upstream tag it forks from.
#
# 'git describe' failing must not read as "no version": the caller treats a
# zero exit as success and would carry an empty version into the rpm release
# field, the topdir path and the upload location. Fail loudly instead.
get_version() {
  local version
  version="$(git describe --long --match 'v*-ces-v*' 2>/dev/null | sed s/^v//)"
  [[ -z ${version} ]] &&
    version="$(git describe --long --match 'v*' 2>/dev/null | sed s/^v//)"
  [[ -z ${version} ]] && {
    echo "error: unable to determine version from 'git describe'" >&2
    return 1
  }
  echo "${version}"
}

get_version
