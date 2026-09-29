# TZUpdater — patching a JDK's tz database in place

> Part of [dalex-ops-toolkit](../README.md) — the disclaimer and licence are in the
> [top-level README](../README.md). 本目录属于 [dalex-ops-toolkit](../README.md),
> 免责声明与许可见仓库根 README。

[English](#english) · [中文](#中文)

## English

[TZUpdater](https://www.oracle.com/java/technologies/javase-tzupdater-downloads.html) is
Oracle's tool for replacing the tz database a JDK carries in `$JAVA_HOME/lib/tzdb.dat`
(`jre/lib/tzdb.dat` on 8). Reach for it only when a zone's rules changed and the JDK cannot
be upgraded yet; a JDK patch release that already bundles the new tzdata is the better fix.
[`jdkcheck.sh`](README.md) tells you which installs need it.

### Download

Download `tzupdater-2.x.x.zip` from the page above (an Oracle account and licence
acceptance are required) and unzip it to get `tzupdater.jar`.

### Usage

Run it **with the JDK you want to patch**: it only rewrites the `tzdb.dat` of the JVM it
runs in, and it needs write access to `$JAVA_HOME/lib`.

```bash
# Show the tzdata version this JDK carries
$JAVA_HOME/bin/java -jar tzupdater.jar -V

# Fetch the latest tzdata from IANA and install it
sudo $JAVA_HOME/bin/java -jar tzupdater.jar -l
```

Then **restart every JVM that uses this JDK**. A running JVM never reloads its zone rules.

| Option | Effect |
|---|---|
| `-V` | Print the JDK's tzdata version and the tool's own version |
| `-l` | Download the latest tzdata (`tzdata-latest.tar.gz`) from IANA and install it |
| `-l <url or file>` | Install a specific tzdata archive, for hosts without internet access |
| `-f` | Force the update even if the target version is the same or older |
| `-v` | Verbose output |
| `-h` | Help |

Offline hosts: download a release such as
`https://data.iana.org/time-zones/releases/tzdata2026c.tar.gz` elsewhere, copy it over, and run

```bash
sudo $JAVA_HOME/bin/java -jar tzupdater.jar -l file:///path/to/tzdata2026c.tar.gz
```

### Scripted: `tzupdate.sh`

[`tzupdate.sh`](tzupdate.sh) wraps the steps above: it takes `tzupdater.jar` (or the zip
it ships in) from a path or a URL on your own mirror, downloads the tzdata **once** for all
JDKs, runs the tool with each JDK's own `java` (via `sudo` when `lib/` is not writable),
and prints the version before and after. Oracle serves the jar only after a login, so the
first copy has to be downloaded by hand.

```bash
./tzupdate.sh --jar tzupdater-2.3.2.zip                  # $JAVA_HOME, newest IANA tzdata
./tzupdate.sh --jar https://mirror.example/tzupdater.jar \
    --java-home /usr/lib/jvm/java-21 --java-home /usr/lib/jvm/java-17 --tzdata 2026c
./tzupdate.sh --check                                    # current version only, no change
```

`--tzdata` defaults to `latest` (IANA's newest release) and also takes a release name, a
local `tzdata*.tar.gz`, or a URL. `-f` and `-v` are passed through to tzupdater.

### Verify

```bash
$JAVA_HOME/bin/java -jar tzupdater.jar -V
bash jdkcheck.sh --require-tzdb 2026c --verify
```

### Caveats

- **One run per JDK.** Each install has its own `tzdb.dat`; run the tool with each one's
  own `bin/java`.
- **Back up first.** The tool keeps the old file under `$JAVA_HOME/lib/tzdb.bak/`, but
  keep your own copy of `tzdb.dat` too.
- **Package managers undo it.** The next `dnf`/`apt`/SDKMAN/Homebrew update of that JDK
  replaces the patched file, which is fine if the new release bundles newer tzdata, and
  silently reverts you if it does not.
- **Licence.** TZUpdater targets Oracle JDK. It works on OpenJDK builds (Corretto,
  Temurin, ...) too, but those vendors ship tzdata in their quarterly (and sometimes
  out-of-band) releases, so upgrading is usually simpler.
- **Containers.** Patching a running container is lost on restart. Either move to a base
  image with a newer JDK, or patch at build time and drop the step once the base image
  catches up:

  ```dockerfile
  COPY tzupdater.jar tzdata2026c.tar.gz /tmp/
  RUN java -jar /tmp/tzupdater.jar -l file:///tmp/tzdata2026c.tar.gz \
      && rm /tmp/tzupdater.jar /tmp/tzdata2026c.tar.gz
  ```

---

## 中文

[TZUpdater](https://www.oracle.com/java/technologies/javase-tzupdater-downloads.html) 是
Oracle 提供的工具,用来替换 JDK 自带的时区库 `$JAVA_HOME/lib/tzdb.dat`(JDK 8 是
`jre/lib/tzdb.dat`)。只有在某地区时区规则变了、而 JDK 暂时不能升级时才需要它;
**升级到已带新 tzdata 的 JDK 补丁版本才是首选**。哪些安装需要处理,用
[`jdkcheck.sh`](README.md) 查。

### 下载

从上面的页面下载 `tzupdater-2.x.x.zip`(需要 Oracle 账号并接受许可),解压得到
`tzupdater.jar`。

### 用法

**必须用要更新的那个 JDK 来运行它**:它只改运行它的那个 JVM 的 `tzdb.dat`,
且需要对 `$JAVA_HOME/lib` 有写权限。

```bash
# 查看这个 JDK 当前的 tzdata 版本
$JAVA_HOME/bin/java -jar tzupdater.jar -V

# 从 IANA 下载最新 tzdata 并更新
sudo $JAVA_HOME/bin/java -jar tzupdater.jar -l
```

更新后**重启所有使用这个 JDK 的 Java 进程**,运行中的 JVM 不会重新加载时区规则。

| 参数 | 作用 |
|---|---|
| `-V` | 显示 JDK 当前 tzdata 版本和工具自身版本 |
| `-l` | 从 IANA 下载最新 tzdata(`tzdata-latest.tar.gz`)并更新 |
| `-l <url或本地文件>` | 用指定的 tzdata 包更新,适合离线/内网主机 |
| `-f` | 强制更新,即使目标版本相同或更旧 |
| `-v` | 详细输出 |
| `-h` | 帮助 |

离线主机:在能上网的机器上下载如
`https://data.iana.org/time-zones/releases/tzdata2026c.tar.gz`,拷过去后运行

```bash
sudo $JAVA_HOME/bin/java -jar tzupdater.jar -l file:///path/to/tzdata2026c.tar.gz
```

### 脚本:`tzupdate.sh`

[`tzupdate.sh`](tzupdate.sh) 把上面的步骤包成一个脚本:从本地路径或自建镜像的 URL
拿 `tzupdater.jar`(或装着它的 zip),tzdata **只下载一次**供所有 JDK 使用,用每个 JDK
自己的 `java` 运行工具(`lib/` 不可写时走 `sudo`),并打印更新前后的版本。
Oracle 要登录才给下载 jar,所以第一份只能手工下载。

```bash
./tzupdate.sh --jar tzupdater-2.3.2.zip                  # $JAVA_HOME,IANA 最新 tzdata
./tzupdate.sh --jar https://mirror.example/tzupdater.jar \
    --java-home /usr/lib/jvm/java-21 --java-home /usr/lib/jvm/java-17 --tzdata 2026c
./tzupdate.sh --check                                    # 只看当前版本,不做修改
```

`--tzdata` 默认是 `latest`(IANA 最新版本),也可以给版本号、本地 `tzdata*.tar.gz` 或 URL。
`-f`、`-v` 原样传给 tzupdater。

### 验证

```bash
$JAVA_HOME/bin/java -jar tzupdater.jar -V
bash jdkcheck.sh --require-tzdb 2026c --verify
```

### 注意事项

- **每个 JDK 各跑一次。** 每个安装有自己的 `tzdb.dat`,要分别用各自的 `bin/java` 运行。
- **先备份。** 工具会把旧文件留在 `$JAVA_HOME/lib/tzdb.bak/`,但最好自己也备份一份 `tzdb.dat`。
- **包管理器会覆盖它。** 下次 `dnf`/`apt`/SDKMAN/Homebrew 更新这个 JDK 时会替换掉改过的文件:
  新版本带的 tzdata 更新则无妨,更旧则会**悄悄退回**。
- **许可。** TZUpdater 面向 Oracle JDK。OpenJDK 系发行版(Corretto、Temurin 等)技术上也能用,
  但这些厂商会在季度更新(有时是紧急更新)里带上新 tzdata,直接升级通常更简单。
- **容器。** 在运行中的容器里打补丁,重启就没了。要么换成带新 JDK 的基础镜像,
  要么在构建镜像时更新,等基础镜像跟上后再删掉这一步:

  ```dockerfile
  COPY tzupdater.jar tzdata2026c.tar.gz /tmp/
  RUN java -jar /tmp/tzupdater.jar -l file:///tmp/tzdata2026c.tar.gz \
      && rm /tmp/tzupdater.jar /tmp/tzdata2026c.tar.gz
  ```
