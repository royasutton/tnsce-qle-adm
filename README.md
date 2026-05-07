# TrueNAS SCALE CE QLogic FC Target Manager

`qle_adm.sh` manages QLogic Fibre Channel HBAs as SCST targets on
TrueNAS SCALE Community Edition. It handles module loading, LUN
mapping, and persistent configuration across reboots and boot
environment changes.

---

## What it does

TrueNAS SCALE CE includes SCST and the `qla2xxx_scst` kernel module,
but the web UI only manages iSCSI — there is no FC target configuration
in the WUI. `qle_adm.sh` fills that gap:

- Loads `qla2xxx_scst` with the correct parameters for target mode
- Reconstructs the full FC target configuration in `/etc/scst.conf` at
  boot from `config.json` — SCST reads it naturally at startup
- Maps ZFS volumes (extents) to initiators as FC LUNs via sysfs at runtime
- Persists all configuration in `config.json` across reboots and TrueNAS
  upgrades
- Provides status, diagnostics, and firmware management

---

## Configuration model

`config.json` on `/mnt` is the single source of truth and survives all
TrueNAS lifecycle events. Two representations are derived from it:

**`/etc/scst.conf`** — rebuilt at boot and on `sync`. SCST reads this file
at startup to initialize all FC target state: enabled ports, rel_tgt_ids,
LUN mappings, and initiator groups. No sysfs writes are needed at boot.

**Live sysfs** — all runtime changes (port enable/disable, open, close,
assign, unassign) write directly to both sysfs and `config.json` atomically.
Active sessions are never disrupted by configuration changes to other targets.

The TrueNAS WUI rewrites `/etc/scst.conf` on every iSCSI save. Running
`sync` after a WUI save rebuilds the FC target block from `config.json`
without touching live sysfs state or active sessions.

---

## What you need

- **TrueNAS SCALE CE** (tested on 25.10.x, kernel 6.12)
- **QLogic ISP2532 or newer HBA** (ISP2432 cannot be used as an FC target
  on kernel 6.12 and is not supported in target mode)
- **SCST running**: verify with `systemctl is-active scst`
- **A ZFS zvol** registered as an SCST block device in `/etc/scst.conf`
- **A dataset under `/mnt`** for persistent storage of the script and config

> **Why `/mnt`?** TrueNAS boot environments replace `/root` and `/etc` on
> upgrade or BE switch. Only datasets under `/mnt/<pool>/` survive all
> lifecycle events.

---

## Quick Start

Expose an existing ZFS extent to FC initiators without installing
`qle_adm.sh`. SCST must already be active (verify in the TrueNAS WUI
under System > Services).

Set `QLE_ADM_HOME` once for the session — all commands below use it:

```bash
export QLE_ADM_HOME=.
```

> When you are ready to make this persistent, update `QLE_ADM_HOME` to
> a dataset under `/mnt` before running `install`.

```bash
# 1. Make the script executable
chmod +x ./qle_adm.sh

# 2. Load qla2xxx_scst and rebuild scst.conf from config.json
#    (initializes config.json in the current directory on first run)
./qle_adm.sh sync --boot

# 3. Verify SCST, module, ports, and scst.conf block are all good
./qle_adm.sh status

# 4. List available extents and note the index [N]
./qle_adm.sh list-extents

# 5. List FC ports and note the index [N] of the port to use
./qle_adm.sh list-ports

# 6. Enable the target port
./qle_adm.sh port enable --port 0

# 7. Open the extent to all initiators
./qle_adm.sh open --ext 0

# 8. Verify the mapping and confirm the initiator session is active
./qle_adm.sh list-assignments
./qle_adm.sh list-initiators
```

The initiator can now scan for and mount the block device. When you are
ready to make this configuration persistent across reboots, see
[Quick Install](#quick-install) below.

---

## Quick Install

```bash
# 1. Extract the archive and install to a persistent dataset
QLE_ADM_HOME=/mnt/<pool>/admin/qle_adm ./qle_adm.sh --yes install

# 2. Verify the HBA is detected
./qle_adm.sh hba-info

# 3. Enable a port as an FC target (writes to sysfs + config.json)
./qle_adm.sh port enable --port 0

# 4a. Expose a ZFS volume to all initiators
./qle_adm.sh open --ext 0

# 4b. Or assign to a specific initiator only
./qle_adm.sh assign --ext 0 --init 0

# 5. Verify
./qle_adm.sh status
```

From this point the configuration is persistent. On every boot,
`qle_adm-boot.service` runs `sync --boot` before SCST starts, which
rebuilds scst.conf from config.json and loads the module. SCST then
reads the reconstructed scst.conf naturally.

---

## After a WUI iSCSI save

The WUI rewrites scst.conf and wipes the FC target block. Rebuild it:

```bash
./qle_adm.sh sync
```

This rebuilds scst.conf from config.json. Live sysfs state and active
sessions are not touched.

---

## What survives what

| Location | Reboot | BE change | Upgrade |
|---|---|---|---|
| `/mnt/<pool>/` | ✓ | ✓ | ✓ |
| `/etc/` | ✓ | ✗ wiped | ✗ wiped |
| `/root/` | ✓ | ✗ wiped | ✗ wiped |
| `/run/` | ✗ tmpfs | ✗ | ✗ |

`config.json` lives on `/mnt` and survives everything. System files in
`/etc` (modprobe config, systemd units, scst.conf block) are regenerated
by `sync`.

---

## After an upgrade or boot environment change

```bash
./qle_adm.sh sync
./qle_adm.sh status
```

`sync` restores all `/etc` files and rebuilds scst.conf from config.json.
If SCST needs to be restarted to pick up the new scst.conf:

```bash
systemctl restart scst
```

---

## When things break

**Link won't come up:**
```bash
./qle_adm.sh status
./qle_adm.sh hba-info
./qle_adm.sh isp-params list
```

**Block device not appearing on initiator:**
```bash
./qle_adm.sh list-assignments
./qle_adm.sh list-initiators
```

**After upgrade — targets not active:**
```bash
./qle_adm.sh sync
systemctl restart scst
```

---

## Further reading

See **[GUIDE.md](GUIDE.md)** for complete documentation including full
command reference, firmware management, ISP parameter profiles,
initiator setup, troubleshooting, and FAQ.
