# LSPosed Stealth

一个 KernelSU 模块，用来守住 LSPosed 作用域、Zygisk 排除名单与挂载隔离这三项
运行时配置的基线，并在配置走样、痕迹残留时把问题暴露出来。

审计对象不写死在文档里，清单在 `common/targets.sh`，一行一个：
`<package>|<显示名>`。下文出现「目标应用」，指的就是那份清单里的条目。

---

## 一、先读这一段

**它能做的：**

- 逐项检查 LSPosed 作用域里有没有目标应用
- 检查 Zygisk 排除名单是否包含这两个包，强制生效开关是否打开
- 在目标应用运行时，直接读它自己的 `/proc/<pid>/mounts`，看模块路径有没有漏进去
- 报告可疑的只读属性
- 检查最近 24 小时的 LSPosed 日志里有没有出现目标包
- 清扫 LSPosed 日志、dropbox 记录、`/data/local/tmp` 残留、管理器缓存（先隔离，不硬删）
- 把 KernelSU 的 feature 基线和本模块目录权限调到位，改一项读回一项，可整体回滚
- 后台按间隔重复上面这些，留下心跳记录

**它做不到的：**

目标应用的安全模块跑在自己进程里，检测 `/proc/self/maps`、Java 层堆栈、
ClassLoader、自身 so 代码段完整性。这些东西在目标进程内部，root shell 接触不到。
本模块不能修改、不能伪装、也不能证明它们干净。

所以本模块验证的是**配置**，不是**应用实际看见了什么**。
这两者之间还有一段需要你在真机上验证的距离，流程写在第五节。

**另外：这台设备已经有过一次封号记录。**
把环境调干净能降低再次命中的概率，但那段历史不会因为刷了模块就消失。

---

## 二、为什么不做「完全隐藏」

试过之后会卡在三个地方：

| 层 | 需要什么 | 本项目 |
|---|---|---|
| Zygisk 层 | 目标进程内注入并接管检测点 | 不做。只在外部读配置 |
| 内核层 | SUSFS 之类的路径级隐藏 | 不做。需要换内核 |
| KSU 模块层 | 文件痕迹、属性、配置基线 | 本项目 |

官方 KernelSU 内核没有 SUSFS，`/data/adb/lspd` 这类路径无法对深度扫描隐藏。
真要补上这一层，得换内核，超出「刷个模块」的范围。

面板的环境行会把这件事直接写出来：`KernelSU · LKM 模式 · …… · 无 SUSFS`。
LKM 是加载的内核模块，GKI 是编译进内核镜像，两者在 `/sys/module` 和 `/proc/modules`
里留下的痕迹不同，所以能分清。SUSFS 则从三处独立痕迹判断——模块表、符号表、模块目录——
三处都读不到时才写「未确认」，不会把「没查到」当成「没有」。

现在这条路线的逻辑是：**只要注入不发生，进程内就没有痕迹可查。**
而注入是否发生，由作用域、排除名单、挂载隔离这三项配置决定。
把这三项守住，比事后清扫有效得多。

---

## 三、组成

```
module.prop            模块声明（id、版本、用途说明）
customize.sh           安装期检查
post-fs-data.sh        开机早期：目录准备、属性伪装（可选）
service.sh             开机后期：拉起后台循环
boot-completed.sh      系统就绪：立刻产出第一份报告
uninstall.sh           卸载：还原隔离区、清掉自己的数据
sepolicy.rule          故意留空，理由写在文件里
system.prop            故意留空，理由写在文件里

common/env.sh          运行时探测层（busybox / ksud / sqlite3 / resetprop / 内核形态 / SUSFS）
common/targets.sh      目标应用清单，加新应用只改这里
common/audit.sh        五项检查 + 生成 report.json
common/scrub.sh        隔离式清扫、回收、还原
common/mute.sh         日志抑制（温和 / 激进）
common/conf.sh         配置读写，给面板用
common/known.json      离线基线：feature id 名单、四种状态、镜像列表
common/upstream.sh     联网核对上游 feature 名单，镜像降级
common/autoconfig.sh   自动配置：预览 / 执行 / 回滚 / 状态
common/hma.sh          只读探测 HMA 的状态存储，不写入
common/migrate.sh      配置生命周期：核对 / 补齐 / 备份 / 恢复
common/daemon.sh       后台循环

webroot/               WebUI 面板
tools/pack.ps1         打包脚本
```

---

## 四、安装

1. 用 `tools/pack.ps1` 生成 zip（见第九节），或直接用现成的 `dist/*.zip`
2. KernelSU 管理器 → 模块 → 从本地安装
3. 重启

刷完先别急着打开目标应用。下一节。

仓库里的成品包放在 `release/`，文件名带版本号。当前这一份：

```
release/lsposed_stealth-v1.2.2.zip
SHA256  5bfa9463ff25a7d5ff1d3b74ad3364567cd02201a97b3a936c8d466eb6b6c58e
```

---

## 五、上线前验证流程

这一步不能跳。模块不能替你证明目标应用看不见什么。

1. **刷入 → 重启 → 打开模块面板**
   看顶部红绿灯和各项检查。面板中段的「自动配置」可以先点一次「预览」，
   看清楚它准备改什么再决定执行——它只动 feature 开关和本模块目录，
   全程不写别人的配置。改动会留记录，随时能回滚。

2. **把红色项按指引改掉**
   每项 `bad` 下面都有一段具体操作说明，照着做。
   改完强行停止目标应用，再回来重新扫描。

3. **黄色项要么查清楚，要么接受**
   `unknown` 表示这项探测跑不起来（缺 sqlite3、版本差异、应用没运行）。
   它不等于通过。点开看 detail，写的是具体原因。

4. **用检测器交叉验证**
   装 Momo、Ruru 或 RootBeer，扫一遍。
   重点看与 LSPosed、Zygisk、mount 相关的项。
   模块面板全绿、检测器也干净，才有底气往下走。

5. **确认干净之后，再登录目标应用**

6. **登录后观察一段时间，回来再跑一次扫描**
   如果作用域被某个模块偷偷加回去了，这一步能抓到。

---

## 六、面板说明

打开方式：KernelSU 管理器 → 模块 → 本模块 → 打开。

- **顶部红绿灯**：绿=全部通过，黄=有查不到的项，红=有异常项
- **四格数字**：通过 / 异常 / 查不到 / 不适用
- **目标卡片**：清单里每个应用一张，每一项一条
- **按钮**：立即扫描 / 清扫预览 / 执行清扫 / 还原最近一次 / 释放日志锁
- **自动配置**：预览 / 执行 / 回滚 / 核对上游，下面逐条列出结果
- **HMA 隐藏配置**：只读探测 HMA 存了什么，下面能展开原始结果
- **更新与配置**：核对配置键、立即备份、从最近快照恢复
- **设置**：守护开关、间隔、自动清扫、隔离保留天数、日志抑制档位、属性伪装

「查不到」和「不适用」都不计入通过。红绿灯只在异常数为 0 时才可能变绿。

「不适用」是第四种状态，只有一个含义：**这一项在你的环境里本来就不该管**。
目前会判成不适用的情况有两种——装了 HMA-OSS 一类注入隐藏模块时的 Zygisk 排除名单，
以及本模块从不触碰的 Magisk denylist。

它和「查不到」的区别值得分清：查不到是我没能确认，不适用是确认过了、而且不需要动。
把这两者混成一个灰色，会让人误以为还有事没做完。

---

## 七、设置项

| 键 | 默认 | 说明 |
|---|---|---|
| `daemon_enabled` | 1 | 后台循环开关 |
| `daemon_interval` | 300 | 每轮间隔（秒），最低 60 |
| `scrub_enabled` | 1 | 每轮是否清扫 |
| `scrub_keep_days` | 7 | 隔离区保留天数，超期回收 |
| `mute_mode` | gentle | `gentle` / `aggressive` / `off` |
| `prop_guard` | 0 | 属性伪装，重启生效 |
| `mute_size_kb` | 256 | 温和档的触发阈值 |
| `autoconfig_enabled` | 1 | 自动配置总开关 |
| `autoconfig_on_boot` | 1 | 开机完成后套用一次基线 |

配置存在 `/data/adb/<模块ID>/config/settings.conf`，改完即时生效，不用重启。

这些键的默认值只有一个来源：`common/env.sh` 里的 `CONF_DEFAULTS`。首次安装的初值、
升级时补的键、面板「更新与配置」里报的缺失项，都读同一张表。

**日志抑制两档：**

- `gentle`：日志目录超过阈值才清，按修改时间清最旧的，保留最新一个文件
- `aggressive`：给日志目录加 `chattr +i` 不可变锁。**不是所有文件系统支持**，
  不支持时会自动退回温和档，并在日志里写明「degraded」

**属性伪装：**
改写 `ro.debuggable`、`ro.secure`、`ro.build.tags`、`ro.boot.flash.locked`。
默认关闭，因为改这些可能影响其他应用行为，而且对内核级检测无效。
`ro.boot.verifiedbootstate=orange` 是解锁的物理结果，改不掉，也不计入判定。

---

## 八、手动命令

在终端（root）里直接跑，输出就是 JSON 或文本：

```sh
M=/data/adb/modules/lsposed_stealth

sh $M/common/audit.sh                 # 扫描，打印 report.json
sh $M/common/scrub.sh --dry-run       # 清扫预览，不动任何文件
sh $M/common/scrub.sh                 # 执行清扫
sh $M/common/scrub.sh --restore       # 还原最近一批
sh $M/common/scrub.sh --restore 20261025-173000   # 还原指定批次
sh $M/common/scrub.sh --gc            # 只跑过期回收
sh $M/common/mute.sh --gentle         # 手动走温和档
sh $M/common/mute.sh --aggressive     # 手动走激进档
sh $M/common/mute.sh --release        # 解除不可变锁
sh $M/common/conf.sh get              # 看全部配置
sh $M/common/conf.sh set mute_mode off
sh $M/common/autoconfig.sh --dry-run  # 预览自动配置会改什么，不写入
sh $M/common/autoconfig.sh            # 执行，每个改动都读回确认
sh $M/common/autoconfig.sh --rollback # 按记录逆序还原
sh $M/common/autoconfig.sh --status   # 看上次结果
sh $M/common/upstream.sh --check      # 联网核对上游 feature 名单
sh $M/common/upstream.sh --show       # 看缓存，不联网
sh $M/common/upstream.sh --clear      # 清掉缓存
sh $M/common/hma.sh probe             # 只读探测 HMA 存储，打印 JSON
sh $M/common/migrate.sh --check       # 核对配置键，只读
sh $M/common/migrate.sh --apply       # 补齐缺失的键，已有的值不动
sh $M/common/migrate.sh --snapshot    # 手动打一份快照
sh $M/common/migrate.sh --restore     # 恢复到最近一份快照
sh $M/common/migrate.sh --restore 20261025-195803   # 恢复到指定快照
```

日志和状态都在 `/data/adb/lsposed_stealth/`：

```
state/report.json      最近一次扫描结果
state/heartbeat        后台循环最后一次心跳
state/daemon.pid       循环进程号
state/autoconfig/last.json     最近一次自动配置结果
state/autoconfig/records.log   改动记录，回滚的依据
state/autoconfig/snapshot/     执行前后的受保护文件哈希
state/upstream.conf            上游核对缓存
state/hma.json                 HMA 只读探测结果
config/settings.conf   配置
config/install.info    上次安装的版本与时间
backup/<时间戳>/       配置快照，保留最近 5 份
quarantine/            隔离区，每批一个时间戳目录
audit.log / scrub.log / mute.log / autoconfig.log / upstream.log
```

---

## 九、打包（换模块名）

```powershell
# 默认，用 module.prop 里现有的 id
powershell -ExecutionPolicy Bypass -File tools\pack.ps1

# 换 id 与显示名
powershell -ExecutionPolicy Bypass -File tools\pack.ps1 `
  -ModuleId my_module `
  -ModuleName "LSPosed Stealth"

# 换输出目录
powershell -ExecutionPolicy Bypass -File tools\pack.ps1 -OutputDir D:\out
```

脚本会做四件事：

1. 校验 21 个必需文件都在
2. 把 `-ModuleId` 写进 `module.prop` 和 `webroot/app.js`（只有这两处，其余都是运行时推导）
3. 检查所有 `.sh` 必须是 LF 换行，有 CRLF 直接失败
4. 打包后复查 zip 条目名，出现反斜杠直接失败并删掉产物

第 4 条不是多余的。PowerShell 5.1 跑在 .NET Framework 上，
`ZipFile.CreateFromDirectory` 会往条目名里写反斜杠，Android 的 unzip 会把它
当成文件名的一部分，整个模块目录结构就散了。脚本手工构建条目名来避开这个坑。

**模块 id 换掉之后**，`/data/adb/<新ID>` 会是一个全新的数据目录，
旧的隔离区不会自动迁移。换名前先手动 `--restore` 一次。

---

## 十、自动配置与联网核对

### 它管什么

只碰两类东西：

1. KernelSU 的 feature 开关——`su_compat`、`kernel_umount`、`sulog`、`adb_root`、
   `selinux_hide`、`shell_su_adb_only`
2. 本模块自己目录的权限

### 它不碰什么

- LSPosed 的作用域和模块列表
- Magisk / KernelSU 的 denylist
- Zygisk Next 的排除名单
- 任何其他模块的目录与配置

这四条不是靠"写代码时小心一点"来保证的，是代码里根本没有指向这些位置的写入路径。
所以面板上 `denylist_guard` 这一项永远显示不适用——不是"暂时不用管"，是"不存在这个动作"。

### 和 HMA-OSS 共存

这一条值得单独讲，因为踩上去会直接抵消掉隐藏效果。

装了 HMA-OSS 一类靠 zygisk 注入来隐藏应用的模块时，把目标包名加进
Zygisk 排除名单，会把 HMA 对它的隐藏一起掐掉——两者走的是同一条注入路径，
排除名单按目标包名匹配，不分是谁提供的隐藏。

所以探测到注入族模块在场之后：

- 自动配置里 `zygisk_exclusion` 直接跳过，不写入
- 扫描里 `zygisk_denylist` 判为「不适用」，而不是判红、也不再建议你加进去
- 面板顶部会写明在场的是哪个模块

判定依据是模块目录名匹配（`*hide_my_app*`、`*hma*`）和 HMA 的状态目录，
不去读别人的配置文件，也不改动它们。

### 读 HMA 的配置（只读）

自动配置不写 HMA，但它可以读。

面板上「探测 HMA 配置」这一块会把 HMA 的状态目录找出来，列出里面每个文件的名字、
大小、开头几百个字节，以及每个目标包名在这些文件里出现了多少次。

为什么只读不写：HMA 把自己的内存状态在退出时写回磁盘。外部改的文件会被它覆盖，
中间那段还可能被它读到半截。改它的正确入口是它自己的界面，不是别人替它动文件。

扫描里对应的检查项叫 `hma_store`：

| 情况 | 判定 |
|---|---|
| 本机没有 HMA | 不适用 |
| HMA 在场，但状态目录一条已知路径都没命中 | 未确认，并列出探测到的目录 |
| 目录找到了但读不出文件 | 未确认 |
| 读到包名出现 N 次 | 已确认，写明次数 |
| 存储能读但一次都没出现目标包名 | 未确认 |

最后一行是这一项最重要的地方。HMA 也可能用模板名或 uid 记账，那样就搜不到包名；
这跟「确实没给这个应用配隐藏」在磁盘上是同一个样子，分不出来。所以不判红，
也不说通过，只说「从这里分不出来」。

「探测 HMA 配置」下面有个展开项，能把原始结果整段复制出来。
发回来就能把新的存储格式补进解析里。

### 四种结果

| 状态 | 含义 |
|---|---|
| 已确认 | 改了，并且读回来确认是新值 |
| 未确认 | 改过但读回不是期望值，或缺少工具无法验证 |
| 跳过 | 有意不动：预览模式、注入族模块在场、或需要你自己判断的项 |
| 不适用 | 你的环境里本来就不该管这一项 |

「未确认」不是「失败」，是「我没能证明它成功了」。
比如设备上缺 `sha256sum` 时，完整性检查会报未确认，并写明"无法证明这些文件没被碰过"，
而不是假装通过。这条区别决定了你能不能在面板变绿时真的放心。

### 回滚

执行前把每个改动写进 `records.log`，格式是 `动作|键|旧值|新值`。
回滚时逆序读回，把旧值写回去，每一条同样读回确认。

回滚只认自己写下的记录。它不会去猜"这个值原来应该是多少"，
也不会去动记录之外的任何东西。

### 联网边界

- 只在你点「核对上游」时才发起请求，其余时候完全不联网
- 读的是上游 KernelSU 仓库里两个文件的内容，只做特征提取：
  feature id 名单、四个状态 token
- 不发送任何设备信息，不携带模块 id
- 镜像按 `cdn.jsdelivr.net` → `ghproxy.net` → `raw.githubusercontent.com` 顺序降级，
  全部连不上就用包内基线，功能不中断
- 结果落盘到 `state/upstream.conf`，下次启动直接读缓存

### 为什么需要联网

上游会加新 feature，也可能改名。本地基线是一份写死的名单，
时间一长，要么漏掉新项，要么把已经改名的旧项当成"上游不再有"而误判。

核对一次能把这名单校准回来。校准只影响"哪些名字算是合法 feature"，
不改变任何开关的实际取值——换句话说，它纠正的是判断依据，不是替你拨开关。

### 能力边界

- 不能证明应用进程内看不到我们的模块目录。它能保证的是：配置和权限在 root 视角下是对的
- 没有 `ksud` 的环境改不了 feature。沙箱里那个 `--fake-ksud` 只用于自测，不是给真机用的
- 不能替代真机检测器。真机上跑一遍检测 App 才算数

---

## 十一、升级与配置沿用

设置和扫描结果存在 `/data/adb/<模块ID>/`，模块代码在 `/data/adb/modules/<模块ID>/`。
刷入新版本只替换后者，前面那个目录不会被覆盖，所以**升级不用重新配置**。

这件事由 `common/migrate.sh` 负责，安装、开机、面板都调它：

| 子命令 | 做什么 | 谁调用 |
|---|---|---|
| `--check` | 只读。报配置状态、缺哪些键、有几份快照、上次装的是哪个版本 | 面板「核对配置」 |
| `--apply` | 只补缺的键，已有的值一个字不改；记下当前版本和安装时间 | 安装脚本、开机脚本 |
| `--snapshot` | 把配置、自动配置基线、上游缓存、HMA 探测结果复制到 `backup/<时间戳>/` | 安装脚本、面板 |
| `--restore` | 覆盖回某份快照；覆盖前先给当前状态备份一份 | 面板「从最近快照恢复」 |

**安装时会看到什么**

```
- 沿用已有配置（8 项）
- 已备份到 20261025-195803
- 配置键完整
```

首次安装则是「首次安装，写入默认配置」。新版本引入了新键时，那一行会变成
「补齐新增配置键 N 项」。

**快照**

- 位置：`/data/adb/<模块ID>/backup/<YYYYmmdd-HHMMSS>/`，保留最近 5 份，多的删最旧
- 内容：`config/settings.conf`、`autoconfig/last.json`、`autoconfig/baseline.snap`、
  `state/upstream.conf`、`state/hma.json`。不存在的文件跳过，不补空文件
- 每次装快照都带 `meta.txt`，写明来源（install / manual / pre-restore）、时间、版本

**恢复是覆盖操作**：手改过的值会被快照里的旧值替换。所以恢复前会强制先拍一份
`pre-restore` 快照，退回去之后还能再退回来。面板上要连点两次按钮才执行，中间那句
「再点一次，覆盖当前配置」就是这一步。

**不保证的部分**：走「卸载模块」再重装，配置会随 `uninstall.sh` 一起清掉。
这是有意的——隐藏类模块在 `/data/adb` 留残留本身就是痕迹，卸载就该清干净。
想跨卸载保留，卸载前自己把 `backup/` 拷到手机存储。

---

## 十二、已知局限

| 局限 | 影响 |
|---|---|
| 无 SUSFS 内核 | `/data/adb/lspd` 路径无法对深度扫描隐藏 |
| root 命名空间 ≠ App 命名空间 | 只能验证配置，不能替代真机检测器 |
| Zygisk Next / LSPosed 配置格式随版本变化 | 探测失败一律降级为 `unknown`，不会瞎猜 |
| `chattr +i` 不是所有文件系统支持 | 激进档会自动退回温和档 |
| 只按文件名匹配 dropbox 记录 | 内容里含关键字但文件名不含的会漏掉 |
| 不自动改他人配置 | LSPosed / Zygisk Next 的配置只读不写 |
| 内核不支持某个 feature | `feature get` 没有 Value 行，该项自动跳过而不是报错 |
| 上游改名或镜像全连不上 | 退回包内基线，功能不中断，但新 feature 认不出来 |
| 注入族模块目录命名不统一 | 探测按常见命名匹配，非常规命名会漏判，此时排除名单按普通逻辑判定 |
| 数据分区不支持 chmod | 权限项会一直「未确认」，不影响其余判定 |
| HMA 存储不在已探测的路径里 | `hma_store` 判未确认，用「探测 HMA 配置」把目录发回来可以补上 |
| HMA 用模板名或 uid 记账 | 搜不到目标包名，只能判未确认；既不判红也不说通过 |
| 不写 HMA 的配置 | 想做隐藏必须去它自己的界面改，本模块不代劳也不假装代劳 |
| 卸载会清掉数据目录 | 配置不跨卸载保留，要留就把 `backup/` 先拷出来 |
| 快照只留最近 5 份 | 更早的会被自动删掉，长期留档请自己另存 |

---

## 十三、卸载

KernelSU 管理器里卸载即可，会触发 `uninstall.sh`：

1. 解除日志目录的不可变锁
2. 杀掉后台循环
3. 把隔离区里的东西按 manifest 全部移回原处
4. 删掉 `/data/adb/<模块ID>`

**顺序是有意的**：先还原，再删自己的数据。反过来的话隔离区里的东西就回不去了。

如果卸载前想保留证据，先把 `state/report.json` 和 `quarantine/` 拷出来。

---

## 十四、排查

**点按钮一直转，转完什么也没发生**

1.1.3 之前有过这个毛病：面板把 JS 回调函数直接交给 KernelSU 的桥接层，而
`ksu.exec(command, optionsJSON, callbackName)` 的第三个参数要的是**函数名的字符串**，
原生侧靠它拼出 `window[名字](errno, stdout, stderr)`。传函数对象时这句求值不成立，
回调一次都不会来，表现为按钮永远转、没有任何报错——而桥接同一时刻只跑一个 shell，
所以扫描卡住之后，保存设置和核对上游也会一起卡在同一处。

1.1.3 起改用函数名，并给每条命令加了兜底超时（扫描 60 秒，联网核对 45 秒，
其余 20 秒）。超时后会明确告诉你"命令没有在限定时间内返回"，按钮回到可点状态，
不会再无声冻结。若仍然超时：

```sh
ps -A | grep -E 'audit|upstream|autoconfig'
```

残留的旧进程会占着桥接队列，结束掉再点一次。

**面板全黄，全是 `unknown`**

多数是设备上没有 `sqlite3`。检查：

```sh
which sqlite3
ls /data/adb/ksu/bin/busybox
```

KernelSU 自带的 busybox 通常没有 sqlite3 applet。装一个带 sqlite3 的 busybox，
或者接受这一项未知、改用 LSPosed 管理器人工确认。

**`mount_view` 一直 `unknown`**

目标应用没在运行，或者 hidepid 挡住了 `/proc/<pid>/mounts`。
先打开一次目标应用，再回面板重新扫描。

**后台循环没有心跳**

```sh
cat /data/adb/lsposed_stealth/audit.log | tail -20
cat /data/adb/lsposed_stealth/state/daemon.pid
```

看日志里有没有 `daemon: started`。没有的话检查 `daemon_enabled` 是否为 1，
以及模块目录下有没有 `disable` 文件。

**清扫之后 LSPosed 管理器报错**

先把 `mute_mode` 设回 `gentle`，跑一次 `mute.sh --release`。

**改完配置还是红色**

强行停止目标应用再重新打开。配置改了但进程还在跑，进程内的状态不会自己变回去。

**自动配置一直显示「查不到」**

说明一次都没成功执行过。先看有没有结果文件：

```sh
sh /data/adb/modules/lsposed_stealth/common/autoconfig.sh --status
```

没有输出就是 `state/autoconfig/last.json` 还没生成。检查 `autoconfig_enabled`
和 `autoconfig_on_boot` 是否都是 1，以及 `autoconfig.log` 里有没有写入过。

**点了「核对上游」没反应**

先看面板底部那行上游状态写了什么。全部镜像都连不上时会显示未核对成功和原因，
本地基线继续用，其他功能不受影响。内网或需要代理的环境下这是正常现象。

**权限项一直「未确认」，读回还是 755**

真机上 ext4 / f2fs 不会出现。如果数据分区不支持 Unix 权限位（某些外置存储、
或在 NTFS 上做测试），`chmod` 会被静默忽略，这一项就永远是未确认。
不是判定逻辑出错，是文件系统不认这个操作。

---

## 十五、边界声明

这个模块的目标是让**你自己的设备**上的环境状态可见、可控。

它不修改目标应用的任何行为，不伪造应用数据，不绕过任何账号风控逻辑。
它做的事情，等价于把 LSPosed 管理器和 Zygisk Next 里那几个开关的状态
搬到一块面板上，并且在你忘记检查的时候提醒你。

剩下的部分，交给真机上的检测器去回答。
