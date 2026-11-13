#!/bin/bash
#
# Pin EPEL to the image's own minor release.
#
# EPEL 10 publishes one repository per RHEL minor release (epel/10.2,
# epel/10.3, ...). Its epel.repo builds the metalink from $releasever,
# which Rocky sets to the major release alone, so it resolves to the newest
# minor EPEL carries. Rocky ships each minor release some time after RHEL
# does; in that window EPEL serves packages built against a newer base than
# the image has (e.g. python3-pyOpenSSL needing a python3-cryptography that
# Rocky does not ship yet), and the image fails to install.
#
# Recipe pre scripts run before pre.packages, so this installs epel-release
# itself. epel.repo is %config(noreplace): a later epel-release upgrade keeps
# the pinned file.

set -euo pipefail

# shellcheck source=/dev/null
. /etc/os-release

dnf install -y --setopt=install_weak_deps=False epel-release

if [[ ! ${VERSION_ID} =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "error: cannot pin EPEL: unexpected VERSION_ID '${VERSION_ID}'" >&2
  exit 1
fi
if [[ ${VERSION_ID} != *.* ]]; then
  echo "no minor release in VERSION_ID '${VERSION_ID}': EPEL left unpinned"
  exit 0
fi

sed -i "s/\\\$releasever\\b/${VERSION_ID}/g" /etc/yum.repos.d/epel*.repo

# Every metalink must now name the minor release, followed by neither a digit
# nor a dot: epel-release has shipped two forms for EL 10, which pin to
# "epel${releasever_minor:+-z}-10.2&" and "epel-10.2${stream:+s}&".
pinned="-${VERSION_ID//./\\.}([^0-9.]|\$)"
links="$(grep -h '^metalink=' /etc/yum.repos.d/epel*.repo || true)"
if ! grep -q '^metalink=' /etc/yum.repos.d/epel.repo \
  || grep -Evq -e "${pinned}" <<<"${links}"; then
  echo "error: cannot pin EPEL to ${VERSION_ID}; the metalinks are:" >&2
  printf '%s\n' "${links}" >&2
  exit 1
fi

echo "EPEL pinned to ${VERSION_ID}"
