# shellcheck shell=bash
# shellcheck disable=SC2034  # variables set here are read by the sourcing driver
# Shared by the two container-side spec scripts; bind-mounted at /spec-lib.sh and
# sourced by /spec-build.sh. Runs INSIDE the openRuyi container.

RB="${HOME}/rpmbuild"          # SOURCES + RPMS + BUILD are bind-mounted for persistence
OUT=/out                       # bind-mounted artifacts dir
PHASE="${PHASE:-build}"
SCCACHE_VERSION="${SCCACHE_VERSION:-v0.15.0}"
SCCACHE_REPO="${SCCACHE_REPO:-https://github.com/mozilla/sccache}"
CEPH_TEST_TIMEOUT="${CEPH_TEST_TIMEOUT:-18000}"   # per-test ctest TIMEOUT, set by the host driver

# install_sccache: the pinned mozilla/sccache release binary into /usr/local/bin, the
# same way upstream ceph/Dockerfile.build does. Not `dnf install sccache`: openRuyi may
# not package it, and another version would churn the cache shared with build-check.
# riscv64 uses the riscv64gc musl asset; a failed download means an uncached build.
install_sccache() {
    command -v sccache >/dev/null 2>&1 && return 0
    local sa surl
    sa="$(uname -m)"; [ "${sa}" = riscv64 ] && sa=riscv64gc
    surl="${SCCACHE_REPO}/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-${sa}-unknown-linux-musl.tar.gz"
    echo "  fetching ${surl}"
    if curl -sS -L "${surl}" | tar --no-anchored --strip-components=1 -C /usr/local/bin/ -xzf - sccache; then
        chmod +x /usr/local/bin/sccache
    else
        echo "  WARN: sccache download failed; deps image will build without cache"
    fi
}

# deps_install_tooling PKG...: what the deps image needs before anything parses the
# spec, plus the compiler and sccache. dnf5-plugins provides `dnf builddep`;
# cmake-rpm-macros + python-rpm-macros must precede it. OBS preinstalls gcc-c++ in
# every build chroot, so the ceph spec does not BuildRequire it. PKG adds
# path-specific tools.
deps_install_tooling() {
    echo "=== deps phase: install rpm tooling ==="
    dnf install -y rpm-build rpmdevtools dnf5-plugins cmake-rpm-macros python-rpm-macros curl tar "$@"
    echo "=== deps phase: install OBS-base compiler (gcc-c++) ==="
    dnf install -y gcc gcc-c++ make
    echo "=== deps phase: install sccache binary ==="
    install_sccache
}

# deps_enable_temp_obs_repo: install the repo file the host wrote into /deps-meta; it
# is committed into the deps image, so the build phase never needs it.
deps_enable_temp_obs_repo() {
    if [ "${TEMP_OBS_REPO:-0}" = 1 ]; then
        echo "=== deps phase: enable temp OBS repo (priority=1) ==="
        install -m 644 /deps-meta/ceph-ci-temp-obs.repo /etc/yum.repos.d/
    else
        echo "=== deps phase: TEMP_OBS_REPO=0, stock openRuyi repos only ==="
    fi
}

# deps_builddep SPEC: the spec's BuildRequires incl. the make_check test deps.
# --allowerasing: the rpm tooling pulls libudev-zero, which conflicts with the
# systemd-udev the rdma BuildRequires need; the swap converges on OBS's set.
deps_builddep() {
    echo "=== deps phase: dnf builddep (BuildRequires incl. make_check test deps) ==="
    dnf builddep -y --allowerasing --define '_with_make_check 1' "$1"
}

# deps_finish: drop the dnf caches from the image and record the installed package
# set so the host can skip the commit on a no-op refresh.
deps_finish() {
    dnf clean all >/dev/null 2>&1 || true
    if [ -d /deps-meta ]; then
        rpm -qa | sort | sha256sum | cut -d' ' -f1 > /deps-meta/pkghash
    fi
    echo "=== deps phase done: build environment ready (host decides whether to commit) ==="
}

# sccache_enable: the spec's %cmake wires no compiler launcher, so inject sccache via
# the CMAKE_<LANG>_COMPILER_LAUNCHER env CMake reads at configure time. Sets
# USE_SCCACHE.
sccache_enable() {
    USE_SCCACHE=0
    if command -v sccache >/dev/null 2>&1; then
        USE_SCCACHE=1
        export CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache
        sccache --start-server 2>/dev/null || true
        sccache --zero-stats >/dev/null 2>&1 || true
        echo "  sccache: ${SCCACHE_DIR:-?} (max ${SCCACHE_CACHE_SIZE:-?})"
    else
        echo "  sccache not in image; building without cache"
    fi
}
sccache_stats() {
    [ "${USE_SCCACHE:-0}" = 1 ] || return 0
    echo "=== sccache stats ==="
    sccache --show-stats 2>/dev/null || true
}

# locate_build_tree: the spec's cmake build tree, nested by rpm's BuildSystem as
# BUILD/<name>-<ver>-build/<name>-<ver>/<vpath>. Takes the shallowest CMakeCache.txt so
# FetchContent sub-builds never win. Sets BUILDDIR.
locate_build_tree() {
    echo "=== build phase: locate the spec's cmake build tree ==="
    BUILDDIR="$(find "${RB}/BUILD" -maxdepth 5 -name CMakeCache.txt 2>/dev/null \
        | awk '{ print length, $0 }' | sort -n | head -1 | cut -d' ' -f2- | xargs -r dirname)"
    [ -n "${BUILDDIR}" ] && [ -d "${BUILDDIR}" ] || {
        echo "ERROR: cannot find the cmake build tree under ${RB}/BUILD" >&2
        exit 1
    }
    echo "  build tree: ${BUILDDIR}"
}

# run_ctest: build the ctest 'tests' aggregate on BUILDDIR and run ctest with the
# build-check tuning, then copy Testing/ and CMakeCache.txt to /out. Sets RC.
run_ctest() {
    echo "=== build phase: build the ctest 'tests' aggregate ==="
    # add_ceph_test stamps each test with a TIMEOUT property that overrides ctest
    # --timeout, so reconfigure the tree with the riscv64 value. /usr/bin/cmake is the
    # binary %cmake used; a bare `cmake` is /usr/sbin/cmake, which flips CMAKE_COMMAND
    # in the cache and rebuilds the Boost ExternalProject.
    /usr/bin/cmake -DCEPH_TEST_TIMEOUT="${CEPH_TEST_TIMEOUT}" "${BUILDDIR}" >/dev/null
    # Most unit tests are EXCLUDE_FROM_ALL; the spec's %check builds this target.
    /usr/bin/cmake --build "${BUILDDIR}" --target tests -j"${NPROC:-$(nproc)}"
    sccache_stats

    echo "=== build phase: run ctest (build-check tuning: ${CHECK_MAKEOPTS:-<none>}) ==="
    # The bypassed %check would have exported this; the test venvs need it to reuse the
    # image's cryptography via --system-site-packages.
    export CEPH_PYTHON_SYSTEM_SITE=true
    # The standalone tests put their BlueStore block file under build/td, where this
    # host's NVMe ext4 O_DIRECT/libaio path stalls; point it at the bind-mounted tmpfs.
    rm -rf "${BUILDDIR}/td"; ln -sfn /td-tmpfs "${BUILDDIR}/td"
    set +e
    # shellcheck disable=SC2086  # CHECK_MAKEOPTS is a pre-split option string
    ( cd "${BUILDDIR}" && ctest ${CHECK_MAKEOPTS:-} )
    RC=$?
    set -e

    echo "=== build phase: collect artifacts to ${OUT} ==="
    cp -r "${BUILDDIR}/Testing" "${OUT}/" 2>/dev/null || true
    cp "${BUILDDIR}/CMakeCache.txt" "${OUT}/" 2>/dev/null || true
}
