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
| | mutex, 4096 mutexes, 50 000 locks per thread, 5 000 loops | locks/s, all threads **and** per thread |
| **Disk** (opt-in) | sequential read | MiB/s |
| | random read/write, non-durable | IOPS, MiB/s, 95th percentile latency |
| | sequential write | MiB/s |

Not covered: network, GPU, NUMA locality, and any storage other than the filesystem holding
`--io-dir`.

The memory subscore is the geometric mean of the sequential read and write figures. The random
4 KiB number is reported next to them because it says something different, not because it
averages well with them.

#### What the mutex test measures, and why it is reported twice

sysbench creates 4096 mutexes and has every thread take `--mutex-locks` of them in turn, spinning
`--mutex-loops` empty iterations between locks. It is not a measure of arithmetic speed: what it
exercises is the cost of an atomic operation and a futex, and how the scheduler behaves when
threads collide.

Every thread takes that same lock count, so the total rate grows with the thread count. The
total is therefore how much lock traffic the whole machine sustains, and the per-thread figure
is how good one of its cores is at it — the same split as cpu-all and cpu-single, and each
carries 5% of the composite. Two guests on one physical host with the same processor but
different vCPU counts land on the same per-thread rate, with totals in proportion to their vCPU
counts.

It is the least repeatable of the six measurements: two runs on the same idle host can come out
25% apart while everything else stays within 2%. At 10% of the composite between them, that is
worth about two points.

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
| mutex, all threads | 5% |
| mutex, per thread | 5% |

A geometric mean is the right average for ratios, and unlike an arithmetic mean it does not let
one enormous subscore carry the composite on its own.

**All five are required.** If any of them fails, the composite is `N/A` and the exit status is
2 — dropping a failed test from the weights would renormalise the rest and could raise the
score, which is the wrong direction entirely.

**File I/O never enters the composite**, so a score means the same thing whether or not `--io`
was used. Storage varies far more than the rest of a machine and would drown everything else.

### The reference profile

`reference profile v3` was measured on two Mac mini (Apple silicon) hosts, each running
Debian 13 aarch64 in Parallels with 8 vCPU, sysbench 1.0.20:

| test | reference |
|---|---|
| cpu, all threads | 24 000 events/s |
| cpu, single thread | 5 500 events/s |
| memory | 175 000 MiB/s |
| threads | 11 500 events/s |
| mutex, all threads | 4 600 000 locks/s |
| mutex, per thread | 575 000 locks/s |

The two hosts agree within 0.04% on the all-threads CPU figure and within 2% on the rest, and a
run at the 60 second default scores 101.0 against the profile.

On a busy host the memory figure is not usable: five repeats in a 4-core container on a loaded
laptop ranged from 57 448 to 136 679 MiB/s, while CPU stayed within half a percent of itself.
Memory subscores compare only between hosts that were idle when measured.

The file I/O reference was not measured on that machine; the I/O test was not run there.

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
- The tests run one after another, never in parallel, and `--remote` walks its targets one at a
  time for the same reason. A lock file stops two invocations on the same host from overlapping.
  What none of that can see is a second guest on the same physical host: measure co-located VMs
  one at a time, or they will measure each other.
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
| | mutex,4096 个 mutex、每线程 50000 次加锁、5000 次空循环 | locks/s,**全线程**与**每线程**各一 |
| **磁盘**(需 `--io`) | 顺序读 | MiB/s |
| | 随机读写(非持久化) | IOPS、MiB/s、95 分位延迟 |
| | 顺序写 | MiB/s |

未覆盖:网络、GPU、NUMA 局部性,以及 `--io-dir` 所在文件系统之外的任何存储。

内存子分取顺序读与顺序写的几何平均。随机 4 KiB 那个数字列在旁边,是因为它说明的是另一回事,
不是因为它适合和前两者平均。

#### mutex 测的是什么,以及为什么报两个数

sysbench 建 4096 个互斥锁,每个线程轮流对它们做 `--mutex-locks` 次加锁,两次加锁之间空转
`--mutex-loops` 圈。它量的**不是算力**:考察的是一次原子操作与 futex 的开销,以及线程相撞时
调度器的表现。

那个加锁次数是**每个线程各做一遍**的,所以总速率随线程数增长。于是总量表示整机能承受多大的
锁流量,每线程表示它单个核心干这件事有多强 —— 与 cpu-all / cpu-single 是同一种拆分,
两者各占综合分 5%。同一台物理机上、同款 CPU、vCPU 数不同的两个 guest,每线程速率相同,
总量则与各自 vCPU 数成比例。

它是六项测量里复现性最差的:同一台空闲机器两次运行可能相差 25%,而其余各项都在 2% 以内。
两者合计 10% 权重,大约影响综合分 2 分。

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
| 互斥锁,全线程 | 5% |
| 互斥锁,每线程 | 5% |

比值型数据本就该用几何平均;而且与算术平均不同,单独一项畸高的子分不会把综合分整个抬起来。

**五项缺一不可。** 任一项失败,综合分显示 `N/A`,退出码为 2 —— 把失败项从权重里剔除会让其余项
重新归一化,反而可能把分数抬高,方向完全错了。

**文件 I/O 永远不进综合分**,所以跑没跑 `--io`,分数含义都一样。存储的离散度远大于机器其余部分,
放进去会把其他项淹没。

### 参考基准

`reference profile v3` 测自两台 Mac mini(Apple 芯片),均为 Parallels 中的 Debian 13
aarch64、8 vCPU、sysbench 1.0.20:

| 测试 | 参考值 |
|---|---|
| cpu 全线程 | 24 000 events/s |
| cpu 单线程 | 5 500 events/s |
| 内存 | 175 000 MiB/s |
| threads | 11 500 events/s |
| 互斥锁,全线程 | 4 600 000 locks/s |
| 互斥锁,每线程 | 575 000 locks/s |

两台机器在全线程 CPU 上相差 0.04%,其余各项在 2% 以内;按 60 秒默认跑一次,对该基准得 101.0 分。

**机器繁忙时内存那项不可用**:在一台有负载的笔记本、4 核容器里重复 5 次,结果在 57 448 到
136 679 MiB/s 之间,而同期 CPU 的波动不超过 0.5%。内存子分只能在**测量时都空闲**的机器之间比较。

文件 I/O 的参考值**不是**在那台机器上测的,那里没跑 I/O 测试。

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
- 各项测试**串行**执行,不并行;`--remote` 也是一台一台走,原因相同。另有锁文件防止同一台机器上
  两次调用重叠。这些都看不见的是**同一物理机上的另一台虚拟机** —— 同宿主的多个 guest 请逐台测,
  否则它们量的是彼此。
- 繁忙守卫的存在是因为:在繁忙机器上跑基准,量到的有一部分是别的负载。它采样的是**实际 CPU
  占用率**而非负载均值:macOS 的负载均值把等待 I/O 和 Mach 端口的线程也算进去,一台空闲的 Mac
  会报负载 8 而 CPU 其实 85% 空闲;而在容器里 `/proc/stat` 报的是宿主机的 CPU 而不是 cgroup 的。
  存在 cgroup 配额时改读 `cpu.stat`。拒绝运行时会列出当时最忙的几个进程。
