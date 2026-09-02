# dalex-ops-toolkit

**Small, self-contained ops scripts for mixed macOS / Debian / RHEL fleets.**
每个脚本都是单文件、可 `curl` 直接跑、不依赖运行时。

| Directory | Scripts | What they answer |
|---|---|---|
| [`tz/`](tz/) | [`tzcheck.sh`](tz/tzcheck.sh), [`tzcheck.ps1`](tz/tzcheck.ps1) | Which tz database does each host carry, and what will a zone actually do this autumn? |
| [`jdk/`](jdk/) | [`jdkcheck.sh`](jdk/jdkcheck.sh) | Which JDKs are installed, which are actually running, and what tz database each one bundles? |

Each directory has its own README with usage, options and sample output:
[tz/README.md](tz/README.md) · [jdk/README.md](jdk/README.md)

每个目录下都有自己的 README,含用法、选项与示例输出。

## Requirements / 依赖

`bash` 3.2 or newer with GNU or BSD `date`; PowerShell 5.1 or newer for `tzcheck.ps1`.
Nothing else is required — the scripts have no runtime dependencies and are meant to be run
straight from a URL or copied onto a host.

`bash` 3.2+(GNU 或 BSD `date`);`tzcheck.ps1` 需要 PowerShell 5.1+。
除此之外无其他依赖 —— 脚本没有运行时依赖,可直接从 URL 运行或拷到主机上执行。

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

---

## License

MIT
