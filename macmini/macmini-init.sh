#!/usr/bin/env bash
#
# macmini-init.sh — audit (default) or apply (--apply) the "always-on server"
#                   baseline on a Mac mini that hosts VMs or services.
#
# The baseline is: never sleep, never drop the NIC, never auto-install updates
# (so never reboot on its own), come back after a power cut, and have a hypervisor
# installed. Every item is read from the
# host first and only changed when it differs — running --apply twice is a no-op.
#
# Usage: ./macmini-init.sh [options]        run ./macmini-init.sh --help for details
#
# Portable: bash 3.2+ (macOS stock bash), no dependencies. macOS 12 or newer.

set -uo pipefail

VERSION="1.0.0"

MODE="check"          # check | apply
HOSTNAME_WANT=""
TZ_WANT=""
FIREWALL_WANT=""      # "" | on | off
AUTOLOGIN_USER=""
INSTALL_VM=""         # "" | parallels | vmware-fusion | utm
KEEP_WIFI=0
KEEP_SECURITY=0       # keep ConfigDataInstall / CriticalUpdateInstall on
NO_DOWNLOAD=0         # also turn automatic download off (default: check + download, never install)
NO_BANNER=0           # do not manage the login-window banner
REMOTE=""
QUIET=0
REMOTE_ARGS=()        # options forwarded to --remote hosts (everything but --remote)

usage() {
  cat <<'USAGE'
macmini-init.sh — always-on server baseline for a Mac mini: check it, or apply it

Usage: ./macmini-init.sh [options]              audit only, changes nothing (default)
       ./macmini-init.sh --apply [options]      fix every item that differs (asks for sudo)

What it checks / sets:
  power        pmset: sleep, disksleep, displaysleep, powernap, standby = 0;
               autorestart (after power loss), womp (wake on LAN), ttyskeepawake,
               tcpkeepalive = 1
  keepawake    a per-user LaunchAgent running `caffeinate -dimsu` forever
  screensaver  idle time 0
  updates      macOS updates: check + download ON, install OFF (no unattended
               reboots); security responses OFF; App Store auto-update OFF
  wifi         Wi-Fi radio off (the server lives on Ethernet)
  ethernet     primary interface has a static IP (warns on DHCP; not changed)
  ssh          Remote Login on
  banner       login window shows "<hostname> | <ip>" so a console shows which box it is
  hostname     HostName / LocalHostName / ComputerName (only with --hostname)
  timezone     system time zone (only with --timezone)
  firewall     application firewall (only with --firewall)
  autologin    automatic login for the VM owner (only with --autologin)
  filevault    reported; On blocks auto-login and unattended reboots
  hypervisor   Parallels / VMware Fusion / UTM / OrbStack present (install with --install-vm)
  updaters     third-party auto-updaters (Google Keystone etc.) — reported only

Options:
  --apply                   Change what differs. Without it the script only reports.
  --hostname <name>         Expected host name; set with --apply
  --timezone <IANA>         Expected time zone, e.g. America/Phoenix; set with --apply
  --firewall on|off         Expected application firewall state; set with --apply
  --autologin <user>        Expect automatic login for <user>; with --apply prompts for the
                            account password (typed locally, never stored by the script)
  --install-vm <name>       With --apply, `brew install --cask <name>` when no hypervisor
                            is present: parallels | vmware-fusion | utm
  --keep-wifi               Do not expect / turn off Wi-Fi
  --keep-security-updates   Leave XProtect / security-response auto-install on
  --no-auto-download        Also turn automatic download off (default keeps check + download on)
  --no-banner               Do not manage the login-window banner
  --remote <a[,b,...]>      Run on those ssh targets instead (check: script piped over ssh;
                            apply: script copied to the host, run with a tty for sudo)
  -q, --quiet               Only print the summary line per host
  -h, --help                Show this help
  --version                 Show version

Exit codes: 0 = baseline met (or applied), 1 = items differ (check) / a change failed
            (apply) / a remote host unreachable, 2 = usage error or not macOS.
USAGE
}

need_value() { [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)        MODE="apply"; REMOTE_ARGS+=("$1") ;;
    --hostname)     need_value "$@"; HOSTNAME_WANT="$2"; REMOTE_ARGS+=("$1" "$2"); shift ;;
    --hostname=*)   HOSTNAME_WANT="${1#*=}"; REMOTE_ARGS+=("$1") ;;
    --timezone)     need_value "$@"; TZ_WANT="$2"; REMOTE_ARGS+=("$1" "$2"); shift ;;
    --timezone=*)   TZ_WANT="${1#*=}"; REMOTE_ARGS+=("$1") ;;
    --firewall)     need_value "$@"; FIREWALL_WANT="$2"; REMOTE_ARGS+=("$1" "$2"); shift ;;
    --firewall=*)   FIREWALL_WANT="${1#*=}"; REMOTE_ARGS+=("$1") ;;
    --autologin)    need_value "$@"; AUTOLOGIN_USER="$2"; REMOTE_ARGS+=("$1" "$2"); shift ;;
    --autologin=*)  AUTOLOGIN_USER="${1#*=}"; REMOTE_ARGS+=("$1") ;;
    --install-vm)   need_value "$@"; INSTALL_VM="$2"; REMOTE_ARGS+=("$1" "$2"); shift ;;
    --install-vm=*) INSTALL_VM="${1#*=}"; REMOTE_ARGS+=("$1") ;;
    --keep-wifi)    KEEP_WIFI=1; REMOTE_ARGS+=("$1") ;;
    --keep-security-updates) KEEP_SECURITY=1; REMOTE_ARGS+=("$1") ;;
    --no-auto-download) NO_DOWNLOAD=1; REMOTE_ARGS+=("$1") ;;
    --no-banner)    NO_BANNER=1; REMOTE_ARGS+=("$1") ;;
    --remote)       need_value "$@"; REMOTE="$2"; shift ;;
    --remote=*)     REMOTE="${1#*=}" ;;
    -q|--quiet)     QUIET=1; REMOTE_ARGS+=("$1") ;;
    -h|--help)      usage; exit 0 ;;
    --version)      echo "macmini-init.sh $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$FIREWALL_WANT" in ''|on|off) ;; *) echo "--firewall must be on or off" >&2; exit 2 ;; esac
case "$INSTALL_VM" in ''|parallels|vmware-fusion|utm) ;;
  *) echo "--install-vm must be parallels, vmware-fusion or utm" >&2; exit 2 ;; esac

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

N_OK=0; N_FIX=0; N_DONE=0; N_FAIL=0; N_WARN=0

# row <status> <item> <current> [note]
# status: OK | FIX (differs, check mode) | DONE (changed) | FAIL | WARN | INFO
row() {
  local st="$1" item="$2" cur="$3" note="${4:-}" col
  case "$st" in
    OK)   N_OK=$((N_OK+1));     col="$C_OK" ;;
    FIX)  N_FIX=$((N_FIX+1));   col="$C_WARN" ;;
    DONE) N_DONE=$((N_DONE+1)); col="$C_OK" ;;
    FAIL) N_FAIL=$((N_FAIL+1)); col="$C_ERR" ;;
    WARN) N_WARN=$((N_WARN+1)); col="$C_WARN" ;;
    *)    col="$C_DIM" ;;
  esac
  [ "$QUIET" -eq 1 ] && return
  printf "  ${col}%-5s${C_RESET} %-28s %-30s ${C_DIM}%s${C_RESET}\n" "$st" "$item" "$cur" "$note"
}

# ---------------------------------------------------------------------------
# remote mode
# ---------------------------------------------------------------------------
if [ -n "$REMOTE" ]; then
  SELF="$0"
  case "$SELF" in /dev/fd/*|/proc/*) SELF="" ;; esac
  [ -n "$SELF" ] && [ -r "$SELF" ] || {
    echo "--remote needs the script as a file: curl -fsSLO <url>, then bash macmini-init.sh --remote ..." >&2
    exit 2
  }
  FWD=""
  for a in ${REMOTE_ARGS[@]+"${REMOTE_ARGS[@]}"}; do FWD="$FWD $(printf '%q' "$a")"; done
  rc=0
  for host in $(printf '%s' "$REMOTE" | tr ',' ' '); do
    head2 "================ $host ================"
    if [ "$MODE" = "apply" ]; then
      # sudo (and --autologin) need a tty on the far side, so ship the file and run it there
      if scp -q "$SELF" "$host:/tmp/macmini-init.sh" && ssh -t "$host" "bash /tmp/macmini-init.sh$FWD"; then :; else rc=1; fi
      ssh "$host" "rm -f /tmp/macmini-init.sh" 2>/dev/null
    else
      ssh -o BatchMode=yes "$host" "bash -s --$FWD" < "$SELF" || rc=1
    fi
  done
  exit $rc
fi

# ---------------------------------------------------------------------------
# local preconditions
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || { echo "macmini-init.sh only runs on macOS" >&2; exit 2; }
if [ "$(id -u)" -eq 0 ]; then
  echo "Run as the login user (the one that owns the VMs), not as root: per-user items" >&2
  echo "(keep-awake agent, screen saver) must land in that user's domain. sudo is used inside." >&2
  exit 2
fi

SUDO_OK=0
if [ "$MODE" = "apply" ]; then
  if sudo -n true 2>/dev/null; then SUDO_OK=1
  elif [ -t 0 ]; then
    say "${C_DIM}--apply needs administrator rights; sudo will ask for your password.${C_RESET}"
    sudo -v && SUDO_OK=1
  fi
  [ "$SUDO_OK" -eq 1 ] || { echo "cannot obtain sudo (no tty?) — run interactively or via --remote" >&2; exit 1; }
fi

# run <cmd...> : apply-mode helper; records DONE/FAIL for the current item
run()  { "$@" >/dev/null 2>&1; }
sudo_run() { sudo "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# header
# ---------------------------------------------------------------------------
OS_VER="$(sw_vers -productVersion 2>/dev/null)"
MODEL="$(sysctl -n hw.model 2>/dev/null)"
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
UP="$(uptime | sed -E 's/.* up ([^,]+(, *[0-9]+:[0-9]+)?),.*/\1/')"
head2 "================ $(hostname -s) — macOS $OS_VER — $MODEL ================"
say "  ${C_DIM}$CHIP, ${MEM_GB} GB, up $UP, mode: $MODE${C_RESET}"

# ---------------------------------------------------------------------------
# 1. power management
# ---------------------------------------------------------------------------
head2 "power (pmset, AC)"
PMSET_AC="$(pmset -g custom 2>/dev/null | awk '/^AC Power:/{p=1;next} /^[A-Za-z]/{p=0} p')"
[ -n "$PMSET_AC" ] || PMSET_AC="$(pmset -g 2>/dev/null)"
pm_get() { printf '%s\n' "$PMSET_AC" | awk -v k="$1" '$1==k{print $2; exit}'; }

# key expected
for spec in "sleep 0" "disksleep 0" "displaysleep 0" "powernap 0" "standby 0" \
            "autorestart 1" "womp 1" "ttyskeepawake 1" "tcpkeepalive 1"; do
  key="${spec% *}"; want="${spec#* }"
  cur="$(pm_get "$key")"
  if [ "$cur" = "$want" ]; then
    row OK "$key" "$cur"
  elif [ -z "$cur" ]; then
    row INFO "$key" "n/a" "not supported on this Mac"
  elif [ "$MODE" = "apply" ]; then
    if sudo_run pmset -a "$key" "$want"; then row DONE "$key" "$cur -> $want"
    else row FAIL "$key" "$cur" "pmset -a $key $want failed"; fi
  else
    row FIX "$key" "$cur" "want $want"
  fi
done

# ---------------------------------------------------------------------------
# 2. keep-awake LaunchAgent
# ---------------------------------------------------------------------------
head2 "keep-awake"
AGENT_LABEL="com.keepawake.caffeinate"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
# no grep -q in pipelines: it closes the pipe early and pipefail reports the SIGPIPE
agent_loaded() { launchctl list 2>/dev/null | grep "[[:space:]]$AGENT_LABEL\$" >/dev/null; }
agent_running() { pgrep -f "caffeinate -dimsu" >/dev/null 2>&1; }

if [ -f "$AGENT_PLIST" ] && agent_loaded && agent_running; then
  row OK "$AGENT_LABEL" "loaded, caffeinate running"
elif [ "$MODE" = "apply" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/caffeinate</string><string>-dimsu</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1
  if run launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" || run launchctl load -w "$AGENT_PLIST"; then
    sleep 1
    if agent_running; then row DONE "$AGENT_LABEL" "installed and running"
    else row WARN "$AGENT_LABEL" "installed, not running yet" "starts at next GUI login"; fi
  else
    row FAIL "$AGENT_LABEL" "plist written, load failed" "no GUI session? log in once"
  fi
else
  if [ -f "$AGENT_PLIST" ]; then row FIX "$AGENT_LABEL" "plist present, not running"
  else row FIX "$AGENT_LABEL" "missing" "caffeinate -dimsu LaunchAgent"; fi
fi

# ---------------------------------------------------------------------------
# 3. screen saver
# ---------------------------------------------------------------------------
head2 "screen saver"
SS_IDLE="$(defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null)"
if [ "$SS_IDLE" = "0" ]; then
  row OK "screensaver idleTime" "0"
elif [ "$MODE" = "apply" ]; then
  if run defaults -currentHost write com.apple.screensaver idleTime -int 0; then row DONE "screensaver idleTime" "${SS_IDLE:-default} -> 0"
  else row FAIL "screensaver idleTime" "${SS_IDLE:-default}"; fi
else
  row FIX "screensaver idleTime" "${SS_IDLE:-default (20 min)}" "want 0"
fi

# ---------------------------------------------------------------------------
# 4. software updates
# ---------------------------------------------------------------------------
head2 "software updates"
SU_DOMAIN="/Library/Preferences/com.apple.SoftwareUpdate"
CO_DOMAIN="/Library/Preferences/com.apple.commerce"
su_key() {   # <domain> <key> <label> <want 0|1>
  local dom="$1" key="$2" label="$3" want="$4" cur wantw curw
  cur="$(defaults read "$dom" "$key" 2>/dev/null)"
  [ "$want" = "1" ] && wantw="on" || wantw="off"
  case "$cur" in 1) curw="on" ;; 0) curw="off" ;; *) curw="unset" ;; esac
  if [ "$cur" = "$want" ]; then
    row OK "$label" "$curw"
  elif [ "$MODE" = "apply" ]; then
    if sudo_run defaults write "$dom" "$key" -bool "$( [ "$want" = 1 ] && echo true || echo false )"; then row DONE "$label" "$curw -> $wantw"
    else row FAIL "$label" "$curw"; fi
  else
    row FIX "$label" "$curw" "want $wantw"
  fi
}
# Check + download so patches are staged and visible, but never install: an
# unattended install reboots the Mac and takes every VM on it down.
# AutomaticCheckEnabled is often absent from the plist while checking is on (the OS
# default), so ask softwareupdate itself rather than trusting the key.
SU_SCHED="$(softwareupdate --schedule 2>/dev/null)"
case "$SU_SCHED" in
  *"turned on"*)  row OK "check for updates" "on" ;;
  *"turned off"*)
    if [ "$MODE" = "apply" ]; then
      if sudo_run softwareupdate --schedule on; then row DONE "check for updates" "off -> on"
      else row FAIL "check for updates" "off"; fi
    else row FIX "check for updates" "off" "want on"; fi ;;
  *) row INFO "check for updates" "unknown" "softwareupdate --schedule gave no answer" ;;
esac
su_key "$SU_DOMAIN" AutomaticDownload                "download updates"           $(( 1 - NO_DOWNLOAD ))
su_key "$SU_DOMAIN" AutomaticallyInstallMacOSUpdates "install macOS updates"      0
if [ "$KEEP_SECURITY" -eq 1 ]; then
  row INFO "security responses" "kept on" "--keep-security-updates"
else
  su_key "$SU_DOMAIN" ConfigDataInstall     "install system data files" 0
  su_key "$SU_DOMAIN" CriticalUpdateInstall "install security responses" 0
fi
su_key "$CO_DOMAIN" AutoUpdate "App Store auto-update" 0
LAST_INSTALL="$(defaults read "$SU_DOMAIN" InstallDateDictionary 2>/dev/null | grep -E '^ +"?[0-9A-Za-z]+"? = ' | sort -t'"' -k2 | tail -1 \
  | sed -E 's/^ *"?([0-9A-Za-z]+)"? = "([^"]+)";.*/\1 on \2/')"
[ -n "$LAST_INSTALL" ] && row INFO "last OS update installed" "$LAST_INSTALL"

# ---------------------------------------------------------------------------
# 5. network
# ---------------------------------------------------------------------------
head2 "network"
HW_PORTS="$(networksetup -listallhardwareports 2>/dev/null)"
WIFI_DEV="$(printf '%s\n' "$HW_PORTS" | awk '/^Hardware Port: Wi-Fi/{getline; print $2; exit}')"
if [ "$KEEP_WIFI" -eq 1 ]; then
  row INFO "wi-fi" "kept" "--keep-wifi"
elif [ -z "$WIFI_DEV" ]; then
  row INFO "wi-fi" "no Wi-Fi interface"
else
  WIFI_STATE="$(networksetup -getairportpower "$WIFI_DEV" 2>/dev/null | awk '{print $NF}')"
  if [ "$WIFI_STATE" = "Off" ]; then
    row OK "wi-fi ($WIFI_DEV)" "off"
  elif [ "$MODE" = "apply" ]; then
    if run networksetup -setairportpower "$WIFI_DEV" off || sudo_run networksetup -setairportpower "$WIFI_DEV" off; then
      row DONE "wi-fi ($WIFI_DEV)" "on -> off"
    else row FAIL "wi-fi ($WIFI_DEV)" "$WIFI_STATE"; fi
  else
    row FIX "wi-fi ($WIFI_DEV)" "${WIFI_STATE:-unknown}" "want off"
  fi
fi

PRI_IP=""; PRI_PORT=""
PRI_DEV="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [ -n "$PRI_DEV" ]; then
  PRI_PORT="$(printf '%s\n' "$HW_PORTS" | awk -v d="$PRI_DEV" '/^Hardware Port:/{p=substr($0,16)} /^Device:/ && $2==d {print p; exit}')"
  PRI_IP="$(ipconfig getifaddr "$PRI_DEV" 2>/dev/null)"
  PRI_CFG="$(networksetup -getinfo "$PRI_PORT" 2>/dev/null | head -1)"
  case "$PRI_CFG" in
    Manual*) row OK "primary ($PRI_DEV, $PRI_PORT)" "${PRI_IP:-?} static" ;;
    DHCP*)   row WARN "primary ($PRI_DEV, $PRI_PORT)" "${PRI_IP:-?} DHCP" "use a static IP or a DHCP reservation" ;;
    *)       row INFO "primary ($PRI_DEV)" "${PRI_IP:-?}" "$PRI_CFG" ;;
  esac
  [ "$PRI_DEV" = "$WIFI_DEV" ] && row WARN "primary is Wi-Fi" "$PRI_DEV" "plug in Ethernet before turning Wi-Fi off"
else
  row WARN "primary interface" "no default route"
fi

if launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
  row OK "remote login (ssh)" "on"
elif [ "$MODE" = "apply" ]; then
  if sudo_run systemsetup -setremotelogin on; then row DONE "remote login (ssh)" "off -> on"
  else row FAIL "remote login (ssh)" "off" "System Settings > General > Sharing"; fi
else
  row FIX "remote login (ssh)" "off" "want on"
fi

# login-window banner: "<hostname> | <ip>" — tells whoever is at the console which box this is
LW_DOMAIN="/Library/Preferences/com.apple.loginwindow"
if [ "$NO_BANNER" -eq 1 ]; then
  row INFO "login banner" "not managed" "--no-banner"
else
  BANNER_HOST="${HOSTNAME_WANT:-$(hostname -s)}"
  BANNER_WANT="$BANNER_HOST | ${PRI_IP:-no-ip}"
  BANNER_CUR="$(defaults read "$LW_DOMAIN" LoginwindowText 2>/dev/null)"
  if [ "$BANNER_CUR" = "$BANNER_WANT" ]; then
    row OK "login banner" "$BANNER_CUR"
  elif [ "$MODE" = "apply" ]; then
    if sudo_run defaults write "$LW_DOMAIN" LoginwindowText -string "$BANNER_WANT"; then row DONE "login banner" "${BANNER_CUR:-(none)} -> $BANNER_WANT"
    else row FAIL "login banner" "${BANNER_CUR:-(none)}"; fi
  else
    row FIX "login banner" "${BANNER_CUR:-(none)}" "want \"$BANNER_WANT\""
  fi
fi

# ---------------------------------------------------------------------------
# 6. identity: hostname, time zone
# ---------------------------------------------------------------------------
head2 "identity"
HN="$(scutil --get HostName 2>/dev/null)"; LHN="$(scutil --get LocalHostName 2>/dev/null)"; CN="$(scutil --get ComputerName 2>/dev/null)"
if [ -n "$HOSTNAME_WANT" ]; then
  if [ "$HN" = "$HOSTNAME_WANT" ] && [ "$LHN" = "$HOSTNAME_WANT" ] && [ "$CN" = "$HOSTNAME_WANT" ]; then
    row OK "hostname" "$HOSTNAME_WANT"
  elif [ "$MODE" = "apply" ]; then
    if sudo_run scutil --set HostName "$HOSTNAME_WANT" && sudo_run scutil --set LocalHostName "$HOSTNAME_WANT" \
       && sudo_run scutil --set ComputerName "$HOSTNAME_WANT"; then
      row DONE "hostname" "${HN:-${LHN:-?}} -> $HOSTNAME_WANT"
    else row FAIL "hostname" "${HN:-${LHN:-?}}"; fi
  else
    row FIX "hostname" "${HN:-(unset)} / $LHN / $CN" "want $HOSTNAME_WANT"
  fi
else
  row INFO "hostname" "${HN:-(unset)} / $LHN" "pass --hostname to enforce"
fi

TZ_CUR="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
if [ -n "$TZ_WANT" ]; then
  if [ "$TZ_CUR" = "$TZ_WANT" ]; then
    row OK "time zone" "$TZ_CUR"
  elif [ "$MODE" = "apply" ]; then
    if sudo_run systemsetup -settimezone "$TZ_WANT"; then row DONE "time zone" "${TZ_CUR:-?} -> $TZ_WANT"
    else row FAIL "time zone" "${TZ_CUR:-?}" "systemsetup -settimezone $TZ_WANT failed"; fi
  else
    row FIX "time zone" "${TZ_CUR:-?}" "want $TZ_WANT"
  fi
else
  row INFO "time zone" "${TZ_CUR:-?}" "pass --timezone to enforce"
fi

# ---------------------------------------------------------------------------
# 7. firewall, auto-login, FileVault
# ---------------------------------------------------------------------------
head2 "security"
FW_BIN=/usr/libexec/ApplicationFirewall/socketfilterfw
FW_CUR="off"; "$FW_BIN" --getglobalstate 2>/dev/null | grep "enabled" >/dev/null && FW_CUR="on"
if [ -n "$FIREWALL_WANT" ]; then
  if [ "$FW_CUR" = "$FIREWALL_WANT" ]; then
    row OK "application firewall" "$FW_CUR"
  elif [ "$MODE" = "apply" ]; then
    if sudo_run "$FW_BIN" --setglobalstate "$FIREWALL_WANT"; then row DONE "application firewall" "$FW_CUR -> $FIREWALL_WANT"
    else row FAIL "application firewall" "$FW_CUR"; fi
  else
    row FIX "application firewall" "$FW_CUR" "want $FIREWALL_WANT"
  fi
else
  row INFO "application firewall" "$FW_CUR" "pass --firewall on|off to enforce"
fi

FV="$(fdesetup status 2>/dev/null | head -1)"
case "$FV" in
  *"is Off"*) row OK "FileVault" "off" ;;
  *"is On"*)  row WARN "FileVault" "on" "blocks auto-login and unattended reboot" ;;
  *)          row INFO "FileVault" "${FV:-unknown}" ;;
esac

AL_USER="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)"
if [ -n "$AUTOLOGIN_USER" ]; then
  if [ "$AL_USER" = "$AUTOLOGIN_USER" ] && [ -e /etc/kcpassword ]; then
    row OK "auto-login" "$AL_USER"
  elif [ "$MODE" = "apply" ]; then
    if [ -t 0 ]; then
      printf "  password for %s (for sysadminctl -autologin, not stored): " "$AUTOLOGIN_USER"
      read -rs AL_PW; echo
      if printf '%s' "$AL_PW" | sudo sysadminctl -autologin set -userName "$AUTOLOGIN_USER" -password - >/dev/null 2>&1; then
        row DONE "auto-login" "${AL_USER:-off} -> $AUTOLOGIN_USER"
      else row FAIL "auto-login" "${AL_USER:-off}" "sysadminctl refused (wrong password / FileVault on?)"; fi
      unset AL_PW
    else
      row FAIL "auto-login" "${AL_USER:-off}" "needs a tty to read the password"
    fi
  else
    row FIX "auto-login" "${AL_USER:-off}" "want $AUTOLOGIN_USER"
  fi
else
  if [ -n "$AL_USER" ]; then row INFO "auto-login" "$AL_USER"
  else row WARN "auto-login" "off" "VMs set to start at login will not come back after a reboot; see --autologin"; fi
fi

# ---------------------------------------------------------------------------
# 8. hypervisor
# ---------------------------------------------------------------------------
head2 "hypervisor"
app_ver() { defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null; }
FOUND=""
for app in "Parallels Desktop" "VMware Fusion" "UTM" "OrbStack" "VirtualBox"; do
  p="/Applications/$app.app"
  [ -d "$p" ] && { FOUND="$FOUND$app $(app_ver "$p"); "; }
done
if [ -n "$FOUND" ]; then
  row OK "installed" "${FOUND%; }"
elif [ "$MODE" = "apply" ] && [ -n "$INSTALL_VM" ]; then
  BREW="$(command -v brew 2>/dev/null || ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null | head -1)"
  if [ -z "$BREW" ]; then
    row FAIL "install $INSTALL_VM" "Homebrew missing" "install brew first, or install the app by hand"
  elif "$BREW" install --cask "$INSTALL_VM" >/dev/null 2>&1; then
    row DONE "install $INSTALL_VM" "installed via brew" "open it once to finish setup / license"
  else
    row FAIL "install $INSTALL_VM" "brew install --cask $INSTALL_VM failed"
  fi
else
  row FIX "installed" "none" "install Parallels / VMware Fusion / UTM (see --install-vm)"
fi
if [ -d "/Applications/Parallels Desktop.app" ]; then
  PRLCTL="/Applications/Parallels Desktop.app/Contents/MacOS/prlctl"
  "$PRLCTL" list -a 2>/dev/null | tail -n +2 | while read -r _ st _ name; do
    row INFO "parallels vm" "$name" "$st"
  done
fi
if [ -d "/Applications/VMware Fusion.app" ]; then
  VMRUN="/Applications/VMware Fusion.app/Contents/Library/vmrun"
  n="$("$VMRUN" list 2>/dev/null | head -1 | awk '{print $NF}')"
  row INFO "vmware running vms" "${n:-0}"
fi

# ---------------------------------------------------------------------------
# 9. third-party auto-updaters (report only)
# ---------------------------------------------------------------------------
head2 "third-party updaters"
UPD="$(ls "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons 2>/dev/null \
      | grep -iE 'keystone|GoogleUpdater|sparkle|autoupdate|updater' | sort -u | tr '\n' ' ')"
if [ -n "$UPD" ]; then row WARN "launch agents" "$UPD" "auto-updaters; remove or ignore"
else row OK "launch agents" "none found"; fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
echo
if [ "$MODE" = "apply" ]; then
  if [ "$N_FAIL" -eq 0 ]; then
    printf "${C_OK}%s: applied — %d changed, %d already ok, %d warnings, %d failed${C_RESET}\n" "$(hostname -s)" "$N_DONE" "$N_OK" "$N_WARN" "$N_FAIL"
    [ "$N_DONE" -gt 0 ] && say "  ${C_DIM}re-run without --apply to verify; a reboot is not required${C_RESET}"
    exit 0
  else
    printf "${C_ERR}%s: applied with errors — %d changed, %d already ok, %d warnings, %d failed${C_RESET}\n" "$(hostname -s)" "$N_DONE" "$N_OK" "$N_WARN" "$N_FAIL"
    exit 1
  fi
else
  if [ "$N_FIX" -eq 0 ]; then
    printf "${C_OK}%s: baseline met — %d ok, %d warnings${C_RESET}\n" "$(hostname -s)" "$N_OK" "$N_WARN"
    exit 0
  else
    printf "${C_WARN}%s: %d items differ, %d ok, %d warnings — run again with --apply${C_RESET}\n" "$(hostname -s)" "$N_FIX" "$N_OK" "$N_WARN"
    exit 1
  fi
fi
