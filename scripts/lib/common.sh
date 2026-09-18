# shellcheck shell=bash
# shellcheck disable=SC2034  # variables set here are read by the sourcing driver
# Helpers shared by the three CI drivers, sourced after site.sh. They read the
# driver's globals REPO_ROOT, BASE (this CI's bucket under WORKDIR) and ENGINE.

# ci_bool VAR DEFAULT: normalize a yes/no env var to 0/1 in place (empty or unset
# -> DEFAULT); anything else aborts.
ci_bool() {
    local val="${!1:-$2}"
    case "${val,,}" in
        1|true|yes|on)   printf -v "$1" 1 ;;
        0|false|no|off)  printf -v "$1" 0 ;;
        *) echo "ERROR: $1='${val}' is not a boolean (0/1, true/false, yes/no, on/off)" >&2; exit 1 ;;
    esac
}

# Per-test ctest kill time for this slow hardware. Feeds both -DCEPH_TEST_TIMEOUT
# (the TIMEOUT property add_ceph_test stamps, which wins over ctest --timeout) and
# ctest --timeout, so the two cannot drift apart.
CI_CTEST_TIMEOUT="${CI_CTEST_TIMEOUT:-18000}"

# Abort a git transfer moving fewer than LIMIT bytes/s for TIME seconds; git itself
# has no transfer timeout. Forwarded into the build-check containers too.
GIT_LOW_SPEED_LIMIT="${GIT_LOW_SPEED_LIMIT:-1000}"
GIT_LOW_SPEED_TIME="${GIT_LOW_SPEED_TIME:-60}"

# ci_require_riscv64: the CI builds natively, never under QEMU.
ci_require_riscv64() {
    if [ "$(uname -m)" != riscv64 ]; then
        echo "ERROR: host arch is $(uname -m); this CI must run on riscv64 hardware." >&2
        exit 1
    fi
}

# ci_git_net_args: GIT_NET_ARGS, the command-level git config every network call
# takes -- pinned proxy (empty = none), low-speed guard, and GIT_TERMINAL_PROMPT=0 so
# a throttled github 401 fails with "could not read Username" (the signature
# run-build-check.sh retries on) instead of prompting. Needs CI_PROXY.
ci_git_net_args() {
    GIT_NET_ARGS=(
        -c "http.lowSpeedLimit=${GIT_LOW_SPEED_LIMIT}"
        -c "http.lowSpeedTime=${GIT_LOW_SPEED_TIME}"
    )
    if [ -n "${CI_PROXY}" ]; then
        GIT_NET_ARGS+=(-c "http.proxy=${CI_PROXY}" -c "https.proxy=${CI_PROXY}")
    else
        GIT_NET_ARGS+=(-c "http.proxy=" -c "https.proxy=")
    fi
    export GIT_TERMINAL_PROMPT=0
}

# ci_submodule_sync DIR: check the submodule worktrees out to the index gitlinks.
# --force re-checks out incomplete worktrees; -c http.proxy reaches child clones via
# GIT_CONFIG_PARAMETERS. Re-run after a patch bumps a gitlink -- git apply rewrites
# only the index entry. `submodule sync` first: a patch may also point .gitmodules
# at a fork, and update fetches from the URL recorded in .git/config at init time.
ci_submodule_sync() {
    git -C "$1" submodule sync --recursive >/dev/null
    git -C "$1" "${GIT_NET_ARGS[@]}" submodule update --init --force --recursive ${CI_PROXY:+--jobs 4}
}

# ci_checkout_ceph REPO REF DIR [FETCH_ARG...]: clone or update DIR to REF, with the
# submodules in sync and no leftovers from the previous run. Sets CEPH_SHA. Needs
# GIT_NET_ARGS (ci_git_net_args).
ci_checkout_ceph() {
    local repo="$1" ref="$2" dir="$3"
    shift 3
    if [ ! -d "${dir}/.git" ]; then
        git "${GIT_NET_ARGS[@]}" clone "${repo}" "${dir}"
    fi
    # An interrupted git leaves *.lock files that fail every later git write; nothing
    # else runs git on this checkout, so clear them unless a git process is alive.
    if ! pgrep -x git >/dev/null; then
        find "${dir}/.git" -name "*.lock" -delete
    fi
    # REF may be a branch/tag or a bare sha; GitHub rejects fetch-by-sha, so a failed
    # fetch falls back to the local object. Bare shas only: runs check out FETCH_HEAD
    # detached and never advance local branch refs, so a branch name would resolve to
    # whatever the clone saw and silently build stale code.
    if git -C "${dir}" "${GIT_NET_ARGS[@]}" fetch --force "$@" "${repo}" "${ref}"; then
        git -C "${dir}" checkout --force FETCH_HEAD
    elif [[ "${ref}" =~ ^[0-9a-f]{7,40}$ ]] &&
         git -C "${dir}" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
        echo "fetch of ${ref} failed; commit exists locally, using local object"
        git -C "${dir}" checkout --force "${ref}"
    else
        echo "ERROR: cannot fetch ${ref} from ${repo}" >&2
        exit 1
    fi
    # checkout --force leaves untracked files (manual testing, a prior make-dist's
    # in-tree tarball/spec), which collide with --3way patches that create new files.
    # No -x, so build/ and other ignored artifacts survive.
    git -C "${dir}" clean -fd
    ci_submodule_sync "${dir}"
    CEPH_SHA="$(git -C "${dir}" rev-parse --short HEAD)"
    echo "checked out ceph ${ref} @ ${CEPH_SHA}"
}

# ci_newest_first GLOB...: the paths that exist, newest mtime first, one per line.
ci_newest_first() {
    local -a found=()
    local f
    for f in "$@"; do [ -e "${f}" ] && found+=("${f}"); done
    [ "${#found[@]}" -gt 0 ] || return 0
    stat -c '%Y %n' "${found[@]}" | sort -rn | cut -d' ' -f2-
}

# ci_open_run_log: from here on tee stdout+stderr into a timestamped log under
# ${BASE}/ci-log/, with ${BASE}/run.log pointing at the newest so `tail -f` follows
# the current run; each line is prefixed with the elapsed wall time. Sets RUN_LOG.
ci_open_run_log() {
    local t0
    mkdir -p "${BASE}/ci-log"
    RUN_LOG="${BASE}/ci-log/$(date +%Y%m%d-%H%M%S)-run.log"
    ln -sfn "${RUN_LOG}" "${BASE}/run.log"
    t0=$(date +%s)
    exec > >(gawk -v t0="${t0}" \
        '{ t = systime() - t0; printf "[%02d:%02d:%02d] %s\n", t/3600, (t%3600)/60, t%60, $0; fflush() }' \
        | stdbuf -oL tee -a "${RUN_LOG}") 2>&1
}

# ci_kill_containers NAME...: kill and remove the named containers, ignoring absent ones.
ci_kill_containers() {
    local c
    for c in "$@"; do
        "${ENGINE}" kill "${c}" >/dev/null 2>&1 || true
        "${ENGINE}" rm -f "${c}" >/dev/null 2>&1 || true
    done
}

# ci_trap_cleanup NAME...: on INT/TERM stop the memory sampler, run CI_CLEANUP_HOOK
# and kill the named containers (they outlive the podman client under conmon).
# Exits 130.
CI_CLEANUP_CONTAINERS=()
CI_CLEANUP_HOOK=""
_ci_cleanup_on_signal() {
    trap - INT TERM
    if [ -n "${MEM_SAMPLER_PID:-}" ]; then
        kill "${MEM_SAMPLER_PID}" 2>/dev/null || true
    fi
    if [ -n "${CI_CLEANUP_HOOK}" ]; then
        "${CI_CLEANUP_HOOK}" || true
    fi
    echo "=== interrupted: killing ${CI_CLEANUP_CONTAINERS[*]} ==="
    ci_kill_containers "${CI_CLEANUP_CONTAINERS[@]}"
    exit 130
}
ci_trap_cleanup() {
    CI_CLEANUP_CONTAINERS=("$@")
    trap _ci_cleanup_on_signal INT TERM
}

# ci_container_proxy_env: PROXY_ENV, the -e flags that forward CI_PROXY into a
# container run (empty when direct). CI_NO_PROXY hosts are reached direct.
ci_container_proxy_env() {
    PROXY_ENV=()
    if [ -n "${CI_PROXY}" ]; then
        PROXY_ENV=(-e "http_proxy=${CI_PROXY}" -e "https_proxy=${CI_PROXY}" -e "no_proxy=${CI_NO_PROXY}")
    fi
}

# ci_ctest_makeopts: CHECK_MAKEOPTS, the ctest options every path forwards:
#   -j CTEST_JOBS
#   --timeout        fallback ceiling only (CI_CTEST_TIMEOUT); add_ceph_test stamps
#                    each test with a TIMEOUT property that overrides it
#   -E '^(...)$'     known-failures.json entries of type "exclude"
#   --repeat         retry when any type "flake" entry exists (FLAKE_RETRIES)
#   --test-output-size-failed  cap the output dumped per failed test; ctest keeps
#                    the tail, which holds the gtest/sanitizer verdict
# ctest -E works per ctest name (a whole gtest binary); a single flaky gtest case
# needs GTEST_FILTER. Never set JENKINS_HOME: run-make-check.sh then swallows
# ctest's exit code.
ci_ctest_makeopts() {
    local kf="${KNOWN_FAILURES:-${REPO_ROOT}/known-failures.json}" parsed="" exclude_re="" have_flakes=""
    CHECK_MAKEOPTS="-j${CTEST_JOBS} --timeout ${CI_CTEST_TIMEOUT} --test-output-size-failed ${CTEST_FAIL_OUTPUT_BYTES:-100000}"
    if [ -f "${kf}" ]; then
        # A malformed file aborts; degrading to "exclude nothing" would turn every
        # known failure into a red run.
        if ! parsed="$(python3 - "${kf}" <<'PY'
import json, sys
fails = json.load(open(sys.argv[1])).get("failures", [])
names = [e["test"] for e in fails if e.get("type") == "exclude"]
print("^(" + "|".join(names) + ")$" if names else "")
print("1" if any(e.get("type") == "flake" for e in fails) else "")
PY
)"; then
            echo "ERROR: cannot parse ${kf}; fix the file or point KNOWN_FAILURES elsewhere." >&2
            exit 1
        fi
        # The second read hits EOF when there are no flake entries; not a failure.
        { read -r exclude_re; read -r have_flakes; } <<< "${parsed}" || true
        [ -n "${exclude_re}" ] && CHECK_MAKEOPTS+=" -E ${exclude_re}"
        [ -n "${have_flakes}" ] && CHECK_MAKEOPTS+=" --repeat until-pass:${FLAKE_RETRIES:-2}"
    fi
    echo "  CHECK_MAKEOPTS='${CHECK_MAKEOPTS}'"
}

# Memory sampler: host memory and the top RSS processes every MEM_SAMPLE_INTERVAL
# seconds into a sibling mem.log, so an OOM-killed run can be diagnosed afterwards.
# Host-side ps sees the in-container processes. Samples are tagged BUILD or TEST by
# whether ctest is running.
_ci_mem_sampler() {
    local phase last_phase="" prev_idle prev_total idle total idle_pct
    read -r prev_idle prev_total < <(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print $5+$6, t}' /proc/stat)
    while :; do
        if pgrep -x ctest >/dev/null 2>&1; then phase=TEST; else phase=BUILD; fi
        if [ "${phase}" != "${last_phase}" ]; then
            printf '===== %s phase @ %s =====\n' "${phase}" "$(date '+%H:%M:%S')"
            last_phase="${phase}"
        fi
        # cpu idle over the sample interval, from the /proc/stat aggregate line
        read -r idle total < <(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print $5+$6, t}' /proc/stat)
        if [ "${total}" -gt "${prev_total}" ]; then
            idle_pct=$(( 100 * (idle - prev_idle) / (total - prev_total) ))
        else
            idle_pct=-1
        fi
        prev_idle=${idle}; prev_total=${total}
        free -m | awk -v ts="$(date '+%H:%M:%S')" -v ph="${phase}" \
            -v la="$(cut -d' ' -f1 /proc/loadavg)" -v id="${idle_pct}" \
            '/^Mem:/{printf "[%s %s] used=%sM avail=%sM load=%s idle=%d%%", ts, ph, $3, $7, la, id}'
        # top 6 processes, then count and total RSS of the compiler/linker processes
        ps -eo rss=,comm= --sort=-rss | awk '
            NR<=6 { printf " %s=%dM", $2, $1/1024 }
            $2=="cc1plus" || $2=="ld" || $2=="ld.lld" || $2=="ld.mold" { n[$2]++; s[$2]+=$1 }
            END { split("cc1plus ld ld.lld ld.mold", L, " ")
                  for (i=1; i<=4; i++) if (L[i] in n) printf " n_%s=%d rss_%s=%dM", L[i], n[L[i]], L[i], s[L[i]]/1024
                  print "" }'
        sleep "${MEM_SAMPLE_INTERVAL:-5}"
    done
}
# ci_mem_sampler_start: sets MEM_LOG and MEM_SAMPLER_PID; ${BASE}/mem-usage.log
# points at the current log.
ci_mem_sampler_start() {
    MEM_LOG="${BASE}/ci-log/$(date +%Y%m%d-%H%M%S)-mem.log"
    ln -sfn "${MEM_LOG}" "${BASE}/mem-usage.log"
    _ci_mem_sampler >> "${MEM_LOG}" 2>&1 &
    MEM_SAMPLER_PID=$!
    echo "  memory sampler pid=${MEM_SAMPLER_PID} -> ${MEM_LOG}"
}
# ci_mem_sampler_stop: stop the sampler and print the per-phase usage peak and the
# peak compiler/linker RSS into run.log.
ci_mem_sampler_stop() {
    kill "${MEM_SAMPLER_PID}" 2>/dev/null || true
    wait "${MEM_SAMPLER_PID}" 2>/dev/null || true
    echo "=== memory peak during build (full timeline: ${MEM_LOG}) ==="
    gawk 'match($0,/\[[0-9:]+ (BUILD|TEST)\] used=([0-9]+)M avail=([0-9]+)M/,m){
            ph=m[1]; u=m[2]+0; a=m[3]+0
            if(u>pu[ph]){pu[ph]=u; LU[ph]=$0}
            if(!(ph in pa)||a<pa[ph]){pa[ph]=a; LA[ph]=$0}
            if(match($0,/ load=([0-9.]+) idle=(-?[0-9]+)%/,c) && c[2]+0>=0){
              ns[ph]++; sl[ph]+=c[1]; si[ph]+=c[2]
              if(c[1]+0>ml[ph]) ml[ph]=c[1]+0}
          }
          END{split("BUILD TEST",ord); n=0
              for(i=1;i<=2;i++){ph=ord[i]; if(ph in pu){n++
                print "  ["ph"] peak used="pu[ph]"M @ "LU[ph]
                print "  ["ph"] min MemAvailable="pa[ph]"M @ "LA[ph]
                if(ns[ph]) printf "  [%s] load avg=%.1f max=%.1f, cpu idle avg=%d%% over %d samples\n", ph, sl[ph]/ns[ph], ml[ph], si[ph]/ns[ph], ns[ph]}}
              if(n==0) print "  (no samples captured)"}' "${MEM_LOG}" || true
    gawk 'match($0,/ (ld\.mold|ld\.lld|ld|mold|cc1plus|cc1)=([0-9]+)M/,a){if(a[2]+0>m){m=a[2]+0;p=a[1]}}
          END{if(m)print "  peak "p" RSS="m"M"}' "${MEM_LOG}" || true
    gawk '{for(i=2;i<=NF;i++) if($i ~ /^rss_[a-z.0-9]+=[0-9]+M$/){split($i,kv,"="); c=substr(kv[1],5); v=kv[2]+0
                                 if(v>m[c]){m[c]=v; n[c]=$(i-1)}}}
          END{for(c in m) print "  peak "c" total RSS="m[c]"M ("n[c]")"}' "${MEM_LOG}" || true
}
