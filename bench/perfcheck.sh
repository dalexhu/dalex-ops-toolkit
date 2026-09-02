#!/usr/bin/env bash
#
# perfcheck.sh - sysbench-based server benchmark that sizes itself to the machine
#                and reports one composite score.
#
# Detects cores, memory, storage and virtualisation, derives every sysbench
# parameter from them, runs the CPU / memory / threads / mutex tests (and file I/O
# on request), then scores each result against a fixed reference profile and
# combines them into a weighted geometric mean.
#
# Usage: ./perfcheck.sh [options]      run ./perfcheck.sh --help for details
#
# Portable: bash 3.2+, sysbench 1.0+, awk. Debian/Ubuntu and RHEL-family.

set -uo pipefail

VERSION="1.0.0"

TIME_PER_TEST=60
DO_IO=0
DO_INSTALL=0      # installing packages changes the machine being measured
FORCE=0
QUIET=0
EMIT_RESULT=0
HELP_SCORING=0
REMOTE=""
IO_DIR=""
BUSY_LIMIT_PCT=25      # refuse to start if the CPU is busier than this

usage() {
  cat <<'USAGE'
perfcheck.sh - sysbench benchmark that sizes itself to the machine

Usage: ./perfcheck.sh [options]

Options:
  --time <sec>       Seconds per test (default 60). A full run is about six minutes,
                     nine with --io
  --quick            Same as --time 10, for checking that the script works
  --io               Also run the file I/O test. Off by default: it writes a file
                     sized from RAM and free space, and the result reflects the
                     storage rather than the machine
  --io-dir <path>    Directory for the I/O test file (default: current directory)
  --install          Install sysbench when it is missing. Off by default: installing
                     packages changes the machine and loads it while doing so
  --no-install       Accepted and ignored; this is now the default
  --force            Run even when the machine is already busy
  --max-busy <pct>   Busy CPU percentage that stops the run (default 25)
  --remote <a[,b,]>  Also run on those ssh targets and print a fleet summary
  -q, --quiet        Print the summary only
  -h, --help         This help
  --help-scoring     Print the reference profile and the weights
  --version          Show version

Exit codes: 0 ran, 1 a host was unreachable or refused to run, 2 sysbench missing
            or usage error.

The composite score is a weighted geometric mean of the CPU, memory, threads and
mutex results measured against the reference profile printed by --help-scoring.
File I/O is scored separately and never enters the composite, so scores stay
comparable whether or not --io was used.
USAGE
}

need_value() {  # need_value <flag> <value...>
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    echo "$1 requires a value" >&2
    exit 2
  fi
  case "$2" in
    -*) echo "$1 requires a value, got the option $2" >&2; exit 2 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --time)       need_value "$@"; TIME_PER_TEST="$2"; shift ;;
    --time=*)     TIME_PER_TEST="${1#*=}" ;;
    --quick)      TIME_PER_TEST=10 ;;
    --io)         DO_IO=1 ;;
    --io-dir)     need_value "$@"; IO_DIR="$2"; DO_IO=1; shift ;;
    --io-dir=*)   IO_DIR="${1#*=}"; DO_IO=1 ;;
    --install)    DO_INSTALL=1 ;;
    --no-install) DO_INSTALL=0 ;;
    --force)      FORCE=1 ;;
    --max-busy)   need_value "$@"; BUSY_LIMIT_PCT="$2"; shift ;;
    --max-busy=*) BUSY_LIMIT_PCT="${1#*=}" ;;
    --remote)     need_value "$@"; REMOTE="$2"; shift ;;
    --remote=*)   REMOTE="${1#*=}" ;;
    -q|--quiet)   QUIET=1 ;;
    --emit-result) EMIT_RESULT=1 ;;
    -h|--help)    usage; exit 0 ;;
    --help-scoring) HELP_SCORING=1 ;;
    --version)    echo "perfcheck.sh $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$TIME_PER_TEST" in
  ''|*[!0-9]*) echo "--time must be a whole number of seconds: $TIME_PER_TEST" >&2; exit 2 ;;
esac
if [ "$TIME_PER_TEST" -lt 3 ]; then
  echo "--time must be at least 3 seconds (shorter runs measure startup)" >&2
  exit 2
fi
case "$BUSY_LIMIT_PCT" in
  ''|*[!0-9]*) echo "--max-busy must be a whole percentage: $BUSY_LIMIT_PCT" >&2; exit 2 ;;
esac
if [ "$BUSY_LIMIT_PCT" -gt 100 ]; then
  echo "--max-busy must be between 0 and 100: $BUSY_LIMIT_PCT" >&2; exit 2
fi
if [ -n "$IO_DIR" ]; then
  if [ ! -d "$IO_DIR" ] || [ ! -w "$IO_DIR" ]; then
    echo "--io-dir must be an existing writable directory: $IO_DIR" >&2; exit 2
  fi
fi
if [ -n "$REMOTE" ]; then
  # a literal newline in the pattern: $(printf '\n') would be stripped to the
  # empty string, turning the pattern into ** and rejecting everything
  PERFCHECK_NL='
'
  case "$REMOTE" in
    -*|*' '*|*"$PERFCHECK_NL"*)
      echo "--remote takes a comma separated list of ssh targets" >&2; exit 2 ;;
  esac
fi

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET='\033[0m'; C_HEAD='\033[1;36m'; C_OK='\033[1;32m'
  C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_DIM='\033[2m'; C_KEY='\033[1m'
else
  C_RESET=''; C_HEAD=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_KEY=''
fi

say()   { [ "$QUIET" -eq 1 ] || printf "%b\n" "$*"; }
head2() { [ "$QUIET" -eq 1 ] || printf "\n${C_HEAD}%s${C_RESET}\n" "$*"; }
kv()    { [ "$QUIET" -eq 1 ] || printf "  %-22s %s\n" "$1" "$2"; }
has()   { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# every sysbench invocation goes through here: a test that fails must not be
# allowed to look like a result of zero
# ---------------------------------------------------------------------------
# Several of these helpers are called inside $( ), which is a subshell, so a
# plain variable would not survive. The failed tests are recorded in a file.
TEST_ERR_FILE="$(mktemp 2>/dev/null || echo "/tmp/perfcheck.errs.$$")"
: > "$TEST_ERR_FILE"

note_error()      { echo "$1" >> "$TEST_ERR_FILE"; }
has_test_errors() { [ -s "$TEST_ERR_FILE" ]; }
test_errors()     { sort -u "$TEST_ERR_FILE" 2>/dev/null | tr '\n' ' '; }

run_sysbench() {  # run_sysbench <label> <command...>   -> prints stdout, non-zero on failure
  local label="$1"; shift
  local err out rc
  err="$(mktemp 2>/dev/null || echo "/tmp/perfcheck.err.$$")"
  out="$("$@" 2>"$err")"
  rc=$?
  if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -q '^FATAL'; then
    note_error "$label"
    printf "  ${C_ERR}%s failed${C_RESET} (exit %s)\n" "$label" "$rc" >&2
    { printf '%s\n' "$out" | grep -E '^(FATAL|ERROR)' | head -3
      head -3 "$err" 2>/dev/null; } | sed 's/^/    /' >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s' "$out"
  return 0
}

# a measurement that could not be parsed is an error, never a zero
metric_or_error() {  # metric_or_error <label> <value>
  if [ -z "$2" ]; then
    note_error "$1"
    echo "ERROR"
  else
    echo "$2"
  fi
}

is_num() { case "$1" in ''|*[!0-9.]*) return 1 ;; *) return 0 ;; esac; }

# all floating point work goes through awk - bc is not always installed
fmul()  { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a*b}'; }
fdiv()  { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0==0) print "0"; else printf "%.2f", a/b}'; }
fpct()  { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0==0) print "0"; else printf "%.1f", 100*a/b}'; }

# ---------------------------------------------------------------------------
# reference profile
#
# Fixed, arbitrary numbers: they only set where 100 sits. A machine twice as fast
# as the reference on a test scores 200 on it. Change them and every score moves,
# so leave them alone if you want scores to stay comparable between runs.
# ---------------------------------------------------------------------------
# Reference profile v2, rounded from two Mac mini (Apple silicon) hosts running
# Debian 13 aarch64 in Parallels with 8 vCPU each, sysbench 1.0.20. The pair
# agreed within 0.5% on CPU, 1% on threads and 2% on mutex and memory, which is
# what makes them usable as a fixed point.
#
# Any of these can be overridden from the environment, which is how you move the
# scale onto a machine of your own:
#   PERFCHECK_REF_CPU_MULTI=45000 ./perfcheck.sh
REF_PROFILE="v3 (Mac mini, 8 vCPU Parallels VM, Debian 13 aarch64)"
REF_CPU_MULTI="${PERFCHECK_REF_CPU_MULTI:-24000}"      # events/s, all threads
REF_CPU_SINGLE="${PERFCHECK_REF_CPU_SINGLE:-5500}"     # events/s, one thread
REF_THREADS="${PERFCHECK_REF_THREADS:-11500}"          # events/s, scheduler test
REF_MUTEX_TOTAL="${PERFCHECK_REF_MUTEX_TOTAL:-4600000}" # mutex locks/s, all threads
REF_MUTEX="${PERFCHECK_REF_MUTEX:-575000}"             # mutex locks/s per thread
# Confirmed at the 60s default on the same machine: 178435 MiB/s against the
# 175000 taken from the 10s runs, 2% apart.
REF_MEMORY="${PERFCHECK_REF_MEMORY:-175000}"           # MiB/s, 1M blocks
# Not measured on the reference machine; the I/O test was not run there.
REF_IO_IOPS="${PERFCHECK_REF_IO_IOPS:-3000}"           # random read+write ops/s

W_CPU_MULTI=30
W_CPU_SINGLE=25
W_MEMORY=20
W_THREADS=15
W_MUTEX_TOTAL=5
W_MUTEX=5

if [ "$HELP_SCORING" -eq 1 ]; then
  cat <<SCORING
perfcheck relative score, reference profile ${REF_PROFILE}

Each result is divided by the reference value below, so 100 means the same as the
reference. The composite is the weighted geometric mean of the five, and file I/O
is never part of it.

  test                reference            weight   environment override
  cpu, all threads    ${REF_CPU_MULTI} events/s          ${W_CPU_MULTI}%      PERFCHECK_REF_CPU_MULTI
  cpu, single thread  ${REF_CPU_SINGLE} events/s           ${W_CPU_SINGLE}%      PERFCHECK_REF_CPU_SINGLE
  memory              ${REF_MEMORY} MiB/s             ${W_MEMORY}%      PERFCHECK_REF_MEMORY
  threads             ${REF_THREADS} events/s          ${W_THREADS}%      PERFCHECK_REF_THREADS
  mutex, all threads  ${REF_MUTEX_TOTAL} locks/s         ${W_MUTEX_TOTAL}%       PERFCHECK_REF_MUTEX_TOTAL
  mutex, per thread   ${REF_MUTEX} locks/s          ${W_MUTEX}%       PERFCHECK_REF_MUTEX
  file I/O            ${REF_IO_IOPS} IOPS               -       PERFCHECK_REF_IO_IOPS

The figures come from two Mac minis that agreed within 2% of each other, and a
later run at the 60 second default scored 101.0 against them. The file I/O
figure was not measured on that machine at all.

The reference numbers are arbitrary and only decide where 100 sits. A score is a
comparison with that profile and with other hosts measured the same way; it is
not a measure of anything on its own.
SCORING
  exit 0
fi

# ---------------------------------------------------------------------------
# machine facts
# ---------------------------------------------------------------------------
CPU_MODEL="unknown"; CPU_LOGICAL=1; CPU_PHYSICAL=1; CPU_SOCKETS=1
CPU_QUOTA=""          # cgroup cpu limit, in whole cores, when one is set
CPU_THREADS=1         # threads the tests actually use
MEM_TOTAL_MB=0; MEM_AVAIL_MB=0; VIRT="none"; GOVERNOR=""; DISK_TYPE=""; HYPERVISOR=""
OS_NAME="unknown"; PKG=""; SUDO=""
HOST_NAME=""; HOST_IP=""

OS_KIND="linux"

# the address the machine actually reaches the network with, not whatever
# /etc/hosts says about the name
primary_ip() {
  local ip iface
  if has ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
  fi
  if [ -z "$ip" ] && has hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "$ip" ] && has route && has ipconfig; then          # macOS
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
    [ -n "$iface" ] && ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
  fi
  if [ -z "$ip" ] && has ifconfig; then
    ip="$(ifconfig 2>/dev/null | awk '/inet /{if ($2 != "127.0.0.1") {print $2; exit}}')"
  fi
  echo "$ip"
}

collect_identity() {
  HOST_NAME="$(hostname -f 2>/dev/null)"
  [ -n "$HOST_NAME" ] || HOST_NAME="$(hostname 2>/dev/null)"
  [ -n "$HOST_NAME" ] || HOST_NAME="host"
  HOST_IP="$(primary_ip)"
}

detect_machine_macos() {
  OS_KIND="macos"
  OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null)"
  has brew && PKG="brew"
  CPU_LOGICAL="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)"
  CPU_PHYSICAL="$(sysctl -n hw.physicalcpu 2>/dev/null || echo "$CPU_LOGICAL")"
  CPU_SOCKETS=1
  CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  [ -n "$CPU_MODEL" ] || CPU_MODEL="$(sysctl -n hw.model 2>/dev/null)"
  [ -n "$CPU_MODEL" ] || CPU_MODEL="$(uname -m) (model not reported)"
  MEM_TOTAL_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
  # free + inactive pages is the closest thing to MemAvailable here
  if has vm_stat; then
    local psize free inactive
    psize="$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)"
    free="$(vm_stat 2>/dev/null | awk '/Pages free/{gsub(/\./,"",$3); print $3}')"
    inactive="$(vm_stat 2>/dev/null | awk '/Pages inactive/{gsub(/\./,"",$3); print $3}')"
    MEM_AVAIL_MB=$(( ( (${free:-0} + ${inactive:-0}) * psize ) / 1048576 ))
  fi
  if [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = "1" ]; then
    VIRT="hypervisor"
  else
    VIRT="none"
  fi
  CPU_THREADS="$CPU_LOGICAL"
  # macOS has no O_DIRECT; sysbench cannot bypass the cache here
  IO_NO_DIRECT=1
}

load_1min() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1}' /proc/loadavg 2>/dev/null
  else
    sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'
  fi
}

detect_machine() {
  case "$(uname -s)" in
    Linux) : ;;
    Darwin) detect_machine_macos; return 0 ;;
    *) echo "perfcheck.sh runs on Linux and macOS; this host is $(uname -s)" >&2; exit 2 ;;
  esac

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    OS_NAME="$(. /etc/os-release; echo "${PRETTY_NAME:-$ID}")"
    # shellcheck disable=SC1091
    case " $(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}") " in
      *debian*|*ubuntu*) PKG="apt" ;;
      *rhel*|*fedora*|*centos*|*almalinux*|*rocky*) if has dnf; then PKG="dnf"; elif has yum; then PKG="yum"; fi ;;
    esac
  fi
  if [ "$(id -u)" -ne 0 ] && has sudo; then
    SUDO="sudo"
  fi

  CPU_LOGICAL="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  if has lscpu; then
    CPU_MODEL="$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -1)"
    CPU_SOCKETS="$(lscpu 2>/dev/null | sed -n 's/^Socket(s): *//p' | head -1)"
    # lscpu prints a bare dash for fields it cannot determine, which happens for
    # the model name and socket count under emulation and in some guests
    HYPERVISOR="$(lscpu 2>/dev/null | sed -n 's/^Hypervisor vendor: *//p' | head -1)"
    [ "$CPU_MODEL" = "-" ] && CPU_MODEL=""
    [ "$CPU_SOCKETS" = "-" ] && CPU_SOCKETS=""
    [ "$HYPERVISOR" = "-" ] && HYPERVISOR=""
    local cps tps
    cps="$(lscpu 2>/dev/null | sed -n 's/^Core(s) per socket: *//p' | head -1)"
    tps="$(lscpu 2>/dev/null | sed -n 's/^Thread(s) per core: *//p' | head -1)"
    if [ -n "$cps" ] && [ -n "$CPU_SOCKETS" ]; then
      CPU_PHYSICAL=$((cps * CPU_SOCKETS))
    fi
    [ -n "$tps" ] || tps=1
  fi
  [ -n "$CPU_MODEL" ] || CPU_MODEL="$(sed -n 's/^model name[[:space:]]*: *//p' /proc/cpuinfo 2>/dev/null | head -1)"
  [ -n "$CPU_MODEL" ] || CPU_MODEL="$(sed -n 's/^Model[[:space:]]*: *//p' /proc/cpuinfo 2>/dev/null | head -1)"
  [ -n "$CPU_MODEL" ] || CPU_MODEL="$(uname -m) (model not reported)"
  [ -n "$CPU_SOCKETS" ] || CPU_SOCKETS=1
  [ "$CPU_PHYSICAL" -ge 1 ] 2>/dev/null || CPU_PHYSICAL="$CPU_LOGICAL"

  if [ -r /proc/meminfo ]; then
    MEM_TOTAL_MB=$(( $(sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 ))
    MEM_AVAIL_MB=$(( $(sed -n 's/^MemAvailable: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 ))
  fi

  if has systemd-detect-virt; then
    VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
  fi
  if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  fi

  # A container or a systemd slice can cap CPU below the visible core count.
  # nproc does not see that cap, so a benchmark sized from nproc would measure
  # throttling rather than the machine.
  # Under systemd the process sits in a slice, so the limit is not at the root of
  # the mount. Resolve this process's own path first and walk up from there.
  local cg_path cg_file=""
  cg_path="$(sed -n 's/^0::\(.*\)/\1/p' /proc/self/cgroup 2>/dev/null | head -1)"
  while [ -n "$cg_path" ]; do
    if [ -r "/sys/fs/cgroup${cg_path}/cpu.max" ]; then
      cg_file="/sys/fs/cgroup${cg_path}/cpu.max"
      break
    fi
    [ "$cg_path" = "/" ] && break
    cg_path="$(dirname "$cg_path")"
  done
  [ -n "$cg_file" ] || cg_file=/sys/fs/cgroup/cpu.max

  if [ -r "$cg_file" ]; then                                   # cgroup v2
    local q p
    q="$(awk '{print $1}' "$cg_file" 2>/dev/null)"
    p="$(awk '{print $2}' "$cg_file" 2>/dev/null)"
    if [ "$q" != "max" ] && [ -n "$q" ] && [ -n "$p" ]; then
      CPU_QUOTA="$(awk -v q="$q" -v p="$p" 'BEGIN{printf "%.2f", q/p}')"
    fi
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then        # cgroup v1
    local q p
    q="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)"
    p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)"
    if [ "${q:--1}" -gt 0 ] 2>/dev/null && [ "${p:-0}" -gt 0 ] 2>/dev/null; then
      CPU_QUOTA="$(awk -v q="$q" -v p="$p" 'BEGIN{printf "%.2f", q/p}')"
    fi
  fi

  # size the tests by the quota when there is one, rounded up to a whole thread
  CPU_THREADS="$CPU_LOGICAL"
  if [ -n "$CPU_QUOTA" ]; then
    CPU_THREADS="$(awk -v q="$CPU_QUOTA" 'BEGIN{n=int(q); if (q > n) n++; if (n < 1) n=1; print n}')"
    [ "$CPU_THREADS" -gt "$CPU_LOGICAL" ] && CPU_THREADS="$CPU_LOGICAL"
  fi

  # rotational flag of the device backing the I/O directory
  local dir dev rot
  dir="${IO_DIR:-$PWD}"
  if has df && has lsblk; then
    dev="$(df -P "$dir" 2>/dev/null | awk 'NR==2{print $1}')"
    rot="$(lsblk -no ROTA "$dev" 2>/dev/null | head -1 | tr -d ' ')"
    case "$rot" in
      0) DISK_TYPE="non-rotational" ;;
      1) DISK_TYPE="rotational" ;;
    esac
  fi
}

ensure_sysbench() {
  if has sysbench; then
    return 0
  fi
  if [ "$DO_INSTALL" -eq 0 ]; then
    printf "${C_ERR}sysbench is not installed.${C_RESET}\n" >&2
    case "$PKG" in
      apt)     printf "  sudo apt-get install sysbench\n" >&2 ;;
      dnf|yum) printf "  sudo %s install epel-release && sudo %s install sysbench\n" "$PKG" "$PKG" >&2 ;;
      brew)    printf "  brew install sysbench\n" >&2 ;;
    esac
    printf "or pass --install to let this script do it, then run it again.\n" >&2
    exit 2
  fi
  head2 "Installing sysbench"
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive $SUDO apt-get update -qq >/dev/null 2>&1
         DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq sysbench >/dev/null 2>&1 ;;
    brew) brew install sysbench >/dev/null 2>&1 ;;
    dnf|yum)
         # sysbench lives in EPEL on the RHEL family
         if ! $SUDO "$PKG" repolist enabled 2>/dev/null | grep -qi '^epel'; then
           $SUDO "$PKG" install -y epel-release >/dev/null 2>&1
         fi
         $SUDO "$PKG" install -y sysbench >/dev/null 2>&1 ;;
    *)   echo "no supported package manager found; install sysbench first" >&2; exit 2 ;;
  esac
  if ! has sysbench; then
    echo "could not install sysbench" >&2
    exit 2
  fi
  say "  installed $(sysbench --version 2>/dev/null)"
  say "  ${C_WARN}the install just loaded this machine; run again for numbers you intend to keep${C_RESET}"
}

# Busy percentage, sampled over a second. The load average is not usable for this:
# on macOS it counts threads waiting on I/O and Mach ports as well as runnable
# ones, so an idle Mac reports a load of 8 while the CPU is 85% idle.
cpu_busy_pct() {
  # In a container /proc/stat still reports the host's CPUs, so a cgroup with a
  # quota has to be measured against its own usage counter instead.
  if [ -n "$CPU_QUOTA" ] && [ -r /sys/fs/cgroup/cpu.stat ]; then
    local a b
    a="$(awk '/^usage_usec/{print $2}' /sys/fs/cgroup/cpu.stat)"
    sleep 1
    b="$(awk '/^usage_usec/{print $2}' /sys/fs/cgroup/cpu.stat)"
    # against the quota itself: rounding 0.5 cores up to one thread would halve
    # the reported utilisation of a cgroup that is already saturated
    awk -v a="${a:-0}" -v b="${b:-0}" -v c="$CPU_QUOTA" 'BEGIN{
      d = b - a;
      if (c+0 <= 0 || d < 0) print "0"; else printf "%.1f", 100 * d / (1000000 * c) }'
    return 0
  fi
  if [ -n "$CPU_QUOTA" ] && [ -r /sys/fs/cgroup/cpuacct/cpuacct.usage ]; then
    local a b
    a="$(cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null)"
    sleep 1
    b="$(cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null)"
    awk -v a="${a:-0}" -v b="${b:-0}" -v c="$CPU_QUOTA" 'BEGIN{
      d = b - a;
      if (c+0 <= 0 || d < 0) print "0"; else printf "%.1f", 100 * d / (1000000000 * c) }'
    return 0
  fi
  if [ -r /proc/stat ]; then
    local a b
    a="$(awk '/^cpu /{i=$5+$6; t=0; for(n=2;n<=NF;n++) t+=$n; print i, t; exit}' /proc/stat)"
    sleep 1
    b="$(awk '/^cpu /{i=$5+$6; t=0; for(n=2;n<=NF;n++) t+=$n; print i, t; exit}' /proc/stat)"
    awk -v a="$a" -v b="$b" 'BEGIN{
      split(a,x," "); split(b,y," ");
      di = y[1]-x[1]; dt = y[2]-x[2];
      if (dt <= 0) print "0"; else printf "%.1f", 100*(1 - di/dt) }'
  elif has top; then
    local idle
    idle="$(top -l 2 -n 0 -s 1 2>/dev/null | sed -n 's/.*, *\([0-9.]*\)% idle.*/\1/p' | tail -1)"
    [ -n "$idle" ] && awk -v i="$idle" 'BEGIN{printf "%.1f", 100-i}' || echo ""
  fi
}

busy_processes() {
  if ps -eo pcpu,comm --sort=-pcpu >/dev/null 2>&1; then
    ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | sed -n '2,4p'
  else
    ps -Ao pcpu,comm -r 2>/dev/null | sed -n '2,4p'
  fi
}

check_idle() {
  local load busy
  load="$(load_1min)"
  busy="$(cpu_busy_pct)"
  [ -n "$load" ] && kv "load average (1m)" "$load  ${C_DIM}(informational)${C_RESET}"
  if [ -z "$busy" ]; then
    kv "cpu busy" "could not sample"
    return 0
  fi
  kv "cpu busy" "${busy}%  (limit ${BUSY_LIMIT_PCT}%)"
  if [ "$FORCE" -eq 1 ]; then
    return 0
  fi
  if awk -v p="$busy" -v l="$BUSY_LIMIT_PCT" 'BEGIN{exit !(p+0 > l+0)}'; then
    printf "\n${C_ERR}refusing to benchmark${C_RESET}: the CPU is %s%% busy, above the %s%% limit.\n" \
      "$busy" "$BUSY_LIMIT_PCT" >&2
    printf "the numbers would measure that workload as much as the machine.\n" >&2
    printf "busiest processes right now:\n" >&2
    busy_processes | sed 's/^/  /' >&2
    printf "raise the limit with --max-busy, or skip the check with --force.\n" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# the tests - every parameter is derived from the machine
# ---------------------------------------------------------------------------
R_CPU_MULTI=0; R_CPU_SINGLE=0; R_THREADS=0; R_MUTEX=0
R_MEM_WRITE=0; R_MEM_READ=0; R_MEM_RND=0; R_MEMORY=0; R_MUTEX_TOTAL=0
R_IO_SEQ_READ=0; R_IO_SEQ_WRITE=0
R_IO_IOPS=0; R_IO_READ=0; R_IO_WRITE=0; R_IO_P95=0

sb_field() {  # sb_field <output> <sed pattern>
  echo "$1" | sed -n "$2" | head -1 | tr -d ' '
}

run_cpu() {
  local out
  head2 "CPU"
  if out="$(run_sysbench cpu-multi sysbench cpu --threads="$CPU_THREADS" \
              --time="$TIME_PER_TEST" --cpu-max-prime=20000 run)"; then
    R_CPU_MULTI="$(metric_or_error cpu-multi "$(sb_field "$out" 's/^ *events per second: *//p')")"
  else
    R_CPU_MULTI="ERROR"
  fi
  kv "all cores ($CPU_THREADS threads)" "$R_CPU_MULTI events/s"

  if out="$(run_sysbench cpu-single sysbench cpu --threads=1 \
              --time="$TIME_PER_TEST" --cpu-max-prime=20000 run)"; then
    R_CPU_SINGLE="$(metric_or_error cpu-single "$(sb_field "$out" 's/^ *events per second: *//p')")"
  else
    R_CPU_SINGLE="ERROR"
  fi
  kv "single thread" "$R_CPU_SINGLE events/s"
}

mem_run() {  # mem_run <label> <oper> <access mode> <block size>
  local total_mb out
  total_mb=$(( MEM_TOTAL_MB * 100 ))
  [ "$total_mb" -gt 0 ] || total_mb=100000
  if ! out="$(run_sysbench "$1" sysbench memory --threads="$CPU_THREADS" --time="$TIME_PER_TEST" \
               --memory-block-size="$4" --memory-total-size="${total_mb}M" \
               --memory-oper="$2" --memory-access-mode="$3" run)"; then
    echo "ERROR"
    return 1
  fi
  metric_or_error "$1" "$(echo "$out" | sed -n 's/.*(\([0-9.]*\) MiB\/sec).*/\1/p' | head -1)"
}

run_memory() {
  head2 "Memory"
  R_MEM_WRITE="$(mem_run mem-write write seq 1M)"
  kv "sequential write" "$R_MEM_WRITE MiB/s   (1M blocks)"
  R_MEM_READ="$(mem_run mem-read read seq 1M)"
  kv "sequential read" "$R_MEM_READ MiB/s   (1M blocks)"
  # small blocks in random order: this one is about access latency, not bandwidth
  R_MEM_RND="$(mem_run mem-random write rnd 4K)"
  kv "random write" "$R_MEM_RND MiB/s   (4K blocks, random order)"

  # the memory subscore uses read and write together; the random figure is
  # reported because it says something different, not because it averages well
  if is_num "$R_MEM_WRITE" && is_num "$R_MEM_READ"; then
    R_MEMORY="$(awk -v a="$R_MEM_WRITE" -v b="$R_MEM_READ" 'BEGIN{printf "%.2f", sqrt(a*b)}')"
    kv "used for scoring" "$R_MEMORY MiB/s   (geometric mean of read and write)"
  else
    R_MEMORY="ERROR"
  fi
}

run_threads() {
  local out events
  head2 "Threads"
  # oversubscribe on purpose: this measures the scheduler under contention
  if ! out="$(run_sysbench threads sysbench threads --threads=$((CPU_THREADS * 4)) \
               --time="$TIME_PER_TEST" --thread-yields=1000 --thread-locks=8 run)"; then
    R_THREADS="ERROR"; kv "$((CPU_THREADS * 4)) threads" "ERROR"; return 0
  fi
  events="$(sb_field "$out" 's/^ *total number of events: *//p')"
  # the threads test reports no events/s line, so derive it
  if is_num "$events"; then
    R_THREADS="$(fdiv "$events" "$TIME_PER_TEST")"
  else
    R_THREADS="$(metric_or_error threads "")"
  fi
  kv "$((CPU_THREADS * 4)) threads" "$R_THREADS events/s"
}

run_mutex() {
  local out locks secs
  head2 "Mutex"
  # Each thread takes --mutex-locks locks, so the work scales with the thread
  # count. Reporting the elapsed time would therefore not compare across machines
  # with different core counts; throughput does.
  locks=50000
  if ! out="$(run_sysbench mutex sysbench mutex --threads="$CPU_THREADS" --mutex-num=4096 \
               --mutex-locks="$locks" --mutex-loops=5000 run)"; then
    R_MUTEX="ERROR"; R_MUTEX_TOTAL="ERROR"; kv "all threads ($CPU_THREADS)" "ERROR"; return 0
  fi
  secs="$(echo "$out" | sed -n 's/^ *total time: *\([0-9.]*\)s.*/\1/p' | head -1)"
  if is_num "$secs" && awk -v s="$secs" 'BEGIN{exit !(s+0 > 0)}'; then
    # per thread, not in total. sysbench takes --mutex-locks from every thread, so
    # the total rate grows with the thread count and would reward a machine for
    # having many slow cores - which cpu-all already measures on purpose.
    R_MUTEX="$(awk -v l="$locks" -v s="$secs" 'BEGIN{printf "%.0f", l/s}')"
    R_MUTEX_TOTAL="$(awk -v t="$CPU_THREADS" -v l="$locks" -v s="$secs" 'BEGIN{printf "%.0f", (t*l)/s}')"
    kv "all threads ($CPU_THREADS)" "$R_MUTEX_TOTAL locks/s   (${secs}s for $((CPU_THREADS * locks)) locks)"
    kv "per thread" "$R_MUTEX locks/s"
  else
    R_MUTEX="$(metric_or_error mutex "")"
    R_MUTEX_TOTAL="ERROR"
    kv "all threads ($CPU_THREADS)" "ERROR"
  fi
}

IO_WORK_DIR=""
io_cleanup() {
  # only ever removes the directory this run created, never a caller's path
  case "$IO_WORK_DIR" in
    */.perfcheck.*)
      if [ -d "$IO_WORK_DIR" ]; then
        ( cd "$IO_WORK_DIR" && sysbench fileio --file-total-size="${IO_SIZE_MB}M" cleanup >/dev/null 2>&1 )
        rm -rf -- "$IO_WORK_DIR"
      fi
      IO_WORK_DIR="" ;;
  esac
}
cleanup_all() {
  io_cleanup
  rm -f "$TEST_ERR_FILE"
}
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

IO_SIZE_MB=0
IO_CACHED=0
IO_NO_DIRECT=""     # set on platforms where O_DIRECT does not exist at all
run_io() {
  [ "$DO_IO" -eq 1 ] || return 0
  local dir free_mb out
  dir="${IO_DIR:-$PWD}"
  head2 "File I/O"

  if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
    say "  ${C_WARN}skipped${C_RESET}: $dir is not a writable directory"
    note_error fileio
    return 0
  fi
  free_mb="$(df -Pm "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
  [ -n "$free_mb" ] || free_mb=0
  # big enough to defeat the page cache, small enough to be polite: 2x RAM,
  # capped at a quarter of the free space and at 8 GiB
  IO_SIZE_MB=$(( MEM_TOTAL_MB * 2 ))
  [ "$IO_SIZE_MB" -gt $(( free_mb / 4 )) ] && IO_SIZE_MB=$(( free_mb / 4 ))
  [ "$IO_SIZE_MB" -gt 8192 ] && IO_SIZE_MB=8192
  if [ "$IO_SIZE_MB" -lt 256 ]; then
    say "  ${C_WARN}skipped${C_RESET}: only ${free_mb} MiB free in $dir"
    return 0
  fi
  # sysbench always writes test_file.0 .. test_file.N into the working directory.
  # A private directory keeps two runs from overwriting each other's files and
  # from touching files that were already there.
  IO_WORK_DIR="$(mktemp -d "$dir/.perfcheck.XXXXXX" 2>/dev/null)"
  if [ -z "$IO_WORK_DIR" ] || [ ! -d "$IO_WORK_DIR" ]; then
    say "  ${C_WARN}skipped${C_RESET}: could not create a work directory in $dir"
    note_error fileio
    return 0
  fi
  dir="$IO_WORK_DIR"
  kv "test file" "${IO_SIZE_MB} MiB in $IO_WORK_DIR (${DISK_TYPE:-unknown media})"

  if ! ( cd "$dir" && sysbench fileio --file-total-size="${IO_SIZE_MB}M" prepare >/dev/null 2>&1 ); then
    say "  ${C_WARN}prepare failed${C_RESET}"
    note_error fileio
    io_cleanup
    return 0
  fi

  # Without O_DIRECT the page cache answers most of the requests and the result
  # describes the cache, not the disk. Not every filesystem or platform supports
  # it - tmpfs, some overlay and network mounts, and macOS - and support can
  # differ per access pattern, so every mode falls back on its own.
  io_mode() {  # io_mode <file-test-mode> <field sed pattern>
    local out
    if [ -z "$IO_NO_DIRECT" ]; then
      out="$( cd "$dir" && sysbench fileio --file-total-size="${IO_SIZE_MB}M" --file-test-mode="$1" \
              --time="$TIME_PER_TEST" --max-requests=0 --file-fsync-freq=0 \
              --file-extra-flags=direct run 2>/dev/null )"
      if [ -n "$(sb_field "$out" "$2")" ]; then
        echo "$out"
        return 0
      fi
      IO_CACHED=1
    fi
    ( cd "$dir" && sysbench fileio --file-total-size="${IO_SIZE_MB}M" --file-test-mode="$1" \
        --time="$TIME_PER_TEST" --max-requests=0 --file-fsync-freq=0 run 2>/dev/null )
  }

  # Order matters. seqwr leaves the files shorter than prepare made them, and any
  # test run afterwards aborts with
  #   FATAL: Size of file 'test_file.12' is 57.5MiB, but at least 64MiB is expected
  # so the sequential write goes last, after everything that reads the file set.
  out="$(io_mode seqrd 's/^ *read, MiB\/s: *//p')"
  R_IO_SEQ_READ="$(sb_field "$out" 's/^ *read, MiB\/s: *//p')"
  kv "sequential read" "${R_IO_SEQ_READ:-0} MiB/s"

  # random read/write, non-durable: --file-fsync-freq=0 means nothing is flushed,
  # so this is raw device throughput and not what a durable commit would cost
  out="$(io_mode rndrw 's/^ *reads\/s: *//p')"
  R_IO_READ="$(sb_field "$out" 's/^ *read, MiB\/s: *//p')"
  R_IO_WRITE="$(sb_field "$out" 's/^ *written, MiB\/s: *//p')"
  local r w
  r="$(sb_field "$out" 's/^ *reads\/s: *//p')"
  w="$(sb_field "$out" 's/^ *writes\/s: *//p')"
  R_IO_IOPS="$(awk -v a="${r:-0}" -v b="${w:-0}" 'BEGIN{printf "%.1f", a+b}')"
  R_IO_P95="$(sb_field "$out" 's/^ *95th percentile: *//p')"
  kv "random read/write" "${R_IO_IOPS} IOPS   ${R_IO_READ:-0} + ${R_IO_WRITE:-0} MiB/s   (non-durable)"
  kv "95th pct latency" "${R_IO_P95:-?} ms"

  # last, because it shortens the files
  out="$(io_mode seqwr 's/^ *written, MiB\/s: *//p')"
  R_IO_SEQ_WRITE="$(sb_field "$out" 's/^ *written, MiB\/s: *//p')"
  kv "sequential write" "${R_IO_SEQ_WRITE:-0} MiB/s"

  io_cleanup
}

# ---------------------------------------------------------------------------
# scoring
# ---------------------------------------------------------------------------
S_CPU_MULTI=0; S_CPU_SINGLE=0; S_MEMORY=0; S_THREADS=0; S_MUTEX=0; S_MUTEX_TOTAL=0; S_IO=0; COMPOSITE=0

score_one() {  # score_one <measured> <reference>
  if is_num "$1"; then
    fpct "$1" "$2"
  else
    echo "ERROR"
  fi
}

score_all() {
  S_CPU_MULTI="$(score_one "$R_CPU_MULTI" "$REF_CPU_MULTI")"
  S_CPU_SINGLE="$(score_one "$R_CPU_SINGLE" "$REF_CPU_SINGLE")"
  S_MEMORY="$(score_one "$R_MEMORY" "$REF_MEMORY")"
  S_THREADS="$(score_one "$R_THREADS" "$REF_THREADS")"
  S_MUTEX_TOTAL="$(score_one "$R_MUTEX_TOTAL" "$REF_MUTEX_TOTAL")"
  S_MUTEX="$(score_one "$R_MUTEX" "$REF_MUTEX")"
  if [ "$DO_IO" -eq 1 ]; then
    if [ "$IO_CACHED" -eq 1 ]; then
      # a run the page cache answered is not on the same scale as a direct one
      S_IO="cached"
    else
      S_IO="$(score_one "$R_IO_IOPS" "$REF_IO_IOPS")"
    fi
  fi

  # Every one of the five is required. Dropping a failed test from the weights
  # would renormalise the rest and could raise the composite, which is exactly
  # the wrong direction.
  if ! is_num "$S_CPU_MULTI" || ! is_num "$S_CPU_SINGLE" || ! is_num "$S_MEMORY" \
     || ! is_num "$S_THREADS" || ! is_num "$S_MUTEX" || ! is_num "$S_MUTEX_TOTAL"; then
    COMPOSITE="N/A"
    return 0
  fi

  # weighted geometric mean - a ratio scale calls for it, and one very high
  # subscore cannot drag the composite up the way an arithmetic mean lets it
  COMPOSITE="$(awk -v a="$S_CPU_MULTI"   -v wa="$W_CPU_MULTI" \
                   -v b="$S_CPU_SINGLE"  -v wb="$W_CPU_SINGLE" \
                   -v c="$S_MEMORY"      -v wc="$W_MEMORY" \
                   -v d="$S_THREADS"     -v wd="$W_THREADS" \
                   -v e="$S_MUTEX_TOTAL" -v we="$W_MUTEX_TOTAL" \
                   -v f="$S_MUTEX"       -v wf="$W_MUTEX" '
    BEGIN {
      n = 0; s = 0;
      if (a+0 > 0) { s += wa * log(a); n += wa }
      if (b+0 > 0) { s += wb * log(b); n += wb }
      if (c+0 > 0) { s += wc * log(c); n += wc }
      if (d+0 > 0) { s += wd * log(d); n += wd }
      if (e+0 > 0) { s += we * log(e); n += we }
      if (f+0 > 0) { s += wf * log(f); n += wf }
      if (n == 0) { print "0" } else { printf "%.1f", exp(s / n) }
    }')"
}

report_scores() {
  head2 "Scores (perfcheck relative score, reference profile $REF_PROFILE)"
  [ "$QUIET" -eq 1 ] && return 0
  printf "  ${C_KEY}%-24s %12s %12s %6s${C_RESET}\n" "TEST" "MEASURED" "REFERENCE" "SCORE"
  printf "  %-24s %12s %12s %6s\n" "cpu, all cores"   "${R_CPU_MULTI:-0}"  "$REF_CPU_MULTI"  "$S_CPU_MULTI"
  printf "  %-24s %12s %12s %6s\n" "cpu, single thread" "${R_CPU_SINGLE:-0}" "$REF_CPU_SINGLE" "$S_CPU_SINGLE"
  printf "  %-24s %12s %12s %6s\n" "memory MiB/s"     "${R_MEMORY:-0}"     "$REF_MEMORY"     "$S_MEMORY"
  printf "  ${C_DIM}%-24s %12s %12s %6s${C_RESET}\n" "  seq write / read" "${R_MEM_WRITE:-0} / ${R_MEM_READ:-0}" "-" "-"
  printf "  ${C_DIM}%-24s %12s %12s %6s${C_RESET}\n" "  random 4K write" "${R_MEM_RND:-0}" "-" "-"
  printf "  %-24s %12s %12s %6s\n" "threads events/s" "${R_THREADS:-0}"    "$REF_THREADS"    "$S_THREADS"
  printf "  %-24s %12s %12s %6s\n" "mutex, all threads" "${R_MUTEX_TOTAL:-0}" "$REF_MUTEX_TOTAL" "$S_MUTEX_TOTAL"
  printf "  %-24s %12s %12s %6s\n" "mutex, per thread"  "${R_MUTEX:-0}"       "$REF_MUTEX"       "$S_MUTEX"
  if [ "$DO_IO" -eq 1 ]; then
    printf "  %-24s %12s %12s %6s\n" "file I/O IOPS"  "${R_IO_IOPS:-0}"    "$REF_IO_IOPS"    "$S_IO"
    printf "  ${C_DIM}%-24s %12s %12s %6s${C_RESET}\n" "  seq read / write MiB/s" "${R_IO_SEQ_READ:-0} / ${R_IO_SEQ_WRITE:-0}" "-" "-"
    printf "  ${C_DIM}%-24s %12s %12s %6s${C_RESET}\n" "  95th pct latency ms" "${R_IO_P95:-0}" "-" "-"
    say "  ${C_DIM}file I/O is reported but never enters the composite${C_RESET}"
    if [ "$IO_CACHED" -eq 1 ]; then
      say "  ${C_WARN}the I/O figures went through the page cache: O_DIRECT was not available${C_RESET}"
    fi
  fi

  if [ "$TIME_PER_TEST" -lt 30 ]; then
    say "  ${C_DIM}at ${TIME_PER_TEST}s per test the figures move between repeats, the memory test most of all${C_RESET}"
  fi

}

report_composite() {
  [ "$QUIET" -eq 1 ] || head2 "Composite"
  if [ "$COMPOSITE" = "N/A" ]; then
    printf "  ${C_ERR}N/A${C_RESET}   %s${C_DIM}%s${C_RESET}\n" "$HOST_NAME" "${HOST_IP:+  $HOST_IP}"
    printf "  ${C_ERR}not scored${C_RESET}: these tests failed: %s\n" "$(test_errors)"
  else
    printf "  ${C_OK}%s${C_RESET}   %s${C_DIM}%s${C_RESET}\n" \
      "$COMPOSITE" "$HOST_NAME" "${HOST_IP:+  $HOST_IP}"
  fi

  # Two lines, because on a guest they are two different machines: the processor
  # and core count come from the host, while the share of it this instance was
  # given comes from the hypervisor or the cgroup.
  local host_desc inst_label inst_desc mem_desc
  host_desc="$CPU_MODEL | $CPU_LOGICAL logical / $CPU_PHYSICAL physical / $CPU_SOCKETS socket(s) visible"
  [ -n "$HYPERVISOR" ] && host_desc="$host_desc | $HYPERVISOR hypervisor"

  mem_desc="${MEM_TOTAL_MB} MiB RAM"
  [ "${MEM_AVAIL_MB:-0}" -gt 0 ] 2>/dev/null && mem_desc="$mem_desc (${MEM_AVAIL_MB} MiB available)"

  if [ -n "$CPU_QUOTA" ]; then
    inst_label="container"
    inst_desc="$CPU_THREADS of $CPU_LOGICAL threads, cgroup quota $CPU_QUOTA cores | $mem_desc"
  else
    case "$VIRT" in
      ""|none)
        inst_label="bare metal"
        inst_desc="$CPU_THREADS threads used | $mem_desc" ;;
      *)
        inst_label="$VIRT"
        inst_desc="guest, $CPU_THREADS vCPU used | $mem_desc" ;;
    esac
  fi
  [ -n "$GOVERNOR" ] && inst_desc="$inst_desc | governor $GOVERNOR"

  printf "  ${C_DIM}host      ${C_RESET} %s\n" "$host_desc"
  printf "  ${C_DIM}%-10s${C_RESET} %s\n" "$inst_label" "$inst_desc"

  [ "$QUIET" -eq 1 ] && return 0
  printf "  ${C_DIM}weighted geometric mean: cpu-all %s%%, cpu-1 %s%%, memory %s%%, threads %s%%, mutex-all %s%%, mutex-1 %s%%${C_RESET}\n" \
    "$W_CPU_MULTI" "$W_CPU_SINGLE" "$W_MEMORY" "$W_THREADS" "$W_MUTEX_TOTAL" "$W_MUTEX"
}

# ---------------------------------------------------------------------------
# remote fan-out
# ---------------------------------------------------------------------------
REMOTE_FAIL_FLAG=""

run_remote() {
  local targets host out line rows="" self="$0"
  targets="$(echo "$REMOTE" | tr ',' ' ')"
  for host in $targets; do
    printf "\n${C_HEAD}>>> ssh %s${C_RESET}\n" "$host" >&2
    if [ ! -r "$self" ]; then
      printf "  cannot read this script (%s) to pipe it over ssh\n" "$self" >&2
      : > "$REMOTE_FAIL_FLAG"
      rows="$rows
PERFCHECK-RESULT|$host|-|?|?|ERROR"
      continue
    fi
    out="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" \
           "bash -s -- --time '$TIME_PER_TEST' --emit-result $( [ "$DO_IO" -eq 1 ] && echo --io ) $( [ "$FORCE" -eq 1 ] && echo --force )" \
           < "$self" 2>&1)"
    echo "$out" | grep -v '^PERFCHECK-RESULT|' >&2
    line="$(echo "$out" | grep '^PERFCHECK-RESULT|' | tail -1)"
    if [ -z "$line" ]; then
      : > "$REMOTE_FAIL_FLAG"
      line="PERFCHECK-RESULT|$host|-|?|?|UNREACHABLE"
    else
      case "$line" in
        *"|N/A|"*) : > "$REMOTE_FAIL_FLAG" ;;
      esac
      line="PERFCHECK-RESULT|$host|$(echo "$line" | cut -d'|' -f3-)"
    fi
    rows="$rows
$line"
  done
  echo "$rows" | grep '^PERFCHECK-RESULT|'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
# The tests run one after another on purpose - two of them at once would measure
# each other. This lock extends that to separate invocations on the same host.
PERFCHECK_LOCK="${TMPDIR:-/tmp}/perfcheck.lock"
if ( set -o noclobber; echo "$$" > "$PERFCHECK_LOCK" ) 2>/dev/null; then
  trap 'rm -f "$PERFCHECK_LOCK"; cleanup_all' EXIT
else
  other="$(cat "$PERFCHECK_LOCK" 2>/dev/null)"
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    printf "${C_ERR}another perfcheck is running on this host${C_RESET} (pid %s).\n" "$other" >&2
    printf "benchmarks measure each other when they overlap; wait for it to finish.\n" >&2
    exit 1
  fi
  # the holder is gone, so the lock is stale
  rm -f "$PERFCHECK_LOCK"
  echo "$$" > "$PERFCHECK_LOCK"
  trap 'rm -f "$PERFCHECK_LOCK"; cleanup_all' EXIT
fi

LOCAL_RC=0
detect_machine
collect_identity

printf "\n${C_HEAD}================ %s ================${C_RESET}\n" \
  "$HOST_NAME${HOST_IP:+ ($HOST_IP)} — $OS_NAME — $(uname -m)"

head2 "Machine"
kv "cpu" "$CPU_MODEL"
kv "cores" "$CPU_LOGICAL logical / $CPU_PHYSICAL physical / $CPU_SOCKETS socket(s)"
if [ -n "$CPU_QUOTA" ]; then
  kv "cgroup cpu quota" "$CPU_QUOTA cores — tests use $CPU_THREADS threads, not $CPU_LOGICAL"
fi
kv "memory" "${MEM_TOTAL_MB} MiB total, ${MEM_AVAIL_MB} MiB available"
[ -n "$VIRT" ] && kv "virtualisation" "$VIRT"
[ -n "$GOVERNOR" ] && kv "cpu governor" "$GOVERNOR"
[ -n "$DISK_TYPE" ] && kv "storage" "$DISK_TYPE"
kv "time per test" "${TIME_PER_TEST}s"

if ! check_idle; then
  LOCAL_RC=1
  COMPOSITE="BUSY"
else
  ensure_sysbench
  kv "sysbench" "$(sysbench --version 2>/dev/null)"
  run_cpu
  run_memory
  run_threads
  run_mutex
  run_io
  score_all
  report_scores
  report_composite
fi

LOCAL_ROW="PERFCHECK-RESULT|$HOST_NAME|${HOST_IP:--}|$CPU_THREADS|${MEM_TOTAL_MB}|$COMPOSITE|$S_CPU_MULTI|$S_CPU_SINGLE|$S_MEMORY|$S_THREADS|$S_MUTEX_TOTAL|$S_MUTEX|${S_IO:-0}"
[ "$EMIT_RESULT" -eq 1 ] && echo "$LOCAL_ROW"

ROWS="$LOCAL_ROW"
REMOTE_RC=0
if [ -n "$REMOTE" ]; then
  # run_remote runs in a command substitution, so it reports failure through a
  # file rather than a variable
  REMOTE_FAIL_FLAG="$(mktemp 2>/dev/null || echo "/tmp/perfcheck.remote.$$")"
  rm -f "$REMOTE_FAIL_FLAG"
  REMOTE_ROWS="$(run_remote)"
  [ -n "$REMOTE_ROWS" ] && ROWS="$ROWS
$REMOTE_ROWS"
  if [ -f "$REMOTE_FAIL_FLAG" ]; then
    REMOTE_RC=1
    rm -f "$REMOTE_FAIL_FLAG"
  fi
fi

if [ "$(echo "$ROWS" | grep -c '^PERFCHECK-RESULT|')" -gt 1 ]; then
  printf "\n${C_HEAD}================ Fleet summary ================${C_RESET}\n"
  printf "  ${C_KEY}%-22s %-15s %6s %9s %10s %8s${C_RESET}\n" "HOST" "IP" "CORES" "RAM MiB" "COMPOSITE" "CPU-ALL"
  echo "$ROWS" | while IFS='|' read -r _ h ip cores ram comp cmulti rest; do
    printf "  %-22s %-15s %6s %9s %10s %8s\n" "$(echo "$h" | cut -c1-22)" "$ip" "$cores" "$ram" "$comp" "$cmulti"
  done
fi

# a benchmark that could not measure what it was asked to measure is a failure,
# on this host or on any host reached from it
if has_test_errors || [ "$COMPOSITE" = "N/A" ]; then
  LOCAL_RC=2
fi
if [ "$LOCAL_RC" -ne 0 ]; then
  exit "$LOCAL_RC"
fi
exit "$REMOTE_RC"
