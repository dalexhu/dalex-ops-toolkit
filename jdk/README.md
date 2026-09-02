# jdk — JDK inventory checks

> Part of [dalex-ops-toolkit](../README.md) — the disclaimer and licence are in the
> [top-level README](../README.md). 本目录属于 [dalex-ops-toolkit](../README.md),
> 免责声明与许可见仓库根 README。

[English](#english) · [中文](#中文)

## English

### `jdkcheck.sh` - JDK inventory with bundled tz database versions

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

---

## 中文

### `jdkcheck.sh` —— JDK 清单 + 各自捆绑的时区库版本

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
