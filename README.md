# db-status.sh

Bash monitoring script for Oracle RAC environments that provides a consolidated, color-coded view of all databases registered in the Cluster Registry (CRS) — including NON-CDB, CDB and PDB status — from a single command.

## Features

- Displays CRS cluster info: Grid version, cluster name, upgrade state, SCAN name, cluster nodes
- Shows host resource usage: memory, hugepages and CPU utilization with color thresholds
- Lists all databases registered in CRS with:
  - DB unique name, role (PRIMARY / PHYSICAL STANDBY), type (CDB / NON-CDB), version
  - Datafile size, SGA max size, CPU count
  - Per-node instance status: `open`, `restricted`, `mount`, `nomount`, `stopped`
- For CDB databases, lists all PDBs with per-node open mode and restricted status
- Filter by database name, db_unique_name or PDB name (with wildcard support)
- Optional CRS header section (can be suppressed for scripting)
- Elapsed time at the end of each run
- Supports Oracle RDBMS 11g and 12c+

## Requirements

- Oracle Linux or compatible Linux distribution
- Oracle Grid Infrastructure (GI) running (`crsd.bin` process must be active)
- Standard Linux tools: `free`, `lscpu`, `mpstat` (sysstat package), `/proc/meminfo`
- Run as the Oracle OS user (or any user with `/ as sysdba` access and `srvctl` permissions)

## Usage

```bash
./db-status.sh [-d <pattern>] [-c true|false] [-h]
```

### Options

| Option | Description |
|--------|-------------|
| `-d <pattern>` | Filter output to databases/PDBs matching `<pattern>`. Supports `*` wildcard. Case-insensitive. |
| `-c true\|false` | Show or hide the CRS INFO header section (default: `true`). |
| `-h`, `--help` | Show help and exit. |

### Filter behaviour

| Match type | Result |
|-----------|--------|
| CDB / NON-CDB name match | Shows only that database; name highlighted in green |
| PDB name match | Shows the full parent CDB block with all its PDBs; matched PDB highlighted in green |
| Wildcard match | Shows all matching databases and/or PDBs across the cluster |

> **Note:** Always quote wildcard patterns to prevent shell glob expansion:
> ```bash
> ./db-status.sh -d 'CDB*'    # correct
> ./db-status.sh -d CDB*      # wrong — shell expands * to filenames
> ```

## Examples

```bash
# Show all registered databases (with CRS info header)
./db-status.sh

# Show databases table only — no CRS info header (useful for scripting)
./db-status.sh -c false

# Show only the database named CDB01
./db-status.sh -d CDB01

# Show the parent CDB of a PDB named PDBFIN
./db-status.sh -d PDBFIN

# Show all databases/PDBs whose name starts with PRO
./db-status.sh -d 'PRO*'

# Show all databases/PDBs whose name ends with PRD
./db-status.sh -d '*PRD'

# Combine filter and suppress CRS header
./db-status.sh -c false -d 'CDB*'
```

## Output colour coding

| Colour | Meaning |
|--------|---------|
| Green | Instance open, or database/PDB name matched by `-d` filter |
| Yellow | Instance in `mount` / `nomount` / `restricted` state, PDB in `MOUNTED` or `restricted` state, cluster upgrade state not `NORMAL` |
| Red | Instance stopped, memory/CPU usage above 95% |

Host resource usage thresholds:

| Range | Colour |
|-------|--------|
| 0 – 75% | Green |
| 76 – 95% | Yellow |
| > 95% | Red |

## Sample output

```
db-status for Oracle Database: Release 1.45 on 06-APR-2026 10:00:00

===========================================================================
CRS info
===========================================================================
GRID_HOME         : /u01/app/19.0.0/grid
GRID_VERSION      : 19.21.0.0.0
CLUSTER_NAME      : mycluster ( upgrade state is NORMAL )
SCAN_NAME         : mycluster-scan
CLUSTER_NODES     : node1,node2
HOST_RESOURCES    : node1 [MEM  128GB (hugepages  64GB)] [CPUs  32 (Intel Xeon ...)]
HOST_USAGE        : node1 [MEM%  42.3% (hugepages  68.5%)] [CPU%  12.4%]

===========================================================================
Databases status
===========================================================================
FILTER_ACTIVE     : -d CDB01*  (showing databases/PDBs matching 'CDB01*')

DB_UNIQUE_NAME    : CDB01                   ORACLE_HOME  : /u01/app/oracle/product/19.0.0/db
DB-ROLE (DB-TYPE) : PRIMARY (CDB)           VERSION      : 19.21.0.0.0
+-----------------------------------+------------------+--------------+-----------+-------------------------+
| DB                                | SIZE             | SGA_MAX_SIZE | CPU_COUNT | node1                   |
+-----------------------------------+------------------+--------------+-----------+-------------------------+
| CDB01                             | [       271 GB ] | 128 GB       | 8         | CDB011(open)            |
| └ PDB$SEED                        |    └        0 GB | -            | -         |   READ ONLY             |
| └ PDBAPP                          |    └      130 GB | 64 GB        | 4         |   READ WRITE            |
| └ PDBDWH                          |    └      141 GB | 64 GB        | 4         |   READ WRITE            |
+-----------------------------------+------------------+--------------+-----------+-------------------------+

Totals (CDBs:1  PDBs:3  Size:271 GB)

===========================================================================
Finished on 06-APR-2026 10:00:05 - elapsed 5s
===========================================================================
```

## Compatibility

| Component | Minimum version |
|-----------|----------------|
| Oracle RDBMS | 11g (11.2) |
| Oracle Grid Infrastructure | 12c |
| Linux | Oracle Linux 7 / RHEL 7 or later |
| Bash | 4.0 |

> Oracle 11g databases are supported as NON-CDB only (no `v$pdbs`, no `CDB` column in `v$database`).

## Installation

```bash
# Copy the script to your utilities directory
cp db-status.sh /home/oracle/utils/

# Make it executable
chmod +x /home/oracle/utils/db-status.sh

# Optional: add to PATH
echo 'export PATH=$PATH:/home/oracle/utils' >> ~/.bash_profile
```

No external dependencies beyond standard Oracle client binaries (`sqlplus`, `srvctl`, `asmcmd`, `olsnodes`) and common Linux utilities.

## License

MIT License — Copyright (c) Ignacio Pastor Fernandez.
