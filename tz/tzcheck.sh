#!/usr/bin/env bash
#
# tzcheck.sh — report the tz database version of a host and prove, from the host's
#              own data, what a given zone actually does in a given autumn.
#
# Written for the Alberta / America/Edmonton change: from 2026-11-01 the zone stays
# on -06:00 permanently (as CST) instead of falling back to MST -07:00. Hosts whose
# tzdata predates that change still shift their clocks back one hour on 2026-11-01.
# Observed boundary: tzdata 2026b = old rule (falls back), 2026c = new rule (no change).
#
# The script asserts nothing about versions — every verdict is computed from the
# host's own zoneinfo by probing offsets and bisecting for real transitions.
#
# Usage: ./tzcheck.sh [options]        run ./tzcheck.sh --help for details
#
# Portable: bash 3.2+, GNU or BSD date, no python required.

set -uo pipefail

VERSION="1.0.0"

ZONE="America/Edmonton"
YEAR=2026
DO_RUNTIMES=1
EXPECT_NO_FALLBACK=0
REMOTE=""
MYSQL_ARGS=""
QUIET=0
EMIT_RESULT=0      # internal: print the machine-readable result line (used by --remote)

usage() {
  cat <<'USAGE'
tzcheck.sh — tz database version + real transition rules for a zone

Usage: ./tzcheck.sh [options]

Options:
  --zone <IANA>          Zone to inspect (default: America/Edmonton)
  --year <YYYY>          Year to inspect (default: 2026)
  --remote <a[,b,...]>   Also run this script on those ssh targets and summarise
  --mysql <args>         Also check MySQL: passed verbatim to the mysql client,
                         e.g. --mysql "-h dbhost -u root -p'secret'"
  --no-runtimes          Skip the java / python / node cross-checks
  --expect-no-fallback   Exit 1 if the zone still falls back that autumn (CI mode)
  -q, --quiet            Only print the verdict line per host
  -h, --help             Show this help
  --version              Show version

Exit codes: 0 = as expected, 1 = fall-back still happens (with --expect-no-fallback)
            or hosts disagree, 2 = usage / lookup error.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --zone)   [ $# -ge 2 ] || { echo "--zone needs a value" >&2; exit 2; }; ZONE="$2"; shift ;;
    --zone=*) ZONE="${1#*=}" ;;
    --year)   [ $# -ge 2 ] || { echo "--year needs a value" >&2; exit 2; }; YEAR="$2"; shift ;;
    --year=*) YEAR="${1#*=}" ;;
    --remote)   [ $# -ge 2 ] || { echo "--remote needs a value" >&2; exit 2; }; REMOTE="$2"; shift ;;
    --remote=*) REMOTE="${1#*=}" ;;
    --mysql)    [ $# -ge 2 ] || { echo "--mysql needs a value" >&2; exit 2; }; MYSQL_ARGS="$2"; shift ;;
    --mysql=*)  MYSQL_ARGS="${1#*=}" ;;
    --no-runtimes)       DO_RUNTIMES=0 ;;
    --expect-no-fallback) EXPECT_NO_FALLBACK=1 ;;
    -q|--quiet) QUIET=1 ;;
    --emit-result) EMIT_RESULT=1 ;;
    -h|--help)  usage; exit 0 ;;
    --version)  echo "tzcheck.sh $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$YEAR" in
  ''|*[!0-9]*) echo "invalid year: $YEAR" >&2; exit 2 ;;
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
kv()    { [ "$QUIET" -eq 1 ] || printf "  %-26s %s\n" "$1" "$2"; }
has()   { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# date primitives (GNU and BSD)
# ---------------------------------------------------------------------------
DATE_GNU=0
date --version >/dev/null 2>&1 && DATE_GNU=1

# local_to_epoch "<YYYY-mm-dd HH:MM:SS>" <zone>
local_to_epoch() {
  if [ "$DATE_GNU" -eq 1 ]; then
    TZ="$2" date -d "$1" +%s 2>/dev/null
  else
    TZ="$2" date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null
  fi
}

# fmt_epoch <epoch> <zone> <format>
fmt_epoch() {
  if [ "$DATE_GNU" -eq 1 ]; then
    TZ="$2" date -d "@$1" +"$3" 2>/dev/null
  else
    TZ="$2" date -r "$1" +"$3" 2>/dev/null
  fi
}

# BSD date(1) prints %z as the CURRENT offset even when rendering another instant,
# so never trust %z here: derive the offset by rendering the wall clock in the zone
# and reading that same wall clock back as UTC. Works identically on GNU and BSD.
offset_at() {   # <epoch> <zone> -> offset in seconds
  local wall as_utc
  wall="$(fmt_epoch "$1" "$2" '%Y-%m-%d %H:%M:%S')"
  [ -n "$wall" ] || { echo 0; return 1; }
  as_utc="$(local_to_epoch "$wall" UTC)"
  [ -n "$as_utc" ] || { echo 0; return 1; }
  echo $(( as_utc - $1 ))
}

abbrev_at()  { fmt_epoch "$1" "$2" '%Z'; }

fmt_offset() {  # <seconds> -> +/-HH:MM
  local s="$1" sign="+" h m
  if [ "$s" -lt 0 ]; then sign="-"; s=$(( -s )); fi
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 ))
  printf "%s%02d:%02d" "$sign" "$h" "$m"
}

stamp_at() {    # <epoch> <zone> -> "YYYY-mm-dd HH:MM:SS ABBR +/-HH:MM"
  printf "%s %s %s" "$(fmt_epoch "$1" "$2" '%Y-%m-%d %H:%M:%S')" \
                    "$(abbrev_at "$1" "$2")" "$(fmt_offset "$(offset_at "$1" "$2")")"
}

# state_at <epoch> <zone> -> "<offset seconds> <abbreviation>"
# Both halves matter: Alberta 2026 keeps the offset and only changes MDT -> CST,
# which is precisely the "the clocks do not move" case we are looking for.
state_at() { echo "$(offset_at "$1" "$2") $(abbrev_at "$1" "$2")"; }

# find_transition <zone> <lo_epoch> <hi_epoch>
# assumes the state differs between lo and hi; echoes the first epoch in the new state
find_transition() {
  local zone="$1" lo="$2" hi="$3" mid s_lo s_mid
  s_lo="$(state_at "$lo" "$zone")"
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    s_mid="$(state_at "$mid" "$zone")"
    if [ "$s_mid" = "$s_lo" ]; then lo="$mid"; else hi="$mid"; fi
  done
  echo "$hi"
}

# ---------------------------------------------------------------------------
# host / tzdata facts
# ---------------------------------------------------------------------------
host_line() {
  local os="unknown"
  case "$(uname -s)" in
    Darwin) os="macOS $(sw_vers -productVersion 2>/dev/null)" ;;
    Linux)
      if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        os="$(. /etc/os-release; echo "${PRETTY_NAME:-$ID}")"
      else
        os="Linux"
      fi ;;
    *) os="$(uname -s)" ;;
  esac
  echo "$(hostname 2>/dev/null || echo host) — $os — $(uname -m)"
}

TZDATA_VER="unknown"
TZDATA_SRC="none"

# sets TZDATA_VER / TZDATA_SRC from the first source that answers
detect_tzdata_version() {
  local v="" f
  if [ -r /usr/share/zoneinfo/+VERSION ]; then
    v="$(head -1 /usr/share/zoneinfo/+VERSION 2>/dev/null)"
    if [ -n "$v" ]; then
      TZDATA_VER="$v"; TZDATA_SRC="/usr/share/zoneinfo/+VERSION"; return 0
    fi
  fi
  for f in /usr/share/zoneinfo/tzdata.zi /usr/lib/zoneinfo/tzdata.zi; do
    if [ -r "$f" ]; then
      v="$(awk '/^# *version/ {print $3; exit}' "$f" 2>/dev/null)"
      if [ -n "$v" ]; then
        TZDATA_VER="$v"; TZDATA_SRC="$f"; return 0
      fi
    fi
  done
  if has dpkg-query; then
    v="$(dpkg-query -W -f '${Version}' tzdata 2>/dev/null)"
    if [ -n "$v" ]; then
      TZDATA_VER="$v"; TZDATA_SRC="dpkg"; return 0
    fi
  fi
  if has rpm; then
    v="$(rpm -q --qf '%{VERSION}-%{RELEASE}' tzdata 2>/dev/null)"
    if [ -n "$v" ]; then
      TZDATA_VER="$v"; TZDATA_SRC="rpm"; return 0
    fi
  fi
  if has apk; then
    v="$(apk info -v tzdata 2>/dev/null | head -1)"
    if [ -n "$v" ]; then
      TZDATA_VER="$v"; TZDATA_SRC="apk"; return 0
    fi
  fi
  return 0
}

zone_file() {
  local z="$1" f
  for f in "/usr/share/zoneinfo/$z" "/usr/lib/zoneinfo/$z" "/var/db/timezone/zoneinfo/$z"; do
    if [ -r "$f" ]; then
      echo "$f"; return 0
    fi
  done
  return 1
}

system_zone() {
  local z=""
  if has timedatectl; then
    z="$(timedatectl show -p Timezone --value 2>/dev/null)"
  fi
  if [ -z "$z" ] && [ -r /etc/timezone ]; then
    z="$(head -1 /etc/timezone 2>/dev/null)"
  fi
  if [ -z "$z" ] && [ -L /etc/localtime ]; then
    z="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
  fi
  [ -n "$z" ] && echo "$z" || echo "unknown"
}

# ---------------------------------------------------------------------------
# the actual analysis
# ---------------------------------------------------------------------------
VERDICT=""          # NO-FALLBACK | FALLBACK | NO-ZONE | ERROR
VERDICT_TEXT=""
NOV_OFFSET=""

analyse_zone() {
  local zone="$1" year="$2"
  local zf t_start t_end i probe prev_epoch prev_off cur_off tr n_tr=0
  local months="01 02 03 04 05 06 07 08 09 10 11 12"

  if ! zf="$(zone_file "$zone")"; then
    # date silently falls back to UTC for an unknown zone — catch that
    VERDICT="NO-ZONE"
    VERDICT_TEXT="zone file for $zone not found (tzdata not installed?)"
    return 1
  fi

  t_start="$(local_to_epoch "$year-01-01 00:00:00" UTC)"
  t_end="$(local_to_epoch "$((year + 1))-01-01 00:00:00" UTC)"
  if [ -z "$t_start" ] || [ -z "$t_end" ]; then
    VERDICT="ERROR"; VERDICT_TEXT="this host's date(1) could not parse the probe timestamps"
    return 1
  fi

  head2 "$zone — transitions in $year (bisected from this host's own data)"
  prev_epoch="$t_start"
  prev_off="$(state_at "$prev_epoch" "$zone")"
  for i in $months; do
    if [ "$i" = "12" ]; then
      probe="$t_end"
    else
      probe="$(local_to_epoch "$year-$(printf '%02d' $((10#$i + 1)))-01 00:00:00" UTC)"
    fi
    cur_off="$(state_at "$probe" "$zone")"
    if [ "$cur_off" != "$prev_off" ]; then
      tr="$(find_transition "$zone" "$prev_epoch" "$probe")"
      n_tr=$((n_tr + 1))
      local before after delta
      before="$(stamp_at $((tr - 1)) "$zone")"
      after="$(stamp_at "$tr" "$zone")"
      delta=$(( $(offset_at "$tr" "$zone") - $(offset_at $((tr - 1)) "$zone") ))
      local what
      if [ "$delta" -eq 0 ]; then
        what="${C_OK}clocks do NOT move${C_RESET} — label/DST flag only ($(abbrev_at $((tr - 1)) "$zone") -> $(abbrev_at "$tr" "$zone"))"
      else
        what="clocks move $(printf '%+d' $((delta / 60)))min"
      fi
      say "  $(printf '%-8s' "#$n_tr")last: $before"
      say "          next: $after"
      say "          UTC : $(fmt_epoch "$tr" UTC '%Y-%m-%d %H:%M:%S UTC')   $what"
    fi
    prev_epoch="$probe"; prev_off="$cur_off"
  done
  [ "$n_tr" -eq 0 ] && say "  ${C_DIM}no transitions at all in $year${C_RESET}"

  # ---- offsets around the autumn window --------------------------------
  local e_oct e_nov e_dec e_jan o_oct o_nov o_dec o_jan
  e_oct="$(local_to_epoch "$year-10-15 12:00:00" "$zone")"
  e_nov="$(local_to_epoch "$year-11-15 12:00:00" "$zone")"
  e_dec="$(local_to_epoch "$year-12-15 12:00:00" "$zone")"
  e_jan="$(local_to_epoch "$((year + 1))-01-15 12:00:00" "$zone")"
  o_oct="$(offset_at "$e_oct" "$zone")"; o_nov="$(offset_at "$e_nov" "$zone")"
  o_dec="$(offset_at "$e_dec" "$zone")"; o_jan="$(offset_at "$e_jan" "$zone")"
  NOV_OFFSET="$(fmt_offset "$o_nov")"

  head2 "Offsets around the $year autumn window"
  kv "$year-10-15 12:00" "$(fmt_offset "$o_oct") $(abbrev_at "$e_oct" "$zone")"
  kv "$year-11-15 12:00" "$(fmt_offset "$o_nov") $(abbrev_at "$e_nov" "$zone")"
  kv "$year-12-15 12:00" "$(fmt_offset "$o_dec") $(abbrev_at "$e_dec" "$zone")"
  kv "$((year + 1))-01-15 12:00" "$(fmt_offset "$o_jan") $(abbrev_at "$e_jan" "$zone")"

  # a fixed UTC instant, rendered locally — what an application would actually show
  local e_fixed
  e_fixed="$(local_to_epoch "$year-11-15 19:00:00" UTC)"
  kv "$year-11-15 19:00 UTC" "-> $(stamp_at "$e_fixed" "$zone")"

  # ---- verdict ---------------------------------------------------------
  local d_sec
  d_sec=$(( o_nov - o_oct ))
  if [ "$d_sec" -eq 0 ]; then
    VERDICT="NO-FALLBACK"
    VERDICT_TEXT="no autumn clock change in $year — stays on $(fmt_offset "$o_nov") through November ($(abbrev_at "$e_nov" "$zone"))"
  else
    VERDICT="FALLBACK"
    VERDICT_TEXT="clocks still move $(printf '%+d' $((d_sec / 60)))min that autumn — November sits at $(fmt_offset "$o_nov") ($(abbrev_at "$e_nov" "$zone"))"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# runtime cross-checks
# ---------------------------------------------------------------------------
check_runtimes() {
  local zone="$1" year="$2"
  [ "$DO_RUNTIMES" -eq 1 ] || return 0
  head2 "Runtime cross-checks (each carries its own tz copy)"

  if has python3; then
    python3 - "$zone" "$year" <<'PY' 2>/dev/null || kv "python3" "zoneinfo unavailable"
import sys
zone, year = sys.argv[1], int(sys.argv[2])
try:
    from zoneinfo import ZoneInfo
    import datetime, sys as s
    tz = ZoneInfo(zone)
    nov = datetime.datetime(year, 11, 15, 12, tzinfo=tz)
    oct_ = datetime.datetime(year, 10, 15, 12, tzinfo=tz)
    src = "OS db"
    try:
        import tzdata
        src = "tzdata module %s (may shadow OS db)" % tzdata.IANA_VERSION
    except ImportError:
        pass
    print("  %-26s %s -> %s %s   (%s)" % ("python3 " + ".".join(map(str, s.version_info[:3])),
          "Nov 15", nov.strftime("%z"), nov.tzname(),
          "no autumn change" if nov.utcoffset() == oct_.utcoffset() else "falls back"))
    print("  %-26s %s" % ("python3 tz source", src))
except Exception as e:
    print("  %-26s %s" % ("python3", e))
PY
  fi

  if has java; then
    local jver tmpd
    jver="$(java -version 2>&1 | head -1 | sed 's/.*version "\([^"]*\)".*/\1/')"
    tmpd="$(mktemp -d 2>/dev/null || echo /tmp/tzcheck.$$)"
    mkdir -p "$tmpd"
    cat > "$tmpd/TzProbe.java" <<'JAVA'
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
    try {
      db = ZoneRulesProvider.getVersions(zone).lastKey();
    } catch (Exception e) {
      db = "?";
    }
    System.out.println(db + "|" + nov + "|" + (oct.equals(nov) ? "no autumn change" : "falls back"));
  }
}
JAVA
    local out
    out="$(java "$tmpd/TzProbe.java" "$zone" "$year" 2>/dev/null | tail -1)"
    if [ -n "$out" ]; then
      kv "java $jver" "tzdb ${out%%|*} — Nov 15 $(echo "$out" | cut -d'|' -f2)  ($(echo "$out" | cut -d'|' -f3))"
    else
      kv "java $jver" "could not run the probe (JRE without javac? try jshell)"
    fi
    rm -rf "$tmpd"
  fi

  if has node; then
    local out
    out="$(node -e '
      const [zone, year] = [process.argv[1], Number(process.argv[2])];
      const f = d => new Intl.DateTimeFormat("en-US", {timeZone: zone, timeZoneName: "longOffset"})
        .formatToParts(d).find(p => p.type === "timeZoneName").value;
      const oct = new Date(Date.UTC(year, 9, 15, 18));
      const nov = new Date(Date.UTC(year, 10, 15, 19));
      console.log(f(nov) + "|" + (f(oct) === f(nov) ? "no autumn change" : "falls back"));
    ' "$zone" "$year" 2>/dev/null)"
    [ -n "$out" ] && kv "node $(node --version 2>/dev/null)" "Nov 15 ${out%%|*}  (${out#*|})"
  fi

  if [ -n "$MYSQL_ARGS" ] && has mysql; then
    local q out
    q="SELECT @@system_time_zone, (SELECT COUNT(*) FROM mysql.time_zone_name),
        CONVERT_TZ('$year-10-15 18:00:00','UTC','$zone'),
        CONVERT_TZ('$year-11-15 19:00:00','UTC','$zone');"
    # shellcheck disable=SC2086
    out="$(eval mysql $MYSQL_ARGS -N -B -e \"\$q\" 2>&1 | tail -1)"
    if [ -n "$out" ]; then
      kv "mysql system_time_zone" "$(echo "$out" | cut -f1)"
      kv "mysql tz tables loaded" "$(echo "$out" | cut -f2) rows in mysql.time_zone_name"
      kv "mysql CONVERT_TZ oct" "$(echo "$out" | cut -f3)"
      kv "mysql CONVERT_TZ nov" "$(echo "$out" | cut -f4)"
      case "$out" in
        *NULL*) say "  ${C_WARN}mysql returned NULL — the zoneinfo tables are not loaded; CONVERT_TZ cannot work${C_RESET}" ;;
      esac
    fi
  fi
}

# ---------------------------------------------------------------------------
# local report
# ---------------------------------------------------------------------------
run_local() {
  local rc=0
  say ""
  printf "${C_HEAD}================ %s ================${C_RESET}\n" "$(host_line)"

  detect_tzdata_version
  head2 "tz database"
  kv "tzdata version" "$TZDATA_VER  ${C_DIM}(from $TZDATA_SRC)${C_RESET}"
  kv "zone file" "$(zone_file "$ZONE" || echo 'NOT FOUND')"
  kv "system timezone" "$(system_zone)"
  kv "now" "$(date '+%Y-%m-%d %H:%M:%S %Z %z')"

  analyse_zone "$ZONE" "$YEAR" || rc=2
  check_runtimes "$ZONE" "$YEAR"

  head2 "Verdict"
  case "$VERDICT" in
    NO-FALLBACK) printf "  ${C_OK}[NO-FALLBACK]${C_RESET} %s\n" "$VERDICT_TEXT" ;;
    FALLBACK)    printf "  ${C_WARN}[FALLBACK]${C_RESET}    %s\n" "$VERDICT_TEXT"
                 printf "  ${C_DIM}correct for a zone that still observes DST; if you expected no change, this host's${C_RESET}\n"
                 printf "  ${C_DIM}tzdata is behind (America/Edmonton: 2026b = old, 2026c = new)${C_RESET}\n" ;;
    NO-ZONE)     printf "  ${C_ERR}[NO-ZONE]${C_RESET}     %s\n" "$VERDICT_TEXT" ;;
    *)           printf "  ${C_ERR}[ERROR]${C_RESET}       %s\n" "$VERDICT_TEXT" ;;
  esac
  if [ "$EXPECT_NO_FALLBACK" -eq 1 ] && [ "$VERDICT" != "NO-FALLBACK" ]; then
    rc=1
  fi
  return $rc
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
TZCHECK-RESULT|$host|?|$ZONE|$YEAR|ERROR|?"
      continue
    fi
    out="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" \
           "bash -s -- --zone '$ZONE' --year '$YEAR' --emit-result $( [ "$DO_RUNTIMES" -eq 0 ] && echo --no-runtimes )" \
           < "$self" 2>&1)"
    echo "$out" | grep -v '^TZCHECK-RESULT|' >&2
    line="$(echo "$out" | grep '^TZCHECK-RESULT|' | tail -1)"
    if [ -z "$line" ]; then
      line="TZCHECK-RESULT|$host|?|$ZONE|$YEAR|UNREACHABLE|?"
    else
      # label the row with the ssh target rather than the remote hostname
      line="TZCHECK-RESULT|$host|$(echo "$line" | cut -d'|' -f3-)"
    fi
    rows="$rows
$line"
  done
  echo "$rows" | grep '^TZCHECK-RESULT|'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
LOCAL_RC=0
run_local || LOCAL_RC=$?

SHORT_HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
LOCAL_ROW="TZCHECK-RESULT|$SHORT_HOST|$TZDATA_VER|$ZONE|$YEAR|$VERDICT|${NOV_OFFSET:-?}"
[ "$EMIT_RESULT" -eq 1 ] && echo "$LOCAL_ROW"

ROWS="$LOCAL_ROW"
if [ -n "$REMOTE" ]; then
  REMOTE_ROWS="$(run_remote)"
  [ -n "$REMOTE_ROWS" ] && ROWS="$ROWS
$REMOTE_ROWS"
fi

ROW_COUNT="$(echo "$ROWS" | grep -c '^TZCHECK-RESULT|')"
if [ "$ROW_COUNT" -gt 1 ]; then
  printf "\n${C_HEAD}================ Fleet summary — %s in %s ================${C_RESET}\n" "$ZONE" "$YEAR"
  printf "  ${C_KEY}%-18s %-24s %-12s %s${C_RESET}\n" "HOST" "TZDATA" "NOV OFFSET" "VERDICT"
  echo "$ROWS" | while IFS='|' read -r _ h v _ _ verdict off; do
    h="$(echo "$h" | cut -c1-18)"
    v="$(echo "$v" | cut -c1-24)"
    case "$verdict" in
      NO-FALLBACK) printf "  %-18s %-24s %-12s ${C_OK}%s${C_RESET}\n" "$h" "$v" "$off" "$verdict" ;;
      FALLBACK)    printf "  %-18s %-24s %-12s ${C_WARN}%s${C_RESET}\n" "$h" "$v" "$off" "$verdict" ;;
      *)           printf "  %-18s %-24s %-12s ${C_ERR}%s${C_RESET}\n" "$h" "$v" "$off" "$verdict" ;;
    esac
  done
fi

DISTINCT="$(echo "$ROWS" | cut -d'|' -f6 | sort -u | grep -v '^$' | tr '\n' ' ')"
EXIT=0
case "$DISTINCT" in
  *FALLBACK*NO-FALLBACK*|*NO-FALLBACK*FALLBACK*)
    printf "\n${C_ERR}Hosts disagree${C_RESET}: some still fall back in %s-11, some do not. Align tzdata before %s-11-01.\n" "$YEAR" "$YEAR"
    EXIT=1 ;;
esac
case "$DISTINCT" in
  *UNREACHABLE*|*NO-ZONE*|*ERROR*) [ "$EXIT" -eq 0 ] && EXIT=1 ;;
esac
if [ "$EXPECT_NO_FALLBACK" -eq 1 ]; then
  case "$DISTINCT" in
    *FALLBACK*) EXIT=1 ;;
  esac
fi
[ "$LOCAL_RC" -eq 2 ] && EXIT=2
exit $EXIT
