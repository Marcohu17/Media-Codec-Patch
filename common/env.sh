#!/system/bin/sh
# common/env.sh - runtime environment probing layer
#
# Contract: anything that cannot be probed returns failure. Callers must
# downgrade failure to "unknown". Never invent a value that was not read.

# Module id resolves from module.prop, so rewriting the package name keeps
# every derived path coherent without touching this file.
if [ -z "$COMMON_DIR" ]; then
  _sd=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
  if [ -d "${_sd}/common" ]; then
    COMMON_DIR="${_sd}/common"
  else
    COMMON_DIR="${_sd}"
  fi
fi
[ -z "$COMMON_DIR" ] && COMMON_DIR="/data/adb/modules/lsposed_stealth/common"
SELF_DIR="$COMMON_DIR"

if [ -z "$MODID" ]; then
  for _mp in "${COMMON_DIR}/../module.prop" "${COMMON_DIR}/module.prop"; do
    [ -f "$_mp" ] || continue
    MODID=$(grep -m1 '^id=' "$_mp" 2>/dev/null | sed -e 's/^id=//' -e 's/[[:space:]]*$//')
    [ -n "$MODID" ] && break
  done
fi
[ -z "$MODID" ] && MODID="lsposed_stealth"

MODDIR="/data/adb/modules/$MODID"
DATA_DIR="/data/adb/$MODID"
STATE_DIR="$DATA_DIR/state"
CONF_DIR="$DATA_DIR/config"
CONF_FILE="$CONF_DIR/settings.conf"
QUAR_DIR="$DATA_DIR/quarantine"
REPORT_FILE="$STATE_DIR/report.json"
AUDIT_LOG="$DATA_DIR/audit.log"
MUTE_LOG="$DATA_DIR/mute.log"
SCRUB_LOG="$DATA_DIR/scrub.log"

# ---------- autoconfig / upstream paths ----------
KNOWN_JSON="$COMMON_DIR/known.json"
UPSTREAM_CACHE="$STATE_DIR/upstream.conf"
UPSTREAM_LOG="$DATA_DIR/upstream.log"
AUTOCONF_DIR="$DATA_DIR/autoconfig"
AUTOCONF_FILE="$AUTOCONF_DIR/last.json"
AUTOCONF_RECORDS="$AUTOCONF_DIR/records.log"
AUTOCONF_SNAP="$AUTOCONF_DIR/baseline.snap"
AUTOCONF_LOG="$DATA_DIR/autoconfig.log"

# ---------- output helpers ----------
mkdir -p "$STATE_DIR" "$CONF_DIR" "$QUAR_DIR" 2>/dev/null

logline() {
  _f="$1"; shift
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  [ -z "$_ts" ] && _ts="?"
  echo "[$_ts] $*" >> "$_f" 2>/dev/null
}

log()      { logline "$AUDIT_LOG" "$@"; }
log_mute() { logline "$MUTE_LOG" "$@"; }
log_scrub(){ logline "$SCRUB_LOG" "$@"; }

die() { echo "$*" >&2; exit 1; }

# ---------- busybox ----------
# KernelSU ships its own busybox; Magisk does too. Try known spots first.
_bb_candidates="/data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/modules/busybox-ndk/system/bin/busybox /system/bin/busybox /system/xbin/busybox"
BB=""
for _p in $_bb_candidates; do
  if [ -x "$_p" ]; then BB="$_p"; break; fi
done
if [ -z "$BB" ]; then
  _w=$(command -v busybox 2>/dev/null)
  [ -n "$_w" ] && BB="$_w"
fi

# bb <applet> <args...> : prefer busybox applet, fall back to system command.
# The applet list is read once and kept in memory. Asking `busybox --list` on
# every call costs a fork plus a grep, and this file is sourced by every panel
# command, so that price gets paid several times per run for one fixed answer.
_BB_APPLETS=""
_bb_has() {
  [ -n "$BB" ] || return 1
  if [ -z "$_BB_APPLETS" ]; then
    _BB_APPLETS=$("$BB" --list 2>/dev/null | tr '\n' ' ')
    [ -z "$_BB_APPLETS" ] && _BB_APPLETS=" "
  fi
  case " $_BB_APPLETS " in
    *" $1 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

bb() {
  _applet="$1"; shift
  if _bb_has "$_applet"; then
    "$BB" "$_applet" "$@"
  else
    "$_applet" "$@"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- ksud ----------
KSUD=""
for _p in /data/adb/ksu/bin/ksud /data/adb/ksud /system/bin/ksud; do
  if [ -x "$_p" ]; then KSUD="$_p"; break; fi
done
[ -z "$KSUD" ] && KSUD=$(command -v ksud 2>/dev/null)

is_ksu() { [ -d /data/adb/ksu ] || [ -n "$KSUD" ]; }

# ---------- kernel form ----------
# KernelSU ships in two shapes. LKM loads kernelsu.ko at boot, so it appears as
# a loaded module. GKI builds compile the driver into the kernel image and leave
# no module entry behind. When neither source can be read the answer stays
# "unknown"; turning a failed read into "built-in" would be a guess dressed up
# as a fact.
KSU_FORM="unknown"
KSU_MOD_NAMES="kernelsu KernelSU kernelsu_lkm sukisu SukiSU"

detect_ksu_form() {
  KSU_FORM="unknown"
  is_ksu || return 0

  for _kn in $KSU_MOD_NAMES; do
    if [ -d "/sys/module/$_kn" ]; then KSU_FORM="lkm"; return 0; fi
  done

  # /proc/modules carries the same list in text. Readable and empty means the
  # driver really does live inside the kernel image.
  if [ -r /proc/modules ]; then
    for _kn in $KSU_MOD_NAMES; do
      if grep -qw "$_kn" /proc/modules 2>/dev/null; then
        KSU_FORM="lkm"; return 0
      fi
    done
    KSU_FORM="builtin"
  fi

  return 0
}

# ---------- susfs ----------
# SUSFS is a kernel patch. It cannot be installed from userspace and it cannot
# be switched on from here. Three independent traces are probed, and "none" is
# only returned when at least one of them could actually be read. Its absence
# is not a failure of this module: every configuration check still runs. What
# is lost is path-level hiding, and the panel says so instead of staying quiet.
SUSFS_STATE="unknown"
SUSFS_EVIDENCE=""

_susfs_hit() {
  SUSFS_STATE="yes"
  SUSFS_EVIDENCE="$1"
}

detect_susfs() {
  SUSFS_STATE="unknown"
  SUSFS_EVIDENCE=""
  _sfs_seen=0

  for _sn in susfs SUSFS; do
    if [ -d "/sys/module/$_sn" ]; then _susfs_hit "/sys/module/$_sn"; return 0; fi
  done

  if [ -r /proc/modules ]; then
    _sfs_seen=1
    if grep -qwi susfs /proc/modules 2>/dev/null; then
      _susfs_hit "/proc/modules"
      return 0
    fi
  fi

  # Built into the image, the symbol table is the only trace left. kptr_restrict
  # zeroes the addresses but keeps the names, and only the name matters here.
  if [ -r /proc/kallsyms ] && [ -s /proc/kallsyms ]; then
    _sfs_seen=1
    if grep -qim1 susfs /proc/kallsyms 2>/dev/null; then
      _susfs_hit "/proc/kallsyms"
      return 0
    fi
  fi

  [ "$_sfs_seen" = "1" ] && SUSFS_STATE="none"
  return 0
}

# ---------- properties ----------
# Strips the trailing CR some getprop builds emit.
gp() { getprop "$1" 2>/dev/null | tr -d '\r'; }

# ---------- sqlite ----------
# LSPosed and Zygisk Next both keep state in SQLite. Many KSU setups have no
# sqlite3 binary at all, so probe it and let callers handle absence.
SQLITE3=""
if have sqlite3; then
  SQLITE3="sqlite3"
elif _bb_has sqlite3; then
  SQLITE3="$BB sqlite3"
fi

has_sqlite() { [ -n "$SQLITE3" ]; }

# sqlq <db> <sql> : single query, returns rows separated by newline
sqlq() {
  _db="$1"; shift
  _sql="$*"
  [ -f "$_db" ] || return 1
  [ -n "$SQLITE3" ] || return 1
  $SQLITE3 "$_db" "$_sql" 2>/dev/null | tr -d '\r'
}

# ---------- json ----------
# One-line escape, safe for embedding in a JSON string literal.
# Written without any backslash literal so the escaping survives every layer
# this file travels through. 92 is the backslash code point, 34 is the quote.
#
# One awk pass instead of tr | tr | awk. The audit calls this three times per
# check, and on a phone a fork costs more than the escaping work itself.
json_escape() {
  awk '
    BEGIN {
      bs = sprintf("%c", 92); q = sprintf("%c", 34)
      cr = sprintf("%c", 13); tab = sprintf("%c", 9)
    }
    {
      line = $0
      gsub(cr, "", line)
      gsub(tab, " ", line)
      out = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == bs)     out = out bs bs
        else if (c == q) out = out bs q
        else             out = out c
      }
      printf "%s%s", (NR > 1 ? " " : ""), out
    }
  '
}

# ---------- config (flat key=value) ----------
conf_get() {
  _k="$1"; _d="$2"
  if [ -f "$CONF_FILE" ]; then
    _v=$(grep -m1 "^${_k}=" "$CONF_FILE" 2>/dev/null | sed -e "s/^${_k}=//")
    [ -n "$_v" ] && { echo "$_v"; return 0; }
  fi
  echo "$_d"
}

conf_set() {
  _k="$1"; _v="$2"
  mkdir -p "$CONF_DIR" 2>/dev/null
  _tmp="$CONF_FILE.tmp.$$"
  if [ -f "$CONF_FILE" ]; then
    grep -v "^${_k}=" "$CONF_FILE" > "$_tmp" 2>/dev/null
  else
    : > "$_tmp"
  fi
  echo "${_k}=${_v}" >> "$_tmp"
  mv -f "$_tmp" "$CONF_FILE" 2>/dev/null
}

# Every setting this module knows, as key=default, one per line.
#
# One table drives three things: the first-run seed, the upgrade backfill in
# migrate.sh, and the panel's report of which keys are missing. Adding a
# setting means adding one line here and nothing else. Values must stay a
# single token with no spaces, because migrate.sh splits this list on
# whitespace when it walks it.
CONF_DEFAULTS='daemon_enabled=1
daemon_interval=300
scrub_enabled=1
scrub_keep_days=7
mute_mode=gentle
prop_guard=0
autoconfig_enabled=1
autoconfig_on_boot=1'

# Nothing is written here. Seeding on load meant that merely sourcing this file
# created settings.conf, so a read-only look at the config reported "first run"
# and then quietly made it untrue. Writing the file is migrate.sh --apply's job,
# which runs at install and at boot and says what it did.
#
# Every reader below tolerates a missing file by falling back to the default in
# the table above, so a fresh install behaves correctly between the flash and
# the first boot.

# The key list, in the order a fresh config is written. Callers iterate over
# this rather than parsing the table themselves.
conf_keys() {
  printf '%s\n' "$CONF_DEFAULTS" | sed -e 's/=.*//'
}

# ---------- resetprop ----------
# KernelSU and Magisk ship different binaries; probe both, degrade quietly.
RESETPROP=""
for _p in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop; do
  [ -x "$_p" ] && { RESETPROP="$_p"; break; }
done
[ -z "$RESETPROP" ] && RESETPROP=$(command -v resetprop 2>/dev/null)

rp() {
  [ -n "$RESETPROP" ] || return 1
  "$RESETPROP" "$@"
}

# ---------- hashing ----------
# Integrity work needs a digest. Probe sha256sum, then md5sum. When neither
# exists the caller must report failure; assuming "nothing changed" because we
# could not look would be a lie dressed as a green light.
HASHER=""
for _hc in sha256sum md5sum; do
  if have "$_hc"; then HASHER="$_hc"; break; fi
done
if [ -z "$HASHER" ] && _bb_has sha256sum; then
  HASHER="$BB sha256sum"
fi

has_hash() { [ -n "$HASHER" ]; }

hash_file() {
  _hf="$1"
  [ -f "$_hf" ] || return 1
  [ -n "$HASHER" ] || return 1
  _ho=$($HASHER "$_hf" 2>/dev/null | awk 'NR==1 { print $1 }')
  [ -n "$_ho" ] || return 1
  printf '%s' "$_ho"
}

# ---------- ksud feature ----------
# `ksud feature check <id>` prints one or more of supported / unsupported /
# managed / forced, one per line, and the conditions are independent: a
# feature can be both supported and forced. Callers receive the whole token
# list because the raw set carries more information than one label.
FEATURE_STATES="supported unsupported managed forced"

feature_check() {
  _fci="$1"
  [ -n "$KSUD" ] || return 1
  _fco=$("$KSUD" feature check "$_fci" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
  [ -n "$_fco" ] || return 1
  printf '%s' "$_fco" | tr -s ' '
}

# `ksud feature get <id>` prints "Value: <n>" on its own line. When the kernel
# does not support the feature there is no Value line at all, which must stay
# a failure instead of quietly becoming 0.
feature_get() {
  _fgi="$1"
  [ -n "$KSUD" ] || return 1
  _fgo=$("$KSUD" feature get "$_fgi" 2>/dev/null | tr -d '\r')
  [ -n "$_fgo" ] || return 1
  _fgv=$(printf '%s' "$_fgo" | awk '{ for (i=1;i<=NF;i++) if ($i=="Value:") { print $(i+1); exit } }')
  case "$_fgv" in
    ''|*[!0-9-]*) return 1 ;;
  esac
  printf '%s' "$_fgv"
}

feature_set() {
  _fsi="$1"; _fsv="$2"
  [ -n "$KSUD" ] || return 1
  "$KSUD" feature set "$_fsi" "$_fsv" >/dev/null 2>&1
}

# ---------- injection family ----------
# HMA-OSS and friends hide apps by injecting through zygisk. Their presence
# changes what "correct" means for several checks, so it gets detected once
# and passed around. Never infers from absence of evidence.
INJ_MODULES=""
INJ_HMA=""
INJ_ZYGISK=""

is_injection_module() {
  _ih=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$_ih" in
    *hma*|*hide_my_applist*)              return 0 ;;
  esac
  return 1
}

is_zygisk_module() {
  _iz=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$_iz" in
    *zygisk_next*|*zygisksu*|*neozygisk*|*rezygisk*) return 0 ;;
  esac
  return 1
}

detect_injection_family() {
  INJ_MODULES=""
  INJ_HMA=""
  INJ_ZYGISK=""

  for _dp in /data/adb/modules/*/module.prop /data/adb/modules_update/*/module.prop; do
    [ -f "$_dp" ] || continue
    _di=$(grep -m1 '^id='   "$_dp" 2>/dev/null | sed -e 's/^id=//'   -e 's/\r$//')
    _dn=$(grep -m1 '^name=' "$_dp" 2>/dev/null | sed -e 's/^name=//' -e 's/\r$//')
    [ -z "$_di" ] && _di="$_dn"
    [ -z "$_di" ] && continue
    [ "$_di" = "$MODID" ] && continue

    if is_injection_module "$_di" || is_injection_module "$_dn"; then
      INJ_HMA="1"
      INJ_MODULES="${INJ_MODULES}${INJ_MODULES:+,}${_di}"
    fi
    if is_zygisk_module "$_di" || is_zygisk_module "$_dn"; then
      INJ_ZYGISK="1"
      INJ_MODULES="${INJ_MODULES}${INJ_MODULES:+,}${_di}"
    fi
  done

  # HMA keeps runtime state outside its module directory. Seeing the state
  # directory counts as evidence even when module.prop is unreadable.
  for _dd in /data/misc/hide_my_applist_*; do
    [ -d "$_dd" ] || continue
    INJ_HMA="1"
    INJ_MODULES="${INJ_MODULES}${INJ_MODULES:+,}hma_state"
    break
  done
}

has_injection() { [ "$INJ_HMA" = "1" ] || [ "$INJ_ZYGISK" = "1" ]; }

# ---------- config keys ----------
# Add one key if it is absent, leaving every stored value untouched. Callers
# that need the whole table applied go through migrate.sh --apply, which reports
# what it added instead of doing it quietly.
_conf_ensure() {
  _ek="$1"; _ed="$2"
  [ -f "$CONF_FILE" ] || return 0
  grep -q "^${_ek}=" "$CONF_FILE" 2>/dev/null && return 0
  echo "${_ek}=${_ed}" >> "$CONF_FILE" 2>/dev/null
}
