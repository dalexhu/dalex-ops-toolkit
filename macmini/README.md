# macmini — always-on server baseline for a Mac mini

> Part of [dalex-ops-toolkit](../README.md) — the disclaimer and licence are in the
> [top-level README](../README.md). 本目录属于 [dalex-ops-toolkit](../README.md),
> 免责声明与许可见仓库根 README。

[English](#english) · [中文](#中文)

## English

### `macmini-init.sh` — check, then apply, the "never sleeps, never reboots itself" setup

A Mac mini that hosts VMs or services has to survive unattended for months. Out of the box
it does not: it naps, it turns the display and disks off, it auto-installs macOS updates
and reboots at 3 am, and every VM on it goes down with it. This script reads the machine's
real state, shows what differs from the baseline, and with `--apply` fixes exactly those
items — running it twice changes nothing the second time.

| Area | Baseline |
|---|---|
| power | `pmset`: sleep, disksleep, displaysleep, powernap, standby **0**; autorestart after power loss, wake-on-LAN, ttyskeepawake, tcpkeepalive **1** |
| keep-awake | a per-user LaunchAgent (`com.keepawake.caffeinate`) running `caffeinate -dimsu` forever |
| screen saver | idle time 0 |
| updates | macOS: check **on**, download **on**, install **off** (patches are staged, never applied by themselves); security responses off; App Store auto-update off |
| network | Wi-Fi off; primary interface reported, warns when it is on DHCP |
| ssh | Remote Login on |
| login banner | login window shows `<hostname> \| <ip>` so whoever is at the console knows which box it is |
| hostname / time zone / firewall | enforced only when you pass `--hostname`, `--timezone`, `--firewall` |
| network time | "set date and time automatically" on. macOS needs root even to *read* this, so a plain check reports it as unknown unless you run `sudo -v` first; `--apply` always handles it |
| auto-login | reported; enforced with `--autologin <user>` (VMs set to "start at login" need it to come back after a reboot) |
| FileVault | reported; **on** blocks auto-login and unattended reboots, and hides ssh until someone unlocks the console |
| hypervisor | Parallels Desktop / VMware Fusion / UTM / OrbStack detected, VMs listed; `--install-vm` installs one via Homebrew |
| updaters | third-party auto-updaters (Google Keystone, Sparkle, …) listed, not touched |

#### Run it

Audit only (no sudo, changes nothing):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/macmini/macmini-init.sh)
```

Apply, on the box itself, logged in as the user that owns the VMs (sudo asks for a password):

```bash
curl -fsSLO https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/macmini/macmini-init.sh
bash macmini-init.sh --apply --hostname macmini-v2-a --timezone America/Edmonton --firewall off
```

Across a fleet over ssh (download it first — `--remote` ships the file itself to each host;
`--apply` copies it over and runs it with a tty so sudo can prompt):

```bash
bash macmini-init.sh --remote mini1,mini2                        # audit
bash macmini-init.sh --remote mini1,mini2 --apply --timezone America/Edmonton
```

#### Options

```
--apply                   Change what differs. Without it the script only reports.
--hostname <name>         Expected host name; set with --apply
--timezone <IANA>         Expected time zone; set with --apply
--firewall on|off         Expected application firewall state; set with --apply
--autologin <user>        Expect automatic login for <user>; --apply prompts for the password
--install-vm <name>       With --apply, brew install --cask parallels | vmware-fusion | utm
--keep-wifi               Do not expect / turn off Wi-Fi
--keep-security-updates   Leave XProtect / security-response auto-install on
--no-auto-download        Also turn automatic download off
--no-banner               Do not manage the login-window banner
--remote <a[,b,...]>      Run on those ssh targets instead
-q, --quiet               Summary line only
```

Exit codes: `0` baseline met / applied · `1` items differ (check), a change failed (apply),
or a host unreachable · `2` usage error or not macOS.

#### What it will not do

- Change the IP configuration. A server wants a static IP or a DHCP reservation; that is a
  decision, so it only warns.
- Remove third-party updaters or turn FileVault off. It tells you; you decide.
- Run as root. Per-user items (the keep-awake agent, the screen saver) must land in the login
  user's domain, so run it as that user and let it `sudo` inside.

#### Sample output

```
================ mini-a — macOS 26.6.2 — Mac16,10 ================
  Apple M4, 32 GB, up 41 mins, mode: check

power (pmset, AC)
  OK    sleep                        0
  FIX   displaysleep                 10                             want 0
  FIX   autorestart                  0                              want 1
  OK    womp                         1

keep-awake
  FIX   com.keepawake.caffeinate     missing                        caffeinate -dimsu LaunchAgent

software updates
  FIX   check for updates            unset                          want on
  OK    download updates             on
  FIX   install macOS updates        on                             want off
  FIX   App Store auto-update        on                             want off
  INFO  last OS update installed     25G83 on 2026-09-03 15:05:03 +0000

network
  FIX   wi-fi (en1)                  On                             want off
  OK    primary (en0, Ethernet)      10.0.1.194 static
  OK    remote login (ssh)           on
  FIX   login banner                 (none)                         want "mini-a | 10.0.1.194"

identity
  OK    time zone                    America/Edmonton
  OK    network time (ntp)           on                             time.apple.com

security
  OK    application firewall         off
  WARN  FileVault                    on                             blocks auto-login and unattended reboot
  WARN  auto-login                   off                            VMs set to start at login will not come back after a reboot; see --autologin

hypervisor
  OK    installed                    VMware Fusion 26.0.1

mini-a: 11 items differ, 13 ok, 3 warnings — run again with --apply
```

---

## 中文

### `macmini-init.sh` —— 先检查、再应用"永不休眠、永不自己重启"的服务器基线

跑虚拟机或服务的 Mac mini 要无人值守好几个月。出厂状态做不到:它会打盹、会关显示器和硬盘、
会在凌晨三点自动装 macOS 更新然后重启,上面的虚拟机全跟着断。这个脚本读取机器的真实状态,
列出与基线的差异,加 `--apply` 时只改那些有差异的项 —— 跑第二遍什么都不会再动。

| 项目 | 基线 |
|---|---|
| 电源 | `pmset`:sleep、disksleep、displaysleep、powernap、standby 全部 **0**;断电后自动开机、网络唤醒、ttyskeepawake、tcpkeepalive 全部 **1** |
| 防休眠 | 用户级 LaunchAgent(`com.keepawake.caffeinate`)常驻运行 `caffeinate -dimsu` |
| 屏保 | 空闲时间 0 |
| 系统更新 | macOS:检查**开**、下载**开**、安装**关**(补丁提前下好,但绝不自动装);安全响应关;App Store 自动更新关 |
| 网络 | Wi-Fi 关;报告主网卡,若是 DHCP 则警告 |
| ssh | 远程登录开 |
| 登录界面横幅 | 登录窗口显示 `<主机名> \| <IP>`,在机房看一眼就知道是哪台 |
| 主机名 / 时区 / 防火墙 | 只有传了 `--hostname`、`--timezone`、`--firewall` 才会强制 |
| 网络对时 | “自动设置日期与时间”开。macOS 连读取这个状态都要 root,所以纯检查模式下除非先 `sudo -v`,否则报 unknown;`--apply` 一定会处理 |
| 自动登录 | 只报告;`--autologin <user>` 才强制(设为"登录时启动"的虚拟机,重启后靠它才能回来) |
| FileVault | 只报告;**开着**会挡住自动登录和无人值守重启,重启后 ssh 也连不上,直到有人在本机解锁 |
| 虚拟机软件 | 检测 Parallels Desktop / VMware Fusion / UTM / OrbStack 并列出虚拟机;`--install-vm` 通过 Homebrew 安装 |
| 第三方更新器 | 列出 Google Keystone、Sparkle 之类的自动更新器,不动它们 |

#### 运行

只检查(不需要 sudo,不改任何东西):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/macmini/macmini-init.sh)
```

在机器本地应用,用拥有虚拟机的那个账号登录(sudo 会要密码):

```bash
curl -fsSLO https://raw.githubusercontent.com/dalexhu/dalex-ops-toolkit/main/macmini/macmini-init.sh
bash macmini-init.sh --apply --hostname macmini-v2-a --timezone America/Edmonton --firewall off
```

批量走 ssh(先下载成文件,`--remote` 会把脚本本体送到每台机器;`--apply` 会先拷过去,
再带 tty 执行,好让 sudo 能提示输密码):

```bash
bash macmini-init.sh --remote mini1,mini2                        # 只检查
bash macmini-init.sh --remote mini1,mini2 --apply --timezone America/Edmonton
```

#### 选项

```
--apply                   修改有差异的项。不带它只报告。
--hostname <name>         期望的主机名;--apply 时设置
--timezone <IANA>         期望的时区;--apply 时设置
--firewall on|off         期望的应用防火墙状态;--apply 时设置
--autologin <user>        期望 <user> 自动登录;--apply 时提示输入该账号密码
--install-vm <name>       --apply 时 brew install --cask parallels | vmware-fusion | utm
--keep-wifi               不要求 / 不关闭 Wi-Fi
--keep-security-updates   保留 XProtect / 安全响应的自动安装
--no-auto-download        连自动下载也关掉
--no-banner               不管理登录界面横幅
--remote <a[,b,...]>      改在这些 ssh 目标上运行
-q, --quiet               只打印汇总行
```

退出码:`0` 符合基线 / 已应用 · `1` 有差异(检查)、某项修改失败(应用)或主机不可达 · `2` 用法错误或不是 macOS。

#### 它不会做的事

- 不改 IP 配置。服务器应该用静态 IP 或 DHCP 保留,这是个决策,所以只警告。
- 不删第三方更新器,不关 FileVault。它告诉你,你来定。
- 不以 root 运行。用户级的项(防休眠 agent、屏保)必须落在登录用户的域里,所以用那个用户跑,
  脚本内部自己 `sudo`。

示例输出见上方英文部分。
