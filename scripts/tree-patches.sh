# shellcheck shell=bash
# Fork patch list for run-build-check.sh (sourced, not executed); expects
# TEMP_OBS_REPO to be set by the caller. Patches apply in listed order; comment a line
# out to skip it, an already-present one is auto-skipped. Numbering: 1xxx =
# upstream-bound (comment links the PR), 2xxx = openRuyi downstream.
TREE_PATCHES=(
    # -- 1xxx: upstream-bound --
    # https://github.com/ceph/ceph/pull/69448
    1004-pmdk-riscv64-use-daos-stack.patch
    # https://github.com/ceph/ceph/pull/69519
    1024-pybind-rbd-rgw-place-nogil-after-the-exception-speci.patch
    # https://github.com/ceph/ceph/pull/69643
    1039-make-run-rbd-unit-tests-faster.patch

    # todo
    1046-test-crimson-onode-shrink-synthetic-pool-under-ASan.patch
    1047-test-transaction_manager-shrink-working-set-under-AS.patch

    # https://github.com/ceph/ceph/pull/70966
    1060-osd-fix-misspelled-inject-ec-clear-command-names.patch
    # https://github.com/ceph/ceph/pull/70965
    1064-osd-avoid-inserting-empty-OI_ATTR-in-rollback_setatt.patch

    # todo
    1085-mgr-DaemonServer-fix-order-dependent-ok-to-stop-fals.patch

    # todo
    1089-ceph_dedup-avoid-divide-by-zero-in-EstimateResult-du.patch
    1090-ceph_dedup-write-chunk-data-at-offset-0-in-make_dedu.patch
    1091-ceph_dedup-validate-sampling-ratio-range-in-daemon.patch
    1092-cephfs-data-scan-increment-progress-in-scan_frags.patch
    1093-cephfs-bench-reject-a-block-size-of-0.patch
    1094-cephfs-bench-fix-invalid-short-option-name-for-files.patch
    1095-kv-rocksdb_cache-fix-BinnedLRUCache-l_elems-counter-.patch

    1097-test-add-RISC-V-architecture-probe-tests.patch

    # https://github.com/ceph/ceph/pull/70959
    1103-rbd-mirror-deadlock.patch

    # todo
    1107-rbd-mirror-reset-pagination-cursor-before-listing-mi.patch
    1108-rbd-mirror-release-granted-sync-slot-when-canceled-a.patch
    1109-rbd-mirror-start-queued-ops-after-draining-a-namespa.patch
    1110-rbd-mirror-honor-deferred-trash-refresh-once-list-co.patch
    1111-rbd-mirror-complete-init-on-remote-fsid-retrieval-fa.patch
    1112-rbd-mirror-don-t-pollute-replay-stats-on-skipped-dem.patch
    1113-rbd-mirror-guard-m_image_map-init-with-m_lock.patch
    1114-rbd-mirror-keep-peer-config-key-resolution-callout.patch

    # todo
    1118-rgw-keystone-guard-against-empty-secret-file-in-read.patch
    1119-rgw-d4n-pass-next_cursor-by-reference-in-BucketDirec.patch
    1120-rgw-d4n-fix-operator-precedence-in-LFUDA-sync-error-.patch
    1121-rgw-amqp-avoid-dereferencing-end-in-multiple-ack-loo.patch

    # https://github.com/ceph/ceph/pull/70007
    1123-rgw-es-require-both-major-and-minor-in-ES-version-pa.patch

    1124-rgw-preserve-endpoint-base-path-prefix-in-REST-clien.patch

    1125-rgw-fix-use-after-free-of-meta_sync_cr-in-RGWRemoteM.patch
    1126-rgw-reserve-allocated_acls-to-avoid-dangling-ACL-poi.patch
    1127-rgw-posix-fix-list_buckets-pagination-and-unchecked-.patch
    1128-rgw-keystone-check-barbican-401-before-generic-error.patch
    1129-rgw-posix-do-not-update-quota-stats-when-object-remo.patch

    # https://github.com/ceph/ceph/pull/70149
    1132-osd-PeeringState-fix-proc_master_log-divergence-chec.patch

    1133-test-osd-add-unittest-for-proc_master_log-wind-forwa.patch

    # https://github.com/ceph/ceph/pull/70207
    1134-fix-replicasplitop-read.patch

    # https://github.com/ceph/ceph/pull/70211
    1140-src-common-optimize-Zvbc-CRC32C-for-riscv64.patch

    # https://github.com/ceph/ceph/pull/70463
    1143-test-mds-run-unittest_mds_quiesce_db-serially.patch

    # https://github.com/ceph/ceph/pull/71249
    1144-cmake-boost-don-t-pass-context-impl-to-the-headers-s.patch

    # https://github.com/ceph/ceph/pull/71460
    1045-qa-lsan.supp-match-OpenSSL-error-state-on-ERR_set_ma.patch

    # -- 2xxx: openRuyi downstream, not for upstream --
    # bump pylint 2.6.0 -> 2.17.7 for py3.13 / wrapt compat
    2001-monitoring-ceph-mixin-bump-pylint.patch
    # bump cephadm pyfakefs pin to >=5.7,<6 for py3.13
    2002-cephadm-tox-pyfakefs-py313.patch

    2006-common-cohort_lru-clear-active-flag-when-object-retu.patch
    2007-rgw-posix-insert-recycled-bucket-cache-entry-under-t.patch

    # boost mirror order: archives.boost.io is fast from the CI host, download.ceph.com is not
    2008-cmake-boost-try-archives.boost.io-before-download.ce.patch

    # raise LimitJobs per-job memory estimates under sanitizers; riscv64-only data,
    # stays local until verified on x86; depends on 1145
    2009-cmake-raise-LimitJobs-memory-estimates-for-sanitizer.patch
)
# 2005: prefer the temporary OBS project (priority=1) for deps, falling back to the
# stock repos. A .patch.in template: the driver substitutes TEMP_OBS_PROJECT /
# TEMP_OBS_REPO_URL from scripts/lib/site.sh, so no patch here carries a site value.
if [ "${TEMP_OBS_REPO}" = 1 ]; then
    TREE_PATCHES+=(2005-build-prefer-a-temporary-OBS-repo-for-deps.patch.in)
fi
