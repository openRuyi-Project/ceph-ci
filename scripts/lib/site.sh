# shellcheck shell=bash
# Site-specific defaults shared by the three CI drivers (sourced, not executed).
# Every value here can be overridden from the environment; this file is the one
# place to edit when the CI moves to another host, proxy or OBS project.

# Temporary OBS project layered over the stock openRuyi repos (dnf priority=1) for
# packages the distro does not carry yet. Site-specific, so no default: set
# TEMP_OBS_PROJECT to enable it. All three paths derive the repo from these two
# values -- the spec paths write the dnf repo file, build-check renders fork patch
# 2005.
TEMP_OBS_PROJECT="${TEMP_OBS_PROJECT:-}"
TEMP_OBS_REPO_URL="${TEMP_OBS_REPO_URL:-https://repo.build.openruyi.cn/${TEMP_OBS_PROJECT//:/:\/}/riscv64/}"

# Proxy for github and the other external hosts the build fetches from. Site-specific,
# so no default: unset = direct. Probed against a git smart-http endpoint, since a
# proxy may policy-block github's web root and api. openRuyi repos go direct.
CI_PROXY_PROBE="${CI_PROXY_PROBE:-}"
CI_PROXY_PROBE_URL="${CI_PROXY_PROBE_URL:-${CEPH_REPO:-https://github.com/ceph/ceph.git}/info/refs?service=git-upload-pack}"
CI_PROXY_PROBE_RETRIES="${CI_PROXY_PROBE_RETRIES:-5}"
CI_PROXY_PROBE_DELAY="${CI_PROXY_PROBE_DELAY:-5}"
CI_NO_PROXY="${CI_NO_PROXY:-boat.openruyi.cn,repo.build.openruyi.cn,.openruyi.cn,goproxy.cn,127.0.0.1,localhost}"

# ci_resolve_proxy: set CI_PROXY ("" = direct). An explicit GIT_PROXY wins ('direct'
# or empty -> none); an unset CI_PROXY_PROBE means the site needs no proxy. Otherwise
# the probe runs with retries and aborts if it never answers.
# shellcheck disable=SC2034  # CI_PROXY is read by the sourcing driver
ci_resolve_proxy() {
    local try=1
    CI_PROXY=""
    if [ -n "${GIT_PROXY+x}" ]; then
        [ "${GIT_PROXY}" = direct ] || CI_PROXY="${GIT_PROXY}"
        return 0
    fi
    if [ -z "${CI_PROXY_PROBE}" ]; then
        echo "  proxy: none configured (CI_PROXY_PROBE unset); going direct"
        return 0
    fi
    while [ "${try}" -le "${CI_PROXY_PROBE_RETRIES}" ]; do
        if curl -fsS -x "${CI_PROXY_PROBE}" -m 10 -o /dev/null "${CI_PROXY_PROBE_URL}" 2>/dev/null; then
            CI_PROXY="${CI_PROXY_PROBE}"
            echo "  proxy: auto-detected ${CI_PROXY_PROBE} (attempt ${try})"
            return 0
        fi
        echo "  proxy: probe ${CI_PROXY_PROBE} failed (attempt ${try}/${CI_PROXY_PROBE_RETRIES})" >&2
        [ "${try}" -lt "${CI_PROXY_PROBE_RETRIES}" ] && sleep "${CI_PROXY_PROBE_DELAY}"
        try=$((try + 1))
    done
    echo "ERROR: proxy probe ${CI_PROXY_PROBE} could not reach ${CI_PROXY_PROBE_URL%%/info/refs*} after ${CI_PROXY_PROBE_RETRIES} attempts." >&2
    echo "       This is a network problem, not a build failure; aborting now." >&2
    echo "       To force a proxy-less direct run, re-run with GIT_PROXY=direct." >&2
    exit 1
}

# ci_require_temp_obs: TEMP_OBS_REPO=1 needs a project to point at; fail here rather
# than letting an empty baseurl reach dnf inside a container.
ci_require_temp_obs() {
    [ "${TEMP_OBS_REPO}" = 1 ] || return 0
    if [ -z "${TEMP_OBS_PROJECT}" ]; then
        echo "ERROR: TEMP_OBS_REPO=1 but TEMP_OBS_PROJECT is empty." >&2
        echo "       Set TEMP_OBS_PROJECT to the OBS project to layer in (the workflow" >&2
        echo "       takes it from the CI_TEMP_OBS_PROJECT repository variable), or run" >&2
        echo "       with TEMP_OBS_REPO=0 to use the stock openRuyi repos only." >&2
        exit 1
    fi
}

# ci_temp_obs_desc: one-line description of the temp-repo setting for a run banner.
ci_temp_obs_desc() {
    if [ "${TEMP_OBS_REPO}" = 1 ]; then
        echo "deps prefer ${TEMP_OBS_PROJECT}"
    else
        echo "stock openRuyi repos only"
    fi
}

# ci_temp_obs_fingerprint: the deps-image fingerprint token for the temp repo
# setting, so toggling it or changing the project rebuilds the image.
ci_temp_obs_fingerprint() {
    if [ "${TEMP_OBS_REPO}" = 1 ]; then
        echo "tempobs:${TEMP_OBS_PROJECT}"
    else
        echo "tempobs:0"
    fi
}

# ci_write_temp_obs_repo DEST: write the dnf repo file for the temp project; the spec
# drivers put it in the deps container's /deps-meta. OBS RPMs are unsigned
# (gpgcheck=0), and an unreachable project must not break CI (skip_if_unavailable=1).
ci_write_temp_obs_repo() {
    cat > "$1" <<REPO
[ceph-ci-temp-obs]
name=${TEMP_OBS_PROJECT:?} (riscv64)
baseurl=${TEMP_OBS_REPO_URL:?}
enabled=1
gpgcheck=0
priority=1
skip_if_unavailable=1
REPO
}
