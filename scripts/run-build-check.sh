#!/usr/bin/env bash
#
# build-check driver: clone ceph @ CEPH_REF, apply the openRuyi fork patches, run
# build-with-container.py -d openruyi (build + ctest). Runs by hand on a riscv64
# host and from the self-hosted runner; all config via env.
#
# Env overrides:
#   CEPH_REPO     upstream ceph git URL (default https://github.com/ceph/ceph.git)
#   CEPH_REF      branch/tag/sha to test (default main)
#   WORKDIR       parent of the per-CI buckets (default: this repo's parent dir);
#                 this CI lives under ${WORKDIR}/build-check/ (non-ASan, default)
#                 or ${WORKDIR}/build-check-asan/ (WITH_ASAN=1)
#   WITH_ASAN     1 to build with -DWITH_ASAN=ON in a separate build-check-asan
#                 bucket; default 0 (no ASan, build-check bucket)
#   STEPS         comma list of bwc steps (default tests)
#   BUILD_INCREMENTAL  1 to reuse an existing build/ (default: clean build)
#   REBUILD_DEPS  1 to drop the cached build image and reinstall BuildRequires,
#                 picking up rolling openRuyi package updates (default: reuse).
#                 bwc's image cache keys on source-file hashes, not package versions.
#   TEMP_OBS_REPO 1 to install deps preferring the temporary OBS project (patch
#                 2005, repo priority=1); 0 (default) = stock openRuyi repos only.
#                 Tracked in the image fingerprint, so toggling rebuilds the image.
#   TEMP_OBS_PROJECT  the OBS project TEMP_OBS_REPO=1 layers in. Site-specific, so
#                 it has no default; TEMP_OBS_REPO=1 without it is an error.
#   CONTAINER_ENGINE   podman (default) or docker
#   GIT_PROXY     proxy for external network; unset = auto-detect via CI_PROXY_PROBE
#                 (abort if it never reaches github); 'direct' forces no proxy
#   CI_PROXY_PROBE  the proxy to probe for. Site-specific, so it has no default;
#                 unset means the run goes direct.
#   CI_PROXY_PROBE_URL / CI_PROXY_PROBE_RETRIES / CI_PROXY_PROBE_DELAY
#                 proxy auto-detect knobs; CI_NO_PROXY hosts bypass the proxy
#                 (defaults in scripts/lib/site.sh)
#   CI_NET_RETRIES  times a bwc run is retried when it died on an external git
#                   fetch (gtest-parallel etc.) rather than on the build (default 3)
#   CI_NET_RETRY_DELAY  max seconds to wait before such a retry (default set below);
#                       the wait polls and returns as soon as fetching works again
#   CI_NET_PROBE_INTERVAL  seconds between those polls (default set below)
#   GIT_LOW_SPEED_LIMIT / GIT_LOW_SPEED_TIME  abort a git transfer that moves fewer
#                 than LIMIT bytes/s for TIME seconds, host side and in-container
#                 (defaults in scripts/lib/common.sh). Guards against a stalled fetch.
#   CI_GIT_TRACE  1 to trace the container's git HTTP exchanges (~150 log lines per
#                 fetch); default 0
#   FLAKE_RETRIES ctest --repeat until-pass count for known flakes (default set below)
#   CTEST_FAIL_OUTPUT_BYTES  bytes of tail output ctest dumps per failed test
#                            (default 100000); raise to see more of a failure
#   CONFIGURE_ARGS override the cmake feature set (default: CONFIGURE_FLAGS below)
#   CEPH_PYTHON_SYSTEM_SITE  true (default) run test venvs with system site-packages;
#                            empty to disable
#   NPROC         build parallelism, overrides run-make.sh's nproc/2 default
#                 (sets build -j and BOOST_J; default set below, lower for the ASan
#                 bucket). ctest -j is CTEST_JOBS.
#   NINJA_MAX_COMPILE_JOBS / NINJA_MAX_LINK_JOBS  ninja compile/link job pools
#                 (ceph's LimitJobs.cmake). Each also gets a separate heavy pool of
#                 half its size, so up to 1.5x these run at once.
#                 Defaults set below; empty leaves ceph's own memory-based sizing.
#   CONTAINER_MEM podman --memory for the build container; default is host MemTotal
#                 minus CONTAINER_MEM_RESERVE_GB (set below). Keeps an OOM inside the
#                 container instead of letting the host OOM killer pick host daemons.
#                 Empty = no limit.
#   CTEST_JOBS    ctest parallelism (the -j inside CHECK_MAKEOPTS). Set a fixed
#                 number to cap it (e.g. CTEST_JOBS=8), or =$(nproc) for max;
#                 default set below.
#   MAX_PARALLEL_JOBS  fan-out *inside* the dencoder ctest tests, NOT a ctest -j.
#                 check-generated.sh/readable.sh fork ceph-dencoder per encoding type
#                 ($(nproc) by default); under ASan each forks at ~1.3G RSS, which
#                 OOMs the host regardless of CTEST_JOBS.
#   SCCACHE_HOST_DIR    host dir bound as the in-container sccache cache so it
#                       persists across runs (default ${WORKDIR}/build-check/sccache-cache)
#   SCCACHE_CACHE_SIZE  sccache max cache size (default set below; sccache's own default is 5G)
#   CCACHE_HOST_DIR     host dir bound as the in-container ccache cache so it
#                       persists across runs (default ${WORKDIR}/build-check/ccache-cache)
#   CCACHE_MAXSIZE      ccache max cache size (default set below; ccache's own default is 5G)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CEPH_REPO="${CEPH_REPO:-https://github.com/ceph/ceph.git}"
CEPH_REF="${CEPH_REF:-main}"
WORKDIR="${WORKDIR:-$(dirname "${REPO_ROOT}")}"
source "${REPO_ROOT}/scripts/lib/site.sh"
source "${REPO_ROOT}/scripts/lib/common.sh"
# WITH_ASAN=1 builds with -DWITH_ASAN=ON in a separate bucket, so the ASan and
# non-ASan checkouts / build dirs / sccache caches never mix.
ci_bool WITH_ASAN 0
# Each CI owns a subdir under ${WORKDIR} (build-check / build-check-asan /
# spec-openruyi / spec-upstream), so checkouts, logs and caches never interleave.
if [ "${WITH_ASAN}" = 1 ]; then
    BASE="${WORKDIR}/build-check-asan"
else
    BASE="${WORKDIR}/build-check"
fi
mkdir -p "${BASE}"
STEPS="${STEPS:-tests}"
ENGINE="${CONTAINER_ENGINE:-podman}"
CEPH_SRC="${BASE}/ceph"
CEPH_PYTHON_SYSTEM_SITE="${CEPH_PYTHON_SYSTEM_SITE:-true}"

# ASan build: cc1plus and ld each take a multiple of the non-ASan footprint, so pin
# the pools (and -j, which bounds their sum) to what fits under CONTAINER_MEM.
# Re-derive from the n_/rss_ fields in mem-usage.log when it drifts.
if [ "${WITH_ASAN}" = 1 ]; then
    NINJA_MAX_COMPILE_JOBS="${NINJA_MAX_COMPILE_JOBS:-26}"
    NINJA_MAX_LINK_JOBS="${NINJA_MAX_LINK_JOBS:-8}"
    # = compile pool + link pool
    NPROC="${NPROC:-34}"
else
    # ceph's memory-based sizing ignores the heavy pool on top, so a cold-cache
    # build ran ~-j cc1plus at once and hit the host OOM killer.
    NINJA_MAX_COMPILE_JOBS="${NINJA_MAX_COMPILE_JOBS:-24}"
    NINJA_MAX_LINK_JOBS="${NINJA_MAX_LINK_JOBS:-}"
    NPROC="${NPROC:-50}"
fi
CTEST_JOBS="${CTEST_JOBS:-$(nproc)}"
MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-}"

# cmake feature set (override the whole set via CONFIGURE_ARGS). Features are
# otherwise left at their defaults so the build tracks cmake/run-make.sh; the
# flags below only suppress defaults unusable here.
CONFIGURE_FLAGS=(
    # run-make.sh hardcodes -DWITH_SPDK=ON (cmake and the rpm build default OFF)
    -DWITH_SPDK=OFF
    # cmake defaults ON; needs npm, and even ceph.spec.in turns it OFF unconditionally
    -DWITH_MGR_DASHBOARD_FRONTEND=OFF
    # No -DCMAKE_BUILD_TYPE: track upstream, which defaults a git checkout to Debug.
    # Both below are on in upstream's make-check CI (ceph-pull-requests{,-arm64}).
    -DWITH_CRIMSON=ON
    -DWITH_RBD_RWL=ON
    # No -DWITH_MOLD: mold 2.41 drops the .symver aliases librados.so exports, and a
    # mold-linked crimson-osd segfaults in mkfs. The build links with ld.bfd.
    # add_ceph_test stamps every test with this as a TIMEOUT property, which overrides
    # ctest's --timeout; the kill time is therefore set here, at configure time.
    -DCEPH_TEST_TIMEOUT="${CI_CTEST_TIMEOUT}"
    # Job pools: -DNINJA_MAX_{COMPILE,LINK}_JOBS are appended below from the env
    # (ceph owns the JOB_POOLS property, so plain -DCMAKE_JOB_POOLS is ignored).
)
if [ -n "${NINJA_MAX_COMPILE_JOBS}" ]; then
    CONFIGURE_FLAGS+=(-DNINJA_MAX_COMPILE_JOBS="${NINJA_MAX_COMPILE_JOBS}")
fi
if [ -n "${NINJA_MAX_LINK_JOBS}" ]; then
    CONFIGURE_FLAGS+=(-DNINJA_MAX_LINK_JOBS="${NINJA_MAX_LINK_JOBS}")
fi

# ASan opt-in. The test working-set shrink patches (1046-1047) are guarded by
# __has_feature(address_sanitizer), so they stay applied unconditionally.
if [ "${WITH_ASAN}" = 1 ]; then
    CONFIGURE_FLAGS+=(-DWITH_ASAN=ON)
    # ld.bfd holds every input section of the multi-GB static rgw/crimson archives in
    # memory; --no-keep-memory re-reads them instead, for a smaller linker peak.
    # shellcheck disable=SC2054  # the commas are inside the -Wl, values
    CONFIGURE_FLAGS+=(
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--no-keep-memory
        -DCMAKE_SHARED_LINKER_FLAGS=-Wl,--no-keep-memory
        -DCMAKE_MODULE_LINKER_FLAGS=-Wl,--no-keep-memory
    )
    # riscv64 linker relaxation makes the assembler emit a SET/SUB relocation pair for
    # every address difference in the debug info -- about half of each object file and
    # of the archives ld holds. -mno-relax drops them.
    CONFIGURE_FLAGS+=(
        -DCMAKE_C_FLAGS=-mno-relax
        -DCMAKE_CXX_FLAGS=-mno-relax
    )
fi

# Compared verbatim in the patch list and the image fingerprint. Off unless the site
# configures a project (TEMP_OBS_PROJECT).
ci_bool TEMP_OBS_REPO 0
ci_require_temp_obs

# RESUME=1: continue an interrupted build without touching the source tree. Skips
# clone/fetch/checkout/submodule/patch and the standalone configure, reusing the
# checkout + build/ as-is. Implies BUILD_INCREMENTAL=1 and ignores CEPH_REF; requires
# an already-configured build/ (build.ninja present).
ci_bool RESUME 0
ci_bool BUILD_INCREMENTAL 0
if [ "${RESUME}" = 1 ]; then
    BUILD_INCREMENTAL=1
fi
ci_bool REBUILD_DEPS 0
ci_bool CI_GIT_TRACE 0

ci_open_run_log

# bwc's fixed container name; killed on interrupt.
BUILD_CONTAINER="ceph_build"
# Short-lived container the fetch diagnostics run in, named for the cleanup trap.
NETFAIL_CONTAINER="ceph_netfail_diag"
# The image bwc builds the deps into and runs every step in ("ceph-build:<branch>.<distro>").
BUILD_IMAGE="ceph-build:HEAD.openruyi"
# shellcheck disable=SC2329  # run from the signal trap via CI_CLEANUP_HOOK
_drop_steps_out() {
    if [ -n "${_steps_out:-}" ]; then
        rm -f "${_steps_out}"
    fi
}
CI_CLEANUP_HOOK=_drop_steps_out
ci_trap_cleanup "${BUILD_CONTAINER}" "${NETFAIL_CONTAINER}"

# GIT_PROXY: explicit value wins; unset -> probe the proxy (scripts/lib/site.sh).
ci_resolve_proxy
GIT_PROXY="${CI_PROXY}"
ci_github_token

ci_require_riscv64

echo "=== ceph-ci build-check run ==="
echo "  repo=${CEPH_REPO} ref=${CEPH_REF}"
echo "  base=${BASE} engine=${ENGINE} steps=${STEPS}"
echo "  WITH_ASAN=${WITH_ASAN} (1=-DWITH_ASAN=ON in build-check-asan, 0=no ASan in build-check)"
echo "  CEPH_PYTHON_SYSTEM_SITE='${CEPH_PYTHON_SYSTEM_SITE}' (empty=off)"
echo "  TEMP_OBS_REPO=${TEMP_OBS_REPO} ($(ci_temp_obs_desc))"
echo "  GIT_PROXY='${GIT_PROXY}' (empty=direct)"
[ "${RESUME}" = 1 ] && echo "  RESUME=1 (skip clone/fetch/patch/configure; reuse build/; CEPH_REF ignored)"

# ensure the openRuyi base image is present
"${REPO_ROOT}/scripts/fetch-openruyi-image.sh"

# Proxy pin, stall guard and credential prompt off (scripts/lib/common.sh). With the
# prompt off a throttled fetch fails with "could not read Username", which
# CI_NET_FAIL_RE matches, so the retry below handles it.
ci_git_net_args

# clone or update the ceph source at CEPH_REF
if [ "${RESUME}" = 1 ]; then
    [ -d "${CEPH_SRC}/.git" ] || {
        echo "ERROR: RESUME=1 but no checkout at ${CEPH_SRC}; run a normal build first." >&2
        exit 1
    }
    CEPH_SHA="$(git -C "${CEPH_SRC}" rev-parse --short HEAD)"
    echo "=== RESUME: reuse existing checkout, ceph @ ${CEPH_SHA} (skip clone/fetch/checkout/submodule/patch) ==="
else
    ci_checkout_ceph "${CEPH_REPO}" "${CEPH_REF}" "${CEPH_SRC}"

    # Fork patches: list lives in tree-patches.sh next to this script.
    source "${REPO_ROOT}/scripts/tree-patches.sh"

    rendered=""
    # A failing `git apply` exits the script under set -e, so drop the rendered
    # copy from an EXIT trap rather than only on the loop's happy path.
    trap 'rm -f "${rendered}"' EXIT
    for name in "${TREE_PATCHES[@]}"; do
        patch_file="${REPO_ROOT}/fork-patches/${name}"
        [ -e "${patch_file}" ] || { echo "ERROR: listed patch not found: ${name}" >&2; exit 1; }
        # A .patch.in is a template: substitute the site values (scripts/lib/site.sh)
        # into a temporary copy, so fork-patches/ carries no site-specific value.
        if [ "${name%.in}" != "${name}" ]; then
            rendered="$(mktemp "${TMPDIR:-/tmp}/ceph-ci-patch.XXXXXX")"
            sed -e "s|@TEMP_OBS_PROJECT@|${TEMP_OBS_PROJECT}|g" \
                -e "s|@TEMP_OBS_REPO_URL@|${TEMP_OBS_REPO_URL}|g" "${patch_file}" > "${rendered}"
            patch_file="${rendered}"
        fi
        # --index is required: without it --check runs against the worktree, where a
        # submodule has no blob to compare, so a gitlink-only patch is always reported
        # as already applied.
        if git -C "${CEPH_SRC}" apply --reverse --check --index "${patch_file}" 2>/dev/null; then
            echo "patch already applied upstream, skipping: ${name}"
        else
            echo "applying ${name}"
            git -C "${CEPH_SRC}" apply --3way "${patch_file}"
        fi
        if [ -n "${rendered}" ]; then
            rm -f "${rendered}"
            rendered=""
        fi
    done
    trap - EXIT

    # A patch may bump a submodule gitlink; git apply rewrites the index entry, not
    # the submodule worktree.
    echo "re-syncing submodules to the patched gitlinks"
    ci_submodule_sync "${CEPH_SRC}"
fi

# ctest options from known-failures.json (scripts/lib/common.sh).
ci_ctest_makeopts

CONFIGURE_ARGS="${CONFIGURE_ARGS:-${CONFIGURE_FLAGS[*]}}"
echo "  CONFIGURE_ARGS='${CONFIGURE_ARGS}'"

# Drop the cached build image (bwc then re-runs install-deps.sh) when either:
#   - REBUILD_DEPS is set. bwc keys its image cache on source-file hashes, not on the
#     installed package versions, so rolling updates otherwise never land.
#   - ceph.spec.in changed since the last build image (tracked in .image-fp).
#   - the temp-OBS setting changed. The fingerprint carries the project name, since
#     patch 2005 is rendered from it.
IMG_FP_FILE="${BASE}/.image-fp"
IMG_FP="spec:$(sha256sum "${CEPH_SRC}/ceph.spec.in" | cut -d' ' -f1) $(ci_temp_obs_fingerprint)"
_drop_reason=""
if [ "${REBUILD_DEPS}" = 1 ]; then
    _drop_reason="REBUILD_DEPS set: forcing dependency refresh"
fi
if [ -z "${_drop_reason}" ] && [ "$(cat "${IMG_FP_FILE}" 2>/dev/null || true)" != "${IMG_FP}" ]; then
    _drop_reason="ceph.spec.in changed since last build image (or first run)"
fi
if [ -n "${_drop_reason}" ]; then
    echo "  dropping build image: ${_drop_reason}"
    mapfile -t _stale_imgs < <("${ENGINE}" images -q localhost/ceph-build 2>/dev/null | sort -u)
    if [ "${#_stale_imgs[@]}" -gt 0 ]; then
        "${ENGINE}" rmi -f "${_stale_imgs[@]}" >/dev/null 2>&1 || true
    fi
fi
printf '%s\n' "${IMG_FP}" > "${IMG_FP_FILE}"

# Default clean build (rm build/); BUILD_INCREMENTAL=1 reuses build/ for a faster
# incremental rebuild.
if [ "${BUILD_INCREMENTAL}" = 1 ]; then
    echo "  BUILD_INCREMENTAL=1: reusing existing build/ if present"
else
    echo "  clean build: removing ${CEPH_SRC}/build"
    rm -rf "${CEPH_SRC}/build"
fi

# Build tuning forwarded to the bwc STEPS run (NPROC/CTEST_JOBS set at top). bwc runs
# each step in a --rm container, so both caches are bind-mounted from the host or they
# start cold every run:
#   sccache: ceph itself (-DWITH_SCCACHE=ON). Content-addressed, so a clean build/
#           still hits. SCCACHE_IDLE_TIMEOUT=0: the server otherwise shut down
#           mid-build and the compile fell back to uncached.
#   ccache: the ExternalProjects driven by their own make (arrow, pmdk). CCACHE_DIR
#           pins the dir where run-make.sh's save/restore_ccache_conf expects it;
#           run-make.sh only raises max_size past 5G under in_jenkins.
SCCACHE_HOST_DIR="${SCCACHE_HOST_DIR:-${BASE}/sccache-cache}"
SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-100G}"
CCACHE_HOST_DIR="${CCACHE_HOST_DIR:-${BASE}/ccache-cache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
mkdir -p "${SCCACHE_HOST_DIR}" "${CCACHE_HOST_DIR}"
echo "  NPROC=${NPROC} (build -j / BOOST_J; ctest -j${CTEST_JOBS}; dencoder MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS})"
echo "  ninja pools: compile=${NINJA_MAX_COMPILE_JOBS:-auto} link=${NINJA_MAX_LINK_JOBS:-auto} (heavy = half; empty = ceph's memory-based default)"
echo "  sccache: ${SCCACHE_HOST_DIR} -> /root/.cache/sccache (max ${SCCACHE_CACHE_SIZE})"
echo "  ccache: ${CCACHE_HOST_DIR} -> /root/.ccache (max ${CCACHE_MAXSIZE})"
declare -a BUILD_TUNE_ARGS=(
    --extra="-eNPROC=${NPROC}"
    # A Debug build type makes run-make.sh inject -Werror.
    --extra="-eWITHOUT_WERROR=1"
    --extra="--volume=${SCCACHE_HOST_DIR}:/root/.cache/sccache:Z"
    --extra="-eSCCACHE_DIR=/root/.cache/sccache"
    --extra="-eSCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}"
    --extra="-eSCCACHE_IDLE_TIMEOUT=0"
    --extra="--volume=${CCACHE_HOST_DIR}:/root/.ccache:Z"
    --extra="-eCCACHE_DIR=/root/.ccache"
    --extra="-eCCACHE_MAXSIZE=${CCACHE_MAXSIZE}"
)
# Memory cap on the build container (cgroup v2 memory.max): an OOM then kills the
# biggest process inside the container and leaves the host daemons alone.
CONTAINER_MEM_RESERVE_GB="${CONTAINER_MEM_RESERVE_GB:-8}"
if [ -z "${CONTAINER_MEM+x}" ]; then
    CONTAINER_MEM="$(awk -v r="${CONTAINER_MEM_RESERVE_GB}" \
        '/^MemTotal:/ { printf "%dg", $2 / 1048576 - r }' /proc/meminfo)"
fi
if [ -n "${CONTAINER_MEM}" ]; then
    BUILD_TUNE_ARGS+=(--extra="--memory=${CONTAINER_MEM}")
fi
echo "  container memory cap: ${CONTAINER_MEM:-none}"

# standalone test data on tmpfs. qa/standalone tests run file-backed BlueStore OSDs
# whose block file sits under build/td; on this host's NVMe ext4 the O_DIRECT/libaio
# write completion intermittently stalls for minutes, hanging the tests. /ceph/build/td
# assumes bwc's default --homedir=/ceph. STEPS (ctest) run only.
TD_TMPFS_DIR="${TD_TMPFS_DIR:-/dev/shm/ceph-ci-td}"
rm -rf "${TD_TMPFS_DIR}"; mkdir -p "${TD_TMPFS_DIR}"
echo "  standalone td on tmpfs: ${TD_TMPFS_DIR} -> /ceph/build/td"
declare -a TD_TMPFS_ARGS=(
    --extra="--volume=${TD_TMPFS_DIR}:/ceph/build/td:Z"
)

# podman's default seccomp profile (v4.9.4) has no riscv_hwprobe (syscall 258), so it
# returns ENOSYS in-container: ceph_arch_riscv_probe() reads all zeros, the RISC-V
# crc32c accel stays off and unittest_arch fails. STEPS (ctest) run only.
declare -a SECCOMP_ARGS=(
    --extra="--security-opt=seccomp=unconfined"
)

# Container networking for proxied hosts. The proxy is a routable IP, so the bwc
# containers reach it over the default bridge net; podman forwards the exported
# *_proxy into them. Must come AFTER the host git clone/fetch.
if [ -n "${GIT_PROXY}" ]; then
    export http_proxy="${GIT_PROXY}" https_proxy="${GIT_PROXY}" no_proxy="${CI_NO_PROXY}"
fi

# run build + ctest via bwc. Env goes in via `--extra=` (bwc's argparse rejects the
# separated `-x -eFOO` form).
declare -a EXEC=()
IFS=',' read -ra _steps <<< "${STEPS}"
for s in "${_steps[@]}"; do EXEC+=(-e "$s"); done

# In-container git config, injected via GIT_CONFIG_COUNT/KEY/VALUE: safe.directory for
# the bind-mounted tree and the same stall abort as the host side, both unconditional.
# The github proxy entry is appended only when GIT_PROXY is set.
declare -a GIT_CFG_ARGS=(
    --extra="-eGIT_TERMINAL_PROMPT=0"   # same reason as the host-side export above
    --extra="-eGIT_CONFIG_KEY_0=safe.directory"
    --extra="-eGIT_CONFIG_VALUE_0=*"
    --extra="-eGIT_CONFIG_KEY_1=http.lowSpeedLimit"
    --extra="-eGIT_CONFIG_VALUE_1=${GIT_LOW_SPEED_LIMIT}"
    --extra="-eGIT_CONFIG_KEY_2=http.lowSpeedTime"
    --extra="-eGIT_CONFIG_VALUE_2=${GIT_LOW_SPEED_TIME}"
)
_git_cfg_count=3
# bwc forwards the token itself but writes its helper at index 0, which this
# GIT_CONFIG_COUNT would drop; carry the same entry instead.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    GIT_CFG_ARGS+=(
        --extra="-eGIT_CONFIG_KEY_${_git_cfg_count}=credential.https://github.com.helper"
        --extra="-eGIT_CONFIG_VALUE_${_git_cfg_count}=${CI_GIT_CRED_HELPER}"
    )
    _git_cfg_count=$((_git_cfg_count + 1))
fi
if [ -n "${GIT_PROXY}" ]; then
    GIT_CFG_ARGS+=(
        --extra="-eGIT_CONFIG_KEY_${_git_cfg_count}=http.https://github.com/.proxy"
        --extra="-eGIT_CONFIG_VALUE_${_git_cfg_count}=${GIT_PROXY}"
        --extra="-eGOPROXY=https://goproxy.cn,direct"   # openRuyi go defaults to GOPROXY=""
    )
    _git_cfg_count=$((_git_cfg_count + 1))
fi
GIT_CFG_ARGS+=(--extra="-eGIT_CONFIG_COUNT=${_git_cfg_count}")
# In-container git HTTP tracing, off by default: ~150 log lines per fetch even on a
# green run. NO_DATA keeps the headers and drops the payloads.
declare -a GIT_TRACE_ARGS=()
if [ "${CI_GIT_TRACE}" = 1 ]; then
    GIT_TRACE_ARGS=(
        --extra="-eGIT_TRACE_CURL=1"
        --extra="-eGIT_TRACE_CURL_NO_DATA=1"
    )
fi
declare -a NET_ARGS=(
    "${GIT_CFG_ARGS[@]}"
    "${GIT_TRACE_ARGS[@]}"
)

declare -a SYSTEM_SITE_ARG=()
[ -n "${CEPH_PYTHON_SYSTEM_SITE}" ] && \
    SYSTEM_SITE_ARG=(--extra="-eCEPH_PYTHON_SYSTEM_SITE=${CEPH_PYTHON_SYSTEM_SITE}")

cd "${CEPH_SRC}"

# Background memory sampler (scripts/lib/common.sh).
ci_mem_sampler_start

# A half-configured build/ (no generator file) makes run-make.sh's configure bail out
# instead of reusing it. Called before each configure attempt, since a configure
# killed mid-FetchContent leaves exactly such a tree behind.
# shellcheck disable=SC2329  # called from _run_configure, which _net_retry runs
_clear_half_configured_build() {
    if [ -d "${CEPH_SRC}/build" ] && [ ! -e "${CEPH_SRC}/build/build.ninja" ] \
       && [ ! -e "${CEPH_SRC}/build/Makefile" ]; then
        echo "=== removing half-configured build/ (no generator file) ==="
        rm -rf "${CEPH_SRC}/build"
    fi
}

# github throttles anonymous git pulls from this proxy's shared exit IP: the POST
# /git-upload-pack comes back 401 while a GET on info/refs still answers 200. Both
# configure (catch2 via CPMAddPackage) and every ninja run (gtest-parallel, pinned at
# GIT_TAG "master") are exposed. Retry on that signature only; the throttle clears
# within minutes.
CI_NET_RETRIES="${CI_NET_RETRIES:-3}"
CI_NET_RETRY_DELAY="${CI_NET_RETRY_DELAY:-300}"
CI_NET_PROBE_INTERVAL="${CI_NET_PROBE_INTERVAL:-60}"
# The fetch both the diagnostic and the wait below exercise.
CI_NET_PROBE_REPO="${CI_NET_PROBE_REPO:-https://github.com/google/gtest-parallel.git}"
CI_NET_PROBE_REF="${CI_NET_PROBE_REF:-master}"
# Throttled git: the refused credential prompt, the half-read advertisement, cmake's
# clone/update wrappers giving up. None of these appear on a clean run.
CI_NET_FAIL_RE="could not read Username for|expected flush after ref listing|Failed to clone repository|FAILED:.*_ext-stamp/[^ ]*-(update|download)"

# Record what github actually answered, once per run; a successful retry would erase
# the evidence. A traced ls-remote needs no local checkout.
_capture_netfail_diag() {
    local label="$1"
    # label doubles as a filename component; keep spaces out of it
    local diag
    diag="${BASE}/ci-log/$(basename "${RUN_LOG}" -run.log)-netfail-${label// /-}.log"
    echo "  capturing fetch diagnostics -> ${diag}"
    # An empty GIT_PROXY must drop the -e flags entirely, not pass empty args. The
    # token goes in too, or this measures a different path than the one that failed.
    local -a proxy_env=() proxy_cfg=()
    local n=0 tok=none
    if [ -n "${GIT_PROXY}" ]; then
        proxy_env=(-ehttp_proxy="${GIT_PROXY}" -ehttps_proxy="${GIT_PROXY}")
        proxy_cfg+=("-eGIT_CONFIG_KEY_${n}=http.https://github.com/.proxy"
                    "-eGIT_CONFIG_VALUE_${n}=${GIT_PROXY}")
        n=$((n + 1))
    fi
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        tok=present
        proxy_env+=(-eGITHUB_TOKEN)
        proxy_cfg+=("-eGIT_CONFIG_KEY_${n}=credential.https://github.com.helper"
                    "-eGIT_CONFIG_VALUE_${n}=${CI_GIT_CRED_HELPER}")
        n=$((n + 1))
    fi
    [ "${n}" -gt 0 ] && proxy_cfg+=("-eGIT_CONFIG_COUNT=${n}")
    {
        echo "== ${label} hit a throttled fetch at $(date '+%F %T'), proxy=${GIT_PROXY} token=${tok} =="
        # shellcheck disable=SC2016  # NET_PROBE_* expand in the container's shell
        "${ENGINE}" run --rm --name="${NETFAIL_CONTAINER}" \
            "${proxy_env[@]}" "${proxy_cfg[@]}" \
            -eGIT_TRACE_CURL=1 -eGIT_TRACE_CURL_NO_DATA=1 -eGIT_TERMINAL_PROMPT=0 \
            -eNET_PROBE_REPO="${CI_NET_PROBE_REPO}" -eNET_PROBE_REF="${CI_NET_PROBE_REF}" \
            "${BUILD_IMAGE}" bash -c '
                git ls-remote --heads "${NET_PROBE_REPO}" "${NET_PROBE_REF}"
                echo "ls-remote-rc=$?"'
    } > "${diag}" 2>&1 || true
}

# Wait for the throttle to lift, polling the path that actually fails: ls-remote
# issues the POST /git-upload-pack that gets 401'd, while a GET on info/refs answers
# 200 right through the throttle. Returns as soon as fetching works again.
_wait_out_throttle() {
    local waited=0
    while [ "${waited}" -lt "${CI_NET_RETRY_DELAY}" ]; do
        sleep "${CI_NET_PROBE_INTERVAL}"
        waited=$((waited + CI_NET_PROBE_INTERVAL))
        if git "${GIT_NET_ARGS[@]}" ls-remote --heads \
               "${CI_NET_PROBE_REPO}" "${CI_NET_PROBE_REF}" >/dev/null 2>&1; then
            echo "  github fetch path usable again after ${waited}s"
            return 0
        fi
        echo "  still throttled after ${waited}s (ls-remote still failing)"
    done
}

# Run one bwc invocation, retrying it only when it died on a throttled fetch.
# Sets RC. _steps_out is global so the signal trap can drop it.
_net_retry() {
    local label="$1"; shift
    local attempt=0 flake
    while :; do
        # Capture a copy to match against; stdout still flows to run.log.
        _steps_out="$(mktemp "${TMPDIR:-/tmp}/ceph-ci-run.XXXXXX")"
        "$@" 2>&1 | tee "${_steps_out}"
        RC=${PIPESTATUS[0]}
        flake=0
        if [ "${RC}" -ne 0 ] && grep -Eq "${CI_NET_FAIL_RE}" "${_steps_out}"; then
            flake=1
        fi
        rm -f "${_steps_out}"; _steps_out=""
        if [ "${flake}" -eq 0 ] || [ "${attempt}" -ge "${CI_NET_RETRIES}" ]; then
            return "${RC}"
        fi
        attempt=$((attempt + 1))
        echo "=== ${label} died on a throttled github fetch, not on the build;" \
             "retry ${attempt}/${CI_NET_RETRIES}, waiting up to ${CI_NET_RETRY_DELAY}s ==="
        [ "${attempt}" -eq 1 ] && _capture_netfail_diag "${label}"
        _wait_out_throttle
    done
}

# Configure pulls catch2 from github (CPMAddPackage), so it can hit the throttle too.
# shellcheck disable=SC2329  # invoked by name through _net_retry
_run_configure() {
    _clear_half_configured_build
    python3 src/script/build-with-container.py \
        --distro openruyi \
        --container-engine "${ENGINE}" \
        "${NET_ARGS[@]}" \
        "${BUILD_TUNE_ARGS[@]}" \
        --extra="-eCONFIGURE_ARGS=${CONFIGURE_ARGS}" \
        "${SYSTEM_SITE_ARG[@]}" \
        -e configure
}

# shellcheck disable=SC2329  # invoked by name through _net_retry
_run_steps() {
    python3 src/script/build-with-container.py \
        --distro openruyi \
        --container-engine "${ENGINE}" \
        "${NET_ARGS[@]}" \
        "${BUILD_TUNE_ARGS[@]}" \
        "${TD_TMPFS_ARGS[@]}" \
        "${SECCOMP_ARGS[@]}" \
        --extra="-eCHECK_MAKEOPTS=${CHECK_MAKEOPTS}" \
        --extra="-eMAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS}" \
        --extra="-eCONFIGURE_ARGS=${CONFIGURE_ARGS}" \
        "${SYSTEM_SITE_ARG[@]}" \
        "${EXEC[@]}"
}

# Configure in a td-free container first, then build + ctest with the tmpfs td
# mounted. The split is required: mounting the td at /ceph/build/td makes podman
# pre-create /ceph/build, and do_cmake.sh refuses to configure into an existing
# build/. The STEPS run's own configure step then short-circuits.
set +e
if [ "${RESUME}" = 1 ]; then
    # build/ must already be configured (see the split above); demand it up front
    # rather than after a long container spin-up.
    if [ ! -e "${CEPH_SRC}/build/build.ninja" ]; then
        echo "ERROR: RESUME=1 but ${CEPH_SRC}/build/build.ninja is missing; build/ is not configured." >&2
        echo "       Run a normal (non-RESUME) build once to configure, then RESUME to continue it." >&2
        exit 1
    fi
    echo "=== RESUME: build/ already configured, skipping standalone configure ==="
    RC=0
else
    echo "=== configure (td-free, so do_cmake sees no pre-created build/) ==="
    _net_retry configure _run_configure
fi

if [ "${RC}" -eq 0 ]; then
    _net_retry "STEPS run" _run_steps
fi
set -e

# Memory peak summary into run.log.
ci_mem_sampler_stop

# surface where ctest results landed (collected as artifacts by the workflow)
echo "=== ctest output dir (build/Testing) ==="
ls -d "${CEPH_SRC}"/build/Testing/* 2>/dev/null || echo "  (no build/Testing yet)"

echo "=== ceph-ci build-check run done: rc=${RC} ceph=${CEPH_SHA} ==="
exit "${RC}"
