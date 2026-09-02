# bench — server benchmark

> Part of [dalex-ops-toolkit](../README.md) — the disclaimer and licence are in the
> [top-level README](../README.md). 本目录属于 [dalex-ops-toolkit](../README.md),
> 免责声明与许可见仓库根 README。

[English](#english) · [中文](#中文)

## English

### `perfcheck.sh` — sysbench, sized to the machine, reduced to one number

Reads the machine first — cores, cgroup CPU quota, memory, storage, virtualisation — derives
every sysbench parameter from what it found, runs the tests, and scores the results against a
reference profile.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/bench/perfcheck.sh)
```

Runs on Debian/Ubuntu, the RHEL family and macOS. **It does not install anything by default**:
installing packages changes the machine being measured and loads it while doing so. When
`sysbench` is missing it prints the command for the platform and exits 2. `--install` lets it
install (`apt`, `dnf` with EPEL enabled first — it is not in the RHEL base repos, or `brew`),
and then says to run again for numbers worth keeping.

On macOS the machine facts come from `sysctl` instead of `/proc`, and the disk tests always go
through the page cache because macOS has no `O_DIRECT`; the report says so when that happens.

Across a fleet, downloading it first so `--remote` can pipe the file to each host:

```bash
curl -fsSLO https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/bench/perfcheck.sh
bash perfcheck.sh --remote app1,app2,db1
```

### Options

```
--time <sec>       Seconds per test (default 60); a full run takes about six
                   minutes, nine with --io
--quick            Same as --time 10, for checking that the script works
--io               Also run the file I/O test (off by default)
--io-dir <path>    Directory for the I/O test file (default: current directory)
--install          Install sysbench when missing (off by default)
--force            Run even when the machine is already busy
--max-busy <pct>   Busy CPU percentage that stops the run (default 25)
--remote <a[,b,]>  Also run on those ssh targets and print a fleet summary
-q, --quiet        Summary only
--help-scoring     Print the reference profile and the weights
```

### How it sizes itself

| Reading | Effect |
|---|---|
| logical cores (`nproc`) | starting point for the thread counts |
| **cgroup CPU quota** | when a container or slice caps CPU below the visible core count, the tests use the quota instead — `cpu.max` on cgroup v2, `cpu.cfs_quota_us` on v1 |
| total RAM | memory test target size; I/O file size starts at 2× RAM |
| free space in the I/O directory | I/O file capped at a quarter of it, and at 8 GiB |
| **CPU busy percentage**, sampled over a second | the run is refused above 25% busy, unless `--force`; raise the bar with `--max-busy` |

The quota reading matters more than it sounds. In a container limited to 4 CPUs on a 16-core
host, `nproc` still answers 16; sizing the CPU test from that measures the throttling, not the
machine. The same run scored 83.8 before the quota was taken into account and 99.5 after.

### What each test measures

| Area | Test | Metric |
|---|---|---|
| **CPU** | all threads, `--cpu-max-prime=20000` | events/s |
| | single thread, same workload | events/s |
| **Memory** | sequential write, 1 MiB blocks | MiB/s |
| | sequential read, 1 MiB blocks | MiB/s |
| | random write, 4 KiB blocks — about access latency rather than bandwidth | MiB/s |
| **Scheduler** | threads, 4× oversubscribed, `--thread-yields=1000 --thread-locks=8` | events/s, derived from the total event count — this test prints no rate of its own |
| | mutex, 4096 mutexes, 50 000 locks per thread, 5 000 loops | locks/s |
| **Disk** (opt-in) | sequential read | MiB/s |
| | random read/write, non-durable | IOPS, MiB/s, 95th percentile latency |
| | sequential write | MiB/s |

Not covered: network, GPU, NUMA locality, and any storage other than the filesystem holding
`--io-dir`.

The memory subscore is the geometric mean of the sequential read and write figures. The random
4 KiB number is reported next to them because it says something different, not because it
averages well with them.

Two things about the disk tests are deliberate. They pass `--file-extra-flags=direct` so the
page cache does not answer the requests, falling back per test where O_DIRECT is unavailable
(tmpfs, some overlay and network mounts, macOS) and saying so. And the sequential **write**
runs last: sysbench leaves the files shorter than `prepare` made them, and anything run
afterwards aborts with `FATAL: Size of file 'test_file.12' is 57.5MiB, but at least 64MiB is
expected`.

The mutex test takes `--mutex-locks` *per thread*, so its elapsed time is not comparable
between machines with different core counts. Throughput is, which is why the metric is locks/s
rather than seconds.

### Scoring — *perfcheck relative score v1*

Each result is divided by the reference value for that test, so 100 means "the same as the
reference". `--help-scoring` prints the whole profile. The composite is a **weighted geometric mean** of the five subscores:

| Subscore | Weight |
|---|---|
| cpu, all threads | 30% |
| cpu, single thread | 25% |
| memory | 20% |
| threads | 15% |
| mutex | 10% |

A geometric mean is the right average for ratios, and unlike an arithmetic mean it does not let
one enormous subscore carry the composite on its own.

**All five are required.** If any of them fails, the composite is `N/A` and the exit status is
2 — dropping a failed test from the weights would renormalise the rest and could raise the
score, which is the wrong direction entirely.

**File I/O never enters the composite**, so a score means the same thing whether or not `--io`
was used. Storage varies far more than the rest of a machine and would drown everything else.

### The reference profile

`reference profile v2` is rounded from three runs on two Mac mini (Apple silicon) hosts, each
running Debian 13 aarch64 in Parallels with 8 vCPU, sysbench 1.0.20, 10 seconds per test:

| test | reference | spread across the three runs |
|---|---|---|
| cpu, all threads | 24 000 events/s | 21 017 – 23 809 |
| cpu, single thread | 5 500 events/s | 5 534 – 5 564 |
| memory | 175 000 MiB/s | 170 305 – 177 842 |
| threads | 11 500 events/s | 10 771 – 11 470 |
| mutex | 4 600 000 locks/s | 4 545 455 – 4 651 163 |

The two hosts are consistent with each other: their all-threads figures landed within 0.04% of
one another (23 809 and 23 800), and single-thread, memory, threads and mutex all repeated
within about 2%. A third run came in 12% lower on the all-threads figure alone, with everything
else unchanged — the signature of something else using the host for that minute rather than of
an unstable machine. The reference is taken from the two runs that agree.

Two caveats worth knowing before reading a score:

- The profile was measured at 10 seconds per test while the default is now 60. The memory test
  is the one that cares: a longer run leaves cache and the figure drops. Measured in a
  4-core container, the median went from 78 901 MiB/s at 3 s to 55 922 MiB/s at 10 s, with the
  coefficient of variation rising from 8.2% to 14.4% — while CPU stayed at 0.3–0.5%. The memory
  reference is the least settled of the five for that reason.
- The file I/O reference was never measured on that machine; the I/O test was not run there.

The numbers are arbitrary in the sense that they only decide where 100 sits. Every one of them
can be overridden, which is how to move the scale onto a machine of your own:

```bash
PERFCHECK_REF_CPU_MULTI=45000 PERFCHECK_REF_MEMORY=100000 bash perfcheck.sh
```

`PERFCHECK_REF_CPU_MULTI`, `_CPU_SINGLE`, `_MEMORY`, `_THREADS`, `_MUTEX`, `_IO_IOPS`.

A score is a comparison, not a verdict: it says how this host compares with the reference and
with the other hosts measured the same way.

### Sample output

```
================ app01.example.internal (10.0.0.36) — Debian GNU/Linux 13 — x86_64 ================

Machine
  cpu                    Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
  cores                  16 logical / 8 physical / 1 socket(s)
  cgroup cpu quota       4.00 cores — tests use 4 threads, not 16
  memory                 32109 MiB total, 28776 MiB available
  virtualisation         kvm
  time per test          10s
  load average (1m)      0.14  (informational)
  cpu busy               2.1%  (limit 25%)

Scores (100 = reference profile v1)
  TEST                         MEASURED    REFERENCE  SCORE
  cpu, all cores               19982.31        20000   99.9
  cpu, single thread            5240.61         5000  104.8
  memory MiB/s                 92208.62       100000   92.2
  threads events/s              7743.33         8000   96.8
  mutex locks/s                 2971768      2500000  118.9

Composite
  100.8   app01.example.internal  10.0.0.36
  weighted geometric mean: cpu-all 30%, cpu-1 25%, memory 20%, threads 15%, mutex 10%
```

With `--remote`, the same identity is what the fleet summary is keyed on:

```
================ Fleet summary ================
  HOST                   IP               CORES   RAM MiB  COMPOSITE  CPU-ALL
  app01                  10.0.0.36            4     32035       84.2     78.1
  db01                   10.0.1.75            8     64256      142.7    155.3
```

### Notes

- Each test runs for 60 seconds by default: six timed tests, so about six minutes, and about
  nine with `--io`. Shorter runs move between repeats — the memory test most of all — so
  `--quick` (10 s) is for checking that the script works, not for numbers you intend to compare.
  The mutex test is not timed: it does a fixed number of locks per thread and reports the rate.
- The I/O tests run with `--file-fsync-freq=0`, so nothing is flushed: they measure raw
  non-durable throughput, not what a durable commit costs. For storage decisions that turn on
  durability, `fio` with an explicit `fsync`/`iodepth`/`numjobs` profile is the right tool.
- The I/O tests run inside a private `.perfcheck.XXXXXX` directory created in `--io-dir`, so two
  runs cannot overwrite each other's `test_file.N` and files already there are left alone. The
  directory is removed on exit, on interrupt and on failure.
- A cached I/O run (no O_DIRECT) is reported but not scored: it is not on the same scale as a
  direct one.
- Exit status: 0 measured, 1 a host was unreachable or too busy, 2 a test failed or a dependency
  or argument was wrong.
- The busy guard exists because a benchmark on a busy host measures the other workload too. It
  samples actual CPU utilisation rather than the load average: on macOS the load average counts
  threads waiting on I/O and Mach ports, so an idle Mac reports a load of 8 while the CPU is 85%
  idle, and inside a container `/proc/stat` reports the host's CPUs rather than the cgroup's.
  Where a cgroup quota exists the guard reads `cpu.stat` instead. When it refuses, it prints the
  busiest processes it found.

---

## 中文

### `perfcheck.sh` —— 按机器自动定型的 sysbench,最后归一到一个分数

先读机器 —— 核数、cgroup CPU 配额、内存、存储、虚拟化 —— 用读到的信息推导出所有 sysbench
参数,跑完再按参考基准打分。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/bench/perfcheck.sh)
```

支持 Debian/Ubuntu、RHEL 系与 macOS。**默认不安装任何东西**:装包会改变被测机器,
而且安装过程本身就在给机器加载。缺 `sysbench` 时会打印对应平台的安装命令并以 2 退出。
加 `--install` 才会装(`apt`、`dnf` 先启用 EPEL、或 `brew`),装完会提示重新运行再取数。

macOS 上机器信息取自 `sysctl` 而非 `/proc`;由于 macOS 没有 `O_DIRECT`,磁盘测试必然经过
page cache,报告里会明确标出。

批量走 ssh(先下载成文件,`--remote` 会把脚本本体喂给每台机器):

```bash
curl -fsSLO https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/bench/perfcheck.sh
bash perfcheck.sh --remote app1,app2,db1
```

### 选项

```
--time <sec>       每项测试的秒数(默认 60);跑完一轮约 6 分钟,带 --io 约 9 分钟
--quick            等同 --time 10,用来确认脚本能跑
--io               跑文件 I/O 测试(默认不跑)
--io-dir <path>    I/O 测试文件所在目录(默认当前目录)
--install          缺 sysbench 时安装它(默认不装)
--force            机器已经很忙时仍然强制运行
--max-busy <pct>   超过这个 CPU 占用率就不跑(默认 25)
--remote <a[,b,]>  同时在这些 ssh 目标上跑,最后出汇总表
-q, --quiet        只输出汇总
--help-scoring     打印参考基准与权重
```

### 怎么自动定型

| 读到的信息 | 作用 |
|---|---|
| 逻辑核数(`nproc`) | 线程数的起点 |
| **cgroup CPU 配额** | 容器或 slice 把 CPU 限制在可见核数之下时,按配额而不是核数定线程 —— cgroup v2 读 `cpu.max`,v1 读 `cpu.cfs_quota_us` |
| 总内存 | 内存测试的目标容量;I/O 文件初始按 2× 内存 |
| I/O 目录可用空间 | I/O 文件上限取其 1/4,且不超过 8 GiB |
| **CPU 实际占用率**(采样 1 秒) | 超过 25% 时拒绝运行,除非 `--force`;可用 `--max-busy` 调高门槛 |

配额这条比听起来重要。在 16 核宿主机上限制为 4 CPU 的容器里,`nproc` 仍然回答 16,
按它定线程测到的是**限流**而不是机器本身。同一次运行,计入配额前得 83.8 分,计入后 99.5 分。

### 每项测什么

| 领域 | 测试 | 指标 |
|---|---|---|
| **CPU** | 全线程,`--cpu-max-prime=20000` | events/s |
| | 单线程,同样负载 | events/s |
| **内存** | 顺序写,1 MiB 块 | MiB/s |
| | 顺序读,1 MiB 块 | MiB/s |
| | 随机写,4 KiB 块 —— 反映的是访问延迟而非带宽 | MiB/s |
| **调度** | threads,4 倍超订,`--thread-yields=1000 --thread-locks=8` | events/s,由总事件数换算 —— 这项测试本身不输出速率 |
| | mutex,4096 个 mutex、每线程 50000 次加锁、5000 次空循环 | locks/s |
| **磁盘**(需 `--io`) | 顺序读 | MiB/s |
| | 随机读写(非持久化) | IOPS、MiB/s、95 分位延迟 |
| | 顺序写 | MiB/s |

未覆盖:网络、GPU、NUMA 局部性,以及 `--io-dir` 所在文件系统之外的任何存储。

内存子分取顺序读与顺序写的几何平均。随机 4 KiB 那个数字列在旁边,是因为它说明的是另一回事,
不是因为它适合和前两者平均。

磁盘测试有两处是刻意为之。一是加了 `--file-extra-flags=direct`,不让 page cache 代答请求;
在 O_DIRECT 不可用的地方(tmpfs、部分 overlay 与网络挂载、macOS)按测试项各自回退并明确说明。
二是**顺序写放在最后**:sysbench 会把文件写得比 `prepare` 建出来时更短,之后再跑任何一项都会
直接 `FATAL: Size of file 'test_file.12' is 57.5MiB, but at least 64MiB is expected`。

mutex 测试的 `--mutex-locks` 是**每线程**的,所以它的总耗时在不同核数的机器之间不可比,
吞吐才可比 —— 这就是指标用 locks/s 而不是秒的原因。

### 打分方式 —— *perfcheck relative score v1*

每项结果除以该项的参考值,100 表示"与参考基准相同"。`--help-scoring` 可打印完整基准表。综合分是五项子分的**加权几何平均**:

| 子项 | 权重 |
|---|---|
| cpu 全线程 | 30% |
| cpu 单线程 | 25% |
| 内存 | 20% |
| 线程 | 15% |
| 互斥锁 | 10% |

比值型数据本就该用几何平均;而且与算术平均不同,单独一项畸高的子分不会把综合分整个抬起来。

**五项缺一不可。** 任一项失败,综合分显示 `N/A`,退出码为 2 —— 把失败项从权重里剔除会让其余项
重新归一化,反而可能把分数抬高,方向完全错了。

**文件 I/O 永远不进综合分**,所以跑没跑 `--io`,分数含义都一样。存储的离散度远大于机器其余部分,
放进去会把其他项淹没。

### 参考基准是怎么来的

`reference profile v2` 取自两台 Mac mini(Apple 芯片)上的三次运行取整 —— 均为 Parallels 中的
Debian 13 aarch64、8 vCPU、sysbench 1.0.20、每项 10 秒:

| 测试 | 参考值 | 三次运行的区间 |
|---|---|---|
| cpu 全线程 | 24 000 events/s | 21 017 – 23 809 |
| cpu 单线程 | 5 500 events/s | 5 534 – 5 564 |
| 内存 | 175 000 MiB/s | 170 305 – 177 842 |
| threads | 11 500 events/s | 10 771 – 11 470 |
| mutex | 4 600 000 locks/s | 4 545 455 – 4 651 163 |

两台机器彼此一致:全线程结果相差 **0.04%**(23 809 与 23 800),单线程、内存、threads、mutex
三次之间也都复现在 2% 以内。第三次运行只有全线程一项低了 12%,其余各项没变 —— 这是那一分钟里
宿主机上有别的活在跑的特征,不是机器本身不稳。参考值取自彼此吻合的那两次。

读分数之前有两点要清楚:

- 基准是在**每项 10 秒**下测的,而现在默认是 60 秒。受影响的是内存测试:跑得越久越会跑出缓存,
  数字随之下降。在一个 4 核容器里实测,中位数从 3 秒的 78 901 MiB/s 降到 10 秒的 55 922 MiB/s,
  变异系数从 8.2% 升到 14.4% —— 同期 CPU 只有 0.3–0.5%。所以五项里内存这项最不稳。
- 文件 I/O 的参考值**不是**在那台机器上测的,那里没跑 I/O 测试。

说参考值"任意",意思是它们只决定 100 分落在哪里。每一项都可以覆盖,
这也是把标尺移到你自己某台基准机上的方式:

```bash
PERFCHECK_REF_CPU_MULTI=45000 PERFCHECK_REF_MEMORY=100000 bash perfcheck.sh
```

可用变量:`PERFCHECK_REF_CPU_MULTI`、`_CPU_SINGLE`、`_MEMORY`、`_THREADS`、`_MUTEX`、`_IO_IOPS`。

分数是比较值,不是判决:它说明这台机器相对参考基准、以及相对用同样方式测过的其他机器处在什么位置。

### 注意

- 每项测试默认跑 60 秒:共 6 项计时测试,整轮约 6 分钟,带 `--io` 约 9 分钟。跑得越短,
  重复之间波动越大 —— 内存测试尤其明显 —— 所以 `--quick`(10 秒)只用来确认脚本能跑,
  不适合用来比较数字。mutex 那项不计时:它做固定次数的加锁,报告速率。
- I/O 测试带 `--file-fsync-freq=0`,不做任何 flush:量的是**非持久化**的裸吞吐,不代表一次持久化
  提交的代价。要为存储选型做决策,应改用 `fio` 并显式给出 `fsync`/`iodepth`/`numjobs` 配置。
- I/O 测试在 `--io-dir` 下新建的私有目录 `.perfcheck.XXXXXX` 里运行,两次并行运行不会互相覆盖
  `test_file.N`,目录中原有文件也不会被动。正常退出、被中断、失败时该目录都会删除。
- 走了 page cache 的 I/O 结果(无 O_DIRECT)只报告不打分:它和 direct 的结果不在同一标尺上。
- 退出码:0 测完,1 有主机不可达或太忙,2 有测试失败、依赖缺失或参数错误。
- 繁忙守卫的存在是因为:在繁忙机器上跑基准,量到的有一部分是别的负载。它采样的是**实际 CPU
  占用率**而非负载均值:macOS 的负载均值把等待 I/O 和 Mach 端口的线程也算进去,一台空闲的 Mac
  会报负载 8 而 CPU 其实 85% 空闲;而在容器里 `/proc/stat` 报的是宿主机的 CPU 而不是 cgroup 的。
  存在 cgroup 配额时改读 `cpu.stat`。拒绝运行时会列出当时最忙的几个进程。
