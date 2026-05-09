# TrueNAS SCALE CE QLogic FC Target Manager

`qle_adm.sh` manages QLogic Fibre Channel HBAs as SCST targets on
TrueNAS SCALE Community Edition. It handles module loading, LUN
mapping, and persistent configuration across reboots and boot
environment changes.

---

## What it does

TrueNAS SCALE CE includes SCST and the `qla2xxx_scst` kernel module,
but the web UI only manages iSCSI - there is no FC target configuration
in the WUI. `qle_adm.sh` fills that gap:

- Loads `qla2xxx_scst` with the correct parameters for target mode
- Reconstructs the full FC target configuration in `/etc/scst.conf` at
  boot from `config.json` - SCST reads it naturally at startup
- Maps ZFS volumes (extents) to initiators as FC LUNs via sysfs at runtime
- Persists all configuration in `config.json` across reboots and TrueNAS
  upgrades
- Provides status, diagnostics, and firmware management

---

## Configuration model

`config.json` on `/mnt` is the single source of truth and survives all
TrueNAS lifecycle events. Two representations are derived from it:

**`/etc/scst.conf`** - rebuilt at boot and on `sync`. SCST reads this file
at startup to initialize all FC target state: enabled ports, rel_tgt_ids,
LUN mappings, and initiator groups. No sysfs writes are needed at boot.

**Live sysfs** - all runtime changes (port enable/disable, open, close,
assign, unassign) write directly to both sysfs and `config.json` atomically.
Active sessions are never disrupted by configuration changes to other targets.

The TrueNAS WUI rewrites `/etc/scst.conf` on every iSCSI save. Running
`sync` after a WUI save rebuilds the FC target block from `config.json`
without touching live sysfs state or active sessions.

---

## What you need

- **TrueNAS SCALE CE** (tested on 25.10.x, kernel 6.12)
- **QLogic ISP2532 or newer HBA** for confirmed target mode support. ISP2432
  target mode has not been achieved on kernel 6.12 - root cause unknown,
  further debugging may find a working configuration. ISP2432 works as an
  initiator.
- **SCST running**: verify with `systemctl is-active scst`
- **A ZFS zvol** registered as an SCST block device in `/etc/scst.conf`
- **A dataset under `/mnt`** for persistent storage of the script and config

> **Why `/mnt`?** TrueNAS boot environments replace `/root` and `/etc` on
> upgrade or BE switch. Only datasets under `/mnt/<pool>/` survive all
> lifecycle events.

---

## Quick Start

Expose an existing ZFS extent to FC initiators without installing
`qle_adm.sh`. SCST must already be active - verify under System >
Services in the TrueNAS WUI.

```bash
git clone https://github.com/royasutton/tnsce-qle-adm.git

cd tnsce-qle-adm
export QLE_ADM_HOME=$(pwd)

chmod +x ./qle_adm.sh

# Inject FC target block into scst.conf
./qle_adm.sh sync

# Load qla2xxx_scst in target mode - SCST reads the FC block on module load
./qle_adm.sh module load

# Verify SCST, module, ports, and scst.conf block are all good
./qle_adm.sh status

# Map (open access) extent on a port for initiator access by index
./qle_adm.sh list-extents
./qle_adm.sh list-ports

./qle_adm.sh open --ext 0
./qle_adm.sh port enable --port 0

# Verify the mapping and confirm the initiator session is active
./qle_adm.sh list-assignments
./qle_adm.sh list-initiators
```

The initiator can now scan for and mount the block device. When you are
ready to make this configuration persistent across reboots, see
[Quick Install](#quick-install) below.

---

## Quick Install

```bash
# 1. Install to a persistent dataset
QLE_ADM_HOME=/mnt/<pool>/admin/qle_adm ./qle_adm.sh --yes install

# 2. Add to your shell startup script (~/.bashrc or ~/.zshrc) so
#    qle_adm.sh is available by name from any directory
export QLE_ADM_HOME=/mnt/<pool>/admin/qle_adm
PATH="${PATH}:${QLE_ADM_HOME}"

# 3. Inject FC target block into scst.conf before loading the module
./qle_adm.sh sync

# 4. Load the module - SCST reads the FC target block on module registration
./qle_adm.sh module load

# 5. Verify - confirm no gaps before proceeding
./qle_adm.sh status

# 6. Verify the HBA is detected and identify the P2P port index
./qle_adm.sh list-hba
./qle_adm.sh list-ports

# 7. Enable the P2P target port (use index from list-ports)
./qle_adm.sh port enable --port 1

# 8a. Expose a ZFS volume to all initiators
./qle_adm.sh open --ext 0

# 8b. Or assign to a specific initiator only
./qle_adm.sh assign --ext 0 --init 0

# 9. Verify
./qle_adm.sh status
```

From this point the configuration is persistent. On every boot, the TrueNAS
POSTINIT init script registered by `install` runs `sync --boot --system`.
It unconditionally reloads `qla2xxx_scst` with configured params - the kernel
autoloads the module before POSTINIT runs with default params, so the reload
is always required. SCST starts after POSTINIT exits and reads the
reconstructed scst.conf, initializing all FC target state from it. The entry
is visible and manageable under System > Advanced > Init/Shutdown Scripts in
the WUI.

---

## After an upgrade or boot environment change

```bash
./qle_adm.sh sync --system --restart
```

Restores the modprobe config and rebuilds scst.conf from config.json.
The POSTINIT boot entry survives upgrades automatically.

---

## When things break

**Link won't come up:**
```bash
./qle_adm.sh status
./qle_adm.sh list-hba
./qle_adm.sh isp-params list
```

**Block device not appearing on initiator:**
```bash
./qle_adm.sh list-assignments
./qle_adm.sh list-initiators
```

**After upgrade - targets not active:**
```bash
./qle_adm.sh sync --system --restart
```

---

## Further reading

See **[GUIDE.md](GUIDE.md)** for complete documentation including full
command reference, firmware management, ISP parameter profiles,
initiator setup, troubleshooting, and FAQ.
