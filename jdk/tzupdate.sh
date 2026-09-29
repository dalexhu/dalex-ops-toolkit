#!/usr/bin/env bash
#
# tzupdate.sh — fetch Oracle's tzupdater.jar and use it to replace the tz database
#               ($JAVA_HOME/lib/tzdb.dat) of one or more JDKs.
#
# tzupdater.jar sits behind an Oracle login and licence click-through, so this script
# cannot download it from oracle.com. Download the zip once by hand and point --jar at it
# (a local .jar or .zip, or an http(s) URL on your own mirror); after that every host can
# fetch it unattended.
#
# Usage: ./tzupdate.sh --jar <path|url> [options]      run ./tzupdate.sh --help for details
#
# Portable: bash 3.2+, macOS and Linux.

set -uo pipefail
: "${TMPDIR:=/tmp}"

VERSION="1.0.0"

JAR_SRC="${TZUPDATER_JAR:-}"
TZDATA="latest"      # newest IANA release
JAVA_HOMES=""        # newline-separated
CHECK_ONLY=0
FORCE=0
VERBOSE=0

IANA_RELEASES="https://data.iana.org/time-zones/releases"
IANA_LATEST="https://data.iana.org/time-zones/tzdata-latest.tar.gz"

usage() {
  cat <<'USAGE'
tzupdate.sh — update a JDK's bundled tz database with Oracle's tzupdater.jar

Usage: ./tzupdate.sh --jar <path|url> [options]

Options:
  --jar <path|url>       tzupdater.jar, or the tzupdater-*.zip it ships in, as a local
                         path or an http(s) URL (default: $TZUPDATER_JAR, then
                         ./tzupdater.jar, then ./tzupdater-*.zip)
  --java-home <dir>      JDK to update; repeat for several (default: $JAVA_HOME, else
                         the JDK behind the java on $PATH)
  --tzdata <ver|path|url>
                         tzdata to install: latest (the default, IANA's newest
                         release), a release such as 2026c (fetched from
                         data.iana.org), a local tzdata*.tar.gz, or a URL
  --check                Only print each JDK's current tzdata version, change nothing
  -f, --force            Install even if the target is the same or older
  -v, --verbose          Pass -v to tzupdater
  -h, --help             Show this help
  --version              Show version

Exit codes: 0 every JDK updated (or already current), 1 an update failed,
            2 usage error / tzupdater.jar or a JDK not found.

Restart every JVM that runs on an updated JDK: a running JVM never reloads its zone rules.
USAGE
}

add_home() {
  if [ -z "$JAVA_HOMES" ]; then JAVA_HOMES="$1"; else JAVA_HOMES="$JAVA_HOMES
$1"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --jar)          [ $# -ge 2 ] || { echo "--jar needs a value" >&2; exit 2; }; JAR_SRC="$2"; shift ;;
    --jar=*)        JAR_SRC="${1#*=}" ;;
    --java-home)    [ $# -ge 2 ] || { echo "--java-home needs a value" >&2; exit 2; }; add_home "$2"; shift ;;
    --java-home=*)  add_home "${1#*=}" ;;
    --tzdata)       [ $# -ge 2 ] || { echo "--tzdata needs a value" >&2; exit 2; }; TZDATA="$2"; shift ;;
    --tzdata=*)     TZDATA="${1#*=}" ;;
    --check)        CHECK_ONLY=1 ;;
    -f|--force)     FORCE=1 ;;
    -v|--verbose)   VERBOSE=1 ;;
    -h|--help)      usage; exit 0 ;;
    --version)      echo "tzupdate.sh $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WORK="$(mktemp -d "${TMPDIR%/}/tzupdate.XXXXXX")" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

fetch() {  # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    echo "Neither curl nor wget is installed" >&2
    return 1
  fi
}

# tzdb.dat starts with 01 00 04 "TZDB" 00 01 00 05 "2026a": keep the alphanumerics.
tzdb_version() {
  head -c 16 "$1" 2>/dev/null | LC_ALL=C tr -cd '[:alnum:]' | sed 's/^TZDB//'
}

tzdb_path() {
  if [ -f "$1/lib/tzdb.dat" ]; then
    echo "$1/lib/tzdb.dat"
  elif [ -f "$1/jre/lib/tzdb.dat" ]; then
    echo "$1/jre/lib/tzdb.dat"
  fi
}

# --- JDKs --------------------------------------------------------------------------

if [ -z "$JAVA_HOMES" ]; then
  if [ -n "${JAVA_HOME:-}" ]; then
    add_home "$JAVA_HOME"
  elif command -v java >/dev/null 2>&1; then
    home="$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java\.home = //p' | head -n 1)"
    [ -n "$home" ] && add_home "$home"
  fi
fi
if [ -z "$JAVA_HOMES" ]; then
  echo "No JDK found: set JAVA_HOME, put java on PATH, or pass --java-home" >&2
  exit 2
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  rc=0
  printf '  %-10s %s\n' "TZDB" "JAVA HOME"
  while IFS= read -r home; do
    db="$(tzdb_path "$home")"
    if [ -z "$db" ]; then
      printf '  %-10s %s  <- no tzdb.dat\n' "-" "$home"
      rc=2
    else
      printf '  %-10s %s\n' "$(tzdb_version "$db")" "$home"
    fi
  done <<EOF
$JAVA_HOMES
EOF
  exit "$rc"
fi

# --- tzupdater.jar -----------------------------------------------------------------

if [ -z "$JAR_SRC" ]; then
  if [ -f ./tzupdater.jar ]; then
    JAR_SRC="./tzupdater.jar"
  else
    for z in ./tzupdater-*.zip; do
      [ -f "$z" ] && JAR_SRC="$z"
    done
  fi
fi
if [ -z "$JAR_SRC" ]; then
  cat >&2 <<'MSG'
tzupdater.jar not found.

Oracle only serves it after a login and a licence click-through, so it cannot be
fetched automatically from oracle.com:
  1. Download tzupdater-*.zip from
     https://www.oracle.com/java/technologies/javase-tzupdater-downloads.html
  2. Run this script with --jar <that zip or the jar inside it>, or put it on a
     server you control and pass --jar https://.../tzupdater.jar
MSG
  exit 2
fi

case "$JAR_SRC" in
  http://*|https://*)
    src="$WORK/$(basename "${JAR_SRC%%\?*}")"
    fetch "$JAR_SRC" "$src" || { echo "Download failed: $JAR_SRC" >&2; exit 2; }
    ;;
  *)
    src="$JAR_SRC"
    [ -f "$src" ] || { echo "No such file: $src" >&2; exit 2; }
    ;;
esac

case "$src" in
  *.zip)
    command -v unzip >/dev/null 2>&1 || { echo "unzip is needed to open $src" >&2; exit 2; }
    unzip -q -j -o "$src" '*tzupdater.jar' -d "$WORK" 2>/dev/null
    JAR="$WORK/tzupdater.jar"
    [ -f "$JAR" ] || { echo "No tzupdater.jar inside $src" >&2; exit 2; }
    ;;
  *)
    JAR="$src"
    ;;
esac

# --- tzdata ------------------------------------------------------------------------

LOCATION=""
if [ -n "$TZDATA" ]; then
  case "$TZDATA" in
    latest)
      LOCATION="$IANA_LATEST"
      ;;
    http://*|https://*|file://*)
      LOCATION="$TZDATA"
      ;;
    *.tar.gz|*.tgz)
      [ -f "$TZDATA" ] || { echo "No such file: $TZDATA" >&2; exit 2; }
      LOCATION="file://$(cd "$(dirname "$TZDATA")" && pwd)/$(basename "$TZDATA")"
      ;;
    [0-9][0-9][0-9][0-9][a-z])
      LOCATION="$IANA_RELEASES/tzdata$TZDATA.tar.gz"
      ;;
    *)
      echo "--tzdata expects latest, a release like 2026c, a tzdata*.tar.gz, or a URL" >&2
      exit 2
      ;;
  esac
fi

# Download once, so every JDK gets the same bytes and a host behind a proxy is only
# asked once.
case "$LOCATION" in
  http://*|https://*)
    tz="$WORK/$(basename "$LOCATION")"
    fetch "$LOCATION" "$tz" || { echo "Download failed: $LOCATION" >&2; exit 2; }
    LOCATION="file://$tz"
    ;;
esac

# --- update ------------------------------------------------------------------------

rc=0
updated=0
while IFS= read -r home; do
  echo "== $home"
  java="$home/bin/java"
  db="$(tzdb_path "$home")"
  if [ ! -x "$java" ] || [ -z "$db" ]; then
    echo "   not a JDK (no bin/java or tzdb.dat), skipped"
    rc=2
    continue
  fi

  before="$(tzdb_version "$db")"
  args="-l"
  [ -n "$LOCATION" ] && args="$args $LOCATION"
  [ "$FORCE" -eq 1 ] && args="$args -f"
  [ "$VERBOSE" -eq 1 ] && args="$args -v"

  # $args is split on purpose: it holds only flags and a URL without spaces, unless
  # the tzdata path itself has one.
  if [ -w "$(dirname "$db")" ]; then
    # shellcheck disable=SC2086
    "$java" -jar "$JAR" $args
  elif command -v sudo >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    sudo "$java" -jar "$JAR" $args
  else
    echo "   $(dirname "$db") is not writable and sudo is not available"
    rc=1
    continue
  fi
  status=$?

  after="$(tzdb_version "$db")"
  if [ "$status" -ne 0 ]; then
    echo "   tzupdater failed (exit $status), tzdb still $after"
    rc=1
  elif [ "$before" = "$after" ]; then
    echo "   tzdb $after, unchanged"
  else
    echo "   tzdb $before -> $after"
    updated=1
  fi
done <<EOF
$JAVA_HOMES
EOF

if [ "$updated" -eq 1 ]; then
  echo
  echo "Restart every JVM running on an updated JDK: running JVMs keep their old zone rules."
fi
exit "$rc"
