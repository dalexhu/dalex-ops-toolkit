#!/usr/bin/env bash
#
# jdkcheck.sh — inventory every JDK on a host: version, vendor, bundled tz database,
#               which one is on PATH, and which ones running JVMs actually use.
#
# The JDK does not read /usr/share/zoneinfo for zone rules. It carries its own compiled
# copy at $JAVA_HOME/lib/tzdb.dat (jre/lib/tzdb.dat on 8), so updating the OS tzdata
# package leaves every JVM on the host unchanged. This script reads the version straight
# out of tzdb.dat — no java process is started — and flags installs that are behind.
#
# Usage: ./jdkcheck.sh [options]      run ./jdkcheck.sh --help for details
#
# Portable: bash 3.2+, macOS and Linux.

set -uo pipefail

VERSION="1.0.0"

REQUIRE_TZDB=""      # e.g. 2026c — fail hosts carrying anything older
REMOTE=""
QUIET=0
EMIT_RESULT=0
SHOW_RUNNING=1
SCAN_DOCKER=0
VERIFY=0
VERIFY_ZONE="America/Edmonton"
VERIFY_YEAR=2026

usage() {
  cat <<'USAGE'
jdkcheck.sh — JDK inventory with bundled tz database versions

Usage: ./jdkcheck.sh [options]

Options:
  --require-tzdb <ver>   Flag any JDK whose tzdb.dat is older than <ver> (e.g. 2026c)
                         and exit 1 if one is found
  --remote <a[,b,...]>   Also run on those ssh targets and print a fleet summary
  --no-running           Skip the scan of running JVM processes
  --docker               Also look inside running containers (each image has its own JDK)
  --verify               Run each JDK and report the offset it yields for the autumn
                         window, instead of trusting the tzdb version string alone
  --zone <IANA>          Zone used by --verify (default America/Edmonton)
  --year <YYYY>          Year used by --verify (default 2026)
  -q, --quiet            Summary lines only
  -h, --help             Show this help
  --version              Show version

Exit codes: 0 all good, 1 a JDK is below --require-tzdb / a host was unreachable,
            2 no JDK found or usage error.

Where JDKs are looked for:
  $JAVA_HOME, the java on $PATH, /usr/lib/jvm/*, /usr/java/*, /opt/{java,jdk}*,
  /Library/Java/JavaVirtualMachines/*/Contents/Home, ~/.sdkman/candidates/java/*,
  Homebrew openjdk kegs, and the binaries behind running JVM processes.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --require-tzdb)   [ $# -ge 2 ] || { echo "--require-tzdb needs a value" >&2; exit 2; }; REQUIRE_TZDB="$2"; shift ;;
    --require-tzdb=*) REQUIRE_TZDB="${1#*=}" ;;
    --remote)         [ $# -ge 2 ] || { echo "--remote needs a value" >&2; exit 2; }; REMOTE="$2"; shift ;;
    --remote=*)       REMOTE="${1#*=}" ;;
    --no-running)     SHOW_RUNNING=0 ;;
    --docker)         SCAN_DOCKER=1 ;;
    --verify)         VERIFY=1 ;;
    --zone)           [ $# -ge 2 ] || { echo "--zone needs a value" >&2; exit 2; }; VERIFY_ZONE="$2"; VERIFY=1; shift ;;
    --zone=*)         VERIFY_ZONE="${1#*=}"; VERIFY=1 ;;
    --year)           [ $# -ge 2 ] || { echo "--year needs a value" >&2; exit 2; }; VERIFY_YEAR="$2"; VERIFY=1; shift ;;
    --year=*)         VERIFY_YEAR="${1#*=}"; VERIFY=1 ;;
    -q|--quiet)       QUIET=1 ;;
    --emit-result)    EMIT_RESULT=1 ;;
    -h|--help)        usage; exit 0 ;;
    --version)        echo "jdkcheck.sh $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

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
has()   { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# tzdb.dat parsing — no JVM is started
#
# Layout written by TzdbZoneRulesCompiler:
#   byte 0      : format version (1)
#   bytes 1..2  : u16 length of the group id  (4)
#   bytes 3..6  : "TZDB"
#   bytes 7..8  : u16 number of rule versions (normally 1)
#   bytes 9..10 : u16 length of the version string
#   bytes 11..  : the version string, e.g. "2026a"
# ---------------------------------------------------------------------------
# Reading the first 16 bytes and dropping every non-alphanumeric byte yields
# exactly "TZDB" + the version (e.g. "TZDB2026a"). Uses only head and tr, so the
# same one-liner also works inside busybox-based containers.
tzdb_version() {  # <tzdb.dat path>
  local raw
  [ -r "$1" ] || { echo "unreadable"; return 1; }
  raw="$(LC_ALL=C head -c 16 "$1" 2>/dev/null | LC_ALL=C tr -cd '0-9A-Za-z')"
  case "$raw" in
    TZDB?*) echo "${raw#TZDB}" ;;
    *)      echo "not-tzdb"; return 1 ;;
  esac
}

# compare tzdata versions such as 2026a / 2026c / 2025b-rearguard
# echoes -1, 0 or 1 for  $1 <=> $2
tzdb_cmp() {
  local a="$1" b="$2" ay al by bl
  ay="$(echo "$a" | sed -n 's/^\([0-9][0-9][0-9][0-9]\).*/\1/p')"
  by="$(echo "$b" | sed -n 's/^\([0-9][0-9][0-9][0-9]\).*/\1/p')"
  al="$(echo "$a" | sed -n 's/^[0-9][0-9][0-9][0-9]\([a-z]\).*/\1/p')"
  bl="$(echo "$b" | sed -n 's/^[0-9][0-9][0-9][0-9]\([a-z]\).*/\1/p')"
  if [ -z "$ay" ] || [ -z "$by" ]; then
    echo 0; return 0
  fi
  if [ "$ay" -lt "$by" ]; then echo -1; return 0; fi
  if [ "$ay" -gt "$by" ]; then echo 1;  return 0; fi
  [ -z "$al" ] && al="a"
  [ -z "$bl" ] && bl="a"
  if [ "$al" \< "$bl" ]; then echo -1; elif [ "$al" \> "$bl" ]; then echo 1; else echo 0; fi
}

# ---------------------------------------------------------------------------
# JDK discovery
# ---------------------------------------------------------------------------
real_path() {
  local p="$1"
  if has readlink && readlink -f / >/dev/null 2>&1; then
    readlink -f "$p" 2>/dev/null && return 0
  fi
  # BSD fallback: resolve by walking with cd -P
  ( cd "$(dirname "$p")" 2>/dev/null && printf "%s/%s\n" "$(pwd -P)" "$(basename "$p")" ) 2>/dev/null || echo "$p"
}

# from any java binary, walk up to the home directory that holds release/lib
home_of_java_bin() {
  local bin home
  bin="$(real_path "$1")"
  home="$(dirname "$(dirname "$bin")")"
  echo "$home"
}

CANDIDATES=""
add_candidate() {
  local h="$1"
  [ -n "$h" ] || return 0
  [ -d "$h" ] || return 0
  # a JDK/JRE home has a java launcher and either release or lib/
  [ -x "$h/bin/java" ] || return 0
  CANDIDATES="$CANDIDATES
$(real_path "$h")"
}

discover_jdks() {
  local p d

  [ -n "${JAVA_HOME:-}" ] && add_candidate "$JAVA_HOME"

  if has java; then
    add_candidate "$(home_of_java_bin "$(command -v java)")"
  fi

  # macOS system locations
  if [ -d /Library/Java/JavaVirtualMachines ]; then
    for d in /Library/Java/JavaVirtualMachines/*/Contents/Home; do
      add_candidate "$d"
    done
  fi
  if [ -x /usr/libexec/java_home ]; then
    add_candidate "$(/usr/libexec/java_home 2>/dev/null)"
  fi

  # Linux distro locations
  for d in /usr/lib/jvm/* /usr/java/* /opt/java/* /opt/jdk* /opt/java* /srv/java/*; do
    add_candidate "$d"
    add_candidate "$d/Contents/Home"
  done

  # sdkman, Homebrew
  for d in "$HOME"/.sdkman/candidates/java/*; do
    add_candidate "$d"
  done
  for d in /opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home \
           /usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home; do
    add_candidate "$d"
  done

  # alternatives
  if has update-alternatives; then
    for p in $(update-alternatives --list java 2>/dev/null); do
      add_candidate "$(home_of_java_bin "$p")"
    done
  fi

  # whatever running JVMs are actually executing
  for p in $(running_java_bins); do
    add_candidate "$(home_of_java_bin "$p")"
  done

  echo "$CANDIDATES" | grep -v '^$' | sort -u
}

RUNNING_HIDDEN=0     # java processes whose binary we were not allowed to resolve

running_java_bins() {
  local pid exe hidden=0
  if [ -d /proc ]; then
    for pid in $(ls /proc 2>/dev/null | grep '^[0-9][0-9]*$'); do
      case "$(cat "/proc/$pid/comm" 2>/dev/null)" in
        java) ;;
        *) continue ;;
      esac
      exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
      if [ -n "$exe" ]; then
        case "$exe" in */java) echo "$exe" ;; esac
      else
        # another user's process, or a JVM inside a container namespace
        hidden=$((hidden + 1))
      fi
    done
  elif has ps; then
    # macOS: the executable path is the command name
    ps -eo comm= 2>/dev/null | grep '/java$' || true
  fi
  RUNNING_HIDDEN=$hidden
  return 0
}

release_value() {  # <java home> <key>
  local f="$1/release"
  [ -r "$f" ] || return 1
  sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}/\1/p" "$f" | head -1
}

# Corretto 8 and some repackaged builds ship no release file; fall back to the
# launcher itself. Cached so each JDK is executed at most once.
JAVA_V_CACHE_HOME=""
JAVA_V_CACHE_OUT=""
java_version_output() {  # <java home>
  if [ "$JAVA_V_CACHE_HOME" != "$1" ]; then
    JAVA_V_CACHE_HOME="$1"
    JAVA_V_CACHE_OUT="$("$1/bin/java" -version 2>&1)"
  fi
  echo "$JAVA_V_CACHE_OUT"
}

jdk_version_of() {  # <java home>
  local v
  v="$(release_value "$1" JAVA_VERSION 2>/dev/null)"
  if [ -n "$v" ]; then
    echo "$v"; return 0
  fi
  v="$(java_version_output "$1" | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$v" ] && echo "$v" || echo "?"
}

jdk_vendor_of() {  # <java home>
  local v
  v="$(release_value "$1" IMPLEMENTOR 2>/dev/null)"
  if [ -n "$v" ]; then
    echo "$v"; return 0
  fi
  # second line looks like: OpenJDK Runtime Environment Corretto-8.472.08.1 (build ...)
  v="$(java_version_output "$1" | sed -n '2p' | sed 's/ (build.*//' | awk '{print $NF}')"
  [ -n "$v" ] && echo "$v" || echo "?"
}

tzdb_path_of() {  # <java home>
  local h="$1"
  if [ -f "$h/lib/tzdb.dat" ]; then
    echo "$h/lib/tzdb.dat"
  elif [ -f "$h/jre/lib/tzdb.dat" ]; then
    echo "$h/jre/lib/tzdb.dat"
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# where an install came from - decides what the fix command looks like
# ---------------------------------------------------------------------------
jdk_source_of() {  # <java home> -> sdkman | homebrew | macos-pkg | rpm:<pkg> | deb:<pkg> | manual
  local h="$1" pkg
  case "$h" in
    */.sdkman/candidates/java/*)                echo "sdkman";    return 0 ;;
    /opt/homebrew/*|/usr/local/Cellar/*)        echo "homebrew";  return 0 ;;
    /Library/Java/JavaVirtualMachines/*)        echo "macos-pkg"; return 0 ;;
  esac
  if has rpm; then
    pkg="$(rpm -qf --qf '%{NAME}' "$h/bin/java" 2>/dev/null)"
    if [ -n "$pkg" ] && [ "${pkg#file }" = "$pkg" ]; then
      echo "rpm:$pkg"; return 0
    fi
  fi
  if has dpkg; then
    pkg="$(dpkg -S "$h/bin/java" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -n "$pkg" ]; then
      echo "deb:$pkg"; return 0
    fi
  fi
  echo "manual"
}

fix_hint_for() {  # <source> <java home>
  case "$1" in
    sdkman)    echo "sdk install java <newer-patch>  (then: sdk default java <ver>)" ;;
    homebrew)  echo "brew upgrade openjdk" ;;
    macos-pkg) echo "reinstall the vendor .pkg, or run TZUpdater against this home" ;;
    rpm:*)     echo "sudo dnf update ${1#rpm:}" ;;
    deb:*)     echo "sudo apt-get install --only-upgrade ${1#deb:}" ;;
    *)         echo "replace tzdb.dat via TZUpdater: java -jar tzupdater.jar -l -Djava.home=$2" ;;
  esac
}

# ---------------------------------------------------------------------------
# optional: run each JDK and see what offset it really produces
# ---------------------------------------------------------------------------
PROBE_DIR=""
PROBE_READY=0

build_probe() {  # <java home>...
  [ "$VERIFY" -eq 1 ] || return 0
  local h javac
  PROBE_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/jdkprobe.$$")"
  mkdir -p "$PROBE_DIR" || return 1
  cat > "$PROBE_DIR/TzProbe.java" <<'JAVA'
import java.time.*;
import java.time.zone.ZoneRulesProvider;
public class TzProbe {
  public static void main(String[] a) {
    String zone = a[0];
    int year = Integer.parseInt(a[1]);
    ZoneId z = ZoneId.of(zone);
    ZoneOffset oct = ZonedDateTime.of(year, 10, 15, 12, 0, 0, 0, z).getOffset();
    ZoneOffset nov = ZonedDateTime.of(year, 11, 15, 12, 0, 0, 0, z).getOffset();
    String db;
    try { db = ZoneRulesProvider.getVersions(zone).lastKey(); } catch (Exception e) { db = "?"; }
    System.out.println(db + "|" + nov + "|" + (oct.equals(nov) ? "no-change" : "falls-back"));
  }
}
JAVA
  # one class file, targeted at 8 so every JDK on the host can run it
  for h in "$@"; do
    javac="$h/bin/javac"
    [ -x "$javac" ] || continue
    if "$javac" --release 8 -d "$PROBE_DIR" "$PROBE_DIR/TzProbe.java" 2>/dev/null \
       || "$javac" -source 8 -target 8 -d "$PROBE_DIR" "$PROBE_DIR/TzProbe.java" 2>/dev/null \
       || "$javac" --release 11 -d "$PROBE_DIR" "$PROBE_DIR/TzProbe.java" 2>/dev/null; then
      PROBE_READY=1
      break
    fi
  done
  [ "$PROBE_READY" -eq 1 ] || say "  ${C_DIM}--verify: no usable javac found; falling back to tzdb version strings${C_RESET}"
  return 0
}

probe_jdk() {  # <java home> -> "<offset> <no-change|falls-back>" or empty
  [ "$PROBE_READY" -eq 1 ] || return 1
  local out
  out="$("$1/bin/java" -cp "$PROBE_DIR" TzProbe "$VERIFY_ZONE" "$VERIFY_YEAR" 2>/dev/null | tail -1)"
  case "$out" in
    *"|"*"|"*) echo "$(echo "$out" | cut -d'|' -f2) $(echo "$out" | cut -d'|' -f3)" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# containers: each image ships its own JDK, invisible to the host scan
# ---------------------------------------------------------------------------
scan_docker() {
  if ! has docker; then
    head2 "Containers"
    say "  ${C_DIM}docker not available on this host${C_RESET}"
    return 0
  fi
  local names c out
  names="$(docker ps --format '{{.Names}}' 2>/dev/null)"
  head2 "Containers with a JVM"
  if [ -z "$names" ]; then
    say "  ${C_DIM}no running containers (or no permission to list them)${C_RESET}"
    return 0
  fi
  printf "  ${C_KEY}%-24s %-14s %-9s %s${C_RESET}\n" "CONTAINER" "VERSION" "TZDB" "JAVA HOME"
  local found=0
  for c in $names; do
    # one shot per container: locate java, read its version and its tzdb.dat
    out="$(docker exec "$c" sh -c '
      jb=$(command -v java 2>/dev/null) || exit 1
      [ -n "$jb" ] || exit 1
      while [ -L "$jb" ]; do jb=$(readlink -f "$jb" 2>/dev/null || echo "$jb"); done
      home=$(dirname "$(dirname "$jb")")
      f="$home/lib/tzdb.dat"
      [ -f "$f" ] || f="$home/jre/lib/tzdb.dat"
      v=$("$jb" -version 2>&1 | head -1 | sed -n "s/.*version \"\([^\"]*\)\".*/\1/p")
      t="none"
      if [ -f "$f" ]; then
        raw=$(head -c 16 "$f" | tr -cd "0-9A-Za-z")
        case "$raw" in TZDB*) t=${raw#TZDB} ;; esac
      fi
      echo "${v:-?}|$t|$home"
    ' 2>/dev/null | tail -1)"
    # docker prints OCI exec failures on stdout for some versions; only accept
    # output that matches the "version|tzdb|/absolute/home" shape we asked for
    case "$out" in
      *"|"*"|/"*) : ;;
      *) continue ;;
    esac
    found=1
    local cv ct ch marker=""
    cv="$(echo "$out" | cut -d'|' -f1)"
    ct="$(echo "$out" | cut -d'|' -f2)"
    ch="$(echo "$out" | cut -d'|' -f3)"
    if [ -n "$REQUIRE_TZDB" ] && [ "$ct" != "none" ] && [ "$(tzdb_cmp "$ct" "$REQUIRE_TZDB")" = "-1" ]; then
      STALE_COUNT=$((STALE_COUNT + 1))
      marker="${C_WARN}  <- older than $REQUIRE_TZDB${C_RESET}"
    fi
    JDK_COUNT=$((JDK_COUNT + 1))
    if [ -z "$OLDEST_TZDB" ] || [ "$(tzdb_cmp "$ct" "$OLDEST_TZDB")" = "-1" ]; then
      case "$ct" in [0-9][0-9][0-9][0-9]*) OLDEST_TZDB="$ct" ;; esac
    fi
    printf "  %-24s %-14s %-9s %s%b\n" "$(echo "$c" | cut -c1-24)" "$cv" "$ct" "$ch" "$marker"
  done
  [ "$found" -eq 0 ] && say "  ${C_DIM}none of the running containers has a java on PATH${C_RESET}"
  return 0
}

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
JDK_COUNT=0
STALE_COUNT=0
OLDEST_TZDB=""
PATH_JAVA_HOME=""
RUNNING_HOMES=""
ADVICE=""

run_local() {
  local homes h ver vendor tzf tzv marker used cmp

  printf "\n${C_HEAD}================ %s ================${C_RESET}\n" \
    "$(hostname 2>/dev/null || echo host) — $(uname -s) $(uname -m)"

  if has java; then
    PATH_JAVA_HOME="$(home_of_java_bin "$(command -v java)")"
  fi
  if [ "$SHOW_RUNNING" -eq 1 ]; then
    for h in $(running_java_bins); do
      RUNNING_HOMES="$RUNNING_HOMES $(home_of_java_bin "$h")"
    done
  fi

  homes="$(discover_jdks)"
  if [ -z "$homes" ]; then
    say "  no JDK or JRE found on this host"
    return 2
  fi

  build_probe $homes

  if [ "$VERIFY" -eq 1 ]; then
    head2 "JDK inventory (tzdb read from tzdb.dat; NOV verified by running each JDK)"
    printf "  ${C_KEY}%-10s %-18s %-9s %-9s %-8s %s${C_RESET}\n" "VERSION" "VENDOR" "TZDB" "NOV" "USE" "PATH"
  else
    head2 "JDK inventory (tzdb version read from tzdb.dat, no JVM started)"
    printf "  ${C_KEY}%-10s %-18s %-9s %-8s %s${C_RESET}\n" "VERSION" "VENDOR" "TZDB" "USE" "PATH"
  fi

  for h in $homes; do
    JDK_COUNT=$((JDK_COUNT + 1))
    ver="$(jdk_version_of "$h")"
    vendor="$(jdk_vendor_of "$h")"
    if tzf="$(tzdb_path_of "$h")"; then
      tzv="$(tzdb_version "$tzf")"
    else
      tzv="none"
    fi

    used=""
    [ "$h" = "$PATH_JAVA_HOME" ] && used="PATH"
    case " $RUNNING_HOMES " in
      *" $h "*) [ -n "$used" ] && used="$used,RUN" || used="RUN" ;;
    esac
    [ -n "$used" ] || used="-"

    marker=""
    if [ -n "$REQUIRE_TZDB" ] && [ "$tzv" != "none" ]; then
      cmp="$(tzdb_cmp "$tzv" "$REQUIRE_TZDB")"
      if [ "$cmp" = "-1" ]; then
        STALE_COUNT=$((STALE_COUNT + 1))
        marker="${C_WARN}  <- older than $REQUIRE_TZDB${C_RESET}"
      fi
    fi
    if [ -z "$OLDEST_TZDB" ] || [ "$(tzdb_cmp "$tzv" "$OLDEST_TZDB")" = "-1" ]; then
      case "$tzv" in [0-9][0-9][0-9][0-9]*) OLDEST_TZDB="$tzv" ;; esac
    fi

    local nov="-"
    if [ "$VERIFY" -eq 1 ]; then
      nov="$(probe_jdk "$h" 2>/dev/null)"
      if [ -z "$nov" ]; then
        nov="unrunnable"
      else
        case "$nov" in
          *falls-back) nov="$(echo "$nov" | cut -d' ' -f1)" ;;
          *no-change)  nov="$(echo "$nov" | cut -d' ' -f1)*" ;;
        esac
      fi
    fi

    if [ -n "$marker" ]; then
      ADVICE="$ADVICE
$(jdk_source_of "$h")|$h|$ver|$tzv"
    fi

    if [ "$VERIFY" -eq 1 ]; then
      printf "  %-10s %-18s %-9s %-9s %-8s %s%b\n" \
        "$(echo "$ver" | cut -c1-10)" "$(echo "$vendor" | cut -c1-18)" "$tzv" "$nov" "$used" "$h" "$marker"
    else
      printf "  %-10s %-18s %-9s %-8s %s%b\n" \
        "$(echo "$ver" | cut -c1-10)" "$(echo "$vendor" | cut -c1-18)" "$tzv" "$used" "$h" "$marker"
    fi
  done
  [ "$VERIFY" -eq 1 ] && say "  ${C_DIM}NOV = offset this JDK yields for $VERIFY_ZONE on $VERIFY_YEAR-11-15; * = no autumn change${C_RESET}"

  if [ "$SHOW_RUNNING" -eq 1 ]; then
    head2 "Running JVMs"
    local any=0
    for h in $(running_java_bins); do
      any=1
      say "  $(real_path "$h")"
    done
    if [ "${RUNNING_HIDDEN:-0}" -gt 0 ]; then
      any=1
      say "  ${C_WARN}${RUNNING_HIDDEN} java process(es) whose binary could not be resolved${C_RESET}"
      say "  ${C_DIM}another user, or a JVM inside a container — containers carry the JDK of their${C_RESET}"
      say "  ${C_DIM}own image, which this host scan cannot see. Re-run with --docker.${C_RESET}"
    fi
    [ "$any" -eq 0 ] && say "  ${C_DIM}none (or not visible to this user)${C_RESET}"
  fi

  if [ "$SCAN_DOCKER" -eq 1 ]; then
    scan_docker
  fi

  if [ -n "$ADVICE" ]; then
    head2 "Recommended actions"
    echo "$ADVICE" | grep -v '^$' | sort -u | while IFS='|' read -r src home ver tzv; do
      say "  ${C_WARN}$ver${C_RESET} (tzdb $tzv, $src)"
      say "    $home"
      say "    -> $(fix_hint_for "$src" "$home")"
    done
    say ""
    say "  ${C_DIM}Universal fallback for any install you cannot upgrade - rewrite tzdb.dat in place:${C_RESET}"
    say "  ${C_DIM}  java -jar tzupdater.jar -l https://data.iana.org/time-zones/releases/tzdataXXXX.tar.gz${C_RESET}"
    say "  ${C_DIM}  (run it with the JDK you are patching; back up lib/tzdb.dat first)${C_RESET}"
  fi

  head2 "Notes"
  say "  ${C_DIM}JDK zone rules come from tzdb.dat inside the JDK, never from /usr/share/zoneinfo.${C_RESET}"
  say "  ${C_DIM}Updating the OS tzdata package does not change any of the rows above.${C_RESET}"
  say "  ${C_DIM}Fix by upgrading the JDK patch release, or by rewriting tzdb.dat with TZUpdater.${C_RESET}"
  say "  ${C_DIM}A JVM reads tzdb.dat once at startup — restart the process after replacing it.${C_RESET}"
  return 0
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
      printf "  --remote needs the script as a real file: curl -fsSLO <raw-url> first\n" >&2
      rows="$rows
JDKCHECK-RESULT|$host|?|?|ERROR"
      continue
    fi
    out="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" \
           "bash -s -- --emit-result $( [ -n "$REQUIRE_TZDB" ] && echo "--require-tzdb $REQUIRE_TZDB" )" \
           < "$self" 2>&1)"
    echo "$out" | grep -v '^JDKCHECK-RESULT|' >&2
    line="$(echo "$out" | grep '^JDKCHECK-RESULT|' | tail -1)"
    if [ -z "$line" ]; then
      line="JDKCHECK-RESULT|$host|?|?|UNREACHABLE"
    else
      line="JDKCHECK-RESULT|$host|$(echo "$line" | cut -d'|' -f3-)"
    fi
    rows="$rows
$line"
  done
  echo "$rows" | grep '^JDKCHECK-RESULT|'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
LOCAL_RC=0
run_local || LOCAL_RC=$?
[ -n "$PROBE_DIR" ] && rm -rf "$PROBE_DIR"

STATUS="OK"
if [ "$LOCAL_RC" -eq 2 ]; then
  STATUS="NO-JDK"
elif [ -n "$REQUIRE_TZDB" ] && [ "$STALE_COUNT" -gt 0 ]; then
  STATUS="STALE"
fi

if [ "$QUIET" -eq 0 ] || [ "$EMIT_RESULT" -eq 1 ]; then
  head2 "Verdict"
  case "$STATUS" in
    OK)     printf "  ${C_OK}[OK]${C_RESET}     %s JDK(s); oldest bundled tzdb: %s\n" "$JDK_COUNT" "${OLDEST_TZDB:-n/a}" ;;
    STALE)  printf "  ${C_WARN}[STALE]${C_RESET}  %s of %s JDK(s) carry a tzdb older than %s (oldest: %s)\n" \
              "$STALE_COUNT" "$JDK_COUNT" "$REQUIRE_TZDB" "${OLDEST_TZDB:-n/a}" ;;
    NO-JDK) printf "  ${C_ERR}[NO-JDK]${C_RESET} no JDK or JRE found\n" ;;
  esac
fi

LOCAL_ROW="JDKCHECK-RESULT|$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)|$JDK_COUNT|${OLDEST_TZDB:-n/a}|$STATUS"
[ "$EMIT_RESULT" -eq 1 ] && echo "$LOCAL_ROW"

ROWS="$LOCAL_ROW"
if [ -n "$REMOTE" ]; then
  REMOTE_ROWS="$(run_remote)"
  [ -n "$REMOTE_ROWS" ] && ROWS="$ROWS
$REMOTE_ROWS"
fi

if [ "$(echo "$ROWS" | grep -c '^JDKCHECK-RESULT|')" -gt 1 ]; then
  printf "\n${C_HEAD}================ Fleet summary ================${C_RESET}\n"
  printf "  ${C_KEY}%-20s %-6s %-12s %s${C_RESET}\n" "HOST" "JDKS" "OLDEST TZDB" "STATUS"
  echo "$ROWS" | while IFS='|' read -r _ h n oldest status; do
    case "$status" in
      OK)    printf "  %-20s %-6s %-12s ${C_OK}%s${C_RESET}\n"   "$h" "$n" "$oldest" "$status" ;;
      STALE) printf "  %-20s %-6s %-12s ${C_WARN}%s${C_RESET}\n" "$h" "$n" "$oldest" "$status" ;;
      *)     printf "  %-20s %-6s %-12s ${C_ERR}%s${C_RESET}\n"  "$h" "$n" "$oldest" "$status" ;;
    esac
  done
fi

EXIT=0
case "$(echo "$ROWS" | cut -d'|' -f5 | sort -u | tr '\n' ' ')" in
  *STALE*|*UNREACHABLE*|*ERROR*) EXIT=1 ;;
esac
[ "$STATUS" = "NO-JDK" ] && EXIT=2
exit $EXIT
