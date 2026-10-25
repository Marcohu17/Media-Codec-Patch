/* tools/bridge-sim/sim.js
 *
 * A stand-in for KernelSU's native WebUI bridge.
 *
 * The real bridge is:
 *     ksu.exec(command, optionsJSON, callbackName)
 * where callbackName is the NAME of a function on window, passed as a string.
 * The native side then evaluates `window[<name>](errno, stdout, stderr)`.
 *
 * This simulator reproduces that contract exactly, including the failure mode:
 * when the third argument is not a string, or the named global is not a
 * function, the call cannot be completed and nothing is ever delivered. No
 * error is thrown anywhere, which is what makes the bug look like a hang.
 *
 * Loaded before app.js so the panel sees a bridge on first run.
 */
(function () {
  'use strict';

  // Every command the panel sends, and how the fake device answers it.
  function report() {
    var checks = [
      { id: 'lsposed_scope', name: 'LSPosed 作用域', state: 'unknown', detail: '设备上没有可用的 sqlite3，读不了配置库。', fix: '装一个带 sqlite3 的 busybox。' },
      { id: 'zygisk_denylist', name: 'Zygisk 排除名单', state: 'na', detail: '检测到注入族模块 hma_oss_zygisk，排除名单不再适用。', fix: '保持现状。' },
      { id: 'mount_view', name: '模块挂载隔离', state: 'ok', detail: '挂载表里没有模块路径。', fix: '无需处理。' },
      { id: 'props', name: '系统属性', state: 'ok', detail: '没有发现明显可疑属性。', fix: '无需处理。' },
      { id: 'lspd_log', name: 'LSPosed 日志', state: 'ok', detail: '最近 24 小时的日志里没有出现 com.tencent.mm。', fix: '无需处理。' },
      { id: 'autoconfig', name: '自动配置', state: 'ok', detail: '上次自动配置没有失败项。', fix: '无需处理。' },
      { id: 'hma_store', name: 'HMA 隐藏配置', state: 'ok', detail: '在 HMA 的存储里读到 com.tencent.mm 出现 2 次（共扫描 2 个文件）。这说明配置里确实有这个包，不说明它当前已对进程生效。', fix: '在 HMA 界面核对模板绑定，再重启目标应用验证。' }
    ];

    return {
      generated_at: '2026-10-25 18:52:00',
      elapsed_seconds: 3,
      module: { id: 'lsposed_stealth', version: 'v1.1.3' },
      device: { brand: 'Xiaomi', model: '2211133C', android: '14', sdk: '34' },
      environment: {
        lsposed: true, zygisk_next: true, kernelsu: true, sqlite3: false,
        hma: true, injection_zygisk: false, injection_modules: 'hma_oss_zygisk',
        ksu_form: 'lkm', susfs: 'none', susfs_evidence: '/proc/modules'
      },
      summary: { ok: 9, bad: 0, unknown: 2, na: 1, level: 'yellow' },
      targets: [
        { pkg: 'com.tencent.mm', label: '微信', installed: true, checks: checks },
        { pkg: 'com.eg.android.AlipayGphone', label: '支付宝', installed: true, checks: checks }
      ]
    };
  }

  var CONFIG = [
    'daemon_enabled=1',
    'daemon_interval=300',
    'scrub_enabled=1',
    'scrub_keep_days=7',
    'mute_mode=gentle',
    'prop_guard=0'
  ].join('\n');

  // Shaped exactly like what common/hma.sh prints for a store with one
  // template bound. The directory name carries the random suffix a real
  // device has, and the template name is Chinese so the escaping path gets
  // exercised in the browser too, not just in the shell sandbox.
  function hmaStore() {
    // ?hma=empty switches to the store an unconfigured HMA leaves behind,
    // where both the template map and the counters are empty objects and the
    // registry never loaded. That combination drives the other verdict path
    // and the fallback hint, which the configured store never reaches.
    if (/[?&]hma=empty/.test(location.search)) return hmaStoreEmpty();

    var dir = '/data/misc/hide_my_applist_xlcolhugacgkagtu';
    return {
      generated_at: '2026-10-25 20:05:00',
      found: true,
      verdict: 'configured',
      dirs: [{
        path: dir,
        entries: 5,
        files: [
          {
            name: 'config.json',
            path: dir + '/config.json',
            size: 3677,
            head: '{"configVersion":93,"templates":{"tpl_wx":{"com.tencent.mm":"微信隐藏模板"}},"settingsTemplates":{}}',
            hits: { 'com.tencent.mm': 1, 'com.tencent.mobileqq': 0 }
          },
          {
            name: 'filter_count.json',
            path: dir + '/filter_count.json',
            size: 38,
            head: '{"filterCounts":{"com.tencent.mm":7}}',
            hits: { 'com.tencent.mm': 1, 'com.tencent.mobileqq': 0 }
          },
          {
            name: 'status.json',
            path: dir + '/status.json',
            size: 33,
            head: '{"workMode":1,"managerUid":10351}',
            hits: { 'com.tencent.mm': 0, 'com.tencent.mobileqq': 0 }
          }
        ]
      }],
      targets: { 'com.tencent.mm': 2, 'com.tencent.mobileqq': 0 },
      targets_source: 'targets.sh',
      targets_list_defined: true,
      targets_registry_length: 45,
      templates_state: 'has_entries',
      settings_templates_state: 'empty',
      filter_counts_state: 'has_entries',
      filter_count_entries: '"com.tencent.mm":7',
      config_version: '93',
      work_mode: '1',
      files_scanned: 6,
      unreadable_dirs: 0,
      note: 'HMA 的过滤计数里已有条目，说明至少有一条隐藏规则在生效。计数对应哪个应用，要看下面的内容。'
    };
  }

  function hmaStoreEmpty() {
    var dir = '/data/misc/hide_my_applist_xlcolhugacgkagtu';
    return {
      generated_at: '2026-10-25 20:10:00',
      found: true,
      verdict: 'empty',
      dirs: [{
        path: dir,
        entries: 5,
        files: [
          {
            name: 'config.json',
            path: dir + '/config.json',
            size: 3677,
            head: '{"configVersion":93,"templates":{},"settingsTemplates":{},"defaultConfig":null}',
            hits: { 'com.tencent.mm': 0, 'com.tencent.mobileqq': 0 }
          },
          {
            name: 'filter_count.json',
            path: dir + '/filter_count.json',
            size: 19,
            head: '{"filterCounts":{}}',
            hits: { 'com.tencent.mm': 0, 'com.tencent.mobileqq': 0 }
          }
        ]
      }],
      targets: { 'com.tencent.mm': 0, 'com.tencent.mobileqq': 0 },
      targets_source: 'fallback',
      targets_list_defined: false,
      targets_registry_length: 0,
      templates_state: 'empty',
      settings_templates_state: 'empty',
      filter_counts_state: 'empty',
      filter_count_entries: '',
      config_version: '93',
      work_mode: '1',
      files_scanned: 2,
      unreadable_dirs: 0,
      note: 'HMA 在运行，但隐藏模板和过滤计数都是空的，说明还没有配置任何规则。这不是探测失败，是它确实还没被配置过。'
    };
  }

  // A config that predates this version: two keys missing, no schema stamp,
  // last install two releases back. ?mig=current switches to the healthy
  // branch so the "everything is fine" rendering gets exercised too.
  var mig = { backups: 2, last: '20261025-195803' };

  function migCheck() {
    var current = /[?&]mig=current/.test(location.search);
    return {
      mode: 'check',
      config_existed: true,
      state: current ? 'current' : 'missing_keys',
      keys_total: 8,
      keys_present: current ? 8 : 6,
      missing: current ? [] : ['autoconfig_enabled', 'autoconfig_on_boot'],
      extra: [],
      schema: current ? 1 : 0,
      schema_expected: 1,
      backups: mig.backups,
      last_backup: mig.last,
      installed_version: current ? 'v1.2.2-beta' : 'v1.2.1',
      installed_at: '2026-10-20 21:14:00',
      module_version: 'v1.2.2-beta',
      module_code: '8'
    };
  }

  function migSnapshot() {
    mig.backups += 1;
    mig.last = '20261025-210404';
    return {
      mode: 'snapshot', ok: true, label: 'manual',
      dir: '/data/adb/lsposed_stealth/backup/' + mig.last,
      name: mig.last,
      copied: ['config/settings.conf', 'autoconfig/last.json', 'state/upstream.conf'],
      copied_count: 3,
      skipped: ['autoconfig/baseline.snap', 'state/hma.json'],
      kept: mig.backups, pruned: 0
    };
  }

  function migRestore() {
    mig.backups += 1;
    return {
      mode: 'restore', ok: true, name: mig.last,
      dir: '/data/adb/lsposed_stealth/backup/' + mig.last,
      restored: ['config/settings.conf', 'autoconfig/last.json', 'state/upstream.conf'],
      restored_count: 3,
      skipped: ['autoconfig/baseline.snap', 'state/hma.json'],
      failed: [], backfilled: [],
      pre_snapshot: '/data/adb/lsposed_stealth/backup/20261025-210410'
    };
  }

  function respond(cmd) {
    if (cmd.indexOf('audit.sh') >= 0) return { code: 0, out: JSON.stringify(report()), err: '' };

    if (cmd.indexOf('conf.sh setm') >= 0) return { code: 0, out: 'ok\n', err: '' };
    if (cmd.indexOf('conf.sh get') >= 0) return { code: 0, out: CONFIG + '\n', err: '' };
    if (cmd.indexOf('conf.sh set') >= 0) return { code: 0, out: 'ok\n', err: '' };

    if (cmd.indexOf('autoconfig.sh --status') >= 0) {
      return {
        code: 0,
        out: JSON.stringify({
          mode: 'status', generated_at: '2026-10-25 18:40:00',
          summary: { ok: 1, failed: 0, skipped: 5, na: 1 },
          actions: [
            { id: 'kernel_umount', name: 'kernel_umount 开关', state: 'ok', old: '0', new: '1', detail: '写入后已读回确认。' },
            { id: 'zygisk_exclusion', name: 'Zygisk 排除名单', state: 'na', detail: '注入族模块在场，不碰这一项。' }
          ]
        }),
        err: ''
      };
    }

    if (cmd.indexOf('autoconfig.sh') >= 0) {
      return {
        code: 0,
        out: JSON.stringify({
          mode: 'dry-run', generated_at: '2026-10-25 18:41:00',
          summary: { ok: 0, failed: 0, skipped: 5, na: 1 },
          actions: [
            { id: 'sulog', name: 'sulog 开关', state: 'skipped', old: '0', new: '1', detail: 'ksud 不认识这个子命令，跳过。' },
            { id: 'zygisk_exclusion', name: 'Zygisk 排除名单', state: 'na', detail: '注入族模块在场，不碰这一项。' }
          ]
        }),
        err: ''
      };
    }

    if (cmd.indexOf('upstream.sh --check') >= 0) {
      return {
        code: 0,
        out: JSON.stringify({
          ok: true, checked_at: '2026-10-25 18:42:00', source: 'jsdelivr',
          feature_ids: ['su_compat', 'kernel_umount', 'sulog', 'adb_root', 'selinux_hide', 'shell_su_adb_only'],
          check_states: { su_compat: 'supported' }, reason: ''
        }),
        err: ''
      };
    }

    if (cmd.indexOf('upstream.sh --show') >= 0) {
      return { code: 0, out: JSON.stringify({ ok: false, reason: '还没有核对过上游。' }), err: '' };
    }

    if (cmd.indexOf('hma.sh') >= 0 || cmd.indexOf('hma.json') >= 0) {
      return { code: 0, out: JSON.stringify(hmaStore()), err: '' };
    }

    // migrate.sh: one shape per subcommand. The counters move between calls so
    // the panel's numbers change the way they would on a device, instead of
    // showing the same frozen answer for every click.
    if (cmd.indexOf('migrate.sh --check') >= 0) {
      return { code: 0, out: JSON.stringify(migCheck()), err: '' };
    }
    if (cmd.indexOf('migrate.sh --snapshot') >= 0) {
      return { code: 0, out: JSON.stringify(migSnapshot()), err: '' };
    }
    if (cmd.indexOf('migrate.sh --restore') >= 0) {
      return { code: 0, out: JSON.stringify(migRestore()), err: '' };
    }

    if (cmd.indexOf('scrub.sh') >= 0) return { code: 0, out: '预览：会清理 3 个日志文件', err: '' };
    if (cmd.indexOf('mute.sh') >= 0) return { code: 0, out: '日志锁已释放', err: '' };
    if (cmd.indexOf('heartbeat') >= 0) return { code: 0, out: '2026-10-25 18:45:00 | 4321', err: '' };

    return { code: 0, out: 'ok', err: '' };
  }

  // Instruments the contract so the test can assert on what actually arrived.
  window.__bridge = {
    calls: [],
    callbackArgTypes: [],
    muted: {}     // command substrings that must never answer
  };

  function isMuted(cmd) {
    var keys = Object.keys(window.__bridge.muted);
    for (var i = 0; i < keys.length; i++) {
      if (window.__bridge.muted[keys[i]] && cmd.indexOf(keys[i]) >= 0) return true;
    }
    return false;
  }

  window.ksu = {
    exec: function (command, options, callbackName) {
      window.__bridge.calls.push(command);
      window.__bridge.callbackArgTypes.push(typeof callbackName);

      // Native side would fail here. Silently, exactly like the real thing.
      if (typeof callbackName !== 'string') return;
      if (isMuted(command)) return;

      setTimeout(function () {
        var fn = window[callbackName];
        if (typeof fn !== 'function') return;
        var r = respond(command);
        fn(r.code, r.out, r.err);
      }, 20);
    },
    toast: function () {},
    fullScreen: function () {},
    moduleInfo: function () { return { id: 'lsposed_stealth' }; }
  };
})();
