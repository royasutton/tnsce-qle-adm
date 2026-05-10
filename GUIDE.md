# Complete Guide

`qle_adm.sh` v3.0: QLogic FC Target Manager for TrueNAS SCALE CE

---

## Table of Contents

1. [Architecture & Design](#architecture--design)
2. [Installation](#installation)
3. [Command Reference](#command-reference)
4. [Initiator Setup](#initiator-setup)
5. [Persistence & Survival](#persistence--survival)
6. [Firmware Management](#firmware-management)
7. [ISP Parameter Profiles](#isp-parameter-profiles)
8. [WWN Naming](#wwn-naming)
9. [Troubleshooting](#troubleshooting)
10. [FAQ](#faq)
11. [config.json Reference](#configjson-reference)
12. [Known Limitations](#known-limitations)

---

## Architecture & Design

### How the stack fits together

```
TrueNAS SCALE CE
│
├── SCST (scst.ko)                      ← SCSI target framework
│   ├── scst_vdisk.ko                   ← block device handler
│   └── qla2xxx_scst.ko                 ← FC target driver
│       └── qla2x00tgt                  ← FC target template in SCST
│
└── qle_adm.sh
    ├── config.json  (${QLE_ADM_HOME}/) ← single source of truth
    ├── /etc/scst.conf                  ← rebuilt at boot and on sync
    ├── /etc/modprobe.d/                ← module params (restored by sync --system)
    └── TrueNAS middleware DB           ← POSTINIT boot entry (survives BE changes)
```

### Configuration model

`config.json` on `/mnt` is the single source of truth. Two representations
are derived from it:

**`/etc/scst.conf` FC target block** is rebuilt from config.json by `sync`.
SCST reads this file at startup to initialize all FC target state - enabled
ports, rel_tgt_ids, LUN mappings, and initiator groups. No sysfs writes are
performed at boot; SCST initializes everything from its own config file.

**Live sysfs** handles all runtime changes. Every change command
(`port enable/disable`, `open`, `close`, `assign`, `unassign`) writes to
both sysfs and config.json atomically. There is no separate save step.

### Why scst.conf for boot, sysfs for runtime

SCST reads `/etc/scst.conf` once at startup. It has no reload mechanism -
there is no `SIGHUP` or `systemctl reload`. Runtime changes must go through
sysfs. The split architecture uses each path for what it does best: scst.conf
for clean initialization at startup, sysfs for zero-disruption runtime changes.

### Why the WUI wipes scst.conf and what sync does about it

The TrueNAS WUI regenerates `/etc/scst.conf` from its internal iSCSI database
on every iSCSI configuration save. It has no knowledge of FC targets. Running
`sync` after a WUI save rebuilds the `TARGET_DRIVER qla2x00t {}` block from
config.json without touching live sysfs state or active sessions. The WUI does
not restart SCST when saving iSCSI changes (it uses sysfs for live iSCSI
updates), so active FC and iSCSI sessions are unaffected by WUI saves.

### Why qlini_mode=dual instead of disabled

`qlini_mode=disabled` prevents the ISP2532 from asserting a valid FC signal
on a direct P2P connection. The port stays in an unknown topology state and
never transmits FLOGI. `qlini_mode=dual` keeps the initiator stack active
alongside the target stack, which causes the ISP2532 to properly assert the
port signal and complete P2P negotiation. This is required for direct cable
(switchless) ISP2532 target operation.

### ISP2432 target mode - current status unknown

ISP2432 (QLE2462, QLE2460) hardware supports FC target mode in principle.
However target mode initialization has not been successfully achieved on Linux
kernel 6.12 with `qla2xxx_scst`. The card produces AEN `0x8017 a964`
continuously and `fw_state` returns all-F values - firmware unresponsive in
target mode. This has been observed across all firmware versions tested and
with multiple module parameter combinations. The root cause has not been
determined - it may be a driver/kernel interaction or a parameter combination
not yet found. Further debugging may resolve it.

ISP2432 works correctly as a plain initiator using the `qla2xxx` module. If
you are investigating ISP2432 target mode, use `isp-params set` and
`module reload` to try parameter combinations without rebooting.

### Why ql2xfwloadbin=0 (HBA flash)

The default firmware source is the HBA primary flash slot (`ql2xfwloadbin=0`). This is the most stable source — firmware is burned to the card by the manufacturer or a deliberate flash operation. No file needs to be present and boot is fast. Use `fw use <version>` to switch to a stored filesystem version when needed.

---

## Installation

### Prerequisites

Before installing, confirm on TrueNAS:

1. **SCST is running:**
   ```bash
   systemctl is-active scst
   cat /sys/module/scst/version
   ```

2. **qla2xxx_scst module is available:**
   ```bash
   modinfo qla2xxx_scst | grep filename
   ```

3. **A ZFS zvol exists and is registered in SCST** as a block device.
   Verify it appears in `/etc/scst.conf` under `HANDLER vdisk_blockio`.
   If not, add it manually:
   ```bash
   # In /etc/scst.conf, under HANDLER vdisk_blockio:
   DEVICE <name> {
       filename /dev/zvol/<pool>/<zvol>
       blocksize 512
   }
   ```
   Then reload SCST: `systemctl restart scst`

4. **A dataset on your data pool** for persistent storage:
   Create a dataset in the TrueNAS web UI under your pool, e.g.
   `tank/admin`. This gives you `/mnt/tank/admin` as a persistent location.

### Step-by-step install

```bash
# Set your pool name and define QLE_ADM_HOME - all commands below use it.
# QLE_ADM_HOME must be on a dataset under /mnt to survive boot environment
# changes and TrueNAS upgrades. Everything - the script, config.json, and
# firmware store - lives here.
POOL=tank
export QLE_ADM_HOME=/mnt/${POOL}/admin/qle_adm

# Create the home directory and copy the script into it
mkdir -p ${QLE_ADM_HOME}
cp qle_adm.sh ${QLE_ADM_HOME}/
chmod +x ${QLE_ADM_HOME}/qle_adm.sh

# Run install - registers POSTINIT boot entry and writes modprobe config
${QLE_ADM_HOME}/qle_adm.sh --yes install

# Add to your shell startup script (~/.bashrc or ~/.zshrc) so qle_adm.sh
# is available by name from any directory on this and future sessions.
# The install command prints these lines for you to copy.
export QLE_ADM_HOME=/mnt/${POOL}/admin/qle_adm
PATH="${PATH}:${QLE_ADM_HOME}"

# Optional: disable color or unicode symbols if your terminal doesn't support them
# export QLE_ADM_USE_COLOR=0
# export QLE_ADM_USE_UNICODE=0

# Inject FC target block into scst.conf before loading the module
${QLE_ADM_HOME}/qle_adm.sh sync

# Load the module - SCST reads the FC target block on module registration
${QLE_ADM_HOME}/qle_adm.sh module load

# Verify - confirm no gaps before proceeding
${QLE_ADM_HOME}/qle_adm.sh status
```

### What install creates

| File | Purpose | Survives BE? |
|---|---|---|
| `${QLE_ADM_HOME}/qle_adm.sh` | Main script | ✓ |
| `${QLE_ADM_HOME}/config.json` | Persistent config | ✓ |
| `${QLE_ADM_HOME}/firmware/` | Firmware store | ✓ |
| `/etc/modprobe.d/qla2xxx_scst.conf` | Module params | ✗ restored by sync --system |
| TrueNAS middleware POSTINIT entry | Boot trigger | ✓ survives all BE changes |

The POSTINIT entry is visible and manageable under System > Advanced >
Init/Shutdown Scripts in the WUI. It is the only boot component that
does not need restoring after a BE change or upgrade.

### After an upgrade or boot environment change

```bash
${QLE_ADM_HOME}/qle_adm.sh sync --system --restart
${QLE_ADM_HOME}/qle_adm.sh status
```

`sync --system` restores the modprobe config in `/etc` and rebuilds
scst.conf from config.json. `--restart` restarts SCST in one step.
The POSTINIT boot entry in the TrueNAS middleware database survives
all BE changes - no reinstall is needed.

---

## Command Reference

All commands are run as `qle_adm.sh <command>` once `QLE_ADM_HOME` is on
your `PATH` (set during install). Alternatively use the full path
`${QLE_ADM_HOME}/qle_adm.sh <command>`, or `./qle_adm.sh <command>`
from the install directory.

### Global options

| Option | Description |
|---|---|
| `--dry-run` | Print all actions without executing any writes |
| `--yes` | Skip all interactive confirmations |
| `--verbose` | Extra diagnostic output |
| `--home <path>` | Override QLE_ADM_HOME for this invocation |
| `--port N` | Select FC port by index from `list-ports` |
| `--init N` | Select initiator by index from `list-initiators` |
| `--ext N` | Select extent by index from `list-extents` |

### Environment variables

Set these in `~/.bashrc` or `~/.zshrc`. All are optional except `QLE_ADM_HOME`.

| Variable | Default | Description |
|---|---|---|
| `QLE_ADM_HOME` | *(required)* | Path to persistent store on a dataset under `/mnt` |
| `QLE_ADM_USE_COLOR` | `1` | Set to `0` to disable ANSI color codes in output |
| `QLE_ADM_USE_UNICODE` | `1` | Set to `0` for ASCII fallback symbols (`* ! x > -`) |

Example `~/.bashrc` block:
```bash
export QLE_ADM_HOME=/mnt/tank/local/admin/tnsce-qle-adm
PATH="${PATH}:${QLE_ADM_HOME}"
# export QLE_ADM_USE_COLOR=0      # uncomment if terminal has no color support
# export QLE_ADM_USE_UNICODE=0    # uncomment if terminal can't render Unicode
```

### Deployment

| Command | Description |
|---|---|
| `install` | Register POSTINIT boot entry in TrueNAS middleware DB, write modprobe config, copy script to QLE_ADM_HOME |
| `uninstall` | Remove all installed components, preserve config.json |

### Operation

| Command | Description |
|---|---|
| `sync [--boot] [--apply] [--restart] [--system]` | Rebuild scst.conf from config.json. `--boot` writes a boot marker to the log, names target ports, and implies `--system`. No module touching — the kernel autoloads `qla2xxx_scst` via udev using params from the modprobe conf; SCST picks it up on start and registers `qla2x00t` cleanly. `--apply` rebuilds scst.conf then applies it to the live SCST sysfs tree via scstadmin - no restart, no session drops. Use when `list-extents` shows `[no sysfs]`. `--restart` rebuilds scst.conf then restarts scst.service (warns and confirms - all active sessions dropped). Use after a BE change to resync module params without rebooting. `--system` writes/restores the modprobe conf in `/etc`; implied by `--boot`. Without any flag, scst.conf only - always safe. |
| `module <load\|unload\|reload\|status>` | Manage the qla2xxx_scst kernel module independently of SCST and config files (see below). |
| `teardown` | Deactivate targets, revert to plain initiator mode |
| `clear <target>` | Clear accumulated state (see below) |

**clear targets:**
```
clear seen       : wipe seen_initiators history
clear ports      : disable all ports and clear enabled_ports
clear mappings   : remove all open/assigned LUNs from sysfs and config
clear names      : wipe all WWN names
clear all        : all of the above (prompts unless --yes)
```

### Module management

The `module` command manages the `qla2xxx_scst` kernel module independently
of the SCST service and configuration files. This separation allows module
state to be managed precisely without affecting scst.conf or restarting SCST.

```bash
./qle_adm.sh module load      # load with configured params; skip if already correct
./qle_adm.sh module unload    # remove module, revert to plain qla2xxx initiator
./qle_adm.sh module reload    # unload then load (applies isp-params changes)
./qle_adm.sh module status    # show loaded module and applied vs configured params
```

`module load` checks whether `qla2xxx_scst` is already loaded with the correct
params. If it is, it exits cleanly. If params differ, it warns and asks before
reloading. This makes `module load` safe to call idempotently.

`module reload` stops `scst.service`, unloads the module, reloads it with
the new params, then starts `scst.service` again. All active FC and iSCSI
sessions are dropped. The confirmation prompt states this explicitly.

`module status` is also surfaced in the `status` command's gap analysis as the
authoritative source for param drift detection.

**Typical param change workflow:**
```bash
./qle_adm.sh isp-params set ISP2532 --profile optrom \
  "qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=1"
./qle_adm.sh isp-params use ISP2532 --profile optrom
./qle_adm.sh module reload
```

**Retired commands** - these print an informative error and exit:

| Command | Replacement |
|---|---|
| `setup [--boot]` | `sync [--boot]` |
| `apply` | Not needed - all changes write atomically to config.json + sysfs |
| `save` | Not needed - seen_initiators captured automatically by `status` and `list-initiators` |
| `repair` | `sync` |

### Status

| Command | Description |
|---|---|
| `status` | Full state with module, service, scst.conf, port, session, and gap analysis. Passively captures seen_initiators from active sessions. |
| `list-hba` | Per-port detail: ISP type, firmware versions, PCIe link, WWN |
| `stats [--watch] [--wide]` | IO counters and link error stats |
| `list-ports` | FC ports with index, state, topology, managed status |
| `list-extents` | SCST extents with size, config state (`[open]`/`[assigned]`), and live sysfs state (`[no sysfs]`/`[mapped]`/`[connected]`/`[active]`). `[no sysfs]` = not applied, run `sync --apply`. `[mapped]` = in sysfs, no initiator session. `[connected]` = session present, no I/O yet. `[active]` = session present with I/O, shows active commands and session R/W totals. |
| `list-initiators` | Connected initiators with IO stats; previously seen initiators always shown |
| `list-assignments` | Per-initiator LUN mappings |
| `list-all` | All five list commands in sequence |

### Log management

Boot sessions are delimited in the log by `=== BOOT sync started ===` marker lines written at the start of each `sync --boot` run. Session-aware commands (`boot`, `last`, `trim`) require at least one boot with v2.29 or later.

| Command | Description |
|---|---|
| `log show [--tail N]` | Full log, paged. `--tail N` shows last N lines |
| `log boot` | Current boot session (from last marker to end of log) |
| `log last [N]` | Previous N boot sessions for comparison (default 1) |
| `log clear` | Truncate log file - confirms before clearing |
| `log trim [N]` | Keep last N boot sessions, discard older (default 10) |
| `log grep <pattern>` | Filter log by pattern |
| `log path` | Print log file path |
| `log status` | Size, line count, session count, oldest/newest entry |

### Port management

```bash
./qle_adm.sh port enable  --port 0         # by index
./qle_adm.sh port enable  <wwn>            # by WWN
./qle_adm.sh port disable --port 0
```

Writes to both sysfs (immediate) and config.json (persistent).

### LUN mapping

```bash
# Open access: all initiators see the LUN
./qle_adm.sh open  --ext 0
./qle_adm.sh close --ext 0

# Per-initiator: specific initiator only
./qle_adm.sh assign   --ext 0 --init 0
./qle_adm.sh assign   --ext 0 <initiator-wwn>
./qle_adm.sh unassign --ext 0 --init 0
```

All mapping commands write to both sysfs (immediate) and config.json
(persistent). No separate save step is required.

### Firmware

```bash
./qle_adm.sh fw save-os                        # capture OS dist firmware
./qle_adm.sh fw save-hba [--port N]            # read optrom → versioned store
./qle_adm.sh fw list                           # list stored versions
./qle_adm.sh fw add ISP2532 <file>             # import external file
./qle_adm.sh fw remove ISP2532 <version>       # remove a version
./qle_adm.sh fw use <version|hba|dist>         # set active source
./qle_adm.sh fw show [--port N]                # show card firmware detail
./qle_adm.sh fw status                         # all ports summary
```

### ISP parameter profiles

```bash
./qle_adm.sh isp-params list
./qle_adm.sh isp-params set ISP2532 --profile optrom \
  "qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=1"
./qle_adm.sh isp-params use ISP2532 --profile optrom
./qle_adm.sh isp-params del ISP2532 --profile optrom
```

### WWN naming

```bash
./qle_adm.sh name list
./qle_adm.sh name set <wwn> <name> [--port N]
./qle_adm.sh name get <wwn>
./qle_adm.sh name del <wwn>
```

---

## Initiator Setup

### Linux (Debian/Ubuntu)

Load the standard `qla2xxx` initiator driver with correct parameters:

```bash
# /etc/modprobe.d/qla2xxx.conf
options qla2xxx qlini_mode=enabled ql2xnvmeenable=0 ql2xfwloadbin=1
```

Apply immediately:
```bash
modprobe -r qla2xxx
modprobe qla2xxx qlini_mode=enabled ql2xnvmeenable=0 ql2xfwloadbin=1
```

Scan for the FC block device after the target maps a LUN:
```bash
echo "- - -" > /sys/class/scsi_host/host<N>/scan
lsblk
```

Increase `dev_loss_tmo` to prevent the driver from dropping the device
during brief link interruptions:
```bash
# /etc/udev/rules.d/99-qla2xxx-timeouts.rules
ACTION=="add", SUBSYSTEM=="fc_host", ATTR{dev_loss_tmo}="60"
ACTION=="add", SUBSYSTEM=="scsi_disk", ATTR{../timeout}="60"
```

### FC BIOS boot (booting from an FC LUN)

Configure via the QLogic Fast!UTIL option ROM utility (press Ctrl+Q during POST):

1. **HBA BIOS: Enable** (required; this is the only mandatory setting)
2. **Selectable Boot: Add** the target WWN and LUN to the boot list
3. Save and exit

Fast!UTIL settings that are optional (defaults work):
- LIP Reset: either setting works
- Connection Mode: P2P only or Loop+P2P both work with ISP2532

### Suspend and sleep

**Booting from an FC LUN and suspending the system is not supported with
deep sleep (S3/mem).** The kernel cannot complete resume without the root
filesystem, but the FC link cannot reconnect until the kernel has fully
resumed; this creates a deadlock.

**Option 1: Disable suspend (recommended):**
```bash
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

**Option 2: Use s2idle (shallow sleep, PCIe stays powered):**
```bash
mkdir -p /etc/systemd/sleep.conf.d
echo s2idle > /etc/systemd/sleep.conf.d/mem.conf
```

---

## Persistence & Survival

| Component | Reboot | BE change | Upgrade | Recovery |
|---|---|---|---|---|
| `config.json` on `/mnt` | ✓ | ✓ | ✓ | N/A |
| `qle_adm.sh` on `/mnt` | ✓ | ✓ | ✓ | N/A |
| Firmware store on `/mnt` | ✓ | ✓ | ✓ | N/A |
| TrueNAS middleware POSTINIT entry | ✓ | ✓ | ✓ | N/A |
| `/etc/modprobe.d/` | ✓ | ✗ | ✗ | `sync --system` |
| `/etc/scst.conf` FC block | ✓ | ✗ | ✗ | `sync` |
| SCST sysfs state | ✗ | ✗ | ✗ | automatic via scst.conf on boot |
| Active FC sessions | ✗ | ✗ | ✗ | automatic on reconnect |

After any BE change or upgrade:
```bash
./qle_adm.sh sync --system --restart
./qle_adm.sh status
```

---

## Firmware Management

### ql2xfwloadbin decoded

| Value | Source |
|---|---|
| `0` | HBA primary flash slot (default) |
| `1` | Optrom slot (secondary flash) |
| `2` | Filesystem — `/usr/lib/firmware/<fw_file>` |

The default is `hba` (`ql2xfwloadbin=0`). When a stored version is selected via `fw use`, qle_adm copies the firmware file directly to `/usr/lib/firmware/` at boot and sets `ql2xfwloadbin=2`. The file persists within the boot environment; a BE upgrade restores the TrueNAS original naturally.

### Versioned firmware store

Firmware is stored per ISP type in versioned subdirectories:

```
firmware/
  ISP2532/
    8.07.00/
      ql2500_fw.bin
      os_TrueNAS-SCALE-25.04.0    ← OS marker
    8.08.207/
      ql2500_fw.bin
    8.08.207-hba/                 ← collision: same version, different content
      ql2500_fw.bin
```

When two sources produce the same version string but differ in content (SHA256 mismatch), the second is stored with a `-<source>` suffix (`-hba`, `-os`, `-imported`) to preserve both. If the SHA256 matches, the store operation is a no-op.

### Workflow

```bash
# First: capture OS dist firmware before making any changes (one-time per OS version)
./qle_adm.sh fw save-os

# Save optrom firmware from HBA
./qle_adm.sh fw save-hba

# See all stored versions
./qle_adm.sh fw list

# Switch to a stored version (takes effect on next boot or sync --system)
./qle_adm.sh fw use 8.08.207

# Switch back to HBA flash
./qle_adm.sh fw use hba

# Show detail per port
./qle_adm.sh fw show
```

### Command reference

| Command | Description |
|---|---|
| `fw list` | All stored versions per ISP type with selection marker |
| `fw save-os [--port N]` | Capture OS dist firmware with `os_<TrueNAS-version>` marker. SHA256 checked. |
| `fw save-hba [--port N]` | Read HBA optrom via sysfs into versioned store. SHA256 checked. |
| `fw add <ISP> <file>` | Import external firmware file. SHA256 checked. |
| `fw remove <ISP> <version>` | Remove a specific version (not if currently selected) |
| `fw use <version\|hba\|dist> [--port N]` | Set active firmware source |
| `fw show [--port N]` | Per-port detail: running, optrom, stored, selection |
| `fw status` | One-line summary per port with sync indicator |

### Firmware version visibility

The driver only exposes the optrom slot version via sysfs (`optrom_fw_version`). The primary flash version is not readable via sysfs on this driver build; `fw show` reports it as "not exposed".

---

## ISP Parameter Profiles

Each ISP type has a set of named parameter profiles stored in `config.json`.
One profile is marked active (`*`) and used by `sync --boot --system`. Multiple
profiles allow switching between configurations without editing the config.

```bash
# View all profiles and current state
./qle_adm.sh isp-params list

# Output shows:
#   ISP2532 (detected):
#     default *: qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0
#     ──
#     Configured : default
#     Applied    : default
```

**Configured:** the active profile that will be loaded on next `sync --boot --system`.
**Applied:** the params actually running in the kernel right now.
**drift:** applied and configured differ; reload the module to resync.

---

## WWN Naming

Assign friendly names to WWNs for readable output across all commands:

```bash
# Target ports: port index auto-detected from PCI function number
./qle_adm.sh name set aa:bb:cc:dd:ee:ff:00:01 nas0
./qle_adm.sh name set aa:bb:cc:dd:ee:ff:00:02 nas0   # second port auto :1

# Initiator ports: first assignment gets :0, second gets :1
./qle_adm.sh name set aa:bb:cc:dd:ee:ff:00:10 workstation
./qle_adm.sh name set aa:bb:cc:dd:ee:ff:00:11 workstation
```

Output throughout the tool then shows:
```
[0] ● aa:bb:cc:dd:ee:ff:00:10 (workstation:0) → aa:bb:cc:dd:ee:ff:00:01 (nas0:0)
```

---

## Troubleshooting

### Link won't come up: checklist

```bash
./qle_adm.sh status
./qle_adm.sh list-hba
./qle_adm.sh isp-params list
dmesg | grep qla2xxx | tail -20
```

Common causes and fixes:

| Symptom | Cause | Fix |
|---|---|---|
| `port_state: Linkdown` on both sides | Wrong `qlini_mode` | Ensure `qlini_mode=dual` for ISP2532 target |
| `LOOP UP detected` instead of `Online P2P` | Loop topology negotiated | Both sides must use P2P capable firmware |
| AEN `8017 d17f` flood | No optical signal | Check SFP seating, cable, correct port |
| `port_type: Unknown` after enable | SCST not running or `qla2x00tgt` not registered | Check `systemctl status scst`, run `sync --restart` |
| Both sides `Linkdown` after module reload | Firmware version mismatch | Check `fw show` |

### AEN error code reference

| Code | Meaning |
|---|---|
| `8017 d17f` | No optical signal (SFP or cable issue) |
| `8017 4034` | Loop arbitration timeout (topology mismatch) |
| `8017 a964` | Target mode firmware init failure (ISP2432 on kernel 6.12 - root cause unknown) |
| `8017 a284` | FLOGI timeout (target transmitting, initiator not responding) |

### scst.conf FC block missing after WUI save

```bash
./qle_adm.sh sync
```

This rebuilds the block from config.json without touching active sessions.
No SCST restart needed - the WUI does not restart SCST on iSCSI saves.

### scst.conf does not exist

`/etc/scst.conf` is owned by TrueNAS SCST. `qle_adm.sh` never creates it -
it only modifies an existing file. If the file is missing, SCST has either
never been started or its installation is incomplete.

```bash
systemctl is-active scst
systemctl start scst
# Once scst.conf exists, sync can write the FC target block:
./qle_adm.sh sync
```

### Targets not active after upgrade or BE change

The POSTINIT boot entry survives the upgrade and will have run automatically.
If targets are still not active, the modprobe config or scst.conf block may
need restoring:

```bash
./qle_adm.sh sync --system --restart
./qle_adm.sh status
```

### Block device not appearing on initiator

```bash
# Confirm session is established on target
./qle_adm.sh list-initiators

# Confirm LUN is mapped
./qle_adm.sh list-assignments

# Rescan on initiator
echo "- - -" > /sys/class/scsi_host/host<N>/scan
dmesg | grep -i "sd\|lun" | tail -10
```

### Session drops on idle

The FC driver drops remote ports after `dev_loss_tmo` seconds of no link
activity. Default is 16 seconds, which is too short for idle periods.

```bash
# Set to 60 seconds persistently
cat > /etc/udev/rules.d/99-qla2xxx-timeouts.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="fc_host", ATTR{dev_loss_tmo}="60"
ACTION=="add", SUBSYSTEM=="scsi_disk", ATTR{../timeout}="60"
EOF
udevadm control --reload-rules
```

**Critical for FC root boot:** if `dev_loss_tmo` is too short, any brief
link hiccup causes the root device to disappear, triggering a kernel panic.
Set to at least 60.

### rel_tgt_id conflicts with iSCSI

FC target ports use `rel_tgt_id` values starting at 10 to avoid conflict
with iSCSI targets which typically occupy slots 1-9. If you see
`invalid slot` errors when enabling a port, check what IDs are in use:
```bash
cat /sys/kernel/scst_tgt/targets/iscsi/*/rel_tgt_id 2>/dev/null
cat /sys/kernel/scst_tgt/targets/qla2x00t/*/rel_tgt_id 2>/dev/null
```

---

## FAQ

**Q: Can I use my ISP2432 (QLE2462/QLE2460) as an FC target?**

The hardware supports target mode in principle, but target mode initialization
has not been successfully achieved on Linux kernel 6.12 with `qla2xxx_scst`.
The card produces AEN `0x8017 a964` continuously with all firmware versions
and parameter combinations tested so far. The root cause is not yet determined
and further debugging may find a working configuration. ISP2432 works correctly
as an initiator using the plain `qla2xxx` driver. If you are investigating
ISP2432 target mode, `isp-params set` and `module reload` allow parameter
changes without rebooting - watch `dmesg` for AEN codes.

---

**Q: Why does the TrueNAS WUI overwrite my scst.conf?**

The WUI manages iSCSI configuration through its own internal database. When
you make any iSCSI change and save, the WUI regenerates `/etc/scst.conf`
from that database, replacing the file entirely. Run `sync` after a WUI
iSCSI save to rebuild the FC target block from config.json. The WUI does not
restart SCST on iSCSI saves, so active sessions are unaffected.

---

**Q: Why does qle_adm use qlini_mode=dual instead of disabled?**

`qlini_mode=disabled` causes the ISP2532 to not assert a valid FC signal on
a direct P2P connection. `qlini_mode=dual` keeps the initiator stack active
alongside the target stack, which causes the ISP2532 to properly assert the
port signal and complete P2P negotiation on a direct cable. This is required
for direct (switchless) ISP2532 target operation.

---

**Q: What is the default firmware source and when should I change it?**

The default is `ql2xfwloadbin=0` (primary flash slot). Use `fw show` to
compare primary and optrom versions. If the optrom slot contains a newer
version you want to use, change to `ql2xfwloadbin=1` via `isp-params set`.
If you want to use a firmware file stored on the filesystem, use `fw save`
to extract the optrom to the firmware store, then set `ql2xfwloadbin=2`.

---

**Q: Why does qle_adm reconstruct scst.conf at boot instead of applying via sysfs?**

SCST reads `/etc/scst.conf` at startup and initializes all target state from
it. Reconstructing the full `TARGET_DRIVER qla2x00t {}` block from config.json
before SCST starts means SCST itself handles the initialization - no sysfs
apply sequence is needed at boot, no race condition between SCST initialization
and sysfs writes, and no brief window where a target port is enabled but LUNs
are not yet mapped. Runtime changes continue through sysfs for zero disruption
to active sessions.

**Boot sequence (normal boot):**

1. Kernel boots — udev detects QLogic PCI device, autoloads `qla2xxx_scst`
   using params from `/etc/modprobe.d/qla2xxx_scst.conf` (present from the
   previous `sync --system` run, persists on ZFS)
2. SCST starts — finds `qla2xxx_scst` already loaded with correct params,
   `qla2x00t` registers successfully, scst.conf initializes FC targets
3. POSTINIT runs `sync --boot` — writes boot marker, names ports, rewrites
   modprobe conf and scst.conf (idempotent — same content, housekeeping only)

No module reloading. No race condition. The conf file being present before
the kernel autoload is the key invariant.

**After a BE change (first boot only):**

The modprobe conf and scst.conf are in `/etc` which is part of the BE root
filesystem on ZFS. A new BE has neither file. On the first boot after a BE
change: the kernel autoloads `qla2xxx_scst` with default params (wrong),
SCST starts and registers `qla2x00t` (but with wrong params), POSTINIT
writes the correct conf files. The `status` command will show a param drift
gap. Run `sync --restart` or reboot to correct — both result in the module
loading with correct params. All subsequent boots are clean.

---

**Q: Do I need to run sync after every configuration change?**

No. All change commands (`port enable/disable`, `open`, `close`, `assign`,
`unassign`) write atomically to both config.json and live sysfs. `sync` is
only needed in specific situations:

- After a WUI iSCSI save wiped the scst.conf FC block: `sync`
- After an upgrade or BE change wiped the modprobe config: `sync --system`
- When SCST needs to re-read the updated scst.conf: `sync --restart`
- After an upgrade or BE change and SCST needs restarting: `sync --system --restart`

The POSTINIT boot entry never needs restoring - it lives in the TrueNAS
middleware database and survives all BE changes and upgrades.

Running `sync` at any other time is harmless - it rebuilds scst.conf from
config.json without touching sysfs or restarting anything.

---

**Q: Can I boot from an FC LUN?**

Yes. Configure via the QLogic Fast!UTIL option ROM (Ctrl+Q during POST):

1. Enable HBA BIOS on the port (this is the only required setting)
2. Add the target to the Selectable Boot list
3. Save and exit

The card will log into the target and present the LUN to the BIOS as a
bootable device on every subsequent boot without manual intervention.

---

**Q: What happens if I suspend a system that boots from an FC LUN?**

Deep sleep (S3/mem) is not compatible with FC root boot. Two solutions:

**Disable suspend entirely (recommended for servers):**
```bash
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

**Use s2idle (shallow sleep, PCIe stays powered):**
```bash
mkdir -p /etc/systemd/sleep.conf.d
echo s2idle > /etc/systemd/sleep.conf.d/mem.conf
```

---

**Q: What is dev_loss_tmo and why does it matter?**

`dev_loss_tmo` is the number of seconds the FC driver waits for a remote
port to reappear after a link event before declaring it permanently lost.
The default is 16 seconds. For a system booting from FC, if the link drops
briefly and does not recover within 16 seconds, the root device disappears
and the kernel panics. Set it to at least 60 seconds via udev rule.

---

**Q: Does the TrueNAS WUI restart SCST when I save iSCSI configuration?**

No. The WUI applies iSCSI configuration changes dynamically via the SCST
sysfs interface without restarting the service. Active iSCSI and FC sessions
are unaffected by WUI iSCSI saves. The `/etc/scst.conf` file is rewritten
but SCST does not re-read it until the next restart.

---

## config.json Reference

```json
{
  "enabled_ports": [
    "aa:bb:cc:dd:ee:ff:00:01"
  ],
  "open_extents": [
    "data_vol"
  ],
  "assignments": {
    "aa:bb:cc:dd:ee:ff:00:10": {
      "extents": ["backup_vol"],
      "luns": {"backup_vol": 0}
    }
  },
  "seen_initiators": {
    "aa:bb:cc:dd:ee:ff:00:10": "2026-05-05 10:28:48"
  },
  "isp_params": {
    "ISP2532": {
      "default": "qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0"
    },
    "ISP2432": {
      "default": "qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0"
    },
    "DEFAULT": {
      "default": "qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0"
    }
  },
  "isp_active_profile": {
    "ISP2532": "default"
  },
  "wwn_names": {
    "aa:bb:cc:dd:ee:ff:00:01": {"name": "nas0", "role": "target", "port": 0},
    "aa:bb:cc:dd:ee:ff:00:02": {"name": "nas0", "role": "target", "port": 1},
    "aa:bb:cc:dd:ee:ff:00:10": {"name": "workstation", "role": "initiator", "port": 0}
  },
  "firmware": {},
  "initscript_id": 4
}
```

| Key | Description |
|---|---|
| `enabled_ports` | WWNs of ports activated as FC targets |
| `open_extents` | Extents mapped to all initiators (default group) |
| `assignments` | Per-initiator extent mappings with LUN numbers |
| `seen_initiators` | History of connected initiator WWNs with last-seen timestamp. Captured automatically by `status` and `list-initiators`. |
| `isp_params` | Per-ISP named parameter profiles |
| `isp_active_profile` | Currently selected profile per ISP type |
| `wwn_names` | Friendly names, roles, and port indices for WWNs |
| `firmware` | Reserved for firmware metadata |
| `initscript_id` | TrueNAS middleware id of the registered POSTINIT boot entry. Used by `uninstall` to remove the entry without a comment search. |

---

## Known Limitations

- **ISP2432 target mode:** not achieved on kernel 6.12 - root cause unknown. Card produces AEN `0x8017 a964` with all firmware and parameter combinations tested. May be resolvable with further debugging. Works correctly as an initiator.
- **Primary flash version:** not readable via sysfs on this driver build. `fw show` reports it as "not exposed by driver".
- **Sysfs NVRAM writes:** writes to the `nvram` sysfs file update the driver shadow buffer only. Physical EEPROM is not written.
- **FC root + deep sleep:** incompatible. Use s2idle or disable suspend.
- **fw flash:** requires `qlflash` utility which is not included and not available via apt on TrueNAS. Set `FLASH_TOOL=` in the script header if using an alternative tool name.
- **TrueNAS WUI:** has no FC target management. All FC configuration is via `qle_adm.sh`.
- **WUI iSCSI saves wipe scst.conf:** run `sync` after any WUI iSCSI save to rebuild the FC target block. No SCST restart is needed.
