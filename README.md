# ceph-ci — a riscv64 Ceph CI on openRuyi

A dedicated CI that builds Ceph and runs `make check` (ctest) on **riscv64
hardware**, inside an **openRuyi** container, by reusing Ceph's own containerized
PR job (`src/script/build-with-container.py`). The commands, flags and result
format match the existing `ceph-pull-requests-*` jobs, so it lines up with a
`ceph-pull-requests-riscv64` job rather than its own ad-hoc setup.

## How it works

You run **one command** — `scripts/run-build-check.sh` (also the body of the
GitHub Actions workflow). It is self-contained; the three stages below are what
that single script does internally, not separate steps to invoke:

1. Clone `ceph/ceph` at `CEPH_REF` (default `main`; any branch / tag / sha).
2. Apply the openRuyi + riscv64 fork-patches onto the clean tree, auto-skipping
   any already merged upstream.
3. Run `build-with-container.py --distro openruyi -e tests`, which configures,
   builds and runs ctest **inside the openRuyi container**. The cmake flags and
   the ctest command come from Ceph's own `run-make.sh` / `run-make-check.sh`.

See [`OPERATING.md`](./OPERATING.md) for the exact invocation.

## Fork patches

[`fork-patches/`](./fork-patches) carries the changes that teach `ceph/ceph` to
build on openRuyi + riscv64. The four-digit prefix marks intent, the same way
openRuyi numbers its spec `%patchlist`:

- **1xxx — bound for upstream**: either ours or carried from openRuyi's ceph
  spec; each comment links the PR/commit, or marks `TODO` if not yet submitted.
- **2xxx — openRuyi downstream**, not intended for upstream.

## Scope

The **build-check** CI runs `make check` (ctest) — the same scope as upstream's
containerized PR job, and the main target here. Single-node IO smoke testing is a
possible follow-up; teuthology and multi-machine testing stay with upstream's Sepia lab.

## The three CIs

One workflow (`build-and-check.yml`), three mutually-exclusive paths, each with its own
driver script and its own `${WORKDIR}/<bucket>/` subdir on the runner so their logs,
checkouts and caches never interleave:

| CI | what it does | driver | bucket |
|----|--------------|--------|--------|
| **build-check** | clone ceph + apply fork-patches + build + ctest (the PR-style job) | `scripts/run-build-check.sh` | `${WORKDIR}/build-check/` |
| **spec-openruyi** | rpmbuild the **downstream** `openruyi/ceph.spec` + ctest + dnf install the rpms | `scripts/openruyi/run-spec-build.sh` | `${WORKDIR}/spec-openruyi/` |
| **spec-upstream** | make-dist the **upstream** `ceph.spec.in` → rpmbuild + ctest | `scripts/upstream-spec/run-spec-in-build.sh` | `${WORKDIR}/spec-upstream/` |

Inside every bucket the same names recur: `run.log` (symlink to the newest run),
`ci-log/` (timestamped run + mem logs), `ceph/` (the checkout, build-check & spec-upstream),
`build/` `sources/` `rpms/` `artifacts/` `state/` (spec paths), `sccache-cache/`,
`ccache-cache/` (build-check).

## Site configuration

No value that ties this CI to one particular lab is committed to the tree: the
site-specific settings have no defaults, and [`scripts/lib/site.sh`](./scripts/lib/site.sh)
reads each from the environment. The workflow supplies them from repository
variables (Settings → Secrets and variables → Actions → Variables):

| what | how to set it |
|------|---------------|
| where the runner keeps its buckets — **required** | `CI_WORKDIR`. The workflow fails on the first step if it is unset, rather than defaulting to a path the runner wipes between jobs. |
| an extra OBS project layered over the stock repos (dnf `priority=1`), for packages openRuyi does not carry yet — optional | `CI_TEMP_OBS_PROJECT`, reaching the drivers as `TEMP_OBS_PROJECT`. Unset means `TEMP_OBS_REPO=0` (the default): build against the stock repos only. The build-check path renders fork patch `2005-…` from this value, so there is nothing to keep in step by hand. |
| the proxy the runner reaches github through — optional | `CI_PROXY_PROBE`. Unset means the runner has direct external network and no probe is attempted. |
| which self-hosted boards exist | the `runner` input's `options` list in [`.github/workflows/build-and-check.yml`](./.github/workflows/build-and-check.yml) — replace with your own runner labels. |

Running the drivers by hand, the same values come from the environment
(`CI_WORKDIR` is `WORKDIR` there); every driver's header comment lists its own.

## License

[MulanPSL-2.0](./LICENSE), except `fork-patches/` and `scripts/upstream-spec/*.patch`,
which are changes to [ceph/ceph](https://github.com/ceph/ceph) and carry ceph's
own license.

## More

How to run and operate this CI: [`OPERATING.md`](./OPERATING.md).
