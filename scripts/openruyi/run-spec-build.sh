#!/usr/bin/env bash
#
# spec-openruyi driver: validate the openRuyi downstream ceph spec (openruyi/) the way
# OBS does, minus OBS. rpmbuild runs in the openRuyi container (the container half is
# spec-build-in-container.sh), then our ctest runs on the spec's own build tree. This
# side sets up the image, proxy, persistent caches and ctest options.
#
# %prep is the spec's own (submodule tarballs, isa-l swap, %autopatch), and the build
# is its real downstream config (WITH_CRIMSON=OFF, RelWithDebInfo, no ASan).
#
# Env overrides:
#   WORKDIR       parent of the per-CI buckets (default: this repo's parent dir);
#                 this CI lives entirely under ${WORKDIR}/spec-openruyi/
#   NPROC         build parallelism (default set below)
#   CTEST_JOBS    ctest -j (default $(nproc))
#   CONTAINER_ENGINE  podman (default) or docker
#   TEMP_OBS_REPO 1 to add the temporary OBS project as a priority=1 dnf repo so
#                 deps it publishes win over the stock repos (on this site it carries
#                 the spec's promtool BuildRequire); 0 (default) = stock repos only
#   TEMP_OBS_PROJECT  the OBS project TEMP_OBS_REPO=1 adds. Site-specific, so it has
#                 no default; TEMP_OBS_REPO=1 without it is an error.
#   REBUILD_DEPS  1 to refresh the cached deps image in place (picks up rolling
#                 openRuyi package updates; commits only if the package set changed).
#                 Default 0 reuses it while its fingerprint holds (spec BuildRequires
#                 + TEMP_OBS_REPO + base image id).
#   GIT_PROXY     proxy for external network (spectool fetches github/boost.io);
#                 unset = auto-probe via CI_PROXY_PROBE; 'direct' forces none
#   CI_PROXY_PROBE  the proxy to probe for. Site-specific, so it has no default;
#                 unset means the run goes direct.
#   CI_PROXY_PROBE_URL / CI_PROXY_PROBE_RETRIES / CI_PROXY_PROBE_DELAY
#                 proxy auto-detect knobs; CI_NO_PROXY hosts bypass the proxy
#                 (defaults in scripts/lib/site.sh)
#   FLAKE_RETRIES ctest --repeat until-pass count for known flakes (default 2)
#   OFFLINE       1 to reuse the cached local image instead of pulling
#   SCCACHE_CACHE_SIZE  sccache max cache size (default 100G)
#   OPENRUYI_BUILD_DIR / OPENRUYI_SCCACHE_HOST_DIR / OPENRUYI_TD_TMPFS_DIR
#                 location overrides for the persisted BUILD/ tree, the sccache cache
#                 and the standalone-test tmpfs td dir (defaults under the bucket and
#                 /dev/shm; prefixed so they never collide with another CI's)
#
# Incremental re-run knobs. The BUILD/ tree (cmake build + nested BUILDROOT) is
# bind-mounted from the bucket and survives the container:
#   FILES_ONLY=1  re-run only the %files check (rpmbuild -bl) against the BUILDROOT a
#                 prior run left behind -- seconds, no compile or install, no ctest.
#   RESUME=1      reuse the persisted BUILD/ tree: --noprep skips %prep, %build is a
#                 ninja incremental. Do a full run after changing patches or Sources.
#   SKIP_CTEST=1  stop once rpmbuild succeeds (rpms are on the host via RPMS/).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENRUYI_DIR="${REPO_ROOT}/openruyi"
WORKDIR="${WORKDIR:-$(dirname "${REPO_ROOT}")}"
source "${REPO_ROOT}/scripts/lib/site.sh"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/spec-host.sh"
# This CI owns ${WORKDIR}/spec-openruyi/; nothing is shared with the other two.
BASE="${WORKDIR}/spec-openruyi"
mkdir -p "${BASE}"
ENGINE="${CONTAINER_ENGINE:-podman}"
NPROC="${NPROC:-50}"
CTEST_JOBS="${CTEST_JOBS:-$(nproc)}"
DEPS_IMAGE="localhost/openruyi-deps:riscv64"
BUILD_CONTAINER="ceph_openruyi_build"
DEPS_CONTAINER="openruyi_deps_build"
SPEC_CONTAINER_SCRIPT="${REPO_ROOT}/scripts/openruyi/spec-build-in-container.sh"

# Off unless the site configures a project (TEMP_OBS_PROJECT).
ci_bool TEMP_OBS_REPO 0
ci_require_temp_obs
ci_bool REBUILD_DEPS 0
ci_bool RESUME 0
ci_bool FILES_ONLY 0
ci_bool SKIP_CTEST 0

[ -f "${OPENRUYI_DIR}/ceph.spec" ] || {
    echo "ERROR: ${OPENRUYI_DIR}/ceph.spec not found" >&2; exit 1; }
ci_require_riscv64
ci_open_run_log
ci_trap_cleanup "${BUILD_CONTAINER}" "${DEPS_CONTAINER}"
# spectool fetches Source0..33 from github.com and archives.boost.io; podman forwards
# *_proxy into the container.
ci_resolve_proxy

echo "=== ceph-ci openRuyi spec validation ==="
echo "  spec=${OPENRUYI_DIR}/ceph.spec  base=${BASE}  engine=${ENGINE}"
echo "  NPROC=${NPROC}  CTEST_JOBS=${CTEST_JOBS}  proxy='${CI_PROXY}' (empty=direct)"
echo "  TEMP_OBS_REPO=${TEMP_OBS_REPO} ($(ci_temp_obs_desc))"
ci_ctest_makeopts

spec_host_dirs OPENRUYI openruyi

# The persisted BUILD tree and the rpm output are keyed by ceph version, so keep only
# the newest (the previous run, still usable for RESUME/FILES_ONLY) and drop the rest;
# this run then adds its own, so at most two versions are ever on disk.
while read -r old_tree; do
    echo "  pruning BUILD tree of an older version: ${old_tree}"
    rm -rf "${old_tree}"
done < <(ci_newest_first "${BUILD_PERSIST}"/ceph-*-build | tail -n +2)
# main-package rpm names carry the version: ceph-<ver>-<rel>.<arch>.rpm
keep_vr=""
while read -r main_rpm; do
    vr="$(basename "${main_rpm}")"; vr="${vr#ceph-}"; vr="${vr%.*.rpm}"
    if [ -z "${keep_vr}" ]; then keep_vr="${vr}"; continue; fi
    [ "${vr}" = "${keep_vr}" ] && continue
    echo "  pruning rpms of an older version: ${vr}"
    rm -f "${RPMS_OUT}"/*/*-"${vr}".*.rpm
done < <(ci_newest_first "${RPMS_OUT}"/*/ceph-[0-9]*.rpm)
echo "  RESUME=${RESUME} FILES_ONLY=${FILES_ONLY} SKIP_CTEST=${SKIP_CTEST}  BUILD persist=${BUILD_PERSIST}"

# 1. base image, deps image
OFFLINE="${OFFLINE:-0}" "${REPO_ROOT}/scripts/fetch-openruyi-image.sh"
ci_container_proxy_env
spec_deps_fingerprint "${OPENRUYI_DIR}/ceph.spec"
spec_deps_image_ensure -v "${OPENRUYI_DIR}:/spec:ro"

# 2. rpmbuild + ctest in the container
ci_mem_sampler_start
spec_build_run -v "${OPENRUYI_DIR}:/spec:ro"
ci_mem_sampler_stop

echo "=== spec validation done: rc=${RC} ==="
echo "  rpms:      ${RPMS_OUT}"
echo "  artifacts: ${ARTIFACTS}"
echo "  sccache:   ${SCCACHE_HOST_DIR} (max ${SCCACHE_CACHE_SIZE})"
echo "  mem log:   ${MEM_LOG}"
exit "${RC}"
