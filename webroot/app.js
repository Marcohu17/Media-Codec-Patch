(function () {
  'use strict';

  /* pack.ps1 rewrites the next line when -ModuleId is supplied */
  var MODULE_ID = 'lsposed_stealth';
  var MOD_DIR = '/data/adb/modules/' + MODULE_ID;
  var DATA_DIR = '/data/adb/' + MODULE_ID;

  var CMD = {
    audit: 'sh ' + MOD_DIR + '/common/audit.sh',
    scrubDry: 'sh ' + MOD_DIR + '/common/scrub.sh --dry-run',
    scrub: 'sh ' + MOD_DIR + '/common/scrub.sh',
    restore: 'sh ' + MOD_DIR + '/common/scrub.sh --restore',
    release: 'sh ' + MOD_DIR + '/common/mute.sh --release',
    confGet: 'sh ' + MOD_DIR + '/common/conf.sh get',
    heartbeat: 'cat ' + DATA_DIR + '/state/heartbeat 2>/dev/null',
    daemonPid: 'cat ' + DATA_DIR + '/state/daemon.pid 2>/dev/null',
    acStatus: 'sh ' + MOD_DIR + '/common/autoconfig.sh --status',
    acDry: 'sh ' + MOD_DIR + '/common/autoconfig.sh --dry-run',
    acApply: 'sh ' + MOD_DIR + '/common/autoconfig.sh',
    acRollback: 'sh ' + MOD_DIR + '/common/autoconfig.sh --rollback',
    upstreamCheck: 'sh ' + MOD_DIR + '/common/upstream.sh --check',
    upstreamShow: 'sh ' + MOD_DIR + '/common/upstream.sh --show',
    hmaProbe: 'sh ' + MOD_DIR + '/common/hma.sh probe',
    hmaShow: 'cat ' + DATA_DIR + '/state/hma.json 2>/dev/null',
    migCheck: 'sh ' + MOD_DIR + '/common/migrate.sh --check',
    migSnapshot: 'sh ' + MOD_DIR + '/common/migrate.sh --snapshot',
    migRestore: 'sh ' + MOD_DIR + '/common/migrate.sh --restore'
  };

  // How long a single command may take before the panel stops waiting. The
  // bridge queues one shell at a time, so a command that never returns would
  // otherwise freeze every button behind it with no explanation.
  var TIMEOUT_SCAN = 60000;
  var TIMEOUT_NET = 45000;
  var TIMEOUT_DEF = 20000;

  var _cbSeq = 0;

  // KernelSU's bridge is:
  //   ksu.exec(command, optionsJSON, callbackName)
  // The third argument is the NAME of a function on window, passed as a string.
  // The native side calls back with `window[<name>](errno, stdout, stderr)`.
  // Handing it the function object itself makes that call evaluate against a
  // value it cannot call, so the callback never fires — and every panel action
  // waits forever on a promise that will never settle.
  function exec(cmd, timeoutMs) {
    return new Promise(function (resolve) {
      if (typeof ksu === 'undefined' || typeof ksu.exec !== 'function') {
        resolve({ code: -1, out: '', err: 'ksu bridge unavailable' });
        return;
      }

      var name = 'lspst_cb_' + Date.now() + '_' + (_cbSeq++);
      var settled = false;
      var timer = null;

      function done(code, out, err) {
        if (settled) return;
        settled = true;
        if (timer) { clearTimeout(timer); timer = null; }
        try { delete window[name]; } catch (e) {}
        resolve({ code: code, out: out || '', err: err || '' });
      }

      window[name] = function (errno, stdout, stderr) {
        var code = parseInt(errno, 10);
        done(isNaN(code) ? 0 : code, stdout, stderr);
      };

      timer = setTimeout(function () {
        done(-2, '', 'no callback within ' + Math.round((timeoutMs || TIMEOUT_DEF) / 1000) + 's');
      }, timeoutMs || TIMEOUT_DEF);

      try {
        var ret = ksu.exec(cmd, '{}', name);
        // Some forks resolve a promise instead of calling the named function.
        // Whichever arrives first wins; done() ignores the second one.
        if (ret && typeof ret.then === 'function') {
          ret.then(function (r) {
            if (r && typeof r === 'object') {
              var c = parseInt(r.errno, 10);
              done(isNaN(c) ? 0 : c, r.stdout, r.stderr);
            } else {
              done(0, String(r || ''), '');
            }
          }, function (e) {
            done(-1, '', String(e));
          });
        }
      } catch (e) {
        done(-1, '', String(e));
      }
    });
  }

  // Turn a failed exec into one sentence a person can act on.
  function failText(r) {
    if (r.code === -2) return '命令没有在限定时间内返回，可能还在跑。过一会儿再点一次。';
    if (r.code === -1) return '桥接没有响应' + (r.err ? '：' + r.err.slice(0, 80) : '');
    if (r.err) return r.err.slice(0, 120);
    return '退出码 ' + r.code;
  }

  function toast(msg, ms) {
    var node = document.getElementById('toast');
    node.textContent = msg;
    node.hidden = false;
    clearTimeout(toast._t);
    toast._t = setTimeout(function () { node.hidden = true; }, ms || 2600);
  }

  function $(id) { return document.getElementById(id); }

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = text;
    return n;
  }

  var STATE_TEXT = { ok: '通过', bad: '异常', unknown: '查不到', na: '不适用' };
  var AC_TEXT = { ok: '已确认', failed: '未确认', skipped: '跳过', na: '不适用' };
  var KSU_FORM_TEXT = { lkm: 'LKM 模式', builtin: '内核内置', unknown: '形态未知' };
  var SUSFS_TEXT = { yes: 'SUSFS 可用', no: '无 SUSFS', unknown: 'SUSFS 未确认' };

  // audit.sh reports the absence of SUSFS as "none". Looking that up in
  // SUSFS_TEXT found nothing and fell back to "未确认", which turned a fact the
  // probe had actually established into doubt — and silenced the capability
  // note that only speaks when the state is known.
  function susfsKey(v) {
    if (v === 'none') return 'no';
    if (v === 'yes' || v === 'no' || v === 'unknown') return v;
    return 'unknown';
  }

  function setLight(level) {
    $('light').setAttribute('data-level', level || 'unknown');
    var map = { green: '环境干净', yellow: '有查不到的项', red: '有异常项' };
    $('light-text').textContent = map[level] || '未扫描';
  }

  function renderEnv(env) {
    var parts = [];
    parts.push(env.kernelsu ? 'KernelSU' : '非 KernelSU');
    if (env.kernelsu) parts.push(KSU_FORM_TEXT[env.ksu_form] || KSU_FORM_TEXT.unknown);
    parts.push(env.lsposed ? 'LSPosed 已装' : '无 LSPosed');
    parts.push(env.zygisk_next ? 'Zygisk Next 已装' : '无 Zygisk Next');
    parts.push(env.sqlite3 ? 'sqlite3 可用' : '无 sqlite3');
    if (env.susfs) parts.push(SUSFS_TEXT[susfsKey(env.susfs)]);
    if (env.hma) parts.push('注入隐藏模块在场：' + (env.injection_modules || 'HMA'));
    $('env').textContent = parts.join(' · ');
    renderCeiling(env);
  }

  // The row above says what this device is. This line says what it therefore
  // cannot do. Without SUSFS every configuration check still runs, so the
  // message names the missing layer, not a missing grade.
  function renderCeiling(env) {
    var host = $('ceiling');
    if (!host) return;

    var sfs = susfsKey(env.susfs);
    var msg = '';
    if (sfs === 'no' && env.ksu_form === 'lkm') {
      msg = 'LKM 加载的内核没有 SUSFS：/data/adb 这类路径在根命名空间里真实存在，深扫能看见。配置这一层照常检查。';
    } else if (sfs === 'no') {
      msg = '这台机的内核没有 SUSFS：/data/adb 这类路径在根命名空间里真实存在，深扫能看见。配置这一层照常检查。';
    } else if (sfs === 'unknown') {
      msg = 'SUSFS 状态没读到，读不到不等于没有。';
    }

    host.textContent = msg;
    host.hidden = !msg;
  }

  function renderTargets(targets) {
    var host = $('targets');
    host.textContent = '';

    if (!targets.length) {
      host.appendChild(el('div', 'raw', '报告里没有目标应用，检查 common/targets.sh。'));
      return;
    }

    targets.forEach(function (t) {
      var card = el('div', 'card');

      var head = el('div', 'card-head');
      var left = el('div');
      left.appendChild(el('div', 'card-title', t.label || t.pkg));
      left.appendChild(el('div', 'card-pkg', t.pkg));
      head.appendChild(left);
      head.appendChild(el('span', 'badge', t.installed ? '已安装' : '未安装'));
      card.appendChild(head);

      (t.checks || []).forEach(function (c) {
        var box = el('div', 'check');

        var h = el('div', 'check-head');
        h.appendChild(el('span', 'dot ' + c.state));
        h.appendChild(el('span', 'check-name', c.name));
        h.appendChild(el('span', 'check-state', STATE_TEXT[c.state] || c.state));
        box.appendChild(h);

        if (c.detail) box.appendChild(el('div', 'check-detail', c.detail));
        if (c.fix && c.state !== 'ok') box.appendChild(el('div', 'check-fix', c.fix));

        card.appendChild(box);
      });

      host.appendChild(card);
    });
  }

  function renderReport(rep) {
    var s = rep.summary || { ok: 0, bad: 0, unknown: 0, level: 'unknown' };
    $('n-ok').textContent = s.ok || 0;
    $('n-bad').textContent = s.bad || 0;
    $('n-unk').textContent = s.unknown || 0;
    $('n-na').textContent = s.na || 0;
    setLight(s.level);

    var dev = rep.device || {};
    var bits = [];
    if (dev.brand) bits.push(dev.brand);
    if (dev.model) bits.push(dev.model);
    if (dev.android) bits.push('Android ' + dev.android);
    var cost = '';
    if (typeof rep.elapsed_seconds === 'number') {
      cost = rep.elapsed_seconds >= 1
        ? ' · 用时 ' + rep.elapsed_seconds + ' 秒'
        : ' · 用时不到 1 秒';
    }
    $('meta').textContent = '上次扫描 ' + (rep.generated_at || '未知') + cost +
      (bits.length ? ' · ' + bits.join(' ') : '');

    if (rep.module && rep.module.version) {
      $('mod-version').textContent = rep.module.version;
    }

    renderEnv(rep.environment || {});
    renderTargets(rep.targets || []);
  }

  function busy(btn, on, label) {
    if (on) {
      btn.dataset.label = btn.textContent;
      btn.disabled = true;
      btn.textContent = label || '处理中';
    } else {
      btn.disabled = false;
      if (btn.dataset.label) btn.textContent = btn.dataset.label;
    }
  }

  async function scan(btn) {
    busy(btn, true, '扫描中');
    var r;
    try {
      r = await exec(CMD.audit, TIMEOUT_SCAN);
    } finally {
      busy(btn, false);
    }

    var text = (r.out || '').trim();
    if (!text) {
      toast('扫描没有返回内容：' + failText(r), 4000);
      $('targets').textContent = '';
      $('targets').appendChild(el('div', 'raw', '扫描没有拿到结果。' + failText(r)));
      return;
    }

    var rep;
    try {
      rep = JSON.parse(text);
    } catch (e) {
      $('targets').textContent = '';
      $('targets').appendChild(el('div', 'raw', text));
      toast('报告解析失败，原始输出已显示');
      return;
    }

    renderReport(rep);
    toast('扫描完成');
  }

  async function showOutput(btn, cmd, label) {
    busy(btn, true, label);
    var r;
    try {
      r = await exec(cmd, TIMEOUT_DEF);
    } finally {
      busy(btn, false);
    }

    var text = ((r.out || '') + (r.err ? '\n' + r.err : '')).trim();
    if (!text) text = '没有任何输出：' + failText(r);

    $('targets').textContent = '';
    $('targets').appendChild(el('div', 'raw', text));
    toast('完成，结果在下方');
  }

  async function loadSettings() {
    var r = await exec(CMD.confGet);
    var map = {};

    (r.out || '').split('\n').forEach(function (line) {
      var i = line.indexOf('=');
      if (i > 0) map[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    });

    $('cfg-daemon').checked = map.daemon_enabled !== '0';
    $('cfg-interval').value = map.daemon_interval || 300;
    $('cfg-scrub').checked = map.scrub_enabled !== '0';
    $('cfg-keep').value = map.scrub_keep_days || 7;
    $('cfg-mute').value = map.mute_mode || 'gentle';
    $('cfg-prop').checked = map.prop_guard === '1';
  }

  function numOr(input, fallback, min) {
    var v = parseInt(input.value, 10);
    if (isNaN(v)) v = fallback;
    if (v < min) v = min;
    return v;
  }

  async function saveSettings() {
    var btn = $('btn-save');
    busy(btn, true, '保存中');

    var kv = [
      ['daemon_enabled', $('cfg-daemon').checked ? '1' : '0'],
      ['daemon_interval', String(numOr($('cfg-interval'), 300, 60))],
      ['scrub_enabled', $('cfg-scrub').checked ? '1' : '0'],
      ['scrub_keep_days', String(numOr($('cfg-keep'), 7, 1))],
      ['mute_mode', $('cfg-mute').value],
      ['prop_guard', $('cfg-prop').checked ? '1' : '0']
    ];

    // One bridge round trip for all six keys. Six separate calls would queue
    // six shells one after another for a job that is three file writes.
    var args = kv.map(function (p) { return p[0] + '=' + p[1]; }).join(' ');
    var r;
    try {
      r = await exec('sh ' + MOD_DIR + '/common/conf.sh setm ' + args, TIMEOUT_DEF);
    } finally {
      busy(btn, false);
    }

    if (r.code !== 0 || (r.out || '').trim() !== 'ok') {
      toast('保存没成功：' + failText(r), 4000);
      return;
    }

    toast('设置已保存');
    loadSettings();
  }

  async function loadHeartbeat() {
    var r = await exec(CMD.heartbeat + ' ; echo "|" ; ' + CMD.daemonPid);
    var parts = (r.out || '').split('|');
    var hb = (parts[0] || '').trim();
    var pid = (parts[1] || '').trim();

    var box = $('heartbeat');
    if (!hb) {
      box.textContent = '守护进程：没有心跳记录';
      return;
    }
    box.textContent = '守护进程：' + hb + (pid ? ' · pid ' + pid : '');
  }

  function renderAutoConfig(rep) {
    var list = $('ac-list');
    list.textContent = '';

    var s = rep.summary || {};
    var modeText = { 'dry-run': '预览', 'apply': '执行', 'rollback': '回滚', 'status': '上次结果' };
    $('ac-summary').textContent =
      (modeText[rep.mode] || rep.mode || '结果') + ' · ' + (rep.generated_at || '未知') +
      ' · 已确认 ' + (s.ok || 0) +
      ' · 未确认 ' + (s.failed || 0) +
      ' · 跳过 ' + (s.skipped || 0) +
      ' · 不适用 ' + (s.na || 0);

    var acts = rep.actions || [];
    if (!acts.length) {
      list.appendChild(el('div', 'raw', '没有动作记录。第一次用先点「预览」。'));
      return;
    }

    acts.forEach(function (a) {
      var box = el('div', 'check');

      var h = el('div', 'check-head');
      h.appendChild(el('span', 'dot ' + (a.state === 'na' ? 'na' : a.state)));
      h.appendChild(el('span', 'check-name', a.name || a.id));
      h.appendChild(el('span', 'check-state', AC_TEXT[a.state] || a.state));
      box.appendChild(h);

      if (a.old || a.new) {
        box.appendChild(el('div', 'check-detail', '值：' + (a.old || '?') + ' → ' + (a.new || '?')));
      }
      if (a.detail) box.appendChild(el('div', 'check-detail', a.detail));

      list.appendChild(box);
    });
  }

  async function runAutoconfig(btn, cmd, label) {
    busy(btn, true, label);
    var r;
    try {
      r = await exec(cmd, TIMEOUT_DEF);
    } finally {
      busy(btn, false);
    }

    var text = (r.out || '').trim();
    if (!text) {
      toast('没有返回内容：' + failText(r), 4000);
      return;
    }

    var rep;
    try {
      rep = JSON.parse(text);
    } catch (e) {
      $('ac-list').textContent = '';
      $('ac-list').appendChild(el('div', 'raw', text));
      $('ac-summary').textContent = '输出解析失败，原始内容已显示';
      return;
    }

    renderAutoConfig(rep);

    // The audit report carries the autoconfig verdict, so refresh it. Do this
    // before the toast, otherwise scan() overwrites the message below.
    await scan($('btn-scan'));

    var failed = (rep.summary && rep.summary.failed) || 0;
    toast(failed > 0 ? ('完成，有 ' + failed + ' 项没确认') : '完成');
  }

  function showUpstream(rep) {
    var box = $('ac-upstream');
    if (!rep) {
      box.textContent = '上游状态：读不出来';
      return;
    }
    if (!rep.ok) {
      box.textContent = '上游状态：' + (rep.reason || '未核对');
      return;
    }
    var ids = rep.feature_ids || [];
    box.textContent = '上游状态：' + (rep.checked_at || '') + ' 经 ' + (rep.source || '?') +
      ' 读到 ' + ids.length + ' 项（' + ids.join(', ') + '）';
  }

  async function runUpstream(btn) {
    busy(btn, true, '核对中');
    var r;
    try {
      r = await exec(CMD.upstreamCheck, TIMEOUT_NET);
    } finally {
      busy(btn, false);
    }

    var text = (r.out || '').trim();
    var rep = null;
    try { rep = JSON.parse(text); } catch (e) { rep = null; }

    if (!rep) {
      $('ac-upstream').textContent = '上游状态：没有拿到结果（' +
        (text ? text.slice(0, 60) : failText(r)) + '）';
      return;
    }

    showUpstream(rep);
    toast(rep.ok ? '上游核对完成' : '上游没连上，包内基线继续用');
  }

  async function loadUpstream() {
    var r = await exec(CMD.upstreamShow);
    var text = (r.out || '').trim();
    if (!text) return;
    var rep = null;
    try { rep = JSON.parse(text); } catch (e) { return; }
    showUpstream(rep);
  }

  async function loadAutoStatus() {
    var r = await exec(CMD.acStatus);
    var text = (r.out || '').trim();
    if (!text) return;

    var rep;
    try { rep = JSON.parse(text); } catch (e) { return; }

    if (!(rep.actions || []).length) {
      $('ac-summary').textContent = '还没有执行记录。先点「预览」看会改什么。';
      return;
    }
    renderAutoConfig(rep);
  }

  // ---------- HMA probe ----------
  // Read-only by design: the panel shows what is in HMA's store, it never
  // writes there. A config a foreign process rewrites gets silently reverted
  // by HMA on its next save, with a corrupt window in between.
  var VERDICT_TEXT = {
    configured: 'HMA 里已有隐藏规则',
    empty: 'HMA 在运行，但还没有配置任何规则',
    unknown: 'HMA 配置状态未确认'
  };

  // Named apart from the check-state map above on purpose: both used to be
  // called STATE_TEXT in this scope, and the later assignment silently replaced
  // the earlier one, so every audit row printed its raw state token.
  var HMA_STATE_TEXT = {
    empty: '空',
    has_entries: '有内容',
    missing: '没读到'
  };

  function renderHma(rep) {
    var body = $('hma-body');
    body.textContent = '';

    if (!rep) {
      $('hma-summary').textContent = '还没有探测记录';
      return;
    }

    var dirs = rep.dirs || [];
    if (!dirs.length) {
      $('hma-summary').textContent = (rep.generated_at || '') + ' 没找到 HMA 的状态目录';
      var n0 = el('div', 'hint', rep.note || '');
      body.appendChild(n0);
      return;
    }

    var head = [rep.generated_at || ''];
    if (VERDICT_TEXT[rep.verdict]) head.push(VERDICT_TEXT[rep.verdict]);
    head.push(dirs.length + ' 个目录');
    head.push((rep.files_scanned || 0) + ' 个文件');
    $('hma-summary').textContent = head.join(' · ');

    var cfgRows = [
      ['隐藏模板', HMA_STATE_TEXT[rep.templates_state]],
      ['设置模板', HMA_STATE_TEXT[rep.settings_templates_state]],
      ['过滤计数', HMA_STATE_TEXT[rep.filter_counts_state]]
    ];
    if (rep.work_mode) cfgRows.push(['工作模式', String(rep.work_mode)]);
    if (rep.config_version) cfgRows.push(['配置版本', String(rep.config_version)]);

    cfgRows.forEach(function (r) {
      var row = el('div', 'hma-row');
      row.appendChild(el('span', 'hma-k', r[0]));
      var v = r[1] || '没读到';
      row.appendChild(el('span', v === '有内容' ? 'hma-v ok' : 'hma-v dim', v));
      body.appendChild(row);
    });

    if (rep.filter_count_entries) {
      body.appendChild(el('div', 'hma-head', '计数：' + rep.filter_count_entries));
    }

    if (rep.targets_source === 'fallback') {
      body.appendChild(el('div', 'hint',
        '目标列表没有从 targets.sh 读到，这次用的是内置默认包名。'));
    }

    var tg = rep.targets || {};
    Object.keys(tg).forEach(function (p) {
      var row = el('div', 'hma-row');
      row.appendChild(el('span', 'hma-k', p));
      var n = tg[p] || 0;
      row.appendChild(el('span', n > 0 ? 'hma-v ok' : 'hma-v dim',
        n > 0 ? ('出现 ' + n + ' 次') : '没有出现'));
      body.appendChild(row);
    });

    dirs.forEach(function (d) {
      body.appendChild(el('div', 'hma-dir', d.path));
      (d.files || []).forEach(function (f) {
        var row = el('div', 'hma-file');
        row.appendChild(el('span', 'hma-fn', f.name));
        row.appendChild(el('span', 'hma-fs',
          (typeof f.size === 'number' && f.size >= 0) ? (f.size + ' B') : '大小未知'));
        body.appendChild(row);
        if (f.head) body.appendChild(el('div', 'hma-head', f.head));
      });
    });

    var raw = $('hma-raw');
    raw.textContent = JSON.stringify(rep, null, 1);
  }

  async function runHma(btn) {
    busy(btn, true, '探测中');
    var r;
    try {
      r = await exec(CMD.hmaProbe, TIMEOUT_SCAN);
    } finally {
      busy(btn, false);
    }

    var text = (r.out || '').trim();
    if (!text) {
      $('hma-summary').textContent = '没有返回内容：' + failText(r);
      return;
    }

    var rep;
    try {
      rep = JSON.parse(text);
    } catch (e) {
      $('hma-summary').textContent = '输出解析失败，原始内容在下面';
      $('hma-raw').textContent = text;
      return;
    }

    renderHma(rep);

    // The audit report carries the HMA verdict, so refresh it first: scan()
    // rewrites the meta line the toast would otherwise be read against.
    await scan($('btn-scan'));
    toast('探测完成');
  }

  async function loadHma() {
    var r = await exec(CMD.hmaShow);
    var text = (r.out || '').trim();
    if (!text) return;
    var rep;
    try { rep = JSON.parse(text); } catch (e) { return; }
    renderHma(rep);
  }

  // ---------- config lifecycle ----------
  // Settings live outside the module directory, so an update replaces code and
  // leaves them alone. What an update can do is bring a key the file has never
  // seen; migrate.sh --apply fills those in at install time and at boot, and
  // this card shows what it found.
  var MIG_STATE_TEXT = {
    fresh: '首次写入',
    missing_keys: '有键待补齐',
    current: '键完整'
  };

  function migSummary(rep) {
    var bits = [];
    if (rep.module_version) bits.push('当前 ' + rep.module_version);
    if (rep.installed_version) {
      bits.push('上次安装 ' + rep.installed_version +
        (rep.installed_at ? '（' + rep.installed_at + '）' : ''));
    } else {
      bits.push('还没有安装记录');
    }
    bits.push(MIG_STATE_TEXT[rep.state] || '状态未知');
    bits.push(rep.backups ? ('快照 ' + rep.backups + ' 份') : '还没有快照');
    return bits.join(' · ');
  }

  function renderMig(rep) {
    var body = $('mig-body');
    body.textContent = '';

    $('mig-summary').textContent = migSummary(rep);

    var missing = rep.missing || [];
    var extra = rep.extra || [];
    var schema = String(rep.schema || 0);
    var want = String(rep.schema_expected || 0);

    var rows = [
      ['配置文件', rep.config_existed ? '已存在' : '这次新建', rep.config_existed ? 'ok' : 'dim'],
      ['配置键', (rep.keys_present || 0) + ' / ' + (rep.keys_total || 0), 'dim'],
      ['缺失键', missing.length ? missing.join('、') : '无', missing.length ? 'warn' : 'ok'],
      ['多余键', extra.length ? extra.join('、') : '无', extra.length ? 'warn' : 'ok'],
      ['架构版本', schema === want ? schema : (schema + '（应为 ' + want + '）'), schema === want ? 'dim' : 'warn'],
      ['最近备份', rep.last_backup || '无', rep.last_backup ? 'ok' : 'dim']
    ];

    rows.forEach(function (r) {
      var row = el('div', 'mig-row');
      row.appendChild(el('span', 'mig-k', r[0]));
      row.appendChild(el('span', 'mig-v ' + r[2], r[1]));
      body.appendChild(row);
    });
  }

  async function runMigCheck(btn, quiet) {
    if (btn) busy(btn, true, '核对中');
    var r;
    try {
      r = await exec(CMD.migCheck, TIMEOUT_DEF);
    } finally {
      if (btn) busy(btn, false);
    }

    var text = (r.out || '').trim();
    if (!text) {
      $('mig-summary').textContent = '没有返回内容：' + failText(r);
      return;
    }

    var rep;
    try {
      rep = JSON.parse(text);
    } catch (e) {
      $('mig-summary').textContent = '输出解析失败';
      $('mig-body').textContent = '';
      $('mig-body').appendChild(el('div', 'raw', text));
      return;
    }

    renderMig(rep);

    if (!quiet) {
      var n = (rep.missing || []).length;
      toast(n ? ('配置缺 ' + n + ' 项，开机时会自动补齐') : '配置键完整');
    }
  }

  async function runMigSnapshot(btn) {
    busy(btn, true, '备份中');
    var r;
    try {
      r = await exec(CMD.migSnapshot, TIMEOUT_DEF);
    } finally {
      busy(btn, false);
    }

    var text = (r.out || '').trim();
    var rep = null;
    try { rep = JSON.parse(text); } catch (e) { rep = null; }

    if (!rep) {
      toast('备份没成功：' + (text ? text.slice(0, 60) : failText(r)), 4000);
      return;
    }
    if (!rep.ok) {
      toast('备份没成功：' + (rep.reason || '没有可备份的文件'), 4000);
      return;
    }

    toast('已备份到 ' + rep.name + '，' + rep.copied_count + ' 个文件');
    await runMigCheck(null, true);
  }

  // Restoring overwrites the current settings, so it takes two presses. A
  // native confirm() would be shorter, but the bridge's WebView is not obliged
  // to implement one, and a dialog that never answers is the same freeze this
  // panel already spent a version removing.
  var _restoreArmed = false;
  var _restoreTimer = null;

  function disarmRestore() {
    _restoreArmed = false;
    if (_restoreTimer) { clearTimeout(_restoreTimer); _restoreTimer = null; }
    var btn = $('btn-mig-restore');
    if (btn && btn.dataset.label) btn.textContent = btn.dataset.label;
  }

  function restoreClick(btn) {
    if (!_restoreArmed) {
      _restoreArmed = true;
      btn.dataset.label = btn.textContent;
      btn.textContent = '再点一次，覆盖当前配置';
      toast('会用最近一份快照覆盖当前设置；覆盖前会先备份现在这份。', 5000);
      _restoreTimer = setTimeout(disarmRestore, 6000);
      return;
    }
    disarmRestore();
    runMigRestore(btn);
  }

  async function runMigRestore(btn) {
    busy(btn, true, '恢复中');
    var r;
    try {
      r = await exec(CMD.migRestore, TIMEOUT_DEF);
    } finally {
      busy(btn, false);
    }

    var text = (r.out || '').trim();
    var rep = null;
    try { rep = JSON.parse(text); } catch (e) { rep = null; }

    if (!rep) {
      toast('恢复没成功：' + (text ? text.slice(0, 60) : failText(r)), 4000);
      return;
    }
    if (!rep.ok) {
      toast('恢复没成功：' + (rep.reason || '原因不明'), 4000);
      return;
    }

    var msg = '已恢复到 ' + rep.name + '（' + rep.restored_count + ' 个文件）';
    if ((rep.backfilled || []).length) {
      msg += '，补了 ' + rep.backfilled.length + ' 项新键';
    }
    toast(msg, 4000);

    // The form fields still hold the values from before the restore. Reloading
    // them is not cosmetic: pressing 保存设置 next would write those old values
    // straight back over the file that was just restored.
    await loadSettings();
    await runMigCheck(null, true);
  }

  function loadMig() { return runMigCheck(null, true); }

  async function init() {
    $('btn-scan').addEventListener('click', function () { scan(this); });

    $('btn-scrub-preview').addEventListener('click', function () {
      showOutput(this, CMD.scrubDry, '预览中');
    });

    $('btn-scrub').addEventListener('click', function () {
      showOutput(this, CMD.scrub, '清扫中');
    });

    $('btn-restore').addEventListener('click', function () {
      showOutput(this, CMD.restore, '还原中');
    });

    $('btn-release').addEventListener('click', function () {
      showOutput(this, CMD.release, '释放中');
    });

    $('btn-save').addEventListener('click', saveSettings);

    $('btn-ac-preview').addEventListener('click', function () {
      runAutoconfig(this, CMD.acDry, '预览中');
    });

    $('btn-ac-apply').addEventListener('click', function () {
      runAutoconfig(this, CMD.acApply, '执行中');
    });

    $('btn-ac-rollback').addEventListener('click', function () {
      runAutoconfig(this, CMD.acRollback, '回滚中');
    });

    $('btn-ac-upstream').addEventListener('click', function () {
      runUpstream(this);
    });

    $('btn-hma').addEventListener('click', function () {
      runHma(this);
    });

    $('btn-mig-check').addEventListener('click', function () {
      runMigCheck(this);
    });

    $('btn-mig-snapshot').addEventListener('click', function () {
      runMigSnapshot(this);
    });

    $('btn-mig-restore').addEventListener('click', function () {
      restoreClick(this);
    });

    if (typeof ksu === 'undefined') {
      $('meta').textContent = '不在 KernelSU WebUI 环境里，按钮无法执行命令。';
    }

    // One root shell at a time. Every ksu.exec starts a fresh shell that
    // re-runs env.sh, so five at once only queue up behind each other and the
    // scan the user is waiting for ends up last in line.
    await scan($('btn-scan'));
    loadSettings();
    loadHeartbeat();
    loadAutoStatus();
    loadUpstream();
    loadHma();
    loadMig();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
