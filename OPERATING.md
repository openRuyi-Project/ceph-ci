# Operating this CI

## Repo layout

| path | what |
|------|------|
| `scripts/fetch-openruyi-image.sh` | `podman pull` the openRuyi minimal OCI image from the registry and tag it `localhost/openruyi-oci:riscv64` (always pulls so upstream updates land; `OFFLINE=1` to reuse the local image) |
| `scripts/fetch-openruyi-image-obs.sh` | alt source: download the OBS rootfs tarball + `podman import` it as `localhost/openruyi-oci:riscv64` (conditional download; `OFFLINE=1` to re-import the cached tarball) |
| `scripts/lib/image.sh` | the openRuyi base image: its local tag (`CI_BASE_IMAGE`, read by the fetch scripts and the spec drivers) and the probe that picks the build (riscv64 / rva20) matching the host's RISC-V profile |
| `scripts/lib/site.sh` | the site settings shared by the three drivers: temporary OBS project, proxy probe, no-proxy list. The first two have no default and come from the environment (see README, *Site configuration*) |
| `scripts/lib/common.sh` | helpers shared by the three drivers: arch check, run.log setup, signal cleanup, the git network config + ceph checkout, ctest options from `known-failures.json`, memory sampler |
| `scripts/lib/spec-host.sh` | host-side helpers shared by the two spec drivers: persistent dirs, deps-image reuse/refresh/rebuild, the build container run |
| `scripts/lib/spec-container.sh` | container-side helpers shared by the two spec container halves (mounted at `/spec-lib.sh`): tooling install, temp repo, builddep, sccache, ctest on the spec's build tree |
| `scripts/run-build-check.sh` | **build-check** driver (upstream main): clone ceph @ ref, apply fork patches, run `build-with-container.py --distro openruyi -e tests`; bucket `${WORKDIR}/build-check/` |
| `scripts/openruyi/run-spec-build.sh` | **spec-openruyi** driver (`openruyi_spec` option): host side -- image, proxy, caches, ctest options -- then launch the container half; bucket `${WORKDIR}/spec-openruyi/` |
| `scripts/openruyi/spec-build-in-container.sh` | container half: `rpmdev-spectool -g` + `dnf builddep` + `rpmbuild -bb --nocheck --with make_check` on `openruyi/ceph.spec`, then build-check-style ctest on the spec's build tree |
| `openruyi/` | the openRuyi downstream `ceph.spec` + its `%patchlist`/source patches (validated by `run-spec-build.sh`) |
| `scripts/upstream-spec/run-spec-in-build.sh` | **spec-upstream** driver: validate the UPSTREAM `ceph.spec.in`: upstream checkout (pristine, or with `scripts/upstream-spec/*.patch` applied+committed to test a patch bound for upstream), host side (image, proxy, caches, ctest), then the container half; bucket `${WORKDIR}/spec-upstream/` |
| `scripts/upstream-spec/*.patch` | optional patches applied onto the upstream checkout before make-dist (e.g. one you're preparing to submit upstream); none present = a clean upstream build |
| `scripts/upstream-spec/spec-in-build-in-container.sh` | container half: upstream `make-dist` (`ceph.spec.in` -> `ceph.spec` + Source0 tarball; dashboard npm step skipped unless `MAKE_DIST_FULL=1`) + `dnf builddep`, then validate the spec via rpm short-circuit (`-bc` -> ctest on the tree -> `-bi --short-circuit` -> `-bl`), or a full `-bb` under `SKIP_CTEST=1` |
| `fork-patches/` | patches teaching ceph about openRuyi + riscv64, rebased onto ceph `main` (`TREE_PATCHES` in `scripts/tree-patches.sh`). A `.patch.in` is a template: the driver substitutes the site values from `scripts/lib/site.sh` before applying it |
| `.github/workflows/build-and-check.yml` | the three CIs (build-check / spec-openruyi / spec-upstream) on a `[self-hosted, linux, riscv64]` runner (manual dispatch) |
| `known-failures.json` | ctest excludes/flakes (tagged `exclude`/`flake`), turned into ctest options by `ci_ctest_makeopts` for all three drivers |

## On-machine layout (which dir belongs to which CI)

Each of the three CIs owns ONE subdir under `${WORKDIR}` (the workflow sets it from
the required repository variable `CI_WORKDIR`; a hand-run driver defaults it to this
repo's parent dir). Nothing is shared or flat — to inspect a run, `cd` into its
bucket and everything there is that CI's:

```
${WORKDIR}/
  build-check/        # scripts/run-build-check.sh   (workflow: default, no spec toggle)
  spec-openruyi/      # scripts/openruyi/run-spec-build.sh        (openruyi_spec ticked)
  spec-upstream/      # scripts/upstream-spec/run-spec-in-build.sh (upstream_spec ticked)
```

Inside every bucket the same names recur (so the layout is identical across CIs):

| name | what |
|------|------|
| `run.log` | symlink to the newest run's log — `tail -f <bucket>/run.log` follows it live |
| `mem-usage.log` | symlink to the newest run's memory-sampler log (used/avail, loadavg, cpu idle, top 6 processes, count and total RSS of cc1plus/ld) |
| `ci-log/` | timestamped per-run logs (`<ts>-run.log`, `<ts>-mem.log`) — the history |
| `ceph/` | the ceph checkout + `build/` tree (build-check & spec-upstream; spec-openruyi builds inside its rpm `build/` instead) |
| `build/` | spec paths only: the persisted rpm `BUILD/` tree (cmake build + BUILDROOT) |
| `sources/` `rpms/` `artifacts/` `state/` | spec paths only: spectool/make-dist tarballs, built rpms, ctest `Testing/`+`CMakeCache`, generated spec |
| `sccache-cache/` | the per-CI sccache cache (kept separate so differing compile flags don't churn one shared cache) |
| `ccache-cache/` | build-check only: the ccache cache, for the ExternalProjects (arrow, pmdk) that compile via their own make instead of ceph's `-DWITH_SCCACHE=ON` |
| `.image-fp` / `.deps-fp` / `.deps-pkghash` / `.deps-meta` | cached build/deps-image fingerprints |

## Running by hand (riscv64 host)

```bash
# host needs riscv64, podman >= 4, git. openRuyi is not required on the host;
# the build runs in the openRuyi container.
git clone <this repo> ceph-ci && cd ceph-ci
CEPH_REF=main ./scripts/run-build-check.sh
```

Validate the openRuyi downstream spec instead of upstream main (`rpmbuild` of
`openruyi/ceph.spec` in the container -- spec drives `%prep`/`%build`/`%install`,
no fork-patches -- then ctest on its build tree, with the spec's own downstream
config: `WITH_CRIMSON=OFF`, RelWithDebInfo, no ASan):

```bash
./scripts/openruyi/run-spec-build.sh
```

Via the GitHub UI once the runner is up: Actions → build-and-check → "Run workflow"
(tick `openruyi_spec` for the spec-validation path; it ignores `ceph_ref`).

Validate the **upstream** `ceph.spec.in` (not the `openruyi/` spec): an upstream
checkout, upstream `make-dist` turns `ceph.spec.in` into a real `ceph.spec` + Source0
tarball, then `rpmbuild` validates it and ctest runs on its build tree. Because the
spec's `%install` deletes the cmake tree (`rm -rf %{_vpath_builddir}`), the spec is
built via rpm short-circuit so the tree survives for ctest — no spec edits:

```bash
./scripts/upstream-spec/run-spec-in-build.sh
# CEPH_REF=<branch/tag/sha>   pick the upstream revision (default main)
# SKIP_CTEST=1                full `rpmbuild -bb` (real rpms, %install/%files), no ctest
# MAKE_DIST_FULL=1            run vanilla make-dist incl. the dashboard frontend npm build
```

To test a patch you intend to submit upstream, drop it in `scripts/upstream-spec/`
(`*.patch`): each is `git apply`'d and committed onto the checkout before make-dist
(committed so make-dist's `git archive HEAD` tarball picks up source changes too). A
patch that changes BuildRequires rebuilds the deps image automatically. With no
`*.patch` present the checkout is pristine upstream.

By default `make-dist`'s dashboard-frontend npm build is skipped: the spec's `%build`
sets `WITH_MGR_DASHBOARD_FRONTEND=OFF`, so that (heavy, riscv64-flaky) output is never
used by `rpmbuild`. `MAKE_DIST_FULL=1` runs make-dist verbatim.

## ctest tuning (known-failures.json)

ctest options are assembled by `ci_ctest_makeopts` (`scripts/lib/common.sh`) from
`known-failures.json` and forwarded as `CHECK_MAKEOPTS` — nothing is set by hand:

- `--timeout 18000` — the fallback ceiling for this slow hardware (`CI_CTEST_TIMEOUT`
  in `scripts/lib/common.sh`, which also feeds `-DCEPH_TEST_TIMEOUT`, the per-test
  property that actually kills a test).
- `-E '^(...)$'` — `known-failures.json` entries tagged `exclude`.
- `--repeat until-pass:N` — added when any entry is tagged `flake` (`N`=`FLAKE_RETRIES`, default 2).

The cmake feature set is a separate axis — the `CONFIGURE_FLAGS` array in
`run-build-check.sh`. The spec paths do not have one: the spec owns its own
configure line.
