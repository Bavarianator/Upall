#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# UPALL v2.0.0 – Universal Linux Updater
# ═══════════════════════════════════════════════════════════════════════════════
# Installation:
#   curl -L https://raw.githubusercontent.com/yourrepo/upall/main/upall.sh -o upall.sh
#   chmod +x upall.sh
#   sudo mv upall.sh /usr/local/bin/upall
#
# Nutzung:
#   upall --normal           # Standard-Update
#   upall --nerd             # Verbose mit Details
#   upall --dry-run          # Simulation ohne Änderungen
#   upall --selective        # Interaktive Paketauswahl
#   upall --schedule         # Cronjob einrichten
#   upall --health           # Systemcheck ohne Update
#   upall --uninstall        # UPALL entfernen
#   upall --update-self      # UPALL selbst aktualisieren
#
# Konfiguration: ~/.config/UPALL/config
# Logs: ~/.local/share/UPALL/logs/
# Snapshots: ~/.local/share/UPALL/snapshots/
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail
IFS=$'\n\t'

# ── Konstanten ─────────────────────────────────────────────────────────────────
readonly VERSION="2.0.0"
readonly SCRIPT_NAME="upall"
readonly CONFIG_DIR="${HOME}/.config/UPALL"
readonly DATA_DIR="${HOME}/.local/share/UPALL"
readonly LOG_DIR="${DATA_DIR}/logs"
readonly SNAPSHOT_DIR="${DATA_DIR}/snapshots"
readonly CONFIG_FILE="${CONFIG_DIR}/config"
readonly LOCK_FILE="/tmp/UPALL.lock"
readonly MIN_DISK_MB=500
readonly PING_HOST="8.8.8.8"
readonly PING_TIMEOUT=5

# Farbdefinitionen für Terminal-Ausgabe
readonly COLOR_RESET='\e[0m'
readonly COLOR_BOLD='\e[1m'
readonly COLOR_RED='\e[31m'
readonly COLOR_GREEN='\e[32m'
readonly COLOR_YELLOW='\e[33m'
readonly COLOR_BLUE='\e[34m'
readonly COLOR_MAGENTA='\e[35m'
readonly COLOR_CYAN='\e[36m'

# Globale Zähler (werden in Funktionen inkrementiert)
UPALL_SUCCESS_COUNT=0
UPALL_FAIL_COUNT=0
UPALL_START_TIME=0

# Modus-Flags
MODE_NORMAL=false
MODE_NERD=false
MODE_DRY_RUN=false
MODE_QUIET=false
MODE_FORCE=false
MODE_SELECTIVE=false
MODE_ROLLBACK=false
MODE_SCHEDULE=false
MODE_HEALTH=false
MODE_UNINSTALL=false
MODE_UPDATE_SELF=false

# Konfigurationsvariablen (werden aus Config geladen)
LOG_RETENTION_DAYS=30
SNAPSHOT_LIMIT=10
AUTO_REBOOT_ON_KERNEL=false
NOTIFY_ON_FINISH=true
PRE_UPDATE_HOOK=""
POST_UPDATE_HOOK=""
EXCLUDE_PACKAGES=""
PARALLEL_DOWNLOADS=true

# Erkannte Systeminformationen
DETECTED_DISTRO=""
DETECTED_VERSION=""
DETECTED_PKG_MANAGER=""
KERNEL_UPDATED=false

# ── Hilfsfunktionen ────────────────────────────────────────────────────────────

# Farbausgabe sicher handhaben
color_output() {
    local color="$1"
    shift
    if [[ -t 1 ]]; then
        echo -ne "${color}"
        echo -n "$@"
        echo -ne "${COLOR_RESET}"
    else
        echo -n "$@"
    fi
}

# Log-Funktion mit Level und Zeitstempel
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%H:%M:%S')
    local log_file="${LOG_DIR}/upall_$(date '+%Y-%m-%d').log"
    
    # Log-Level Filter im Quiet-Modus
    if [[ "$MODE_QUIET" == true && "$level" != "ERROR" ]]; then
        return 0
    fi
    
    # Formatierung für Nerd-Modus
    local prefix=""
    if [[ "$MODE_NERD" == true ]]; then
        case "$level" in
            INFO)  prefix="[${COLOR_GREEN}INFO${COLOR_RESET}] " ;;
            WARN)  prefix="[${COLOR_YELLOW}WARN${COLOR_RESET}] " ;;
            ERROR) prefix="[${COLOR_RED}ERROR${COLOR_RESET}] " ;;
            DEBUG) prefix="[${COLOR_CYAN}DEBUG${COLOR_RESET}] " ;;
        esac
    else
        case "$level" in
            ERROR) prefix="[ERROR] " ;;
            WARN)  prefix="[WARN] " ;;
        esac
    fi
    
    # Ausgabe auf Terminal (wenn nicht quiet oder Fehler)
    if [[ "$MODE_QUIET" == false || "$level" == "ERROR" ]]; then
        if [[ "$MODE_NERD" == true && "$level" == "INFO" ]]; then
            echo -e "[${timestamp}] ${prefix}${message}"
        else
            echo -e "${prefix}${message}" >&2
        fi
    fi
    
    # Immer in Log-Datei schreiben
    mkdir -p "$LOG_DIR"
    local plain_message="[${timestamp}] [${level}] [${DETECTED_DISTRO:-unknown}] ${message}"
    echo "$plain_message" >> "$log_file"
}

# Debug-Log nur im Nerd-Modus
log_debug() {
    if [[ "$MODE_NERD" == true ]]; then
        log DEBUG "$@"
    fi
}

# Abhängigkeit prüfen
check_dep() {
    local cmd="$1"
    local package="${2:-$cmd}"
    
    if ! command -v "$cmd" &>/dev/null; then
        log WARN "Fehlende Abhängigkeit: $cmd (Paket: $package)"
        return 1
    fi
    return 0
}

# Alle benötigten Tools prüfen
check_dependencies() {
    local missing=()
    local critical=("bash" "date" "mkdir" "cat" "grep" "sed")
    local optional=("fzf" "notify-send" "fwupdmgr" "curl" "git")
    
    for cmd in "${critical[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Kritische Abhängigkeiten fehlen: ${missing[*]}"
        log ERROR "Installation abgebrochen."
        exit 1
    fi
    
    # Optionale Tools nur melden
    for cmd in "${optional[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_debug "Optionales Tool nicht verfügbar: $cmd"
        fi
    done
}

# Lock-Mechanismus mit PID-Prüfung
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            log ERROR "Eine andere Instanz läuft bereits (PID: $old_pid)"
            log ERROR "Lock-Datei: $LOCK_FILE"
            exit 1
        else
            log WARN "Stale lock erkannt, entferne alte Lock-Datei"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
    log_debug "Lock erworben (PID: $$)"
}

# Root-Rechte prüfen und ggf. sudo vorschlagen
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log WARN "Nicht als root ausgeführt. Einige Updates benötigen sudo."
        if command -v sudo &>/dev/null; then
            if [[ "$MODE_FORCE" == false ]]; then
                read -rp "Mit sudo neu starten? [y/N] " response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    exec sudo bash "$0" "$@"
                fi
            fi
        fi
        log WARN "Fahre ohne root-Rechte fort (eingeschränkte Funktionalität)"
    fi
}

# Netzwerkverbindung prüfen
check_network() {
    log INFO "Prüfe Netzwerkverbindung..."
    
    if command -v ping &>/dev/null; then
        if ping -c 1 -W "$PING_TIMEOUT" "$PING_HOST" &>/dev/null; then
            log INFO "Netzwerk: ✓ erreichbar"
            return 0
        else
            log WARN "Netzwerk: ✗ kein Zugriff auf $PING_HOST"
            if [[ "$MODE_FORCE" == false ]]; then
                read -rp "Ohne Netzwerk fortfahren? [y/N] " response
                if [[ ! "$response" =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            fi
            return 1
        fi
    else
        log_debug "ping nicht verfügbar, überspringe Netzwerktest"
        return 0
    fi
}

# Freier Speicherplatz prüfen
check_disk_space() {
    log INFO "Prüfe verfügbaren Speicher..."
    
    local available_kb
    available_kb=$(df -k / | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))
    
    if [[ $available_mb -lt $MIN_DISK_MB ]]; then
        log ERROR "Zu wenig Speicherplatz: ${available_mb}MB verfügbar (Minimum: ${MIN_DISK_MB}MB)"
        if [[ "$MODE_FORCE" == false ]]; then
            log ERROR "Update abgebrochen. Bitte Speicher freigeben oder --force verwenden."
            exit 1
        fi
        log WARN "Überspringe Speicherprüfung aufgrund von --force"
    else
        log INFO "Speicher: ${available_mb} MB frei ✓"
    fi
}

# Distro-Erkennung mit mehreren Fallbacks
detect_distro() {
    log_debug "Starte Distro-Erkennung..."
    
    # Primär: /etc/os-release
    if [[ -f /etc/os-release ]]; then
        # Variablen sicher auslesen ohne side-effects
        local os_name os_version os_id os_id_like
        os_name=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "")
        os_version=$(grep -E "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "")
        os_id=$(grep -E "^ID=" /etc/os-release 2>/dev/null | grep -v "ID_LIKE" | cut -d'"' -f2 || echo "")
        os_id_like=$(grep -E "^ID_LIKE=" /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "")
        
        DETECTED_DISTRO="${os_name:-unknown}"
        DETECTED_VERSION="${os_version:-unknown}"
        
        # Paketmanager aus ID_LIKE oder ID ableiten
        case "${os_id_like:-$os_id}" in
            *debian*|ubuntu*)
                DETECTED_PKG_MANAGER="apt"
                ;;
            *fedora*|rhel|centos|rocky|almalinux*)
                if command -v dnf &>/dev/null; then
                    DETECTED_PKG_MANAGER="dnf"
                else
                    DETECTED_PKG_MANAGER="yum"
                fi
                ;;
            *arch*)
                DETECTED_PKG_MANAGER="pacman"
                ;;
            *opensuse*|suse*)
                DETECTED_PKG_MANAGER="zypper"
                ;;
            *gentoo*)
                DETECTED_PKG_MANAGER="emerge"
                ;;
            *alpine*)
                DETECTED_PKG_MANAGER="apk"
                ;;
            *void*)
                DETECTED_PKG_MANAGER="xbps"
                ;;
            *nixos*)
                DETECTED_PKG_MANAGER="nix"
                ;;
            *)
                DETECTED_PKG_MANAGER="unknown"
                ;;
        esac
        
        log_debug "Erkannt via os-release: $DETECTED_DISTRO ($DETECTED_PKG_MANAGER)"
        return 0
    fi
    
    # Fallback 1: which <paketmanager>
    local managers=("apt-get" "dnf" "yum" "pacman" "zypper" "emerge" "apk" "xbps-install" "nix-env" "brew")
    for mgr in "${managers[@]}"; do
        if command -v "$mgr" &>/dev/null; then
            case "$mgr" in
                apt-get) DETECTED_PKG_MANAGER="apt" ;;
                xbps-install) DETECTED_PKG_MANAGER="xbps" ;;
                nix-env) DETECTED_PKG_MANAGER="nix" ;;
                *) DETECTED_PKG_MANAGER="${mgr%-*}" ;;
            esac
            DETECTED_DISTRO="Unknown (detected: $DETECTED_PKG_MANAGER)"
            DETECTED_VERSION="unknown"
            log_debug "Erkannt via which: $DETECTED_PKG_MANAGER"
            return 0
        fi
    done
    
    # Fallback 2: /etc/issue
    if [[ -f /etc/issue ]]; then
        local issue_content
        issue_content=$(cat /etc/issue)
        DETECTED_DISTRO="$issue_content"
        DETECTED_VERSION="unknown"
        
        case "$issue_content" in
            *Debian*) DETECTED_PKG_MANAGER="apt" ;;
            *Ubuntu*) DETECTED_PKG_MANAGER="apt" ;;
            *Fedora*) DETECTED_PKG_MANAGER="dnf" ;;
            *CentOS*) DETECTED_PKG_MANAGER="yum" ;;
            *Arch*) DETECTED_PKG_MANAGER="pacman" ;;
            *openSUSE*) DETECTED_PKG_MANAGER="zypper" ;;
            *Gentoo*) DETECTED_PKG_MANAGER="emerge" ;;
            *) DETECTED_PKG_MANAGER="unknown" ;;
        esac
        
        log_debug "Erkannt via /etc/issue: $DETECTED_DISTRO ($DETECTED_PKG_MANAGER)"
        return 0
    fi
    
    # Alles fehlgeschlagen
    DETECTED_DISTRO="unknown"
    DETECTED_VERSION="unknown"
    DETECTED_PKG_MANAGER="unknown"
    log WARN "Konnte Distribution nicht eindeutig erkennen"
    return 1
}

# Konfiguration laden oder erstellen
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_debug "Lade Konfiguration von $CONFIG_FILE"
        # Sicherer Config-Load ohne eval
        while IFS='=' read -r key value; do
            # Kommentare und leere Zeilen überspringen
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            case "$key" in
                LOG_RETENTION_DAYS) LOG_RETENTION_DAYS="$value" ;;
                SNAPSHOT_LIMIT) SNAPSHOT_LIMIT="$value" ;;
                AUTO_REBOOT_ON_KERNEL) AUTO_REBOOT_ON_KERNEL="$value" ;;
                NOTIFY_ON_FINISH) NOTIFY_ON_FINISH="$value" ;;
                PRE_UPDATE_HOOK) PRE_UPDATE_HOOK="$value" ;;
                POST_UPDATE_HOOK) POST_UPDATE_HOOK="$value" ;;
                EXCLUDE_PACKAGES) EXCLUDE_PACKAGES="$value" ;;
                PARALLEL_DOWNLOADS) PARALLEL_DOWNLOADS="$value" ;;
            esac
        done < "$CONFIG_FILE"
    else
        create_config
    fi
}

# Konfigurationsdatei erstellen
create_config() {
    log INFO "Erstelle Standard-Konfiguration..."
    mkdir -p "$CONFIG_DIR"
    
    cat > "$CONFIG_FILE" << 'EOF'
# UPALL Konfigurationsdatei
# Wird automatisch beim ersten Start erstellt

# Wie viele Tage Logs behalten werden
LOG_RETENTION_DAYS=30

# Maximale Anzahl an Snapshots
SNAPSHOT_LIMIT=10

# Automatischer Neustart bei Kernel-Update
AUTO_REBOOT_ON_KERNEL=false

# Desktop-Benachrichtigung bei Fertigstellung
NOTIFY_ON_FINISH=true

# Script das VOR dem Update ausgeführt wird (Pfad)
PRE_UPDATE_HOOK=""

# Script das NACH dem Update ausgeführt wird (Pfad)
POST_UPDATE_HOOK=""

# Pakete die vom Update ausgeschlossen werden (kommagetrennt)
EXCLUDE_PACKAGES=""

# Parallele Downloads aktivieren
PARALLEL_DOWNLOADS=true
EOF
    
    log INFO "Konfiguration gespeichert: $CONFIG_FILE"
}

# Logs rotieren (alte Logs löschen)
rotate_logs() {
    log_debug "Rotiere Logs (älter als $LOG_RETENTION_DAYS Tage)"
    
    find "$LOG_DIR" -name "*.log" -type f -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# Snapshot-Limit einhalten
cleanup_snapshots() {
    log_debug "Bereinige Snapshots (Maximal: $SNAPSHOT_LIMIT)"
    
    if [[ ! -d "$SNAPSHOT_DIR" ]]; then
        return 0
    fi
    
    local count
    count=$(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
    
    if [[ $count -gt $SNAPSHOT_LIMIT ]]; then
        local to_delete=$((count - SNAPSHOT_LIMIT))
        find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | \
            sort -n | head -n "$to_delete" | cut -d' ' -f2- | \
            xargs -r rm -rf
        log_debug "$to_delete alte Snapshots gelöscht"
    fi
}

# Paketliste sichern (Backup)
create_snapshot() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M')
    local snapshot_path="${SNAPSHOT_DIR}/${timestamp}"
    
    log INFO "Erstelle Snapshot: $snapshot_path"
    mkdir -p "$snapshot_path"
    
    case "$DETECTED_PKG_MANAGER" in
        apt)
            dpkg --get-selections > "${snapshot_path}/pkg_list.txt" 2>/dev/null || true
            ;;
        pacman)
            pacman -Qqe > "${snapshot_path}/pkg_list.txt" 2>/dev/null || true
            ;;
        dnf|yum)
            dnf history list 0 > "${snapshot_path}/history.txt" 2>/dev/null || true
            rpm -qa --qf '%{NAME}\n' > "${snapshot_path}/pkg_list.txt" 2>/dev/null || true
            ;;
        zypper)
            rpm -qa --qf '%{NAME}\n' > "${snapshot_path}/pkg_list.txt" 2>/dev/null || true
            ;;
        emerge)
            equery list '*' > "${snapshot_path}/pkg_list.txt" 2>/dev/null || true
            ;;
        apk)
            apk info > "${snapshot_path}/pkg_list.txt" 2>/dev/null || true
            ;;
        xbps)
            xbps-query -l > "${snapshot_path}/pkg_list.txt" 2>/dev/null || true
            ;;
        nix)
            nix-env -q > "${snapshot_path}/pkg_list.txt" 2>/dev/null || true
            ;;
        brew)
            brew list > "${snapshot_path}/pkg_list.txt" 2>/dev/null || true
            ;;
    esac
    
    cleanup_snapshots
    log INFO "Snapshot erstellt ✓"
}

# Rollback-Funktionalität (basis)
perform_rollback() {
    log INFO "Starte Rollback-Versuch..."
    
    if [[ ! -d "$SNAPSHOT_DIR" ]]; then
        log ERROR "Keine Snapshots vorhanden für Rollback"
        return 1
    fi
    
    local latest_snapshot
    latest_snapshot=$(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | \
        sort -rn | head -1 | cut -d' ' -f2-)
    
    if [[ -z "$latest_snapshot" ]]; then
        log ERROR "Kein gültiger Snapshot gefunden"
        return 1
    fi
    
    log INFO "Verwende Snapshot: $latest_snapshot"
    
    case "$DETECTED_PKG_MANAGER" in
        apt)
            if [[ -f "${latest_snapshot}/pkg_list.txt" ]]; then
                log INFO "Stelle apt-Paketauswahl wieder her..."
                dpkg --set-selections < "${latest_snapshot}/pkg_list.txt"
                log WARN "Bitte führe 'apt dselect-upgrade' manuell aus um den Rollback abzuschließen"
            fi
            ;;
        *)
            log WARN "Rollback für $DETECTED_PKG_MANAGER nicht vollständig automatisiert"
            log INFO "Manuelle Wiederherstellung nötig. Siehe Snapshot: $latest_snapshot"
            ;;
    esac
    
    log INFO "Rollback vorbereitet ✓"
}

# Universelle Update-Funktion mit Fehlerbehandlung
run_update() {
    local name="$1"
    local cmd="$2"
    
    log INFO "Starte: $name"
    
    if [[ "$MODE_DRY_RUN" == true ]]; then
        log INFO "[DRY-RUN] Würde ausführen: $cmd"
        UPALL_SUCCESS_COUNT=$((UPALL_SUCCESS_COUNT + 1))
        return 0
    fi
    
    local exit_code=0
    
    # Befehl ausführen und Fehler abfangen
    if eval "$cmd"; then
        log INFO "✓ $name erfolgreich"
        UPALL_SUCCESS_COUNT=$((UPALL_SUCCESS_COUNT + 1))
    else
        exit_code=$?
        log ERROR "✗ $name fehlgeschlagen (Exit: $exit_code)"
        UPALL_FAIL_COUNT=$((UPALL_FAIL_COUNT + 1))
        # Kein exit! Weitermachen mit nächstem Update
    fi
    
    return 0
}

# Haupt-Update je nach Paketmanager
run_pkg_manager_update() {
    case "$DETECTED_PKG_MANAGER" in
        apt)
            run_update "apt update" "apt-get update"
            run_update "apt upgrade" "apt-get upgrade -y"
            run_update "apt autoremove" "apt-get autoremove -y"
            run_update "apt autoclean" "apt-get autoclean"
            ;;
        dnf)
            run_update "dnf check-update" "dnf check-update" || true
            run_update "dnf upgrade" "dnf upgrade -y"
            run_update "dnf autoremove" "dnf autoremove -y"
            ;;
        yum)
            run_update "yum update" "yum update -y"
            run_update "yum autoremove" "yum autoremove -y"
            ;;
        pacman)
            run_update "pacman sync" "pacman -Syu --noconfirm"
            run_update "pacman clean" "pacman -Sc --noconfirm"
            ;;
        yay|paru)
            local aur_helper="${DETECTED_PKG_MANAGER}"
            if command -v "$aur_helper" &>/dev/null; then
                run_update "AUR update ($aur_helper)" "$aur_helper -Syu --noconfirm"
            else
                log WARN "AUR-Helper $aur_helper nicht gefunden"
            fi
            ;;
        zypper)
            run_update "zypper refresh" "zypper refresh"
            run_update "zypper update" "zypper update -y"
            run_update "zypper dist-upgrade" "zypper dist-upgrade -y"
            run_update "zypper clean" "zypper clean"
            ;;
        emerge)
            run_update "emerge sync" "emerge --sync"
            run_update "emerge update" "emerge -uDN @world"
            run_update "emerge depclean" "emerge --depclean"
            ;;
        apk)
            run_update "apk update" "apk update"
            run_update "apk upgrade" "apk upgrade"
            ;;
        xbps)
            run_update "xbps sync" "xbps-install -Suy"
            ;;
        nix)
            run_update "nix-channel update" "nix-channel --update"
            run_update "nix upgrade" "nix-env -u '*'"
            ;;
        brew)
            run_update "brew update" "brew update"
            run_update "brew upgrade" "brew upgrade"
            run_update "brew cleanup" "brew cleanup"
            ;;
        unknown)
            log WARN "Unbekannter Paketmanager, überspringe System-Update"
            ;;
    esac
    
    # Kernel-Update erkennen
    if [[ "$DETECTED_PKG_MANAGER" == "apt" || "$DETECTED_PKG_MANAGER" == "dnf" || "$DETECTED_PKG_MANAGER" == "pacman" ]]; then
        if [[ -f /var/run/reboot-required ]] || \
           [[ -f /.needrestart/restart_required ]] || \
           [[ $(rpm -qa kernel 2>/dev/null | wc -l) -gt 1 ]]; then
            KERNEL_UPDATED=true
            log WARN "Kernel-Update erkannt: Reboot empfohlen!"
        fi
    fi
}

# Flatpak Updates
update_flatpak() {
    if [[ "${UPALL_FLATPAK:-true}" != "true" ]]; then
        log_debug "Flatpak Updates deaktiviert"
        return 0
    fi
    
    if ! command -v flatpak &>/dev/null; then
        log_debug "Flatpak nicht installiert"
        return 0
    fi
    
    run_update "Flatpak Apps" "flatpak update -y"
}

# Snap Updates
update_snap() {
    if [[ "${UPALL_SNAP:-true}" != "true" ]]; then
        log_debug "Snap Updates deaktiviert"
        return 0
    fi
    
    if ! command -v snap &>/dev/null; then
        log_debug "Snap nicht installiert"
        return 0
    fi
    
    run_update "Snap Packages" "snap refresh"
}

# Firmware Updates
update_firmware() {
    if [[ "${UPALL_FIRMWARE:-true}" != "true" ]]; then
        log_debug "Firmware Updates deaktiviert"
        return 0
    fi
    
    if ! command -v fwupdmgr &>/dev/null; then
        log_debug "fwupdmgr nicht installiert"
        return 0
    fi
    
    run_update "Firmware Refresh" "fwupdmgr refresh"
    run_update "Firmware Update" "fwupdmgr update -y" || true
}

# pipx Updates
update_pipx() {
    if [[ "${UPALL_PIPX:-false}" != "true" ]]; then
        log_debug "pipx Updates deaktiviert"
        return 0
    fi
    
    if ! command -v pipx &>/dev/null; then
        log_debug "pipx nicht installiert"
        return 0
    fi
    
    run_update "pipx packages" "pipx upgrade-all"
}

# npm globale Updates
update_npm() {
    if [[ "${UPALL_NPM:-false}" != "true" ]]; then
        log_debug "npm Updates deaktiviert"
        return 0
    fi
    
    if ! command -v npm &>/dev/null; then
        log_debug "npm nicht installiert"
        return 0
    fi
    
    run_update "npm global packages" "npm update -g"
}

# cargo Updates
update_cargo() {
    if [[ "${UPALL_CARGO:-false}" != "true" ]]; then
        log_debug "cargo Updates deaktiviert"
        return 0
    fi
    
    if ! command -v cargo &>/dev/null; then
        log_debug "cargo nicht installiert"
        return 0
    fi
    
    if command -v cargo-install-update &>/dev/null; then
        run_update "cargo packages" "cargo install-update -a"
    else
        log_debug "cargo-edit nicht installiert, überspringe"
    fi
}

# gem Updates
update_gems() {
    if [[ "${UPALL_GEMS:-false}" != "true" ]]; then
        log_debug "gem Updates deaktiviert"
        return 0
    fi
    
    if ! command -v gem &>/dev/null; then
        log_debug "gem nicht installiert"
        return 0
    fi
    
    run_update "Ruby gems" "gem update"
}

# conda Updates
update_conda() {
    if [[ "${UPALL_CONDA:-false}" != "true" ]]; then
        log_debug "conda Updates deaktiviert"
        return 0
    fi
    
    if ! command -v conda &>/dev/null; then
        log_debug "conda nicht installiert"
        return 0
    fi
    
    run_update "conda packages" "conda update --all -y"
}

# Selective Mode mit fzf oder Fallback
run_selective_update() {
    log INFO "Starte selektives Update..."
    
    if [[ "$MODE_DRY_RUN" == true ]]; then
        log INFO "[DRY-RUN] Selektiver Modus würde interaktive Auswahl starten"
        return 0
    fi
    
    case "$DETECTED_PKG_MANAGER" in
        apt)
            if command -v fzf &>/dev/null; then
                local packages
                packages=$(apt list --upgradable 2>/dev/null | tail -n +2 | cut -d'/' -f1)
                if [[ -n "$packages" ]]; then
                    local selected
                    selected=$(echo "$packages" | fzf --multi --preview="apt show {}")
                    if [[ -n "$selected" ]]; then
                        run_update "Selektive Pakete" "apt-get install -y $selected"
                    fi
                fi
            else
                log WARN "fzf nicht installiert, verwende Fallback-Menü"
                # Einfaches Fallback ohne fzf
                apt list --upgradable 2>/dev/null | tail -n +2
                read -rp "Paketnamen eingeben zum Update (Leer für alle): " pkg_name
                if [[ -n "$pkg_name" ]]; then
                    run_update "Ausgewählte Pakete" "apt-get install -y $pkg_name"
                else
                    run_update "Alle Pakete" "apt-get upgrade -y"
                fi
            fi
            ;;
        pacman)
            if command -v fzf &>/dev/null; then
                local packages
                packages=$(pacman -Qu 2>/dev/null | cut -d' ' -f1)
                if [[ -n "$packages" ]]; then
                    local selected
                    selected=$(echo "$packages" | fzf --multi)
                    if [[ -n "$selected" ]]; then
                        run_update "Selektive Pakete" "pacman -S --noconfirm $selected"
                    fi
                fi
            else
                pacman -Qu 2>/dev/null || true
                read -rp "Paketnamen eingeben zum Update (Leer für alle): " pkg_name
                if [[ -n "$pkg_name" ]]; then
                    run_update "Ausgewählte Pakete" "pacman -S --noconfirm $pkg_name"
                else
                    run_update "Alle Pakete" "pacman -Syu --noconfirm"
                fi
            fi
            ;;
        *)
            log WARN "Selektiver Modus nur für apt und pacman voll unterstützt"
            run_pkg_manager_update
            ;;
    esac
}

# Health Check ohne Update
run_health_check() {
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║  UPALL v${VERSION} – System Health Check               ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
    
    detect_distro
    echo "System     : ${DETECTED_DISTRO:-unknown}"
    echo "Version    : ${DETECTED_VERSION:-unknown}"
    echo "PaketMgr   : ${DETECTED_PKG_MANAGER:-unknown}"
    echo ""
    
    # Disk Space
    local available_kb
    available_kb=$(df -k / | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))
    printf "Speicher   : %-10s " "${available_mb} MB"
    if [[ $available_mb -ge $MIN_DISK_MB ]]; then
        echo "✓"
    else
        echo "✗ (kritisch)"
    fi
    
    # RAM
    if [[ -f /proc/meminfo ]]; then
        local total_ram free_ram
        total_ram=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
        free_ram=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo)
        echo "RAM        : ${free_ram} MB frei von ${total_ram} MB"
    fi
    
    # Verfügbare Updates zählen
    echo ""
    echo "Verfügbare Updates:"
    case "$DETECTED_PKG_MANAGER" in
        apt)
            local count
            count=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
            echo "  Pakete   : $count"
            ;;
        pacman)
            local count
            count=$(pacman -Qu 2>/dev/null | wc -l)
            echo "  Pakete   : $count"
            ;;
        dnf|yum)
            local count
            count=$(dnf check-update 2>/dev/null | grep -c "^\S" || echo 0)
            echo "  Pakete   : $count"
            ;;
        *)
            echo "  Nicht ermittelbar für $DETECTED_PKG_MANAGER"
            ;;
    esac
    
    # Kernel Version
    echo ""
    echo "Kernel     : $(uname -r)"
    
    # Letzte Boot-Zeit
    if command -v uptime &>/dev/null; then
        echo "Uptime     : $(uptime -p 2>/dev/null || uptime)"
    fi
    
    echo ""
}

# Changelog anzeigen
show_changelog() {
    log INFO "Zeige Changelogs der zu aktualisierenden Pakete..."
    
    case "$DETECTED_PKG_MANAGER" in
        apt)
            if command -v apt-listchanges &>/dev/null; then
                apt-listchanges --news
            else
                log WARN "apt-listchanges nicht installiert"
                apt list --upgradable 2>/dev/null | head -20
            fi
            ;;
        dnf|yum)
            dnf changelog all 2>/dev/null | head -50 || true
            ;;
        pacman)
            pacman -Qu 2>/dev/null | cut -d' ' -f1 | head -10 | while read -r pkg; do
                echo "=== $pkg ==="
                pacman -Qi "$pkg" 2>/dev/null | grep -A5 "Description" || true
            done
            ;;
        *)
            log WARN "Changelog-Anzeige für $DETECTED_PKG_MANAGER nicht implementiert"
            ;;
    esac
}

# Cronjob einrichten/entfernen
manage_schedule() {
    echo "Cronjob-Verwaltung"
    echo "=================="
    echo ""
    echo "Optionen:"
    echo "  1) Täglichen Cronjob einrichten (3:00 Uhr)"
    echo "  2) Wöchentlichen Cronjob einrichten (Sonntag 4:00)"
    echo "  3) Cronjob entfernen"
    echo "  4) Abbrechen"
    echo ""
    
    if [[ "$MODE_FORCE" == false ]]; then
        read -rp "Auswahl [1-4]: " choice
    else
        choice="1"
    fi
    
    case "$choice" in
        1)
            (crontab -l 2>/dev/null | grep -v UPALL; echo "0 3 * * * $0 --normal --quiet") | crontab -
            echo "Täglicher Cronjob eingerichtet ✓"
            ;;
        2)
            (crontab -l 2>/dev/null | grep -v UPALL; echo "0 4 * * 0 $0 --normal --quiet") | crontab -
            echo "Wöchentlicher Cronjob eingerichtet ✓"
            ;;
        3)
            crontab -l 2>/dev/null | grep -v UPALL | crontab - || true
            echo "Cronjob entfernt ✓"
            ;;
        4)
            echo "Abgebrochen"
            ;;
        *)
            echo "Ungültige Auswahl"
            ;;
    esac
}

# Desktop-Benachrichtigung
send_notification() {
    if [[ "${NOTIFY_ON_FINISH}" != "true" ]]; then
        return 0
    fi
    
    if ! command -v notify-send &>/dev/null; then
        log_debug "notify-send nicht verfügbar"
        return 0
    fi
    
    local status="Erfolgreich"
    if [[ $UPALL_FAIL_COUNT -gt 0 ]]; then
        status="Mit Fehlern abgeschlossen"
    fi
    
    notify-send -u normal "UPALL Update abgeschlossen" \
        "Erfolgreich: $UPALL_SUCCESS_COUNT | Fehler: $UPALL_FAIL_COUNT"
}

# Abschlussbericht
print_summary() {
    local duration=0
    if [[ $UPALL_START_TIME -gt 0 ]]; then
        local end_time
        end_time=$(date +%s)
        duration=$((end_time - UPALL_START_TIME))
    fi
    
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo " UPALL v${VERSION} – Abschlussbericht"
    echo "════════════════════════════════════════════════════════"
    echo " System     : ${DETECTED_DISTRO:-unknown} (${DETECTED_PKG_MANAGER:-unknown})"
    printf " Dauer      : %dm %ds\n" "$minutes" "$seconds"
    local total=$((UPALL_SUCCESS_COUNT + UPALL_FAIL_COUNT))
    if [[ $total -gt 0 ]]; then
        echo " Erfolgreich: ${UPALL_SUCCESS_COUNT}/${total} Quellen"
    else
        echo " Erfolgreich: $UPALL_SUCCESS_COUNT Quellen"
    fi
    echo " Fehler     : $UPALL_FAIL_COUNT (siehe Log)"
    
    if [[ "$KERNEL_UPDATED" == true ]]; then
        echo " Reboot     : ERFORDERLICH (Kernel-Update)"
    else
        echo " Reboot     : nicht erforderlich"
    fi
    
    echo "════════════════════════════════════════════════════════"
    echo ""
}

# UPALL deinstallieren
uninstall_upall() {
    echo "UPALL Deinstallation"
    echo "===================="
    echo ""
    
    if [[ "$MODE_FORCE" == false ]]; then
        read -rp "Wirklich alle UPALL-Daten löschen? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Abgebrochen"
            exit 0
        fi
    fi
    
    # Cronjob entfernen
    crontab -l 2>/dev/null | grep -v UPALL | crontab - || true
    
    # Daten löschen
    rm -rf "$CONFIG_DIR"
    rm -rf "$DATA_DIR"
    rm -f "$LOCK_FILE"
    
    # Script selbst löschen wenn im System-Pfad
    local script_path
    script_path=$(command -v upall 2>/dev/null || echo "")
    if [[ -n "$script_path" && "$script_path" != "$(pwd)/upall.sh" && "$script_path" != "./upall.sh" ]]; then
        if [[ -w "$script_path" ]]; then
            rm -f "$script_path"
            echo "Script entfernt: $script_path"
        else
            echo "Script gefunden unter: $script_path (bitte manuell löschen)"
        fi
    fi
    
    echo "UPALL wurde vollständig entfernt ✓"
    exit 0
}

# UPALL selbst aktualisieren
update_self() {
    log INFO "Suche nach UPALL Updates..."
    
    local current_dir
    current_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local script_name
    script_name="$(basename "${BASH_SOURCE[0]}")"
    
    # Wenn im Git-Repo
    if [[ -d "${current_dir}/.git" ]]; then
        if command -v git &>/dev/null; then
            log INFO "Aktualisiere via git..."
            (cd "$current_dir" && git pull --rebase) || {
                log ERROR "Git-Update fehlgeschlagen"
                return 1
            }
            log INFO "UPALL aktualisiert ✓"
            return 0
        fi
    fi
    
    # Fallback: curl Download
    if command -v curl &>/dev/null; then
        log INFO "Versuche Download von GitHub..."
        local temp_file
        temp_file=$(mktemp)
        
        if curl -L "https://raw.githubusercontent.com/yourrepo/upall/main/upall.sh" -o "$temp_file" 2>/dev/null; then
            if diff -q "$current_dir/$script_name" "$temp_file" &>/dev/null; then
                log INFO "Bereits aktuell"
                rm -f "$temp_file"
                return 0
            fi
            
            cp "$temp_file" "$current_dir/$script_name"
            chmod +x "$current_dir/$script_name"
            rm -f "$temp_file"
            log INFO "UPALL aktualisiert ✓"
            log INFO "Bitte Script neu starten für die neue Version"
            return 0
        else
            rm -f "$temp_file"
        fi
    fi
    
    log WARN "Konnte keine Update-Quelle finden"
    log INFO "Manuelles Update nötig oder installieren via Paketmanager"
    return 1
}

# Pre/Post Hooks ausführen
run_hook() {
    local hook_type="$1"
    local hook_path="$2"
    
    if [[ -z "$hook_path" ]]; then
        return 0
    fi
    
    if [[ ! -f "$hook_path" ]]; then
        log_debug "Hook-Datei nicht gefunden: $hook_path"
        return 1
    fi
    
    if [[ ! -x "$hook_path" ]]; then
        log WARN "Hook-Datei nicht ausführbar: $hook_path"
        return 1
    fi
    
    log INFO "Führe $hook_type Hook aus: $hook_path"
    if ! "$hook_path"; then
        log ERROR "$hook_type Hook fehlgeschlagen"
        if [[ "$hook_type" == "PRE" && "$MODE_FORCE" == false ]]; then
            log ERROR "Abbruch aufgrund von Pre-Update-Hook-Fehler"
            exit 1
        fi
    else
        log INFO "$hook_type Hook erfolgreich"
    fi
}

# Argumente parsen
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --normal)
                MODE_NORMAL=true
                ;;
            --nerd)
                MODE_NERD=true
                ;;
            --dry-run)
                MODE_DRY_RUN=true
                ;;
            --quiet)
                MODE_QUIET=true
                ;;
            --force)
                MODE_FORCE=true
                ;;
            --selective)
                MODE_SELECTIVE=true
                ;;
            --rollback)
                MODE_ROLLBACK=true
                ;;
            --schedule)
                MODE_SCHEDULE=true
                ;;
            --health)
                MODE_HEALTH=true
                ;;
            --changelog)
                MODE_CHANGELOG=true
                ;;
            --uninstall)
                MODE_UNINSTALL=true
                ;;
            --update-self)
                MODE_UPDATE_SELF=true
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                echo "UPALL v${VERSION}"
                exit 0
                ;;
            *)
                log ERROR "Unbekanntes Argument: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
    
    # Default-Modus setzen wenn keiner angegeben
    if [[ "$MODE_NORMAL" == false && "$MODE_NERD" == false && "$MODE_DRY_RUN" == false && \
          "$MODE_QUIET" == false && "$MODE_SELECTIVE" == false && "$MODE_ROLLBACK" == false && \
          "$MODE_SCHEDULE" == false && "$MODE_HEALTH" == false && "$MODE_UNINSTALL" == false && \
          "$MODE_UPDATE_SELF" == false && "${MODE_CHANGELOG:-false}" == false ]]; then
        MODE_NORMAL=true
    fi
}

# Hilfe anzeigen
show_help() {
    cat << EOF
UPALL v${VERSION} – Universal Linux Updater

VERWENDUNG:
    upall [OPTIONEN]

OPTIONEN:
    --normal       Standard-Update (apt/dnf/pacman upgrade + cleanup)
    --nerd         Verbose-Modus mit Zeitstempeln und Details
    --dry-run      Simulation ohne echte Änderungen
    --quiet        Nur Fehler ausgeben
    --force        Alle Bestätigungen überspringen
    --selective    Interaktive Paketauswahl (benötigt fzf für beste UX)
    --rollback     Letztes Update rückgängig machen (wo möglich)
    --schedule     Cronjob einrichten/entfernen
    --health       Systemcheck ohne Update (Disk, RAM, verfügbare Updates)
    --changelog    Changelogs der zu aktualisierenden Pakete anzeigen
    --uninstall    UPALL komplett entfernen (Config, Logs, Cronjobs)
    --update-self  UPALL selbst aktualisieren
    --help, -h     Diese Hilfe anzeigen
    --version, -v  Versionsnummer anzeigen

UMGEBUNGSVARIABLEN:
    UPALL_FLATPAK=false   Flatpak Updates deaktivieren
    UPALL_SNAP=false      Snap Updates deaktivieren
    UPALL_FIRMWARE=false  Firmware Updates deaktivieren
    UPALL_PIPX=true       pipx Updates aktivieren
    UPALL_NPM=true        npm globale Updates aktivieren
    UPALL_CARGO=true      cargo Updates aktivieren
    UPALL_GEMS=true       gem Updates aktivieren
    UPALL_CONDA=true      conda Updates aktivieren

BEISPIELE:
    upall --normal              # Standard-Update durchführen
    upall --nerd --force        # Verbose ohne Bestätigungen
    upall --dry-run             # Testen was passieren würde
    upall --selective           # Pakete einzeln auswählen
    upall --health              # Systemstatus prüfen
    upall --schedule            # Automatische Updates einrichten
    UPALL_PIPX=true upall       # Mit pipx Updates

KONFIGURATION:
    ~/.config/UPALL/config

LOGS:
    ~/.local/share/UPALL/logs/

EOF
}

# Hauptfunktion
main() {
    UPALL_START_TIME=$(date +%s)
    
    parse_args "$@"
    
    # Spezialfälle zuerst behandeln
    if [[ "$MODE_UNINSTALL" == true ]]; then
        uninstall_upall
    fi
    
    if [[ "$MODE_UPDATE_SELF" == true ]]; then
        update_self
        exit $?
    fi
    
    if [[ "$MODE_HEALTH" == true ]]; then
        run_health_check
        exit 0
    fi
    
    if [[ "$MODE_SCHEDULE" == true ]]; then
        manage_schedule
        exit 0
    fi
    
    if [[ "${MODE_CHANGELOG:-false}" == true ]]; then
        detect_distro
        show_changelog
        exit 0
    fi
    
    if [[ "$MODE_ROLLBACK" == true ]]; then
        detect_distro
        load_config
        perform_rollback
        exit $?
    fi
    
    # Normaler Betrieb
    echo ""
    if [[ "$MODE_NERD" == true ]]; then
        echo "[$(date '+%H:%M:%S')] ┌─────────────────────────────────────┐"
        echo "[$(date '+%H:%M:%S')] │  UPALL v${VERSION} – Universal Updater   │"
        echo "[$(date '+%H:%M:%S')] └─────────────────────────────────────┘"
    else
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║  UPALL v${VERSION} – Universal Updater                   ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
    fi
    
    # Initialisierung
    check_dependencies
    acquire_lock
    load_config
    rotate_logs
    
    # Systemchecks
    detect_distro
    log INFO "Distro erkannt: ${DETECTED_DISTRO} (${DETECTED_PKG_MANAGER})"
    
    check_network
    check_disk_space
    
    # Pre-Update Hook
    run_hook "PRE" "$PRE_UPDATE_HOOK"
    
    # Snapshot erstellen
    create_snapshot
    
    # Haupt-Update
    if [[ "$MODE_SELECTIVE" == true ]]; then
        run_selective_update
    else
        run_pkg_manager_update
    fi
    
    # Zusatz-Updates
    update_flatpak
    update_snap
    update_firmware
    update_pipx
    update_npm
    update_cargo
    update_gems
    update_conda
    
    # Post-Update Hook
    run_hook "POST" "$POST_UPDATE_HOOK"
    
    # Abschluss
    send_notification
    print_summary
    
    # Reboot-Hinweis
    if [[ "$KERNEL_UPDATED" == true && "$AUTO_REBOOT_ON_KERNEL" == true ]]; then
        log WARN "Automatischer Reboot in 10 Sekunden..."
        sleep 10
        systemctl reboot || reboot || exit 0
    elif [[ "$KERNEL_UPDATED" == true ]]; then
        log WARN "Ein Reboot wird empfohlen um das Kernel-Update abzuschließen"
    fi
    
    # Exit-Code basierend auf Fehlern
    if [[ $UPALL_FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
    
    exit 0
}

# Einstiegspunkt
main "$@"
