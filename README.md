# dalex-ops-toolkit

**Small, self-contained ops scripts for mixed macOS / Debian / RHEL fleets.**
每个脚本都是单文件、可 `curl` 直接跑、不依赖运行时。

[English](#english) · [中文](#中文)

| Script | Platform | What it answers |
|---|---|---|
| [`tz/tzcheck.sh`](tz/tzcheck.sh) | macOS, Linux | Which tz database does each host carry, and what will a zone actually do this autumn? |
| [`tz/tzcheck.ps1`](tz/tzcheck.ps1) | Windows, PowerShell 7 anywhere | Same questions against Windows' own registry-based zone data |
| [`jdk/jdkcheck.sh`](jdk/jdkcheck.sh) | macOS, Linux | Which JDKs are installed, which are actually running, and what tz database each one bundles |

---

## English

### `tz/tzcheck.sh` — tz database audit across a fleet

Answers three questions per host, all computed from the host's **own** zoneinfo —
no hardcoded rules, no assumptions about versions:

1. Which tz database version is installed (and where that answer came from).
2. What the real transitions are for a zone in a given year, bisected second-by-second.
3. Whether the clocks actually move that autumn, and what the November offset is.

It also cross-checks the runtimes that ship their **own** copy of the tz database —
Java, Python, Node, and optionally MySQL — because those routinely disagree with the OS.

#### Run it

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/tz/tzcheck.sh)
```

Across a fleet over ssh (download it first — `--remote` pipes the file itself to each host):

```bash
curl -fsSLO https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/tz/tzcheck.sh
bash tzcheck.sh --remote web1,web2,db1
```

Any zone, any year, CI-friendly exit code:

```bash
bash tzcheck.sh --zone Europe/Dublin --year 2027
bash tzcheck.sh --remote web1,web2 --expect-no-fallback   # exit 1 if any host still falls back
```

#### Options

```
--zone <IANA>          Zone to inspect (default: America/Edmonton)
--year <YYYY>          Year to inspect (default: 2026)
--remote <a[,b,...]>   Also run on those ssh targets and print a fleet summary
--mysql "<args>"       Also check MySQL (args passed verbatim to the mysql client)
--no-runtimes          Skip the java / python / node cross-checks
--expect-no-fallback   Exit 1 if the zone still falls back that autumn
-q, --quiet            Verdict lines only
```

Exit codes: `0` as expected · `1` fall-back still happens / hosts disagree / host unreachable · `2` usage error.

#### Sample output

```
================ app01 — AlmaLinux 10.0 — x86_64 ================

tz database
  tzdata version             2025b-rearguard  (from /usr/share/zoneinfo/tzdata.zi)
  zone file                  /usr/share/zoneinfo/America/Edmonton
  system timezone            America/Edmonton

America/Edmonton — transitions in 2026 (bisected from this host's own data)
  #1      last: 2026-03-08 01:59:59 MST -07:00
          next: 2026-03-08 03:00:00 MDT -06:00
          UTC : 2026-03-08 09:00:00 UTC   clocks move +60min
  #2      last: 2026-11-01 01:59:59 MDT -06:00
          next: 2026-11-01 01:00:00 MST -07:00
          UTC : 2026-11-01 08:00:00 UTC   clocks move -60min

Verdict
  [FALLBACK]    clocks still move -60min that autumn — November sits at -07:00 (MST)
```

Verdicts: `NO-FALLBACK` (clocks stay put) · `FALLBACK` (clocks still move) ·
`NO-ZONE` (tzdata missing — `date` silently falls back to UTC, which this catches) ·
`UNREACHABLE`.

#### Windows: `tz/tzcheck.ps1`

Same three questions, same verdicts, against the zone data Windows keeps in the registry
(which arrives through Windows Update, not through IANA releases). Runs on Windows
PowerShell 5.1 and on PowerShell 7 on any platform.

```powershell
irm https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/tz/tzcheck.ps1 -OutFile tzcheck.ps1
.\tzcheck.ps1
.\tzcheck.ps1 -Zone Europe/Dublin -Year 2027
```

From `cmd.exe`:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File tzcheck.ps1
```

Across a fleet, using native PowerShell remoting:

```powershell
Invoke-Command -ComputerName app1,app2,db1 -FilePath .\tzcheck.ps1
```

Windows specifics it handles:

- Reports `TzVersion` from the registry when the build exposes it, plus the OS build number
  (Windows has no IANA-style version string, and zone data ships with the cumulative update).
- Prints the per-year adjustment rules (Windows "Dynamic DST") that actually apply to the year.
- Windows PowerShell 5.1 cannot resolve IANA ids at all; the script falls back to an
  IANA -> Windows map, says so in the report, and warns that Windows groups zones
  differently, so the answer describes the Windows zone. Use PowerShell 7 or pass
  `-WindowsZone 'Mountain Standard Time'` when that matters.
- Zone names come out as the Windows long names (`Mountain Standard Time`) rather than
  IANA abbreviations (`CST`); the offsets are what the verdict is based on.

There is deliberately **no `.bat` version**: `cmd.exe` has no time zone arithmetic, so a
batch file could only shell out to PowerShell anyway — the one-liner above does that directly.

#### The case this was written for: America/Edmonton, autumn 2026

From tzdata **2026c**, Alberta stops observing the autumn change: at
`2026-11-01 02:00` local the zone switches from **MDT** to **CST** — the DST flag and
the abbreviation change, but the offset stays at **-06:00** and *the clocks do not move*.
Hosts still on **2026b** or older fall back to **MST -07:00** as usual, so a mixed fleet
will disagree by one hour for everything from that instant onward.

| tz database | 2026-11-15 offset | Autumn 2026 behaviour |
|---|---|---|
| 2026b and older | `-07:00` MST | falls back one hour on 2026-11-01 |
| 2026c and newer | `-06:00` CST | no clock change; label/DST flag only |

### `jdk/jdkcheck.sh` - JDK inventory with bundled tz database versions

The JDK never reads `/usr/share/zoneinfo` for zone rules. It carries its own compiled copy
at `$JAVA_HOME/lib/tzdb.dat` (`jre/lib/tzdb.dat` on 8), so `dnf update tzdata` leaves every
JVM on the box exactly as it was. This script finds every JDK on a host and reads the
version straight out of `tzdb.dat` - no JVM is started, so even installs for another
architecture are reported.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/jdk/jdkcheck.sh) --require-tzdb 2026c
```

```
  VERSION    VENDOR                 TZDB      USE      PATH
  17.0.18    Amazon.com Inc.        2025b     -        /home/x/.sdkman/candidates/java/17.0.18-amzn  <- older than 2026c
  21.0.12    Amazon.com Inc.        2026b     PATH,RUN /home/x/.sdkman/candidates/java/21.0.12-amzn  <- older than 2026c

  CONTAINER                VERSION        TZDB      JAVA HOME
  app-container            21.0.8         2025b     /opt/java/openjdk  <- older than 2026c
```

- Looks in `$JAVA_HOME`, the `java` on `$PATH`, `/usr/lib/jvm`, `/usr/java`, `/opt/java*`,
  macOS `JavaVirtualMachines`, SDKMAN, Homebrew kegs, `update-alternatives`, and the
  binaries behind running JVM processes.
- `USE` marks which install is on `$PATH` and which ones running JVMs actually execute -
  usually the only two rows that matter.
- `--docker` also looks inside running containers, since each image ships its own JDK that
  a host scan cannot see.
- `--verify` goes one step further and *runs* each JDK, printing the offset it actually
  yields for the autumn window (`--zone`, `--year`), so the report does not rest on the
  version string alone. One class file is compiled at release 8, so even a JDK 8 install
  is measured.
- `--require-tzdb <ver>` flags anything older and exits 1, so it works as a CI gate.
- A `Recommended actions` section prints the fix per install, chosen from where the JDK
  came from: SDKMAN, Homebrew, an rpm/deb package, a macOS pkg, or an unmanaged tarball.
- `--remote a,b,c` fans out over ssh and prints a fleet summary, same as `tzcheck.sh`.

How the version is read: the first bytes of `tzdb.dat` are `01 00 04 "TZDB" 00 01 00 05
"2026a"`, so dropping non-alphanumeric bytes from the first 16 gives `TZDB2026a`. Only
`head` and `tr` are needed, which is why the same one-liner also runs inside busybox
containers.

#### Remediation

```bash
sudo apt-get update && sudo apt-get install --only-upgrade tzdata   # Debian / Ubuntu
sudo dnf update tzdata                                              # RHEL / AlmaLinux / Rocky
```

The OS package is only half the job — these carry their own copy and must be checked separately:

- **Java** — the JDK bundles its own tzdb; a JDK update (or Azul/OpenJDK `TZUpdater`) is required.
  `tzcheck.sh` prints the exact tzdb version the JVM sees.
- **Node** — bundled ICU; update Node itself.
- **Python** — `zoneinfo` normally reads the OS database, but a pip-installed `tzdata`
  package shadows it; the script reports which source is in play.
- **MySQL** — `CONVERT_TZ` uses the `mysql.time_zone*` tables, which are a *snapshot*.
  After updating the OS tzdata, reload them:
  ```bash
  mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql
  ```

`tzcheck.sh` requires `bash` 3.2+ and GNU or BSD `date`; verified on macOS 26,
AlmaLinux 9/10, Debian 12, Ubuntu 24.04. `tzcheck.ps1` is verified on PowerShell 7.4
(Linux container); its Windows-only code paths — registry `TzVersion`, the 5.1 fallback
map, `Invoke-Command` fan-out — are written but have not been run on a Windows host here.

> Note: BSD `date -r` prints `%z` as the *current* offset even when rendering another
> instant. This script never trusts `%z` — it derives every offset by rendering the wall
> clock in the zone and reading it back as UTC.

---

## 中文

### `tz/tzcheck.sh` —— 全机群时区数据库审计

每台机器回答三个问题,全部**由该机器自己的 zoneinfo 算出来**,不写死任何规则、不假设版本:

1. 装的是哪个版本的 tz 数据库(以及这个答案是从哪读到的)。
2. 指定时区在指定年份的真实切换点 —— 用二分法精确到秒。
3. 那年秋天到底动不动表,11 月的偏移是多少。

同时交叉核对**自带一份时区库**的运行时:Java、Python、Node,以及可选的 MySQL ——
这些经常和操作系统对不上。

#### 运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/tz/tzcheck.sh)
```

批量走 ssh(先下载成文件,`--remote` 会把脚本本体喂给每台机器):

```bash
curl -fsSLO https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/tz/tzcheck.sh
bash tzcheck.sh --remote web1,web2,db1
```

任意时区/年份,退出码可直接用于 CI:

```bash
bash tzcheck.sh --zone Europe/Dublin --year 2027
bash tzcheck.sh --remote web1,web2 --expect-no-fallback   # 只要还有机器会回拨就 exit 1
```

#### 选项

```
--zone <IANA>          要查的时区(默认 America/Edmonton)
--year <YYYY>          要查的年份(默认 2026)
--remote <a[,b,...]>   同时在这些 ssh 目标上跑,最后出汇总表
--mysql "<args>"       附带检查 MySQL(参数原样传给 mysql 客户端)
--no-runtimes          跳过 java / python / node 交叉检查
--expect-no-fallback   若该年秋天仍会回拨则 exit 1
-q, --quiet            只输出结论行
```

退出码:`0` 符合预期 · `1` 仍会回拨 / 各机器结论不一致 / 机器不可达 · `2` 参数错误。

结论取值:`NO-FALLBACK`(不动表)· `FALLBACK`(仍回拨)·
`NO-ZONE`(没装 tzdata —— 此时 `date` 会静默按 UTC 走,脚本能识别出来)· `UNREACHABLE`。

#### Windows:`tz/tzcheck.ps1`

同样的三个问题、同样的结论口径,针对 Windows 自己那套**注册表**时区数据(它跟随
Windows Update 下发,和 IANA 版本没有对应关系)。Windows PowerShell 5.1 与
PowerShell 7(任意平台)都能跑。

```powershell
irm https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/tz/tzcheck.ps1 -OutFile tzcheck.ps1
.\tzcheck.ps1
.\tzcheck.ps1 -Zone Europe/Dublin -Year 2027
```

从 `cmd.exe` 调用:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File tzcheck.ps1
```

批量走 PowerShell 远程:

```powershell
Invoke-Command -ComputerName app1,app2,db1 -FilePath .\tzcheck.ps1
```

针对 Windows 的特殊处理:

- 能读到就报注册表里的 `TzVersion`,再加上系统 build 号(Windows 没有 IANA 那种版本号,
  时区数据随累积更新下发)。
- 打印该年份实际生效的逐年规则(Windows 的 "Dynamic DST")。
- **Windows PowerShell 5.1 根本无法解析 IANA 时区 ID**;脚本会退回 IANA -> Windows 映射表,
  并在报告里明确标注 —— 同时警告 Windows 的时区分组方式和 IANA 不同,这时结论描述的是
  Windows 时区。要精确请用 PowerShell 7,或显式传 `-WindowsZone 'Mountain Standard Time'`。
- 时区名显示的是 Windows 长名(`Mountain Standard Time`)而不是 IANA 缩写(`CST`);
  结论只基于偏移量判断。

**故意不提供 `.bat` 版本**:`cmd.exe` 没有任何时区运算能力,批处理最终也只能去调
PowerShell —— 上面那行命令已经直接做了这件事。

#### 这个脚本要解决的具体问题:America/Edmonton 2026 年秋天

从 tzdata **2026c** 起,Alberta 不再执行秋季回拨:本地时间 `2026-11-01 02:00`,
时区从 **MDT** 变为 **CST** —— DST 标志和缩写变了,但偏移仍是 **-06:00**,**表不动**。
仍停留在 **2026b 或更早**的机器会照旧回拨到 **MST -07:00**;混装的机群从那一刻起会差整整一小时。

| tz 数据库 | 2026-11-15 偏移 | 2026 秋季行为 |
|---|---|---|
| 2026b 及更早 | `-07:00` MST | 2026-11-01 回拨一小时 |
| 2026c 及更新 | `-06:00` CST | 不动表,只改标签和 DST 标志 |

### `jdk/jdkcheck.sh` —— JDK 清单 + 各自捆绑的时区库版本

JDK **从不**读 `/usr/share/zoneinfo` 的时区规则,它自带一份编译好的副本在
`$JAVA_HOME/lib/tzdb.dat`(JDK 8 是 `jre/lib/tzdb.dat`)。所以 `dnf update tzdata`
对机器上任何一个 JVM 都没有影响。本脚本扫出主机上**每一个** JDK,并直接从
`tzdb.dat` 里读版本号 —— 不启动 JVM,所以连跨架构、跑不起来的安装也能报出来。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/jdk/jdkcheck.sh) --require-tzdb 2026c
```

```
  VERSION    VENDOR                 TZDB      USE      PATH
  17.0.18    Amazon.com Inc.        2025b     -        /home/x/.sdkman/candidates/java/17.0.18-amzn  <- older than 2026c
  21.0.12    Amazon.com Inc.        2026b     PATH,RUN /home/x/.sdkman/candidates/java/21.0.12-amzn  <- older than 2026c

  CONTAINER                VERSION        TZDB      JAVA HOME
  app-container            21.0.8         2025b     /opt/java/openjdk  <- older than 2026c
```

- 搜索范围:`$JAVA_HOME`、`$PATH` 上的 `java`、`/usr/lib/jvm`、`/usr/java`、`/opt/java*`、
  macOS 的 `JavaVirtualMachines`、SDKMAN、Homebrew、`update-alternatives`,
  以及正在运行的 JVM 进程所对应的二进制。
- `USE` 列标出哪个在 `$PATH` 上、哪些是**真正在跑**的 —— 通常只有这两行要紧。
- `--docker` 会进到运行中的容器里查 —— 每个镜像自带一套 JDK,主机扫描看不到。
- `--verify` 会**实际运行**每个 JDK,打印它对秋季窗口给出的真实偏移(`--zone`、`--year`),
  不只看版本号。探针类以 release 8 编译一次,所以 JDK 8 也能测。
- `--require-tzdb <ver>` 低于该版本就标记并 exit 1,可直接当 CI 卡点。
- `Recommended actions` 段会按安装来源给出对应修复命令:SDKMAN、Homebrew、
  rpm/deb 包、macOS pkg,或无人管理的 tarball。
- `--remote a,b,c` 走 ssh 批量执行并出汇总表,和 `tzcheck.sh` 一致。

版本怎么读出来的:`tzdb.dat` 开头是 `01 00 04 "TZDB" 00 01 00 05 "2026a"`,
把前 16 字节里的非字母数字丢掉就得到 `TZDB2026a`。只用到 `head` 和 `tr`,
所以同一行命令在 busybox 容器里也能跑。

#### 修复

```bash
sudo apt-get update && sudo apt-get install --only-upgrade tzdata   # Debian / Ubuntu
sudo dnf update tzdata                                              # RHEL / AlmaLinux / Rocky
```

只升系统包**不够** —— 下面这些各自带一份时区库,必须单独确认:

- **Java** —— JDK 自带 tzdb,必须升级 JDK(或用 `TZUpdater`)。脚本会打印 JVM 实际看到的 tzdb 版本。
- **Node** —— 用内置 ICU,升级 Node 本体。
- **Python** —— `zoneinfo` 默认读系统库,但 pip 装的 `tzdata` 包会盖掉它;脚本会报告当前用的是哪一个。
- **MySQL** —— `CONVERT_TZ` 依赖 `mysql.time_zone*` 表,那是一份**快照**。系统 tzdata 升级后要重新导入:
  ```bash
  mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql
  ```

`tzcheck.sh` 依赖 `bash` 3.2+ 与 GNU/BSD `date`,已在 macOS 26、AlmaLinux 9/10、
Debian 12、Ubuntu 24.04 验证。`tzcheck.ps1` 已在 PowerShell 7.4(Linux 容器)验证;
其 Windows 专属分支 —— 注册表 `TzVersion`、5.1 回退映射、`Invoke-Command` 分发 ——
代码已写好但**尚未在真实 Windows 机器上跑过**。

> 注意:BSD 的 `date -r` 在渲染其他时刻时,`%z` 输出的仍是**当前**偏移。
> 本脚本从不信任 `%z` —— 所有偏移都是「把该时刻在目标时区渲染成墙上时间,再按 UTC 读回来」算出来的。

---

## Disclaimer / 免责声明

**English.** These are personal utilities, shared in case they are useful to someone else, and
provided **as is, without warranty of any kind, express or implied**. The author accepts no
liability for any loss or damage arising from their use.

They are not affiliated with, endorsed by, sponsored by or supported by IANA, Oracle, the
Eclipse Foundation, Amazon, Microsoft, Apple, Red Hat, Canonical, the Debian or AlmaLinux
projects, the maintainers of SDKMAN!, Homebrew, Node.js, Python, MySQL or Docker, or any other
project or vendor named anywhere in this repository. All product names, logos and trademarks
are the property of their respective owners, and are used here only to identify the software
these scripts inspect or operate on.

The scripts read system state, and where asked to, connect to hosts named on the command line
over ssh and run package-manager commands. What they report reflects the data present on the
host at the time they run; it is not a certification of correctness of that host or of any
runtime on it. Nothing in this repository is legal advice.

**中文。** 这些是个人自用工具,公开出来只是想着或许对别人也有用,
**按原样提供,不附带任何明示或默示的担保**。作者对因使用本项目而产生的任何损失或损害
不承担责任。

本项目与 IANA、Oracle、Eclipse 基金会、Amazon、Microsoft、Apple、Red Hat、Canonical、
Debian 与 AlmaLinux 项目、SDKMAN!、Homebrew、Node.js、Python、MySQL、Docker 的维护方,
以及本仓库中提及的任何其他项目或厂商,**均无关联,未获其背书、赞助或支持**。
所有产品名称、标识与商标均归其各自所有者所有,在此仅用于指明这些脚本所检查或操作的软件对象。

脚本会读取系统状态,并在被要求时通过 ssh 连接命令行上指定的主机、执行包管理器命令。
它们报告的是运行当时主机上的数据,不构成对该主机或其上任何运行时的正确性认证。
本仓库中的任何内容均不构成法律意见。

---

## License

MIT
