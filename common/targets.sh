#!/system/bin/sh
# common/targets.sh - target application registry
#
# One line per target: <package>|<display label>
# Add entries here to extend auditing. Anything else in the pipeline reads
# this list, so a new target needs no other change.

TARGETS='com.tencent.mm|WeChat
com.tencent.mobileqq|QQ'

# Packages whose child processes also run app-level integrity checks.
target_procs() {
  case "$1" in
    com.tencent.mm)       echo "com.tencent.mm com.tencent.mm:push com.tencent.mm:appbrand0" ;;
    com.tencent.mobileqq) echo "com.tencent.mobileqq com.tencent.mobileqq:MSF com.tencent.mobileqq:qzone" ;;
    *)                    echo "$1" ;;
  esac
}

# pm path is the cheapest reliable "is it installed" probe on a rooted device.
target_installed() {
  _p=$(pm path "$1" 2>/dev/null | head -n1)
  [ -n "$_p" ]
}

# Reads lines out of the registry.
targets_list() { printf '%s\n' "$TARGETS"; }
