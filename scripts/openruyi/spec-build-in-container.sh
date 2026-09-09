#!/usr/bin/env bash
#
# Runs INSIDE the openRuyi container (invoked by run-spec-build.sh): what an OBS
# worker does for the ceph package, minus the OBS scheduling layer. Two phases,
# selected by PHASE:
#
#   PHASE=deps  install everything that does not change per build -- rpm tooling,
#               gcc-c++, sccache, the temp OBS repo and `dnf builddep` of the spec --
#               then record the package hash in /deps-meta; the host commits the
#               container into the deps image. Runs FROM the base image, or FROM the
#               existing deps image on a REBUILD_DEPS refresh.
#   PHASE=build (default, FROM the deps image): stage openruyi/ into ~/rpmbuild,
#               rpmdev-spectool the Source tarballs, rpmbuild -bb --nocheck --with
#               make_check, then run ctest on the spec's build tree with the
#               build-check tuning (the spec's own %check is a bare ctest).
#
# %prep is the spec's own (submodule tarballs, isa-l swap, %autopatch), and the build
# is its real downstream config (WITH_CRIMSON=OFF, RelWithDebInfo, no ASan).
#
# Env in (set by run-spec-build.sh): PHASE, NPROC, CHECK_MAKEOPTS, TEMP_OBS_REPO,
#   RESUME, FILES_ONLY, SKIP_CTEST (see the host driver's header).
set -euo pipefail
# shellcheck source=scripts/lib/spec-container.sh
source /spec-lib.sh

SPEC_DIR=/spec                 # bind-mounted openruyi/ (ro)

# stage_spec: the spec into ~/rpmbuild/SPECS with Release pinned to 0 -- %autorelease
# is resolved by an OBS service before the chroot sees the spec. The local (no-URL)
# Sources go along: patches and the sysusers.d files, which %sysusers_create_package
# cats while the spec is PARSED, before %prep.
stage_spec() {
    rpmdev-setuptree
    sed 's/^Release:.*%autorelease.*/Release:        0/' \
        "${SPEC_DIR}/ceph.spec" > "${RB}/SPECS/ceph.spec"
    find "${SPEC_DIR}" -maxdepth 1 -type f ! -name '*.spec' \
        -exec cp -f -t "${RB}/SOURCES/" {} +
}

# ============================================================================
# PHASE=deps
# ============================================================================
if [ "${PHASE}" = deps ]; then
    # shellcheck disable=SC2119  # the extra-package list is optional
    deps_install_tooling
    # The temp project carries the spec's `BuildRequires: promtool`, which the stock
    # repos lack.
    deps_enable_temp_obs_repo
    stage_spec
    deps_builddep "${RB}/SPECS/ceph.spec"
    deps_finish
    exit 0
fi

# ============================================================================
# PHASE=build: everything above is present from the deps image; no dnf here.
# ============================================================================
echo "=== build phase: stage spec into ${RB} ==="
stage_spec

# FILES_ONLY: re-check %files against the BUILDROOT a prior run left under the
# persisted BUILD/ tree. rpmbuild -bl only stat()s every listed path.
if [ "${FILES_ONLY:-0}" = 1 ]; then
    echo "=== build phase: FILES_ONLY -- rpmbuild -bl (%files check vs persisted BUILDROOT) ==="
    rpmbuild -bl --nocheck --with make_check \
        --define "_smp_build_ncpus ${NPROC:-$(nproc)}" \
        "${RB}/SPECS/ceph.spec"
    echo "=== build phase: FILES_ONLY done (rc=0) ==="
    exit 0
fi

echo "=== build phase: fetch Source tarballs ==="
# The local Sources are already staged; spectool fetches the URL ones into the cached
# SOURCES. Its progress bar floods a non-tty log, so surface it only on failure.
_spectool_log=/tmp/spectool.log
if rpmdev-spectool -g -C "${RB}/SOURCES" "${RB}/SPECS/ceph.spec" >"${_spectool_log}" 2>&1; then
    echo "  sources ready in ${RB}/SOURCES"
else
    echo "ERROR: rpmdev-spectool failed; output follows:" >&2
    cat "${_spectool_log}" >&2
    exit 1
fi

sccache_enable

# RESUME: --noprep skips %prep (no tarball re-extract, no isa-l swap, no %autopatch);
# %build is then a ninja incremental.
PREP_OPT=""
if [ "${RESUME:-0}" = 1 ]; then
    echo "=== build phase: RESUME -- reuse persisted BUILD/ tree, skip %prep (--noprep) ==="
    PREP_OPT="--noprep"
fi

echo "=== build phase: rpmbuild -bb --nocheck --noclean ${PREP_OPT} --with make_check ==="
# --with make_check: keep the test wiring for our ctest. --nocheck: skip the spec's
#   own %check. -bb: build + %install + package, so %files is validated too.
# --noclean: rpm 4.20's BuildSystem otherwise rm -rf's the cmake tree ctest needs.
# _smp_build_ncpus caps the %cmake_build / BOOST_J parallelism at NPROC.
# shellcheck disable=SC2086  # PREP_OPT is empty or one flag
rpmbuild -bb --nocheck --noclean ${PREP_OPT} --with make_check \
    --define "_smp_build_ncpus ${NPROC:-$(nproc)}" \
    "${RB}/SPECS/ceph.spec"

if [ "${SKIP_CTEST:-0}" = 1 ]; then
    sccache_stats
    echo "=== build phase: SKIP_CTEST -- packaging validated, skipping ctest (rc=0) ==="
    exit 0
fi

locate_build_tree
run_ctest
# The built rpms are already on the host via the bind-mounted RPMS/.

echo "=== spec build done: rc=${RC} ==="
exit "${RC}"
