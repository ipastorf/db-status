#!/bin/bash
#######################################################################################
# Script:       "db-status.sh"                                                        #
# Description:  Obtain information about NON-CDB, CDB and PDBS in Oracle RAC          #
# Versions:     Oracle GI > 12c and RDBMS > 11g                                       #
#                                                                                     #
# Author:       Ignacio Pastor Fernández                                              #
#                                                                                     #
# License:      MIT License                                                           #
# Copyright (C) - Ignacio Pastor Fernandez."                                          #
#######################################################################################
version="1.45"

# Output table columns width variables (user-modifiable)
col_width_db="35"          # Column width for DB
col_width_size="18"        # Column width for SIZE
col_width_sga="14"         # Column width for SGA_MAX_SIZE
col_width_cpucount="11"    # Column width for CPU_COUNT
col_width_dbnodes="25"     # Column width for each DBNODE

# Seconds variable for elapsed time
SECONDS=0

# Platform compatibility check
os_name=$(uname -s 2>/dev/null)
if [ "${os_name}" != "Linux" ]; then
    echo ""
    echo "error: unsupported platform '${os_name}'."
    echo "       This script requires Oracle Linux or a compatible Linux distribution."
    case "${os_name}" in
        SunOS)  echo "       Detected: Solaris " ;;
        AIX)    echo "       Detected: AIX " ;;
        HP-UX)  echo "       Detected: HP-UX " ;;
        *)      echo "       Detected OS: ${os_name}" ;;
    esac
    echo ""
    exit 1
fi

platform_errors=()
[ ! -f /proc/meminfo ]          && platform_errors+=("/proc/meminfo not found")
! command -v free    &>/dev/null && platform_errors+=("command not found: free")
! command -v lscpu   &>/dev/null && platform_errors+=("command not found: lscpu")
! command -v mpstat  &>/dev/null && platform_errors+=("command not found: mpstat (install sysstat package)")

if [ ${#platform_errors[@]} -gt 0 ]; then
    echo ""
    echo "error: platform requirements not met:"
    for e in "${platform_errors[@]}"; do echo "       - ${e}"; done
    echo ""
    exit 1
fi


# Help / usage
show_help() {
    echo ""
    echo "Usage: $(basename $0) [-d <pattern>] [-h|--help]"
    echo ""
    echo "Description:"
    echo "  Displays status information for Oracle RAC databases (NON-CDB, CDBs and PDBs)"
    echo "  registered in the Cluster Registry (CRS) on the local node."
    echo ""
    echo "Options:"
    echo "  -d <pattern>   Filter output to show only databases matching <pattern>."
    echo "                 Matching is case-insensitive and supports wildcards:"
    echo "                   *   matches any sequence of characters"
    echo ""
    echo "                 The filter searches across:"
    echo "                   - CDB and NON-CDB names    (e.g. -d CDB01, -d DB01)"
    echo "                   - db_unique_name values    (e.g. -d CDB01_RAC01)"
    echo "                   - PDB names                (e.g. -d PDB1)"
    echo ""
    echo "                 Behaviour by match type:"
    echo "                   CDB / NON-CDB match  -> shows only that database;"
    echo "                                           its name is highlighted in green."
    echo "                   PDB match            -> shows the full parent CDB block"
    echo "                                           with all its PDBs; the matched"
    echo "                                           PDB name is highlighted in green."
    echo "                   Wildcard match       -> all matching databases and/or PDBs"
    echo "                                           are shown (may span multiple CDBs)."
    echo ""
    echo "  -c true|false  Show or hide the CRS INFO header section (default: true)."
    echo "                 Use -c false to suppress the header and show only the"
    echo "                 Databases status table (useful for scripting or quick checks)."
    echo ""
    echo "  -h, --help     Show this help message and exit."
    echo ""
    echo "Output colour coding:"
    echo "   Green   - database / PDB matched by -d filter, or instance open"
    echo "   Yellow  - instance in mount/nomount state, or PDB in MOUNTED state,"
    echo "             or cluster upgrade state not NORMAL"
    echo "   Red     - instance stopped"
    echo ""
    echo "Examples:"
    echo "  $(basename $0)                   Show all registered databases (with CRS info)"
    echo "  $(basename $0) -c false          Show databases table only (no CRS info header)"
    echo "  $(basename $0) -d CDB1           Show only CDB1 (exact CDB/NON-CDB match)"
    echo "  $(basename $0) -d PDB1           Show the parent CDB of PDBFIN, highlight it"
    echo "  $(basename $0) -d PDB*           Show all databases/PDBs starting with PDB"
    echo "  $(basename $0) -d '*PRO'         Show all databases/PDBs ending with PRO"
    echo "  $(basename $0) -d '*PDB*'        Show all databases/PDBs containing PDB"
    echo ""
    exit 0
}

# Parse command-line arguments
filter_db=""
show_crs="true"
[[ "$1" == "--help" ]] && show_help
while getopts ":d:c:h" opt; do
    case ${opt} in
        d) filter_db=$(echo "${OPTARG}" | tr '[:lower:]' '[:upper:]')
           # Validate: only letters, digits, underscore, $ and wildcard * are allowed.
           # If the value contains / . spaces or looks like a filename/path, it was likely
           # expanded by the shell (user forgot to quote the * wildcard).
           if [[ "${filter_db}" =~ [^A-Z0-9_\$\*] ]]; then
               echo ""
               echo "error: invalid -d pattern '${OPTARG}'."
               echo "       Allowed characters: letters, digits, _ and wildcard *"
               echo "       If you used *, make sure to quote it: -d 'VIT*'"
               echo ""
               exit 1
           fi
           ;;
        c) show_crs=$(echo "${OPTARG}" | tr '[:upper:]' '[:lower:]')
           if [[ "${show_crs}" != "true" && "${show_crs}" != "false" ]]; then
               echo ""
               echo "error: invalid value for -c '${OPTARG}'. Use 'true' or 'false'."
               echo "usage: $(basename $0) [-d <pattern>] [-c true|false] [-h]"
               echo ""
               exit 1
           fi
           ;;
        h) show_help ;;
        :) echo ""; echo "error: option -${OPTARG} requires an argument"; echo "usage: $(basename $0) [-d <pattern>] [-c true|false] [-h]"; echo ""; exit 1 ;;
        ?) echo ""; echo "error: unknown option -${OPTARG}";              echo "usage: $(basename $0) [-d <pattern>] [-c true|false] [-h]"; echo ""; exit 1 ;;
    esac
done
filter_found=false


# Print begin info
echo "
db-status for Oracle Database: Release ${version} on `date '+%d-%^b-%Y %H:%M:%S'`"


# Set Oracle environment variables to null
export ORACLE_HOME=""
export ORACLE_SID=""
export ORACLE_PDB_SID=""
export GRID_HOME=""

# Detect GRID_HOME from running crsd.bin process
GRID_HOME=$(ps -ef | grep -w crsd.bin | grep -v grep | awk '{ print $(NF-1) }' | sed 's/\/bin\/crsd\.bin//')

# Check if GRID_HOME is set
if [ -z "${GRID_HOME}" ]; then
    echo ""
    echo "error: GRID_HOME not detected or crs is not running (crsd.bin)"
    echo ""
    exit 1
fi

current_dbnode="`hostname -s`"
db_cdb_size="0"
sum_pdbs="0"
sum_size_gb=0

# Build array of database nodes
a_dbnodes=()
while IFS= read -r node; do a_dbnodes+=("$node"); done < <(${GRID_HOME}/bin/srvctl config nodeapps | grep "VIP exists: network number 1" | awk '{print $NF}')
num_dbnodes="${#a_dbnodes[@]}"

## internal table format
internal_width_size="9"
color_offset=$((col_width_dbnodes + 9))

# Number of columns in table = num_dbnodes + fixed_columns (DB, SIZE, SGA and CPU_COUNT)
fixed_columns=4
num_columns=$((num_dbnodes + fixed_columns))

# Build separator line and calculate total header width
line=$(printf "+%-${col_width_db}s"       "" | tr ' ' '-')
line+=$(printf "+%-${col_width_size}s"    "" | tr ' ' '-')
line+=$(printf "+%-${col_width_sga}s"     "" | tr ' ' '-')
line+=$(printf "+%-${col_width_cpucount}s" "" | tr ' ' '-')
for ((i = 0; i < num_dbnodes; i++)); do
    line+=$(printf "+%-${col_width_dbnodes}s" "" | tr ' ' '-')
done
line+="+"
header_chars=${#line}

if [ "${show_crs}" = "true" ]; then
    GRID_VERSION=$(${GRID_HOME}/bin/asmcmd showversion | awk -F: {'print $2'}| sed 's/^ *//;s/ *$//' )
    CLUSTER_NAME=$(${GRID_HOME}/bin/olsnodes -c)
    CLUSTER_STATUS=$(${GRID_HOME}/bin/crsctl query crs activeversion -f > /dev/null && (${GRID_HOME}/bin/crsctl query crs activeversion -f | grep -o '\[[^]]*\]' | sed -n '2p' | tr -d '[]'))
    CLUSTER_STATUS_COLOR=$( [ "$CLUSTER_STATUS" = "NORMAL" ] && echo -e "\033[32m$CLUSTER_STATUS\033[0m" || echo -e "\033[33m$CLUSTER_STATUS\033[0m" )
    SCAN_NAME=$(${GRID_HOME}/bin/srvctl config scan | grep "SCAN name"| awk -F: '{print $2}' | awk -F, '{print $1}' | sed 's/^[ \t]*//;s/[ \t]*$//')
    string_dbnodes=`(IFS=,; echo "${a_dbnodes[*]}")`

    # Get operating system info
    # Memory
    total_mem_gb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
    total_mem_usage_pct=$(free | awk '/Mem:/ { printf("%.1f%%\n", ($3/$2)*100) }')
    hp_total_kb=$(( $(grep HugePages_Total /proc/meminfo | awk '{print $2}') * $(grep Hugepagesize /proc/meminfo | awk '{print $2}') ))
    hp_total_gb=$(( hp_total_kb / 1024 / 1024 ))
    hp_usage_pct=$(awk '/HugePages_Total/ {t=$2} /HugePages_Free/ {f=$2} END {print (t? sprintf("%.1f%%", (t-f)*100/t) : "N/A")}' /proc/meminfo)
    # CPU
    cpus=$(lscpu | awk -F: '/^CPU\(s\):/ {gsub(/^[ \t]+/, "", $2); print $2}')
    model=$(lscpu | awk -F: '/^Model name:/ {gsub(/^[ \t]+/, "", $2); print $2}')
    cpu_usage_pct=$(mpstat 1 1 | tail -n 1 | awk '{printf "%.1f\n", 100 - $12}')%

    # Apply color to usage percentage values:
    #   0-75%   -> green
    #  76-95%   -> yellow
    #  96-100%  -> red
    colorize_pct() {
        local raw="$1"
        local val=$(echo "$raw" | tr -d '%')
        # If value is not numeric (e.g. "N/A"), return as-is without colour
        if ! [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "${raw}"
            return
        fi
        if awk "BEGIN {exit !($val > 95)}"; then
            echo -e "\033[31m${raw}\033[0m"
        elif awk "BEGIN {exit !($val > 75)}"; then
            echo -e "\033[33m${raw}\033[0m"
        else
            echo -e "\033[32m${raw}\033[0m"
        fi
    }

    total_mem_usage_pct_color=$(colorize_pct "$total_mem_usage_pct")
    hp_usage_pct_color=$(colorize_pct "$hp_usage_pct")
    cpu_usage_pct_color=$(colorize_pct "$cpu_usage_pct")

    # Print CRS info
    printf "\n%${header_chars}s\n" | tr ' ' '='
    echo  "CRS info"
    printf "%${header_chars}s\n" | tr ' ' '='
    printf "%-18s: %-23s %s\n" "GRID_HOME"      "${GRID_HOME}"
    printf "%-18s: %-23s %s\n" "GRID_VERSION"   "${GRID_VERSION}"
    printf "%-18s: %-23s %s\n" "CLUSTER_NAME"   "${CLUSTER_NAME} ( upgrade state is ${CLUSTER_STATUS_COLOR} )"
    printf "%-18s: %-23s %s\n" "SCAN_NAME"      "${SCAN_NAME}"
    printf "%-18s: %-23s %s\n" "CLUSTER_NODES"  "${string_dbnodes}"
    printf "%-18s: %-2s [MEM%5sGB (hugepages%5sGB)] [CPUs%4s (%s)]\n"      "HOST_RESOURCES" "$(hostname)" "$total_mem_gb" "$hp_total_gb" "$cpus" "$model"
    printf "%-18s: %-2s [MEM%% %5s (hugepages  %5s)] [CPU%% %5s]\n"         "HOST_USAGE"     "$(hostname)" "$total_mem_usage_pct_color" "$hp_usage_pct_color" "$cpu_usage_pct_color"
fi

# Print DB info
printf "\n%${header_chars}s\n" | tr ' ' '='
echo -e "Databases status"
printf "%${header_chars}s\n" | tr ' ' '='
if [ -n "${filter_db}" ]; then
    echo "FILTER_ACTIVE     : -d $(printf "\033[32m%s\033[0m" "${filter_db}")  (showing databases/PDBs matching '$(printf "\033[32m%s\033[0m" "${filter_db}")')"
fi
echo ""

# Check if srvctl config database output is valid
${GRID_HOME}/bin/srvctl config database -v > /dev/null
if [ $? -ne 0 ]; then
  echo "error: srvctl config database -v command is not ok"
  ${GRID_HOME}/bin/srvctl config database -v
  echo ""
else
    # Loop for each database registered in CRS
    while IFS= read -r db_config ; do
        # If no database is registered in CRS, warn and exit loop
        if [ "${db_config}" = "No databases are configured" ]; then
            echo -e "warning: No databases are configured in crs\n"
        else
            # Prepare database variables
            ORACLE_SID=""
            local_instance=""
            db_printed=false
            db_unique_name="`echo $db_config | awk '{print $1}'`"
            db_oracle_home="`echo $db_config | awk '{print $2}'`"
            db_version="`echo $db_config | awk '{print $3}'`"
            db_type=""
            # Set ORACLE_HOME for this database
            ORACLE_HOME="${db_oracle_home}"
            # Array to hold instance status strings
            a_instances=()

            # Compute version major/minor from srvctl config output (available before any sqlplus call)
            db_ver_major=$(echo "$db_version" | awk -F. '{print $1+0}')
            db_ver_minor=$(echo "$db_version"  | awk -F. '{print $2+0}')

            # --- Fast pre-filter: skip expensive srvctl/sqlplus calls for non-matching databases ---
            # When a filter is active and db_unique_name does not already match, we use a cheap
            # single-node instance check + one lightweight sqlplus query to decide early whether
            # this database can contain a match. This avoids the full cluster-wide
            # "srvctl status database -v" and the heavy q_cdb sqlplus call for every non-target DB.
            if [ -n "${filter_db}" ] && [[ "$(echo "${db_unique_name}" | tr '[:lower:]' '[:upper:]')" != ${filter_db} ]]; then
                # Fast local instance check (queries local CRS agent only, not all nodes)
                inst_line=$(${ORACLE_HOME}/bin/srvctl status instance -d "${db_unique_name}" -n "${current_dbnode}" 2>/dev/null)
                if ! echo "${inst_line}" | grep -q " is running"; then
                    continue   # local instance is not running — nothing to display, skip
                fi
                # Local instance is running. Extract ORACLE_SID from the status line.
                ORACLE_SID=$(echo "${inst_line}" | awk '{print $2}')
                # Single sqlplus call: check db_name AND matching PDB count together.
                # Oracle 11g has no v$pdbs — always NON-CDB, PDB count is always 0.
                filter_db_sql="${filter_db//\*/\%}"
                if [ "${db_ver_major}" -ge 12 ]; then
                    pre_check=$(echo -e "set head off feed off pages 0 trimout on;\nselect upper(trim(NAME))||'|'||(select count(*) from v\$pdbs where upper(name) like '${filter_db_sql}') from v\$database;" | ${ORACLE_HOME}/bin/sqlplus -s / as sysdba 2>/dev/null | tr -d ' \n')
                else
                    pre_check=$(echo -e "set head off feed off pages 0 trimout on;\nselect upper(trim(NAME))||'|0' from v\$database;" | ${ORACLE_HOME}/bin/sqlplus -s / as sysdba 2>/dev/null | tr -d ' \n')
                fi
                db_name_precheck=$(echo "${pre_check}" | cut -d'|' -f1)
                pdb_cnt_precheck=$(echo "${pre_check}" | cut -d'|' -f2)
                if [[ "${db_name_precheck}" != ${filter_db} ]] && [ "${pdb_cnt_precheck:-0}" -le 0 ] 2>/dev/null; then
                    continue   # neither db_name nor any PDB matches the filter — skip
                fi
            fi
            # --- End fast pre-filter ---

            # Check if srvctl status database command is valid
            ${ORACLE_HOME}/bin/srvctl status database -d ${db_unique_name} >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo "error: srvctl database -d ${db_unique_name} command is not ok"
            else
                # Query CRS for instance status on each node
                while IFS= read -r inst ; do
                    status_inst="`echo ${inst} | awk '/^Instance/ {inst = $2; if ($4 == "not") {status = "\033[31mstopped\033[0m"; printf "%s(%s)\n", inst, status; next} else {status = "unknown"}} /Instance status:/ {if ($0 ~ /Mounted \\(Closed\\)/) {status = "\033[33mmount\033[0m"} else if ($0 ~ /Dismounted/) {status = "\033[33mnomount\033[0m"} else if ($0 ~ /Restricted/) {status = "\033[33mrestricted\033[0m"} else if ($0 ~ /Open/) {status = "\033[32mopen\033[0m"} printf "%s(%s)\n", inst, status}'` "
                    a_instances+=("${status_inst}")

                    sid="`echo ${inst} | grep -w ${current_dbnode} | wc -l`"
                        if [ ${sid} == "1" ]; then
                            # Set ORACLE_SID for the local node instance
                            ORACLE_SID="`echo ${inst} | grep -w ${current_dbnode} | awk '{print $2}'`"
                            # Check if local instance is running and open (or restricted)
                            if [ `echo "$status_inst" | grep -E "open|restricted" | wc -l` == 1 ]; then
                                local_instance="open"
                            fi
                        fi
                done < <(${ORACLE_HOME}/bin/srvctl status database -d ${db_unique_name} -v)
            fi

            # Proceed only if local instance is open
            if [ "${local_instance}" == "open" ]; then
                # Select VERSION_FULL (>=12.2) or VERSION (<12.2) based on db version from srvctl
                if [[ "$db_ver_major" -gt 12 ]] || [[ "$db_ver_major" -eq 12 && "$db_ver_minor" -ge 2 ]]; then
                    version_col="VERSION_FULL"
                else
                    version_col="VERSION"
                fi
                # Run query to retrieve CDB-level information.
                # Oracle 11g: no CDB column in v$database, no v$pdbs — always NON-CDB.
                # Oracle 12c+: use CDB column and v$pdbs for total size.
                if [ "${db_ver_major}" -ge 12 ]; then
                    q_cdb=$(echo -e "set head off feed off lines 300 pages 0;\nselect (select trim(CDB) from v\$database)||'|'||(select replace(trim(DATABASE_ROLE),' ','_') from v\$database)||'|'||(select trim(NAME) from v\$database)||'|'||(select trim(VALUE) from v\$parameter where name='cpu_count')||'|'||(select trim(case when cdb='YES' then (select SUM(ROUND(TOTAL_SIZE/1024/1024/1024,0))||' GB' from v\$pdbs) else (select ROUND(SUM(bytes)/1024/1024/1024,0)||' GB' from dba_data_files) end) from v\$database)||'|'||(select trim(${version_col}) from v\$instance)||'|'||(select trim(case when to_number(value)=0 then '-' else round(to_number(value)/1024/1024/1024,1)||' GB' end) from v\$parameter where name='sga_max_size') as DATA from dual;" | ${ORACLE_HOME}/bin/sqlplus -s / as sysdba)
                else
                    q_cdb=$(echo -e "set head off feed off lines 300 pages 0;\nselect 'NO'||'|'||(select replace(trim(DATABASE_ROLE),' ','_') from v\$database)||'|'||(select trim(NAME) from v\$database)||'|'||(select trim(VALUE) from v\$parameter where name='cpu_count')||'|'||(select ROUND(SUM(bytes)/1024/1024/1024,0)||' GB' from dba_data_files)||'|'||(select trim(VERSION) from v\$instance)||'|'||(select trim(case when to_number(value)=0 then '-' else round(to_number(value)/1024/1024/1024,1)||' GB' end) from v\$parameter where name='sga_max_size') as DATA from dual;" | ${ORACLE_HOME}/bin/sqlplus -s / as sysdba)
                fi
                # Example output: YES|PRIMARY|CDBDEV|8|271 GB|19.21.0.0.0|128 GB

                # Parse query result fields
                db_type=$(echo ${q_cdb} | awk -F "|" '{ print $1 }' | awk '{ if ($1 == "NO") { print "NON-CDB" } else if ($1 == "YES") { print "CDB" } else { print "N/A" } }' )
                db_role=$(echo "${q_cdb}" | awk -F "|" '{ print $2 }' | awk '{print $1}' )
                db_name=$(echo "${q_cdb}" | awk -F "|" '{ print $3 }' | awk '{print $1}' )
                db_cpu_count=$(echo "${q_cdb}" | awk -F "|" '{ print $4 }' | awk '{print $1}' )
                db_cdb_size=$(echo "${q_cdb}" | awk -F "|" '{ print $5 }' | awk '{print $1" "$2}' )
                db_version=$(echo "${q_cdb}" | awk -F "|" '{ print $6 }'  | awk '{print $1 }' )
                db_sga=$(echo "${q_cdb}"    | awk -F "|" '{ print $7 }'  | awk '{print $1" "$2}' )

                # Determine if this database should be shown based on -d filter
                db_should_show=true
                filter_pdb_target=""
                filter_match_cdb=false
                if [ -n "${filter_db}" ]; then
                    db_name_up=$(echo "${db_name}"        | tr '[:lower:]' '[:upper:]')
                    db_uniq_up=$(echo "${db_unique_name}" | tr '[:lower:]' '[:upper:]')
                    if [[ "${db_name_up}" == ${filter_db} ]] || [[ "${db_uniq_up}" == ${filter_db} ]]; then
                        filter_match_cdb=true
                    elif [ "${db_type}" = "CDB" ]; then
                        filter_db_sql="${filter_db//\*/\%}"
                        pdb_cnt=$(echo -e "set head off feed off pages 0 trimout on;\nselect count(*) from v\$pdbs where upper(name) like '${filter_db_sql}';" | ${ORACLE_HOME}/bin/sqlplus -s / as sysdba | tr -d ' \n')
                        if [ "${pdb_cnt:-0}" -gt 0 ] 2>/dev/null; then
                            filter_pdb_target="${filter_db}"
                        else
                            db_should_show=false
                        fi
                    else
                        db_should_show=false
                    fi
                fi

                if [ "${db_should_show}" = "true" ]; then
                filter_found=true
                db_printed=true

                # Print database header info
                printf "%-18s: %-23s %-12s: %s\n" "DB_UNIQUE_NAME"    "${db_unique_name}" "ORACLE_HOME" "${db_oracle_home}"
                printf "%-18s: %-23s %-12s: %s\n" "DB-ROLE (DB-TYPE)" "${db_role} (${db_type})" "VERSION" "${db_version}"

                # Print table top separator
                printf "+%-${col_width_db}s"        "" | tr ' ' '-'
                printf "+%-${col_width_size}s"       "" | tr ' ' '-'
                printf "+%-${col_width_sga}s"        "" | tr ' ' '-'
                printf "+%-${col_width_cpucount}s"   "" | tr ' ' '-'
                for ((i = 0; i < num_dbnodes; i++)); do printf "+%-${col_width_dbnodes}s" "" | tr ' ' '-'; done
                printf "+\n"

                # Print table header row
                printf "|%-${col_width_db}s"        " DB"
                printf "|%-${col_width_size}s"       " SIZE"
                printf "|%-${col_width_sga}s"        " SGA_MAX_SIZE"
                printf "|%-${col_width_cpucount}s"   " CPU_COUNT"
                for ((i = 0; i < num_dbnodes; i++)); do printf "|%-${col_width_dbnodes}s" " ${a_dbnodes[$((i))]}"; done
                printf "|\n"

                # Print table sub-header separator
                printf "+%-${col_width_db}s"        "" | tr ' ' '-'
                printf "+%-${col_width_size}s"       "" | tr ' ' '-'
                printf "+%-${col_width_sga}s"        "" | tr ' ' '-'
                printf "+%-${col_width_cpucount}s"   "" | tr ' ' '-'
                for ((i = 0; i < num_dbnodes; i++)); do printf "+%-${col_width_dbnodes}s" "" | tr ' ' '-'; done
                printf "+\n"

                # Print CDB data row
                if [ "${filter_match_cdb}" = "true" ]; then
                    printf "|%-$((col_width_db + 9))s" " $(printf "\033[32m%s\033[0m" "${db_name}")"
                else
                    printf "|%-${col_width_db}s" " ${db_name}"
                fi
                printf "|%-${col_width_size}s"       "`printf " [%$((internal_width_size + 2))s ]" "${db_cdb_size}"` "
                printf "|%-${col_width_sga}s"        " ${db_sga}"
                printf "|%-${col_width_cpucount}s"   " ${db_cpu_count}"
                for ((i = 0; i < num_dbnodes; i++)); do
                    printf "|%-${color_offset}s" " ${a_instances[$((i))]}"
                done
                printf "|\n"

                # If CDB, also print PDB rows
                if [ "${db_type}" == "CDB" ]; then
                    # Query PDB status for all PDBs in the CDB
                    while IFS= read -r pdb ; do
                        #                       NAME|RESTRICTED|SIZE_GB|CPU_COUNT|SGA|STATUS
                        # Format of line $pdb:  PDB$SEED|NO:NO|1 GB|4|-|1:READ ONLY;2:READ ONLY;
                        a_pdbs_status=()
                        a_pdbs_restricted=()
                        pdb_name="`echo ${pdb} | awk -F "|" '{ print $1 }'`"
                        pdb_restricted=$(echo $pdb | awk -F "|" '{print $2}' | sed 's/[[:space:]]*$//')
                        IFS=':' read -r -a a_pdbs_restricted <<< "$pdb_restricted"
                        pdb_size="`echo ${pdb} | awk -F "|" '{ print $3 }'`"
                        pdb_cpu_count=$(echo $pdb | awk -F "|" '{print $4}')
                        pdb_sga=$(echo $pdb | awk -F "|" '{print $5}' | awk '{print $1" "$2}')
                        pdb_status=$(echo $pdb | awk -F "|" '{print $6}'| sed 's/[[:space:]]*$//' )
                        IFS=';' read -r -a a_pdbs_status <<< "$pdb_status"

                        # Print PDB row
                        pdb_name_up=$(echo "${pdb_name}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')
                        if [ -n "${filter_pdb_target}" ] && [[ "${pdb_name_up}" == ${filter_pdb_target} ]]; then
                            printf "|%-$((col_width_db + 9))s" " └ $(printf "\033[32m%s\033[0m" "${pdb_name}")"
                        else
                            printf "|%-${col_width_db}s" " └ ${pdb_name}"
                        fi
                        printf "  |%-${col_width_size}s  " "`printf "   └ %${internal_width_size}s" "${pdb_size}"`"
                        printf "|%-${col_width_sga}s"      " ${pdb_sga}"
                        printf "|%-${col_width_cpucount}s" " ${pdb_cpu_count}"

                        # Print per-node open mode, highlighting restricted if applicable
                        for ((i = 1; i <= num_dbnodes; i++)); do
                            f=false
                            for s in "${a_pdbs_status[@]}"; do
                                if [[ "$s" == "$i:"* ]]; then
                                    f=true
                                    v=${s}
                                fi
                            done

                            if [ "$f" = true ]; then
                                pdb_node_status="${v#"$i:"}"
                                if [[ "$pdb_node_status" == *"MOUNTED"* ]]; then
                                    printf "|%-${color_offset}s" "  $(printf "\033[33m%s\033[0m" "${pdb_node_status}")"
                                elif [[ "$pdb_node_status" == *"RESTRICTED"* ]]; then
                                    base_status="${pdb_node_status%,RESTRICTED}"
                                    printf "|%-${color_offset}s" "  ${base_status}($(printf "\033[33m%s\033[0m" "restricted"))"
                                else
                                    printf "|%-${col_width_dbnodes}s" "  ${pdb_node_status}"
                                fi
                            else
                                printf "|%-${col_width_dbnodes}s" " -"
                            fi
                        done
                        printf "|\n"

                        # Increment PDB counter
                        ((sum_pdbs++))

                    done < <(echo -e """set head off feed off lines 300 pages 0 colsep |;\ncol NAME for a50;\ncol STATUS for a50;\ncol CPU_COUNT for a10;\ncol SGA for a14;\nselect p.name,nvl(max(p.restricted),'no') as res,round(max(p.total_size)/1024/1024/1024,0)||' GB' as SIZE_GB,nvl((select sp.value from v\$system_parameter sp where sp.con_id=p.con_id and sp.name='cpu_count'),'-') as CPU_COUNT,nvl((select trim(case when to_number(sp2.value)=0 then '-' else round(to_number(sp2.value)/1024/1024/1024,1)||' GB' end) from v\$system_parameter sp2 where sp2.con_id=p.con_id and sp2.name='sga_max_size'),'-') as SGA,listagg(p.inst_id||':'||p.open_mode||case when p.restricted='YES' then ',RESTRICTED' else '' end,';') within group (order by p.inst_id)||';' as STATUS from gv\$pdbs p group by name,con_id order by con_id,name;""" | ${ORACLE_HOME}/bin/sqlplus -s / as sysdba)
                fi

                # Print table bottom separator
                printf "+%-${col_width_db}s"        "" | tr ' ' '-'
                printf "+%-${col_width_size}s"       "" | tr ' ' '-'
                printf "+%-${col_width_sga}s"        "" | tr ' ' '-'
                printf "+%-${col_width_cpucount}s"   "" | tr ' ' '-'
                for ((i = 0; i < num_dbnodes; i++)); do printf "+%-${col_width_dbnodes}s" "" | tr ' ' '-'; done
                printf "+\n"

                # Accumulate totals
                ((sum_cdbs++))
                db_size_num=$(echo "${db_cdb_size}" | awk 'NF>0{print ($1+0); exit}')
                sum_size_gb=$((sum_size_gb + ${db_size_num:-0}))

                fi # end if db_should_show

            # Local instance is not running
            ## BUG: when database instance is not running, all PDB status should show N/A
            else
                db_uniq_up=$(echo "${db_unique_name}" | tr '[:lower:]' '[:upper:]')
                if [ -z "${filter_db}" ] || [[ "${db_uniq_up}" == ${filter_db} ]]; then
                    [ -n "${filter_db}" ] && filter_found=true
                    db_printed=true
                    # Print database header info with unknown role
                    printf "%-18s: %-23s %-12s: %s\n" "DB_UNIQUE_NAME"    "${db_unique_name}" "ORACLE_HOME" "${db_oracle_home}"
                    printf "%-18s: %-23s %-12s: %s\n" "DB-ROLE (DB-TYPE)" "?" "VERSION" "${db_version}"

                    single_line=$(printf "+%$((header_chars - 2))s+" "" | tr ' ' '-')
                    inner_width=$((header_chars - 2))
                    printf "%s\n" "${single_line}"
                    printf "|%-$((inner_width + 9))s|\n" " warning: local_instance ORACLE_SID: ${ORACLE_SID} is $(printf "\033[31mstopped\033[0m") or not configured in local_node for database"
                    printf "%s\n" "${single_line}"
                    while IFS= read -r inst_line_out; do
                        printf "|%-${inner_width}s|\n" " ${inst_line_out}"
                    done < <(${ORACLE_HOME}/bin/srvctl status database -d ${db_unique_name})
                    printf "%s\n" "${single_line}"

                fi # end if filter check for stopped instance

            fi

        fi
        [ "${db_printed}" = "true" ] && echo ""
    done < <(${GRID_HOME}/bin/srvctl config database -v )
fi

# Warn if -d filter produced no results
if [ -n "${filter_db}" ] && [ "${filter_found}" = "false" ]; then
    echo -e "warning: '${filter_db}' not found as NON-CDB, CDB or PDB in this cluster (or local instance is not open)\n"
fi

# Print totals summary
echo -e "Totals (CDBs:${sum_cdbs}  PDBs:${sum_pdbs}  Size:${sum_size_gb} GB)\n "

# Print end info
printf "%${header_chars}s\n" | tr ' ' '='
echo -e "Finished on `date '+%d-%^b-%Y %H:%M:%S'` - elapsed ${SECONDS}s\t"
printf "%${header_chars}s\n\n" | tr ' ' '='

exit 0
