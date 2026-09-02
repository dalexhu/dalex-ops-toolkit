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

TIME_PER_TEST=10
DO_IO=0
DO_INSTALL=1
FORCE=0
QUIET=0
EMIT_RESULT=0
REMOTE=""
IO_DIR=""
BUSY_LIMIT_PCT=25      # refuse to start if the CPU is busier than this

usage() {
  cat <<'USAGE'
perfcheck.sh - sysbench benchmark that sizes itself to the machine

Usage: ./perfcheck.sh [options]

Options:
  --time <sec>       Seconds per test (default 10)
  --quick            Same as --time 3
  --io               Also run the file I/O test. Off by default: it writes a file
                     sized from RAM and free space, and the result reflects the
                     storage rather than the machine
  --io-dir <path>    Directory for the I/O test file (default: current directory)
  --no-install       Do not try to install sysbench if it is missing
  --force            Run even when the machine is already busy
  --max-busy <pct>   Busy CPU percentage that stops the run (default 25)
  --remote <a[,b,]>  Also run on those ssh targets and print a fleet summary
  -q, --quiet        Print the summary only
  -h, --help         This help
  --version          Show version

Exit codes: 0 ran, 1 a host was unreachable or refused to run, 2 sysbench missing
            or usage error.

The composite score is a weighted geometric mean of the CPU, memory, threads and
mutex results measured against the reference profile printed by --help-scoring.
File I/O is scored separately and never enters the composite, so scores stay
comparable whether or not --io was used.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --time)       TIME_PER_TEST="${2:-10}"; shift ;;
    --time=*)     TIME_PER_TEST="${1#*=}" ;;
    --quick)      TIME_PER_TEST=3 ;;
    --io)         DO_IO=1 ;;
    --io-dir)     IO_DIR="${2:-}"; DO_IO=1; shift ;;
    --io-dir=*)   IO_DIR="${1#*=}"; DO_IO=1 ;;
    --no-install) DO_INSTALL=0 ;;
    --force)      FORCE=1 ;;
    --max-busy)   BUSY_LIMIT_PCT="${2:-25}"; shift ;;
    --max-busy=*) BUSY_LIMIT_PCT="${1#*=}" ;;
    --remote)     REMOTE="${2:-}"; shift ;;
    --remote=*)   REMOTE="${1#*=}" ;;
    -q|--quiet)   QUIET=1 ;;
    --emit-result) EMIT_RESULT=1 ;;
    -h|--help)    usage; exit 0 ;;
    --version)    echo "perfcheck.sh $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$TIME_PER_TEST" in
  ''|*[!0-9]*) echo "invalid --time: $TIME_PER_TEST" >&2; exit 2 ;;
esac

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
# Any of these can be overridden from the environment, which is how you calibrate
# the scale to a machine of your own:
#   PERFCHECK_REF_CPU_MULTI=45000 ./perfcheck.sh
REF_CPU_MULTI="${PERFCHECK_REF_CPU_MULTI:-20000}"      # events/s, all threads
REF_CPU_SINGLE="${PERFCHECK_REF_CPU_SINGLE:-5000}"     # events/s, one thread
REF_MEMORY="${PERFCHECK_REF_MEMORY:-40000}"            # MiB/s, 1M blocks
REF_THREADS="${PERFCHECK_REF_THREADS:-15000}"          # events/s, scheduler test
REF_MUTEX="${PERFCHECK_REF_MUTEX:-2500000}"            # mutex locks/s
REF_IO_IOPS="${PERFCHECK_REF_IO_IOPS:-3000}"           # random read+write ops/s

W_CPU_MULTI=30
W_CPU_SINGLE=25
W_MEMORY=20
W_THREADS=15
W_MUTEX=10

# ---------------------------------------------------------------------------
# machine facts
# ---------------------------------------------------------------------------
CPU_MODEL="unknown"; CPU_LOGICAL=1; CPU_PHYSICAL=1; CPU_SOCKETS=1
CPU_QUOTA=""          # cgroup cpu limit, in whole cores, when one is set
CPU_THREADS=1         # threads the tests actually use
MEM_TOTAL_MB=0; MEM_AVAIL_MB=0; VIRT="none"; GOVERNOR=""; DISK_TYPE=""
OS_NAME="unknown"; PKG=""; SUDO=""

OS_KIND="linux"

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
  if [ -r /sys/fs/cgroup/cpu.max ]; then                       # cgroup v2
    local q p
    q="$(awk '{print $1}' /sys/fs/cgroup/cpu.max 2>/dev/null)"
    p="$(awk '{print $2}' /sys/fs/cgroup/cpu.max 2>/dev/null)"
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
    echo "sysbench is not installed and --no-install was given" >&2
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
    awk -v a="${a:-0}" -v b="${b:-0}" -v c="$CPU_THREADS" 'BEGIN{
      d = b - a;
      if (c <= 0 || d < 0) print "0"; else printf "%.1f", 100 * d / (1000000 * c) }'
    return 0
  fi
  if [ -n "$CPU_QUOTA" ] && [ -r /sys/fs/cgroup/cpuacct/cpuacct.usage ]; then
    local a b
    a="$(cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null)"
    sleep 1
    b="$(cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null)"
    awk -v a="${a:-0}" -v b="${b:-0}" -v c="$CPU_THREADS" 'BEGIN{
      d = b - a;
      if (c <= 0 || d < 0) print "0"; else printf "%.1f", 100 * d / (1000000000 * c) }'
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
R_MEM_WRITE=0; R_MEM_READ=0; R_MEM_RND=0; R_MEMORY=0
R_IO_SEQ_READ=0; R_IO_SEQ_WRITE=0
R_IO_IOPS=0; R_IO_READ=0; R_IO_WRITE=0; R_IO_P95=0

sb_field() {  # sb_field <output> <sed pattern>
  echo "$1" | sed -n "$2" | head -1 | tr -d ' '
}

run_cpu() {
  local out
  head2 "CPU"
  out="$(sysbench cpu --threads="$CPU_THREADS" --time="$TIME_PER_TEST" --cpu-max-prime=20000 run 2>/dev/null)"
  R_CPU_MULTI="$(sb_field "$out" 's/^ *events per second: *//p')"
  kv "all cores ($CPU_THREADS threads)" "${R_CPU_MULTI:-0} events/s"

  out="$(sysbench cpu --threads=1 --time="$TIME_PER_TEST" --cpu-max-prime=20000 run 2>/dev/null)"
  R_CPU_SINGLE="$(sb_field "$out" 's/^ *events per second: *//p')"
  kv "single thread" "${R_CPU_SINGLE:-0} events/s"
}

mem_run() {  # mem_run <oper> <access mode> <block size>
  local total_mb out
  total_mb=$(( MEM_TOTAL_MB * 100 ))
  [ "$total_mb" -gt 0 ] || total_mb=100000
  out="$(sysbench memory --threads="$CPU_THREADS" --time="$TIME_PER_TEST" \
          --memory-block-size="$3" --memory-total-size="${total_mb}M" \
          --memory-oper="$1" --memory-access-mode="$2" run 2>/dev/null)"
  echo "$out" | sed -n 's/.*(\([0-9.]*\) MiB\/sec).*/\1/p' | head -1
}

run_memory() {
  head2 "Memory"
  R_MEM_WRITE="$(mem_run write seq 1M)"
  kv "sequential write" "${R_MEM_WRITE:-0} MiB/s   (1M blocks)"
  R_MEM_READ="$(mem_run read seq 1M)"
  kv "sequential read" "${R_MEM_READ:-0} MiB/s   (1M blocks)"
  # small blocks in random order: this one is about access latency, not bandwidth
  R_MEM_RND="$(mem_run write rnd 4K)"
  kv "random write" "${R_MEM_RND:-0} MiB/s   (4K blocks, random order)"

  # the memory subscore uses read and write together; the random figure is
  # reported because it says something different, not because it averages well
  R_MEMORY="$(awk -v a="${R_MEM_WRITE:-0}" -v b="${R_MEM_READ:-0}" \
              'BEGIN{ if (a+0<=0 || b+0<=0) { print (a+0>0?a:b) } else { printf "%.2f", sqrt(a*b) } }')"
  kv "used for scoring" "${R_MEMORY:-0} MiB/s   (geometric mean of read and write)"
}

run_threads() {
  local out events
  head2 "Threads"
  # oversubscribe on purpose: this measures the scheduler under contention
  out="$(sysbench threads --threads=$((CPU_THREADS * 4)) --time="$TIME_PER_TEST" \
          --thread-yields=1000 --thread-locks=8 run 2>/dev/null)"
  events="$(sb_field "$out" 's/^ *total number of events: *//p')"
  # the threads test reports no events/s line, so derive it
  R_THREADS="$(fdiv "${events:-0}" "$TIME_PER_TEST")"
  kv "$((CPU_THREADS * 4)) threads" "${R_THREADS:-0} events/s"
}

run_mutex() {
  local out locks secs
  head2 "Mutex"
  # Each thread takes --mutex-locks locks, so the work scales with the thread
  # count. Reporting the elapsed time would therefore not compare across machines
  # with different core counts; throughput does.
  locks=50000
  out="$(sysbench mutex --threads="$CPU_THREADS" --mutex-num=4096 \
          --mutex-locks="$locks" --mutex-loops=5000 run 2>/dev/null)"
  secs="$(echo "$out" | sed -n 's/^ *total time: *\([0-9.]*\)s.*/\1/p' | head -1)"
  R_MUTEX="$(awk -v t="$CPU_THREADS" -v l="$locks" -v s="${secs:-0}" \
             'BEGIN{ if (s+0 <= 0) print "0"; else printf "%.0f", (t*l)/s }')"
  kv "$CPU_THREADS threads" "${R_MUTEX:-0} locks/s  (${secs:-?}s for $((CPU_THREADS * locks)) locks)"
}

IO_PREPARED=0
io_cleanup() {
  if [ "$IO_PREPARED" -eq 1 ]; then
    ( cd "${IO_DIR:-$PWD}" && sysbench fileio --file-total-size="${IO_SIZE_MB}M" cleanup >/dev/null 2>&1 )
    IO_PREPARED=0
  fi
}
trap io_cleanup EXIT INT TERM

IO_SIZE_MB=0
IO_CACHED=0
IO_NO_DIRECT=""     # set on platforms where O_DIRECT does not exist at all
run_io() {
  [ "$DO_IO" -eq 1 ] || return 0
  local dir free_mb out
  dir="${IO_DIR:-$PWD}"
  head2 "File I/O"

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
  kv "test file" "${IO_SIZE_MB} MiB in $dir (${DISK_TYPE:-unknown media})"

  ( cd "$dir" && sysbench fileio --file-total-size="${IO_SIZE_MB}M" prepare >/dev/null 2>&1 ) || {
    say "  ${C_WARN}prepare failed${C_RESET}"; return 0; }
  IO_PREPARED=1

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

  # random read/write - what a database does
  out="$(io_mode rndrw 's/^ *reads\/s: *//p')"
  R_IO_READ="$(sb_field "$out" 's/^ *read, MiB\/s: *//p')"
  R_IO_WRITE="$(sb_field "$out" 's/^ *written, MiB\/s: *//p')"
  local r w
  r="$(sb_field "$out" 's/^ *reads\/s: *//p')"
  w="$(sb_field "$out" 's/^ *writes\/s: *//p')"
  R_IO_IOPS="$(awk -v a="${r:-0}" -v b="${w:-0}" 'BEGIN{printf "%.1f", a+b}')"
  R_IO_P95="$(sb_field "$out" 's/^ *95th percentile: *//p')"
  kv "random read/write" "${R_IO_IOPS} IOPS   ${R_IO_READ:-0} + ${R_IO_WRITE:-0} MiB/s"
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
S_CPU_MULTI=0; S_CPU_SINGLE=0; S_MEMORY=0; S_THREADS=0; S_MUTEX=0; S_IO=0; COMPOSITE=0

score_all() {
  S_CPU_MULTI="$(fpct "${R_CPU_MULTI:-0}" "$REF_CPU_MULTI")"
  S_CPU_SINGLE="$(fpct "${R_CPU_SINGLE:-0}" "$REF_CPU_SINGLE")"
  S_MEMORY="$(fpct "${R_MEMORY:-0}" "$REF_MEMORY")"
  S_THREADS="$(fpct "${R_THREADS:-0}" "$REF_THREADS")"
  S_MUTEX="$(fpct "${R_MUTEX:-0}" "$REF_MUTEX")"
  if [ "$DO_IO" -eq 1 ]; then
    S_IO="$(fpct "${R_IO_IOPS:-0}" "$REF_IO_IOPS")"
  fi

  # weighted geometric mean - a ratio scale calls for it, and one very high
  # subscore cannot drag the composite up the way an arithmetic mean lets it
  COMPOSITE="$(awk -v a="$S_CPU_MULTI" -v wa="$W_CPU_MULTI" \
                   -v b="$S_CPU_SINGLE" -v wb="$W_CPU_SINGLE" \
                   -v c="$S_MEMORY"     -v wc="$W_MEMORY" \
                   -v d="$S_THREADS"    -v wd="$W_THREADS" \
                   -v e="$S_MUTEX"      -v we="$W_MUTEX" '
    BEGIN {
      n = 0; s = 0;
      if (a+0 > 0) { s += wa * log(a); n += wa }
      if (b+0 > 0) { s += wb * log(b); n += wb }
      if (c+0 > 0) { s += wc * log(c); n += wc }
      if (d+0 > 0) { s += wd * log(d); n += wd }
      if (e+0 > 0) { s += we * log(e); n += we }
      if (n == 0) { print "0" } else { printf "%.1f", exp(s / n) }
    }')"
}

report() {
  head2 "Scores (100 = reference profile v1)"
  printf "  ${C_KEY}%-24s %12s %12s %6s${C_RESET}\n" "TEST" "MEASURED" "REFERENCE" "SCORE"
  printf "  %-24s %12s %12s %6s\n" "cpu, all cores"   "${R_CPU_MULTI:-0}"  "$REF_CPU_MULTI"  "$S_CPU_MULTI"
  printf "  %-24s %12s %12s %6s\n" "cpu, single thread" "${R_CPU_SINGLE:-0}" "$REF_CPU_SINGLE" "$S_CPU_SINGLE"
  printf "  %-24s %12s %12s %6s\n" "memory MiB/s"     "${R_MEMORY:-0}"     "$REF_MEMORY"     "$S_MEMORY"
  printf "  ${C_DIM}%-24s %12s %12s %6s${C_RESET}\n" "  seq write / read" "${R_MEM_WRITE:-0} / ${R_MEM_READ:-0}" "-" "-"
  printf "  ${C_DIM}%-24s %12s %12s %6s${C_RESET}\n" "  random 4K write" "${R_MEM_RND:-0}" "-" "-"
  printf "  %-24s %12s %12s %6s\n" "threads events/s" "${R_THREADS:-0}"    "$REF_THREADS"    "$S_THREADS"
  printf "  %-24s %12s %12s %6s\n" "mutex locks/s"    "${R_MUTEX:-0}"      "$REF_MUTEX"      "$S_MUTEX"
  if [ "$DO_IO" -eq 1 ]; then
    printf "  %-24s %12s %12s %6s\n" "file I/O IOPS"  "${R_IO_IOPS:-0}"    "$REF_IO_IOPS"    "$S_IO"
    printf "  ${C_DIM}%-24s %12s %12s %6s${C_RESET}\n" "  seq read / write MiB/s" "${R_IO_SEQ_READ:-0} / ${R_IO_SEQ_WRITE:-0}" "-" "-"
    printf "  ${C_DIM}%-24s %12s %12s %6s${C_RESET}\n" "  95th pct latency ms" "${R_IO_P95:-0}" "-" "-"
    say "  ${C_DIM}file I/O is reported but never enters the composite${C_RESET}"
    if [ "$IO_CACHED" -eq 1 ]; then
      say "  ${C_WARN}the I/O figures went through the page cache: O_DIRECT was not available${C_RESET}"
    fi
  fi

  if [ "$TIME_PER_TEST" -lt 10 ]; then
    say "  ${C_DIM}runs shorter than 10s vary between repeats, the memory test most of all${C_RESET}"
  fi

  head2 "Composite"
  printf "  ${C_OK}%s${C_RESET}   ${C_DIM}weighted geometric mean: cpu-all %s%%, cpu-1 %s%%, memory %s%%, threads %s%%, mutex %s%%${C_RESET}\n" \
    "$COMPOSITE" "$W_CPU_MULTI" "$W_CPU_SINGLE" "$W_MEMORY" "$W_THREADS" "$W_MUTEX"
}

# ---------------------------------------------------------------------------
# remote fan-out
# ---------------------------------------------------------------------------
run_remote() {
  local targets host out line rows="" self="$0"
  targets="$(echo "$REMOTE" | tr ',' ' ')"
  for host in $targets; do
    printf "\n${C_HEAD}>>> ssh %s${C_RESET}\n" "$host" >&2
    if [ ! -r "$self" ]; then
      printf "  cannot read this script (%s) to pipe it over ssh\n" "$self" >&2
      rows="$rows
PERFCHECK-RESULT|$host|?|?|ERROR"
      continue
    fi
    out="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" \
           "bash -s -- --time '$TIME_PER_TEST' --emit-result $( [ "$DO_IO" -eq 1 ] && echo --io ) $( [ "$FORCE" -eq 1 ] && echo --force )" \
           < "$self" 2>&1)"
    echo "$out" | grep -v '^PERFCHECK-RESULT|' >&2
    line="$(echo "$out" | grep '^PERFCHECK-RESULT|' | tail -1)"
    if [ -z "$line" ]; then
      line="PERFCHECK-RESULT|$host|?|?|UNREACHABLE"
    else
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
LOCAL_RC=0
detect_machine

printf "\n${C_HEAD}================ %s ================${C_RESET}\n" \
  "$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) — $OS_NAME — $(uname -m)"

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
else
  ensure_sysbench
  kv "sysbench" "$(sysbench --version 2>/dev/null)"
  run_cpu
  run_memory
  run_threads
  run_mutex
  run_io
  score_all
  report
fi

HOST_LABEL="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
LOCAL_ROW="PERFCHECK-RESULT|$HOST_LABEL|$CPU_THREADS|${MEM_TOTAL_MB}|$COMPOSITE|$S_CPU_MULTI|$S_CPU_SINGLE|$S_MEMORY|$S_THREADS|$S_MUTEX|${S_IO:-0}"
[ "$EMIT_RESULT" -eq 1 ] && echo "$LOCAL_ROW"

ROWS="$LOCAL_ROW"
if [ -n "$REMOTE" ]; then
  REMOTE_ROWS="$(run_remote)"
  [ -n "$REMOTE_ROWS" ] && ROWS="$ROWS
$REMOTE_ROWS"
fi

if [ "$(echo "$ROWS" | grep -c '^PERFCHECK-RESULT|')" -gt 1 ]; then
  printf "\n${C_HEAD}================ Fleet summary ================${C_RESET}\n"
  printf "  ${C_KEY}%-18s %6s %10s %10s %8s %8s${C_RESET}\n" "HOST" "CORES" "RAM MiB" "COMPOSITE" "CPU-ALL" "CPU-1"
  echo "$ROWS" | while IFS='|' read -r _ h cores ram comp cmulti csingle rest; do
    printf "  %-18s %6s %10s %10s %8s %8s\n" "$(echo "$h" | cut -c1-18)" "$cores" "$ram" "$comp" "$cmulti" "$csingle"
  done
fi

exit $LOCAL_RC
