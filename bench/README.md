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

Installs `sysbench` if it is missing (`apt`, or `dnf` with EPEL enabled first — it is not in the
RHEL base repos). Pass `--no-install` to skip that.

Across a fleet, downloading it first so `--remote` can pipe the file to each host:

```bash
curl -fsSLO https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/bench/perfcheck.sh
bash perfcheck.sh --remote app1,app2,db1
```

### Options

```
--time <sec>       Seconds per test (default 10)
--quick            Same as --time 3
--io               Also run the file I/O test (off by default)
--io-dir <path>    Directory for the I/O test file (default: current directory)
--no-install       Do not install sysbench if it is missing
--force            Run even when the machine is already busy
--remote <a[,b,]>  Also run on those ssh targets and print a fleet summary
-q, --quiet        Summary only
```

### How it sizes itself

| Reading | Effect |
|---|---|
| logical cores (`nproc`) | starting point for the thread counts |
| **cgroup CPU quota** | when a container or slice caps CPU below the visible core count, the tests use the quota instead — `cpu.max` on cgroup v2, `cpu.cfs_quota_us` on v1 |
| total RAM | memory test target size; I/O file size starts at 2× RAM |
| free space in the I/O directory | I/O file capped at a quarter of it, and at 8 GiB |
| 1-minute load average | the run is refused if load exceeds 25% of the usable cores, unless `--force` |

The quota reading matters more than it sounds. In a container limited to 4 CPUs on a 16-core
host, `nproc` still answers 16; sizing the CPU test from that measures the throttling, not the
machine. The same run scored 83.8 before the quota was taken into account and 99.5 after.

### What each test measures

| Test | Parameters | Metric |
|---|---|---|
| cpu, all threads | `--cpu-max-prime=20000`, threads = usable cores | events/s |
| cpu, single thread | same, one thread | events/s |
| memory | 1 MiB blocks, write, threads = usable cores | MiB/s |
| threads | 4× oversubscribed, `--thread-yields=1000 --thread-locks=8` | events/s, derived from the total event count — this test prints no rate of its own |
| mutex | 4096 mutexes, 50 000 locks per thread, 5 000 loops | locks/s |
| file I/O (opt-in) | random read/write, `--file-fsync-freq=0` | IOPS, MiB/s, 95th percentile latency |

The mutex test takes `--mutex-locks` *per thread*, so its elapsed time is not comparable
between machines with different core counts. Throughput is, which is why the metric is locks/s
rather than seconds.

### Scoring

Each result is divided by the reference value for that test, so 100 means "the same as the
reference". The composite is a **weighted geometric mean** of the five subscores:

| Subscore | Weight |
|---|---|
| cpu, all threads | 30% |
| cpu, single thread | 25% |
| memory | 20% |
| threads | 15% |
| mutex | 10% |

A geometric mean is the right average for ratios, and unlike an arithmetic mean it does not let
one enormous subscore carry the composite on its own.

**File I/O never enters the composite**, so a score means the same thing whether or not `--io`
was used. Storage varies far more than the rest of a machine and would drown everything else.

The reference numbers are arbitrary — they only decide where 100 sits. Every one of them can be
overridden, which is how to calibrate the scale against a machine of your own:

```bash
PERFCHECK_REF_CPU_MULTI=45000 PERFCHECK_REF_MEMORY=100000 bash perfcheck.sh
```

`PERFCHECK_REF_CPU_MULTI`, `_CPU_SINGLE`, `_MEMORY`, `_THREADS`, `_MUTEX`, `_IO_IOPS`.

A score is a comparison, not a verdict: it says how this host compares with the reference and
with the other hosts measured the same way.

### Sample output

```
================ app01 — Debian GNU/Linux 13 — x86_64 ================

Machine
  cpu                    Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
  cores                  16 logical / 8 physical / 1 socket(s)
  cgroup cpu quota       4.00 cores — tests use 4 threads, not 16
  memory                 32109 MiB total, 28776 MiB available
  virtualisation         kvm
  time per test          10s
  load average (1m)      0.14  (3.5% of 4 cores)

Scores (100 = reference profile v1)
  TEST                         MEASURED    REFERENCE  SCORE
  cpu, all cores               19982.31        20000   99.9
  cpu, single thread            5240.61         5000  104.8
  memory MiB/s                 92208.62       100000   92.2
  threads events/s              7743.33         8000   96.8
  mutex locks/s                 2971768      2500000  118.9

Composite
  100.8   weighted geometric mean: cpu-all 30%, cpu-1 25%, memory 20%, threads 15%, mutex 10%
```

### Notes

- Runs shorter than 10 s vary between repeats, the memory test most of all. `--quick` is for
  checking that the script works, not for numbers you intend to compare.
- The I/O test writes a file sized from RAM and free space, and removes it afterwards — on exit,
  on interrupt, and on failure.
- The load guard exists because a benchmark on a busy host measures the other workload too.

---

## 中文

### `perfcheck.sh` —— 按机器自动定型的 sysbench,最后归一到一个分数

先读机器 —— 核数、cgroup CPU 配额、内存、存储、虚拟化 —— 用读到的信息推导出所有 sysbench
参数,跑完再按参考基准打分。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/bench/perfcheck.sh)
```

`sysbench` 缺失时会自动装(`apt`;RHEL 系先启用 EPEL —— 基础仓库里没有它)。
用 `--no-install` 可跳过。

批量走 ssh(先下载成文件,`--remote` 会把脚本本体喂给每台机器):

```bash
curl -fsSLO https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/bench/perfcheck.sh
bash perfcheck.sh --remote app1,app2,db1
```

### 选项

```
--time <sec>       每项测试的秒数(默认 10)
--quick            等同 --time 3
--io               跑文件 I/O 测试(默认不跑)
--io-dir <path>    I/O 测试文件所在目录(默认当前目录)
--no-install       缺 sysbench 时不自动安装
--force            机器已经很忙时仍然强制运行
--remote <a[,b,]>  同时在这些 ssh 目标上跑,最后出汇总表
-q, --quiet        只输出汇总
```

### 怎么自动定型

| 读到的信息 | 作用 |
|---|---|
| 逻辑核数(`nproc`) | 线程数的起点 |
| **cgroup CPU 配额** | 容器或 slice 把 CPU 限制在可见核数之下时,按配额而不是核数定线程 —— cgroup v2 读 `cpu.max`,v1 读 `cpu.cfs_quota_us` |
| 总内存 | 内存测试的目标容量;I/O 文件初始按 2× 内存 |
| I/O 目录可用空间 | I/O 文件上限取其 1/4,且不超过 8 GiB |
| 1 分钟负载 | 负载超过可用核数的 25% 时拒绝运行,除非 `--force` |

配额这条比听起来重要。在 16 核宿主机上限制为 4 CPU 的容器里,`nproc` 仍然回答 16,
按它定线程测到的是**限流**而不是机器本身。同一次运行,计入配额前得 83.8 分,计入后 99.5 分。

### 每项测什么

| 测试 | 参数 | 指标 |
|---|---|---|
| cpu 全线程 | `--cpu-max-prime=20000`,线程 = 可用核数 | events/s |
| cpu 单线程 | 同上,1 线程 | events/s |
| 内存 | 1 MiB 块、写、线程 = 可用核数 | MiB/s |
| 线程 | 4 倍超订,`--thread-yields=1000 --thread-locks=8` | events/s,由总事件数换算 —— 这项测试本身不输出速率 |
| 互斥锁 | 4096 个 mutex、每线程 50000 次加锁、5000 次空循环 | locks/s |
| 文件 I/O(需 `--io`) | 随机读写,`--file-fsync-freq=0` | IOPS、MiB/s、95 分位延迟 |

mutex 测试的 `--mutex-locks` 是**每线程**的,所以它的总耗时在不同核数的机器之间不可比,
吞吐才可比 —— 这就是指标用 locks/s 而不是秒的原因。

### 打分方式

每项结果除以该项的参考值,100 表示"与参考基准相同"。综合分是五项子分的**加权几何平均**:

| 子项 | 权重 |
|---|---|
| cpu 全线程 | 30% |
| cpu 单线程 | 25% |
| 内存 | 20% |
| 线程 | 15% |
| 互斥锁 | 10% |

比值型数据本就该用几何平均;而且与算术平均不同,单独一项畸高的子分不会把综合分整个抬起来。

**文件 I/O 永远不进综合分**,所以跑没跑 `--io`,分数含义都一样。存储的离散度远大于机器其余部分,
放进去会把其他项淹没。

参考值是任意选定的 —— 它们只决定 100 分落在哪里。每一项都可以覆盖,
这也是把标尺校准到你自己某台基准机的方式:

```bash
PERFCHECK_REF_CPU_MULTI=45000 PERFCHECK_REF_MEMORY=100000 bash perfcheck.sh
```

可用变量:`PERFCHECK_REF_CPU_MULTI`、`_CPU_SINGLE`、`_MEMORY`、`_THREADS`、`_MUTEX`、`_IO_IOPS`。

分数是比较值,不是判决:它说明这台机器相对参考基准、以及相对用同样方式测过的其他机器处在什么位置。

### 注意

- 短于 10 秒的运行在重复之间波动明显,内存测试尤甚。`--quick` 用来确认脚本能跑,
  不适合用来比较数字。
- I/O 测试会写一个按内存与可用空间定大小的文件,结束后删除 —— 正常退出、被中断、失败时都会删。
- 负载守卫的存在是因为:在繁忙机器上跑基准,量到的有一部分是别的负载。
