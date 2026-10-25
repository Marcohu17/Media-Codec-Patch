#!/system/bin/sh
# common/audit.sh - baseline audit
#
# Reads state only. Never writes to another module's config.
# Every check resolves to exactly one of: ok / bad / unknown / na.
# "unknown" means the probe could not run. It is never treated as a pass.
# "na" means the check does not apply here, and the detail says why. That is
# different from "ok": something was not verified, on purpose.

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="/data/adb/modules/lsposed_stealth/common"
. "$SELF_DIR/env.sh"
. "$SELF_DIR/targets.sh"

# ---------- check accumulator ----------
_CUR=""

# Totals are counted while checks are emitted. Parsing the finished JSON back
# apart with grep afterwards spends three processes per state to recover a
# number this function already has in hand.
_N_OK=0
_N_BAD=0
_N_UNK=0
_N_NA=0

emit_check() {
  _id="$1"; _name="$2"; _detail="$4"; _fix="$5"
  case "$3" in
    ok|bad|unknown|na) _st="$3" ;;
    *)                 _st="unknown" ;;
  esac
  _n=$(printf '%s' "$_name"   | json_escape)
  _d=$(printf '%s' "$_detail" | json_escape)
  _f=$(printf '%s' "$_fix"    | json_escape)
  [ -n "$_CUR" ] && _CUR="$_CUR,"
  _CUR="${_CUR}{\"id\":\"${_id}\",\"name\":\"${_n}\",\"state\":\"${_st}\",\"detail\":\"${_d}\",\"fix\":\"${_f}\"}"
  case "$_st" in
    ok)      _N_OK=$((_N_OK + 1)) ;;
    bad)     _N_BAD=$((_N_BAD + 1)) ;;
    unknown) _N_UNK=$((_N_UNK + 1)) ;;
    na)      _N_NA=$((_N_NA + 1)) ;;
  esac
}

take_checks() { printf '%s' "$_CUR"; _CUR=""; }

# ---------- discovery ----------
LSPD_DIR=""
for _c in /data/adb/lspd /data/adb/modules/zygisk_lsposed /data/adb/modules/riru_lsposed; do
  [ -d "$_c" ] && { LSPD_DIR="$_c"; break; }
done
LSPD_DB="/data/adb/lspd/config/modules_config.db"
LSPD_LOG_DIR="/data/adb/lspd/log"
# The log listing is the same for every target in one run, so it is taken
# once and shared.
_LSPD_RECENT=""
_LSPD_SCAN_DONE=0

ZYGISK_DIR=""
for _c in /data/adb/zygisksu /data/adb/modules/zygisksu; do
  [ -d "$_c" ] && { ZYGISK_DIR="$_c"; break; }
done
MAGISK_DB="/data/adb/magisk.db"

# ---------- check 1: LSPosed scope ----------
check_lsposed_scope() {
  _pkg="$1"

  if [ -z "$LSPD_DIR" ]; then
    emit_check "lsposed_scope" "LSPosed 作用域" "ok" \
      "没有找到 LSPosed 运行目录，作用域注入不存在。" \
      "无需处理。"
    return
  fi

  if [ ! -f "$LSPD_DB" ]; then
    emit_check "lsposed_scope" "LSPosed 作用域" "unknown" \
      "检测到 ${LSPD_DIR}，但没有找到配置库 ${LSPD_DB}，可能是版本差异或存储位置变化。" \
      "打开 LSPosed 管理器，确认 ${_pkg} 没有被任何模块勾选作用域。"
    return
  fi

  if ! has_sqlite; then
    emit_check "lsposed_scope" "LSPosed 作用域" "unknown" \
      "设备上没有可用的 sqlite3，读不了 ${LSPD_DB}。" \
      "装一个带 sqlite3 的 busybox，或在 LSPosed 管理器里手动确认 ${_pkg} 未被勾选。"
    return
  fi

  _tables=$(sqlq "$LSPD_DB" ".tables")
  if [ -z "$_tables" ]; then
    emit_check "lsposed_scope" "LSPosed 作用域" "unknown" \
      "能打开 ${LSPD_DB} 但读不出表结构，可能被占用或版本不匹配。" \
      "在 LSPosed 管理器里手动确认 ${_pkg} 未被勾选。"
    return
  fi

  _tbl=""
  for _t in scope scopes app_scope; do
    if printf '%s' "$_tables" | tr -s ' \t' '\n\n' | grep -qx "$_t"; then
      _tbl="$_t"; break
    fi
  done

  if [ -z "$_tbl" ]; then
    emit_check "lsposed_scope" "LSPosed 作用域" "unknown" \
      "配置库里没有已知的作用域表（表清单：$(printf '%s' "$_tables" | json_escape)）。" \
      "在 LSPosed 管理器里手动确认 ${_pkg} 未被勾选。"
    return
  fi

  _cols=$(sqlq "$LSPD_DB" "PRAGMA table_info($_tbl);")
  _col=""
  for _c in app_pkg_name pkg_name package_name; do
    if printf '%s' "$_cols" | grep -q "|${_c}|"; then
      _col="$_c"; break
    fi
  done

  if [ -z "$_col" ]; then
    emit_check "lsposed_scope" "LSPosed 作用域" "unknown" \
      "作用域表 ${_tbl} 里没有可识别的包名列。" \
      "在 LSPosed 管理器里手动确认 ${_pkg} 未被勾选。"
    return
  fi

  _n=$(sqlq "$LSPD_DB" "SELECT COUNT(*) FROM ${_tbl} WHERE ${_col}='${_pkg}';")
  case "$_n" in
    ''|*[!0-9]*)
      emit_check "lsposed_scope" "LSPosed 作用域" "unknown" \
        "查询 ${_tbl}.${_col} 失败（返回：$(printf '%s' "$_n" | json_escape)）。" \
        "在 LSPosed 管理器里手动确认 ${_pkg} 未被勾选。"
      ;;
    0)
      emit_check "lsposed_scope" "LSPosed 作用域" "ok" \
        "${_pkg} 不在任何 LSPosed 模块的作用域里。" \
        "无需处理。"
      ;;
    *)
      emit_check "lsposed_scope" "LSPosed 作用域" "bad" \
        "${_pkg} 出现在 LSPosed 作用域里，共 ${_n} 条记录。注入会发生，进程内会有痕迹。" \
        "打开 LSPosed 管理器 → 模块 → 逐个检查，把与 ${_pkg} 相关的勾选全部取消，然后强行停止 ${_pkg} 再重新打开。"
      ;;
  esac
}

# ---------- check 2: Zygisk deny list ----------
check_zygisk_denylist() {
  _pkg="$1"

  # An injection-family module hides apps by injecting into them through
  # zygote. Putting the target on a Zygisk exclusion list stops that
  # injection, which silently turns its hiding off as a side effect. On such
  # a device this check is no longer "should be excluded", it is "leave the
  # list alone", so it reports na instead of bad.
  if [ "$INJ_HMA" = "1" ]; then
    emit_check "zygisk_denylist" "Zygisk 排除名单" "na" \
      "检测到注入族模块（${INJ_MODULES}）。它靠 zygisk 注入来隐藏应用，把 ${_pkg} 放进排除名单会连同它对该应用的隐藏一起掐掉。这一项在本机不适用。" \
      "不要往排除名单里加 ${_pkg}。如果哪天卸载了这些模块，再回来重新看这一项。"
    return
  fi

  if [ -z "$ZYGISK_DIR" ] && [ ! -f "$MAGISK_DB" ]; then
    emit_check "zygisk_denylist" "Zygisk 排除名单" "ok" \
      "没有检测到 Zygisk Next，也没有 magisk.db，不存在 zygisk 注入面。" \
      "无需处理。"
    return
  fi

  if [ ! -f "$MAGISK_DB" ]; then
    emit_check "zygisk_denylist" "Zygisk 排除名单" "unknown" \
      "检测到 ${ZYGISK_DIR}，但没有 ${MAGISK_DB}，排除名单的存储位置无法确认。" \
      "打开 Zygisk Next 管理界面，确认 ${_pkg} 在排除名单里，并且已强制生效。"
    return
  fi

  if ! has_sqlite; then
    emit_check "zygisk_denylist" "Zygisk 排除名单" "unknown" \
      "设备上没有可用的 sqlite3，读不了 ${MAGISK_DB}。" \
      "装一个带 sqlite3 的 busybox，或在 Zygisk Next 界面里手动确认 ${_pkg} 已被排除。"
    return
  fi

  _n=$(sqlq "$MAGISK_DB" "SELECT COUNT(*) FROM denylist WHERE package_name='${_pkg}';")
  case "$_n" in
    ''|*[!0-9]*)
      emit_check "zygisk_denylist" "Zygisk 排除名单" "unknown" \
        "查询 denylist 表失败（返回：$(printf '%s' "$_n" | json_escape)）。" \
        "在 Zygisk Next 界面里手动确认 ${_pkg} 已被排除。"
      return
      ;;
  esac

  _enf=$(sqlq "$MAGISK_DB" "SELECT value FROM settings WHERE key='denylist';")
  case "$_enf" in ''|*[!0-9]*) _enf="?" ;; esac

  if [ "$_n" = "0" ]; then
    emit_check "zygisk_denylist" "Zygisk 排除名单" "bad" \
      "${_pkg} 不在排除名单里。zygisk 会照常注入，进程内能看到 zygisk 的映射。" \
      "打开 Zygisk Next（或 Magisk DenyList），把 ${_pkg} 加入排除名单，然后强行停止它再重新打开。"
    return
  fi

  if [ "$_enf" != "1" ]; then
    emit_check "zygisk_denylist" "Zygisk 排除名单" "bad" \
      "${_pkg} 已在排除名单里（${_n} 条），但强制生效开关没打开（denylist=${_enf}），名单不会真正拦注入。" \
      "打开 Zygisk Next 的「强制排除」开关，或在 Magisk 设置里开启「遵守排除列表」。"
    return
  fi

  emit_check "zygisk_denylist" "Zygisk 排除名单" "ok" \
    "${_pkg} 在排除名单中（${_n} 条），强制生效已开启。" \
    "无需处理。"
}

# ---------- check 3: module mount visibility ----------
# Reads the target process's OWN mount table when it is running. This is the
# closest a root shell can get to "what the app actually sees".
check_mount_view() {
  _pkg="$1"
  _pids=$(pidof "$_pkg" 2>/dev/null | tr -d '\r')

  if [ -z "$_pids" ]; then
    emit_check "mount_view" "模块挂载隔离" "unknown" \
      "${_pkg} 当前没有运行，读不到它自己的挂载表。KernelSU 的按应用卸载状态也没有稳定命令行可查。" \
      "先打开一次 ${_pkg}，再回来重新扫描；或在 KernelSU 管理器 → 超级用户 里确认 ${_pkg} 的「卸载模块」已开启。"
    return
  fi

  _readable=0
  _leak_pids=""
  for _pid in $_pids; do
    if [ -r "/proc/${_pid}/mounts" ]; then
      _readable=1
      if grep -qE '/data/adb/modules/[^ ]*|/data/adb/lspd|/data/adb/ksu' "/proc/${_pid}/mounts" 2>/dev/null; then
        _leak_pids="${_leak_pids} ${_pid}"
      fi
    fi
  done

  if [ "$_readable" = "0" ]; then
    emit_check "mount_view" "模块挂载隔离" "unknown" \
      "${_pkg} 在运行（pid ${_pids}），但根命名空间读不到它的 mount 表，可能被 hidepid 或 SELinux 挡住。" \
      "在 KernelSU 管理器 → 超级用户 里确认 ${_pkg} 的「卸载模块」已开启，并用 Momo 之类的检测器复核。"
    return
  fi

  if [ -n "$_leak_pids" ]; then
    emit_check "mount_view" "模块挂载隔离" "bad" \
      "${_pkg} 进程（pid${_leak_pids}）的挂载表里能看到模块路径，模块对它没有做隔离。" \
      "在 KernelSU 管理器 → 超级用户 里给 ${_pkg} 打开「卸载模块」，然后强行停止并重新打开。"
    return
  fi

  emit_check "mount_view" "模块挂载隔离" "ok" \
    "${_pkg} 进程（pid ${_pids}）的挂载表里没有模块路径。" \
    "无需处理。"
}

# ---------- check 4: leak-prone properties ----------
# Nothing here depends on the target. The five properties are read once and
# the verdict is reused for every target, the same way the autoconfig check
# below works.
_PROPS_STATE=""
_PROPS_DETAIL=""
_PROPS_FIX=""

_compute_props() {
  [ -n "$_PROPS_STATE" ] && return 0

  _dbg=$(gp ro.debuggable)
  _sec=$(gp ro.secure)
  _tags=$(gp ro.build.tags)
  _vb=$(gp ro.boot.verifiedbootstate)
  _lk=$(gp ro.boot.flash.locked)

  _bad=""
  [ "$_dbg" = "1" ] && _bad="${_bad} ro.debuggable=1;"
  [ "$_sec" = "0" ] && _bad="${_bad} ro.secure=0;"
  case "$_tags" in *test-keys*) _bad="${_bad} ro.build.tags=test-keys;" ;; esac

  _base="ro.debuggable=${_dbg:-?} ro.secure=${_sec:-?} ro.build.tags=${_tags:-?} verifiedbootstate=${_vb:-?} flash.locked=${_lk:-?}"

  if [ -n "$_bad" ]; then
    _PROPS_STATE="bad"
    _PROPS_DETAIL="存在明显可疑属性：${_bad} （当前值：${_base}）"
    _PROPS_FIX="打开本模块的「属性伪装」开关（prop_guard），重启一次生效。解锁状态属于物理事实，改不掉，也不算在本项判定里。"
    return 0
  fi

  # Readable properties all look clean. Report the boot-state values as
  # context, without judging them.
  _PROPS_STATE="ok"
  _PROPS_DETAIL="没有发现明显可疑属性。参考值：${_base}"
  _PROPS_FIX="无需处理。verifiedbootstate=orange 是解锁的物理结果，模块无法消除，也不计入通过条件。"
  return 0
}

check_props() {
  _compute_props
  emit_check "props" "系统属性" "$_PROPS_STATE" "$_PROPS_DETAIL" "$_PROPS_FIX"
}

# ---------- check 5: LSPosed log activity ----------
# Looks only at log files touched in the last 24h, so an old scope entry that
# has already been removed does not keep this check red forever.
check_lspd_log() {
  _pkg="$1"

  if [ -z "$LSPD_DIR" ]; then
    emit_check "lspd_log" "LSPosed 日志" "ok" \
      "没有 LSPosed，日志不存在。" \
      "无需处理。"
    return
  fi

  if [ ! -d "$LSPD_LOG_DIR" ]; then
    emit_check "lspd_log" "LSPosed 日志" "unknown" \
      "检测到 LSPosed，但没有找到日志目录 ${LSPD_LOG_DIR}。" \
      "打开 LSPosed 管理器的日志页手动看一眼，确认 ${_pkg} 没有出现在加载列表里。"
    return
  fi

  if [ "$_LSPD_SCAN_DONE" = "0" ]; then
    _LSPD_RECENT=$(find "$LSPD_LOG_DIR" -type f -mmin -1440 2>/dev/null | head -n 40)
    _LSPD_SCAN_DONE=1
  fi
  _recent="$_LSPD_RECENT"
  if [ -z "$_recent" ]; then
    emit_check "lspd_log" "LSPosed 日志" "ok" \
      "最近 24 小时内 LSPosed 没有写新日志，${_pkg} 近期没有被加载的记录。" \
      "无需处理。"
    return
  fi

  _hits=""
  for _f in $_recent; do
    [ -f "$_f" ] || continue
    if grep -q -- "$_pkg" "$_f" 2>/dev/null; then
      _hits="${_hits} $(basename "$_f")"
      [ $(printf '%s' "$_hits" | wc -w) -ge 3 ] && break
    fi
  done

  if [ -n "$_hits" ]; then
    emit_check "lspd_log" "LSPosed 日志" "bad" \
      "最近 24 小时的 LSPosed 日志里出现了 ${_pkg}：${_hits}" \
      "说明近期有模块在向 ${_pkg} 注入。回 LSPosed 管理器取消相关作用域，然后运行一次清扫。"
    return
  fi

  emit_check "lspd_log" "LSPosed 日志" "ok" \
    "最近 24 小时的日志（$(echo "$_recent" | grep -c .) 个文件）里没有出现 ${_pkg}。" \
    "无需处理。"
}

# ---------- check 6: last autoconfig result ----------
# Computed once per audit run and reused for every target, so two targets do
# not read the same file twice.
_AC_STATE=""
_AC_DETAIL=""
_AC_FIX=""

_compute_autoconfig() {
  if [ ! -f "$AUTOCONF_FILE" ]; then
    _AC_STATE="unknown"
    _AC_DETAIL="还没有执行过自动配置，没有结果可以核对。"
    _AC_FIX="打开本模块面板，先点「预览」看会改什么，确认后再点「执行」。"
    return
  fi

  _af=$(cat "$AUTOCONF_FILE" 2>/dev/null)
  if [ -z "$_af" ]; then
    _AC_STATE="unknown"
    _AC_DETAIL="结果文件 ${AUTOCONF_FILE} 存在但读不出内容。"
    _AC_FIX="回面板重新执行一次自动配置。"
    return
  fi

  _aok=$(printf '%s' "$_af" | grep -o '"state":"ok"' | wc -l | tr -d ' ')
  _abad=$(printf '%s' "$_af" | grep -o '"state":"failed"' | wc -l | tr -d ' ')
  _askip=$(printf '%s' "$_af" | grep -o '"state":"skipped"' | wc -l | tr -d ' ')
  _ana=$(printf '%s' "$_af" | grep -o '"state":"na"' | wc -l | tr -d ' ')
  _agen=$(printf '%s' "$_af" | grep -o '"generated_at":"[^"]*"' | head -n1 | sed -e 's/.*"generated_at":"//' -e 's/"$//')
  [ -n "$_agen" ] || _agen="时间未知"

  if [ "$_abad" -gt 0 ]; then
    _AC_STATE="bad"
    _AC_DETAIL="上次自动配置（${_agen}）有 ${_abad} 项没能确认成功：ok=${_aok} failed=${_abad} skipped=${_askip} na=${_ana}。"
    _AC_FIX="打开面板看是哪一项红的，每项都写了原因。处理完再执行一次。"
    return
  fi

  _AC_STATE="ok"
  _AC_DETAIL="上次自动配置（${_agen}）：ok=${_aok} failed=0 skipped=${_askip} na=${_ana}。没有失败项。"
  _AC_FIX="无需处理。skipped 和 na 的项各自写了不做的原因，点开卡片能看到。"
}

check_autoconfig() {
  if [ -z "$_AC_STATE" ]; then
    _compute_autoconfig
  fi
  emit_check "autoconfig" "自动配置" "$_AC_STATE" "$_AC_DETAIL" "$_AC_FIX"
}

# ---------- HMA store ----------
# The probe is read-only. It runs once per audit run, not once per target:
# every target is reading the same store, and rescanning it would double the
# cost of a scan for an answer that cannot change in between.
_HMA_PROBED=0
_HMA_OUT=""

_hma_probe_once() {
  [ "$_HMA_PROBED" = "1" ] && return 0
  _HMA_PROBED=1
  [ -f "$SELF_DIR/hma.sh" ] || return 0
  _HMA_OUT=$(sh "$SELF_DIR/hma.sh" probe 2>/dev/null)
}

check_hma_store() {
  _hp="$1"

  if [ "$INJ_HMA" != "1" ]; then
    emit_check "hma_store" "HMA 隐藏配置" "na" \
      "本机没有检测到 HMA 一类注入隐藏模块，这一项不适用。" ""
    return
  fi

  _hma_probe_once

  if [ -z "$_HMA_OUT" ]; then
    emit_check "hma_store" "HMA 隐藏配置" "unknown" \
      "HMA 在场，但只读探测没有返回结果。可能是脚本没能运行，也可能读不到它的目录。没读到不当作没配置。" \
      "在面板点「探测 HMA 配置」，那里会写清楚卡在哪一步。"
    return
  fi

  case "$_HMA_OUT" in
    *'"found":false'*)
      emit_check "hma_store" "HMA 隐藏配置" "unknown" \
        "HMA 的模块目录在，但没找到它的状态存储。已知的几条路径都没有命中，说明它的存放位置和这里设想的不一样。没找到不当作没配置。" \
        "在面板点「探测 HMA 配置」，把列出来的目录发回来，就能补上新的路径。"
      return ;;
  esac

  _scanned=$(printf '%s' "$_HMA_OUT" | sed -n 's/.*"files_scanned":\([0-9]*\).*/\1/p')
  case "$_scanned" in ''|*[!0-9]*) _scanned=0 ;; esac

  # Only the targets object, not the per-file hits: the same key appears in
  # both places, and the total is what this check is about.
  _seg=$(printf '%s' "$_HMA_OUT" | sed -n 's/.*"targets":{\([^}]*\)}.*/\1/p')
  _hits=$(printf '%s' "$_seg" | sed -n "s/.*\"${_hp}\":\([0-9]*\).*/\1/p")
  case "$_hits" in ''|*[!0-9]*) _hits=0 ;; esac

  if [ "$_scanned" -eq 0 ]; then
    emit_check "hma_store" "HMA 隐藏配置" "unknown" \
      "找到了 HMA 的目录，但里面没有可读文件。读不到内容就判断不了配置，这一项按未确认处理。" \
      "确认 HMA 至少打开过一次并保存过配置，再扫一遍试试。"
    return
  fi

  if [ "$_hits" -gt 0 ]; then
    emit_check "hma_store" "HMA 隐藏配置" "ok" \
      "在 HMA 的存储里读到 ${_hp} 出现 ${_hits} 次（共扫描 ${_scanned} 个文件）。这说明配置里确实有这个包，不说明它当前已对进程生效。" \
      "想把「配置里有」变成「确有隐藏」，只能在 HMA 界面核对模板绑定，再重启目标应用验证。"
    return
  fi

  emit_check "hma_store" "HMA 隐藏配置" "unknown" \
    "HMA 的存储能读（${_scanned} 个文件），但里面一次都没出现 ${_hp}。它可能改用模板或 uid 记录，也可能确实没给这个应用配隐藏。这两种情况从这里分不出来。" \
    "打开 HMA 管理器，看目标应用有没有绑定隐藏模板。有的话就是存储格式和假设不同，把「探测 HMA 配置」的结果发回来就能补上解析。"
}

# ---------- main ----------
_bool_json() {
  if "$@" >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi
}

main() {
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  [ -z "$_ts" ] && _ts="unknown"
  _t0=$(date '+%s' 2>/dev/null)
  case "$_t0" in ''|*[!0-9]*) _t0="" ;; esac

  # Detected once, then reused by every check that cares about injection.
  detect_injection_family
  detect_ksu_form
  detect_susfs

  _targets_json=""
  _first=1

  printf '%s\n' "$TARGETS" > "$STATE_DIR/.target_list" 2>/dev/null

  while IFS='|' read -r _pkg _label; do
    [ -z "$_pkg" ] && continue

    _CUR=""
    check_lsposed_scope "$_pkg"
    check_zygisk_denylist "$_pkg"
    check_mount_view "$_pkg"
    check_props
    check_lspd_log "$_pkg"
    check_autoconfig
    check_hma_store "$_pkg"
    _checks=$(take_checks)

    if target_installed "$_pkg"; then _inst="true"; else _inst="false"; fi
    _lbl=$(printf '%s' "$_label" | json_escape)

    if [ "$_first" = "1" ]; then
      _first=0
    else
      _targets_json="${_targets_json},"
    fi
    _targets_json="${_targets_json}{\"pkg\":\"${_pkg}\",\"label\":\"${_lbl}\",\"installed\":${_inst},\"checks\":[${_checks}]}"
  done < "$STATE_DIR/.target_list"

  rm -f "$STATE_DIR/.target_list" 2>/dev/null

  if [ "$_N_BAD" -gt 0 ]; then
    _level="red"
  elif [ "$_N_UNK" -gt 0 ]; then
    _level="yellow"
  else
    _level="green"
  fi

  # Wall-clock cost of the whole run, so a slow device can say how slow it
  # actually is instead of just "it feels slow".
  _elapsed=0
  if [ -n "$_t0" ]; then
    _t1=$(date '+%s' 2>/dev/null)
    case "$_t1" in
      ''|*[!0-9]*) ;;
      *)
        _elapsed=$((_t1 - _t0))
        [ "$_elapsed" -lt 0 ] && _elapsed=0
        ;;
    esac
  fi

  _brand=$(gp ro.product.brand | json_escape)
  _model=$(gp ro.product.model | json_escape)
  _rel=$(gp ro.build.version.release | json_escape)
  _sdk=$(gp ro.build.version.sdk | json_escape)
  _ver=$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^version=//' | json_escape)

  if [ -n "$LSPD_DIR" ]; then _lsp="true"; else _lsp="false"; fi
  if [ -n "$ZYGISK_DIR" ]; then _zyg="true"; else _zyg="false"; fi
  if is_ksu; then _ksu="true"; else _ksu="false"; fi
  if has_sqlite; then _sq="true"; else _sq="false"; fi
  if [ "$INJ_HMA" = "1" ]; then _hma="true"; else _hma="false"; fi
  if [ "$INJ_ZYGISK" = "1" ]; then _inzy="true"; else _inzy="false"; fi
  _inj_e=$(printf '%s' "$INJ_MODULES" | json_escape)
  _sfe=$(printf '%s' "$SUSFS_EVIDENCE" | json_escape)

  _json="{\"generated_at\":\"${_ts}\",\"elapsed_seconds\":${_elapsed}"
  _json="${_json},\"module\":{\"id\":\"${MODID}\",\"version\":\"${_ver}\"}"
  _json="${_json},\"device\":{\"brand\":\"${_brand}\",\"model\":\"${_model}\",\"android\":\"${_rel}\",\"sdk\":\"${_sdk}\"}"
  _json="${_json},\"environment\":{\"lsposed\":${_lsp},\"zygisk_next\":${_zyg},\"kernelsu\":${_ksu},\"sqlite3\":${_sq},\"hma\":${_hma},\"injection_zygisk\":${_inzy},\"injection_modules\":\"${_inj_e}\",\"ksu_form\":\"${KSU_FORM}\",\"susfs\":\"${SUSFS_STATE}\",\"susfs_evidence\":\"${_sfe}\"}"
  _json="${_json},\"summary\":{\"ok\":${_N_OK},\"bad\":${_N_BAD},\"unknown\":${_N_UNK},\"na\":${_N_NA},\"level\":\"${_level}\"}"
  _json="${_json},\"targets\":[${_targets_json}]}"

  if [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null; then
    printf '%s' "$_json" > "${REPORT_FILE}.tmp" 2>/dev/null \
      && mv -f "${REPORT_FILE}.tmp" "$REPORT_FILE" 2>/dev/null
  fi

  log "audit ok=${_N_OK} bad=${_N_BAD} unknown=${_N_UNK} na=${_N_NA} level=${_level} elapsed=${_elapsed}s"
  printf '%s' "$_json"
}

main "$@"
