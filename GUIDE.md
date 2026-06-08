# Complete Guide

`qle_adm.sh`: QLogic FC Target Manager for TrueNAS SCALE CE

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
    ├── /etc/modprobe.d/                ← module params (restored by boot entry)
    └── TrueNAS middleware DB           ← boot entry (survives BE changes)
```

### Configuration model

`config.json` on `/mnt` is the single source of truth. Two representations
are derived from it:

**`/etc/scst.conf` FC target block** is rebuilt from config.json by `sync`.
SCST reads this file at startup to initialize all FC target state - enabled
ports, rel_tgt_ids, LUN mappings, and initiator groups. No sysfs writes are
performed at boot; SCST initializes everything from its own config file.

**Live sysfs** handles all runtime changes. Every change command
(`port enable/disable`, `open`, `close`, `group map`, `group unmap`) writes to
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

### ISP2432 target mode — confirmed working

ISP2432 (QLE2462, QLE2460) target mode is confirmed working on Linux kernel
6.12 with `qla2xxx_scst` using `qlini_mode=disabled`. The card comes up in
loop mode initially (`LOOP UP detected`) but completes P2P negotiation
correctly and presents as `Online P2P` with active sessions.

The default ISP2432 parameter profile is `qlini_mode=disabled ql2xfc2target=1
ql2xnvmeenable=0 ql2xfwloadbin=0`. Unlike the ISP2532, the ISP2432 does not
require `qlini_mode=dual` for direct P2P operation — `disabled` is sufficient.

Earlier investigation produced AEN `0x8017 a964` on kernel 6.12. This was a
driver removal loop caused by ISP2532 module params being applied to an ISP2432
card (wrong `qlini_mode=dual`). With correct params the card initializes
cleanly.

### Why ql2xfwloadbin=0 (HBA flash)

The default firmware source is the HBA primary flash slot (`ql2xfwloadbin=0`). This is the most stable source: firmware is burned to the card by the manufacturer or a deliberate flash operation. No file needs to be present and boot is fast. Use `fw use <version>` to switch to a stored filesystem version when needed.

---

## Installation

### Prerequisites

Before installing, confirm on TrueNAS:

0. **A supported QLogic Fibre Channel HBA** — any card supported by the
   `qla2xxx` kernel driver should work. The kernel documentation states that
   `qla2xxx` supports all QLogic FC PCI and PCIe host adaptors with firmware
   support for ISP21xx, ISP22xx, ISP23xx, ISP24xx, ISP25xx, and newer chip
   generations. ISP2432 and ISP2532 are confirmed working in target mode on
   kernel 6.12 with `qla2xxx_scst` 10.02.09.400-k.

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

# Run install - registers boot entry and writes /etc artefacts
${QLE_ADM_HOME}/qle_adm.sh --yes deploy install --mode grub

# Add to your shell startup script (~/.bashrc or ~/.zshrc) so qle_adm.sh
# is available by name from any directory on this and future sessions.
# The install command prints these lines for you to copy.
export QLE_ADM_HOME=/mnt/${POOL}/admin/qle_adm
PATH="${PATH}:${QLE_ADM_HOME}"

# Optional: disable color or unicode symbols if your terminal doesn't support them
# export QLE_ADM_USE_COLOR=0
# export QLE_ADM_USE_UNICODE=0

# Inject FC target block into scst.conf
${QLE_ADM_HOME}/qle_adm.sh sync

# If qla2xxx_scst is not yet loaded for this session, load it now.
# On subsequent boots the boot entry handles the module lifecycle automatically.
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
| `/etc/modprobe.d/qla2xxx_scst.conf` | Module params (reload/blacklist modes) | ✗ restored by boot entry |
| `/etc/systemd/system/scst.service.d/qle-adm-ordering.conf` | SCST starts after boot entry | ✗ restored by boot entry |
| TrueNAS middleware boot entry | Boot-time module management and scst.conf write | ✓ survives all BE changes |

The boot entry is visible and manageable under
System > Advanced > Init/Shutdown Scripts in the WUI. It is the only
boot component that does not need restoring after a BE change or upgrade;
it lives in the TrueNAS middleware database.

### Boot modes

`qle_adm.sh` supports three boot modes, selected at `deploy install` time
or changed later with `deploy reconfigure`. The active mode is stored in
`config.json`. **`grub` is the default for new installs.**

| Mode | How params are applied | Module reload at boot | Firmware sources |
|------|------------------------|----------------------|-----------------|
| `grub` | Params as `qla2xxx_scst.<k>=<v>` tokens in `kernel_extra_options` via TrueNAS middleware | No | HBA flash or OS dist |
| `blacklist` | Module blacklisted at boot; boot entry performs the first clean load with `modprobe -i` | No | HBA, OS dist, user-stored |
| `reload` | Boot entry unloads and reloads module with correct params | Yes | HBA, OS dist, user-stored |

Switch modes at any time:

```bash
qle_adm.sh deploy reconfigure --mode grub
qle_adm.sh deploy status
```

### After an upgrade or boot environment change

```bash
${QLE_ADM_HOME}/qle_adm.sh sync --restart
${QLE_ADM_HOME}/qle_adm.sh status
```

`sync --restart` rebuilds scst.conf from config.json and restarts SCST.
The boot entry survives all BE changes; no reinstall is needed. On the
first boot after a BE change the boot entry restores all `/etc` artefacts
before SCST starts and the boot is fully automatic from the second boot on.

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
| `--verbose` / `-v` | Extra diagnostic output; for `list-extents` adds a device detail block (dev_file, thin, compression, ro, bs, vbs, naa, prod_id) |
| `--home <path>` | Override QLE_ADM_HOME for this invocation |
| `--port N` | Select FC port by index from `list-ports` |
| `--group <name>` | Select initiator by index from `list-initiators` |
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

### Status

| Command | Short | Description |
|---|---|---|
| `status` | `st` | Full state with module, service, scst.conf, port, session, and gap analysis. Passively captures seen_initiators from active sessions. |
| `stats [--watch] [--wide]` | `sw` / `si` | IO counters and link error stats. `--watch` refreshes every 2s; `--wide` shows per-initiator detail. |
| `list-hba` | `lh` | Per-port detail: ISP type, firmware versions, PCIe link, WWN |
| `list-ports` | `lp` | FC ports with index, state, topology, managed status |
| `list-initiators` | `li` | Connected initiators with IO stats; previously seen initiators always shown |
| `list-extents` | `le` | SCST extents. Column order: `[idx] name  size  s/n  groups:[...]  sysfs:[...]`. `groups:[...]` is a unified config state field — brackets contain `OPEN` and/or group names, both reported if true: `groups:[UNMAPPED]` not in any group or open access; `groups:[OPEN]` world-accessible; `groups:[g1ed2]` in one group; `groups:[OPEN,g1ed2]` open and in a group; `groups:[g1ed2,vostro]` in multiple groups. `sysfs:[...]` is the live SCST kernel state and is progressive — each state adds to the previous tokens: `sysfs:[no sysfs]` config exists but not yet applied — run `sync --apply`; `sysfs:[mapped]` LUN in sysfs, no initiator session; `sysfs:[mapped,connected]` session present, zero lifetime I/O; `sysfs:[mapped,connected,io]` session present with lifetime I/O recorded (session-level counter — SCST exposes no per-LUN lifetime stats; all LUNs in the same group reflect the same session). The two columns are sourced independently; `groups:[UNMAPPED] sysfs:[mapped]` means a LUN mapping exists in sysfs that config.json has no record of — run `sync` to reconcile. With `--verbose` / `-v`, two additional lines are printed per extent: `dev_file:` `thin:` `compression:` `ro:` `bs:` `vbs:` on the first line, and `naa:` `prod_id:` on the second. `thin` and `ro` are decoded as `Y`/`N`; `ro:Y` and `thin:N` are highlighted in yellow. |
| `list-mapping` | `lm` | Full LUN mapping topology: groups, initiators, LUN mappings, port associations, and a port-centric summary. `list-groups` / `lg` retained as aliases. |
| `list-all` | `la` | All list commands in sequence |

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

# Per-group: specific initiator group only
./qle_adm.sh group map   esxi_side_a --ext 0
./qle_adm.sh group unmap esxi_side_a --ext 0
```

All mapping commands write to both sysfs (immediate) and config.json
(persistent). No separate save step is required.

### Deferred LUN number changes

LUN numbers can be changed without disrupting live sessions by staging
the change into `pending_luns` in `config.json`. The change is only
applied when `sync --restart` or `sync --apply` is run, or on next reboot.
Multiple changes can be staged and are validated as a unit at apply time.

```
lun set <extent> <wwn> <new-lun>
    Stage a LUN number change for an extent/initiator pair. Does not
    touch live sysfs. Setting the current live LUN number cancels any
    pending change for that extent. Each call prints the current pending
    state and a READY / NOT READY indicator.

lun clear-pending <wwn>
    Clear all pending LUN changes for a specific initiator.

lun clear-pending --all
    Clear all pending LUN changes across all initiators.

lun status [<wwn>]
    Show pending changes and the merged desired LUN map with conflict
    detection. Reports READY (no conflicts) or NOT READY with details.
```

Conflict detection runs at apply time (`sync --restart` or `sync --apply`).
If the merged map contains duplicate LUN numbers, the entire pending set
is rejected and nothing is written. Resolve with further `lun set` calls
then re-run `sync --restart`.

Example - swap LUN 0 and LUN 1 for an initiator without session disruption
until the restart:

```bash
qle_adm.sh lun set g1ed2-debian  51:40:2e:c0:01:7c:6f:1c 1
qle_adm.sh lun set g1ed2-truenas 51:40:2e:c0:01:7c:6f:1c 0
qle_adm.sh lun status
qle_adm.sh sync --restart
```

### WWN naming

```bash
./qle_adm.sh name list
./qle_adm.sh name set <wwn> <name> [--port N]
./qle_adm.sh name get <wwn>
./qle_adm.sh name del <wwn>
```

### Operation

| Command | Description |
|---|---|
| `sync [--apply] [--restart] [--boot]` | Rebuild scst.conf from config.json. `--apply` rebuilds scst.conf then applies to live SCST non-disruptively. `--restart` rebuilds scst.conf then restarts scst.service (all sessions dropped). `--boot` writes `/etc` artefacts, rebuilds scst.conf, and manages the module per boot_mode; used by the boot entry, never prompts. Without any flag, scst.conf only; always safe. |
| `reset <target>` | Reset accumulated state (see below) |
| `lun <set\|clear-pending\|status>` | Stage deferred LUN number changes (see below) |
| `module <load\|unload\|reload\|status>` | Manage the qla2xxx_scst kernel module independently of SCST and config files (see below). |
| `teardown` | Deactivate targets, revert to plain initiator mode |

**reset targets:**
```
reset seen       : wipe seen_initiators history
reset ports      : disable all ports and clear enabled_ports
reset mappings   : remove all open/group-mapped LUNs from sysfs and config
reset names      : wipe all WWN names
reset all        : all of the above (prompts unless --yes)
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
| `setup [--preinit]` | `sync [--boot]` |
| `apply` | Not needed - all changes write atomically to config.json + sysfs |
| `save` | Not needed - seen_initiators captured automatically by `status` and `list-initiators` |
| `repair` | `sync` |

### ISP parameter profiles

```bash
./qle_adm.sh isp-params list
./qle_adm.sh isp-params set ISP2532 --profile optrom \
  "qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=1"
./qle_adm.sh isp-params use ISP2532 --profile optrom
./qle_adm.sh isp-params del ISP2532 --profile optrom
```

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

### Deployment

| Command | Description |
|---|---|
| `deploy install [--mode M]` | Register boot entry, write /etc artefacts, copy script to QLE_ADM_HOME. Modes: grub (default), blacklist, reload |
| `deploy uninstall` | Remove all installed components and kernel cmdline tokens, preserve config.json |
| `deploy reconfigure [--mode M]` | Switch boot mode; tears down old artefacts, installs new. Writes `hba_identity` on completion. |
| `deploy status` | Show active mode, artefact state, last boot mode, and gap analysis |
| `deploy migrate [--apply]` | Migrate config.json to current schema. Defaults to dry-run; use `--apply` to write. Backs up config first. |
| `deploy migrate [--apply]` | Migrate config.json to the current schema. Defaults to dry-run preview; use `--apply` to write. Backs up config before writing (`config.json.bak`, `.bak.1`, `.bak.2` ...). |

### Config Schema Migration

When a new version of `qle_adm.sh` introduces a breaking schema change,
`config.json` must be migrated before the script will operate. The script
detects the mismatch at startup and refuses to run, printing instructions.

#### Eligibility

Not all schema versions can be migrated automatically. The script maintains
an internal `MIGRATION_TABLE` that records which version-to-version paths are
eligible. If a path is marked ineligible (or absent), the script will tell you
and provide manual steps instead.

Multi-hop migrations (e.g. schema 1 → 2 → 3) are run as sequential steps,
each confirmed before the next.

#### Running a migration

Always preview first (dry-run is the default):

```bash
# Preview what will change - no files are written
qle_adm.sh deploy migrate

# Apply the migration (backs up config.json first)
qle_adm.sh deploy migrate --apply
```

A backup is written automatically before any changes are made. If
`config.json.bak` already exists, the backup is numbered sequentially
(`config.json.bak.1`, `.bak.2`, etc.).

#### Schema 1 → 2 (v5.x → v7.0)

This migration converts the old per-initiator assignment scheme to the
group-based schema introduced in v7.0.

**What changes automatically:**

- Each old assignment entry (keyed by initiator WWN) becomes a named group
- The WWN becomes the sole member of the group's `initiators` list
- `extents`, `luns`, and any `pending_luns` are preserved unchanged
- `config_schema: 2` is added; `pending_luns_version` is removed

**What requires manual follow-up:**

Group names are derived from initiator WWNs during migration
(e.g. `20:00:00:25:b5:c0:a0:1f`). After migration the script prints a list
of rename commands. Use them to assign meaningful names:

```bash
qle_adm.sh group rename 20:00:00:25:b5:c0:a0:1f esxi_side_a
qle_adm.sh group rename 20:00:00:25:b5:c0:b0:7f esxi_side_b
```

If you have initiators that share access to the same extents, you can
consolidate them into a single group after migration:

```bash
# Create a new named group and add both initiators
qle_adm.sh group create esxi_side_a
qle_adm.sh group add esxi_side_a 20:00:00:25:b5:c0:a0:1f
qle_adm.sh group add esxi_side_a 20:00:00:25:b5:c0:a0:7f

# Assign extents to the group
qle_adm.sh group map esxi_side_a <extent>

# Delete the old single-initiator groups
qle_adm.sh group delete 20:00:00:25:b5:c0:a0:1f
qle_adm.sh group delete 20:00:00:25:b5:c0:a0:7f

# Sync to update scst.conf
qle_adm.sh sync
```


#### Schema 2 → 3 (v6.x → v7.0)

This migration introduces `groups` and `port_groups`, replacing the `assignments` key.

**What changes automatically:**

- Each entry in `assignments` becomes a named entry in `groups` (initiators, luns, and pending_luns preserved)
- `port_groups` is built by attaching all groups to all currently enabled ports (preserving the "every group on every port" default)
- `assignments` key is removed
- `config_schema: 3` and `version: 7.0` are set

**What requires manual follow-up:**

After migration, all groups are attached to all ports. For dual-fabric or asymmetric topologies, refine the port associations:

```bash
# Review what was created
qle_adm.sh list-mapping

# Detach groups from ports where they should not be active
qle_adm.sh port detach 21:00:...:d6 esxi_side_a
qle_adm.sh port detach 21:00:...:d7 esxi_side_a

# Attach the correct side-B groups to those ports
qle_adm.sh port attach 21:00:...:d6 esxi_side_b
qle_adm.sh port attach 21:00:...:d7 esxi_side_b

# Sync to update scst.conf
qle_adm.sh sync
```

#### If automatic migration is not possible

If the script reports that migration is ineligible, the configuration must
be rebuilt manually:

```bash
# Back up the existing config
cp "${QLE_ADM_HOME}/config.json" "${QLE_ADM_HOME}/config.json.bak"

# Remove the old config and re-initialise
rm "${QLE_ADM_HOME}/config.json"
qle_adm.sh deploy install

# Re-add your configuration
qle_adm.sh port enable <wwn>
qle_adm.sh group create <name>
qle_adm.sh group add <name> <wwn>
qle_adm.sh group map <name> <extent>
qle_adm.sh sync
```

### HBA swap

```bash
qle_adm.sh hba swap           # auto-migrate port config to new card (same ISP, new count >= old)
qle_adm.sh hba swap --force   # cross-ISP or port count reduction: clears enabled_ports,
                   # preserves groups/extents/initiator names
```

`hba swap` compares `hba_identity` (registered by `deploy reconfigure`) against
the currently installed card. For same-ISP swaps where the new card has at least
as many ports, it remaps `enabled_ports` and target `wwn_names` to the new
WWNs by port index and applies the change live if SCST is running. Use
`--force` for cross-ISP or port reduction swaps — this clears the FC port
config and requires `port enable` to re-activate targets.

The PREINIT boot entry performs the same auto-migration automatically at boot,
so a system that is rebooted after a card swap will self-heal without manual
intervention for same-ISP same-or-larger swaps. `status` displays a one-time
summary of any boot-time migration.

---

### Log management

Boot sessions are delimited in the log by `=== Boot sync started ===` marker lines written at the start of each boot run. Session-aware commands (`boot`, `last`, `trim`) use this marker to identify session boundaries.

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
| TrueNAS middleware boot entry | ✓ | ✓ | ✓ | N/A |
| `/etc/modprobe.d/` | ✓ | ✗ | ✗ | `sync --boot` |
| `/etc/scst.conf` FC block | ✓ | ✗ | ✗ | `sync` |
| SCST sysfs state | ✗ | ✗ | ✗ | automatic via scst.conf on boot |
| Active FC sessions | ✗ | ✗ | ✗ | automatic on reconnect |

After any BE change or upgrade:
```bash
./qle_adm.sh sync --restart
./qle_adm.sh status
```

---

## Firmware Management

### ql2xfwloadbin decoded

| Value | Source |
|---|---|
| `0` | HBA primary flash slot (default) |
| `1` | Optrom slot (secondary flash) |
| `2` | Filesystem - `/usr/lib/firmware/<fw_file>` |

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

# Switch to a stored version (takes effect on next boot or reboot)
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
One profile is marked active (`*`) and used by the boot entry (sync --boot). Multiple
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

**Configured:** the active profile that will be loaded on next `sync --boot` or reboot.
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
| `port_state: Linkdown` on both sides | Wrong `qlini_mode` | ISP2532 target requires `qlini_mode=dual`; ISP2432 target requires `qlini_mode=disabled` |
| `LOOP UP detected` instead of `Online P2P` | Loop topology negotiated | Both sides must use P2P capable firmware |
| AEN `8017 d17f` flood | No optical signal | Check SFP seating, cable, correct port |
| `port_type: Unknown` after enable | SCST not running or `qla2x00tgt` not registered | Check `systemctl status scst`, run `sync --restart` |
| Both sides `Linkdown` after module reload | Firmware version mismatch | Check `fw show` |

### AEN error code reference

| Code | Meaning |
|---|---|
| `8017 d17f` | No optical signal (SFP or cable issue) |
| `8017 4034` | Loop arbitration timeout (topology mismatch) |
| `8017 a964` | Target mode firmware init failure — typically caused by wrong `qlini_mode` for the ISP type (e.g. `qlini_mode=dual` applied to ISP2432) |
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

> **WARNING:** At least one iSCSI target must be defined in the TrueNAS iSCSI
> WUI (Sharing → iSCSI → Targets) for `/etc/scst.conf` to be created. The
> target name does not matter; its mere existence triggers the file. Without
> any iSCSI target defined, SCST starts but does not write `scst.conf`, and
> `qle_adm.sh sync` will fail with "scst.conf not found".

```bash
systemctl is-active scst
systemctl start scst
# Once scst.conf exists, sync can write the FC target block:
./qle_adm.sh sync
```

### Targets not active after upgrade or BE change

The boot entry survives the upgrade and will have run automatically.
If targets are still not active, the modprobe config or scst.conf block may
need restoring:

```bash
./qle_adm.sh sync --restart
./qle_adm.sh status
```

### Block device not appearing on initiator

```bash
# Confirm session is established on target
./qle_adm.sh list-initiators

# Confirm LUN is mapped
./qle_adm.sh list-mapping

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

Yes. ISP2432 target mode is confirmed working on kernel 6.12 with
`qla2xxx_scst` using `qlini_mode=disabled`. The card initializes in loop mode
initially but completes P2P negotiation and comes up `Online P2P` with active
sessions. Use `qlini_mode=disabled` (not `dual` — that is for ISP2532 only).

`qle_adm.sh` sets the correct default params per ISP type automatically.
Run `qle_adm.sh isp-params list` to confirm ISP2432 is detected and using the
`qlini_mode=disabled` profile.

---

**Q: Why does the TrueNAS WUI overwrite my scst.conf?**

The WUI manages iSCSI configuration through its own internal database. When
you make any iSCSI change and save, the WUI regenerates `/etc/scst.conf`
from that database, replacing the file entirely. Run `sync` after a WUI
iSCSI save to rebuild the FC target block from config.json. The WUI does not
restart SCST on iSCSI saves, so active sessions are unaffected.

---

**Q: Why does `sync` fail with "scst.conf not found" even though SCST is running?**

`/etc/scst.conf` is created by TrueNAS when it saves iSCSI configuration. If
no iSCSI targets have ever been defined in the WUI (Sharing → iSCSI → Targets),
TrueNAS never writes the file. At least one iSCSI target must exist for
`scst.conf` to be created - the target name and configuration do not matter,
its existence is the trigger. Create a placeholder iSCSI target in the WUI,
save, and `scst.conf` will appear. Then run `sync` to add the FC target block.

---

**Q: Why does qle_adm use qlini_mode=dual instead of disabled?**

`qlini_mode=disabled` causes the ISP2532 to not assert a valid FC signal on
a direct P2P connection. `qlini_mode=dual` keeps the initiator stack active
alongside the target stack, which causes the ISP2532 to properly assert the
port signal and complete P2P negotiation on a direct cable. This is required
for direct (switchless) ISP2532 target operation.

---

**Q: What is the default firmware source and when should I change it?**

The default is `hba` (`ql2xfwloadbin=0`): firmware loads from the HBA
primary flash slot. This is the most stable and conservative choice. Use
`fw show` to compare running, optrom, and any stored versions. To use a
different firmware version: run `fw save-os` to capture the OS dist
firmware and `fw save-hba` to capture the optrom firmware into the versioned
store, then `fw use <version>` to select one. Takes effect on next boot or
`sync --boot`.

---

**Q: Why does qle_adm reconstruct scst.conf at boot instead of applying via sysfs?**

SCST reads `/etc/scst.conf` at startup and initializes all target state from
it. Reconstructing the full `TARGET_DRIVER qla2x00t {}` block from config.json
before SCST starts means SCST itself handles the initialization - no sysfs
apply sequence is needed at boot, no race condition between SCST initialization
and sysfs writes, and no brief window where a target port is enabled but LUNs
are not yet mapped. Runtime changes continue through sysfs for zero disruption
to active sessions.

**Boot sequence (normal boot, grub mode - default):**

1. Kernel boots: `qla2xxx_scst` autoloads from initramfs at ~3s with
   params delivered via `kernel_extra_options` cmdline tokens. No reload needed.
2. systemd starts, `/etc` ZFS dataset mounts (~18s)
3. **Boot entry** runs `sync --boot` - writes scst.conf and SCST ordering
   drop-in to `/etc`. No module management (params already applied via cmdline).
   SCST is guaranteed not running at this point because the drop-in adds
   `After=ix-preinit.service` to `scst.service`.
4. SCST starts - finds `qla2xxx_scst` loaded with correct params, `qla2x00t`
   registers successfully, reads scst.conf and initializes FC targets.

**Boot sequence (blacklist mode):**

1. Kernel boots: `module_blacklist=qla2xxx_scst` in cmdline prevents autoload.
2. systemd starts, `/etc` ZFS dataset mounts.
3. **Boot entry** runs `sync --boot` - writes modprobe conf, scst.conf, and
   SCST ordering drop-in to `/etc`. Loads `qla2xxx_scst` with `modprobe -i`
   (ignore-blacklist) and correct params for the first and only time.
4. SCST starts - finds module loaded, `qla2x00t` registers, reads scst.conf.

**Boot sequence (reload mode):**

1. Kernel boots: `qla2xxx_scst` autoloads from initramfs at ~3s with default
   compiled-in params. `/etc` is not yet mounted at this point.
2. systemd starts, `/etc` ZFS dataset mounts (~18s).
3. **Boot entry** runs `sync --boot` - writes modprobe conf, scst.conf, and
   SCST ordering drop-in to `/etc`, then unloads and reloads `qla2xxx_scst`
   with correct params. SCST is guaranteed not running at this point.
4. SCST starts - finds `qla2xxx_scst` loaded with correct params, `qla2x00t`
   registers successfully, reads scst.conf and initializes FC targets.

**After a BE change:** The modprobe conf, scst.conf, and the SCST ordering
drop-in are all in `/etc` which is BE-specific. On the first boot after a
BE change all three are absent. SCST and the boot entry race; SCST may win
and fail. Run `sync --restart` to recover. The boot entry then restores all
three files for all subsequent boots.

---

**Q: Do I need to run sync after every configuration change?**

No. All change commands (`port enable/disable`, `open`, `close`, `group map`,
`group unmap`) write atomically to both config.json and live sysfs. `sync` is
only needed in specific situations:

- After a WUI iSCSI save wiped the scst.conf FC block: `sync`
- After an upgrade or BE change wiped the modprobe config: `sync --boot`
- When SCST needs to re-read the updated scst.conf: `sync --restart`
- After an upgrade or BE change and SCST needs restarting: `sync --restart`

The boot entry never needs restoring - it lives in the TrueNAS
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
  "config_schema": 3,
  "enabled_ports": [
    "aa:bb:cc:dd:ee:ff:00:01"
  ],
  "open_extents": [
    "data_vol"
  ],
  "groups": {
    "workstation": {
      "initiators": ["aa:bb:cc:dd:ee:ff:00:10"],
      "luns": {"backup_vol": 0},
      "pending_luns": {}
    }
  },
  "port_groups": {
    "aa:bb:cc:dd:ee:ff:00:01": ["workstation"]
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
  "initscript_preinit_id": 3,
  "boot_mode": "grub",
  "rootwait_was_preexisting": false,
  "hba_identity": {
    "isp_type": "ISP2432",
    "port_count": 2,
    "port_wwns": ["aa:bb:cc:dd:ee:ff:00:01", "aa:bb:cc:dd:ee:ff:00:02"],
    "model": "QLE2462",
    "registered_at": "2026-05-14T23:08:15"
  },
  "hba_swap_event": null
}
```

| Key | Description |
|---|---|
| `config_schema` | Schema version; current is `3`. Controls migration eligibility. |
| `enabled_ports` | WWNs of ports activated as FC targets |
| `open_extents` | Extents mapped to all initiators (SCST default luns group) |
| `groups` | Named initiator groups. Each entry has `initiators` (WWN list), `luns` (extent→LUN-number map), and `pending_luns` (staged deferred changes). |
| `port_groups` | Per-port group associations. Maps target port WWN → list of group names attached to that port. |
| `seen_initiators` | History of connected initiator WWNs with last-seen timestamp. Captured automatically by `status` and `list-initiators`. |
| `isp_params` | Per-ISP named parameter profiles |
| `isp_active_profile` | Currently selected profile per ISP type |
| `wwn_names` | Friendly names, roles, and port indices for WWNs |
| `firmware` | Reserved for firmware metadata |
| `initscript_preinit_id` | TrueNAS middleware id of the registered boot entry. Used by `deploy uninstall` to remove the entry without a comment search. |
| `boot_mode` | Active boot mode: `grub` (default), `blacklist`, or `reload` |
| `rootwait_was_preexisting` | Whether `rootwait` was in `kernel_extra_options` before qle_adm added it. Controls whether `rootwait` is removed on uninstall. |
| `hba_identity` | Installed HBA fingerprint: ISP type, port count, WWNs in PCI function order, model, and registration timestamp. Written by `deploy reconfigure` and `hba swap`. Used by PREINIT swap detection to identify card changes at boot. |
| `hba_swap_event` | Written when PREINIT auto-migrates a card swap or writes a bare FC block. Displayed once by `status` then cleared to `null`. `null` when no swap was detected at last boot. |

---

## Known Limitations

- **Primary flash version:** not readable via sysfs on this driver build. `fw show` reports it as "not exposed by driver".
- **Sysfs NVRAM writes:** writes to the `nvram` sysfs file update the driver shadow buffer only. Physical EEPROM is not written.
- **FC root + deep sleep:** incompatible. Use s2idle or disable suspend.
- **fw flash:** requires `qlflash` utility which is not included and not available via apt on TrueNAS. Set `FLASH_TOOL=` in the script header if using an alternative tool name.
- **TrueNAS WUI:** has no FC target management. All FC configuration is via `qle_adm.sh`.
- **WUI iSCSI saves wipe scst.conf:** run `sync` after any WUI iSCSI save to rebuild the FC target block. No SCST restart is needed.
- **hba swap cross-ISP or port reduction:** requires `hba swap --force` which clears `enabled_ports`. FC targets must be re-enabled manually with `port enable` after force-swapping.
