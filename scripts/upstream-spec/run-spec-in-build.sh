#!/usr/bin/env bash
#
# spec-upstream driver: validate the UPSTREAM ceph.spec.in the way a distro build
# would. Upstream make-dist turns ceph.spec.in into a real ceph.spec + Source0 tarball
# inside the openRuyi container, rpmbuild builds it, then our ctest runs on the spec's
# build tree (the container half is spec-in-build-in-container.sh). Counterpart of
# scripts/openruyi/run-spec-build.sh, which validates the DOWNSTREAM spec.
#
# The checkout is pristine upstream unless scripts/upstream-spec/*.patch exist:
# those are applied and committed before make-dist (its tarball is `git archive
# HEAD`), to validate a patch bound for upstream.
#
# Env overrides:
#   CEPH_REPO     upstream ceph git URL (default https://github.com/ceph/ceph.git)
#   CEPH_REF      branch/tag/sha to validate (default main)
#   WORKDIR       parent of the per-CI buckets (default: this repo's parent dir);
#                 this CI lives entirely under ${WORKDIR}/spec-upstream/
#   NPROC         build parallelism (default set below)
#   CTEST_JOBS    ctest -j (default $(nproc))
#   CONTAINER_ENGINE  podman (default) or docker
#   MAKE_DIST_FULL 0 (default) skip make-dist's dashboard-frontend npm build (heavy,
#                 flaky on riscv64, and unused: the spec's %build sets it OFF);
#                 1 = vanilla upstream make-dist
#   TEMP_OBS_REPO 1 to add the temporary OBS project as a priority=1 dnf repo so
#                 packages it publishes win; 0 (default) = stock openRuyi repos only
#   TEMP_OBS_PROJECT  the OBS project TEMP_OBS_REPO=1 adds. Site-specific, so it has
#                 no default; TEMP_OBS_REPO=1 without it is an error.
#   REBUILD_DEPS  1 to refresh the cached deps image in place (picks up rolling
#                 openRuyi updates; commits only if the package set changed). Default
#                 0 reuses it while its fingerprint holds.
#   GIT_PROXY     proxy for external network (clone + make-dist's boost/liburing/pmdk
#                 downloads); unset = auto-probe via CI_PROXY_PROBE; 'direct' forces none
#   CI_PROXY_PROBE  the proxy to probe for. Site-specific, so it has no default;
#                 unset means the run goes direct.
#   CI_PROXY_PROBE_URL / CI_PROXY_PROBE_RETRIES / CI_PROXY_PROBE_DELAY
#                 proxy auto-detect knobs; CI_NO_PROXY hosts bypass the proxy
#                 (defaults in scripts/lib/site.sh)
#   FLAKE_RETRIES ctest --repeat until-pass count for known flakes (default 2)
#   OFFLINE       1 to reuse the cached local base image instead of pulling
#   SCCACHE_CACHE_SIZE  sccache max cache size (default 100G)
#   SPECIN_BUILD_DIR / SPECIN_SCCACHE_HOST_DIR / SPECIN_TD_TMPFS_DIR
#                 location overrides for the persisted BUILD/ tree, the sccache cache
#                 and the standalone-test tmpfs td dir (defaults under the bucket and
#                 /dev/shm; prefixed so they never collide with another CI's)
#
# Incremental re-run knobs (the BUILD/ tree is bind-mounted from the bucket and
# survives the container):
#   SKIP_CTEST=1  stop after a full `rpmbuild -bb` (real rpms in RPMS/, %install and
#                 %files validated); the fast path for pure spec checks.
#   RESUME=1      reuse the persisted spec/tarball + BUILD/ tree: skip clone and
#                 make-dist, rpmbuild skips %prep. Full run after changing CEPH_REF.
#   FILES_ONLY=1  re-run only the %files check (rpmbuild -bl) against the BUILDROOT a
#                 prior run left behind. No make-dist, no ctest.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKDIR="${WORKDIR:-$(dirname "${REPO_ROOT}")}"
CEPH_REPO="${CEPH_REPO:-https://github.com/ceph/ceph.git}"
CEPH_REF="${CEPH_REF:-main}"
source "${REPO_ROOT}/scripts/lib/site.sh"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/spec-host.sh"
# This CI owns ${WORKDIR}/spec-upstream/; nothing is shared with the other two.
BASE="${WORKDIR}/spec-upstream"
mkdir -p "${BASE}"
ENGINE="${CONTAINER_ENGINE:-podman}"
# A dedicated clean checkout: the build-check one carries the fork patches.
CEPH_SRC="${BASE}/ceph"
NPROC="${NPROC:-50}"
CTEST_JOBS="${CTEST_JOBS:-$(nproc)}"
DEPS_IMAGE="localhost/specin-deps:riscv64"
BUILD_CONTAINER="ceph_specin_build"
DEPS_CONTAINER="specin_deps_build"
SPEC_CONTAINER_SCRIPT="${REPO_ROOT}/scripts/upstream-spec/spec-in-build-in-container.sh"

# Off unless the site configures a project (TEMP_OBS_PROJECT).
ci_bool TEMP_OBS_REPO 0
ci_require_temp_obs
ci_bool REBUILD_DEPS 0
ci_bool MAKE_DIST_FULL 0
ci_bool RESUME 0
ci_bool FILES_ONLY 0
ci_bool SKIP_CTEST 0

ci_require_riscv64
ci_open_run_log
ci_trap_cleanup "${BUILD_CONTAINER}" "${DEPS_CONTAINER}"
# The host clone and make-dist's tarball downloads go through the proxy.
ci_resolve_proxy

echo "=== ceph-ci upstream ceph.spec.in validation ==="
echo "  repo=${CEPH_REPO} ref=${CEPH_REF}  checkout=${CEPH_SRC}"
echo "  base=${BASE}  engine=${ENGINE}  NPROC=${NPROC}  CTEST_JOBS=${CTEST_JOBS}"
echo "  proxy='${CI_PROXY}' (empty=direct)  MAKE_DIST_FULL=${MAKE_DIST_FULL} (0=skip dashboard npm)"
echo "  TEMP_OBS_REPO=${TEMP_OBS_REPO}  RESUME=${RESUME} FILES_ONLY=${FILES_ONLY} SKIP_CTEST=${SKIP_CTEST}"
ci_ctest_makeopts

# ----------------------------------------------------------------------------
# 1. Clean upstream checkout (no fork patches). Skipped on RESUME/FILES_ONLY, which
#    reuse the persisted spec/tarball + BUILD/ tree.
# ----------------------------------------------------------------------------
# Proxy pin, stall guard and credential prompt off (scripts/lib/common.sh).
ci_git_net_args
if [ "${RESUME}" = 1 ] || [ "${FILES_ONLY}" = 1 ]; then
    [ -d "${CEPH_SRC}/.git" ] || {
        echo "ERROR: RESUME/FILES_ONLY but no checkout at ${CEPH_SRC}; run a full build first." >&2
        exit 1; }
    echo "=== RESUME/FILES_ONLY: reuse existing checkout (skip clone/fetch/make-dist) ==="
else
    # --tags: make-dist derives the dist version from `git describe --match v*`.
    ci_checkout_ceph "${CEPH_REPO}" "${CEPH_REF}" "${CEPH_SRC}" --tags

    # Patches under test are COMMITTED: make-dist's tarball is `git archive HEAD`. The
    # deps fingerprint comes from the patched ceph.spec.in, so a BuildRequires change
    # rebuilds the deps image. Next run's `checkout --force` discards the commit.
    shopt -s nullglob
    _patches=( "${REPO_ROOT}/scripts/upstream-spec/"*.patch )
    shopt -u nullglob
    if [ "${#_patches[@]}" -gt 0 ]; then
        echo "=== applying ${#_patches[@]} patch(es) from scripts/upstream-spec/ ==="
        for _p in "${_patches[@]}"; do
            echo "  ${_p##*/}"
            # --3way tolerates minor base drift.
            if ! git -C "${CEPH_SRC}" apply --3way --whitespace=nowarn "${_p}"; then
                echo "ERROR: failed to apply ${_p##*/} onto ${CEPH_REF}; rebase the patch." >&2
                exit 1
            fi
        done
        # A patch may bump a submodule gitlink, which `git add -A` would re-stage from
        # the still-old worktree; check the submodules out to the index gitlink first.
        ci_submodule_sync "${CEPH_SRC}"
        git -C "${CEPH_SRC}" add -A
        git -C "${CEPH_SRC}" -c user.name="ceph-ci" -c user.email="ceph-ci@localhost" \
            commit -s -q -m "ceph-ci: apply scripts/upstream-spec patches for validation"
        echo "  patched HEAD: $(git -C "${CEPH_SRC}" rev-parse --short HEAD)"
    else
        echo "  no patches in scripts/upstream-spec/ -- pristine upstream build"
    fi
fi

# ----------------------------------------------------------------------------
# 2. Persistent host dirs, base image, deps image. state/ keeps the make-dist
#    generated ceph.spec so RESUME can restage it.
# ----------------------------------------------------------------------------
spec_host_dirs SPECIN specin
STATE_DIR="${BASE}/state"
mkdir -p "${STATE_DIR}"
OFFLINE="${OFFLINE:-0}" "${REPO_ROOT}/scripts/fetch-openruyi-image.sh"
ci_container_proxy_env
spec_deps_fingerprint "${CEPH_SRC}/ceph.spec.in"
spec_deps_image_ensure -v "${CEPH_SRC}:/ceph:ro"

# ----------------------------------------------------------------------------
# 3. make-dist + rpmbuild + ctest in the container. The checkout is bind-mounted rw
#    for make-dist's tarball and spec.
# ----------------------------------------------------------------------------
ci_mem_sampler_start
spec_build_run \
    -e "MAKE_DIST_FULL=${MAKE_DIST_FULL}" \
    -v "${CEPH_SRC}:/ceph:Z" \
    -v "${STATE_DIR}:/state:Z"
ci_mem_sampler_stop

echo "=== upstream spec.in validation done: rc=${RC} ==="
echo "  checkout:  ${CEPH_SRC}"
echo "  rpms:      ${RPMS_OUT} (populated only in SKIP_CTEST mode)"
echo "  artifacts: ${ARTIFACTS}"
echo "  sccache:   ${SCCACHE_HOST_DIR} (max ${SCCACHE_CACHE_SIZE})"
echo "  mem log:   ${MEM_LOG}"
exit "${RC}"
