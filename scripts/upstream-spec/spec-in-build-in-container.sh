#!/usr/bin/env bash
#
# Runs INSIDE the openRuyi container (invoked by run-spec-in-build.sh): validate the
# UPSTREAM ceph.spec.in the way a distro build would. Two phases, selected by PHASE:
#
#   PHASE=deps  install everything that does not change per build -- rpm tooling,
#               make-dist's tools, gcc-c++, sccache, the temp OBS repo and `dnf
#               builddep` of the spec -- then record the package hash in /deps-meta;
#               the host commits the container into the deps image.
#   PHASE=build (default, FROM the deps image): upstream make-dist turns ceph.spec.in
#               into ceph.spec + the Source0 tarball, then rpmbuild validates it:
#          ctest mode (default): -bc (%prep+%build, tree kept) -> our ctest on the
#            tree -> -bi --short-circuit (%install) -> -bl (%files vs BUILDROOT). The
#            spec deletes the build tree in %install, so -bb then ctest is impossible.
#          SKIP_CTEST=1: a full -bb (real rpms + %install/%files).
#
# Env in (set by run-spec-in-build.sh): PHASE, NPROC, CHECK_MAKEOPTS, TEMP_OBS_REPO,
#   RESUME, FILES_ONLY, SKIP_CTEST, MAKE_DIST_FULL (see the host driver's header).
#   The ceph checkout is bind-mounted rw at /ceph (make-dist writes into it).
set -euo pipefail
# shellcheck source=scripts/lib/spec-container.sh
source /spec-lib.sh

CEPH_SRC=/ceph                 # bind-mounted clean upstream checkout
STATE=/state                   # bind-mounted: persists the generated spec for RESUME

# stage_throwaway_spec: a spec straight from ceph.spec.in for the deps phase, so
# `dnf builddep` has one before make-dist runs. BuildRequires ignore the version, so
# the placeholder values do not matter.
stage_throwaway_spec() {
    rpmdev-setuptree
    sed -e 's/@PROJECT_VERSION@/0/g' \
        -e 's/@RPM_RELEASE@/0/g' \
        -e 's/@TARBALL_BASENAME@/ceph-0/g' \
        "${CEPH_SRC}/ceph.spec.in" > "${RB}/SPECS/ceph.spec"
}

# ============================================================================
# PHASE=deps
# ============================================================================
if [ "${PHASE}" = deps ]; then
    # git/wget/bzip2/python3/findutils are make-dist's own tools (git-archive-all,
    # the boost/liburing/pmdk downloads, the rook client gen).
    deps_install_tooling git wget bzip2 python3 findutils
    deps_enable_temp_obs_repo
    if [ "${TEMP_OBS_REPO:-0}" = 1 ]; then
        # The %openruyi macro that selects ceph.spec.in's openRuyi BuildRequires branch
        # ships only in the temp project's openruyi-release, and builddep never upgrades
        # an installed package. Without it the spec takes the Fedora branch and builddep
        # dies on "No match". (rva20 seeds the macro directly, see
        # publish-openruyi-image.sh.)
        echo "=== deps phase: upgrade openruyi-release from temp repo (pull in %openruyi macro) ==="
        dnf upgrade -y openruyi-release
    fi
    stage_throwaway_spec
    deps_builddep "${RB}/SPECS/ceph.spec"
    deps_finish
    exit 0
fi

# ============================================================================
# PHASE=build: everything above is present from the deps image; no dnf here.
# ============================================================================
rpmdev-setuptree

# run_make_dist: ceph.spec.in -> ceph.spec + ceph-<ver>.tar.bz2, staged into
# ~/rpmbuild; the spec is also kept in /state so RESUME can restage it.
run_make_dist() {
    echo "=== build phase: make-dist (generate spec + Source0 tarball) ==="
    local script=./make-dist
    if [ "${MAKE_DIST_FULL:-0}" != 1 ]; then
        # The dashboard-frontend npm build is heavy, flaky on riscv64 and unused (the
        # spec's %build sets it OFF); drop that step from a copy.
        echo "  (skipping dashboard frontend npm build; set MAKE_DIST_FULL=1 for vanilla make-dist)"
        script=/tmp/make-dist.run
        sed -e '/^build_dashboard_frontend$/d' \
            -e '/^[[:space:]]*dashboard_frontend[[:space:]]*\\$/d' \
            "${CEPH_SRC}/make-dist" > "${script}"
    else
        echo "  (MAKE_DIST_FULL=1: running vanilla upstream make-dist, dashboard frontend included)"
    fi
    # Pin the dist version to the nearest tag (make-dist's default embeds the sha) so
    # the build path is stable across commits and sccache keeps hitting.
    local dist_ver="${MAKE_DIST_VERSION:-}"
    if [ -z "${dist_ver}" ]; then
        dist_ver="$(cd "${CEPH_SRC}" && git describe --long --match 'v*' 2>/dev/null \
            | sed 's/^v//; s/-g[0-9a-f]\+$//; s/-[0-9]\+$//')"
    fi
    [ -n "${dist_ver}" ] || { echo "ERROR: could not derive a dist version (git describe failed); set MAKE_DIST_VERSION" >&2; exit 1; }
    echo "  pinning dist version -> ${dist_ver} (override via MAKE_DIST_VERSION)"
    ( cd "${CEPH_SRC}" && bash "${script}" "${dist_ver}" )

    local tarball
    tarball="$(find "${CEPH_SRC}" -maxdepth 1 -name 'ceph-*.tar.bz2' -printf '%T@ %p\n' \
        2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    [ -n "${tarball}" ] && [ -f "${tarball}" ] || {
        echo "ERROR: make-dist produced no ceph-*.tar.bz2 in ${CEPH_SRC}" >&2; exit 1; }
    [ -f "${CEPH_SRC}/ceph.spec" ] || {
        echo "ERROR: make-dist produced no ceph.spec in ${CEPH_SRC}" >&2; exit 1; }
    echo "  tarball: $(basename "${tarball}")  spec: ceph.spec"
    cp -f "${tarball}" "${RB}/SOURCES/"
    cp -f "${CEPH_SRC}/ceph.spec" "${RB}/SPECS/ceph.spec"
    [ -d "${STATE}" ] && cp -f "${CEPH_SRC}/ceph.spec" "${STATE}/ceph.spec"
    # Leave the checkout as make-dist found it (it also drops a `ln -s . ceph-<ver>`).
    rm -f "${tarball}" "${CEPH_SRC}/ceph.spec" 2>/dev/null || true
    rm -f "${CEPH_SRC}"/ceph-*[0-9] 2>/dev/null || true
}

# restage_persisted_spec: RESUME/FILES_ONLY reuse the previous run's spec and tarball.
restage_persisted_spec() {
    if [ -f "${STATE}/ceph.spec" ]; then
        cp -f "${STATE}/ceph.spec" "${RB}/SPECS/ceph.spec"
    elif [ ! -f "${RB}/SPECS/ceph.spec" ]; then
        echo "ERROR: RESUME/FILES_ONLY but no persisted spec at ${STATE}/ceph.spec;" >&2
        echo "       run a full build (RESUME/FILES_ONLY unset) first." >&2
        exit 1
    fi
    ls "${RB}"/SOURCES/ceph-*.tar.bz2 >/dev/null 2>&1 || {
        echo "ERROR: RESUME/FILES_ONLY but no Source tarball in ${RB}/SOURCES;" >&2
        echo "       run a full build first." >&2; exit 1; }
}

SPEC="${RB}/SPECS/ceph.spec"
# _smp_build_ncpus caps the %cmake_build / BOOST_J parallelism at NPROC.
SMP_DEF=(--define "_smp_build_ncpus ${NPROC:-$(nproc)}")
# No LTO, as the openRuyi downstream ceph.spec sets: openRuyi's default optflags carry
# -flto=auto, and the make_check link of ceph_test_keyvaluedb_atomicity then fails on
# LTO-deferred symbols from static archive members. Upstream ceph.spec.in has no
# override, so apply it at rpmbuild time.
LTO_DEF=(--define "_lto_cflags %{nil}")

# FILES_ONLY: re-check %files against the BUILDROOT a prior run left under the
# persisted BUILD/ tree.
if [ "${FILES_ONLY:-0}" = 1 ]; then
    echo "=== build phase: FILES_ONLY -- rpmbuild -bl (%files vs persisted BUILDROOT) ==="
    restage_persisted_spec
    rpmbuild -bl --with make_check "${SMP_DEF[@]}" "${LTO_DEF[@]}" "${SPEC}"
    echo "=== build phase: FILES_ONLY done (rc=0) ==="
    exit 0
fi

if [ "${RESUME:-0}" = 1 ]; then
    echo "=== build phase: RESUME -- reuse persisted spec/tarball + BUILD/ tree ==="
    restage_persisted_spec
else
    run_make_dist
fi

sccache_enable

# SKIP_CTEST: full packaging. -bb runs %prep/%build/%install/%files and emits real
# rpms; without ctest the spec may delete the build tree in %install.
if [ "${SKIP_CTEST:-0}" = 1 ]; then
    PREP_OPT=""; [ "${RESUME:-0}" = 1 ] && PREP_OPT="--noprep"
    echo "=== build phase: rpmbuild -bb ${PREP_OPT} --with make_check (full packaging, no ctest) ==="
    # shellcheck disable=SC2086  # PREP_OPT is empty or one flag
    rpmbuild -bb ${PREP_OPT} --with make_check "${SMP_DEF[@]}" "${LTO_DEF[@]}" "${SPEC}"
    sccache_stats
    echo "=== build phase: SKIP_CTEST -- packaging validated, rpms in RPMS/ (rc=0) ==="
    exit 0
fi

# ctest mode: -bc keeps the build tree (RESUME -> --short-circuit skips %prep).
BC_OPT=""; [ "${RESUME:-0}" = 1 ] && BC_OPT="--short-circuit"
echo "=== build phase: rpmbuild -bc ${BC_OPT} --with make_check (%prep+%build, keep tree) ==="
# shellcheck disable=SC2086  # BC_OPT is empty or one flag
rpmbuild -bc ${BC_OPT} --with make_check "${SMP_DEF[@]}" "${LTO_DEF[@]}" "${SPEC}"

locate_build_tree
run_ctest

# %install on the kept tree (its trailing rm -rf of the vpath is fine, ctest already
# ran), then %files against the BUILDROOT it populated. No rpms in this mode.
echo "=== build phase: rpmbuild -bi --short-circuit --with make_check (validate %install) ==="
rpmbuild -bi --short-circuit --with make_check "${SMP_DEF[@]}" "${LTO_DEF[@]}" "${SPEC}"
echo "=== build phase: rpmbuild -bl --with make_check (validate %files vs BUILDROOT) ==="
rpmbuild -bl --with make_check "${SMP_DEF[@]}" "${LTO_DEF[@]}" "${SPEC}"

echo "=== spec.in validation done: rc=${RC} (ctest result; %build/%install/%files all passed) ==="
exit "${RC}"
