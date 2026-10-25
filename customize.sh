#!/system/bin/sh
# Installer entry point (Magisk and KernelSU both call this).
# Keep output short: the installer UI only shows a few lines.

SKIPUNZIP=0

ui_print "- Media Codec Patch"
ui_print "- installing baseline diagnostics"

if [ -d /data/adb/ksu ]; then
  ui_print "- KernelSU detected"
elif [ -d /data/adb/magisk ]; then
  ui_print "- Magisk detected"
else
  ui_print "! no KernelSU or Magisk root found"
  ui_print "! the module will install but checks will report unknown"
fi

MODPATH=${MODPATH:-$PWD}

chmod 0755 "$MODPATH"/*.sh 2>/dev/null
chmod 0755 "$MODPATH"/common/*.sh 2>/dev/null

for _p in com.tencent.mm com.tencent.mobileqq; do
  if pm path "$_p" >/dev/null 2>&1; then
    ui_print "- target present: $_p"
  else
    ui_print "- target missing: $_p (check will report not installed)"
  fi
done

if [ -x /data/adb/ksu/bin/busybox ] || [ -x /data/adb/magisk/busybox ] || command -v sqlite3 >/dev/null 2>&1; then
  ui_print "- runtime tools found"
else
  ui_print "! no busybox or sqlite3 found"
  ui_print "! config checks will degrade to unknown"
fi

# ---------- carry the config across the update ----------
# Settings live in /data/adb/<id>; the module itself lives in
# /data/adb/modules/<id>. Flashing replaces the second and leaves the first
# alone, so an update never costs the user their configuration. This block says
# which case this is, copies the current state aside before anything is
# written, and then adds only the keys this version introduces.
if [ -f "$MODPATH/common/migrate.sh" ]; then
  _ID=$(grep -m1 '^id=' "$MODPATH/module.prop" 2>/dev/null | sed -e 's/^id=//')
  [ -n "$_ID" ] || _ID=lsposed_stealth
  _CONF="/data/adb/${_ID}/config/settings.conf"
  _existed=0

  if [ -f "$_CONF" ]; then
    _existed=1
    # schema_version is bookkeeping, not one of the user's settings.
    _n=$(grep -v '^schema_version=' "$_CONF" 2>/dev/null | grep -c '^[A-Za-z_][A-Za-z0-9_]*=')
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    ui_print "- 沿用已有配置（${_n} 项）"

    _snap=$(sh "$MODPATH/common/migrate.sh" --snapshot 2>/dev/null)
    _sdir=$(printf '%s' "$_snap" | sed -n 's/.*"dir":"\([^"]*\)".*/\1/p')
    if [ -n "$_sdir" ]; then
      ui_print "- 已备份到 ${_sdir##*/}"
    else
      ui_print "! 备份没做成功，继续安装，配置不会被改动"
    fi
  else
    ui_print "- 首次安装，写入默认配置"
  fi

  _apply=$(sh "$MODPATH/common/migrate.sh" --apply 2>/dev/null)
  _added=$(printf '%s' "$_apply" | sed -n 's/.*"added_count":\([0-9]*\).*/\1/p')
  case "$_added" in ''|*[!0-9]*) _added=0 ;; esac
  # On a first install the line above already said everything; counting the
  # seed as "补齐 N 项" here would describe a fresh write as a repair.
  if [ "$_existed" = "1" ]; then
    if [ "$_added" -gt 0 ]; then
      ui_print "- 补齐新增配置键 ${_added} 项"
    else
      ui_print "- 配置键完整"
    fi
  fi
fi

ui_print "- done, open the module WebUI for the first scan"
ui_print "- finish setup before signing in to WeChat"
