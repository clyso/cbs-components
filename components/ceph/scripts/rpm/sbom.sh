#!/bin/bash

# CES - generate the Build SBOMs for the Ceph RPMs
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

# Runs after the rpms have been built (by build_rpms.sh with CBS_SBOM_TOOL set,
# which keeps the build tree) and signed. Crawls the build tree, the worktree
# and the rpms with ceph-sbom and writes the build facts, the build record and
# one Build SBOM per rpm into CBS_SBOM_OUT, which CBS then signs and uploads.
#
# Facts ceph-sbom does not consider deliverable (an input, file or component
# its evidence cannot explain) fail the build: never pass
# --allow-not-deliverable here.

sbom_tool="${CBS_SBOM_TOOL:?}"
sbom_out="${CBS_SBOM_OUT:?}"
topdir="${CBS_TOPDIR:?}"
worktree="${CBS_WORKTREE:?}"
patches="${CBS_PATCHES:?}"

# The build tree is tens of GB; free it whether or not the SBOM succeeded.
cleanup_build_tree() {
  local i
  echo "SBOM: removing build trees from ${topdir}"
  for i in BUILD BUILDROOT; do
    if [[ -d "${topdir}/${i}" ]]; then
      find "${topdir}/${i}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
  done
}

crawler_exit_meaning() {
  case "${1}" in
    2) echo "usage error (bad arguments or missing inputs)" ;;
    3) echo "build system not approved (an older ceph-sbom: update the" \
      "checkout, current versions record the approval instead)" ;;
    4) echo "invariant error: the build facts are incomplete or inconsistent" ;;
    5) echo "tool failure (an external tool failed or an input is unreadable)" ;;
    *) echo "unexpected exit code" ;;
  esac
}

assembler_exit_meaning() {
  case "${1}" in
    2) echo "usage error" ;;
    3) echo "facts refused (not deliverable)" ;;
    4) echo "a generated document failed its own validation" ;;
    *) echo "unexpected exit code" ;;
  esac
}

generate_sbom() {
  local facts="${sbom_out}/build-facts.json"
  local rc

  mkdir -p "${sbom_out}" || return 1

  echo "SBOM: crawling the build in ${topdir}"
  python3 "${sbom_tool}/crawl_ceph_build.py" \
    --mode cbs \
    --topdir "${topdir}" \
    --worktree "${worktree}" \
    --regenerate-file-api \
    --patches "${patches}" \
    -o "${facts}"
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo "error: SBOM crawler failed with exit code ${rc}:" \
      "$(crawler_exit_meaning "${rc}")" >&2
    return 1
  fi

  echo "SBOM: assembling the Build SBOMs into ${sbom_out}"
  python3 "${sbom_tool}/assemble_rpm_sboms.py" \
    --facts "${facts}" \
    --config "${sbom_tool}/config/assembler-clyso.json" \
    --out "${sbom_out}"
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo "error: SBOM assembler failed with exit code ${rc}:" \
      "$(assembler_exit_meaning "${rc}")" >&2
    return 1
  fi
}

trap cleanup_build_tree EXIT

generate_sbom || exit 1
