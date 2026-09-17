# shellcheck shell=bash
# shellcheck disable=SC2034  # variables set here are read by the sourcing driver
# Host-side helpers shared by the two spec drivers (spec-openruyi, spec-upstream),
# sourced after common.sh. Both validate a ceph spec by running rpmbuild in the
# openRuyi container and build FROM a cached "deps" image that holds the
# BuildRequires. The driver sets DEPS_IMAGE, DEPS_CONTAINER, BUILD_CONTAINER and
# SPEC_CONTAINER_SCRIPT (its container half, mounted at /spec-build.sh).

# shellcheck source=scripts/lib/image.sh
source "${REPO_ROOT}/scripts/lib/image.sh"   # CI_BASE_IMAGE
SPEC_CONTAINER_LIB="${REPO_ROOT}/scripts/lib/spec-container.sh"

# spec_host_dirs PREFIX NAME: the persistent host dirs bound into the container, all
# under ${BASE}: sources, rpms, artifacts, sccache-cache, build (the rpm BUILD/ tree
# incl. the nested BUILDROOT, which RESUME/FILES_ONLY reuse) and the tmpfs td dir.
# Location overrides are ${PREFIX}_{BUILD_DIR,SCCACHE_HOST_DIR,TD_TMPFS_DIR}; NAME
# names the tmpfs td dir.
spec_host_dirs() {
    local prefix="$1" name="$2" v
    SOURCES_CACHE="${BASE}/sources"
    RPMS_OUT="${BASE}/rpms"
    ARTIFACTS="${BASE}/artifacts"
    v="${prefix}_BUILD_DIR";        BUILD_PERSIST="${!v:-${BASE}/build}"
    v="${prefix}_SCCACHE_HOST_DIR"; SCCACHE_HOST_DIR="${!v:-${BASE}/sccache-cache}"
    v="${prefix}_TD_TMPFS_DIR";     TD_TMPFS="${!v:-/dev/shm/ceph-ci-${name}-td}"
    SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-100G}"
    mkdir -p "${SOURCES_CACHE}" "${RPMS_OUT}" "${ARTIFACTS}" "${SCCACHE_HOST_DIR}" "${BUILD_PERSIST}"
    rm -rf "${TD_TMPFS}"; mkdir -p "${TD_TMPFS}"
}

# spec_deps_fingerprint SPECFILE: what the deps image is built from -- the spec's
# BuildRequires, the temp-OBS setting and the base image id. Sets DEPS_FP.
spec_deps_fingerprint() {
    local base_id
    base_id="$("${ENGINE}" image inspect --format '{{.Id}}' "${CI_BASE_IMAGE}" 2>/dev/null | cut -c1-19)"
    DEPS_FP="br:$(grep -E '^(BuildRequires|BuildConflicts):' "$1" | sha256sum | cut -d' ' -f1) $(ci_temp_obs_fingerprint) base:${base_id}"
}

# spec_deps_image_ensure RUN_ARGS...: make DEPS_IMAGE current. The build container is
# --rm, so the cacheable half (rpm tooling, gcc-c++, sccache, dnf builddep) is baked
# into a derived image by the container script's PHASE=deps. Cheapest outcome wins:
#   reuse   : DEPS_FP unchanged and no REBUILD_DEPS -> no container at all
#   refresh : REBUILD_DEPS with a matching DEPS_FP -> PHASE=deps FROM the existing
#             image so dnf upgrades in place; commit only if the package set changed
#   rebuild : image missing or DEPS_FP changed -> PHASE=deps FROM the base image
# RUN_ARGS are the path-specific mounts (the spec source). Needs DEPS_FP, PROXY_ENV.
spec_deps_image_ensure() {
    local fp_file="${BASE}/.deps-fp" pkghash_file="${BASE}/.deps-pkghash" meta_dir="${BASE}/.deps-meta"
    local exists=0 fp_ok=0 src="" reason="" old_id cur_id new_hash old_hash
    "${ENGINE}" image inspect "${DEPS_IMAGE}" >/dev/null 2>&1 && exists=1
    [ "$(cat "${fp_file}" 2>/dev/null || true)" = "${DEPS_FP}" ] && fp_ok=1
    if [ "${exists}" = 0 ]; then
        src="${CI_BASE_IMAGE}"; reason="rebuild: deps image missing (first run)"
    elif [ "${fp_ok}" = 0 ]; then
        src="${CI_BASE_IMAGE}"; reason="rebuild: BuildRequires/base image changed"
    elif [ "${REBUILD_DEPS}" = 1 ]; then
        src="${DEPS_IMAGE}"; reason="refresh: REBUILD_DEPS -- pick up rolling package updates in place"
    fi
    if [ -z "${src}" ]; then
        echo "=== reusing cached deps image ${DEPS_IMAGE} (fingerprint unchanged, no rebuild_deps) ==="
        return 0
    fi

    echo "=== deps image ${DEPS_IMAGE}: ${reason} (from ${src}) ==="
    rm -rf "${meta_dir}"; mkdir -p "${meta_dir}"
    if [ "${TEMP_OBS_REPO}" = 1 ]; then
        ci_write_temp_obs_repo "${meta_dir}/ceph-ci-temp-obs.repo"
    fi
    old_id="$("${ENGINE}" image inspect --format '{{.Id}}' "${DEPS_IMAGE}" 2>/dev/null || true)"
    "${ENGINE}" rm -f "${DEPS_CONTAINER}" >/dev/null 2>&1 || true
    # --pids-limit=-1: builddep and its scriptlets fan out past podman's default pid
    # cap. /deps-meta carries the repo file in and the package hash out.
    "${ENGINE}" run --name "${DEPS_CONTAINER}" \
        --pids-limit=-1 \
        -e "PHASE=deps" \
        -e "TEMP_OBS_REPO=${TEMP_OBS_REPO}" \
        "${PROXY_ENV[@]}" \
        -v "${SPEC_CONTAINER_SCRIPT}:/spec-build.sh:ro" \
        -v "${SPEC_CONTAINER_LIB}:/spec-lib.sh:ro" \
        -v "${meta_dir}:/deps-meta:Z" \
        "$@" \
        "${src}" \
        bash /spec-build.sh

    # A refresh that found no updates: keep the image, skip the expensive commit.
    new_hash="$(cat "${meta_dir}/pkghash" 2>/dev/null || true)"
    old_hash="$(cat "${pkghash_file}" 2>/dev/null || true)"
    if [ "${exists}" = 1 ] && [ -n "${new_hash}" ] && [ "${new_hash}" = "${old_hash}" ]; then
        echo "  package set unchanged (pkghash ${new_hash:0:12}…); skipping commit, keeping cached image"
        "${ENGINE}" rm -f "${DEPS_CONTAINER}" >/dev/null 2>&1 || true
    else
        echo "  package set changed (or first build); committing deps image"
        "${ENGINE}" commit "${DEPS_CONTAINER}" "${DEPS_IMAGE}" >/dev/null
        "${ENGINE}" rm -f "${DEPS_CONTAINER}" >/dev/null 2>&1 || true
        # The commit re-points the tag and leaves the old image dangling: prune it.
        cur_id="$("${ENGINE}" image inspect --format '{{.Id}}' "${DEPS_IMAGE}" 2>/dev/null || true)"
        if [ -n "${old_id}" ] && [ "${old_id}" != "${cur_id}" ]; then
            "${ENGINE}" rmi -f "${old_id}" >/dev/null 2>&1 || true
        fi
        [ -n "${new_hash}" ] && printf '%s\n' "${new_hash}" > "${pkghash_file}"
        echo "  deps image ready: ${DEPS_IMAGE}"
    fi
    printf '%s\n' "${DEPS_FP}" > "${fp_file}"
}

# spec_build_run RUN_ARGS...: run the container script's PHASE=build FROM DEPS_IMAGE
# with the shared knobs and mounts; RUN_ARGS add the path-specific ones. Sets RC.
# --pids-limit=-1 lifts podman's default 2048-pid cap, which a -j${NPROC} ninja build
# with sccache exceeds ("posix_spawn: Resource temporarily unavailable").
spec_build_run() {
    set +e
    "${ENGINE}" run --rm --name "${BUILD_CONTAINER}" \
        --pids-limit=-1 \
        -e "PHASE=build" \
        -e "NPROC=${NPROC}" \
        -e "CHECK_MAKEOPTS=${CHECK_MAKEOPTS}" \
        -e "CEPH_TEST_TIMEOUT=${CI_CTEST_TIMEOUT}" \
        -e "TEMP_OBS_REPO=${TEMP_OBS_REPO}" \
        -e "SCCACHE_DIR=/root/.cache/sccache" \
        -e "SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}" \
        -e "SCCACHE_IDLE_TIMEOUT=0" \
        -e "RESUME=${RESUME}" \
        -e "FILES_ONLY=${FILES_ONLY}" \
        -e "SKIP_CTEST=${SKIP_CTEST}" \
        "${PROXY_ENV[@]}" \
        -v "${SPEC_CONTAINER_SCRIPT}:/spec-build.sh:ro" \
        -v "${SPEC_CONTAINER_LIB}:/spec-lib.sh:ro" \
        -v "${SOURCES_CACHE}:/root/rpmbuild/SOURCES:Z" \
        -v "${RPMS_OUT}:/root/rpmbuild/RPMS:Z" \
        -v "${BUILD_PERSIST}:/root/rpmbuild/BUILD:Z" \
        -v "${ARTIFACTS}:/out:Z" \
        -v "${SCCACHE_HOST_DIR}:/root/.cache/sccache:Z" \
        -v "${TD_TMPFS}:/td-tmpfs:Z" \
        "$@" \
        "${DEPS_IMAGE}" \
        bash /spec-build.sh
    RC=$?
    set -e
}

# spec_install_check STAMP: dnf-install the rpms written after STAMP into a fresh
# container FROM the base image, like openRuyi's PR CI does after its build. No
# BuildRequires are present there, so a missing or wrong runtime Requires, a file
# conflict or a failing scriptlet shows up. Stock repos only; *-debuginfo and
# *-debugsource are left out. Needs INSTALL_CONTAINER, PROXY_ENV. Sets INSTALL_RC.
spec_install_check() {
    local stamp="$1" rpm
    local -a rpms=()
    while IFS= read -r rpm; do
        rpms+=("/rpms/${rpm#"${RPMS_OUT}"/}")
    done < <(find "${RPMS_OUT}" -name '*.rpm' ! -name '*.src.rpm' \
                 ! -name '*-debuginfo-*' ! -name '*-debugsource-*' \
                 -newer "${stamp}" | sort)
    if [ "${#rpms[@]}" = 0 ]; then
        echo "ERROR: no rpms from this run under ${RPMS_OUT}" >&2
        INSTALL_RC=1
        return 0
    fi
    echo "=== install check: dnf install ${#rpms[@]} rpms into a clean ${CI_BASE_IMAGE} container ==="
    set +e
    "${ENGINE}" run --rm --name "${INSTALL_CONTAINER}" \
        "${PROXY_ENV[@]}" \
        -v "${RPMS_OUT}:/rpms:ro,Z" \
        "${CI_BASE_IMAGE}" \
        bash -ec 'set -x; dnf update -y; dnf install -y "$@"' _ "${rpms[@]}"
    INSTALL_RC=$?
    set -e
}
