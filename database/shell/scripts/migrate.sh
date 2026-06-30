#!/bin/bash

SCRIPT_VERSION="2.0.0"
SCHEMA_VERSION=1

ENV_FILE=".env"
_ENV_EXPLICIT=false
for _arg in "$@"; do
    case "$_arg" in
        --env=*) ENV_FILE="${_arg#*=}" ; _ENV_EXPLICIT=true ;;
    esac
done
unset _arg
if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
elif [ "$_ENV_EXPLICIT" = true ]; then
    printf "env file not found: %s\n" "$ENV_FILE" 1>&2
    exit 1
fi
unset _ENV_EXPLICIT

PGPORT=${PGPORT:-5432}
PGUSER=${PGUSER:-}
PGPASSWORD=${PGPASSWORD:-}
PGDATABASE=${PGDATABASE:-}
DB_DIR=${DB_DIR:-"/database"}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$MIGRATE_SCHEMA" ]; then
    STEPS_FILE="$MIGRATE_SCHEMA"
elif [ -f "$SCRIPT_DIR/migrate.yml" ]; then
    STEPS_FILE="$SCRIPT_DIR/migrate.yml"
else
    STEPS_FILE="$SCRIPT_DIR/migrate.yml"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

W=64

DRY_RUN=false
APPLY=false
REVERT=false
TAG=false
HELP=false
FORCE=false

STEP_NAMES=()
STEP_TYPES=()
STEP_SLUGS=()
STEP_SCHEMAS=()
STEP_CONDITIONS=()
STEP_INCLUDES=()
STEP_EXCLUDES=()
STEP_VARS=()

FILENAME_GRAMMAR='^V[1-9][0-9]*(\.[0-9]+)*__[a-z0-9]+_[a-z0-9_]+\.sql$'

function hr() {
    local char="${1:-─}"
    local color="${2:-$GRAY}"
    printf "${color}"
    for ((i=0; i<W; i++)); do printf "%s" "$char"; done
    printf "${NC}\n"
}

function header() {
    local text="$1"
    local color="${2:-$CYAN}"
    local len=${#text}
    local pad=$(( (W - len - 2) / 2 ))
    [ $pad -lt 0 ] && pad=0
    local left="" right=""
    for ((i=0; i<pad; i++)); do left="${left}━"; done
    local right_pad=$(( W - len - 2 - pad ))
    for ((i=0; i<right_pad; i++)); do right="${right}━"; done
    printf "\n  ${color}${left} ${BOLD}%s${NC}${color} ${right}${NC}\n" "$text"
}

function subheader() {
    local text="$1"
    local len=${#text}
    local pad=$(( (W - len - 2) / 2 ))
    [ $pad -lt 0 ] && pad=0
    local left="" right=""
    for ((i=0; i<pad; i++)); do left="${left}─"; done
    local right_pad=$(( W - len - 2 - pad ))
    for ((i=0; i<right_pad; i++)); do right="${right}─"; done
    printf "${GRAY}${left} ${CYAN}%s${NC}${GRAY} ${right}${NC}\n" "$text"
}

function success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
function warn()    { printf "   ${YELLOW}- %s${NC}\n" "$1"; }
function fail()    { printf "   ${RED}- %s${NC}\n" "$1"; }
function info()    { printf "${GRAY}·${NC} %s\n" "$1"; }
function skip()    { printf "${GRAY}○ %s${NC}\n" "$1"; }

function require_db() {
    local missing=""
    [ -z "$PGUSER" ] && missing+="PGUSER "
    [ -z "$PGPASSWORD" ] && missing+="PGPASSWORD "
    [ -z "$PGDATABASE" ] && missing+="PGDATABASE "
    if [ -n "$missing" ]; then
        printf "${RED}Missing required database configuration: ${WHITE}%s${NC}\n" "$missing"
        printf "${GRAY}Set via environment variables or flags${NC}\n"
        exit 1
    fi
}

function detect_dep() {
    command -v "$1" &> /dev/null
}

function detect_pkg_manager() {
    if detect_dep brew; then echo "brew"
    elif detect_dep apk; then echo "apk"
    elif detect_dep apt-get; then echo "apt"
    elif detect_dep dnf; then echo "dnf"
    elif detect_dep yum; then echo "yum"
    elif detect_dep pacman; then echo "pacman"
    else echo "unknown"
    fi
}

function install_dep() {
    local dep="$1"
    local pkg_manager=$(detect_pkg_manager)

    case "$pkg_manager" in
        brew)    brew install "$dep" ;;
        apk)     apk add --no-cache "$dep" ;;
        apt)     apt-get install -y "$dep" ;;
        dnf)     dnf install -y "$dep" ;;
        yum)     yum install -y "$dep" ;;
        pacman)  pacman -S --noconfirm "$dep" ;;
        *)
            printf "${RED}Cannot auto install %s. Unknown package manager.${NC}\n" "$dep"
            return 1
            ;;
    esac
}

function ensure_deps() {
    local missing=0

    if ! detect_dep yq; then
        printf "${YELLOW}yq not found, installing...${NC}\n"
        if ! install_dep yq; then
            missing=1
        fi
    fi

    if ! detect_dep psql; then
        printf "${YELLOW}psql not found, installing...${NC}\n"
        local pkg_manager=$(detect_pkg_manager)
        case "$pkg_manager" in
            brew)    brew install libpq && brew link --force libpq ;;
            apk)     apk add --no-cache postgresql-client ;;
            apt)     apt-get install -y postgresql-client ;;
            dnf)     dnf install -y postgresql ;;
            *)       install_dep postgresql-client ;;
        esac
        if ! detect_dep psql; then
            missing=1
        fi
    fi

    if ! detect_dep shasum && ! detect_dep sha256sum; then
        printf "${YELLOW}sha256 hasher not found${NC}\n"
        missing=1
    fi

    if [ "$missing" -gt 0 ]; then
        printf "${RED}Missing required dependencies. Cannot continue.${NC}\n"
        exit 1
    fi
}

function file_sha256() {
    if detect_dep sha256sum; then
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    else
        shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    fi
}

function file_size() {
    local s=""
    s=$(stat -c%s "$1" 2>/dev/null)
    if [ -z "$s" ]; then
        s=$(stat -f%z "$1" 2>/dev/null)
    fi
    if [ -z "$s" ]; then
        s=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
    fi
    [ -z "$s" ] && s=0
    printf "%s" "$s"
}

function now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

function now_timestamp() {
    date -u +"%Y%m%dT%H%M%SZ"
}

function sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

function show_help_root() {
    cat << 'EOF'

  ███╗   ███╗██╗ ██████╗ ██████╗  █████╗ ████████╗███████╗
  ████╗ ████║██║██╔════╝ ██╔══██╗██╔══██╗╚══██╔══╝██╔════╝
  ██╔████╔██║██║██║  ███╗██████╔╝███████║   ██║   █████╗
  ██║╚██╔╝██║██║██║   ██║██╔══██╗██╔══██║   ██║   ██╔══╝
  ██║ ╚═╝ ██║██║╚██████╔╝██║  ██║██║  ██║   ██║   ███████╗
  ╚═╝     ╚═╝╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝
                    Samna© 2026

EOF

    printf "${BOLD}Script version:${NC} %s   ${BOLD}Schema version:${NC} %s\n" "$SCRIPT_VERSION" "$SCHEMA_VERSION"
    echo ""
    printf "${BOLD}Usage:${NC} migrate.sh <command> [target] [flags]\n"
    echo ""
    printf "${BOLD}Commands:${NC}\n"
    printf "  ${CYAN}up${NC} [target]           Apply pending migrations after preflight\n"
    printf "  ${CYAN}check${NC}                 Run preflight scan only, no SQL executed\n"
    printf "  ${CYAN}state${NC} [step]          Dump live SQL of every non seed step\n"
    printf "  ${CYAN}merge${NC}                 Rebase local files into .upgraded/ from live DB\n"
    printf "  ${CYAN}merge --apply${NC}         Promote .upgraded/ into source tree\n"
    printf "  ${CYAN}merge --apply --tag${NC}   Same as apply plus annotated git tag at HEAD\n"
    printf "  ${CYAN}merge --revert${NC} [n]    Restore a prior .migrate-<n>/ snapshot\n"
    printf "  ${CYAN}upgrade${NC}               Evolve samna_migrate schema to SCHEMA_VERSION\n"
    printf "  ${CYAN}list${NC}                  List every step and file with stats\n"
    printf "  ${CYAN}doctor${NC} [target]       Scan SQL files for dangerous patterns\n"
    printf "  ${CYAN}schema${NC}                Show resolved plan or create template\n"
    printf "  ${CYAN}stat${NC}                  Show migration state and history\n"
    printf "  ${CYAN}delete${NC}                Drop the samna_migrate schema\n"
    printf "  ${CYAN}help${NC} [command]        Show help, root or per command\n"
    echo ""
    printf "${BOLD}Flags:${NC}\n"
    printf "  ${DIM}--pghost=HOST              PGHOST${NC}\n"
    printf "  ${DIM}--pgport=PORT              PGPORT${NC}\n"
    printf "  ${DIM}--pguser=USER              PGUSER${NC}\n"
    printf "  ${DIM}--pgpassword=PASS          PGPASSWORD${NC}\n"
    printf "  ${DIM}--pgdatabase=DB            PGDATABASE${NC}\n"
    printf "  ${DIM}--pgsslmode=MODE           PGSSLMODE${NC}\n"
    printf "  ${DIM}--schema=FILE              Schema file${NC}\n"
    printf "  ${DIM}--env=FILE                 Env file to source (default .env)${NC}\n"
    printf "  ${DIM}--dry-run                  Plan only, no writes${NC}\n"
    printf "  ${DIM}--apply                    Promote .upgraded/ during merge${NC}\n"
    printf "  ${DIM}--revert                   Restore prior .migrate-<n>/ snapshot${NC}\n"
    printf "  ${DIM}--tag                      Create git annotated tag during apply${NC}\n"
    printf "  ${DIM}--force                    Skip safety checks where supported${NC}\n"
    printf "  ${DIM}--help, -h                 Show help${NC}\n"
    echo ""
    printf "${BOLD}Step types in migrate.yml:${NC}\n"
    printf "  ${WHITE}base${NC}        Declarative, idempotent. Drift logged not fatal.\n"
    printf "  ${WHITE}migration${NC}   Append only. Hash locked. Drift fatal.\n"
    printf "  ${WHITE}seed${NC}        Data only. Skipped by state and merge intake.\n"
    echo ""
    printf "${BOLD}Filename grammar inside migration steps:${NC}\n"
    printf "  ${WHITE}V<num>(.<num>)*__{slug}_{name}.sql${NC}\n"
    echo ""
    printf "${BOLD}Storage tables in samna_migrate schema:${NC}\n"
    printf "  ${WHITE}file${NC}      Current truth per source file with state pending applied folded\n"
    printf "  ${WHITE}history${NC}   Append only attempt log foreign keyed to file.id\n"
    printf "  ${WHITE}state${NC}     Single row with tool_version, schema_version, run pointers\n"
    echo ""
    printf "${BOLD}Boot order on every command:${NC}\n"
    printf "  1. Ensure samna_migrate schema exists\n"
    printf "  2. Compare samna_migrate.state.schema_version to SCHEMA_VERSION\n"
    printf "  3. If behind, demand upgrade. If ahead, refuse.\n"
    printf "  4. Run command preflight if applicable\n"
    echo ""
    printf "${BOLD}Rebase workflow:${NC}\n"
    printf "  1. up                   Bring DB to head\n"
    printf "  2. merge                Write .upgraded/ from live DB and source files\n"
    printf "  3. inspect .upgraded/   Review the rewritten tree\n"
    printf "  4. merge --apply        Snapshot to .migrate-<ts>/ and move .upgraded/ in\n"
    printf "  5. commit and deploy    Source tree now matches live DB\n"
    printf "  6. merge --revert [n]   Restore a prior .migrate-<n>/ if needed\n"
    echo ""
}

function show_help_up() {
    printf "\n${BOLD}up${NC} [target]\n"
    printf "  Apply pending migrations after preflight. Walks steps in YAML order,\n"
    printf "  files in V order. Aborts on tampered or missing applied files.\n"
    echo ""
}

function show_help_check() {
    printf "\n${BOLD}check${NC}\n"
    printf "  Preflight only. Computes sha256 of every disk file, compares to\n"
    printf "  samna_migrate.file. Exits non zero on tampered or missing migration\n"
    printf "  files. Never opens a write connection.\n"
    echo ""
}

function show_help_state() {
    printf "\n${BOLD}state${NC} [step]\n"
    printf "  Dump live SQL per non seed step. Object classes covered: tables,\n"
    printf "  views, indexes, constraints, enums, functions, triggers, sequences.\n"
    printf "  Grants, comments, policies, extensions, default privileges, and\n"
    printf "  sequence ownership are emitted only when the source SQL declares them.\n"
    echo ""
}

function show_help_merge() {
    printf "\n${BOLD}merge${NC}\n"
    printf "  Two pass rebase. Pass one writes live SQL of every base and seed\n"
    printf "  file into .upgraded/. Pass two routes migration files into base\n"
    printf "  folders via a regex identifier registry built off the source SQL.\n"
    printf "  Source tree and database untouched.\n"
    echo ""
    printf "${BOLD}merge --apply${NC} [--tag] [--force]\n"
    printf "  Snapshot current source tree into .migrate-<ts>-<sha8>/, move files\n"
    printf "  out of .upgraded/ into the source tree, reconcile samna_migrate.file\n"
    printf "  rows. --tag adds an annotated git tag at HEAD before the swap.\n"
    echo ""
    printf "${BOLD}merge --revert${NC} [name] [--force]\n"
    printf "  Restore files from .migrate-<name>/ back into the source tree. Without\n"
    printf "  name, picks the most recent .migrate-* by mtime. Snapshots the current\n"
    printf "  tree first so the revert itself is reversible.\n"
    echo ""
}

function show_help_upgrade() {
    printf "\n${BOLD}upgrade${NC} [--force]\n"
    printf "  Evolve samna_migrate.* tables to current SCHEMA_VERSION. Idempotent.\n"
    printf "  Refuses to touch application schema. Stamps schema_version and\n"
    printf "  tool_version on samna_migrate.state. With --force, resets the stored\n"
    printf "  schema_version to 0 and re-runs every upgrade step even if the DB is\n"
    printf "  already at the current version.\n"
    echo ""
}

function show_help_list() {
    printf "\n${BOLD}list${NC}\n"
    printf "  Table of every step and file with line counts and object counts.\n"
    echo ""
}

function show_help_doctor() {
    printf "\n${BOLD}doctor${NC} [target]\n"
    printf "  Scan SQL files for unsafe patterns. Reports critical issues and\n"
    printf "  warnings without applying anything.\n"
    echo ""
}

function show_help_schema() {
    printf "\n${BOLD}schema${NC}\n"
    printf "  Show the resolved execution plan from migrate.yml. Creates a\n"
    printf "  template when no migrate.yml is found.\n"
    echo ""
}

function show_help_stat() {
    printf "\n${BOLD}stat${NC}\n"
    printf "  Show samna_migrate.state and samna_migrate.history rows.\n"
    echo ""
}

function show_help_delete() {
    printf "\n${BOLD}delete${NC}\n"
    printf "  Drop the samna_migrate schema and all migration history.\n"
    printf "  Asks for confirmation before running DROP SCHEMA CASCADE.\n"
    echo ""
}

function show_help() {
    local cmd="${1:-}"
    case "$cmd" in
        up)             show_help_up ;;
        check)          show_help_check ;;
        state)          show_help_state ;;
        merge)          show_help_merge ;;
        upgrade)        show_help_upgrade ;;
        list)           show_help_list ;;
        doctor)         show_help_doctor ;;
        schema)         show_help_schema ;;
        stat)           show_help_stat ;;
        delete)         show_help_delete ;;
        *)              show_help_root ;;
    esac
}

function parse_flags() {
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --pghost=*)     PGHOST="${arg#*=}" ;;
            --pgport=*)     PGPORT="${arg#*=}" ;;
            --pguser=*)     PGUSER="${arg#*=}" ;;
            --pgpassword=*) PGPASSWORD="${arg#*=}" ;;
            --pgdatabase=*) PGDATABASE="${arg#*=}" ;;
            --pgsslmode=*)  PGSSLMODE="${arg#*=}" ;;
            --schema=*)     MIGRATE_SCHEMA="${arg#*=}" ; STEPS_FILE="$MIGRATE_SCHEMA" ;;
            --steps=*)      STEPS_FILE="${arg#*=}" ;;
            --env=*)        ;;
            --dry-run)      DRY_RUN=true ;;
            --apply)        APPLY=true ;;
            --revert)       REVERT=true ;;
            --tag)          TAG=true ;;
            --force)        FORCE=true ;;
            --help|-h)      HELP=true ;;
            *)              args+=("$arg") ;;
        esac
    done
    ARGS=("${args[@]}")
}

function eval_condition() {
    local condition="$1"
    if [ -z "$condition" ] || [ "$condition" = "null" ]; then
        return 0
    fi
    eval "$condition" 2>/dev/null
    return $?
}

function psql_base_args() {
    local args=(--username "$PGUSER" --dbname "$PGDATABASE")
    [ -n "$PGHOST" ] && args=(--host "$PGHOST" "${args[@]}")
    [ -n "$PGPORT" ] && args=(--port "$PGPORT" "${args[@]}")
    printf '%s\n' "${args[@]}"
}

function run_psql_cmd() {
    local sql="$1"
    local psql_args=()
    while IFS= read -r a; do psql_args+=("$a"); done < <(psql_base_args)
    psql_args+=(-tAc "$sql")
    PGPASSWORD="$PGPASSWORD" psql "${psql_args[@]}" 2>/dev/null
}

function run_psql_query() {
    local sql="$1"
    local psql_args=()
    while IFS= read -r a; do psql_args+=("$a"); done < <(psql_base_args)
    psql_args+=(-tA -F'|' -c "$sql")
    PGPASSWORD="$PGPASSWORD" psql "${psql_args[@]}" 2>/dev/null
}

function run_psql_cmd_strict() {
    local sql="$1"
    local label="${2:-psql command}"
    local psql_args=()
    while IFS= read -r a; do psql_args+=("$a"); done < <(psql_base_args)
    psql_args+=(--set ON_ERROR_STOP=1 -tAc "$sql")
    local out
    if ! out=$(PGPASSWORD="$PGPASSWORD" psql "${psql_args[@]}" 2>&1); then
        echo ""
        printf "${RED}${BOLD}aborted${NC} ${GRAY}(%s)${NC}\n" "$label"
        printf "${RED}%s${NC}\n" "$out"
        exit 1
    fi
    printf '%s' "$out"
}

function run_psql_file() {
    local file="$1"
    local psql_args=()
    while IFS= read -r a; do psql_args+=("$a"); done < <(psql_base_args)
    psql_args+=(--quiet --set ON_ERROR_STOP=1 -f "$file")
    PGPASSWORD="$PGPASSWORD" psql "${psql_args[@]}"
}

function ensure_migrate_schema() {
    run_psql_cmd "CREATE SCHEMA IF NOT EXISTS samna_migrate" > /dev/null
    run_psql_cmd "CREATE TABLE IF NOT EXISTS samna_migrate.state (
        id INTEGER PRIMARY KEY,
        version TEXT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )" > /dev/null
    run_psql_cmd "INSERT INTO samna_migrate.state (id) VALUES (1) ON CONFLICT (id) DO NOTHING" > /dev/null
}

function column_exists() {
    local schema="$1"
    local table="$2"
    local column="$3"
    local r=$(run_psql_cmd "SELECT 1 FROM information_schema.columns WHERE table_schema='$schema' AND table_name='$table' AND column_name='$column'")
    [ "$r" = "1" ]
}

function get_schema_version() {
    if ! column_exists samna_migrate state schema_version; then
        echo "0"
        return
    fi
    local v=$(run_psql_cmd "SELECT schema_version FROM samna_migrate.state WHERE id = 1")
    echo "${v:-0}"
}

function set_schema_version() {
    local v="$1"
    run_psql_cmd "UPDATE samna_migrate.state SET schema_version = $v, tool_version = '$(sql_escape "$SCRIPT_VERSION")', updated_at = NOW() WHERE id = 1" > /dev/null
}

function upgrade_to_1() {
    info "ensuring samna_migrate.state columns"
    run_psql_cmd_strict "ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS schema_version INTEGER NOT NULL DEFAULT 0" "state.schema_version" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS tool_version TEXT" "state.tool_version" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_run_at TIMESTAMPTZ" "state.last_run_at" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_run_status TEXT" "state.last_run_status" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_run_command TEXT" "state.last_run_command" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.state ADD COLUMN IF NOT EXISTS last_run_duration_ms INTEGER" "state.last_run_duration_ms" > /dev/null
    run_psql_cmd "ALTER TABLE samna_migrate.state ALTER COLUMN version DROP NOT NULL" > /dev/null 2>&1 || true

    info "ensuring samna_migrate.history table"
    run_psql_cmd_strict "CREATE TABLE IF NOT EXISTS samna_migrate.history (
        id SERIAL PRIMARY KEY,
        step_name TEXT,
        file_path TEXT NOT NULL,
        sha256 TEXT,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        duration_ms INTEGER NOT NULL DEFAULT 0,
        success BOOLEAN NOT NULL DEFAULT true
    )" "history table" > /dev/null

    info "ensuring samna_migrate.history columns"
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS file_id INTEGER" "history.file_id" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS step_name TEXT" "history.step_name" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS step_type TEXT" "history.step_type" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS slug TEXT" "history.slug" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS version TEXT" "history.version" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS file_name TEXT" "history.file_name" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS sha256 TEXT" "history.sha256" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS size_bytes INTEGER" "history.size_bytes" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS attempt INTEGER NOT NULL DEFAULT 1" "history.attempt" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS action_type TEXT NOT NULL DEFAULT 'apply'" "history.action_type" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS tool_version TEXT" "history.tool_version" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS schema_yaml_checksum TEXT" "history.schema_yaml_checksum" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS executed_by TEXT" "history.executed_by" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS host TEXT" "history.host" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS database TEXT" "history.database" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS error_sqlstate TEXT" "history.error_sqlstate" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS error_message TEXT" "history.error_message" > /dev/null
    run_psql_cmd_strict "ALTER TABLE samna_migrate.history ADD COLUMN IF NOT EXISTS notes TEXT" "history.notes" > /dev/null

    if column_exists samna_migrate history step; then
        info "backfilling samna_migrate.history.step_name"
        run_psql_cmd_strict "UPDATE samna_migrate.history SET step_name = step WHERE step_name IS NULL AND step IS NOT NULL" "history.step_name backfill" > /dev/null
    fi
    if column_exists samna_migrate history checksum; then
        info "backfilling samna_migrate.history.sha256"
        run_psql_cmd_strict "UPDATE samna_migrate.history SET sha256 = checksum WHERE sha256 IS NULL AND checksum IS NOT NULL" "history.sha256 backfill" > /dev/null
    fi

    info "ensuring samna_migrate.file table"
    run_psql_cmd_strict "CREATE TABLE IF NOT EXISTS samna_migrate.file (
        id SERIAL PRIMARY KEY,
        step_name TEXT NOT NULL,
        step_type TEXT NOT NULL,
        step_yaml_path TEXT,
        slug TEXT NOT NULL,
        version TEXT,
        file_name TEXT NOT NULL,
        file_path TEXT NOT NULL UNIQUE,
        sha256 TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('pending','applied','folded')),
        first_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        discovered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        last_applied_at TIMESTAMPTZ,
        last_applied_history_id INTEGER,
        last_attempt_status TEXT,
        attempts_count INTEGER NOT NULL DEFAULT 0,
        last_drift_sha256 TEXT,
        last_drift_at TIMESTAMPTZ,
        folded_at TIMESTAMPTZ,
        folded_into TEXT,
        removed_from_disk_at TIMESTAMPTZ
    )" "file table" > /dev/null

    info "seeding samna_migrate.file from successful history"
    local seeded=$(run_psql_cmd_strict "
        WITH ins AS (
            INSERT INTO samna_migrate.file (step_name, step_type, slug, file_name, file_path, sha256, size_bytes, state, first_seen, discovered_at, last_applied_at)
            SELECT
                COALESCE(MAX(step_name), 'Unknown'),
                'unknown',
                'unknown',
                split_part(file_path, '/', 2),
                file_path,
                COALESCE(MAX(sha256), 'unknown'),
                0,
                'applied',
                MIN(applied_at),
                MIN(applied_at),
                MAX(applied_at)
            FROM samna_migrate.history
            WHERE success = true AND file_path IS NOT NULL
            GROUP BY file_path
            ON CONFLICT (file_path) DO NOTHING
            RETURNING id
        )
        SELECT count(*) FROM ins
    " "file seed from history")
    if [ -n "$seeded" ] && [ "$seeded" -gt 0 ] 2>/dev/null; then
        success "seeded $seeded file row(s) from history"
    else
        info "no new file rows to seed"
    fi

    info "promoting pending file rows that match successful history"
    local promoted=$(run_psql_cmd_strict "
        WITH upd AS (
            UPDATE samna_migrate.file f
            SET state                   = 'applied',
                last_applied_at         = h.max_applied_at,
                last_applied_history_id = h.last_id,
                last_attempt_status     = 'success'
            FROM (
                SELECT file_path,
                       MAX(applied_at) AS max_applied_at,
                       MAX(id)         AS last_id,
                       MAX(sha256)     AS sha
                FROM samna_migrate.history
                WHERE success = true
                  AND action_type = 'apply'
                  AND file_path IS NOT NULL
                GROUP BY file_path
            ) h
            WHERE f.file_path = h.file_path
              AND f.state     = 'pending'
              AND f.sha256    = h.sha
            RETURNING f.id
        )
        SELECT count(*) FROM upd
    " "promote pending rows from history")
    if [ -n "$promoted" ] && [ "$promoted" -gt 0 ] 2>/dev/null; then
        success "promoted $promoted pending row(s) to applied"
    else
        info "no pending rows matched successful history"
    fi

    run_psql_cmd "ALTER TABLE samna_migrate.history ADD CONSTRAINT history_file_id_fkey FOREIGN KEY (file_id) REFERENCES samna_migrate.file(id)" > /dev/null 2>&1 || true

    info "ensuring indexes on samna_migrate.history and samna_migrate.file"
    run_psql_cmd_strict "CREATE INDEX IF NOT EXISTS history_file_id_idx ON samna_migrate.history(file_id)" "history.file_id index" > /dev/null
    run_psql_cmd_strict "CREATE INDEX IF NOT EXISTS history_applied_at_idx ON samna_migrate.history(applied_at DESC)" "history.applied_at index" > /dev/null
    run_psql_cmd_strict "CREATE INDEX IF NOT EXISTS file_state_idx ON samna_migrate.file(state)" "file.state index" > /dev/null
    run_psql_cmd_strict "CREATE INDEX IF NOT EXISTS file_slug_idx ON samna_migrate.file(slug)" "file.slug index" > /dev/null

    if [ "${#STEP_NAMES[@]}" -eq 0 ]; then
        load_steps
    fi
    local disk_index=""
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local step_type=$(echo "$entry" | cut -d'|' -f3)
        local step_slug=$(echo "$entry" | cut -d'|' -f4)
        local condition=$(echo "$entry" | cut -d'|' -f6)
        local filepath=$(echo "$entry" | cut -d'|' -f7)
        if ! eval_condition "$condition"; then
            continue
        fi
        local base=$(basename "$filepath")
        local dir=$(basename "$(dirname "$filepath")")
        local file_id="${dir}/${base}"
        local sha=$(file_sha256 "$filepath")
        local size=$(file_size "$filepath")
        disk_index="${disk_index}${file_id}|${sha}|${size}|${step_type}|${step_slug}
"
    done < <(collect_all_files)

    info "reconciling samna_migrate.file sha against disk for applied rows"
    local rebaselined=0
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        local fp=$(echo "$row" | cut -d'|' -f1)
        local stored_sha=$(echo "$row" | cut -d'|' -f2)
        local match=$(printf '%s' "$disk_index" | awk -F'|' -v key="$fp" '$1==key {print $2"|"$3"|"$4"|"$5; exit}')
        [ -z "$match" ] && continue
        local new_sha=$(echo "$match" | cut -d'|' -f1)
        local new_size=$(echo "$match" | cut -d'|' -f2)
        local new_step_type=$(echo "$match" | cut -d'|' -f3)
        local new_slug=$(echo "$match" | cut -d'|' -f4)
        [ -z "$new_size" ] && new_size=0
        [ -z "$new_step_type" ] && new_step_type="base"
        [ -z "$new_slug" ] && new_slug="$new_step_type"
        [ "$stored_sha" = "$new_sha" ] && continue
        run_psql_cmd_strict "UPDATE samna_migrate.file SET sha256 = '$(sql_escape "$new_sha")', size_bytes = ${new_size}, step_type = '$(sql_escape "$new_step_type")', slug = '$(sql_escape "$new_slug")', last_drift_sha256 = NULL, last_drift_at = NULL WHERE file_path = '$(sql_escape "$fp")'" "rebaseline sha for $fp" > /dev/null
        local from_short=$(printf "%s" "$stored_sha" | cut -c1-12)
        local to_short=$(printf "%s" "$new_sha" | cut -c1-12)
        run_psql_cmd_strict "INSERT INTO samna_migrate.history (step_name, file_path, action_type, sha256, tool_version, executed_by, host, database, duration_ms, success, notes) VALUES ('upgrade', '$(sql_escape "$fp")', 'upgrade_rebaseline', '$(sql_escape "$new_sha")', '$(sql_escape "$SCRIPT_VERSION")', '$(sql_escape "$PGUSER")', '$(sql_escape "${PGHOST:-localhost}")', '$(sql_escape "$PGDATABASE")', 0, true, 'from=${from_short} to=${to_short}')" "rebaseline history row for $fp" > /dev/null
        printf "${GRAY}  rebaselined ${WHITE}%s${NC} ${GRAY}%s -> %s${NC}\n" "$fp" "$from_short" "$to_short"
        rebaselined=$((rebaselined + 1))
    done < <(run_psql_query "SELECT file_path, sha256 FROM samna_migrate.file WHERE state = 'applied'")

    if [ "$rebaselined" -gt 0 ]; then
        success "rebaselined $rebaselined sha row(s) to current disk content"
    else
        info "no sha drift to reconcile"
    fi
}

function boot_check() {
    require_db
    ensure_migrate_schema
    local current=$(get_schema_version)
    if [ "$current" -gt "$SCHEMA_VERSION" ]; then
        printf "${RED}Database was last touched by a newer migrate.sh${NC}\n"
        printf "${GRAY}DB schema_version=%s, script SCHEMA_VERSION=%s${NC}\n" "$current" "$SCHEMA_VERSION"
        exit 1
    fi
    if [ "$current" -lt "$SCHEMA_VERSION" ]; then
        printf "${GRAY}samna_migrate at v%s, script at v%s, upgrading...${NC}\n" "$current" "$SCHEMA_VERSION"
        local v="$current"
        while [ "$v" -lt "$SCHEMA_VERSION" ]; do
            local next=$((v + 1))
            case "$next" in
                1) upgrade_to_1 ;;
                *) fail "no upgrade step defined for $next" ; exit 1 ;;
            esac
            set_schema_version "$next"
            v="$next"
        done
        printf "${GREEN}samna_migrate now at v%s${NC}\n" "$SCHEMA_VERSION"
    fi
}

function upgrade_command() {
    require_db
    ensure_migrate_schema
    local current=$(get_schema_version)
    if [ "$current" -gt "$SCHEMA_VERSION" ]; then
        printf "${YELLOW}samna_migrate at v%s, script at v%s, resetting to 0 and re-running upgrades...${NC}\n" "$current" "$SCHEMA_VERSION"
        run_psql_cmd "UPDATE samna_migrate.state SET schema_version = 0 WHERE id = 1" > /dev/null
        current=0
    fi
    if [ "$FORCE" = true ] && [ "$current" -ge "$SCHEMA_VERSION" ]; then
        printf "${YELLOW}--force: resetting samna_migrate.state.schema_version from %s to 0 and re-running upgrades${NC}\n" "$current"
        run_psql_cmd "UPDATE samna_migrate.state SET schema_version = 0 WHERE id = 1" > /dev/null
        current=0
    fi
    if [ "$current" -ge "$SCHEMA_VERSION" ]; then
        info "samna_migrate already at version $current"
        return 0
    fi
    header "samna_migrate upgrade" "$CYAN"
    while [ "$current" -lt "$SCHEMA_VERSION" ]; do
        local next=$((current + 1))
        printf "${GRAY}applying upgrade step %s -> %s${NC}\n" "$current" "$next"
        case "$next" in
            1) upgrade_to_1 ;;
            *) fail "no upgrade step defined for $next" ; exit 1 ;;
        esac
        set_schema_version "$next"
        success "samna_migrate now at version $next"
        current="$next"
    done
    echo ""
}

function update_state_run() {
    local cmd="$1"
    local status="$2"
    local dur="$3"
    run_psql_cmd "UPDATE samna_migrate.state SET last_run_at = NOW(), last_run_status = '$(sql_escape "$status")', last_run_command = '$(sql_escape "$cmd")', last_run_duration_ms = $dur, tool_version = '$(sql_escape "$SCRIPT_VERSION")', updated_at = NOW() WHERE id = 1" > /dev/null
}

function version_sort() {
    sed 's/.*V\([0-9]*\)\.\([0-9]*\).*/\1 \2 &/' | sort -k1,1n -k2,2n | awk '{print $3}'
}

function load_steps() {
    if [ ! -f "$STEPS_FILE" ]; then
        echo ""
        fail "Steps file not found: $STEPS_FILE"
        info "Run migrate.sh schema to create a template."
        echo ""
        exit 1
    fi

    local count=$(yq '.steps | length' "$STEPS_FILE")

    for ((i=0; i<count; i++)); do
        local name=$(yq ".steps[$i].name" "$STEPS_FILE")
        local type=$(yq ".steps[$i].type // \"base\"" "$STEPS_FILE")
        local slug=$(yq ".steps[$i].slug // \"\"" "$STEPS_FILE")
        local condition=$(yq ".steps[$i].if // \"\"" "$STEPS_FILE")

        local schemas=""
        local sch_count=$(yq ".steps[$i].schemas | length" "$STEPS_FILE" 2>/dev/null)
        if [ "$sch_count" -gt 0 ] 2>/dev/null; then
            for ((j=0; j<sch_count; j++)); do
                local s=$(yq ".steps[$i].schemas[$j]" "$STEPS_FILE")
                [ -n "$schemas" ] && schemas+=","
                schemas+="$s"
            done
        fi
        [ -z "$schemas" ] && schemas="public"

        local includes=""
        local inc_count=$(yq ".steps[$i].include | length" "$STEPS_FILE" 2>/dev/null)
        if [ "$inc_count" -gt 0 ] 2>/dev/null; then
            for ((j=0; j<inc_count; j++)); do
                local inc_entry
                local inc_type=$(yq ".steps[$i].include[$j] | tag" "$STEPS_FILE" 2>/dev/null)
                if [ "$inc_type" = "!!map" ]; then
                    local inc_path=$(yq ".steps[$i].include[$j].path" "$STEPS_FILE")
                    local inc_fb=$(yq ".steps[$i].include[$j].fallback // \"\"" "$STEPS_FILE")
                    if [ -n "$inc_fb" ] && [ "$inc_fb" != "null" ]; then
                        inc_entry="${inc_path};${inc_fb}"
                    else
                        inc_entry="$inc_path"
                    fi
                else
                    inc_entry=$(yq ".steps[$i].include[$j]" "$STEPS_FILE")
                fi
                [ -n "$includes" ] && includes+=","
                includes+="$inc_entry"
            done
        fi

        local excludes=""
        local exc_count=$(yq ".steps[$i].exclude | length" "$STEPS_FILE" 2>/dev/null)
        if [ "$exc_count" -gt 0 ] 2>/dev/null; then
            for ((j=0; j<exc_count; j++)); do
                local exc_entry
                local exc_type=$(yq ".steps[$i].exclude[$j] | tag" "$STEPS_FILE" 2>/dev/null)
                if [ "$exc_type" = "!!map" ]; then
                    local exc_path=$(yq ".steps[$i].exclude[$j].path" "$STEPS_FILE")
                    local exc_fb=$(yq ".steps[$i].exclude[$j].fallback // \"\"" "$STEPS_FILE")
                    if [ -n "$exc_fb" ] && [ "$exc_fb" != "null" ]; then
                        exc_entry="${exc_path};${exc_fb}"
                    else
                        exc_entry="$exc_path"
                    fi
                else
                    exc_entry=$(yq ".steps[$i].exclude[$j]" "$STEPS_FILE")
                fi
                [ -n "$excludes" ] && excludes+=","
                excludes+="$exc_entry"
            done
        fi

        local step_vars=""
        local step_var_keys=$(yq ".steps[$i].vars | keys | .[]" "$STEPS_FILE" 2>/dev/null)
        if [ -n "$step_var_keys" ]; then
            while IFS= read -r key; do
                local val=$(yq ".steps[$i].vars.$key" "$STEPS_FILE")
                val=$(eval echo "$val")
                [ -n "$step_vars" ] && step_vars+=","
                step_vars+="$key=$val"
            done <<< "$step_var_keys"
        fi

        STEP_NAMES+=("$name")
        STEP_TYPES+=("$type")
        STEP_SLUGS+=("$slug")
        STEP_SCHEMAS+=("$schemas")
        STEP_CONDITIONS+=("$condition")
        STEP_INCLUDES+=("$includes")
        STEP_EXCLUDES+=("$excludes")
        STEP_VARS+=("$step_vars")
    done
}

function resolve_path() {
    local path="$1"
    local fallbacks="$2"

    local try="$DB_DIR/$path"
    if [ -f "$try" ] || [ -d "$try" ]; then
        echo "$try"
        return 0
    fi

    if [ -f "$path" ] || [ -d "$path" ]; then
        echo "$path"
        return 0
    fi

    if [ -n "$fallbacks" ]; then
        IFS=',' read -ra fbs <<< "$fallbacks"
        for fb in "${fbs[@]}"; do
            local fb_try="$DB_DIR/$fb"
            if [ -f "$fb_try" ] || [ -d "$fb_try" ]; then
                echo "$fb_try"
                return 0
            fi
            if [ -f "$fb" ] || [ -d "$fb" ]; then
                echo "$fb"
                return 0
            fi
        done
    fi

    return 1
}

function matches_exclude() {
    local filename="$1"
    local excludes="$2"

    [ -z "$excludes" ] && return 1

    IFS=',' read -ra entries <<< "$excludes"
    for entry in "${entries[@]}"; do
        local primary="${entry%%;*}"
        local fallback=""
        if [[ "$entry" == *";"* ]]; then
            fallback="${entry#*;}"
        fi
        for pattern in "$primary" "$fallback"; do
            [ -z "$pattern" ] && continue
            case "$filename" in
                $pattern) return 0 ;;
            esac
            echo "$filename" | grep -qiE "$pattern" 2>/dev/null && return 0
        done
    done
    return 1
}

function resolve_include() {
    local entry="$1"
    local excludes="$2"

    local path="${entry%%;*}"
    local fallback=""
    if [[ "$entry" == *";"* ]]; then
        fallback="${entry#*;}"
    fi

    local resolved
    resolved=$(resolve_path "$path" "$fallback")
    if [ $? -ne 0 ]; then
        fail "Path not found: $path"
        return 1
    fi

    if [ -f "$resolved" ] && [[ "$resolved" == *.sql ]]; then
        local base=$(basename "$resolved")
        if ! matches_exclude "$base" "$excludes"; then
            echo "$resolved"
        fi
        return
    fi

    if [ -d "$resolved" ]; then
        for file in $(ls "$resolved"/[Vv]*.sql 2>/dev/null | version_sort); do
            local base=$(basename "$file")
            if ! matches_exclude "$base" "$excludes"; then
                echo "$file"
            fi
        done
    fi
}

function collect_all_files() {
    for ((i=0; i<${#STEP_NAMES[@]}; i++)); do
        local name="${STEP_NAMES[$i]}"
        local type="${STEP_TYPES[$i]}"
        local slug="${STEP_SLUGS[$i]}"
        local schemas="${STEP_SCHEMAS[$i]}"
        local condition="${STEP_CONDITIONS[$i]}"
        local includes="${STEP_INCLUDES[$i]}"
        local excludes="${STEP_EXCLUDES[$i]}"
        local vars="${STEP_VARS[$i]}"

        IFS=',' read -ra inc_paths <<< "$includes"
        for path in "${inc_paths[@]}"; do
            [ -z "$path" ] && continue
            while IFS= read -r resolved; do
                [ -z "$resolved" ] && continue
                echo "${i}|${name}|${type}|${slug}|${schemas}|${condition}|${resolved}|${vars}"
            done < <(resolve_include "$path" "$excludes")
        done
    done
}

function parse_filename() {
    local file_name="$1"
    if [[ "$file_name" =~ ^V([1-9][0-9]*(\.[0-9]+)*)__([a-z0-9]+)_([a-z0-9_]+)\.sql$ ]]; then
        echo "${BASH_REMATCH[1]}|${BASH_REMATCH[3]}|${BASH_REMATCH[4]}"
        return 0
    fi
    return 1
}

function validate_filenames() {
    local errors=0
    local notices=""
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local step_name=$(echo "$entry" | cut -d'|' -f2)
        local step_type=$(echo "$entry" | cut -d'|' -f3)
        local filepath=$(echo "$entry" | cut -d'|' -f7)
        local base=$(basename "$filepath")
        [ "$step_type" = "seed" ] && continue
        if [[ "$base" =~ $FILENAME_GRAMMAR ]]; then
            continue
        fi
        if [ "$step_type" = "migration" ]; then
            fail "Filename grammar violation in step '$step_name': $base"
            errors=$((errors + 1))
        else
            notices+="   ${GRAY}- unsupported filename in step '$step_name': $base${NC}\n"
        fi
    done < <(collect_all_files)
    if [ -n "$notices" ]; then
        printf "${GRAY}Filename grammar not enforced on base and seed steps; the following files exist but are not validated:${NC}\n"
        printf "%b" "$notices"
    fi
    return $errors
}

function preflight_scan() {
    local fatal=0
    local drift=0
    local new=0
    local unchanged=0
    local folded=0
    local missing=0
    local report=""

    declare -A seen_paths
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local step_name=$(echo "$entry" | cut -d'|' -f2)
        local step_type=$(echo "$entry" | cut -d'|' -f3)
        local slug=$(echo "$entry" | cut -d'|' -f4)
        local condition=$(echo "$entry" | cut -d'|' -f6)
        local filepath=$(echo "$entry" | cut -d'|' -f7)

        if ! eval_condition "$condition"; then
            continue
        fi

        local base=$(basename "$filepath")
        local dir=$(basename "$(dirname "$filepath")")
        local file_id="${dir}/${base}"
        seen_paths["$file_id"]=1

        local sha=$(file_sha256 "$filepath")
        local size=$(file_size "$filepath")

        local row=$(run_psql_query "SELECT sha256, state FROM samna_migrate.file WHERE file_path = '$(sql_escape "$file_id")'")
        if [ -z "$row" ]; then
            new=$((new + 1))
            local file_slug=""
            local file_ver=""
            local parsed=$(parse_filename "$base")
            if [ -n "$parsed" ]; then
                file_ver=$(echo "$parsed" | cut -d'|' -f1)
                file_slug=$(echo "$parsed" | cut -d'|' -f2)
            fi
            [ -z "$file_slug" ] && file_slug="$slug"
            [ -z "$size" ] && size=0
            run_psql_cmd "INSERT INTO samna_migrate.file (step_name, step_type, slug, version, file_name, file_path, sha256, size_bytes, state) VALUES ('$(sql_escape "$step_name")', '$(sql_escape "$step_type")', '$(sql_escape "$file_slug")', NULLIF('$(sql_escape "$file_ver")', ''), '$(sql_escape "$base")', '$(sql_escape "$file_id")', '$(sql_escape "$sha")', $size, 'pending')" > /dev/null
            continue
        fi

        local db_sha=$(echo "$row" | cut -d'|' -f1)
        local db_state=$(echo "$row" | cut -d'|' -f2)

        if [ "$db_sha" = "$sha" ]; then
            unchanged=$((unchanged + 1))
            continue
        fi

        if [ "$db_state" = "applied" ] && [ "$step_type" = "migration" ]; then
            report+="  ${RED}✗ tampered:${NC} ${WHITE}${file_id}${NC}\n"
            report+="     ${GRAY}expected ${db_sha:0:12} got ${sha:0:12}${NC}\n"
            fatal=$((fatal + 1))
            continue
        fi

        drift=$((drift + 1))
        run_psql_cmd "UPDATE samna_migrate.file SET last_drift_sha256 = '$(sql_escape "$sha")', last_drift_at = NOW() WHERE file_path = '$(sql_escape "$file_id")'" > /dev/null
    done < <(collect_all_files)

    local db_rows=$(run_psql_query "SELECT file_path, state, step_type FROM samna_migrate.file WHERE state = 'applied'")
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        local fp=$(echo "$row" | cut -d'|' -f1)
        local st=$(echo "$row" | cut -d'|' -f2)
        local sty=$(echo "$row" | cut -d'|' -f3)
        if [ -z "${seen_paths[$fp]}" ]; then
            if [ "$sty" = "migration" ]; then
                report+="  ${RED}✗ missing applied migration:${NC} ${WHITE}${fp}${NC}\n"
                fatal=$((fatal + 1))
                missing=$((missing + 1))
            else
                run_psql_cmd "UPDATE samna_migrate.file SET removed_from_disk_at = NOW() WHERE file_path = '$(sql_escape "$fp")'" > /dev/null
            fi
        fi
    done <<< "$db_rows"

    folded=$(run_psql_cmd "SELECT count(*) FROM samna_migrate.file WHERE state = 'folded'")

    echo ""
    printf "${BOLD}Preflight${NC}\n"
    printf "  ${GREEN}%4s unchanged${NC}\n" "$unchanged"
    printf "  ${CYAN}%4s new${NC}\n" "$new"
    printf "  ${YELLOW}%4s drift${NC}\n" "$drift"
    printf "  ${GRAY}%4s folded${NC}\n" "$folded"
    if [ "$fatal" -gt 0 ]; then
        printf "  ${RED}%4s fatal${NC}\n" "$fatal"
        echo ""
        printf "%b" "$report"
        echo ""
        return 1
    fi
    echo ""
    return 0
}

function _draw_divider_line() {
    local file="$1"
    local elapsed="$2"
    local visible_len=${#file}
    local elapsed_text=""
    if [ -n "$elapsed" ]; then
        elapsed_text=" · ${elapsed}s"
        visible_len=$((visible_len + ${#elapsed_text}))
    fi
    local rule_len=$(( 78 - visible_len - 6 ))
    [ "$rule_len" -lt 4 ] && rule_len=4
    printf "${GRAY}─── ${WHITE}${BOLD}%s${NC}" "$file"
    [ -n "$elapsed_text" ] && printf "${GRAY}%s${NC}" "$elapsed_text"
    printf " ${GRAY}"
    local i=0
    while [ "$i" -lt "$rule_len" ]; do printf "─"; i=$((i + 1)); done
    printf "${NC}"
}

function file_divider() {
    printf "\n"
    _draw_divider_line "$1" ""
    printf "\n"
}

function filter_psql_output() {
    awk \
        -v R="$(printf '\033[0;31m')" \
        -v G="$(printf '\033[0;32m')" \
        -v Y="$(printf '\033[0;33m')" \
        -v C="$(printf '\033[0;36m')" \
        -v GR="$(printf '\033[0;90m')" \
        -v B="$(printf '\033[1m')" \
        -v N="$(printf '\033[0m')" '
        BEGIN { st = 0; buf = ""; have_buf = 0 }
        st == 1 && /^\([0-9]+ rows?\)$/ { st = 2; next }
        st == 1 { next }
        st == 2 { st = 0; if ($0 == "") next }
        /^[ ]*[-+]+[-+ ]*$/ { st = 1; have_buf = 0; next }
        {
            if (have_buf) emit(buf)
            buf = $0
            have_buf = 1
        }
        END {
            if (have_buf && st == 0) emit(buf)
            fflush()
        }
        function emit(line,    pre) {
            sub(/^psql:[^:]+:[0-9]+: /, "", line)
            if (line ~ /^(ERROR|FATAL|PANIC)/) {
                pre = line
                sub(/^(ERROR|FATAL|PANIC):[ ]*/, "", line)
                printf "       %s%s✗ %s%s\n", R, B, line, N
            } else if (line ~ /^NOTICE/) {
                sub(/^NOTICE:[ ]*/, "", line)
                printf "       %s· %s%s\n", GR, line, N
            } else if (line ~ /^WARNING/) {
                sub(/^WARNING:[ ]*/, "", line)
                printf "       %s! %s%s\n", Y, line, N
            } else if (line ~ /^(CREATE|INSERT|ALTER|DROP|DO|SELECT|GRANT|REVOKE|COMMENT|TRUNCATE|UPDATE|DELETE)/) {
                printf "       %s%s%s\n", GR, line, N
            } else if (line == "") {
                printf "\n"
            } else {
                printf "       %s%s%s\n", GR, line, N
            }
            fflush()
        }
    '
}

function run_sql() {
    local filepath="$1"
    local vars="$2"
    local file=$(basename "$filepath")

    local psql_args=()
    while IFS= read -r a; do psql_args+=("$a"); done < <(psql_base_args)
    psql_args+=(--single-transaction --set ON_ERROR_STOP=1 --quiet -f "$filepath")

    if [ -n "$vars" ]; then
        IFS=',' read -ra var_pairs <<< "$vars"
        for pair in "${var_pairs[@]}"; do
            local key=$(echo "$pair" | cut -d= -f1)
            local val=$(echo "$pair" | cut -d= -f2-)
            psql_args+=(-v "$key=$val")
        done
    fi

    file_divider "$file"

    local lines_below_divider=0
    local is_tty=0
    [ -t 1 ] && is_tty=1

    printf "  ${DIM}sql${NC}\n"
    lines_below_divider=$((lines_below_divider + 1))
    while IFS= read -r fl; do
        printf "       ${DIM}%s${NC}\n" "$fl"
        lines_below_divider=$((lines_below_divider + 1))
    done < "$filepath"
    printf "\n"
    lines_below_divider=$((lines_below_divider + 1))

    printf "  ${DIM}output${NC}\n"
    lines_below_divider=$((lines_below_divider + 1))

    local out_file=$(mktemp)
    local exit_file=$(mktemp)
    local start_time=$(date +%s)

    (
        PGPASSWORD="$PGPASSWORD" psql "${psql_args[@]}" > "$out_file" 2>&1
        echo $? > "$exit_file"
    ) &
    local psql_pid=$!

    redraw_divider_with_elapsed() {
        local elapsed_val="$1"
        local up=$((lines_below_divider + 1))
        printf "\033[%dA\r\033[K" "$up"
        _draw_divider_line "$file" "$elapsed_val"
        printf "\033[%dB\r" "$up"
    }

    local last_pos=0 current_size=0
    local elapsed=0 last_elapsed=-1 now_t=0
    local chunk chunk_lines

    while kill -0 "$psql_pid" 2>/dev/null; do
        current_size=$(wc -c < "$out_file" 2>/dev/null)
        current_size=${current_size:-0}
        if [ "$current_size" -gt "$last_pos" ]; then
            chunk=$(tail -c +$((last_pos + 1)) "$out_file" 2>/dev/null | filter_psql_output)
            if [ -n "$chunk" ]; then
                chunk_lines=$(printf '%s' "$chunk" | awk 'END{print NR}')
                printf '%s' "$chunk"
                lines_below_divider=$((lines_below_divider + chunk_lines))
            fi
            last_pos=$current_size
        fi
        if [ "$is_tty" -eq 1 ]; then
            now_t=$(date +%s)
            elapsed=$((now_t - start_time))
            if [ "$elapsed" -ne "$last_elapsed" ]; then
                redraw_divider_with_elapsed "$elapsed"
                last_elapsed=$elapsed
            fi
        fi
        sleep 0.2
    done

    current_size=$(wc -c < "$out_file" 2>/dev/null)
    current_size=${current_size:-0}
    if [ "$current_size" -gt "$last_pos" ]; then
        chunk=$(tail -c +$((last_pos + 1)) "$out_file" 2>/dev/null | filter_psql_output)
        if [ -n "$chunk" ]; then
            chunk_lines=$(printf '%s' "$chunk" | awk 'END{print NR}')
            printf '%s' "$chunk"
            lines_below_divider=$((lines_below_divider + chunk_lines))
        fi
    fi

    wait "$psql_pid" 2>/dev/null

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ "$is_tty" -eq 1 ]; then
        redraw_divider_with_elapsed "$duration"
    fi

    local exit_code
    exit_code=$(cat "$exit_file" 2>/dev/null)
    [ -z "$exit_code" ] && exit_code=1

    local creates=$(grep -cE "^CREATE" "$out_file" 2>/dev/null)
    local inserts=$(grep -cE "^INSERT" "$out_file" 2>/dev/null)
    local alters=$(grep -cE "^ALTER" "$out_file" 2>/dev/null)
    local drops=$(grep -cE "^DROP" "$out_file" 2>/dev/null)
    local dos=$(grep -cE "^DO$" "$out_file" 2>/dev/null)
    local selects=$(grep -cE "^SELECT" "$out_file" 2>/dev/null)
    local errors=$(grep -cE "^(ERROR|FATAL|PANIC)" "$out_file" 2>/dev/null)
    creates=${creates:-0}; inserts=${inserts:-0}; alters=${alters:-0}
    drops=${drops:-0}; dos=${dos:-0}; selects=${selects:-0}; errors=${errors:-0}

    local last_err=""
    if [ "$errors" -gt 0 ]; then
        last_err=$(grep -E "^(ERROR|FATAL|PANIC):" "$out_file" | head -1 | sed 's/^[A-Z]*: *//')
    fi

    rm -f "$out_file" "$exit_file"

    local summary=""
    [ "$creates" -gt 0 ] && summary+="${GREEN}${creates} created${NC} ${GRAY}·${NC} "
    [ "$inserts" -gt 0 ] && summary+="${GREEN}${inserts} inserted${NC} ${GRAY}·${NC} "
    [ "$alters" -gt 0 ]  && summary+="${YELLOW}${alters} altered${NC} ${GRAY}·${NC} "
    [ "$drops" -gt 0 ]   && summary+="${RED}${drops} dropped${NC} ${GRAY}·${NC} "
    [ "$dos" -gt 0 ]     && summary+="${CYAN}${dos} executed${NC} ${GRAY}·${NC} "
    [ "$selects" -gt 0 ] && summary+="${CYAN}${selects} called${NC} ${GRAY}·${NC} "
    summary="${summary% ${GRAY}·${NC} }"

    RUN_SQL_DURATION_MS=$((duration * 1000))
    RUN_SQL_ERROR_MESSAGE="$last_err"

    printf "\n"
    if [ "$exit_code" -ne 0 ]; then
        printf "  ${RED}${BOLD}✗ failed${NC}  ${GRAY}%s${NC}  %b\n" "$file" "$summary"
        return 1
    elif [ "$errors" -gt 0 ]; then
        printf "  ${YELLOW}${BOLD}! warnings${NC}  ${GRAY}%s${NC}  %b\n" "$file" "$summary"
        return 1
    else
        printf "  ${GREEN}${BOLD}✓ done${NC}  ${GRAY}%s${NC}  %b\n" "$file" "$summary"
    fi

    return 0
}

DOCTOR_ISSUES=0
DOCTOR_WARNINGS=0
DOCTOR_MESSAGES=""

STAT_LINES=0
STAT_TABLES=0
STAT_INDEXES=0
STAT_FUNCS=0
STAT_TRIGGERS=0
STAT_VIEWS=0
STAT_TYPES=0
STAT_INSERTS=0
STAT_DELETES=0
STAT_ALTERS=0
STAT_DROPS=0
STAT_SELECTS=0

function file_stats() {
    local filepath="$1"
    local content=$(cat "$filepath")
    STAT_LINES=$(echo "$content" | wc -l | tr -d ' ')
    STAT_TABLES=$(echo "$content" | grep -ciE '^CREATE[[:space:]]+TABLE' || true)
    STAT_INDEXES=$(echo "$content" | grep -ciE '^CREATE[[:space:]]+INDEX' || true)
    STAT_FUNCS=$(echo "$content" | grep -ciE '^CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?FUNCTION' || true)
    STAT_TRIGGERS=$(echo "$content" | grep -ciE '^CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?TRIGGER' || true)
    STAT_VIEWS=$(echo "$content" | grep -ciE '^CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?VIEW' || true)
    STAT_TYPES=$(echo "$content" | grep -ciE 'CREATE[[:space:]]+TYPE' || true)
    STAT_INSERTS=$(echo "$content" | grep -ciE 'INSERT[[:space:]]+INTO' || true)
    STAT_DELETES=$(echo "$content" | grep -ciE 'DELETE[[:space:]]+FROM' || true)
    STAT_ALTERS=$(echo "$content" | grep -ciE '^ALTER[[:space:]]+TABLE' || true)
    STAT_DROPS=$(echo "$content" | grep -ciE '^DROP[[:space:]]+(TABLE|INDEX|FUNCTION|TRIGGER|VIEW|TYPE)' || true)
    STAT_SELECTS=$(echo "$content" | grep -ciE '^SELECT[[:space:]]+[a-z_\.]+[[:space:]]*\(' || true)
}

function strip_body() {
    sed '/\$\$/,/\$\$/d' \
        | sed 's/--.*$//' \
        | awk '
            BEGIN { in_co = 0; in_block = 0 }
            {
                line = $0
                while (1) {
                    if (in_block) {
                        p = index(line, "*/")
                        if (p == 0) { line = ""; break }
                        line = substr(line, p + 2)
                        in_block = 0
                    }
                    s = index(line, "/*")
                    if (s == 0) break
                    rest = substr(line, s + 2)
                    e = index(rest, "*/")
                    if (e == 0) {
                        line = substr(line, 1, s - 1)
                        in_block = 1
                        break
                    }
                    line = substr(line, 1, s - 1) substr(rest, e + 2)
                }
                if (in_co) {
                    if (index(line, ";") > 0) in_co = 0
                    next
                }
                if (match(line, /^[[:space:]]*COMMENT[[:space:]]+ON/)) {
                    if (match(line, /;[[:space:]]*$/)) next
                    in_co = 1
                    next
                }
                print line
            }
        '
}

function doctor_file() {
    local filepath="$1"
    local content
    content=$(cat "$filepath")
    local toplevel
    toplevel=$(echo "$content" | strip_body)
    DOCTOR_ISSUES=0
    DOCTOR_WARNINGS=0
    DOCTOR_MESSAGES=""

    if echo "$toplevel" | grep -qiE 'INSERT[[:space:]]+INTO' && \
       ! echo "$content" | grep -qiE 'ON[[:space:]]+CONFLICT' && \
       ! echo "$content" | grep -qiE 'IF[[:space:]]+NOT[[:space:]]+EXISTS'; then
        local bare_inserts
        bare_inserts=$(echo "$content" | grep -niE '^[[:space:]]*INSERT[[:space:]]+INTO' | head -5)
        while IFS= read -r insert_line; do
            [ -z "$insert_line" ] && continue
            local line_num=$(echo "$insert_line" | cut -d: -f1)
            local before=$(head -n "$line_num" "$filepath" | grep -c '\$\$')
            if [ $((before % 2)) -eq 1 ]; then
                continue
            fi
            fail "Bare INSERT without ON CONFLICT at line $line_num"
            DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
        done <<< "$bare_inserts"
    fi

    if echo "$toplevel" | grep -qiE '(DROP[[:space:]]+TABLE|DROP[[:space:]]+SCHEMA|DROP[[:space:]]+INDEX)' && \
       ! echo "$content" | grep -qiE 'DROP[[:space:]]+(TABLE|SCHEMA|INDEX)[[:space:]]+IF[[:space:]]+EXISTS'; then
        fail "DROP without IF EXISTS"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$toplevel" | grep -qiE 'DELETE[[:space:]]+FROM'; then
        fail "DELETE FROM at top level"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$toplevel" | grep -qiE 'TRUNCATE'; then
        fail "TRUNCATE detected"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$toplevel" | grep -qiE 'ALTER[[:space:]]+TABLE[[:space:]]+.*DROP[[:space:]]+COLUMN'; then
        fail "ALTER TABLE DROP COLUMN"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$toplevel" | grep -qiE 'ALTER[[:space:]]+TABLE[[:space:]]+.*RENAME' && \
       ! echo "$content" | grep -qiE 'IF[[:space:]]+EXISTS'; then
        fail "ALTER TABLE RENAME without state check"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$toplevel" | grep -qiE 'UPDATE[[:space:]]+.*[[:space:]]+SET[[:space:]]' && \
       ! echo "$toplevel" | grep -qiE 'UPDATE[[:space:]]+.*SET[[:space:]]+.*WHERE'; then
        fail "UPDATE without WHERE at top level"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$content" | grep -qiE 'CREATE[[:space:]]+TABLE[[:space:]]' && \
       ! echo "$content" | grep -qiE 'CREATE[[:space:]]+TABLE[[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS'; then
        fail "CREATE TABLE without IF NOT EXISTS"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$content" | grep -qiE 'CREATE[[:space:]]+FUNCTION' && \
       ! echo "$content" | grep -qiE 'CREATE[[:space:]]+OR[[:space:]]+REPLACE[[:space:]]+FUNCTION'; then
        fail "CREATE FUNCTION without OR REPLACE"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$content" | grep -qiE 'CREATE[[:space:]]+INDEX' && \
       ! echo "$content" | grep -qiE 'CREATE[[:space:]]+INDEX[[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS' && \
       ! echo "$content" | grep -qiE 'DROP[[:space:]]+INDEX[[:space:]]+IF[[:space:]]+EXISTS'; then
        fail "CREATE INDEX without IF NOT EXISTS or preceding DROP IF EXISTS"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$content" | grep -qiE 'CREATE[[:space:]]+TYPE' && \
       ! echo "$content" | grep -qiE 'DO[[:space:]]+' && \
       ! echo "$content" | grep -qiE 'EXCEPTION'; then
        fail "CREATE TYPE without idempotent DO block"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$content" | grep -qiE 'CREATE[[:space:]]+TRIGGER' && \
       ! echo "$content" | grep -qiE 'CREATE[[:space:]]+OR[[:space:]]+REPLACE[[:space:]]+TRIGGER' && \
       ! echo "$content" | grep -qiE 'DROP[[:space:]]+TRIGGER[[:space:]]+IF[[:space:]]+EXISTS'; then
        fail "CREATE TRIGGER without OR REPLACE or DROP IF EXISTS"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$content" | grep -qiE 'CREATE[[:space:]]+VIEW' && \
       ! echo "$content" | grep -qiE 'CREATE[[:space:]]+OR[[:space:]]+REPLACE[[:space:]]+VIEW'; then
        fail "CREATE VIEW without OR REPLACE"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$content" | grep -qiE 'session_replication_role'; then
        fail "session_replication_role detected"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    fi

    if echo "$toplevel" | grep -qiE '^[[:space:]]*SELECT[[:space:]]' && \
       ! echo "$content" | grep -qiE 'CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?VIEW' && \
       ! echo "$toplevel" | grep -qiE 'SELECT[[:space:]]+([a-z_][a-z_0-9]*\.)?[a-z_][a-z_0-9]*[[:space:]]*\('; then
        warn "Top level SELECT outside function body"
        DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
    fi

    if [ ! -s "$filepath" ] || ! grep -qE '[^[:space:]]' "$filepath"; then
        warn "Empty file"
        DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
    fi
}

function doctor_check() {
    local filepath="$1"
    local tmpfile=$(mktemp)
    doctor_file "$filepath" > "$tmpfile" 2>&1
    local issues=$DOCTOR_ISSUES
    local warnings=$DOCTOR_WARNINGS

    if [ "$issues" -eq 0 ] && [ "$warnings" -eq 0 ]; then
        printf "  ${GREEN}✓${NC} %s\n" "$(basename "$filepath")"
    elif [ "$issues" -eq 0 ]; then
        printf "  ${YELLOW}!${NC} %s\n" "$(basename "$filepath")"
    else
        printf "  ${RED}✗${NC} %s\n" "$(basename "$filepath")"
    fi
    [ -s "$tmpfile" ] && cat "$tmpfile"
    rm -f "$tmpfile"
}

function doctor() {
    local target="${1:-}"
    local total_issues=0
    local total_warnings=0
    local files_checked=0
    local current_group=""

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local filepath=$(echo "$entry" | cut -d'|' -f7)

        if [ -n "$target" ] && ! echo "$filepath" | grep -qiE "$target"; then
            continue
        fi

        [ ! -f "$filepath" ] && continue

        local step_name=$(echo "$entry" | cut -d'|' -f2)
        if [ "$step_name" != "$current_group" ]; then
            current_group="$step_name"
            printf "\n${CYAN}${BOLD}%s${NC}\n" "$step_name"
        fi

        doctor_check "$filepath"
        total_issues=$((total_issues + DOCTOR_ISSUES))
        total_warnings=$((total_warnings + DOCTOR_WARNINGS))

        files_checked=$((files_checked + 1))
    done < <(collect_all_files)

    echo ""
    printf "${WHITE}%d files${NC}  " "$files_checked"
    [ "$total_issues" -gt 0 ] && printf "${RED}%d critical${NC}  " "$total_issues" || printf "${GREEN}0 critical${NC}  "
    [ "$total_warnings" -gt 0 ] && printf "${YELLOW}%d warnings${NC}\n" "$total_warnings" || printf "${GREEN}0 warnings${NC}\n"
    echo ""

    return "$total_issues"
}

function print_stat_val() {
    local val="$1" color="$2"
    [ "$val" -gt 0 ] && printf " ${color}%4s${NC}" "$val" || printf " ${WHITE}%4s${NC}" "0"
}

function list_steps() {
    echo ""
    printf "${WHITE}${BOLD}%-45s${NC} ${GRAY}%5s${NC} ${GREEN}%4s${NC} ${GREEN}%4s${NC} ${CYAN}%4s${NC} ${YELLOW}%4s${NC} ${BLUE}%4s${NC} ${MAGENTA}%4s${NC} ${CYAN}%4s${NC} ${GREEN}%4s${NC} ${RED}%4s${NC}\n" \
        "step" "lines" "tbl" "idx" "func" "trig" "view" "type" "sel" "ins" "del"
    printf "${GRAY}"
    for ((i=0; i<100; i++)); do printf "─"; done
    printf "${NC}\n"

    local t_lines=0 t_tables=0 t_indexes=0 t_funcs=0 t_trigs=0 t_views=0 t_types=0 t_sel=0 t_ins=0 t_del=0
    local file_count=0

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local filepath=$(echo "$entry" | cut -d'|' -f7)
        [ ! -f "$filepath" ] && continue

        local dir=$(basename "$(dirname "$filepath")")
        local label="$dir/$(basename "$filepath")"

        file_stats "$filepath"
        t_lines=$((t_lines + STAT_LINES)); t_tables=$((t_tables + STAT_TABLES)); t_indexes=$((t_indexes + STAT_INDEXES))
        t_funcs=$((t_funcs + STAT_FUNCS)); t_trigs=$((t_trigs + STAT_TRIGGERS)); t_views=$((t_views + STAT_VIEWS))
        t_types=$((t_types + STAT_TYPES)); t_sel=$((t_sel + STAT_SELECTS)); t_ins=$((t_ins + STAT_INSERTS)); t_del=$((t_del + STAT_DELETES))
        file_count=$((file_count + 1))

        printf "${WHITE}%-45s${NC} ${GRAY}%5s${NC}" "$label" "$STAT_LINES"
        print_stat_val "$STAT_TABLES" "$GREEN"
        print_stat_val "$STAT_INDEXES" "$GREEN"
        print_stat_val "$STAT_FUNCS" "$CYAN"
        print_stat_val "$STAT_TRIGGERS" "$YELLOW"
        print_stat_val "$STAT_VIEWS" "$BLUE"
        print_stat_val "$STAT_TYPES" "$MAGENTA"
        print_stat_val "$STAT_SELECTS" "$CYAN"
        print_stat_val "$STAT_INSERTS" "$GREEN"
        print_stat_val "$STAT_DELETES" "$RED"
        echo ""
    done < <(collect_all_files)

    printf "${GRAY}"
    for ((i=0; i<100; i++)); do printf "─"; done
    printf "${NC}\n"
    printf "${WHITE}${BOLD}%-45s${NC} ${GRAY}%5s${NC} ${GREEN}%4s${NC} ${GREEN}%4s${NC} ${CYAN}%4s${NC} ${YELLOW}%4s${NC} ${BLUE}%4s${NC} ${MAGENTA}%4s${NC} ${CYAN}%4s${NC} ${GREEN}%4s${NC} ${RED}%4s${NC}\n" \
        "$file_count files" "$t_lines" "$t_tables" "$t_indexes" "$t_funcs" "$t_trigs" "$t_views" "$t_types" "$t_sel" "$t_ins" "$t_del"
    echo ""
}

function schema_cmd() {
    if [ ! -f "$STEPS_FILE" ]; then
        local template_path="$SCRIPT_DIR/migrate.yml"
        local app_name="${APP_NAME:-myapp}"
        cat > "$template_path" << EOF
name: $app_name
description: Database migrations
version: "1.0"

steps:
  - name: Application Tables
    type: base
    slug: base
    schemas: [public]
    include:
      - path: base/
EOF
        success "Template created: $template_path"
        return
    fi

    local name=$(yq '.name // ""' "$STEPS_FILE")
    local desc=$(yq '.description // ""' "$STEPS_FILE")
    local ver=$(yq '.version // ""' "$STEPS_FILE")

    echo ""
    [ -n "$name" ] && printf "${WHITE}${BOLD}%s${NC}" "$name"
    [ -n "$ver" ] && printf " ${GRAY}v%s${NC}" "$ver"
    [ -n "$name" ] && echo ""
    [ -n "$desc" ] && printf "${GRAY}%s${NC}\n" "$desc"
    printf "${GRAY}script %s, schema %s${NC}\n" "$SCRIPT_VERSION" "$SCHEMA_VERSION"

    local total_files=0

    for ((i=0; i<${#STEP_NAMES[@]}; i++)); do
        local step_name="${STEP_NAMES[$i]}"
        local step_type="${STEP_TYPES[$i]}"
        local step_slug="${STEP_SLUGS[$i]}"
        local step_schemas="${STEP_SCHEMAS[$i]}"
        local includes="${STEP_INCLUDES[$i]}"
        local excludes="${STEP_EXCLUDES[$i]}"
        local file_count=0

        IFS=',' read -ra inc_paths <<< "$includes"

        printf "\n${CYAN}${BOLD}%s${NC} ${GRAY}type=%s slug=%s schemas=%s${NC}\n" "$step_name" "$step_type" "$step_slug" "$step_schemas"

        for path in "${inc_paths[@]}"; do
            [ -z "$path" ] && continue
            while IFS= read -r resolved; do
                [ -z "$resolved" ] && continue
                file_count=$((file_count + 1))
                printf "  ${GRAY}%s${NC}\n" "$(basename "$resolved")"
            done < <(resolve_include "$path" "$excludes" 2>/dev/null)
        done
        total_files=$((total_files + file_count))
        printf "  ${GRAY}%d files${NC}\n" "$file_count"
    done

    printf "\n${WHITE}${BOLD}Total${NC} ${GRAY}%d steps, %d files${NC}\n\n" "${#STEP_NAMES[@]}" "$total_files"
}

function migrate_stat() {
    require_db
    local schema_exists=$(run_psql_cmd "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'samna_migrate'")

    if [ "$schema_exists" != "1" ]; then
        echo ""
        printf "${GRAY}No migration state found. Run 'migrate.sh up' first.${NC}\n"
        echo ""
        return
    fi

    local schema_version=$(run_psql_cmd "SELECT schema_version FROM samna_migrate.state WHERE id = 1")
    local tool_version=$(run_psql_cmd "SELECT tool_version FROM samna_migrate.state WHERE id = 1")
    local version=$(run_psql_cmd "SELECT version FROM samna_migrate.state WHERE id = 1")
    local last_run_at=$(run_psql_cmd "SELECT to_char(last_run_at, 'YYYY-MM-DD HH24:MI:SS') FROM samna_migrate.state WHERE id = 1")
    local last_run_status=$(run_psql_cmd "SELECT last_run_status FROM samna_migrate.state WHERE id = 1")
    local last_run_command=$(run_psql_cmd "SELECT last_run_command FROM samna_migrate.state WHERE id = 1")

    local pending=$(run_psql_cmd "SELECT count(*) FROM samna_migrate.file WHERE state = 'pending'")
    local applied=$(run_psql_cmd "SELECT count(*) FROM samna_migrate.file WHERE state = 'applied'")
    local folded=$(run_psql_cmd "SELECT count(*) FROM samna_migrate.file WHERE state = 'folded'")

    echo ""
    printf "${WHITE}${BOLD}State${NC}\n"
    printf "${WHITE}schema_version:${NC}    %s\n" "${schema_version:-0}"
    printf "${WHITE}tool_version:${NC}      %s ${GRAY}(running %s)${NC}\n" "${tool_version:-unknown}" "$SCRIPT_VERSION"
    printf "${WHITE}label:${NC}             %s\n" "${version:-none}"
    printf "${WHITE}last_run_at:${NC}       %s\n" "${last_run_at:-never}"
    printf "${WHITE}last_run_status:${NC}   %s\n" "${last_run_status:-unknown}"
    printf "${WHITE}last_run_command:${NC}  %s\n" "${last_run_command:-none}"

    echo ""
    printf "${WHITE}${BOLD}Files${NC}\n"
    printf "${GREEN}%s applied${NC}  ${YELLOW}%s pending${NC}  ${GRAY}%s folded${NC}\n" "$applied" "$pending" "$folded"

    echo ""
    printf "${WHITE}${BOLD}Recent history${NC}\n"
    printf "${WHITE}%-40s %-12s %-20s %8s${NC}\n" "file" "action" "applied" "ms"
    printf "${GRAY}"
    for ((i=0; i<82; i++)); do printf "─"; done
    printf "${NC}\n"

    run_psql_query "SELECT file_path, action_type, to_char(applied_at, 'YYYY-MM-DD HH24:MI'), duration_ms, success FROM samna_migrate.history ORDER BY id DESC LIMIT 25" | while IFS='|' read -r fp at when ms ok; do
        if [ "$ok" = "t" ]; then
            printf "${WHITE}%-40s${NC} ${CYAN}%-12s${NC} ${GRAY}%-20s${NC} ${GRAY}%8s${NC}\n" "$fp" "$at" "$when" "$ms"
        else
            printf "${RED}%-40s${NC} ${CYAN}%-12s${NC} ${GRAY}%-20s${NC} ${RED}%8s${NC}\n" "$fp" "$at" "$when" "FAILED"
        fi
    done
    echo ""
}

function migrate_delete() {
    require_db
    local schema_exists=$(run_psql_cmd "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'samna_migrate'" 2>/dev/null)

    if [ "$schema_exists" != "1" ]; then
        printf "${GRAY}No samna_migrate schema found.${NC}\n"
        return
    fi

    printf "${RED}${BOLD}This will permanently delete the samna_migrate schema and all migration history.${NC}\n"
    printf "Are you sure? [y/N] "
    read -r response
    case "$response" in
        [yY])
            run_psql_cmd "DROP SCHEMA samna_migrate CASCADE" > /dev/null
            printf "${GREEN}samna_migrate schema deleted.${NC}\n"
            ;;
        *)
            printf "${GRAY}Cancelled.${NC}\n"
            ;;
    esac
}

function record_history_apply() {
    local file_id="$1"
    local step_name="$2"
    local step_type="$3"
    local slug="$4"
    local version="$5"
    local file_name="$6"
    local file_path="$7"
    local sha="$8"
    local size="$9"
    local duration_ms="${10}"
    local success="${11}"
    local error_msg="${12}"

    [ -z "$size" ] && size=0
    [ -z "$duration_ms" ] && duration_ms=0
    [ -z "$file_id" ] && file_id=NULL

    local attempt=$(run_psql_cmd "SELECT attempts_count + 1 FROM samna_migrate.file WHERE id = $file_id")
    [ -z "$attempt" ] && attempt=1

    local hist_id=$(run_psql_cmd "INSERT INTO samna_migrate.history (file_id, step_name, step_type, slug, version, file_name, file_path, sha256, size_bytes, attempt, action_type, tool_version, executed_by, host, database, duration_ms, success, error_message) VALUES ($file_id, '$(sql_escape "$step_name")', '$(sql_escape "$step_type")', '$(sql_escape "$slug")', NULLIF('$(sql_escape "$version")', ''), '$(sql_escape "$file_name")', '$(sql_escape "$file_path")', '$(sql_escape "$sha")', $size, $attempt, 'apply', '$(sql_escape "$SCRIPT_VERSION")', '$(sql_escape "$PGUSER")', '$(sql_escape "${PGHOST:-localhost}")', '$(sql_escape "$PGDATABASE")', $duration_ms, $success, NULLIF('$(sql_escape "$error_msg")', '')) RETURNING id")

    if [ "$success" = "true" ]; then
        run_psql_cmd "UPDATE samna_migrate.file SET state = 'applied', last_applied_at = NOW(), last_applied_history_id = $hist_id, last_attempt_status = 'success', attempts_count = $attempt WHERE id = $file_id" > /dev/null
    else
        run_psql_cmd "UPDATE samna_migrate.file SET last_attempt_status = 'failure', attempts_count = $attempt WHERE id = $file_id" > /dev/null
    fi
}

function migrate_up() {
    boot_check
    local target="${1:-}"

    if ! validate_filenames; then
        echo ""
        printf "${RED}Filename grammar check failed${NC}\n"
        echo ""
        exit 1
    fi

    if ! preflight_scan; then
        printf "${RED}Preflight failed. Aborting.${NC}\n"
        echo ""
        exit 1
    fi

    printf "${GRAY}%s:%s/%s${NC}\n" "${PGHOST:-socket}" "$PGPORT" "$PGDATABASE"

    local current_step="" step_active=true
    local total_files=0 total_skipped=0
    local start_time=$(date +%s)

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local name=$(echo "$entry" | cut -d'|' -f2)
        local type=$(echo "$entry" | cut -d'|' -f3)
        local slug=$(echo "$entry" | cut -d'|' -f4)
        local step_cond=$(echo "$entry" | cut -d'|' -f6)
        local filepath=$(echo "$entry" | cut -d'|' -f7)
        local vars=$(echo "$entry" | cut -d'|' -f8)

        if [ "$name" != "$current_step" ]; then
            current_step="$name"
            if ! eval_condition "$step_cond"; then
                step_active=false
                continue
            fi
            step_active=true
            printf "\n${CYAN}${BOLD}%s${NC} ${GRAY}type=%s${NC}\n" "$name" "$type"
        fi

        if [ "$step_active" = false ]; then
            continue
        fi

        local dir=$(basename "$(dirname "$filepath")")
        local base=$(basename "$filepath")
        local file_id="${dir}/${base}"
        local sha=$(file_sha256 "$filepath")

        local row=$(run_psql_query "SELECT id, state, sha256 FROM samna_migrate.file WHERE file_path = '$(sql_escape "$file_id")'")
        local file_db_id=$(echo "$row" | cut -d'|' -f1)
        local db_state=$(echo "$row" | cut -d'|' -f2)
        local db_sha=$(echo "$row" | cut -d'|' -f3)

        if [ "$db_state" = "applied" ] && [ "$db_sha" = "$sha" ]; then
            printf "  ${GRAY}· %s (applied)${NC}\n" "$base"
            total_skipped=$((total_skipped + 1))
            continue
        fi

        if [ "$db_state" = "applied" ] && [ "$db_sha" != "$sha" ] && [ "$type" = "base" ]; then
            printf "  ${YELLOW}· %s (drift, replaying)${NC}\n" "$base"
            run_psql_cmd "UPDATE samna_migrate.file SET sha256 = '$(sql_escape "$sha")' WHERE id = $file_db_id" > /dev/null
        fi

        if [ "$DRY_RUN" = true ]; then
            printf "  ${CYAN}○ %s (dry run)${NC}\n" "$base"
            continue
        fi

        local file_start=$(date +%s%N 2>/dev/null || date +%s)
        run_sql "$filepath" "$vars"
        local rc=$?
        local file_end=$(date +%s%N 2>/dev/null || date +%s)
        local duration_ms=$(( (file_end - file_start) / 1000000 )) 2>/dev/null || duration_ms=0

        local version=""
        local parsed=$(parse_filename "$base")
        if [ -n "$parsed" ]; then
            version=$(echo "$parsed" | cut -d'|' -f1)
        fi
        local size=$(file_size "$filepath")
        [ -z "$size" ] && size=0

        if [ $rc -ne 0 ]; then
            record_history_apply "$file_db_id" "$name" "$type" "$slug" "$version" "$base" "$file_id" "$sha" "$size" "$duration_ms" "false" "$RUN_SQL_ERROR_MESSAGE"
            echo ""
            printf "${RED}${BOLD}Migration failed${NC}  ${GRAY}%d files completed${NC}\n" "$total_files"
            echo ""
            local total_dur=$(( $(date +%s) - start_time ))
            update_state_run "up" "failed" "$((total_dur * 1000))"
            exit 1
        fi

        record_history_apply "$file_db_id" "$name" "$type" "$slug" "$version" "$base" "$file_id" "$sha" "$size" "$duration_ms" "true" ""
        total_files=$((total_files + 1))

        if [ -n "$target" ] && echo "$file_id" | grep -qiE "$target"; then
            break
        fi
    done < <(collect_all_files)

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    update_state_run "up" "success" "$((duration * 1000))"

    echo ""
    printf "${GREEN}${BOLD}Migration complete${NC}  ${GRAY}%d applied  %d skipped  %ds${NC}\n" "$total_files" "$total_skipped" "$duration"
    echo ""
}

function migrate_check() {
    boot_check
    if ! validate_filenames; then
        echo ""
        printf "${RED}Filename grammar check failed${NC}\n"
        echo ""
        exit 1
    fi
    if ! preflight_scan; then
        exit 1
    fi
    printf "${GREEN}${BOLD}Preflight passed${NC}\n\n"
}

function quote_idents_csv() {
    local csv="$1"
    local out=""
    IFS=',' read -ra parts <<< "$csv"
    for p in "${parts[@]}"; do
        [ -z "$p" ] && continue
        [ -n "$out" ] && out+=","
        out+="'$(sql_escape "$p")'"
    done
    printf "%s" "$out"
}

function dump_objects_for_schemas() {
    local schemas_csv="$1"
    local source_uses_grant="$2"
    local source_uses_comment="$3"
    local source_uses_policy="$4"
    local source_uses_extension="$5"
    local source_uses_default_priv="$6"
    local source_uses_seq_owned="$7"
    local out_file="$8"

    local q_schemas=$(quote_idents_csv "$schemas_csv")

    : > "$out_file"

    if [ "$source_uses_extension" = "true" ]; then
        run_psql_query "SELECT 'CREATE EXTENSION IF NOT EXISTS '||quote_ident(extname)||' WITH SCHEMA '||quote_ident(n.nspname)||';' FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE n.nspname IN ($q_schemas) ORDER BY extname" >> "$out_file"
        echo "" >> "$out_file"
    fi

    run_psql_query "SELECT 'CREATE TYPE '||quote_ident(n.nspname)||'.'||quote_ident(t.typname)||' AS ENUM ('||string_agg(quote_literal(e.enumlabel), ', ' ORDER BY e.enumsortorder)||');' FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace JOIN pg_enum e ON e.enumtypid = t.oid WHERE n.nspname IN ($q_schemas) GROUP BY n.nspname, t.typname ORDER BY n.nspname, t.typname" >> "$out_file"

    local psql_args=()
    while IFS= read -r a; do psql_args+=("$a"); done < <(psql_base_args)
    psql_args+=(-tA -F'|' -c "SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname IN ($q_schemas) ORDER BY n.nspname, c.relname")
    local tables=$(PGPASSWORD="$PGPASSWORD" psql "${psql_args[@]}" 2>/dev/null)

    local pg_dump_args=(--username "$PGUSER" --dbname "$PGDATABASE" --schema-only --no-owner --no-comments --no-publications --no-subscriptions)
    [ -n "$PGHOST" ] && pg_dump_args=(--host "$PGHOST" "${pg_dump_args[@]}")
    [ -n "$PGPORT" ] && pg_dump_args=(--port "$PGPORT" "${pg_dump_args[@]}")
    IFS=',' read -ra schema_arr <<< "$schemas_csv"
    for s in "${schema_arr[@]}"; do
        pg_dump_args+=(--schema="$s")
    done

    PGPASSWORD="$PGPASSWORD" pg_dump "${pg_dump_args[@]}" 2>/dev/null | awk '/^CREATE TABLE /,/;$/' >> "$out_file"
    echo "" >> "$out_file"

    run_psql_query "SELECT indexdef||';' FROM pg_indexes WHERE schemaname IN ($q_schemas) ORDER BY schemaname, indexname" >> "$out_file"

    run_psql_query "SELECT 'CREATE OR REPLACE VIEW '||quote_ident(n.nspname)||'.'||quote_ident(c.relname)||' AS '||pg_get_viewdef(c.oid, true) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('v','m') AND n.nspname IN ($q_schemas) ORDER BY n.nspname, c.relname" >> "$out_file"
    echo "" >> "$out_file"

    run_psql_query "SELECT pg_get_functiondef(p.oid)||';' FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname IN ($q_schemas) AND p.prokind IN ('f','p') ORDER BY n.nspname, p.proname" >> "$out_file"
    echo "" >> "$out_file"

    run_psql_query "SELECT pg_get_triggerdef(t.oid, true)||';' FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE NOT t.tgisinternal AND n.nspname IN ($q_schemas) ORDER BY n.nspname, c.relname, t.tgname" >> "$out_file"
    echo "" >> "$out_file"

    if [ "$source_uses_grant" = "true" ]; then
        run_psql_query "SELECT 'GRANT '||privilege_type||' ON TABLE '||quote_ident(table_schema)||'.'||quote_ident(table_name)||' TO '||grantee||';' FROM information_schema.table_privileges WHERE table_schema IN ($q_schemas) AND grantee NOT IN ('PUBLIC','postgres') ORDER BY table_schema, table_name, grantee, privilege_type" >> "$out_file"
        echo "" >> "$out_file"
    fi

    if [ "$source_uses_comment" = "true" ]; then
        run_psql_query "SELECT 'COMMENT ON '||CASE c.relkind WHEN 'r' THEN 'TABLE' WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' END||' '||quote_ident(n.nspname)||'.'||quote_ident(c.relname)||' IS '||quote_literal(d.description)||';' FROM pg_description d JOIN pg_class c ON c.oid = d.objoid AND d.objsubid = 0 JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname IN ($q_schemas) AND c.relkind IN ('r','v','m') ORDER BY n.nspname, c.relname" >> "$out_file"
        echo "" >> "$out_file"
    fi

    if [ "$source_uses_policy" = "true" ]; then
        run_psql_query "SELECT 'CREATE POLICY '||quote_ident(policyname)||' ON '||quote_ident(schemaname)||'.'||quote_ident(tablename)||' '||COALESCE('AS '||permissive||' ','')||'FOR '||cmd||' TO '||array_to_string(roles, ', ')||COALESCE(' USING ('||qual||')','')||COALESCE(' WITH CHECK ('||with_check||')','')||';' FROM pg_policies WHERE schemaname IN ($q_schemas) ORDER BY schemaname, tablename, policyname" >> "$out_file"
        echo "" >> "$out_file"
    fi

    if [ "$source_uses_default_priv" = "true" ]; then
        run_psql_query "SELECT 'ALTER DEFAULT PRIVILEGES IN SCHEMA '||quote_ident(n.nspname)||' GRANT '||string_agg(p,', ')||' ON '||object_type||' TO '||grantee||';' FROM (SELECT n.nspname, CASE d.defaclobjtype WHEN 'r' THEN 'TABLES' WHEN 'f' THEN 'FUNCTIONS' WHEN 'S' THEN 'SEQUENCES' WHEN 'T' THEN 'TYPES' END AS object_type, unnest(d.defaclacl)::text AS acl_entry FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace WHERE n.nspname IN ($q_schemas)) x WHERE 1=0" >> "$out_file" 2>/dev/null
    fi

    if [ "$source_uses_seq_owned" = "true" ]; then
        run_psql_query "SELECT 'ALTER SEQUENCE '||quote_ident(s.sequence_schema)||'.'||quote_ident(s.sequence_name)||' OWNED BY '||quote_ident(deps.refobjschema)||'.'||quote_ident(deps.refobjname)||'.'||quote_ident(deps.refobjcol)||';' FROM information_schema.sequences s WHERE s.sequence_schema IN ($q_schemas)" >> "$out_file" 2>/dev/null
    fi
}

function source_uses() {
    local pattern="$1"
    shift
    for f in "$@"; do
        grep -qiE "$pattern" "$f" 2>/dev/null && return 0
    done
    return 1
}

function state_command() {
    boot_check
    local target="${1:-}"

    local out_dir="${STATE_OUT:-}"
    [ -n "$out_dir" ] && mkdir -p "$out_dir"

    declare -A step_files

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local idx=$(echo "$entry" | cut -d'|' -f1)
        local name=$(echo "$entry" | cut -d'|' -f2)
        local type=$(echo "$entry" | cut -d'|' -f3)
        local slug=$(echo "$entry" | cut -d'|' -f4)
        local schemas=$(echo "$entry" | cut -d'|' -f5)
        local filepath=$(echo "$entry" | cut -d'|' -f7)

        [ "$type" = "seed" ] && continue
        [ -n "$target" ] && ! echo "$name" | grep -qiE "$target" && continue

        local key="${idx}|${name}|${type}|${slug}|${schemas}"
        step_files["$key"]+="$filepath"$'\n'
    done < <(collect_all_files)

    for key in "${!step_files[@]}"; do
        local idx=$(echo "$key" | cut -d'|' -f1)
        local name=$(echo "$key" | cut -d'|' -f2)
        local type=$(echo "$key" | cut -d'|' -f3)
        local slug=$(echo "$key" | cut -d'|' -f4)
        local schemas=$(echo "$key" | cut -d'|' -f5)
        local files="${step_files[$key]}"

        local uses_grant=false uses_comment=false uses_policy=false uses_extension=false uses_default_priv=false uses_seq_owned=false
        local file_list=()
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            file_list+=("$f")
        done <<< "$files"

        source_uses 'GRANT|REVOKE' "${file_list[@]}" && uses_grant=true
        source_uses 'COMMENT[[:space:]]+ON' "${file_list[@]}" && uses_comment=true
        source_uses 'CREATE[[:space:]]+POLICY|ROW[[:space:]]+LEVEL[[:space:]]+SECURITY' "${file_list[@]}" && uses_policy=true
        source_uses 'CREATE[[:space:]]+EXTENSION' "${file_list[@]}" && uses_extension=true
        source_uses 'ALTER[[:space:]]+DEFAULT[[:space:]]+PRIVILEGES' "${file_list[@]}" && uses_default_priv=true
        source_uses 'ALTER[[:space:]]+SEQUENCE[[:space:]].*OWNED[[:space:]]+BY' "${file_list[@]}" && uses_seq_owned=true

        local tmp_out=$(mktemp)
        dump_objects_for_schemas "$schemas" "$uses_grant" "$uses_comment" "$uses_policy" "$uses_extension" "$uses_default_priv" "$uses_seq_owned" "$tmp_out"

        if [ -n "$out_dir" ]; then
            local target_file="$out_dir/${slug:-step$idx}.sql"
            {
                printf -- "-- step %s\n" "$name"
                printf -- "-- type %s slug %s schemas %s\n" "$type" "$slug" "$schemas"
                printf -- "-- generated by migrate.sh %s at %s\n\n" "$SCRIPT_VERSION" "$(now_iso)"
                cat "$tmp_out"
            } > "$target_file"
            success "wrote $target_file"
        else
            printf "\n${CYAN}${BOLD}-- %s${NC}\n" "$name"
            printf "${GRAY}-- type=%s slug=%s schemas=%s${NC}\n" "$type" "$slug" "$schemas"
            cat "$tmp_out"
        fi
        rm -f "$tmp_out"
    done
}

function source_files_for_slug() {
    local target_slug="$1"
    for ((i=0; i<${#STEP_NAMES[@]}; i++)); do
        local slug="${STEP_SLUGS[$i]}"
        local type="${STEP_TYPES[$i]}"
        if [ "$slug" = "$target_slug" ] && [ "$type" = "base" ]; then
            local includes="${STEP_INCLUDES[$i]}"
            local excludes="${STEP_EXCLUDES[$i]}"
            IFS=',' read -ra inc_paths <<< "$includes"
            for path in "${inc_paths[@]}"; do
                [ -z "$path" ] && continue
                while IFS= read -r resolved; do
                    [ -z "$resolved" ] && continue
                    echo "$resolved"
                done < <(resolve_include "$path" "$excludes")
            done
        fi
    done
}

function build_identifier_registry() {
    local registry_file="$1"
    : > "$registry_file"
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local type=$(echo "$entry" | cut -d'|' -f3)
        [ "$type" != "base" ] && continue
        local filepath=$(echo "$entry" | cut -d'|' -f7)
        local rel=$(basename "$(dirname "$filepath")")/$(basename "$filepath")

        grep -oiE 'CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?(FUNCTION|PROCEDURE|TABLE|VIEW|TRIGGER|TYPE|INDEX|SEQUENCE|MATERIALIZED[[:space:]]+VIEW)[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?[a-z_0-9.]+' "$filepath" 2>/dev/null | \
            while IFS= read -r line; do
                local ident=$(echo "$line" | awk '{print $NF}')
                echo "$ident|$rel" >> "$registry_file"
            done
    done < <(collect_all_files)
}

function find_base_file_for_identifier() {
    local ident="$1"
    local registry_file="$2"
    local bare="${ident##*.}"
    local match
    match=$(grep -E "^[^|]*\.${bare}\|" "$registry_file" 2>/dev/null | head -1)
    [ -z "$match" ] && match=$(grep -E "^${bare}\|" "$registry_file" 2>/dev/null | head -1)
    [ -n "$match" ] && echo "$match" | cut -d'|' -f2
}

function merge_command() {
    boot_check

    local upgraded_dir="$(dirname "$STEPS_FILE")/.upgraded"

    if [ -d "$upgraded_dir" ] && [ -n "$(ls -A "$upgraded_dir" 2>/dev/null)" ]; then
        if [ "$FORCE" != true ]; then
            fail ".upgraded/ already exists with content. Use --force to overwrite."
            exit 1
        fi
        rm -rf "$upgraded_dir"
    fi

    if ! validate_filenames; then
        echo ""
        printf "${RED}Filename grammar check failed${NC}\n"
        echo ""
        exit 1
    fi

    if ! preflight_scan; then
        exit 1
    fi

    local pending=$(run_psql_cmd "SELECT count(*) FROM samna_migrate.file WHERE state = 'pending'")
    if [ "$pending" -gt 0 ]; then
        fail "$pending pending migrations on disk. Run 'migrate.sh up' first."
        exit 1
    fi

    mkdir -p "$upgraded_dir"

    header "pass 1: live SQL into .upgraded/" "$CYAN"

    declare -A step_files
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local idx=$(echo "$entry" | cut -d'|' -f1)
        local name=$(echo "$entry" | cut -d'|' -f2)
        local type=$(echo "$entry" | cut -d'|' -f3)
        local slug=$(echo "$entry" | cut -d'|' -f4)
        local schemas=$(echo "$entry" | cut -d'|' -f5)
        local filepath=$(echo "$entry" | cut -d'|' -f7)

        [ "$type" = "migration" ] && continue

        local key="${idx}|${name}|${type}|${slug}|${schemas}"
        step_files["$key"]+="$filepath"$'\n'
    done < <(collect_all_files)

    for key in "${!step_files[@]}"; do
        local idx=$(echo "$key" | cut -d'|' -f1)
        local name=$(echo "$key" | cut -d'|' -f2)
        local type=$(echo "$key" | cut -d'|' -f3)
        local slug=$(echo "$key" | cut -d'|' -f4)
        local schemas=$(echo "$key" | cut -d'|' -f5)
        local files="${step_files[$key]}"

        local uses_grant=false uses_comment=false uses_policy=false uses_extension=false uses_default_priv=false uses_seq_owned=false
        local file_list=()
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            file_list+=("$f")
        done <<< "$files"

        source_uses 'GRANT|REVOKE' "${file_list[@]}" && uses_grant=true
        source_uses 'COMMENT[[:space:]]+ON' "${file_list[@]}" && uses_comment=true
        source_uses 'CREATE[[:space:]]+POLICY|ROW[[:space:]]+LEVEL[[:space:]]+SECURITY' "${file_list[@]}" && uses_policy=true
        source_uses 'CREATE[[:space:]]+EXTENSION' "${file_list[@]}" && uses_extension=true
        source_uses 'ALTER[[:space:]]+DEFAULT[[:space:]]+PRIVILEGES' "${file_list[@]}" && uses_default_priv=true
        source_uses 'ALTER[[:space:]]+SEQUENCE[[:space:]].*OWNED[[:space:]]+BY' "${file_list[@]}" && uses_seq_owned=true

        local merged=$(mktemp)
        dump_objects_for_schemas "$schemas" "$uses_grant" "$uses_comment" "$uses_policy" "$uses_extension" "$uses_default_priv" "$uses_seq_owned" "$merged"

        for f in "${file_list[@]}"; do
            local rel_dir=$(basename "$(dirname "$f")")
            local rel_file=$(basename "$f")
            local out_dir="$upgraded_dir/$rel_dir"
            mkdir -p "$out_dir"
            local out_file="$out_dir/$rel_file"
            if [ "$type" = "seed" ]; then
                emit_seed_flat "$f" "$schemas" "$out_file" "$name" "$slug"
            else
                {
                    printf -- "-- step %s\n" "$name"
                    printf -- "-- type %s slug %s schemas %s\n" "$type" "$slug" "$schemas"
                    printf -- "-- generated by migrate.sh %s at %s\n" "$SCRIPT_VERSION" "$(now_iso)"
                    printf -- "-- source %s\n\n" "$f"
                    cat "$merged"
                } > "$out_file"
            fi
            success "wrote ${out_file#$upgraded_dir/}"
        done
        rm -f "$merged"
    done

    header "pass 2: route migrations" "$CYAN"

    local registry=$(mktemp)
    build_identifier_registry "$registry"

    mkdir -p "$upgraded_dir/migrations"

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local type=$(echo "$entry" | cut -d'|' -f3)
        [ "$type" != "migration" ] && continue
        local filepath=$(echo "$entry" | cut -d'|' -f7)
        local base=$(basename "$filepath")

        local introduced=$(grep -oiE 'CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?(FUNCTION|PROCEDURE|TABLE|VIEW|TRIGGER|TYPE|INDEX|SEQUENCE)[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?[a-z_0-9.]+' "$filepath" 2>/dev/null | awk '{print $NF}' | sort -u)

        local route_count=0
        local route_target=""
        local outcome="placeholder"

        if [ -n "$introduced" ]; then
            while IFS= read -r ident; do
                [ -z "$ident" ] && continue
                local target=$(find_base_file_for_identifier "$ident" "$registry")
                if [ -n "$target" ]; then
                    route_count=$((route_count + 1))
                    route_target="$target"
                fi
            done <<< "$introduced"
        fi

        if [ "$route_count" -gt 0 ]; then
            outcome="folded into $route_target"
            : > "$upgraded_dir/migrations/$base"
            printf "  ${GREEN}✓${NC} %s ${GRAY}-> %s${NC}\n" "$base" "$route_target"
        else
            outcome="unrouted"
            cp "$filepath" "$upgraded_dir/migrations/$base"
            printf "  ${YELLOW}!${NC} %s ${GRAY}-> .upgraded/migrations (review)${NC}\n" "$base"
        fi
    done < <(collect_all_files)

    rm -f "$registry"

    echo ""
    success ".upgraded/ ready at $upgraded_dir"
    info "review the tree, then run: migrate.sh migrate --apply"
    echo ""
}

function emit_seed_flat() {
    local source_file="$1"
    local schemas_csv="$2"
    local out_file="$3"
    local step_name="$4"
    local slug="$5"

    local q_schemas=$(quote_idents_csv "$schemas_csv")

    {
        printf -- "-- step %s\n" "$step_name"
        printf -- "-- type seed slug %s schemas %s\n" "$slug" "$schemas_csv"
        printf -- "-- generated by migrate.sh %s at %s\n" "$SCRIPT_VERSION" "$(now_iso)"
        printf -- "-- source %s\n\n" "$source_file"
    } > "$out_file"

    local inserts=$(grep -oiE 'INSERT[[:space:]]+INTO[[:space:]]+[a-z_0-9.]+' "$source_file" 2>/dev/null | awk '{print $3}' | sort -u)
    if [ -z "$inserts" ]; then
        echo "-- seed source declared no INSERT targets; review manually" >> "$out_file"
        return
    fi

    while IFS= read -r tbl; do
        [ -z "$tbl" ] && continue
        local schema_part="public"
        local table_part="$tbl"
        if [[ "$tbl" == *.* ]]; then
            schema_part="${tbl%%.*}"
            table_part="${tbl##*.}"
        fi
        local cols=$(run_psql_query "SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema = '$(sql_escape "$schema_part")' AND table_name = '$(sql_escape "$table_part")'")
        [ -z "$cols" ] && continue
        echo "" >> "$out_file"
        echo "-- $tbl" >> "$out_file"
        run_psql_query "SELECT 'INSERT INTO $(sql_escape "$schema_part").$(sql_escape "$table_part") ($cols) VALUES ('||(SELECT string_agg(CASE WHEN v IS NULL THEN 'NULL' ELSE quote_literal(v) END, ', ') FROM unnest(ARRAY(SELECT (row_to_json(t))::jsonb->>k FROM jsonb_object_keys(row_to_json(t)::jsonb) k))::text[] AS v)||');' FROM ${schema_part}.${table_part} t" >> "$out_file" 2>/dev/null
    done <<< "$inserts"
}

function merge_apply() {
    boot_check
    local upgraded_dir="$(dirname "$STEPS_FILE")/.upgraded"
    if [ ! -d "$upgraded_dir" ] || [ -z "$(ls -A "$upgraded_dir" 2>/dev/null)" ]; then
        fail ".upgraded/ is missing or empty"
        exit 1
    fi

    local ts=$(now_timestamp)
    local source_root="$(dirname "$STEPS_FILE")"

    local tree_sha=$(find "$source_root" -type f -name '*.sql' -not -path "*/.upgraded/*" -not -path "*/.migrate-*" 2>/dev/null | sort | xargs cat 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-8)
    local snap_dir="$source_root/.migrate-${ts}-${tree_sha}"

    if [ "$TAG" = true ]; then
        if ! detect_dep git; then
            fail "git not found, cannot create tag"
            exit 1
        fi
        if ! git -C "$source_root" rev-parse --git-dir >/dev/null 2>&1; then
            fail "source tree is not inside a git repository"
            exit 1
        fi
        if [ -n "$(git -C "$source_root" status --porcelain)" ]; then
            fail "git working tree is not clean, refusing to tag"
            exit 1
        fi
    fi

    header "snapshot source tree" "$CYAN"
    mkdir -p "$snap_dir"
    local moved_files=0
    for ((i=0; i<${#STEP_NAMES[@]}; i++)); do
        local includes="${STEP_INCLUDES[$i]}"
        IFS=',' read -ra inc_paths <<< "$includes"
        for path in "${inc_paths[@]}"; do
            [ -z "$path" ] && continue
            local first="${path%%;*}"
            local resolved
            resolved=$(resolve_path "$first" "")
            [ -z "$resolved" ] && continue
            if [ -d "$resolved" ]; then
                local rel=$(basename "$resolved")
                mkdir -p "$snap_dir/$rel"
                cp -R "$resolved/." "$snap_dir/$rel/"
            fi
        done
    done
    success "snapshot at $snap_dir"

    if [ "$TAG" = true ]; then
        local tag_name="migrate-apply-${ts}-${tree_sha}"
        git -C "$source_root" tag -a "$tag_name" -m "snapshot $snap_dir" >/dev/null
        success "git tag $tag_name"
    fi

    header "move .upgraded/ into source tree" "$CYAN"
    local total_moved=0
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        local rel="${src#$upgraded_dir/}"
        local dest="$source_root/$rel"
        mkdir -p "$(dirname "$dest")"
        if [ ! -s "$src" ]; then
            if [ -f "$dest" ]; then
                rm -f "$dest"
                printf "  ${GRAY}- removed %s (folded)${NC}\n" "$rel"
            fi
        else
            mv "$src" "$dest"
            printf "  ${GREEN}+${NC} %s\n" "$rel"
            total_moved=$((total_moved + 1))
        fi
    done < <(find "$upgraded_dir" -type f -name '*.sql' | sort)

    rm -rf "$upgraded_dir"
    success "removed .upgraded/"

    header "reconcile samna_migrate.file" "$CYAN"
    local folded=0
    local rekeyed=0

    declare -A disk_paths
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local filepath=$(echo "$entry" | cut -d'|' -f7)
        local dir=$(basename "$(dirname "$filepath")")
        local base=$(basename "$filepath")
        disk_paths["$dir/$base"]=1
    done < <(collect_all_files)

    local applied_rows=$(run_psql_query "SELECT id, file_path, step_type FROM samna_migrate.file WHERE state = 'applied'")
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        local rid=$(echo "$row" | cut -d'|' -f1)
        local fp=$(echo "$row" | cut -d'|' -f2)
        local st=$(echo "$row" | cut -d'|' -f3)
        if [ -z "${disk_paths[$fp]}" ]; then
            if [ "$st" = "migration" ]; then
                run_psql_cmd "UPDATE samna_migrate.file SET state = 'folded', folded_at = NOW() WHERE id = $rid" > /dev/null
                folded=$((folded + 1))
                printf "  ${GRAY}○ folded %s${NC}\n" "$fp"
            else
                run_psql_cmd "UPDATE samna_migrate.file SET removed_from_disk_at = NOW() WHERE id = $rid" > /dev/null
            fi
        fi
    done <<< "$applied_rows"

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local name=$(echo "$entry" | cut -d'|' -f2)
        local type=$(echo "$entry" | cut -d'|' -f3)
        local slug=$(echo "$entry" | cut -d'|' -f4)
        local filepath=$(echo "$entry" | cut -d'|' -f7)
        local dir=$(basename "$(dirname "$filepath")")
        local base=$(basename "$filepath")
        local file_id="${dir}/${base}"
        local sha=$(file_sha256 "$filepath")
        local size=$(file_size "$filepath")
        [ -z "$size" ] && size=0

        local exists=$(run_psql_cmd "SELECT 1 FROM samna_migrate.file WHERE file_path = '$(sql_escape "$file_id")'")
        if [ -z "$exists" ]; then
            local file_slug="$slug"
            local file_ver=""
            local parsed=$(parse_filename "$base")
            if [ -n "$parsed" ]; then
                file_ver=$(echo "$parsed" | cut -d'|' -f1)
                file_slug=$(echo "$parsed" | cut -d'|' -f2)
            fi
            run_psql_cmd "INSERT INTO samna_migrate.file (step_name, step_type, slug, version, file_name, file_path, sha256, size_bytes, state) VALUES ('$(sql_escape "$name")', '$(sql_escape "$type")', '$(sql_escape "$file_slug")', NULLIF('$(sql_escape "$file_ver")', ''), '$(sql_escape "$base")', '$(sql_escape "$file_id")', '$(sql_escape "$sha")', $size, 'applied')" > /dev/null
            rekeyed=$((rekeyed + 1))
        else
            run_psql_cmd "UPDATE samna_migrate.file SET sha256 = '$(sql_escape "$sha")', size_bytes = $size WHERE file_path = '$(sql_escape "$file_id")'" > /dev/null
        fi
    done < <(collect_all_files)

    run_psql_cmd "INSERT INTO samna_migrate.history (step_name, file_path, action_type, tool_version, executed_by, host, database, duration_ms, success, notes) VALUES ('apply', '$(sql_escape "$snap_dir")', 'merge_apply', '$(sql_escape "$SCRIPT_VERSION")', '$(sql_escape "$PGUSER")', '$(sql_escape "${PGHOST:-localhost}")', '$(sql_escape "$PGDATABASE")', 0, true, 'moved=$total_moved folded=$folded rekeyed=$rekeyed')" > /dev/null

    echo ""
    printf "${GREEN}${BOLD}apply complete${NC}  ${GRAY}moved=%d folded=%d rekeyed=%d${NC}\n" "$total_moved" "$folded" "$rekeyed"
    printf "${GRAY}snapshot retained at %s${NC}\n" "$snap_dir"
    echo ""
}

function merge_revert() {
    boot_check
    local name="${1:-}"
    local source_root="$(dirname "$STEPS_FILE")"
    local snap_dir=""

    if [ -n "$name" ]; then
        snap_dir="$source_root/.migrate-${name}"
        if [ ! -d "$snap_dir" ]; then
            snap_dir="$source_root/.migrate-${name#.migrate-}"
        fi
    else
        snap_dir=$(ls -dt "$source_root"/.migrate-* 2>/dev/null | head -1)
    fi

    if [ -z "$snap_dir" ] || [ ! -d "$snap_dir" ]; then
        fail "no snapshot found"
        exit 1
    fi

    local last_action=$(run_psql_cmd "SELECT action_type FROM samna_migrate.history WHERE action_type IN ('merge_apply','merge_revert') ORDER BY id DESC LIMIT 1")
    if [ "$last_action" != "merge_apply" ] && [ "$FORCE" != true ]; then
        fail "most recent merge action is not merge_apply; revert requires --force"
        exit 1
    fi

    local ts=$(now_timestamp)
    local tree_sha=$(find "$source_root" -type f -name '*.sql' -not -path "*/.upgraded/*" -not -path "*/.migrate-*" 2>/dev/null | sort | xargs cat 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-8)
    local pre_revert_snap="$source_root/.migrate-${ts}-${tree_sha}"

    header "snapshot current tree before revert" "$CYAN"
    mkdir -p "$pre_revert_snap"
    for ((i=0; i<${#STEP_NAMES[@]}; i++)); do
        local includes="${STEP_INCLUDES[$i]}"
        IFS=',' read -ra inc_paths <<< "$includes"
        for path in "${inc_paths[@]}"; do
            [ -z "$path" ] && continue
            local first="${path%%;*}"
            local resolved
            resolved=$(resolve_path "$first" "")
            [ -z "$resolved" ] && continue
            if [ -d "$resolved" ]; then
                local rel=$(basename "$resolved")
                mkdir -p "$pre_revert_snap/$rel"
                cp -R "$resolved/." "$pre_revert_snap/$rel/"
            fi
        done
    done
    success "pre revert snapshot at $pre_revert_snap"

    header "restore from $snap_dir" "$CYAN"
    local restored=0
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        local rel="${src#$snap_dir/}"
        local dest="$source_root/$rel"
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        printf "  ${GREEN}+${NC} %s\n" "$rel"
        restored=$((restored + 1))
    done < <(find "$snap_dir" -type f -name '*.sql' | sort)

    header "reconcile samna_migrate.file" "$CYAN"
    run_psql_cmd "UPDATE samna_migrate.file SET state = 'applied', folded_at = NULL WHERE state = 'folded' AND folded_at > (SELECT applied_at FROM samna_migrate.history WHERE action_type = 'merge_apply' ORDER BY id DESC LIMIT 1)" > /dev/null

    run_psql_cmd "INSERT INTO samna_migrate.history (step_name, file_path, action_type, tool_version, executed_by, host, database, duration_ms, success, notes) VALUES ('revert', '$(sql_escape "$snap_dir")', 'merge_revert', '$(sql_escape "$SCRIPT_VERSION")', '$(sql_escape "$PGUSER")', '$(sql_escape "${PGHOST:-localhost}")', '$(sql_escape "$PGDATABASE")', 0, true, 'restored=$restored pre_revert_snapshot=$pre_revert_snap')" > /dev/null

    echo ""
    printf "${GREEN}${BOLD}revert complete${NC}  ${GRAY}restored=%d${NC}\n" "$restored"
    printf "${GRAY}pre revert snapshot retained at %s${NC}\n" "$pre_revert_snap"
    echo ""
}

parse_flags "$@"

COMMAND="${ARGS[0]:-help}"
TARGET="${ARGS[1]:-}"

if [ "$HELP" = true ]; then
    show_help "$COMMAND"
    exit 0
fi

if [ "$COMMAND" = "merge" ]; then
    if [ "$APPLY" = true ]; then
        ensure_deps
        if [ "$STEPS_FILE" ] && [ -f "$STEPS_FILE" ]; then
            load_steps
        fi
        merge_apply
        exit 0
    fi
    if [ "$REVERT" = true ]; then
        ensure_deps
        if [ "$STEPS_FILE" ] && [ -f "$STEPS_FILE" ]; then
            load_steps
        fi
        merge_revert "$TARGET"
        exit 0
    fi
fi

ensure_deps

if [ "$COMMAND" != "help" ] && [ "$COMMAND" != "schema" ] || [ -f "$STEPS_FILE" ]; then
    load_steps
fi

case "$COMMAND" in
    help|--help|-h) show_help "$TARGET" ;;
    list)           list_steps ;;
    up)             migrate_up "$TARGET" ;;
    check)          migrate_check ;;
    state)          state_command "$TARGET" ;;
    merge)          merge_command ;;
    upgrade)        upgrade_command ;;
    doctor)         doctor "$TARGET" ;;
    schema)         schema_cmd ;;
    stat)           migrate_stat ;;
    delete)         migrate_delete ;;
    *)
        fail "Unknown command: $COMMAND"
        show_help
        ;;
esac
