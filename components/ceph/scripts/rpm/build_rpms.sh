#!/bin/bash

# CES - build Ceph RPMs
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

build_ceph_rpms() {
  local ceph_dir="${CBS_WORKTREE:?}"
  local dist_version=".el${CBS_TARGET_OS_VERSION:?}.clyso"
  local topdir="${CBS_TOPDIR:-${HOME}/rpmbuild}"
  local version="${CBS_VERSION:?}"

  if [[ -n ${CES_CCACHE_PATH} ]]; then
    echo "CES build rpms with CCACHE: ${CES_CCACHE_PATH}"
    CCACHE_DIR="${CES_CCACHE_PATH}"
    export CCACHE_DIR

    CEPH_EXTRA_CMAKE_ARGS="-DWITH_CCACHE=ON"
  fi

  for i in BUILD SOURCES RPMS SRPMS SPECS; do
    mkdir -p "${topdir}/${i}" || true
  done

  echo "Include building boost with valgrind support"
  CEPH_EXTRA_CMAKE_ARGS="${CEPH_EXTRA_CMAKE_ARGS} -DWITH_SYSTEM_BOOST=OFF -DWITH_BOOST_VALGRIND=ON"
  echo "cmake extra args: ${CEPH_EXTRA_CMAKE_ARGS}"

  export CEPH_EXTRA_CMAKE_ARGS

  echo "Build Ceph SRPMs and RPMs"

  pushd "${ceph_dir}" >/dev/null || exit 1
  git submodule sync --recursive || exit 1
  git submodule update --init --recursive || exit 1

  ./make-dist "${version}" || exit 1

  echo "move ceph tarball to ${topdir}/SOURCES/"
  mv "ceph-${version}.tar.bz2" "${topdir}"/SOURCES/ || exit 1

  echo "building srpms"
  rpmbuild \
    --without=crimson \
    --define "_topdir ${topdir}" \
    --define "dist ${dist_version}" \
    -bs ceph.spec || exit 1

  if [[ -n ${CBS_SBOM_TOOL} ]]; then
    build_ceph_rpms_for_sbom "${topdir}" "${dist_version}" || exit 1
    popd >/dev/null || exit 1
    return 0
  fi

  echo "building rpms"
  rpmbuild \
    --without=crimson \
    --define "_topdir ${topdir}" \
    --define "dist ${dist_version}" \
    --define "_lto_cflags -flto=3 -ffat-lto-objects" \
    --without=dwz \
    -rb "${topdir}"/SRPMS/*.src.rpm || exit 1

  popd >/dev/null || exit 1
}

# SBOM variant of the binary build, used only when CBS sets CBS_SBOM_TOOL (the
# ceph-sbom checkout). Must be called from the worktree, after the srpm has
# been built. It differs from the plain build in three ways:
#
#   1. cmake is configured with ceph-sbom's configure hook and the package
#      identity, so the linker records its inputs and stamps an ELF package
#      note (epoch:version-release) into every linked file;
#   2. the srpm is installed and built with 'rpmbuild -bb --noclean' instead
#      of 'rpmbuild -rb', which always deletes the build tree -- the crawler
#      (scripts/rpm/sbom.sh) reads that tree after the build;
#   3. stale BUILD/ and BUILDROOT/ contents are removed first, since the
#      topdir is reused across builds of the same version and the crawler
#      refuses more than one build tree.
build_ceph_rpms_for_sbom() {
  local topdir="${1:?}"
  local dist_version="${2:?}"
  local sbom_hook="${CBS_SBOM_TOOL}/cephsbom/data/ceph-sbom-configure.cmake"
  local rpm_evr rpm_nvr os_cpe srpm

  [[ -f ${sbom_hook} ]] || {
    echo "error: SBOM configure hook not found at '${sbom_hook}'" >&2
    return 1
  }

  # The exact epoch:version-release rpm will give the packages. It must match
  # what the crawler reads from the built rpms, which writes an unset epoch as
  # 'version-release' (no '0:' prefix) and a set one as 'epoch:version-release'.
  # rpmspec has no --without alias; '_without_crimson' is what rpmbuild's
  # '--without=crimson' expands to.
  rpm_evr="$(rpmspec -q --srpm \
    --define "_without_crimson --without-crimson" \
    --define "_topdir ${topdir}" \
    --define "dist ${dist_version}" \
    --qf '%{EPOCH}:%{VERSION}-%{RELEASE}\n' ceph.spec | head -n 1)"
  [[ -n ${rpm_evr} && ${rpm_evr} != *"(none)-"* ]] || {
    echo "error: unable to determine the rpm version from ceph.spec" >&2
    return 1
  }
  rpm_evr="${rpm_evr#'(none):'}"
  rpm_nvr="ceph-${rpm_evr#*:}"
  echo "SBOM: rpm package version: ${rpm_evr}"

  # shellcheck disable=SC1091
  os_cpe="$(. /etc/os-release 2>/dev/null && echo "${CPE_NAME}")"

  CEPH_EXTRA_CMAKE_ARGS="${CEPH_EXTRA_CMAKE_ARGS} -DCMAKE_PROJECT_INCLUDE=${sbom_hook}"
  CEPH_EXTRA_CMAKE_ARGS="${CEPH_EXTRA_CMAKE_ARGS} -DCEPH_SBOM_PACKAGE_NAME=ceph"
  CEPH_EXTRA_CMAKE_ARGS="${CEPH_EXTRA_CMAKE_ARGS} -DCEPH_SBOM_PACKAGE_VERSION=${rpm_evr}"
  if [[ -n ${os_cpe} ]]; then
    CEPH_EXTRA_CMAKE_ARGS="${CEPH_EXTRA_CMAKE_ARGS} -DCEPH_SBOM_PACKAGE_OS_CPE=${os_cpe}"
  else
    echo "SBOM: no CPE_NAME in /etc/os-release, building without an OS CPE"
  fi
  echo "cmake extra args: ${CEPH_EXTRA_CMAKE_ARGS}"
  export CEPH_EXTRA_CMAKE_ARGS

  echo "SBOM: removing stale build trees from ${topdir}"
  for i in BUILD BUILDROOT; do
    if [[ -d "${topdir}/${i}" ]]; then
      find "${topdir}/${i}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || return 1
    fi
  done

  # The srpm built above, by its exact name: SRPMS/ may also hold other srpms
  # from earlier runs in this topdir (ceph-release, for one).
  srpm="${topdir}/SRPMS/${rpm_nvr}.src.rpm"
  [[ -f ${srpm} ]] || {
    echo "error: expected srpm '${srpm}' not found" >&2
    return 1
  }

  echo "installing ${srpm}"
  rpm -i --define "_topdir ${topdir}" "${srpm}" || return 1

  echo "building rpms (keeping the build tree for the SBOM)"
  rpmbuild \
    --without=crimson \
    --define "_topdir ${topdir}" \
    --define "dist ${dist_version}" \
    --define "_lto_cflags -flto=3 -ffat-lto-objects" \
    --without=dwz \
    -bb --noclean "${topdir}"/SPECS/ceph.spec || return 1
}

# This function was initially copied, and then heavily based, on the function
# of the same name from 'ceph/ceph-build', in 'ceph-rpm-release/build/build'.
# It has been significantly modified for CES purposes instead of upstream's.
build_ceph_release_rpm() {
  local el_version="${CBS_TARGET_OS_VERSION:?}"
  local topdir="${CBS_TOPDIR:?}"
  local version="${CBS_VERSION:?}"

  echo "Build Ceph RPM release package"

  summary="CES Ceph repository configuration"
  project_url=https://www.clyso.com/
  epoch=1 # means a non-development release (0 would be development)
  # Artifact locations are injected by the backend (CBS_* env contract) —
  # never hardcoded here: pointing a deployment at a different bucket is a
  # config change (storage.s3.public-url, signing.key-url).
  repo_base_url="${CBS_COMPONENT_REPO_URL:?}"
  gpgcheck=1
  gpgkey="${CBS_RELEASE_KEY_URL:?}"
  dist_version=".el${el_version}.clyso"

  cat <<EOF >"${topdir}"/SPECS/ceph-release.spec
Name:           ceph-release
Version:        2
Release:        ${epoch}%{?dist}
Summary:        ${summary}
Group:          System Environment/Base
License:        GPLv2
URL:            ${project_url}
Source0:        ceph.repo
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch

%description
This package contains the Clyso Enterprise Storage's Ceph repository's
configuration for yum and up2date.

%prep

%setup -q  -c -T
install -pm 644 %{SOURCE0} .

%build

%install
rm -rf %{buildroot}
install -dm 755 %{buildroot}/%{_sysconfdir}/yum.repos.d
install -pm 644 %{SOURCE0} \
    %{buildroot}/%{_sysconfdir}/yum.repos.d

%clean

%post

%postun

%files
%defattr(-,root,root,-)
/etc/yum.repos.d/*

%changelog
* Sat Mar 1 2025 Joao Eduardo Luis <joao@clyso.com> 2-1
- Adjust for Clyso Enterprise Storage packages
* Fri Aug 12 2016 Alfredo Deza <adeza@redhat.com> 1-1
* Mon Jan 12 2015 Travis Rhoden <trhoden@redhat.com> 1-1
- Make .repo files be %config(noreplace)
* Sun Mar 10 2013 Gary Lowell <glowell@inktank.com> - 1-0
- Handle both yum and zypper
- Use URL to ceph git repo for key
- remove config attribute from repo file
* Mon Aug 27 2012 Gary Lowell <glowell@inktank.com> - 1-0
- Initial Package
EOF
  #  End of ceph-release.spec file.

  # Install ceph.repo file
  cat <<EOF >"${topdir}"/SOURCES/ceph.repo
[Ceph]
name=Clyso Ceph packages for \$basearch
baseurl=${repo_base_url}/\$basearch
enabled=1
gpgcheck=${gpgcheck}
type=rpm-md
gpgkey=${gpgkey}

[Ceph-noarch]
name=Clyso Ceph noarch packages
baseurl=${repo_base_url}/noarch
enabled=1
gpgcheck=${gpgcheck}
type=rpm-md
gpgkey=${gpgkey}

[ceph-source]
name=Clyso Ceph source packages
baseurl=${repo_base_url}/SRPMS
enabled=1
gpgcheck=${gpgcheck}
type=rpm-md
gpgkey=${gpgkey}
EOF
  # End of ceph.repo file

  # build source packages for official releases
  rpmbuild -ba \
    --define "_topdir ${topdir}" \
    --define "_unpackaged_files_terminate_build 0" \
    --define "dist ${dist_version}" \
    "${topdir}"/SPECS/ceph-release.spec
}

build_ceph_rpms || exit 1
build_ceph_release_rpm || exit 1
