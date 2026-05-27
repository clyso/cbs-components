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

[[ ! -e ".git" ]] && {
  echo "error: must be run from the repository's root" >&2
  exit 1
}

tag="$(git describe --match 'v*' --exact-match 2>/dev/null)"
[[ -z ${tag} ]] && {
  echo "error: will only package tagged releases" >&2
  exit 1
}

[[ "$(git cat-file -t "${tag}" 2>/dev/null)" != "tag" ]] && {
  echo "error: must only package annotated tags" >&2
  exit 1
}

archive_path="./cbs-components-${tag}.tar"

usage() {
  cat <<EOF >&2
usage: $0 [options]

Options:
  --component PATH        Specify component to be included in the archive.
                          Can be specified multiple times.
                          (default: ./components/*)
  -o | --output PATH      Specify resulting archive path.
                          (default: ${archive_path})
  -h | --help             Shows this message.

EOF
}

component_paths=()

while [[ $# -gt 0 ]]; do
  case ${1} in
    --component)
      [[ -z ${2} ]] && {
        echo "error: '--component' requires a PATH" >&2
        exit 1
      }
      comp_path="$(realpath "${2}")"
      [[ ! -d ${comp_path} ]] && {
        echo "error: path at '${2}' is not a directory" >&2
        exit 1
      }
      component_paths+=("${comp_path}")
      shift 1
      ;;
    -o | --output)
      [[ -z ${2} ]] && {
        echo "error: '--output' requires a PATH" >&2
        exit 1
      }
      archive_path="${2}"
      shift 1
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option '${1}'" >&2
      exit 1
      ;;
    *)
      echo "error: unknown argument '${1}'" >&2
      exit 1
      ;;
  esac
  shift 1
done

archive_path="$(realpath "${archive_path}")"

[[ -e ${archive_path} ]] && {
  echo "error: archive path at '${archive_path}' already exists" >&2
  exit 1
}

if [[ ${#component_paths[@]} -eq 0 ]]; then
  [[ ! -d "./components" ]] && {
    echo "error: missing 'components' directory" >&2
    exit 1
  }

  for c in ./components/*; do
    component_paths+=("$(realpath "${c}")")
  done
fi

for comp_path in "${component_paths[@]}"; do
  res="$(find "${comp_path}" -name 'cbs.component.yaml' -type f -print -quit)"
  [[ -z ${res} ]] && {
    echo "error: component not found at '${comp_path}'" >&2
    exit 1
  }
done

archive_dir="$(mktemp -d --suffix='-cbs-components')"

cleanup() {
  [[ -e ${archive_dir} ]] && rm -fr "${archive_dir}"
}

trap cleanup EXIT SIGINT SIGTERM

for comp in "${component_paths[@]}"; do
  comp_name="$(basename "${comp}")"
  echo "> archiving '${comp_name}' at '${comp}'"
  cp -r "${comp}" "${archive_dir}/${comp_name}" || {
    echo "error: unable to copy component from '${comp_path}'" >&2
    exit 1
  }
done

tar -C "${archive_dir}" -cf "${archive_path}" . || {
  echo "error: unable to create component archive at '${archive_path}'" >&2
  exit 1
}
