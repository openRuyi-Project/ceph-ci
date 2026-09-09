# shellcheck shell=bash
# The openRuyi base image: its local tag and the host-profile probe that picks
# which upstream build to fetch. Sourced, not executed.

# Local tag of the base image every path builds on; fixed because
# build-with-container.py's DefaultImage.OPENRUYI hardcodes this name.
# shellcheck disable=SC2034  # read by the sourcing script
CI_BASE_IMAGE="${OPENRUYI_IMAGE:-localhost/openruyi-oci:riscv64}"

# ci_openruyi_baseline: echo the openRuyi build that matches this host's RISC-V
# profile -- riscv64 for RVA23 boards (SG2044, has 'v'), rva20 for RVA20 boards
# (SG2042, no 'v', where RVA23 binaries SIGILL). OPENRUYI_BASELINE overrides the
# probe, with either a baseline name or an ISA string.
ci_openruyi_baseline() {
    local isa="${OPENRUYI_BASELINE:-$(grep -m1 -oE 'rv64[a-z]+' /proc/cpuinfo)}"
    case "${isa#rv64}" in   # strip 'rv64' so its own 'v' cannot false-match
        *v*) echo riscv64 ;;
        *)   echo rva20 ;;
    esac
}
