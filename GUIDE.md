# Complete Guide

`qle_adm.sh` v1.9: QLogic FC Target Manager for TrueNAS SCALE CE

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
├── SCST (scst.ko)                    ← SCSI target framework
│   ├── scst_vdisk.ko                 ← block device handler
│   └── qla2xxx_scst.ko               ← FC target driver
│       └── qla2x00tgt                ← FC target template in SCST
│
└── qle_adm.sh
    ├── config.json  (/mnt/<pool>/)   ← persistent source of truth
    ├── /etc/modprobe.d/              ← module params (regenerated)
    └── /etc/systemd/system/          ← boot service (regenerated)
```

### Why sysfs-only (no scst.conf management)

The TrueNAS WUI regenerates `/etc/scst.conf` from its internal database on
every iSCSI configuration change. Any manual edits are silently overwritten.
`qle_adm.sh` does not rely on `scst.conf` for FC configuration; all target
activation, LUN mapping, and initiator group management is applied directly
to the live SCST sysfs interface at `/sys/kernel/scst_tgt/`.

The one exception: the `TARGET_DRIVER qla2x00t {}` block must exist in
`scst.conf` for SCST to load the FC target template at startup. `qle_adm.sh`
injects this block automatically as part of `setup --boot`, which runs before
SCST starts. Since the WUI does not restart SCST on iSCSI saves (it uses
sysfs for live changes), the block remains effective until the next reboot,
at which point `setup --boot` reinjects it again.

### Why config.json as single source of truth

`config.json` lives on `/mnt/<pool>/` and survives all TrueNAS lifecycle
events: reboots, boot environment changes, and upgrades. All other managed
files (`/etc/modprobe.d/qla2xxx_scst.conf`, systemd units) are regenerated
from it by `repair`. The script itself also lives on `/mnt/<pool>/` for the
same reason.

### Why ISP2432 is not supported as a target

The `qla2xxx_scst` driver's target mode initialization sequence is
incompatible with ISP2432 (QLE2462, QLE2460) on Linux kernel 6.12. The card
produces AEN `0x8017 a964` continuously and `fw_state` returns all-F values.
Firmware is completely unresponsive in target mode. This occurs with all
firmware versions tested and is a driver/kernel compatibility issue, not a
hardware fault. ISP2432 works correctly as a plain initiator using `qla2xxx`.
ISP2532 (QLE2562, HP AJ764A) and newer work correctly in target mode.

### Why qlini_mode=dual instead of disabled

`qlini_mode=disabled` prevents the ISP2532 from asserting a valid FC signal
on a direct P2P connection. The card's port stays in an unknown topology
state and never transmits FLOGI. Setting `qlini_mode=dual` keeps the
initiator stack active alongside the target stack, which causes the ISP2532
to properly assert the port signal and complete P2P negotiation. This was
discovered through extensive testing; it is a required parameter for direct
cable (no switch) ISP2532 target operation.

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
# Set your pool name
POOL=tank

# Create the qle_adm home directory
mkdir -p /mnt/${POOL}/admin/qle_adm

# Copy the script (from wherever you extracted the archive)
cp qle_adm.sh /mnt/${POOL}/admin/qle_adm/
chmod +x /mnt/${POOL}/admin/qle_adm/qle_adm.sh

# Run install (sets up all system files)
QLE_ADM_HOME=/mnt/${POOL}/admin/qle_adm \
  /mnt/${POOL}/admin/qle_adm/qle_adm.sh --yes install

# Verify
/mnt/${POOL}/admin/qle_adm/qle_adm.sh status
```

### What install creates

| File | Purpose | Survives BE? |
|---|---|---|
| `/mnt/<pool>/admin/qle_adm/qle_adm.sh` | Main script | ✓ |
| `/mnt/<pool>/admin/qle_adm/config.json` | Persistent config | ✓ |
| `/mnt/<pool>/admin/qle_adm/firmware/` | Firmware store | ✓ |
| `/etc/modprobe.d/qla2xxx_scst.conf` | Module params | ✗ |
| `/etc/systemd/system/qle_adm-boot.service` | Boot service | ✗ |

Files in `/etc` are regenerated by `repair` after any BE change or upgrade.

### After an upgrade or boot environment change

```bash
/mnt/<pool>/admin/qle_adm/qle_adm.sh repair
/mnt/<pool>/admin/qle_adm/qle_adm.sh setup
/mnt/<pool>/admin/qle_adm/qle_adm.sh status
```

`repair` restores `/etc` files from the persistent config on `/mnt`.
`setup` reloads the module and reactivates all configured targets.

---

## Command Reference

All commands are run as `./qle_adm.sh <command>` from the install directory,
or by full path `/mnt/<pool>/admin/qle_adm/qle_adm.sh <command>`.

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

### Deployment

| Command | Description |
|---|---|
| `install` | Deploy modprobe config, boot service, copy script to QLE_ADM_HOME |
| `uninstall` | Remove all installed components, preserve config.json |
| `repair` | Restore `/etc` files after upgrade or BE change |

### Operation

| Command | Description |
|---|---|
| `setup [--boot]` | Load module, inject scst.conf block, activate targets |
| `teardown` | Deactivate targets, revert to plain initiator mode |
| `apply` | Push config.json to live SCST sysfs without restart |
| `save` | Record currently connected initiators to config.json |
| `clear <target>` | Clear accumulated state (see below) |

**clear targets:**
```
clear seen       : wipe seen_initiators history
clear ports      : disable all ports and clear enabled_ports
clear mappings   : remove all open/assigned LUNs from sysfs and config
clear names      : wipe all WWN names
clear all        : all of the above (prompts unless --yes)
```

### Status

| Command | Description |
|---|---|
| `status` | Full state with module, service, port, session, and gap analysis |
| `hba-info` | Per-port detail: ISP type, firmware versions, PCIe link, WWN |
| `stats [--watch] [--wide]` | IO counters and link error stats |
| `list-ports` | FC ports with index, state, topology, managed status |
| `list-extents` | SCST extents with size, open/assigned state |
| `list-initiators [--seen]` | Connected initiators; `--seen` adds history |
| `list-assignments` | Per-initiator LUN mappings |
| `list-all` | All four list commands in sequence |

### Port management

```bash
./qle_adm.sh port enable  --port 0         # by index
./qle_adm.sh port enable  <wwn>            # by WWN
./qle_adm.sh port disable --port 0
```

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

### Firmware

```bash
./qle_adm.sh fw list                           # list stored firmware files
./qle_adm.sh fw add ISP2532 <file>             # add to store
./qle_adm.sh fw remove ISP2532                 # remove from store
./qle_adm.sh fw save [--port N]                # read optrom → store
./qle_adm.sh fw show [--port N]                # show card firmware versions
./qle_adm.sh fw status                         # all ports summary
./qle_adm.sh fw flash --slot <primary|optrom>  # flash card (requires qlflash)
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
| `/etc/modprobe.d/` | ✓ | ✗ | ✗ | `repair` |
| `/etc/systemd/system/` | ✓ | ✗ | ✗ | `repair` |
| SCST sysfs state | ✗ | ✗ | ✗ | `setup` |
| Active FC sessions | ✗ | ✗ | ✗ | automatic on reconnect |

After any BE change or upgrade:
```bash
./qle_adm.sh repair   # restore /etc files
./qle_adm.sh setup    # reload module, reactivate targets
./qle_adm.sh status   # verify
```

---

## Firmware Management

### ql2xfwloadbin decoded

| Value | Source |
|---|---|
| `0` | Primary flash slot (default) |
| `1` | Optrom slot (secondary flash, not filesystem) |
| `2` | Filesystem via `request_firmware()` |

The ISP2532 has two flash slots. The primary slot contains the factory
firmware. The optrom slot contains a separate firmware image that can be
newer or older. `ql2xfwloadbin=1` loads from optrom, which is the
recommended setting when the optrom contains a newer version than primary.

### Saving optrom firmware

```bash
./qle_adm.sh fw save
./qle_adm.sh fw list   # confirm version
```

This reads the optrom via the sysfs `optrom_ctl` enable/read/release
sequence and stores the binary in `firmware/ISP2532/ql2500_fw.bin`.
Once stored, `setup` can load it via `ql2xfwloadbin=2` as a filesystem
overlay, making the card independent of its optrom slot contents.

### Firmware version visibility

The driver only exposes the optrom slot version via sysfs
(`optrom_fw_version`). The primary flash version is not readable via sysfs
on this driver build; `fw show` reports it as "not exposed by driver".

---

## ISP Parameter Profiles

Each ISP type has a set of named parameter profiles stored in `config.json`.
One profile is marked active (`*`) and used by `setup`. Multiple profiles
allow switching between configurations without editing the config file.

```bash
# View all profiles and current state
./qle_adm.sh isp-params list

# Output shows:
#   ISP2532 (detected):
#     default *: qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=1
#     ──
#     Configured : default
#     Applied    : default
```

**Configured:** the active profile that will be loaded on next `setup`.
**Applied:** the params actually running in the kernel right now.
**⚠ drift:** applied and configured differ; run `setup` to resync.

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

Port index for local HBA ports is derived from the PCI function number
(`.0` → port 0, `.1` → port 1), reliable and automatic. For remote
initiator ports, the index is assigned sequentially as names are added.

---

## Troubleshooting

### Link won't come up: checklist

```bash
./qle_adm.sh status          # check for gaps
./qle_adm.sh hba-info        # check port state, firmware version
./qle_adm.sh isp-params list # check applied vs configured
dmesg | grep qla2xxx | tail -20
```

Common causes and fixes:

| Symptom | Cause | Fix |
|---|---|---|
| `port_state: Linkdown` on both sides | Wrong `qlini_mode` | Ensure `qlini_mode=dual` for ISP2532 target |
| `LOOP UP detected` instead of `Online P2P` | Loop topology negotiated | Both sides must use P2P capable firmware |
| AEN `8017 d17f` flood | No optical signal | Check SFP seating, cable, correct port |
| `port_type: Unknown` after enable | SCST not running or `qla2x00tgt` not registered | Check `systemctl status scst`, run `setup` |
| Both sides `Linkdown` after module reload | Firmware version mismatch | Check `fw show`, use `ql2xfwloadbin=1` |

### AEN error code reference

| Code | Meaning |
|---|---|
| `8017 d17f` | No optical signal (SFP or cable issue) |
| `8017 4034` | Loop arbitration timeout (topology mismatch) |
| `8017 a964` | Target mode firmware init failure (ISP2432 on kernel 6.12) |
| `8017 a284` | FLOGI timeout (target transmitting, initiator not responding) |

### SCST won't start after upgrade

Check for stale systemd drop-ins from older installs:
```bash
ls /etc/systemd/system/scst.service.d/
```

Remove any `fcadm-preload.conf` if present (renamed from old `fcadm` tool):
```bash
rm /etc/systemd/system/scst.service.d/fcadm-preload.conf
systemctl daemon-reload
systemctl start scst
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

If session shows but block device doesn't appear, the ini_group may not
have been applied. Run `./qle_adm.sh apply` on the target.

### Session drops on idle

The FC driver drops remote ports after `dev_loss_tmo` seconds of no link
activity. Default is 16 seconds, which is too short for systems with idle periods.

```bash
# Check current value
cat /sys/class/fc_host/host<N>/dev_loss_tmo

# Set to 60 seconds persistently
cat > /etc/udev/rules.d/99-qla2xxx-timeouts.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="fc_host", ATTR{dev_loss_tmo}="60"
ACTION=="add", SUBSYSTEM=="scsi_disk", ATTR{../timeout}="60"
EOF
udevadm control --reload-rules
```

**Critical for FC root boot:** if the system boots from an FC LUN and
`dev_loss_tmo` is too short, any brief link hiccup causes the root device
to disappear, triggering a kernel panic. Set `dev_loss_tmo` to at least 60.

### rel_tgt_id conflicts with iSCSI

When enabling FC target ports, `qle_adm.sh` assigns `rel_tgt_id` values
starting at 10 to avoid conflict with iSCSI targets which typically occupy
slots 1–9. If you see `invalid slot` errors when enabling a port, check
what IDs are in use:
```bash
cat /sys/kernel/scst_tgt/targets/iscsi/*/rel_tgt_id 2>/dev/null
cat /sys/kernel/scst_tgt/targets/qla2x00t/*/rel_tgt_id 2>/dev/null
```

---

## FAQ

**Q: Why can't I use my ISP2432 (QLE2462/QLE2460) as an FC target?**

The `qla2xxx_scst` driver's target mode initialization is incompatible with
ISP2432 on Linux kernel 6.12. The card produces AEN `0x8017 a964`
continuously and the firmware state register returns all-F values; the
card is completely unresponsive in target mode. This is not fixable via
firmware or module parameters. ISP2432 works correctly as an initiator using
the plain `qla2xxx` driver. Use ISP2532 or newer for target mode.

---

**Q: Why does the TrueNAS WUI overwrite my scst.conf?**

The WUI manages iSCSI configuration through its own internal database. When
you make any iSCSI change and save, the WUI regenerates `/etc/scst.conf`
from that database, replacing the file entirely. It has no knowledge of FC
targets and cannot preserve manual additions.

`qle_adm.sh` handles this by injecting the required `TARGET_DRIVER qla2x00t`
block as part of `setup --boot`, which runs as a systemd `ExecStartPre`
before SCST starts on every boot. The WUI does not restart SCST when saving
iSCSI changes (it applies changes via sysfs), so active FC sessions are not
affected by WUI saves. The block is only needed at SCST startup.

---

**Q: Why does qle_adm use qlini_mode=dual instead of disabled?**

`qlini_mode=disabled` causes the ISP2532 to not assert a valid FC signal on
a direct P2P connection. The port stays in an unknown topology state and
never completes FLOGI. `qlini_mode=dual` keeps the initiator stack active
alongside the target stack, which causes the ISP2532 to properly assert the
port signal and complete P2P negotiation on a direct cable. This was
discovered through extensive testing and is required for direct (switchless)
ISP2532 target operation.

---

**Q: What is the optrom slot and why does it matter?**

The ISP2532 has two firmware storage locations:
- **Primary flash:** the main slot, loaded by default (`ql2xfwloadbin=0`)
- **Optrom slot:** a secondary slot, loaded with `ql2xfwloadbin=1`

The optrom slot often contains a newer firmware version than primary flash.
On some cards the optrom contains `8.08.207` while primary flash contains
`8.07.00`. The newer firmware has better P2P negotiation behavior. Use
`ql2xfwloadbin=1` to load from optrom, or `fw save` to extract it to the
firmware store and load it via `ql2xfwloadbin=2`.

---

**Q: Can I boot from an FC LUN?**

Yes. Configure via the QLogic Fast!UTIL option ROM (Ctrl+Q during POST):

1. Enable HBA BIOS on the port (this is the only required setting)
2. Add the target to the Selectable Boot list
3. Save and exit

The card will log into the target and present the LUN to the BIOS as a
bootable device on every subsequent boot without manual intervention.

Other Fast!UTIL settings (LIP Reset, connection mode) can remain at defaults,
as they are not required for reliable boot with ISP2532 firmware 8.08.207.

---

**Q: What happens if I suspend a system that boots from an FC LUN?**

Deep sleep (S3/mem) is not compatible with FC root boot. When the system
suspends, the PCIe bus powers down and the HBA loses its connection. On
resume, the kernel cannot complete the resume sequence without the root
filesystem, but the FC link cannot reconnect until the kernel has resumed
enough to run the recovery hook; this creates a deadlock. The system hangs mid-resume.

Two solutions:

**Disable suspend entirely (recommended for servers):**
```bash
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

**Use s2idle (shallow sleep, PCIe stays powered):**
```bash
mkdir -p /etc/systemd/sleep.conf.d
echo s2idle > /etc/systemd/sleep.conf.d/mem.conf
```

`s2idle` keeps the PCIe bus powered so the HBA maintains its FC link
through the suspend cycle. Less power saving than S3 but fully compatible
with FC root boot.

---

**Q: Why must qle_adm.sh be installed on /mnt?**

TrueNAS SCALE uses boot environments (ZFS clones of the system dataset).
When you upgrade TrueNAS or activate a different boot environment, `/root`,
`/etc`, and all system paths are replaced with the contents of the new BE.
Only datasets under `/mnt/<pool>/` are independent of boot environments and
survive all lifecycle events. If qle_adm.sh and config.json were stored in
`/root`, they would be lost on every upgrade.

---

**Q: What is dev_loss_tmo and why does it matter?**

`dev_loss_tmo` is the number of seconds the FC driver waits for a remote
port to reappear after a link event before declaring it permanently lost and
removing the associated block device. The default is 16 seconds.

For a system booting from FC, if the link drops briefly (even due to a
module reload or LIP) and does not recover within 16 seconds, the root
device disappears and the kernel panics. Set it to at least 60 seconds via
udev rule to give the link enough time to renegotiate.

---

**Q: Does the TrueNAS WUI restart SCST when I save iSCSI configuration?**

No. The WUI applies iSCSI configuration changes dynamically via the SCST
sysfs interface without restarting the service. This means active iSCSI
sessions are not dropped when you save iSCSI changes in the WUI, and active
FC sessions managed by qle_adm are also unaffected. The `/etc/scst.conf`
file is rewritten but SCST does not re-read it until the next restart.

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
      "default": "qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=1"
    },
    "ISP2432": {
      "default": "qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0"
    },
    "DEFAULT": {
      "default": "qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0"
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
  "firmware": {}
}
```

| Key | Description |
|---|---|
| `enabled_ports` | WWNs of ports activated as FC targets |
| `open_extents` | Extents mapped to all initiators (default group) |
| `assignments` | Per-initiator extent mappings with LUN numbers |
| `seen_initiators` | History of connected initiator WWNs with last-seen timestamp |
| `isp_params` | Per-ISP named parameter profiles |
| `isp_active_profile` | Currently selected profile per ISP type |
| `wwn_names` | Friendly names, roles, and port indices for WWNs |
| `firmware` | Reserved for firmware metadata |

---

## Known Limitations

- **ISP2432 target mode:** not supported on kernel 6.12. Use ISP2532 or newer.
- **Primary flash version:** not readable via sysfs on this driver build. `fw show` reports it as "not exposed by driver".
- **Sysfs NVRAM writes:** writes to the `nvram` sysfs file update the driver shadow buffer only. Physical EEPROM is not written.
- **FC root + deep sleep:** incompatible. Use s2idle or disable suspend.
- **fw flash:** requires `qlflash` utility which is not included and not available via apt on TrueNAS. Set `FLASH_TOOL=` in the script header if using an alternative tool name.
- **TrueNAS WUI:** has no FC target management. All FC configuration is via `qle_adm.sh`.
- **Python f-string symbols:** `isp-params list` drift indicators (`→`, `⚠`) in the Configured/Applied section are not affected by `USE_UNICODE=0` since they are generated by Python, not bash.
