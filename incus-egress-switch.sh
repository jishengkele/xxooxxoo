#!/usr/bin/env bash
# shellcheck disable=SC1111 # 中文交互文案会有意使用全角引号。
set -euo pipefail

APP_NAME="incus-egress-switch"
CONFIG_DIR="${EGRESS_CONFIG_DIR:-/etc/incus-egress-switch}"
CONFIG_FILE="$CONFIG_DIR/config.env"
EXITS_FILE="$CONFIG_DIR/exits.tsv"
LIMITS_FILE="$CONFIG_DIR/exit-limits.tsv"
CONTAINERS_FILE="$CONFIG_DIR/containers.tsv"
SPLIT_DIR="$CONFIG_DIR/split"
SPLIT_APPS_FILE="$SPLIT_DIR/apps.tsv"
SPLIT_POLICIES_FILE="$SPLIT_DIR/policies.tsv"
SPLIT_CATEGORY_POLICIES_FILE="$SPLIT_DIR/category-policies.tsv"
SPLIT_CONTAINER_POLICIES_FILE="$SPLIT_DIR/container-policies.tsv"
SPLIT_FORCE_POLICIES_FILE="$SPLIT_DIR/force-policies.tsv"
SPLIT_FORCE_CATEGORY_POLICIES_FILE="$SPLIT_DIR/force-category-policies.tsv"
SPLIT_FORCE_ON_EXIT_POLICIES_FILE="$SPLIT_DIR/force-on-exit-policies.tsv"
SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE="$SPLIT_DIR/force-category-on-exit-policies.tsv"
SPLIT_CACHE_DIR="$SPLIT_DIR/cache"
SPLIT_RAW_DIR="$SPLIT_CACHE_DIR/raw"
SPLIT_RESOLVED_DIR="$SPLIT_CACHE_DIR/resolved"
SPLIT_LAST_SYNC_FILE="$SPLIT_DIR/last-sync"
SPLIT_CATALOG_FILE="$SPLIT_DIR/catalog-sync"
SPLIT_README_FILE="$SPLIT_CACHE_DIR/README.md"
SPLIT_BUNDLE_FILE="$SPLIT_CACHE_DIR/Scam-Abuse-Risk.list"
SPLIT_DNSMASQ_DIR="$SPLIT_DIR/dnsmasq"
INCUS_NETWORKS_DIR="${EGRESS_INCUS_NETWORKS_DIR:-/var/lib/incus/networks}"
RUN_DIR="/run/$APP_NAME"
RULE_STATE_FILE="$RUN_DIR/ip-rules.state"
NFT_STATE_FILE="$RUN_DIR/nft.state"
STATE_LOCK_FILE="$CONFIG_DIR/.state.lock"
APPLY_LOCK_FILE="$RUN_DIR/apply.lock"
PENDING_NFT_FILE="$CONFIG_DIR/.nft-apply-pending"
SYSCTL_FILE="/etc/sysctl.d/99-$APP_NAME.conf"
SYSCTL_ORIGINAL_FILE="$CONFIG_DIR/sysctl-original.env"
SPLIT_CACHE_LOCK_FILE="$SPLIT_DIR/.split-cache.lock"
INSTALL_BIN="/usr/local/sbin/$APP_NAME"
SHORTCUT_BIN="/usr/local/sbin/sbout"
LIB_DIR="/usr/local/lib/$APP_NAME"
CONTROLLER_FILE="$LIB_DIR/controller.py"
AUTOSYNC_FILE="$LIB_DIR/autosync.py"
OUT_CLIENT_FILE="$LIB_DIR/out"
SINGBOX_BIN="$LIB_DIR/cloudshlii-sing-box"
EXIT_DIR="$CONFIG_DIR/cloudshlii-exits.d"
LEGACY_SINGBOX_BIN="$LIB_DIR/sing-box"
LEGACY_EXIT_DIR="$CONFIG_DIR/exits.d"
SYSTEMD_DIR="${EGRESS_SYSTEMD_DIR:-/etc/systemd/system}"
SERVICE_FILE="$SYSTEMD_DIR/$APP_NAME.service"
AUTOSYNC_SERVICE="$SYSTEMD_DIR/$APP_NAME-autosync.service"
EXIT_SERVICE_PREFIX="incus-egress-switch-exit"
WG_SERVER_DIR="${WG_SERVER_DIR:-/etc/cloudshlii-wg-server}"
WG_SERVER_ENV="$WG_SERVER_DIR/server.env"
WG_SERVER_PEERS="$WG_SERVER_DIR/peers.tsv"
WG_SERVER_PRIVATE_KEY="$WG_SERVER_DIR/server.key"
WG_SERVER_PUBLIC_KEY="$WG_SERVER_DIR/server.pub"
WG_SERVER_IFACE="cwg-server"
WG_SERVER_CONF="/etc/wireguard/${WG_SERVER_IFACE}.conf"
WG_SERVER_NFT="$WG_SERVER_DIR/server.nft"
WG_SERVER_NFT_TABLE="csh_wg_server"
WG_SERVER_SYSCTL="/etc/sysctl.d/99-cloudshlii-wg-server.conf"
WG_SERVER_LOCK="/run/lock/cloudshlii-wg-server.lock"
WG_SERVER_OPENRC_SERVICE="/etc/init.d/cloudshlii-wg-server"
UPDATE_BACKUP_ROOT="${EGRESS_UPDATE_BACKUP_ROOT:-/var/backups/$APP_NAME}"
DEFAULT_UPDATE_SCRIPT_URL="https://raw.githubusercontent.com/jishengkele/xxooxxoo/main/incus-egress-switch-wg.sh"
UPDATE_BACKUP_PATH=""
UPDATE_BACKUP_ARCHIVE=""

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

if [ -t 1 ]; then
    UI_RESET="$(printf '\033[0m')"
    UI_BOLD="$(printf '\033[1m')"
    UI_GREEN="$(printf '\033[32m')"
    UI_CYAN="$(printf '\033[36m')"
    UI_YELLOW="$(printf '\033[33m')"
else
    UI_RESET=""
    UI_BOLD=""
    UI_GREEN=""
    UI_CYAN=""
    UI_YELLOW=""
fi

ui_line() { printf '%s\n' '================================================================'; }
ui_subline() { printf '%s\n' '----------------------------------------------------------------'; }
ui_title() { ui_line; printf '%s%s%s\n' "$UI_BOLD" "$1" "$UI_RESET"; ui_line; }
ui_kv() { printf '  %s%-16s%s %s\n' "$UI_CYAN" "$1" "$UI_RESET" "$2"; }

# 配置写入锁和数据面应用锁分离：配置锁保护 TSV/env，应用锁串行化 nft/ip/tc 更新。
# 同一 Bash 进程内允许重入，避免管理函数持有配置锁后调用 do_apply 时自锁。
STATE_LOCK_DEPTH=0
APPLY_LOCK_DEPTH=0
SPLIT_CACHE_LOCK_DEPTH=0

state_lock_acquire() {
    if [ "$STATE_LOCK_DEPTH" -gt 0 ]; then
        STATE_LOCK_DEPTH=$((STATE_LOCK_DEPTH + 1))
        return 0
    fi
    mkdir -p "$CONFIG_DIR"
    need_cmd flock
    exec {STATE_LOCK_FD}>"$STATE_LOCK_FILE"
    flock -x "$STATE_LOCK_FD"
    STATE_LOCK_DEPTH=1
}

state_lock_release() {
    [ "$STATE_LOCK_DEPTH" -gt 0 ] || return 0
    STATE_LOCK_DEPTH=$((STATE_LOCK_DEPTH - 1))
    [ "$STATE_LOCK_DEPTH" -eq 0 ] || return 0
    flock -u "$STATE_LOCK_FD" 2>/dev/null || true
    exec {STATE_LOCK_FD}>&-
}

apply_lock_acquire() {
    if [ "$APPLY_LOCK_DEPTH" -gt 0 ]; then
        APPLY_LOCK_DEPTH=$((APPLY_LOCK_DEPTH + 1))
        return 0
    fi
    mkdir -p "$RUN_DIR"
    need_cmd flock
    exec {APPLY_LOCK_FD}>"$APPLY_LOCK_FILE"
    flock -x "$APPLY_LOCK_FD"
    APPLY_LOCK_DEPTH=1
}

apply_lock_release() {
    [ "$APPLY_LOCK_DEPTH" -gt 0 ] || return 0
    APPLY_LOCK_DEPTH=$((APPLY_LOCK_DEPTH - 1))
    [ "$APPLY_LOCK_DEPTH" -eq 0 ] || return 0
    flock -u "$APPLY_LOCK_FD" 2>/dev/null || true
    exec {APPLY_LOCK_FD}>&-
}

split_cache_lock_acquire() {
    if [ "$SPLIT_CACHE_LOCK_DEPTH" -gt 0 ]; then
        SPLIT_CACHE_LOCK_DEPTH=$((SPLIT_CACHE_LOCK_DEPTH + 1))
        return 0
    fi
    mkdir -p "$SPLIT_DIR"
    need_cmd flock
    exec {SPLIT_CACHE_LOCK_FD}>"$SPLIT_CACHE_LOCK_FILE"
    flock -x "$SPLIT_CACHE_LOCK_FD"
    SPLIT_CACHE_LOCK_DEPTH=1
}

split_cache_lock_release() {
    [ "$SPLIT_CACHE_LOCK_DEPTH" -gt 0 ] || return 0
    SPLIT_CACHE_LOCK_DEPTH=$((SPLIT_CACHE_LOCK_DEPTH - 1))
    [ "$SPLIT_CACHE_LOCK_DEPTH" -eq 0 ] || return 0
    flock -u "$SPLIT_CACHE_LOCK_FD" 2>/dev/null || true
    exec {SPLIT_CACHE_LOCK_FD}>&-
}

mark_nft_pending() {
    mkdir -p "$CONFIG_DIR"
    local tmp
    tmp="$(mktemp "$CONFIG_DIR/.nft-pending.XXXXXX")"
    printf 'host-%s-%s\n' "$$" "$(date +%s)" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$PENDING_NFT_FILE"
}

need_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "这个操作必须使用 root 权限运行。"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少必要命令: $1"
}

install_host_dependencies() {
    need_root
    local missing="" cmd
    for cmd in install python3 systemctl ip tc nft incus curl tar gzip awk mktemp flock sysctl conntrack sha256sum; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -n "$missing" ] || { info "宿主机基础依赖已满足。"; return 0; }

    info "检测到缺失命令:$missing"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
            ca-certificates curl tar gzip python3 iproute2 nftables gawk coreutils util-linux procps conntrack
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache ca-certificates curl tar gzip python3 iproute2 nftables gawk coreutils util-linux procps conntrack-tools
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl tar gzip python3 iproute nftables gawk coreutils util-linux procps-ng conntrack-tools
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl tar gzip python3 iproute nftables gawk coreutils util-linux procps-ng conntrack-tools
    else
        warn "未识别包管理器，请手动安装缺失命令后重试:$missing"
    fi
}

# 持久化转发所需内核参数，避免宿主机重启后 fwmark 路由因转发/rp_filter 失效。
install_runtime_sysctls() {
    need_root
    need_cmd sysctl
    load_config
    local tmp iface key
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$SYSCTL_ORIGINAL_FILE" ]; then
        {
            printf 'net.ipv4.ip_forward=%s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf 0)"
            printf 'net.ipv4.conf.all.src_valid_mark=%s\n' "$(sysctl -n net.ipv4.conf.all.src_valid_mark 2>/dev/null || printf 0)"
            printf 'net.ipv4.conf.all.rp_filter=%s\n' "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || printf 0)"
            printf 'net.ipv4.conf.default.rp_filter=%s\n' "$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || printf 0)"
            printf 'net.ipv6.conf.all.forwarding=%s\n' "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || printf 0)"
            for iface in $BRIDGE_IFACES; do
                valid_name "$iface" || continue
                key="net.ipv4.conf.$iface.rp_filter"
                sysctl -n "$key" >/dev/null 2>&1 || continue
                printf '%s=%s\n' "$key" "$(sysctl -n "$key")"
            done
        } > "$SYSCTL_ORIGINAL_FILE"
        chmod 600 "$SYSCTL_ORIGINAL_FILE"
    fi
    tmp="$(mktemp)"
    cat > "$tmp" <<'EOF'
# Managed by incus-egress-switch.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv6.conf.all.forwarding = 1
EOF
    for iface in $BRIDGE_IFACES; do
        valid_name "$iface" || continue
        printf 'net.ipv4.conf.%s.rp_filter = 0\n' "$iface" >> "$tmp"
    done
    install -m 0644 "$tmp" "$SYSCTL_FILE"
    rm -f "$tmp"
    sysctl -e -q -p "$SYSCTL_FILE" || warn "部分内核转发参数无法应用，请检查 $SYSCTL_FILE。"
}

restore_runtime_sysctls() {
    [ -f "$SYSCTL_ORIGINAL_FILE" ] || return 0
    command -v sysctl >/dev/null 2>&1 || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            net.ipv4.ip_forward|net.ipv4.conf.all.src_valid_mark|net.ipv4.conf.all.rp_filter|net.ipv4.conf.default.rp_filter|net.ipv4.conf.*.rp_filter|net.ipv6.conf.all.forwarding)
                [[ "$value" =~ ^[0-9]+$ ]] && sysctl -q -w "$key=$value" 2>/dev/null || true
                ;;
        esac
    done < "$SYSCTL_ORIGINAL_FILE"
}

install_self_atomically() {
    local source="$1" staged
    staged="$(mktemp "${INSTALL_BIN}.XXXXXX")"
    install -m 0755 "$source" "$staged"
    mv -f "$staged" "$INSTALL_BIN"
}

install_shortcut() {
    local shortcut_dir
    shortcut_dir="$(dirname "$SHORTCUT_BIN")"
    mkdir -p "$shortcut_dir"
    ln -sfn "$INSTALL_BIN" "$SHORTCUT_BIN"
}

unit_is_active() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$1" </dev/null
}

unit_is_enabled() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet "$1" </dev/null
}

wait_unit_active() {
    local unit="$1" timeout="${2:-30}" deadline
    deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        unit_is_active "$unit" && return 0
        sleep 1
    done
    unit_is_active "$unit"
}

# 在触碰生产配置前，先验证上传脚本及其内嵌 controller/autosync/out 模板。
preflight_update_source() {
    local source="$1" stage
    [ -f "$source" ] || die "找不到待更新脚本: $source"
    bash -n "$source" || die "待更新脚本 Bash 语法检查失败: $source"
    stage="$(mktemp -d)"
    if ! (
        set -e
        LIB_DIR="$stage/lib"
        CONTROLLER_FILE="$LIB_DIR/controller.py"
        AUTOSYNC_FILE="$LIB_DIR/autosync.py"
        OUT_CLIENT_FILE="$LIB_DIR/out"
        INSTALL_BIN="$stage/bin/$APP_NAME"
        SERVICE_FILE="$stage/systemd/$APP_NAME.service"
        AUTOSYNC_SERVICE="$stage/systemd/$APP_NAME-autosync.service"
        mkdir -p "$(dirname "$INSTALL_BIN")"
        install -m 0755 "$source" "$INSTALL_BIN"
        write_controller
        write_autosync
        write_client_file
        write_service
        python3 -m py_compile "$CONTROLLER_FILE" "$AUTOSYNC_FILE"
        sh -n "$OUT_CLIENT_FILE"
        grep -q '^ExecStart=' "$SERVICE_FILE"
        grep -q '^ExecStart=' "$AUTOSYNC_SERVICE"
    ); then
        rm -rf -- "$stage"
        die "待更新脚本的内嵌组件预检失败，宿主机现有配置尚未改动。"
    fi
    rm -rf -- "$stage"
    info "待更新脚本及内嵌组件预检通过。"
}

# 只让 nft 解析完整事务，不提交规则；用于更新前发现无效配置。
preflight_update_runtime() {
    local nft_preview nft_batch
    validate_runtime_config
    validate_exits
    validate_exit_limits
    validate_containers
    validate_split_policies
    nft_preview="$(mktemp)"
    nft_batch="$(mktemp)"
    build_nft_file "$nft_preview"
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        printf 'delete table inet %s\n' "$NFT_TABLE" > "$nft_batch"
    fi
    cat "$nft_preview" >> "$nft_batch"
    if ! nft -c -f "$nft_batch"; then
        rm -f "$nft_preview" "$nft_batch"
        return 1
    fi
    rm -f "$nft_preview" "$nft_batch"
}

create_update_backup() {
    local source="$1" main_active="$2" main_enabled="$3" autosync_active="$4" autosync_enabled="$5"
    local stamp path service_dir svc size path_kb required_kb=0 available_kb=0
    local -a paths=()
    stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    [[ "$UPDATE_BACKUP_ROOT" = /* ]] || { warn "更新备份目录必须使用绝对路径: $UPDATE_BACKUP_ROOT"; return 1; }
    case "$UPDATE_BACKUP_ROOT" in
        */../*|*/..|*/./*) warn "更新备份目录不能包含 . 或 .. 路径段: $UPDATE_BACKUP_ROOT"; return 1 ;;
    esac
    if [ "$UPDATE_BACKUP_ROOT" = "/" ] || [[ "$UPDATE_BACKUP_ROOT/" = "$CONFIG_DIR/"* ]] || [[ "$UPDATE_BACKUP_ROOT/" = "$LIB_DIR/"* ]]; then
        warn "更新备份目录不能位于根目录、配置目录或组件目录内部: $UPDATE_BACKUP_ROOT"
        return 1
    fi
    mkdir -p "$UPDATE_BACKUP_ROOT" || return 1
    chmod 0700 "$UPDATE_BACKUP_ROOT" || return 1
    : > "$UPDATE_BACKUP_ROOT/.managed-by-$APP_NAME" || return 1
    chmod 0600 "$UPDATE_BACKUP_ROOT/.managed-by-$APP_NAME" || return 1
    UPDATE_BACKUP_PATH="$UPDATE_BACKUP_ROOT/$stamp"
    mkdir -p "$UPDATE_BACKUP_PATH" || return 1
    chmod 0700 "$UPDATE_BACKUP_PATH" || return 1
    UPDATE_BACKUP_ARCHIVE="$UPDATE_BACKUP_PATH/state.tar.gz"

    for path in "$CONFIG_DIR" "$INSTALL_BIN" "$SHORTCUT_BIN" "$CONTROLLER_FILE" "$AUTOSYNC_FILE" "$OUT_CLIENT_FILE" \
        "$SERVICE_FILE" "$AUTOSYNC_SERVICE" "$SYSCTL_FILE"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            if [[ "$path" != /* ]]; then
                warn "拒绝备份非绝对路径: $path"
                return 1
            fi
            paths+=("${path#/}")
        fi
    done
    service_dir="$(dirname "$SERVICE_FILE")"
    for path in "$service_dir"/${EXIT_SERVICE_PREFIX}-*.service; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            if [[ "$path" != /* ]]; then
                warn "拒绝备份非绝对路径: $path"
                return 1
            fi
            paths+=("${path#/}")
        fi
    done

    for path in "${paths[@]}"; do
        path_kb="$(du -sk "/$path" 2>/dev/null | awk 'NR == 1 {print $1 + 0}')"
        required_kb=$((required_kb + ${path_kb:-0}))
    done
    available_kb="$(df -Pk "$UPDATE_BACKUP_ROOT" 2>/dev/null | awk 'NR == 2 {print $4 + 0}')"
    if [ "${available_kb:-0}" -le $((required_kb + 20480)) ]; then
        warn "更新备份空间不足：预计最多需要 $((required_kb / 1024 + 20)) MiB，可用约 $((available_kb / 1024)) MiB。"
        rm -rf -- "$UPDATE_BACKUP_PATH"
        UPDATE_BACKUP_PATH=""
        UPDATE_BACKUP_ARCHIVE=""
        return 1
    fi

    if [ "${#paths[@]}" -gt 0 ]; then
        tar -C / -czpf "$UPDATE_BACKUP_ARCHIVE" "${paths[@]}" || return 1
    else
        tar -C / -czpf "$UPDATE_BACKUP_ARCHIVE" --files-from /dev/null || return 1
    fi
    (
        cd "$UPDATE_BACKUP_PATH"
        sha256sum state.tar.gz > state.tar.gz.sha256
    ) || return 1
    {
        printf 'created=%s\n' "$(date -Is)"
        printf 'source=%s\n' "$source"
        printf 'source_sha256=%s\n' "$(sha256sum "$source" | awk '{print $1}')"
        printf 'main_active=%s\n' "$main_active"
        printf 'main_enabled=%s\n' "$main_enabled"
        printf 'autosync_active=%s\n' "$autosync_active"
        printf 'autosync_enabled=%s\n' "$autosync_enabled"
    } > "$UPDATE_BACKUP_PATH/metadata.env" || return 1
    chmod 0600 "$UPDATE_BACKUP_PATH/metadata.env" "$UPDATE_BACKUP_PATH/state.tar.gz.sha256" "$UPDATE_BACKUP_ARCHIVE" || return 1
    : > "$UPDATE_BACKUP_PATH/active-exits.txt" || return 1
    if command -v systemctl >/dev/null 2>&1; then
        while IFS= read -r svc; do
            [ -n "$svc" ] || continue
            unit_is_active "$svc" && printf '%s\n' "$svc" >> "$UPDATE_BACKUP_PATH/active-exits.txt"
        done < <(managed_exit_services)
    fi
    chmod 0600 "$UPDATE_BACKUP_PATH/active-exits.txt" || return 1
    size="$(du -h "$UPDATE_BACKUP_ARCHIVE" 2>/dev/null | awk '{print $1}')"
    info "更新前备份已创建: $UPDATE_BACKUP_PATH（${size:-未知大小}）"
}

prune_update_backups() {
    local keep="${UPDATE_BACKUP_KEEP:-5}" index old
    local -a discovered=() backups=()
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
    [ "$keep" -ge 1 ] || keep=1
    [ -d "$UPDATE_BACKUP_ROOT" ] || return 0
    mapfile -t discovered < <(
        for old in "$UPDATE_BACKUP_ROOT"/*; do
            [ -d "$old" ] || continue
            [ -f "$old/metadata.env" ] && [ -f "$old/state.tar.gz" ] || continue
            printf '%s\n' "$old"
        done | sort -r
    )
    if [ -n "$UPDATE_BACKUP_PATH" ] && [ -d "$UPDATE_BACKUP_PATH" ]; then
        backups+=("$UPDATE_BACKUP_PATH")
    fi
    for old in "${discovered[@]}"; do
        [ "$old" = "$UPDATE_BACKUP_PATH" ] || backups+=("$old")
    done
    for ((index=keep; index<${#backups[@]}; index++)); do
        old="${backups[$index]}"
        case "$old" in
            "$UPDATE_BACKUP_ROOT"/*) rm -rf -- "$old" ;;
        esac
    done
}

restore_update_service_state() {
    local main_active="$1" main_enabled="$2" autosync_active="$3" autosync_enabled="$4" failed=0
    command -v systemctl >/dev/null 2>&1 || return 0
    if [ "$main_enabled" = "true" ]; then
        systemctl enable "$APP_NAME.service" >/dev/null 2>&1 || failed=1
    else
        systemctl disable "$APP_NAME.service" >/dev/null 2>&1 || true
    fi
    if [ "$autosync_enabled" = "true" ]; then
        systemctl enable "$APP_NAME-autosync.service" >/dev/null 2>&1 || failed=1
    else
        systemctl disable "$APP_NAME-autosync.service" >/dev/null 2>&1 || true
    fi
    if [ "$main_active" = "true" ]; then
        systemctl restart "$APP_NAME.service" >/dev/null 2>&1 || failed=1
    else
        systemctl stop "$APP_NAME.service" >/dev/null 2>&1 || true
    fi
    if [ "$autosync_active" = "true" ]; then
        systemctl restart "$APP_NAME-autosync.service" >/dev/null 2>&1 || failed=1
    else
        systemctl stop "$APP_NAME-autosync.service" >/dev/null 2>&1 || true
    fi
    return "$failed"
}

restore_update_backup() {
    local backup="$1" main_active="$2" main_enabled="$3" autosync_active="$4" autosync_enabled="$5"
    local archive="$backup/state.tar.gz" service_dir current_nft rollback_failed=0
    [ -f "$archive" ] || { warn "更新回滚包不存在: $archive"; return 1; }
    if ! (cd "$backup" && sha256sum -c state.tar.gz.sha256 >/dev/null); then
        warn "更新回滚包校验失败，拒绝自动解压: $archive"
        return 1
    fi
    command -v systemctl >/dev/null 2>&1 && systemctl stop "$APP_NAME-autosync" "$APP_NAME" 2>/dev/null || true
    load_config
    current_nft="$NFT_TABLE"
    reset_managed_ip_rules 2>/dev/null || true
    flush_exit_route_tables 2>/dev/null || true
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet "$current_nft" 2>/dev/null || true
        nft delete table inet "${current_nft}_apply_guard" 2>/dev/null || true
    fi

    service_dir="$(dirname "$SERVICE_FILE")"
    rm -rf -- "$CONFIG_DIR"
    rm -f -- "$INSTALL_BIN" "$SHORTCUT_BIN" "$CONTROLLER_FILE" "$AUTOSYNC_FILE" "$OUT_CLIENT_FILE" \
        "$SERVICE_FILE" "$AUTOSYNC_SERVICE" "$SYSCTL_FILE"
    rm -f -- "$service_dir"/${EXIT_SERVICE_PREFIX}-*.service 2>/dev/null || true
    tar -C / -xzpf "$archive" || return 1
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true

    if command -v systemctl >/dev/null 2>&1 && [ -f "$backup/active-exits.txt" ]; then
        while IFS= read -r svc; do
            [ -n "$svc" ] || continue
            systemctl restart "$svc" >/dev/null 2>&1 || rollback_failed=1
        done < "$backup/active-exits.txt"
    fi

    if [ -x "$INSTALL_BIN" ]; then
        "$INSTALL_BIN" apply >/dev/null 2>&1 || rollback_failed=1
    fi
    if [ -f "$SYSCTL_FILE" ]; then
        sysctl -e -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || rollback_failed=1
    else
        restore_runtime_sysctls
    fi
    restore_update_service_state "$main_active" "$main_enabled" "$autosync_active" "$autosync_enabled" || rollback_failed=1
    if [ "$rollback_failed" -eq 0 ]; then
        warn "更新失败，已自动恢复更新前版本和配置。备份保留在: $backup"
        return 0
    fi
    warn "自动回滚已执行，但旧数据面或服务未完全恢复，请检查: $backup"
    return 1
}

update_health_check() {
    local autosync_should_run="$1" backup="$2" timeout="${UPDATE_HEALTH_TIMEOUT:-30}"
    local deadline health_url svc
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=30
    [ "$timeout" -ge 5 ] || timeout=5
    wait_unit_active "$APP_NAME.service" "$timeout" || { warn "更新后 API 服务未恢复。"; return 1; }
    [ -x "$INSTALL_BIN" ] && [ -s "$CONTROLLER_FILE" ] && [ -s "$AUTOSYNC_FILE" ] && [ -x "$OUT_CLIENT_FILE" ] || {
        warn "更新后的脚本组件不完整。"
        return 1
    }
    nft list table inet "$NFT_TABLE" >/dev/null 2>&1 || { warn "更新后 nftables 主表不存在。"; return 1; }
    ! nft list table inet "$(apply_guard_table)" >/dev/null 2>&1 || { warn "更新后流量保护表仍未释放。"; return 1; }
    [ ! -e "$PENDING_NFT_FILE" ] || { warn "更新后仍存在待应用标记。"; return 1; }

    health_url="${API_PUBLIC_URL%/}/health"
    deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        curl -fsS --connect-timeout 2 --max-time 4 "$health_url" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -fsS --connect-timeout 2 --max-time 4 "$health_url" >/dev/null 2>&1 || {
        warn "更新后 API 健康检查失败: $health_url"
        return 1
    }
    if [ "$autosync_should_run" = "true" ]; then
        wait_unit_active "$APP_NAME-autosync.service" "$timeout" || { warn "更新后自动同步服务未恢复。"; return 1; }
    fi
    if [ -f "$backup/active-exits.txt" ]; then
        while IFS= read -r svc; do
            [ -n "$svc" ] || continue
            wait_unit_active "$svc" "$timeout" || { warn "更新前在线的出口服务未恢复: $svc"; return 1; }
        done < "$backup/active-exits.txt"
    fi
    return 0
}

# 读取宿主机控制器配置。没有配置文件时使用保守默认值，便于首次进入中文菜单。
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
    BRIDGE_IFACES="${BRIDGE_IFACES:-incusbr0 lxdbr0}"
    API_BIND="${API_BIND:-0.0.0.0}"
    API_PORT="${API_PORT:-18988}"
    API_PUBLIC_URL="${API_PUBLIC_URL:-http://10.88.0.1:18988}"
    API_MAX_CONCURRENT="${API_MAX_CONCURRENT:-24}"
    API_RATE_LIMIT="${API_RATE_LIMIT:-120}"
    API_MAX_BODY="${API_MAX_BODY:-4096}"
    API_SOCKET_TIMEOUT="${API_SOCKET_TIMEOUT:-15}"
    NFT_TABLE="${NFT_TABLE:-incus_egress_switch}"
    RULE_PRIORITY="${RULE_PRIORITY:-80}"
    LIMIT_BURST="${LIMIT_BURST:-64kb}"
    LIMIT_LATENCY="${LIMIT_LATENCY:-50ms}"
    SWITCH_CLEAR_CONNTRACK="${SWITCH_CLEAR_CONNTRACK:-true}"
    BLOCK_UNMANAGED_IPV6="${BLOCK_UNMANAGED_IPV6:-true}"
    ENABLE_SPLIT_RULES="${ENABLE_SPLIT_RULES:-true}"
    SPLIT_RULE_BUNDLE_URL="${SPLIT_RULE_BUNDLE_URL:-https://raw.githubusercontent.com/0xdabiaoge/VPS-Tool/main/Scam-Abuse-Risk.list}"
    SPLIT_UPDATE_INTERVAL="${SPLIT_UPDATE_INTERVAL:-259200}"
    SPLIT_DNS_REFRESH_INTERVAL="${SPLIT_DNS_REFRESH_INTERVAL:-21600}"
    SPLIT_FETCH_TIMEOUT="${SPLIT_FETCH_TIMEOUT:-10}"
    SPLIT_DOMAIN_RESOLVE_LIMIT="${SPLIT_DOMAIN_RESOLVE_LIMIT:-80}"
    SPLIT_DNS_TIMEOUT="${SPLIT_DNS_TIMEOUT:-1}"
    SPLIT_DNS_WORKERS="${SPLIT_DNS_WORKERS:-4}"
    SPLIT_DNSMASQ_NFTSET="${SPLIT_DNSMASQ_NFTSET:-true}"
    STRICT_TOKEN="${STRICT_TOKEN:-true}"
    AUTO_SYNC="${AUTO_SYNC:-true}"
    AUTO_INTERVAL="${AUTO_INTERVAL:-15}"
    AUTO_PROJECTS="${AUTO_PROJECTS:-default}"
    AUTO_INCLUDE_REGEX="${AUTO_INCLUDE_REGEX:-.*}"
    AUTO_EXCLUDE_REGEX="${AUTO_EXCLUDE_REGEX:-}"
    AUTO_ALLOW_EXITS="${AUTO_ALLOW_EXITS:-*}"
    AUTO_DEFAULT_EXIT="${AUTO_DEFAULT_EXIT:-}"
    AUTO_INSTALL_CLIENT="${AUTO_INSTALL_CLIENT:-true}"
    AUTO_CLIENT_VERIFY_INTERVAL="${AUTO_CLIENT_VERIFY_INTERVAL:-300}"
    AUTO_STATE_REFRESH_INTERVAL="${AUTO_STATE_REFRESH_INTERVAL:-300}"
    AUTO_CLIENT_PATH="${AUTO_CLIENT_PATH:-/usr/local/bin/out}"
    AUTO_TOKEN_PATH="${AUTO_TOKEN_PATH:-/etc/incus-egress-token}"
    AUTO_RUNNING_ONLY="${AUTO_RUNNING_ONLY:-true}"
    AUTO_SYNC_WORKERS="${AUTO_SYNC_WORKERS:-8}"
    AUTO_INJECT_WORKERS="${AUTO_INJECT_WORKERS:-4}"
    AUTO_COMMAND_TIMEOUT="${AUTO_COMMAND_TIMEOUT:-30}"
    AUTO_DELETE_GRACE_SCANS="${AUTO_DELETE_GRACE_SCANS:-2}"
    AUTO_RECONCILE_MIN_INTERVAL="${AUTO_RECONCILE_MIN_INTERVAL:-10}"
    AUTO_EVENT_DEBOUNCE="${AUTO_EVENT_DEBOUNCE:-2}"
    UPDATE_BACKUP_KEEP="${UPDATE_BACKUP_KEEP:-5}"
    UPDATE_HEALTH_TIMEOUT="${UPDATE_HEALTH_TIMEOUT:-30}"
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

valid_mark() {
    local value="$1"
    if [[ "$value" =~ ^0x[0-9a-fA-F]{1,8}$ ]]; then
        [ "$((value))" -ge 1 ]
        return $?
    fi
    if [[ "$value" =~ ^[0-9]{1,10}$ ]]; then
        [ "$((10#$value))" -ge 1 ] && [ "$((10#$value))" -le 4294967295 ]
        return $?
    fi
    return 1
}

valid_table_id() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 4294967295 ]
}

normalize_limit_rate() {
    local rate
    rate="$(trim_space "${1:-}")"
    rate="${rate,,}"
    case "$rate" in
        ""|-|0|off|none|unlimited|no|false)
            printf '%s\n' "-"
            return 0
            ;;
    esac
    if [[ "$rate" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%smbps\n' "$rate"
        return 0
    fi
    if [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(k|m|g|t)$ ]]; then
        printf '%sbps\n' "$rate"
        return 0
    fi
    if [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(kbps|kbit)$ ]]; then
        printf '%skbps\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(mbps|mbit)$ ]]; then
        printf '%smbps\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(gbps|gbit)$ ]]; then
        printf '%sgbps\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(tbps|tbit)$ ]]; then
        printf '%stbps\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

valid_limit_rate() {
    normalize_limit_rate "$1" >/dev/null
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_ipv4() {
    local ip="$1" a b c d n
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for n in "$a" "$b" "$c" "$d"; do
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        [ "$n" -ge 0 ] && [ "$n" -le 255 ] || return 1
    done
}

is_ipv6() {
    [[ "$1" == *:* ]]
}

trim_space() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s\n' "$s"
}

normalize_proxy_host() {
    local host
    host="$(trim_space "${1:-}")"
    if [[ "$host" =~ ^\[(.*)\]$ ]]; then
        host="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$host"
}

valid_ipv6_literal() {
    local host="$1"
    python3 - "$host" <<'PY' >/dev/null 2>&1
import ipaddress
import sys

try:
    ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

valid_domain_name() {
    local host="$1" label
    [ -n "$host" ] || return 1
    [ "${#host}" -le 253 ] || return 1
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$host" != *..* ]] || return 1
    [[ "$host" != .* ]] || return 1
    [[ "$host" != *. ]] || return 1
    [[ "$host" =~ [A-Za-z] ]] || return 1
    IFS=. read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        [ -n "$label" ] || return 1
        [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

valid_proxy_host() {
    local host
    host="$(normalize_proxy_host "${1:-}")"
    [ -n "$host" ] || return 1
    [[ "$host" != *"://"* ]] || return 1
    [[ "$host" != *@* ]] || return 1
    [[ "$host" != */* ]] || return 1
    [[ "$host" != *[[:space:]]* ]] || return 1
    if is_ipv4 "$host"; then
        return 0
    fi
    if [[ "$host" == *:* ]]; then
        valid_ipv6_literal "$host"
        return $?
    fi
    valid_domain_name "$host"
}

detect_bridge_ipv4() {
    local iface ip
    for iface in incusbr0 lxdbr0; do
        ip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}')
        [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
    done
    printf '10.88.0.1\n'
}

# 初始化分流应用目录。应用目录不再内置常用列表，必须先从 GitHub 同步目录。
write_default_split_apps() {
    mkdir -p "$SPLIT_DIR" "$SPLIT_RAW_DIR" "$SPLIT_RESOLVED_DIR"
    if [ ! -f "$SPLIT_APPS_FILE" ]; then
        cat > "$SPLIT_APPS_FILE" <<'EOF'
# app_id  显示名  分类  GitHub目录  启用
# 请先在“分流管理”执行 1. 同步应用目录。
# GitHub 应用会由脚本自动发现；自定义规则会以 custom: 前缀保存，不会被更新覆盖。
EOF
        chmod 600 "$SPLIT_APPS_FILE"
    fi
    if [ ! -f "$SPLIT_POLICIES_FILE" ]; then
        cat > "$SPLIT_POLICIES_FILE" <<'EOF'
# 应用分流策略，每行一条：
# app_id  目标出口候选列表
#
# 目标出口候选列表用英文逗号分隔，第一个出口为宿主机默认出口。
# 目标出口写入口机或 - 表示入口机直出；写已添加出口的内部ID。
# 也可以通过主菜单“分流管理”设置，脚本会自动把显示名解析为内部ID。
EOF
        chmod 600 "$SPLIT_POLICIES_FILE"
    fi
    if [ ! -f "$SPLIT_CATEGORY_POLICIES_FILE" ]; then
        cat > "$SPLIT_CATEGORY_POLICIES_FILE" <<'EOF'
# 分类分流策略，每行一条：
# 分类  目标出口候选列表
#
# 目标出口候选列表用英文逗号分隔，第一个出口为宿主机默认出口。
# 目标出口写入口机或 - 表示入口机直出；写已添加出口的内部ID。
EOF
        chmod 600 "$SPLIT_CATEGORY_POLICIES_FILE"
    fi
    if [ ! -f "$SPLIT_CONTAINER_POLICIES_FILE" ]; then
        cat > "$SPLIT_CONTAINER_POLICIES_FILE" <<'EOF'
# 容器级应用分流覆盖，每行一条：
# 容器名  app_id  目标出口
#
# 这里由容器内 out split 管理。容器只能从宿主机为该应用/分类设置的候选出口中选择。
# 目标出口写入口机或 - 表示该容器的该应用走入口机直出。
# 不写覆盖时，会继续使用宿主机默认候选出口。
EOF
        chmod 600 "$SPLIT_CONTAINER_POLICIES_FILE"
    fi
    if [ ! -f "$SPLIT_FORCE_POLICIES_FILE" ]; then
        cat > "$SPLIT_FORCE_POLICIES_FILE" <<'EOF'
# 强制应用分流策略，每行一条：
# app_id
#
# 被标记的应用不受容器当前出口影响，始终使用宿主机为该应用设置的分流出口。
EOF
        chmod 600 "$SPLIT_FORCE_POLICIES_FILE"
    fi
    if [ ! -f "$SPLIT_FORCE_CATEGORY_POLICIES_FILE" ]; then
        cat > "$SPLIT_FORCE_CATEGORY_POLICIES_FILE" <<'EOF'
# 强制分类分流策略，每行一条：
# 分类
#
# 被标记的分类下应用不受容器当前出口影响，始终使用宿主机为该应用设置的分流出口。
EOF
        chmod 600 "$SPLIT_FORCE_CATEGORY_POLICIES_FILE"
    fi
    if [ ! -f "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" ]; then
        cat > "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" <<'EOF'
# 按容器当前出口强制应用分流，每行一条：
# app_id  来源出口  目标出口
EOF
        chmod 600 "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE"
    fi
    if [ ! -f "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE" ]; then
        cat > "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE" <<'EOF'
# 按容器当前出口强制分类分流，每行一条：
# 分类  来源出口  目标出口
EOF
        chmod 600 "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE"
    fi
}

# 初始化三份核心配置文件：
# config.env 控制 API 和 nftables 参数；
# exits.tsv 记录出口名、fwmark、路由表；
# containers.tsv 记录容器 IP、令牌、允许出口和当前出口。
write_default_config() {
    local default_api_ip
    state_lock_acquire
    default_api_ip=$(detect_bridge_ipv4)
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
# 接收 Incus/LXD 容器流量的网桥接口，多个接口用空格分隔。
BRIDGE_IFACES="incusbr0 lxdbr0"

# 容器自助切换 API 的监听地址和端口。
# 生产环境建议绑定到 Incus 网桥网关 IP，而不是 0.0.0.0。
API_BIND="$default_api_ip"
API_PORT="18988"
API_PUBLIC_URL="http://$default_api_ip:18988"

# API 并发与滥用保护。限额按单个来源 IP、每分钟计算。
API_MAX_CONCURRENT="24"
API_RATE_LIMIT="120"
API_MAX_BODY="4096"
API_SOCKET_TIMEOUT="15"

# 本脚本独占管理的 nftables 表名。
NFT_TABLE="incus_egress_switch"

# 策略路由优先级，必须低于宽泛的容器网段规则。
# 旧 singbox-out 脚本通常使用 priority 100，所以这里默认 80，
# 让“按容器 IP 切出口”的 fwmark 规则先命中。
RULE_PRIORITY="80"

# 出口共享限速的 tc 参数。限速本身写在 exit-limits.tsv。
LIMIT_BURST="64kb"
LIMIT_LATENCY="50ms"

# 切换出口后是否清理该容器的旧连接跟踪。
# 开启后新出口立即生效，但容器已有连接会断开。
SWITCH_CLEAR_CONNTRACK="true"

# 是否阻止未纳入出口规则的公网 IPv6。
# 默认开启，避免容器 IPv6 绕过 SS/TUN 出口直接暴露宿主机 IPv6。
BLOCK_UNMANAGED_IPV6="true"

# 是否启用宿主机统一应用分流规则。
ENABLE_SPLIT_RULES="true"

# 单文件应用分流规则源。一次下载后按文件中的“风险场景/应用”注释拆分分类和应用。
SPLIT_RULE_BUNDLE_URL="https://raw.githubusercontent.com/0xdabiaoge/VPS-Tool/main/Scam-Abuse-Risk.list"

# 应用规则自动核对更新间隔秒数。默认 259200 秒，即 3 天。
SPLIT_UPDATE_INTERVAL="259200"

# 仅使用本地缓存重新解析域名规则的间隔，不访问 GitHub。默认 6 小时。
SPLIT_DNS_REFRESH_INTERVAL="21600"

# 单文件下载请求超时秒数。raw.githubusercontent.com 异常时会快速失败并保留旧目录。
SPLIT_FETCH_TIMEOUT="10"

# 每个已设置分流策略的应用最多解析多少条域名规则为 nft 目标 IP。
# Clash 规则中的 IP-CIDR 会完整使用；DOMAIN-KEYWORD、IP-ASN、PROCESS-NAME 只记录不直接下发。
SPLIT_DOMAIN_RESOLVE_LIMIT="80"

# 单个域名 DNS 解析超时秒数。
SPLIT_DNS_TIMEOUT="1"

# 分流域名解析并发数。默认 4，在缩短等待时间的同时限制 DNS/线程资源占用。
SPLIT_DNS_WORKERS="4"

# 使用 Incus 网桥 dnsmasq 的 nftset 功能，动态补充域名及其子域名解析出的 IP。
# 不支持 nftset 的环境会自动退回现有的静态 DNS 解析缓存。
SPLIT_DNSMASQ_NFTSET="true"

# 是否强制每台容器使用独立 token。
STRICT_TOKEN="true"

# 是否启用 Incus 容器自动接管。
AUTO_SYNC="true"

# 自动同步间隔秒数。事件监听会尽快触发，同步间隔用于兜底。
AUTO_INTERVAL="15"

# 需要扫描的 Incus project，多个 project 用空格分隔。
AUTO_PROJECTS="default"

# 自动接管的容器名称正则。默认接管全部容器。
AUTO_INCLUDE_REGEX=".*"

# 自动排除的容器名称正则。为空表示不排除。
AUTO_EXCLUDE_REGEX=""

# 新容器默认允许使用哪些出口，* 表示全部出口；也可以写出口 ID，多个用英文逗号分隔。
AUTO_ALLOW_EXITS="*"

# 新容器默认出口。留空或写 "-" 表示入口机直出；写出口名才默认走指定出口。
AUTO_DEFAULT_EXIT=""

# 是否自动向容器内注入 out 命令和 token。
AUTO_INSTALL_CLIENT="true"

# 容器内 out/token 文件巡检间隔秒数。
# 默认 300 秒，即容器重装后最多约 5 分钟会自动补回 out 命令。
AUTO_CLIENT_VERIFY_INTERVAL="300"

# 已登记容器 IP 的完整复核间隔。普通轮询复用已有 IP，避免每轮逐容器查询 Incus。
AUTO_STATE_REFRESH_INTERVAL="300"

# 容器内 out 命令和 token 的目标路径。
AUTO_CLIENT_PATH="/usr/local/bin/out"
AUTO_TOKEN_PATH="/etc/incus-egress-token"

# 只同步运行中的容器。开启后 stopped/frozen 等状态不会写入授权、不会注入 out/token。
AUTO_RUNNING_ONLY="true"

# 新容器/定期 IP 复核的状态查询并发数；平时不会为每台容器启动查询进程。
AUTO_SYNC_WORKERS="8"

# out/token 注入与巡检的独立并发数。默认 4，避免容器较多时瞬间占满 CPU/磁盘。
AUTO_INJECT_WORKERS="4"

# 单条 Incus 查询/注入命令超时秒数。
AUTO_COMMAND_TIMEOUT="30"

# 连续多少轮完整扫描都确认容器消失后才回收配置，避免 Incus 短暂异常误删 token。
AUTO_DELETE_GRACE_SCANS="2"

# 批量生命周期事件期间两轮同步的最小间隔，避免反复扫描形成资源尖峰。
AUTO_RECONCILE_MIN_INTERVAL="10"

# Incus 生命周期事件去抖秒数，避免批量启动/重装时连续触发多轮同步。
AUTO_EVENT_DEBOUNCE="2"

# 安全更新成功后保留多少份更新前备份。备份目录权限为 0700，归 root 所有。
UPDATE_BACKUP_KEEP="5"

# 更新后等待 API、自动同步和原先在线出口恢复的最长秒数。
UPDATE_HEALTH_TIMEOUT="30"

# GitHub 在线更新地址。下载后仍执行与手动更新相同的预检、备份和自动回滚。
UPDATE_SCRIPT_URL="$DEFAULT_UPDATE_SCRIPT_URL"
EOF
        chmod 600 "$CONFIG_FILE"
    fi

    if [ ! -f "$EXITS_FILE" ]; then
        cat > "$EXITS_FILE" <<'EOF'
# 出口配置，每行一条：
# 内部ID  fwmark  路由表ID  IPv4默认路由  IPv6默认路由  显示名
#
# 示例：
# hk    0x5101  101    dev:tun-hk   dev:tun-hk   香港
# jp    0x5102  102    dev:tun-jp   dev:tun-jp   日本
# sg    0x5103  103    dev:tun-sg   dev:tun-sg   新加坡
#
# route 写法：
#   none
#   dev:tun-jp
#   via:192.0.2.1,dev:eth1
#
# 如果对应路由表已经由别的脚本维护，route4/route6 可以写 none。
EOF
        chmod 600 "$EXITS_FILE"
    fi

    if [ ! -f "$LIMITS_FILE" ]; then
        cat > "$LIMITS_FILE" <<'EOF'
# 出口共享限速配置，每行一条：
# 出口ID  下载限速  上传限速
#
# 这里是按出口整体限速，不区分单台容器；同一个出口下所有容器共享带宽。
# 下载/上传是从容器视角描述。默认单位是 Mbps；0 或 - 表示不限速。
# 换算：1 Mbps = 0.125 MB/s，8 Mbps = 1 MB/s。
# 单位示例：50Mbps、500Kbps、1Gbps。
# USNTT  100mbps  30mbps
EOF
        chmod 600 "$LIMITS_FILE"
    fi

    if [ ! -f "$CONTAINERS_FILE" ]; then
        cat > "$CONTAINERS_FILE" <<'EOF'
# 容器授权配置，每行一台：
# 名称    容器IP       token               允许出口      当前出口
# ct101   10.88.0.21   replace-this-token  hk,jp,sg       hk
#
# 允许出口可以写 "*"，表示允许使用全部出口。
EOF
        chmod 600 "$CONTAINERS_FILE"
    fi
    write_default_split_apps
    state_lock_release
}

read_exit_rows() {
    [ -f "$EXITS_FILE" ] || return 0
    while read -r name mark table route4 route6 display; do
        [ -n "${name:-}" ] || continue
        case "$name" in \#*) continue ;; esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$mark" "$table" "${route4:-none}" "${route6:-none}" "${display:-$name}" || return 0
    done < "$EXITS_FILE"
}

read_exit_limit_rows() {
    [ -f "$LIMITS_FILE" ] || return 0
    while read -r name down up rest; do
        [ -n "${name:-}" ] || continue
        case "$name" in \#*) continue ;; esac
        down="$(normalize_limit_rate "${down:--}")" || continue
        up="$(normalize_limit_rate "${up:-$down}")" || continue
        printf '%s\t%s\t%s\n' "$name" "$down" "$up" || return 0
    done < "$LIMITS_FILE"
}

exit_limit_down() {
    local target="$1"
    [ -f "$LIMITS_FILE" ] || { printf '%s\n' "-"; return 0; }
    read_exit_limit_rows | awk -F '\t' -v n="$target" '$1 == n {print $2; found=1; exit} END {if (!found) print "-"}'
}

exit_limit_up() {
    local target="$1"
    [ -f "$LIMITS_FILE" ] || { printf '%s\n' "-"; return 0; }
    read_exit_limit_rows | awk -F '\t' -v n="$target" '$1 == n {print $3; found=1; exit} END {if (!found) print "-"}'
}

limit_rate_label() {
    local rate="${1:--}"
    case "$rate" in
        ""|"-") printf '不限速'; return 0 ;;
        *) ;;
    esac
    if [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(kbps|kbit)$ ]]; then
        printf '%s Kbps' "${BASH_REMATCH[1]}"
    elif [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(mbps|mbit)$ ]]; then
        printf '%s Mbps' "${BASH_REMATCH[1]}"
    elif [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(gbps|gbit)$ ]]; then
        printf '%s Gbps' "${BASH_REMATCH[1]}"
    elif [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(tbps|tbit)$ ]]; then
        printf '%s Tbps' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$rate"
    fi
}

limit_rate_to_tc() {
    local rate="${1:--}"
    case "$rate" in
        ""|"-") printf '%s\n' "-"; return 0 ;;
    esac
    if [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)kbps$ ]]; then
        printf '%skbit\n' "${BASH_REMATCH[1]}"
    elif [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)mbps$ ]]; then
        printf '%smbit\n' "${BASH_REMATCH[1]}"
    elif [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)gbps$ ]]; then
        printf '%sgbit\n' "${BASH_REMATCH[1]}"
    elif [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)tbps$ ]]; then
        printf '%stbit\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$rate"
    fi
}

read_container_rows() {
    [ -f "$CONTAINERS_FILE" ] || return 0
    while read -r name ip token allowed current rest; do
        [ -n "${name:-}" ] || continue
        case "$name" in \#*) continue ;; esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$ip" "${token:--}" "${allowed:-*}" "${current:--}" || return 0
    done < "$CONTAINERS_FILE"
}

append_container_row() {
    local file="$1" name="$2" ip="$3" token="$4" allowed="$5" current="$6" project="${7:-}" instance="${8:-}" fingerprint="${9:-}"
    {
        printf '%s\t%s\t%s\t%s\t%s' "$name" "$ip" "$token" "$allowed" "$current"
        if [ -n "$project" ] || [ -n "$instance" ]; then
            printf '\t%s\t%s\t%s' "$project" "$instance" "$fingerprint"
        fi
        printf '\n'
    } >> "$file"
}

read_split_apps() {
    [ -f "$SPLIT_APPS_FILE" ] || return 0
    while IFS=$'\t' read -r app display category remote enabled rest; do
        [ -n "${app:-}" ] || continue
        case "$app" in \#*) continue ;; esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$app" "${display:-$app}" "${category:-未分类}" "${remote:-$app}" "${enabled:-true}" || return 0
    done < "$SPLIT_APPS_FILE"
}

read_split_policies() {
    [ -f "$SPLIT_POLICIES_FILE" ] || return 0
    while IFS=$'\t' read -r app target rest; do
        [ -n "${app:-}" ] || continue
        case "$app" in \#*) continue ;; esac
        printf '%s\t%s\n' "$app" "${target:--}" || return 0
    done < "$SPLIT_POLICIES_FILE"
}

read_split_category_policies() {
    [ -f "$SPLIT_CATEGORY_POLICIES_FILE" ] || return 0
    while IFS=$'\t' read -r category target rest; do
        [ -n "${category:-}" ] || continue
        case "$category" in \#*) continue ;; esac
        printf '%s\t%s\n' "$category" "${target:--}" || return 0
    done < "$SPLIT_CATEGORY_POLICIES_FILE"
}

read_container_split_policies() {
    [ -f "$SPLIT_CONTAINER_POLICIES_FILE" ] || return 0
    while IFS=$'\t' read -r container app target rest; do
        [ -n "${container:-}" ] || continue
        case "$container" in \#*) continue ;; esac
        printf '%s\t%s\t%s\n' "$container" "$app" "${target:--}" || return 0
    done < "$SPLIT_CONTAINER_POLICIES_FILE"
}

read_force_split_policies() {
    [ -f "$SPLIT_FORCE_POLICIES_FILE" ] || return 0
    while IFS=$'\t' read -r app rest; do
        [ -n "${app:-}" ] || continue
        case "$app" in \#*) continue ;; esac
        printf '%s\n' "$app" || return 0
    done < "$SPLIT_FORCE_POLICIES_FILE"
}

read_force_split_category_policies() {
    [ -f "$SPLIT_FORCE_CATEGORY_POLICIES_FILE" ] || return 0
    while IFS=$'\t' read -r category rest; do
        [ -n "${category:-}" ] || continue
        case "$category" in \#*) continue ;; esac
        printf '%s\n' "$category" || return 0
    done < "$SPLIT_FORCE_CATEGORY_POLICIES_FILE"
}

read_force_on_exit_policies() {
    [ -f "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" ] || return 0
    awk -F '\t' 'NF >= 3 && $1 !~ /^#/ {print $1 "\t" $2 "\t" $3}' "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE"
}

read_force_category_on_exit_policies() {
    [ -f "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE" ] || return 0
    awk -F '\t' 'NF >= 3 && $1 !~ /^#/ {print $1 "\t" $2 "\t" $3}' "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE"
}

read_enabled_split_app_ids() {
    local category source target app display app_category remote enabled
    {
        read_split_policies | awk -F '\t' '{print $1}'
        read_force_on_exit_policies | awk -F '\t' '{print $1}'
        while IFS=$'\t' read -r category source target; do
            while IFS=$'\t' read -r app display app_category remote enabled; do
                [ "$app_category" = "$category" ] && printf '%s\n' "$app"
            done < <(read_split_apps)
        done < <(read_force_category_on_exit_policies)
    } | awk 'NF && !seen[$0]++'
}

set_config_value() {
    local key="$1" value="$2" tmp
    [ -n "$key" ] || die "配置项不能为空。"
    state_lock_acquire
    write_default_config
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
        index($0, key "=") == 1 {
            print key "=\"" value "\""
            done = 1
            next
        }
        { print }
        END {
            if (!done) {
                print key "=\"" value "\""
            }
        }
    ' "$CONFIG_FILE" > "$tmp"
    install -m 0600 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
    state_lock_release
}

ensure_config_default() {
    local key="$1" value="$2"
    [ -f "$CONFIG_FILE" ] || write_default_config
    if ! grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        set_config_value "$key" "$value"
    fi
}

ensure_runtime_config_defaults() {
    ensure_config_default BRIDGE_IFACES "incusbr0 lxdbr0"
    ensure_config_default API_BIND "0.0.0.0"
    ensure_config_default API_PORT 18988
    ensure_config_default API_PUBLIC_URL "http://10.88.0.1:18988"
    ensure_config_default API_MAX_CONCURRENT 24
    ensure_config_default API_RATE_LIMIT 120
    ensure_config_default API_MAX_BODY 4096
    ensure_config_default API_SOCKET_TIMEOUT 15
    ensure_config_default NFT_TABLE incus_egress_switch
    ensure_config_default RULE_PRIORITY 80
    ensure_config_default LIMIT_BURST 64kb
    ensure_config_default LIMIT_LATENCY 50ms
    ensure_config_default SWITCH_CLEAR_CONNTRACK true
    ensure_config_default BLOCK_UNMANAGED_IPV6 true
    ensure_config_default ENABLE_SPLIT_RULES true
    ensure_config_default SPLIT_RULE_BUNDLE_URL "https://raw.githubusercontent.com/0xdabiaoge/VPS-Tool/main/Scam-Abuse-Risk.list"
    ensure_config_default SPLIT_UPDATE_INTERVAL 259200
    ensure_config_default SPLIT_DNS_REFRESH_INTERVAL 21600
    ensure_config_default SPLIT_FETCH_TIMEOUT 10
    ensure_config_default SPLIT_DOMAIN_RESOLVE_LIMIT 80
    ensure_config_default SPLIT_DNS_TIMEOUT 1
    ensure_config_default SPLIT_DNS_WORKERS 4
    ensure_config_default SPLIT_DNSMASQ_NFTSET true
    ensure_config_default STRICT_TOKEN true
    ensure_config_default AUTO_SYNC true
    ensure_config_default AUTO_INTERVAL 15
    ensure_config_default AUTO_PROJECTS default
    ensure_config_default AUTO_INCLUDE_REGEX ".*"
    ensure_config_default AUTO_EXCLUDE_REGEX ""
    ensure_config_default AUTO_ALLOW_EXITS "*"
    ensure_config_default AUTO_DEFAULT_EXIT ""
    ensure_config_default AUTO_INSTALL_CLIENT true
    ensure_config_default AUTO_CLIENT_VERIFY_INTERVAL 300
    ensure_config_default AUTO_CLIENT_PATH "/usr/local/bin/out"
    ensure_config_default AUTO_TOKEN_PATH "/etc/incus-egress-token"
    ensure_config_default AUTO_RUNNING_ONLY true
    ensure_config_default AUTO_SYNC_WORKERS 8
    ensure_config_default AUTO_INJECT_WORKERS 4
    ensure_config_default AUTO_STATE_REFRESH_INTERVAL 300
    ensure_config_default AUTO_COMMAND_TIMEOUT 30
    ensure_config_default AUTO_DELETE_GRACE_SCANS 2
    ensure_config_default AUTO_RECONCILE_MIN_INTERVAL 10
    ensure_config_default AUTO_EVENT_DEBOUNCE 2
    ensure_config_default UPDATE_BACKUP_KEEP 5
    ensure_config_default UPDATE_HEALTH_TIMEOUT 30
    ensure_config_default UPDATE_SCRIPT_URL "$DEFAULT_UPDATE_SCRIPT_URL"
}

upgrade_config_and_components() {
    need_root
    local source_path="${1:-}" main_was_active="false" main_was_enabled="false"
    local autosync_was_active="false" autosync_was_enabled="false"
    install_host_dependencies
    need_cmd install
    need_cmd python3
    need_cmd systemctl
    need_cmd ip
    need_cmd nft
    need_cmd curl
    need_cmd tar
    need_cmd gzip
    need_cmd sha256sum
    [ -n "$source_path" ] || source_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    source_path="$(readlink -f "$source_path" 2>/dev/null || printf '%s' "$source_path")"
    [ -f "$source_path" ] || source_path="$INSTALL_BIN"
    preflight_update_source "$source_path"

    unit_is_active "$APP_NAME.service" && main_was_active="true"
    unit_is_enabled "$APP_NAME.service" && main_was_enabled="true"
    unit_is_active "$APP_NAME-autosync.service" && autosync_was_active="true"
    unit_is_enabled "$APP_NAME-autosync.service" && autosync_was_enabled="true"
    systemctl stop "$APP_NAME-autosync" "$APP_NAME" 2>/dev/null || true

    if ! create_update_backup "$source_path" "$main_was_active" "$main_was_enabled" "$autosync_was_active" "$autosync_was_enabled"; then
        if [ -n "$UPDATE_BACKUP_PATH" ]; then
            case "$UPDATE_BACKUP_PATH" in
                "$UPDATE_BACKUP_ROOT"/*) rm -rf -- "$UPDATE_BACKUP_PATH" ;;
            esac
        fi
        restore_update_service_state "$main_was_active" "$main_was_enabled" "$autosync_was_active" "$autosync_was_enabled" || true
        die "无法创建更新前备份，已取消更新。"
    fi

    if (
        set -e
        write_default_config
        ensure_runtime_config_defaults
        install_runtime_sysctls
        load_config
        preflight_update_runtime
        do_apply
        mkdir -p "$LIB_DIR" "$RUN_DIR"
        if [ "$source_path" != "$INSTALL_BIN" ]; then
            install_self_atomically "$source_path"
            info "已更新安装脚本: $INSTALL_BIN"
        fi
        install_shortcut
        write_controller
        write_autosync
        write_client_file
        write_service
        refresh_existing_exit_service_hooks
        systemctl daemon-reload
        systemctl enable "$APP_NAME.service" >/dev/null
        systemctl restart "$APP_NAME.service"
        if [ "$autosync_was_active" = "true" ]; then
            systemctl restart "$APP_NAME-autosync.service"
        else
            systemctl stop "$APP_NAME-autosync.service" 2>/dev/null || true
        fi
        update_health_check "$autosync_was_active" "$UPDATE_BACKUP_PATH"
    ); then
        load_config
        prune_update_backups
        info "安全更新完成：配置项、脚本组件、systemd 和数据面均已通过健康检查。"
        info "现有出口、容器授权、token、限速、分流策略和自定义规则均已保留。"
        info "更新前备份: $UPDATE_BACKUP_PATH"
        return 0
    fi

    warn "安全更新未通过，开始自动回滚。"
    if restore_update_backup "$UPDATE_BACKUP_PATH" "$main_was_active" "$main_was_enabled" "$autosync_was_active" "$autosync_was_enabled"; then
        load_config
        prune_update_backups
        die "更新失败，已恢复到更新前状态；请查看上方错误后重试。"
    fi
    die "更新失败且自动回滚未完全恢复。请立即检查服务，并使用备份目录: $UPDATE_BACKUP_PATH"
}

update_from_github() {
    need_root
    load_config
    need_cmd curl
    need_cmd mktemp
    local url="${1:-${UPDATE_SCRIPT_URL:-$DEFAULT_UPDATE_SCRIPT_URL}}" tmp
    [ -n "$url" ] || die "GitHub 更新地址不能为空。"
    tmp="$(mktemp /tmp/incus-egress-online-update.XXXXXX.sh)"
    info "正在从 GitHub 获取更新: $url"
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 120 -o "$tmp" "$url"; then
        rm -f "$tmp"
        die "GitHub 更新脚本下载失败；当前安装未做任何修改。"
    fi
    chmod 0700 "$tmp"
    # 复用原有安全更新：完整预检、备份、健康检查与失败回滚。
    upgrade_config_and_components "$tmp"
    rm -f "$tmp"
}

first_exit_name() {
    [ -f "$EXITS_FILE" ] || return 0
    awk -F '\t' 'NF && $1 !~ /^#/ {print $1; exit}' "$EXITS_FILE"
}

is_entry_exit_alias() {
    case "${1:-}" in
        -|入口机|host|direct|entry|local|main) return 0 ;;
        *) return 1 ;;
    esac
}

display_exit_name() {
    if [ "${1:-}" = "-" ] || [ -z "${1:-}" ]; then
        printf '入口机'
    else
        exit_display "$1"
    fi
}

resolve_exit_target() {
    local target="${1:-}" matched=""
    if [ -z "$target" ]; then
        printf -- '-\n'
        return 0
    fi
    if exit_exists "$target"; then
        printf '%s\n' "$target"
        return 0
    fi
    matched="$(exit_name_by_display "$target")"
    if [ -n "$matched" ]; then
        printf '%s\n' "$matched"
        return 0
    fi
    if is_entry_exit_alias "$target"; then
        printf -- '-\n'
        return 0
    fi
    return 1
}

split_target_list_each() {
    local list="${1:-}" item
    while [ -n "$list" ]; do
        item="${list%%,*}"
        item="$(trim_space "$item")"
        [ -n "$item" ] && printf '%s\n' "$item"
        [ "$list" = "${list#*,}" ] && break
        list="${list#*,}"
    done
}

split_target_list_default() {
    local list="${1:-}" first
    first="${list%%,*}"
    first="$(trim_space "$first")"
    printf '%s' "$first"
}

split_target_list_contains() {
    local list="${1:-}" target="${2:-}" item
    while IFS= read -r item; do
        [ "$item" = "$target" ] && return 0
    done < <(split_target_list_each "$list")
    return 1
}

split_target_list_label() {
    local list="${1:-}" item label out="" count=0 first=""
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        label="$(display_exit_name "$item")"
        [ -n "$first" ] || first="$label"
        if [ -n "$out" ]; then
            out="$out, $label"
        else
            out="$label"
        fi
        count=$((count + 1))
    done < <(split_target_list_each "$list")
    if [ -z "$out" ]; then
        printf '未设置'
    elif [ "$count" -gt 1 ]; then
        printf '%s（默认：%s）' "$out" "$first"
    else
        printf '%s' "$out"
    fi
}

resolve_split_target_list() {
    local raw item resolved out="" seen=","
    [ "$#" -gt 0 ] || return 1
    for raw in "$@"; do
        [ -n "${raw:-}" ] || continue
        while [ -n "$raw" ]; do
            item="${raw%%,*}"
            item="$(trim_space "$item")"
            if [ -n "$item" ]; then
                resolved="$(resolve_exit_target "$item")" || return 1
                case "$seen" in
                    *,"$resolved",*) ;;
                    *)
                        [ -n "$out" ] && out="$out,"
                        out="$out$resolved"
                        seen="$seen$resolved,"
                        ;;
                esac
            fi
            [ "$raw" = "${raw#*,}" ] && break
            raw="${raw#*,}"
        done
    done
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

split_target_list_remove() {
    local list="${1:-}" removed="${2:-}" item out="" changed="false"
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        if [ "$item" = "$removed" ]; then
            changed="true"
            continue
        fi
        [ -n "$out" ] && out="$out,"
        out="$out$item"
    done < <(split_target_list_each "$list")
    [ -n "$out" ] || out="-"
    printf '%s\t%s\n' "$out" "$changed"
}

exit_exists() {
    local target="$1"
    [ -f "$EXITS_FILE" ] || return 1
    awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $1 == n {found=1} END {exit found ? 0 : 1}' "$EXITS_FILE"
}

exit_display() {
    local target="$1" display
    display="$([ -f "$EXITS_FILE" ] && awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $1 == n {print ($6 ? $6 : $1); exit}' "$EXITS_FILE" || true)"
    printf '%s' "${display:-$target}"
}

exit_name_by_display() {
    local target="$1"
    [ -f "$EXITS_FILE" ] || return 0
    awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $6 == n {print $1; exit}' "$EXITS_FILE"
}

exit_mark() {
    local target="$1"
    [ -f "$EXITS_FILE" ] || return 0
    awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $1 == n {print $2; exit}' "$EXITS_FILE"
}

exit_row() {
    local target="$1"
    [ -f "$EXITS_FILE" ] || return 0
    awk -F '\t' -v n="$target" '
        NF && $1 !~ /^#/ && $1 == n {
            print $1 "\t" $2 "\t" $3 "\t" ($4 ? $4 : "none") "\t" ($5 ? $5 : "none") "\t" ($6 ? $6 : $1)
            exit
        }
    ' "$EXITS_FILE"
}

split_app_exists() {
    local target="$1"
    [ -f "$SPLIT_APPS_FILE" ] || return 1
    awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $1 == n {found=1} END {exit found ? 0 : 1}' "$SPLIT_APPS_FILE"
}

split_app_display() {
    local target="$1" display
    display="$([ -f "$SPLIT_APPS_FILE" ] && awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $1 == n {print ($2 ? $2 : $1); exit}' "$SPLIT_APPS_FILE" || true)"
    printf '%s' "${display:-$target}"
}

split_app_category() {
    local target="$1"
    [ -f "$SPLIT_APPS_FILE" ] || return 0
    awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $1 == n {print ($3 ? $3 : "未分类"); exit}' "$SPLIT_APPS_FILE"
}

split_app_remote() {
    local target="$1"
    [ -f "$SPLIT_APPS_FILE" ] || return 0
    awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $1 == n {print ($4 ? $4 : $1); exit}' "$SPLIT_APPS_FILE"
}

split_app_id_by_display() {
    local display="$1"
    [ -f "$SPLIT_APPS_FILE" ] || return 0
    awk -F '\t' -v n="$display" 'NF && $1 !~ /^#/ && ($2 ? $2 : $1) == n {print $1; exit}' "$SPLIT_APPS_FILE"
}

split_policy_target() {
    local target="$1"
    split_target_list_default "$(split_policy_targets "$target")"
}

split_policy_targets() {
    local target="$1"
    [ -f "$SPLIT_POLICIES_FILE" ] || return 0
    awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $1 == n {print ($2 ? $2 : "-"); exit}' "$SPLIT_POLICIES_FILE"
}

split_category_policy_target() {
    local target="$1"
    split_target_list_default "$(split_category_policy_targets "$target")"
}

split_category_policy_targets() {
    local target="$1"
    [ -f "$SPLIT_CATEGORY_POLICIES_FILE" ] || return 0
    awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && $1 == n {print ($2 ? $2 : "-"); exit}' "$SPLIT_CATEGORY_POLICIES_FILE"
}

split_category_exists() {
    local target="$1"
    [ -f "$SPLIT_APPS_FILE" ] || return 1
    awk -F '\t' -v n="$target" 'NF && $1 !~ /^#/ && ($3 ? $3 : "未分类") == n {found=1} END {exit found ? 0 : 1}' "$SPLIT_APPS_FILE"
}

split_app_is_forced() {
    local app="$1" category
    force_split_app_exists "$app" && return 0
    category="$(split_app_category "$app")"
    [ -n "$category" ] || return 1
    force_split_category_exists "$category"
}

force_split_app_exists() {
    local app="$1"
    [ -f "$SPLIT_FORCE_POLICIES_FILE" ] || return 1
    awk -F '\t' -v n="$app" 'NF && $1 !~ /^#/ && $1 == n {found=1} END {exit found ? 0 : 1}' "$SPLIT_FORCE_POLICIES_FILE"
}

force_split_category_exists() {
    local category="$1"
    [ -f "$SPLIT_FORCE_CATEGORY_POLICIES_FILE" ] || return 1
    awk -F '\t' -v n="$category" 'NF && $1 !~ /^#/ && $1 == n {found=1} END {exit found ? 0 : 1}' "$SPLIT_FORCE_CATEGORY_POLICIES_FILE"
}

force_on_exit_app_exists() {
    local app="$1" source="$2"
    [ -f "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" ] || return 1
    awk -F '\t' -v a="$app" -v s="$source" 'NF >= 3 && $1 !~ /^#/ && $1 == a && $2 == s {found=1} END {exit found ? 0 : 1}' "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE"
}

force_on_exit_target() {
    local app="$1" source="$2" category
    [ -f "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" ] && awk -F '\t' -v a="$app" -v s="$source" 'NF >= 3 && $1 !~ /^#/ && $1 == a && $2 == s {print $3; exit}' "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE"
    force_on_exit_app_exists "$app" "$source" && return 0
    category="$(split_app_category "$app")"
    [ -n "$category" ] || return 1
    [ -f "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE" ] || return 1
    awk -F '\t' -v c="$category" -v s="$source" 'NF >= 3 && $1 !~ /^#/ && $1 == c && $2 == s {print $3; found=1; exit} END {exit found ? 0 : 1}' "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE"
}

container_current_exit() {
    local container="$1"
    [ -f "$CONTAINERS_FILE" ] || return 0
    awk -F '\t' -v n="$container" 'NF && $1 !~ /^#/ && $1 == n {print $5; exit}' "$CONTAINERS_FILE"
}

split_count_file() {
    local file="$1"
    [ -f "$file" ] || { printf '0'; return 0; }
    awk 'NF && $1 !~ /^#/ {n++} END {print n+0}' "$file"
}

split_resolved_v4_file() {
    printf '%s/%s.ipv4\n' "$SPLIT_RESOLVED_DIR" "$1"
}

split_resolved_v6_file() {
    printf '%s/%s.ipv6\n' "$SPLIT_RESOLVED_DIR" "$1"
}

split_raw_file() {
    printf '%s/%s.rules\n' "$SPLIT_RAW_DIR" "$1"
}

split_target_label() {
    local target="${1:-}"
    if [ -z "$target" ]; then
        printf '未设置'
    else
        split_target_list_label "$target"
    fi
}

split_app_policy_is_category_default() {
    local app="$1" target="$2" category category_target
    category="$(split_app_category "$app")"
    [ -n "$category" ] || return 1
    category_target="$(split_category_policy_targets "$category")"
    [ -n "$category_target" ] && [ "$category_target" = "$target" ]
}

declare -A SPLIT_NFT_NAME_CACHE=()

split_nft_name_into() {
    local output_var="$1" name="$2" clean digest generated
    if [ -n "${SPLIT_NFT_NAME_CACHE[$name]+x}" ]; then
        printf -v "$output_var" '%s' "${SPLIT_NFT_NAME_CACHE[$name]}"
        return 0
    fi
    clean="${name,,}"
    clean="${clean//-/_}"
    clean="${clean//[!a-z0-9_]/_}"
    while [[ "$clean" == _* ]]; do clean="${clean#_}"; done
    while [[ "$clean" == *_ ]]; do clean="${clean%_}"; done
    clean="${clean:0:39}"
    [ -n "$clean" ] || clean="set"
    digest="$(printf '%s' "$name" | sha256sum)"
    digest="${digest%% *}"
    generated="${clean}_${digest:0:8}"
    SPLIT_NFT_NAME_CACHE[$name]="$generated"
    printf -v "$output_var" '%s' "$generated"
}

split_nft_name() {
    local safe_name
    split_nft_name_into safe_name "$1"
    printf '%s\n' "$safe_name"
}

validate_exits() {
    local name mark table route4 route6 display dev mark_key table_key
    local -A seen_names=() seen_marks=() seen_tables=() seen_devs=()
    while IFS=$'\t' read -r name mark table route4 route6 display; do
        valid_name "$name" || die "Invalid exit name: $name"
        valid_mark "$mark" || die "Invalid mark for exit $name: $mark"
        valid_table_id "$table" || die "Invalid table id for exit $name: $table"
        case "$table" in 253|254|255) die "出口 $name 使用了系统保留路由表 ID: $table" ;; esac
        [ -n "$route4" ] || die "Missing route4 for exit $name"
        [ -n "$route6" ] || die "Missing route6 for exit $name"
        [ -z "${seen_names[$name]:-}" ] || die "出口内部 ID 重复: $name"
        if [[ "$mark" == 0x* || "$mark" == 0X* ]]; then
            mark_key="$((mark))"
        else
            mark_key="$((10#$mark))"
        fi
        table_key="$((10#$table))"
        [ -z "${seen_marks[$mark_key]:-}" ] || die "出口 $name 与 ${seen_marks[$mark_key]} 使用了相同 fwmark: $mark"
        [ -z "${seen_tables[$table_key]:-}" ] || die "出口 $name 与 ${seen_tables[$table_key]} 使用了相同路由表: $table"
        seen_names[$name]=1
        seen_marks[$mark_key]="$name"
        seen_tables[$table_key]="$name"
        dev="$(exit_limit_device "$route4" "$route6" 2>/dev/null || true)"
        if [ -n "$dev" ]; then
            [ -z "${seen_devs[$dev]:-}" ] || die "出口 $name 与 ${seen_devs[$dev]} 使用了相同设备: $dev"
            seen_devs[$dev]="$name"
        fi
    done < <(read_exit_rows)
}

validate_exit_limits() {
    local name down up
    [ -f "$LIMITS_FILE" ] || return 0
    while read -r name down up _rest; do
        [ -n "${name:-}" ] || continue
        case "$name" in \#*) continue ;; esac
        exit_exists "$name" || die "出口限速引用了未知出口: $name"
        valid_limit_rate "${down:--}" || die "出口 $name 的下载限速无效: ${down:-}"
        valid_limit_rate "${up:-$down}" || die "出口 $name 的上传限速无效: ${up:-}"
    done < "$LIMITS_FILE"
}

validate_runtime_config() {
    [[ "$NFT_TABLE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [ "${#NFT_TABLE}" -le 48 ] || die "nftables 表名无效（仅允许字母、数字、下划线，且不超过 48 字符）: $NFT_TABLE"
    [[ "$RULE_PRIORITY" =~ ^[0-9]+$ ]] || die "策略路由优先级必须是整数: $RULE_PRIORITY"
    [ "$RULE_PRIORITY" -ge 1 ] && [ "$RULE_PRIORITY" -lt 4294967295 ] || die "策略路由优先级超出范围: $RULE_PRIORITY"
    [[ "$UPDATE_BACKUP_KEEP" =~ ^[0-9]+$ ]] && [ "$UPDATE_BACKUP_KEEP" -ge 1 ] && [ "$UPDATE_BACKUP_KEEP" -le 100 ] || die "更新备份保留数量必须是 1-100: $UPDATE_BACKUP_KEEP"
    [[ "$UPDATE_HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$UPDATE_HEALTH_TIMEOUT" -ge 5 ] && [ "$UPDATE_HEALTH_TIMEOUT" -le 600 ] || die "更新健康检查超时必须是 5-600 秒: $UPDATE_HEALTH_TIMEOUT"
    bridge_set_expr >/dev/null
}

validate_containers() {
    local name ip token allowed current item
    local items=()
    local -A seen_names=() seen_ips=() seen_tokens=()
    while IFS=$'\t' read -r name ip token allowed current; do
        valid_name "$name" || die "Invalid container name: $name"
        if ! is_ipv4 "$ip" && ! is_ipv6 "$ip"; then
            die "Invalid container IP for $name: $ip"
        fi
        [ -z "${seen_names[$name]:-}" ] || die "容器名称重复: $name"
        [ -z "${seen_ips[$ip]:-}" ] || die "容器 $name 与 ${seen_ips[$ip]} 使用了相同 IP: $ip；为避免串号已拒绝应用规则。"
        seen_names[$name]=1
        seen_ips[$ip]="$name"
        if [ -n "$token" ] && [ "$token" != "-" ]; then
            [ -z "${seen_tokens[$token]:-}" ] || die "容器 $name 与 ${seen_tokens[$token]} 使用了相同 token。"
            seen_tokens[$token]="$name"
        fi
        if [ "$allowed" != "*" ] && [ "$allowed" != "-" ]; then
            IFS=',' read -r -a items <<< "$allowed"
            for item in "${items[@]}"; do
                [ -n "$item" ] || continue
                exit_exists "$item" || die "Container $name allowed list uses unknown exit: $item"
            done
        fi
        [ "$current" = "-" ] || exit_exists "$current" || die "Container $name uses unknown exit: $current"
        [ "$current" = "-" ] || allowed_contains "$allowed" "$current" || die "Container $name current exit is not allowed: $current"
    done < <(read_container_rows)
}

validate_split_policies() {
    local app target targets container category item source
    [ "${ENABLE_SPLIT_RULES:-true}" = "true" ] || return 0
    while IFS=$'\t' read -r app targets; do
        split_app_exists "$app" || die "应用分流策略引用了未知应用: $app"
        while IFS= read -r item; do
            [ "$item" = "-" ] || exit_exists "$item" || die "应用分流策略 $app 引用了未知出口: $item"
        done < <(split_target_list_each "$targets")
    done < <(read_split_policies)
    while IFS=$'\t' read -r category targets; do
        split_category_exists "$category" || die "分类分流策略引用了未知分类: $category"
        while IFS= read -r item; do
            [ "$item" = "-" ] || exit_exists "$item" || die "分类分流策略 $category 引用了未知出口: $item"
        done < <(split_target_list_each "$targets")
    done < <(read_split_category_policies)
    while IFS=$'\t' read -r container app target; do
        container_exists "$container" || die "容器级分流引用了未知容器: $container"
        split_app_exists "$app" || die "容器级分流 $container 引用了未知应用: $app"
        [ "$target" = "-" ] || exit_exists "$target" || die "容器级分流 $container/$app 引用了未知出口: $target"
        targets="$(split_policy_targets "$app")"
        [ -z "$targets" ] || split_target_list_contains "$targets" "$target" || die "容器级分流 $container/$app 引用了不在候选列表内的出口: $target"
        container_allows_exit "$container" "$target" || die "容器级分流 $container/$app 引用了该容器未授权的出口: $target"
    done < <(read_container_split_policies)
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        split_app_exists "$app" || die "强制应用分流引用了未知应用: $app"
        [ -n "$(split_policy_target "$app")" ] || die "强制应用分流 $app 尚未设置宿主机分流目标"
    done < <(read_force_split_policies)
    while IFS= read -r category; do
        [ -n "$category" ] || continue
        split_category_exists "$category" || die "强制分类分流引用了未知分类: $category"
    done < <(read_force_split_category_policies)
    while IFS=$'\t' read -r app source target; do
        split_app_exists "$app" || die "按出口强制应用分流引用了未知应用: $app"
        [ "$source" = "-" ] || exit_exists "$source" || die "按出口强制应用分流 $app 引用了未知来源出口: $source"
        while IFS= read -r item; do [ "$item" = "-" ] || exit_exists "$item" || die "按出口强制应用分流 $app 引用了未知目标出口: $item"; done < <(split_target_list_each "$target")
    done < <(read_force_on_exit_policies)
    while IFS=$'\t' read -r category source target; do
        split_category_exists "$category" || die "按出口强制分类分流引用了未知分类: $category"
        [ "$source" = "-" ] || exit_exists "$source" || die "按出口强制分类分流 $category 引用了未知来源出口: $source"
        while IFS= read -r item; do [ "$item" = "-" ] || exit_exists "$item" || die "按出口强制分类分流 $category 引用了未知目标出口: $item"; done < <(split_target_list_each "$target")
    done < <(read_force_category_on_exit_policies)
}

route_spec_value() {
    local spec="$1" key="$2" part k v
    local parts=()
    IFS=',' read -r -a parts <<< "$spec"
    for part in "${parts[@]}"; do
        k="${part%%:*}"
        v="${part#*:}"
        [ "$k" = "$key" ] && { printf '%s\n' "$v"; return 0; }
    done
    return 1
}

apply_default_route() {
    local family="$1" table="$2" spec="$3" via="" dev="" route_cmd
    local -a cmd
    case "$spec" in ""|none|-) return 0 ;; esac
    via="$(route_spec_value "$spec" via || true)"
    dev="$(route_spec_value "$spec" dev || true)"
    [ -n "$via" ] || [ -n "$dev" ] || die "Invalid route spec: $spec"

    if [ "$family" = "6" ]; then
        route_cmd=(ip -6 route)
    else
        route_cmd=(ip route)
    fi
    # 专用路由表先放置不可达兜底；隧道掉线或路由消失时禁止继续回落到 main 表泄漏直连。
    while "${route_cmd[@]}" del default table "$table" 2>/dev/null; do :; done
    "${route_cmd[@]}" add unreachable default metric 42760 table "$table" 2>/dev/null || true
    [ -n "$via" ] && cmd+=(via "$via")
    [ -n "$dev" ] && cmd+=(dev "$dev")
    if [ -n "$dev" ] && ! ip link show "$dev" >/dev/null 2>&1; then
        warn "出口设备 $dev 尚未就绪，table $table 已进入阻断保护，流量不会回落到入口机。"
        return 0
    fi
    cmd=("${route_cmd[@]}" add default "${cmd[@]}" metric 10 table "$table")
    if ! "${cmd[@]}"; then
        warn "table $table 的出口路由添加失败，已保留不可达兜底以阻止流量泄漏。"
    fi
}

# 只删除本脚本记录过的 ip rule，避免误删宿主机上已有的其它策略路由。
reset_managed_ip_rules() {
    mkdir -p "$RUN_DIR"
    if [ -f "$RULE_STATE_FILE" ]; then
        while read -r family priority mark table; do
            [ -n "${family:-}" ] || continue
            if [ "$family" = "6" ]; then
                if [ "${table:--}" = "-" ]; then
                    ip -6 rule del unreachable priority "$priority" fwmark "$mark" 2>/dev/null || true
                else
                    ip -6 rule del priority "$priority" fwmark "$mark" lookup "$table" 2>/dev/null || true
                fi
            else
                if [ "${table:--}" = "-" ]; then
                    ip rule del unreachable priority "$priority" fwmark "$mark" 2>/dev/null || true
                else
                    ip rule del priority "$priority" fwmark "$mark" lookup "$table" 2>/dev/null || true
                fi
            fi
        done < "$RULE_STATE_FILE"
    fi
    : > "$RULE_STATE_FILE"
}

# 为每个出口建立 fwmark -> route table 的策略路由。
# 真正的出口隧道或 sing-box 实例需要你提前准备好，这里只负责把标记后的流量送进对应表。
apply_routes_and_rules() {
    local name mark table route4 route6 display fallback_priority ipv6_available="false"
    # 先准备全部路由，再替换规则；准备失败时旧规则仍然受不可达路由保护。
    while IFS=$'\t' read -r name mark table route4 route6 display; do
        apply_default_route 4 "$table" "$route4"
        apply_default_route 6 "$table" "$route6"
    done < <(read_exit_rows)
    reset_managed_ip_rules
    fallback_priority=$((RULE_PRIORITY + 1))
    ip -6 rule show >/dev/null 2>&1 && ipv6_available="true"
    while IFS=$'\t' read -r name mark table route4 route6 display; do
        ip rule add priority "$RULE_PRIORITY" fwmark "$mark" lookup "$table" || die "无法添加 IPv4 策略路由规则: $name"
        printf '4 %s %s %s\n' "$RULE_PRIORITY" "$mark" "$table" >> "$RULE_STATE_FILE"
        ip rule add unreachable priority "$fallback_priority" fwmark "$mark" || die "无法添加 IPv4 出口失效保护规则: $name"
        printf '4 %s %s -\n' "$fallback_priority" "$mark" >> "$RULE_STATE_FILE"
        if [ "$ipv6_available" = "true" ]; then
            ip -6 rule add priority "$RULE_PRIORITY" fwmark "$mark" lookup "$table" || die "无法添加 IPv6 策略路由规则: $name"
            printf '6 %s %s %s\n' "$RULE_PRIORITY" "$mark" "$table" >> "$RULE_STATE_FILE"
            ip -6 rule add unreachable priority "$fallback_priority" fwmark "$mark" || die "无法添加 IPv6 出口失效保护规则: $name"
            printf '6 %s %s -\n' "$fallback_priority" "$mark" >> "$RULE_STATE_FILE"
        fi
    done < <(read_exit_rows)
}

limit_is_unlimited() {
    [ -z "${1:-}" ] || [ "${1:-}" = "-" ]
}

exit_limit_device() {
    local route4="$1" route6="$2" dev=""
    dev="$(route_spec_value "$route4" dev 2>/dev/null || true)"
    [ -n "$dev" ] || dev="$(route_spec_value "$route6" dev 2>/dev/null || true)"
    [ -n "$dev" ] || return 1
    printf '%s\n' "$dev"
}

reset_tc_limit_on_dev() {
    local dev="$1"
    command -v tc >/dev/null 2>&1 || return 0
    tc qdisc del dev "$dev" root 2>/dev/null || true
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
}

apply_tc_limit_on_dev() {
    local dev="$1" down="$2" up="$3" tc_down tc_up
    ip link show "$dev" >/dev/null 2>&1 || { warn "出口限速设备 $dev 尚未就绪，暂时跳过。"; return 0; }
    need_cmd tc
    tc_down="$(limit_rate_to_tc "$down")"
    tc_up="$(limit_rate_to_tc "$up")"
    reset_tc_limit_on_dev "$dev"
    if ! limit_is_unlimited "$up"; then
        tc qdisc replace dev "$dev" root tbf rate "$tc_up" burst "$LIMIT_BURST" latency "$LIMIT_LATENCY"
    fi
    if ! limit_is_unlimited "$down"; then
        tc qdisc add dev "$dev" handle ffff: ingress
        tc filter add dev "$dev" parent ffff: protocol ip prio 50 u32 match u32 0 0 police rate "$tc_down" burst "$LIMIT_BURST" drop flowid :1
        tc filter add dev "$dev" parent ffff: protocol ipv6 prio 51 u32 match u32 0 0 police rate "$tc_down" burst "$LIMIT_BURST" drop flowid :1 2>/dev/null || true
    fi
}

apply_exit_limits() {
    local name mark table route4 route6 display dev down up
    while IFS=$'\t' read -r name mark table route4 route6 display; do
        dev="$(exit_limit_device "$route4" "$route6" || true)"
        [ -n "$dev" ] || continue
        down="$(exit_limit_down "$name")"
        up="$(exit_limit_up "$name")"
        apply_tc_limit_on_dev "$dev" "$down" "$up"
    done < <(read_exit_rows)
}

bridge_set_expr() {
    local iface out=""
    for iface in $BRIDGE_IFACES; do
        valid_name "$iface" || die "Invalid bridge interface name: $iface"
        if [ -n "$out" ]; then
            out="$out, \"$iface\""
        else
            out="\"$iface\""
        fi
    done
    [ -n "$out" ] || die "BRIDGE_IFACES is empty."
    printf '%s\n' "$out"
}

nft_elements_from_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    awk 'NF && $1 !~ /^#/ {gsub(/\r/, "", $1); if ($1 != "") {printf "%s%s", sep, $1; sep=", "}}' "$file"
}

build_split_dnsmasq_file() {
    local out="$1" app raw safe kind domain
    : > "$out"
    [ "${ENABLE_SPLIT_RULES:-true}" = "true" ] || return 0
    while IFS=$'\t' read -r app _target; do
        [ -n "$app" ] || continue
        raw="$(split_raw_file "$app")"
        [ -s "$raw" ] || continue
        split_nft_name_into safe "$app"
        [ -n "$safe" ] || continue
        while IFS=$'\t' read -r kind domain; do
            case "$kind" in DOMAIN|DOMAIN-SUFFIX) ;; *) continue ;; esac
            domain="${domain,,}"
            [[ "$domain" == \*.* ]] && domain="${domain:2}"
            domain="${domain#.}"
            domain="${domain%.}"
            valid_domain_name "$domain" || continue
            printf 'nftset=/%s/4#inet#%s#split4_%s\n' "$domain" "$NFT_TABLE" "$safe" >> "$out"
            printf 'nftset=/%s/6#inet#%s#split6_%s\n' "$domain" "$NFT_TABLE" "$safe" >> "$out"
        done < <(awk -F ',' '
            /^[[:space:]]*#/ || NF < 2 {next}
            {
                kind=toupper($1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", kind)
                value=$2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (kind == "DOMAIN" || kind == "DOMAIN-SUFFIX") print kind "\t" value
            }
        ' "$raw")
    done < <(read_enabled_split_app_ids)
    sort -u -o "$out" "$out"
}

split_dnsmasq_supported() {
    local iface
    [ "${SPLIT_DNSMASQ_NFTSET:-true}" = "true" ] || return 1
    command -v incus >/dev/null 2>&1 || return 1
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        incus_bridge_dnsmasq_supports_nftset "$iface" && return 0
    done < <(split_managed_dns_bridges)
    return 1
}

split_dnsmasq_status_label() {
    if [ "${SPLIT_DNSMASQ_NFTSET:-true}" != "true" ]; then
        printf '已关闭'
    elif split_dnsmasq_supported && [ -n "$(split_managed_dns_bridges)" ]; then
        printf '已启用（Incus dnsmasq nftset）'
    else
        printf '静态缓存模式（环境不支持 nftset）'
    fi
}

split_managed_dns_bridges() {
    local iface
    for iface in $BRIDGE_IFACES; do
        [ -n "$iface" ] || continue
        [ -d "$INCUS_NETWORKS_DIR/$iface" ] || continue
        incus network show "$iface" >/dev/null 2>&1 || continue
        printf '%s\n' "$iface"
    done
}

# Incus 可能使用 snap/自带的 dnsmasq，不能用宿主机 PATH 中的 dnsmasq 判断功能。
# 读取网桥 dnsmasq.pid 后检查实际运行二进制，取不到时按不支持处理以避免中断网桥 DNS。
incus_dnsmasq_pid_from_file() {
    local pid_file="$1" first pid
    [ -r "$pid_file" ] || return 1
    read -r first < "$pid_file" || return 1
    if [[ "$first" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$first"
        return 0
    fi
    pid="$(awk '$1 == "pid:" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$pid_file")"
    [ -n "$pid" ] || return 1
    printf '%s\n' "$pid"
}

incus_bridge_dnsmasq_binary() {
    local iface pid_file pid binary
    iface="$1"
    pid_file="$INCUS_NETWORKS_DIR/$iface/dnsmasq.pid"
    pid="$(incus_dnsmasq_pid_from_file "$pid_file")" || return 1
    binary="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
    [ -n "$binary" ] && [ -x "$binary" ] || return 1
    printf '%s\n' "$binary"
}

incus_bridge_dnsmasq_supports_nftset() {
    local iface="$1" binary
    binary="$(incus_bridge_dnsmasq_binary "$iface")" || return 1
    "$binary" --version 2>/dev/null | dnsmasq_version_supports_nftset
}

dnsmasq_version_supports_nftset() {
    # 必须是独立编译选项；grep -w 会把 no-nftset 中连字符后的 nftset 误判为支持。
    grep -Eq '(^|[[:space:]])nftset([[:space:]]|$)'
}

strip_split_dnsmasq_block() {
    local src="$1" dst="$2"
    awk -v begin="# BEGIN $APP_NAME nftset" -v end="# END $APP_NAME nftset" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        !skip {lines[++count]=$0}
        END {
            while (count > 0 && lines[count] == "") count--
            for (i=1; i<=count; i++) print lines[i]
        }
    ' "$src" > "$dst"
}

files_identical() {
    local left="$1" right="$2" left_hash right_hash
    [ -f "$left" ] && [ -f "$right" ] || return 1
    left_hash="$(sha256sum "$left" | awk '{print $1}')"
    right_hash="$(sha256sum "$right" | awk '{print $1}')"
    [ -n "$left_hash" ] && [ "$left_hash" = "$right_hash" ]
}

text_files_identical() {
    local left="$1" right="$2"
    [ -f "$left" ] && [ -f "$right" ] || return 1
    [ "$(cat "$left")" = "$(cat "$right")" ]
}

set_incus_network_raw_dnsmasq() {
    local iface="$1" file="$2" value
    value="$(cat "$file")"
    # 使用 Incus 当前推荐的 key=value 形式；配置加载失败不能再以旧语法重复提交同一坏配置。
    incus network set "$iface" "raw.dnsmasq=$value" >/dev/null
}

remove_split_dnsmasq_integration() {
    local iface current base config_file changed=0
    command -v incus >/dev/null 2>&1 || return 0
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        current="$(mktemp)"
        base="$(mktemp)"
        if ! incus network get "$iface" raw.dnsmasq > "$current" 2>/dev/null; then
            rm -f "$current" "$base"
            continue
        fi
        strip_split_dnsmasq_block "$current" "$base"
        config_file="$INCUS_NETWORKS_DIR/$iface/$APP_NAME-nftset.conf"
        if ! text_files_identical "$current" "$base"; then
            set_incus_network_raw_dnsmasq "$iface" "$base" || {
                rm -f "$current" "$base"
                warn "移除网桥 $iface 的 dnsmasq 动态分流配置失败。"
                return 1
            }
            changed=$((changed + 1))
        fi
        rm -f "$config_file" "$current" "$base"
    done < <(split_managed_dns_bridges)
    [ "$changed" -eq 0 ] || info "已移除 $changed 个 Incus 网桥的 dnsmasq 动态分流配置。"
}

apply_split_dnsmasq_nftsets() {
    local generated iface network_dir config_file old_config current base desired file_changed raw_changed changed=0 unsupported=0
    if [ "${SPLIT_DNSMASQ_NFTSET:-true}" != "true" ]; then
        remove_split_dnsmasq_integration
        return $?
    fi
    if ! split_dnsmasq_supported; then
        remove_split_dnsmasq_integration || return $?
        warn "Incus 网桥实际使用的 dnsmasq 不支持 nftset，已使用静态 DNS 缓存分流。"
        return 0
    fi
    generated="$(mktemp)"
    build_split_dnsmasq_file "$generated"
    mkdir -p "$SPLIT_DNSMASQ_DIR"
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        network_dir="$INCUS_NETWORKS_DIR/$iface"
        config_file="$network_dir/$APP_NAME-nftset.conf"
        old_config="$(mktemp)"
        current="$(mktemp)"
        base="$(mktemp)"
        desired="$(mktemp)"
        [ -f "$config_file" ] && cp "$config_file" "$old_config" || : > "$old_config"
        if ! incus network get "$iface" raw.dnsmasq > "$current" 2>/dev/null; then
            rm -f "$old_config" "$current" "$base" "$desired" "$generated"
            warn "读取网桥 $iface 的 raw.dnsmasq 配置失败。"
            return 1
        fi
        strip_split_dnsmasq_block "$current" "$base"
        if ! incus_bridge_dnsmasq_supports_nftset "$iface"; then
            if ! text_files_identical "$current" "$base" && ! set_incus_network_raw_dnsmasq "$iface" "$base"; then
                rm -f "$old_config" "$current" "$base" "$desired" "$generated"
                warn "网桥 $iface 使用的 dnsmasq 不支持 nftset，且旧动态配置清理失败。"
                return 1
            fi
            rm -f "$config_file" "$old_config" "$current" "$base" "$desired"
            unsupported=$((unsupported + 1))
            continue
        fi
        cp "$base" "$desired"
        if [ -s "$generated" ]; then
            [ ! -s "$desired" ] || printf '\n' >> "$desired"
            printf '# BEGIN %s nftset\n' "$APP_NAME" >> "$desired"
            printf 'conf-file=%s\n' "$config_file" >> "$desired"
            printf '# END %s nftset\n' "$APP_NAME" >> "$desired"
        fi
        file_changed="false"
        raw_changed="false"
        files_identical "$generated" "$old_config" || file_changed="true"
        text_files_identical "$current" "$desired" || raw_changed="true"
        if [ -s "$generated" ]; then
            install -m 0644 "$generated" "$config_file"
        else
            rm -f "$config_file"
        fi
        if [ "$file_changed" = "true" ] || [ "$raw_changed" = "true" ]; then
            if ! set_incus_network_raw_dnsmasq "$iface" "$desired"; then
                if [ -s "$old_config" ]; then
                    install -m 0644 "$old_config" "$config_file"
                else
                    rm -f "$config_file"
                fi
                if ! set_incus_network_raw_dnsmasq "$iface" "$current"; then
                    warn "网桥 $iface 的 raw.dnsmasq 自动回滚失败，请立即检查该网桥 DNS 服务。"
                fi
                rm -f "$old_config" "$current" "$base" "$desired" "$generated"
                warn "更新网桥 $iface 的 dnsmasq 动态分流配置失败。"
                return 1
            fi
            changed=$((changed + 1))
        fi
        rm -f "$old_config" "$current" "$base" "$desired"
    done < <(split_managed_dns_bridges)
    rm -f "$generated"
    [ "$changed" -eq 0 ] || info "已更新 $changed 个 Incus 网桥的 dnsmasq 动态域名分流。"
    [ "$unsupported" -eq 0 ] || warn "$unsupported 个 Incus 网桥实际使用的 dnsmasq 不支持 nftset，已使用静态 DNS 缓存分流。"
}

# 生成 nftables 数据面：
# 从 Incus/LXD 网桥进入的包，会按源 IP 查询 map，然后写入对应 fwmark。
# 控制器切换出口时只需要修改 map 中单个容器 IP 的 mark，不需要重启容器。
build_nft_file() {
    local tmp="$1" name ip token allowed current mark
    local elems4="" keys4="" elems6="" keys6="" managed4="" managed6="" comma
    local keys4_line="" keys6_line="" elems4_line="" elems6_line="" managed4_line="" managed6_line=""
    local split4="" split6="" split4_line="" split6_line=""
    local block_unmanaged6_line=""
    local split_sets="" split_rules="" force_split_rules="" conditional_force_rules="" container_split_rules="" bridge_expr app target policy_targets safe v4file v6file domains_file v4elems v6elems v4elements_line v6elements_line split_mark
    local container cip source category display app_category remote enabled
    bridge_expr="$(bridge_set_expr)"
    while IFS=$'\t' read -r name ip token allowed current; do
        if is_ipv4 "$ip"; then
            comma=""
            [ -n "$managed4" ] && comma=", "
            managed4="${managed4}${comma}${ip}"
            if [ "$current" = "-" ]; then
                comma=""
                [ -n "$split4" ] && comma=", "
                split4="${split4}${comma}${ip}"
                continue
            fi
            mark="$(exit_mark "$current")"
            [ -n "$mark" ] || continue
            comma=""
            [ -n "$elems4" ] && comma=", "
            elems4="${elems4}${comma}${ip} : ${mark}"
            comma=""
            [ -n "$keys4" ] && comma=", "
            keys4="${keys4}${comma}${ip}"
        else
            comma=""
            [ -n "$managed6" ] && comma=", "
            managed6="${managed6}${comma}${ip}"
            if [ "$current" = "-" ]; then
                comma=""
                [ -n "$split6" ] && comma=", "
                split6="${split6}${comma}${ip}"
                continue
            fi
            mark="$(exit_mark "$current")"
            [ -n "$mark" ] || continue
            comma=""
            [ -n "$elems6" ] && comma=", "
            elems6="${elems6}${comma}${ip} : ${mark}"
            comma=""
            [ -n "$keys6" ] && comma=", "
            keys6="${keys6}${comma}${ip}"
        fi
    done < <(read_container_rows)

    [ -n "$keys4" ] && keys4_line="    elements = { $keys4 }"
    [ -n "$keys6" ] && keys6_line="    elements = { $keys6 }"
    [ -n "$elems4" ] && elems4_line="    elements = { $elems4 }"
    [ -n "$elems6" ] && elems6_line="    elements = { $elems6 }"
    [ -n "$managed4" ] && managed4_line="    elements = { $managed4 }"
    [ -n "$managed6" ] && managed6_line="    elements = { $managed6 }"
    [ -n "$split4" ] && split4_line="    elements = { $split4 }"
    [ -n "$split6" ] && split6_line="    elements = { $split6 }"
    if [ "${ENABLE_SPLIT_RULES:-true}" = "true" ]; then
        while IFS= read -r app; do
            split_nft_name_into safe "$app"
            [ -n "$safe" ] || continue
            v4file="$(split_resolved_v4_file "$app")"
            v6file="$(split_resolved_v6_file "$app")"
            domains_file="$SPLIT_RESOLVED_DIR/$app.domains"
            v4elems="$(nft_elements_from_file "$v4file")"
            v6elems="$(nft_elements_from_file "$v6file")"
            if [ -n "$v4elems" ] || [ -s "$domains_file" ]; then
                v4elements_line=""
                [ -n "$v4elems" ] && v4elements_line="    elements = { $v4elems }"
                split_sets="$split_sets
  set split4_$safe {
    type ipv4_addr
    flags interval
$v4elements_line
  }
"
            fi
            if [ -n "$v6elems" ] || [ -s "$domains_file" ]; then
                v6elements_line=""
                [ -n "$v6elems" ] && v6elements_line="    elements = { $v6elems }"
                split_sets="$split_sets
  set split6_$safe {
    type ipv6_addr
    flags interval
$v6elements_line
  }
"
            fi
        done < <(read_enabled_split_app_ids)

        while IFS=$'\t' read -r app target; do
            split_app_is_forced "$app" || continue
            target="$(split_target_list_default "$target")"
            [ -n "$target" ] || continue
            split_nft_name_into safe "$app"
            [ -n "$safe" ] || continue
            if [ "$target" != "-" ]; then
                split_mark="$(exit_mark "$target")"
                [ -n "$split_mark" ] || continue
            else
                split_mark=""
            fi
            v4file="$(split_resolved_v4_file "$app")"
            v6file="$(split_resolved_v6_file "$app")"
            domains_file="$SPLIT_RESOLVED_DIR/$app.domains"
            if [ -s "$v4file" ] || [ -s "$domains_file" ]; then
                if [ "$target" = "-" ]; then
                    force_split_rules="$force_split_rules    iifname { $bridge_expr } ip saddr @managed4_keys ip daddr @split4_$safe return
"
                else
                    force_split_rules="$force_split_rules    iifname { $bridge_expr } ip saddr @managed4_keys ip daddr @split4_$safe meta mark set $split_mark return
"
                fi
            fi
            if [ -s "$v6file" ] || [ -s "$domains_file" ]; then
                if [ "$target" = "-" ]; then
                    force_split_rules="$force_split_rules    iifname { $bridge_expr } ip6 saddr @managed6_keys ip6 daddr @split6_$safe return
"
                else
                    force_split_rules="$force_split_rules    iifname { $bridge_expr } ip6 saddr @managed6_keys ip6 daddr @split6_$safe meta mark set $split_mark return
"
                fi
            fi
        done < <(read_split_policies)

        # 条件强制只对当前使用指定来源出口的容器生效。单应用规则
        # 优先于同来源出口的分类规则；现有全局强制仍位于最前面。
        while IFS=$'\t' read -r app source target; do
            split_app_is_forced "$app" && continue
            target="$(split_target_list_default "$target")"
            split_nft_name_into safe "$app"
            [ -n "$safe" ] || continue
            if [ "$target" != "-" ]; then
                split_mark="$(exit_mark "$target")"
                [ -n "$split_mark" ] || continue
            else
                split_mark=""
            fi
            v4file="$(split_resolved_v4_file "$app")"
            v6file="$(split_resolved_v6_file "$app")"
            domains_file="$SPLIT_RESOLVED_DIR/$app.domains"
            while IFS=$'\t' read -r container cip _token _allowed current; do
                [ "$current" = "$source" ] || continue
                if is_ipv4 "$cip" && { [ -s "$v4file" ] || [ -s "$domains_file" ]; }; then
                    if [ "$target" = "-" ]; then
                        conditional_force_rules="$conditional_force_rules    iifname { $bridge_expr } ip saddr $cip ip daddr @split4_$safe return
"
                    else
                        conditional_force_rules="$conditional_force_rules    iifname { $bridge_expr } ip saddr $cip ip daddr @split4_$safe meta mark set $split_mark return
"
                    fi
                elif is_ipv6 "$cip" && { [ -s "$v6file" ] || [ -s "$domains_file" ]; }; then
                    if [ "$target" = "-" ]; then
                        conditional_force_rules="$conditional_force_rules    iifname { $bridge_expr } ip6 saddr $cip ip6 daddr @split6_$safe return
"
                    else
                        conditional_force_rules="$conditional_force_rules    iifname { $bridge_expr } ip6 saddr $cip ip6 daddr @split6_$safe meta mark set $split_mark return
"
                    fi
                fi
            done < <(read_container_rows)
        done < <(read_force_on_exit_policies)

        while IFS=$'\t' read -r category source target; do
            target="$(split_target_list_default "$target")"
            while IFS=$'\t' read -r app display app_category remote enabled; do
                [ "$app_category" = "$category" ] || continue
                split_app_is_forced "$app" && continue
                force_on_exit_app_exists "$app" "$source" && continue
                split_nft_name_into safe "$app"
                [ -n "$safe" ] || continue
                if [ "$target" != "-" ]; then
                    split_mark="$(exit_mark "$target")"
                    [ -n "$split_mark" ] || continue
                else
                    split_mark=""
                fi
                v4file="$(split_resolved_v4_file "$app")"
                v6file="$(split_resolved_v6_file "$app")"
                domains_file="$SPLIT_RESOLVED_DIR/$app.domains"
                while IFS=$'\t' read -r container cip _token _allowed current; do
                    [ "$current" = "$source" ] || continue
                    if is_ipv4 "$cip" && { [ -s "$v4file" ] || [ -s "$domains_file" ]; }; then
                        if [ "$target" = "-" ]; then
                            conditional_force_rules="$conditional_force_rules    iifname { $bridge_expr } ip saddr $cip ip daddr @split4_$safe return
"
                        else
                            conditional_force_rules="$conditional_force_rules    iifname { $bridge_expr } ip saddr $cip ip daddr @split4_$safe meta mark set $split_mark return
"
                        fi
                    elif is_ipv6 "$cip" && { [ -s "$v6file" ] || [ -s "$domains_file" ]; }; then
                        if [ "$target" = "-" ]; then
                            conditional_force_rules="$conditional_force_rules    iifname { $bridge_expr } ip6 saddr $cip ip6 daddr @split6_$safe return
"
                        else
                            conditional_force_rules="$conditional_force_rules    iifname { $bridge_expr } ip6 saddr $cip ip6 daddr @split6_$safe meta mark set $split_mark return
"
                        fi
                    fi
                done < <(read_container_rows)
            done < <(read_split_apps)
        done < <(read_force_category_on_exit_policies)

        while IFS=$'\t' read -r container app target; do
            policy_targets="$(split_policy_targets "$app")"
            [ -n "$policy_targets" ] || continue
            split_target_list_contains "$policy_targets" "$target" || continue
            container_allows_exit "$container" "$target" || continue
            split_app_is_forced "$app" && continue
            split_nft_name_into safe "$app"
            [ -n "$safe" ] || continue
            cip="$(container_ip "$container")"
            [ -n "$cip" ] || continue
            if [ "$target" != "-" ]; then
                split_mark="$(exit_mark "$target")"
                [ -n "$split_mark" ] || continue
            else
                split_mark=""
            fi
            v4file="$(split_resolved_v4_file "$app")"
            v6file="$(split_resolved_v6_file "$app")"
            domains_file="$SPLIT_RESOLVED_DIR/$app.domains"
            if is_ipv4 "$cip" && { [ -s "$v4file" ] || [ -s "$domains_file" ]; }; then
                if [ "$target" = "-" ]; then
                    container_split_rules="$container_split_rules    iifname { $bridge_expr } ip saddr @split4_keys ip saddr $cip ip daddr @split4_$safe return
"
                else
                    container_split_rules="$container_split_rules    iifname { $bridge_expr } ip saddr @split4_keys ip saddr $cip ip daddr @split4_$safe meta mark set $split_mark return
"
                fi
            elif is_ipv6 "$cip" && { [ -s "$v6file" ] || [ -s "$domains_file" ]; }; then
                if [ "$target" = "-" ]; then
                    container_split_rules="$container_split_rules    iifname { $bridge_expr } ip6 saddr @split6_keys ip6 saddr $cip ip6 daddr @split6_$safe return
"
                else
                    container_split_rules="$container_split_rules    iifname { $bridge_expr } ip6 saddr @split6_keys ip6 saddr $cip ip6 daddr @split6_$safe meta mark set $split_mark return
"
                fi
            fi
        done < <(read_container_split_policies)

        while IFS=$'\t' read -r app target; do
            target="$(split_target_list_default "$target")"
            [ -n "$target" ] || continue
            split_nft_name_into safe "$app"
            [ -n "$safe" ] || continue
            split_app_is_forced "$app" && continue
            if [ "$target" != "-" ]; then
                split_mark="$(exit_mark "$target")"
                [ -n "$split_mark" ] || continue
            else
                split_mark=""
            fi
            v4file="$(split_resolved_v4_file "$app")"
            v6file="$(split_resolved_v6_file "$app")"
            domains_file="$SPLIT_RESOLVED_DIR/$app.domains"
            if [ -s "$v4file" ] || [ -s "$domains_file" ]; then
                if [ "$target" = "-" ]; then
                    split_rules="$split_rules    iifname { $bridge_expr } ip saddr @split4_keys ip daddr @split4_$safe return
"
                else
                    split_rules="$split_rules    iifname { $bridge_expr } ip saddr @split4_keys ip daddr @split4_$safe meta mark set $split_mark return
"
                fi
            fi
            if [ -s "$v6file" ] || [ -s "$domains_file" ]; then
                if [ "$target" = "-" ]; then
                    split_rules="$split_rules    iifname { $bridge_expr } ip6 saddr @split6_keys ip6 daddr @split6_$safe return
"
                else
                    split_rules="$split_rules    iifname { $bridge_expr } ip6 saddr @split6_keys ip6 daddr @split6_$safe meta mark set $split_mark return
"
                fi
            fi
        done < <(read_split_policies)
    fi
    if [ "${BLOCK_UNMANAGED_IPV6:-true}" = "true" ]; then
        block_unmanaged6_line="    iifname { $bridge_expr } ip6 saddr != @managed6_keys drop"
    fi

    cat > "$tmp" <<EOF
table inet $NFT_TABLE {
  set managed4_keys {
    type ipv4_addr
$managed4_line
  }

  set managed6_keys {
    type ipv6_addr
$managed6_line
  }

  set split4_keys {
    type ipv4_addr
$split4_line
  }

  set split6_keys {
    type ipv6_addr
$split6_line
  }

  set egress4_keys {
    type ipv4_addr
$keys4_line
  }

  set egress6_keys {
    type ipv6_addr
$keys6_line
  }

  map egress4 {
    type ipv4_addr : mark
$elems4_line
  }

  map egress6 {
    type ipv6_addr : mark
$elems6_line
  }
$split_sets

  chain prerouting {
    # 晚于常见的 mangle(-150) 链执行，避免宿主机已有回程/默认出口规则覆盖容器自选出口标记。
    type filter hook prerouting priority -140; policy accept;
    iifname { $bridge_expr } ct status dnat return
    iifname { $bridge_expr } ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 169.254.0.0/16 } return
    iifname { $bridge_expr } ip6 daddr { ::1/128, fc00::/7, fe80::/10, ff00::/8 } return
$force_split_rules$conditional_force_rules$container_split_rules$split_rules    iifname { $bridge_expr } ip saddr @egress4_keys meta mark set ip saddr map @egress4
    iifname { $bridge_expr } ip6 saddr @egress6_keys meta mark set ip6 saddr map @egress6
$block_unmanaged6_line
  }
}
EOF
}

apply_nftables() {
    local preserve_pending="${1:-false}" tmp batch
    tmp="$(mktemp)"
    batch="$(mktemp)"
    build_nft_file "$tmp"
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        printf 'delete table inet %s\n' "$NFT_TABLE" > "$batch"
    fi
    cat "$tmp" >> "$batch"
    # delete + create 位于同一个 nft transaction；校验或提交失败时旧表保持不变。
    if ! nft -c -f "$batch"; then
        rm -f "$tmp" "$batch"
        return 1
    fi
    if ! nft -f "$batch"; then
        rm -f "$tmp" "$batch"
        return 1
    fi
    mkdir -p "$RUN_DIR"
    cp "$tmp" "$NFT_STATE_FILE"
    if ! apply_split_dnsmasq_nftsets; then
        rm -f "$tmp" "$batch"
        return 1
    fi
    [ "$preserve_pending" = "true" ] || rm -f "$PENDING_NFT_FILE"
    rm -f "$tmp" "$batch"
}

apply_guard_table() {
    printf '%s_apply_guard\n' "$NFT_TABLE"
}

build_apply_guard_file() {
    local tmp="$1" guard_table bridge_expr
    guard_table="$(apply_guard_table)"
    bridge_expr="$(bridge_set_expr)"
    cat > "$tmp" <<EOF
table inet $guard_table {
  chain prerouting {
    type filter hook prerouting priority -151; policy accept;
    iifname { $bridge_expr } drop
  }
}
EOF
}

enable_apply_guard() {
    local guard_table tmp batch
    guard_table="$(apply_guard_table)"
    tmp="$(mktemp)"
    batch="$(mktemp)"
    build_apply_guard_file "$tmp"
    if nft list table inet "$guard_table" >/dev/null 2>&1; then
        printf 'delete table inet %s\n' "$guard_table" > "$batch"
    fi
    cat "$tmp" >> "$batch"
    if ! nft -c -f "$batch" || ! nft -f "$batch"; then
        rm -f "$tmp" "$batch"
        return 1
    fi
    rm -f "$tmp" "$batch"
}

disable_apply_guard() {
    local guard_table
    guard_table="$(apply_guard_table)"
    nft delete table inet "$guard_table" 2>/dev/null || ! nft list table inet "$guard_table" >/dev/null 2>&1
}

do_apply() {
    need_root
    load_config
    need_cmd ip
    need_cmd nft
    need_cmd awk
    need_cmd mktemp
    state_lock_acquire
    apply_lock_acquire
    validate_runtime_config
    validate_exits
    validate_exit_limits
    validate_containers
    validate_split_policies
    mark_nft_pending
    if ! apply_exit_limits; then
        warn "出口限速应用失败，已中止全量更新。"
        apply_lock_release
        state_lock_release
        return 1
    fi
    enable_apply_guard || die "无法启用全量应用期间的流量保护表，已中止更新。"
    if ! (
        apply_routes_and_rules
        apply_nftables true
    ); then
        warn "全量应用失败；临时流量保护仍保持启用，修复错误后重新执行 apply 即可恢复。"
        apply_lock_release
        state_lock_release
        return 1
    fi
    if ! disable_apply_guard; then
        warn "新规则已提交，但临时流量保护表移除失败；请重新执行 apply。"
        apply_lock_release
        state_lock_release
        return 1
    fi
    rm -f "$PENDING_NFT_FILE"
    apply_lock_release
    state_lock_release
    info "已应用出口规则：nft 表 '$NFT_TABLE'，策略路由优先级 $RULE_PRIORITY。"
}

do_apply_nftables() {
    need_root
    load_config
    need_cmd nft
    need_cmd awk
    need_cmd mktemp
    if nft list table inet "$(apply_guard_table)" >/dev/null 2>&1; then
        warn "检测到上一次全量应用未完成，自动改为执行完整恢复。"
        do_apply
        return $?
    fi
    state_lock_acquire
    apply_lock_acquire
    validate_runtime_config
    validate_exits
    validate_containers
    validate_split_policies
    apply_nftables
    apply_lock_release
    state_lock_release
}

do_apply_limits() {
    need_root
    load_config
    need_cmd ip
    need_cmd tc
    if command -v nft >/dev/null 2>&1 && nft list table inet "$(apply_guard_table)" >/dev/null 2>&1; then
        warn "检测到上一次全量应用未完成，先执行完整恢复。"
        do_apply
        return $?
    fi
    state_lock_acquire
    apply_lock_acquire
    validate_exits
    validate_exit_limits
    apply_exit_limits
    apply_lock_release
    state_lock_release
}

do_apply_exit_route() {
    need_root
    load_config
    need_cmd ip
    local target="${1:-}" row name mark table route4 route6 display
    [ -n "$target" ] || die "用法: $0 apply-exit-route 出口ID"
    state_lock_acquire
    row="$(read_exit_rows | awk -F '\t' -v n="$target" '$1 == n {print; exit}')"
    [ -n "$row" ] || { state_lock_release; return 0; }
    IFS=$'\t' read -r name mark table route4 route6 display <<< "$row"
    apply_lock_acquire
    apply_default_route 4 "$table" "$route4"
    apply_default_route 6 "$table" "$route6"
    apply_lock_release
    state_lock_release
}

gen_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
        printf '\n'
    fi
}

add_exit() {
    need_root
    load_config
    write_default_config
    state_lock_acquire
    local name="${1:-}" mark="${2:-}" table="${3:-}" route4="${4:-none}" route6="${5:-none}" display="${6:-}"
    [ -n "$name" ] && [ -n "$mark" ] && [ -n "$table" ] || die "用法: $0 add-exit 出口名 fwmark 路由表ID [IPv4路由] [IPv6路由]"
    valid_name "$name" || die "出口名无效: $name"
    valid_mark "$mark" || die "fwmark 无效: $mark"
    valid_table_id "$table" || die "路由表 ID 无效: $table"
    exit_exists "$name" && die "出口已存在: $name"
    display="$(normalize_display_name "${display:-$name}")"
    if [ -n "$(exit_name_by_display "$display")" ]; then
        die "出口显示名已存在: $display"
    fi
    mark_nft_pending
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$mark" "$table" "$route4" "$route6" "$display" >> "$EXITS_FILE"
    chmod 600 "$EXITS_FILE"
    state_lock_release
    info "已添加出口 '$display'。真实出口设备/路由表准备好后，请运行: $0 apply"
}

next_exit_index() {
    local idx mark table existing_mark existing_table
    local -A used_marks=() used_tables=()
    while IFS=$'\t' read -r _name existing_mark existing_table _route4 _route6 _display; do
        if [[ "$existing_mark" == 0x* ]]; then
            used_marks[$((existing_mark))]=1
        else
            used_marks[$((10#$existing_mark))]=1
        fi
        used_tables[$((10#$existing_table))]=1
    done < <(read_exit_rows)
    for ((idx = 1; idx <= 65535; idx++)); do
        mark="$(mark_for_index "$idx")"
        table=$((100 + idx))
        case "$table" in 253|254|255) continue ;; esac
        if [ -z "${used_marks[$((mark))]:-}" ] && [ -z "${used_tables[$table]:-}" ]; then
            printf '%s\n' "$idx"
            return 0
        fi
    done
    die "没有可用的出口 fwmark/路由表编号。"
}

mark_for_index() {
    printf '0x51%02x\n' "$1"
}

table_for_index() {
    printf '%s\n' "$((100 + $1))"
}

tun_for_exit() {
    local name="$1" clean digest
    clean="${name//[!A-Za-z0-9]/-}"
    clean="${clean:0:6}"
    [ -n "$clean" ] || clean="exit"
    digest="$(printf '%s' "$name" | sha256sum)"
    digest="${digest%% *}"
    # Linux 接口名最多 15 个字符；哈希后缀避免相同前缀的多个出口冲突。
    printf 'csh-%s-%s\n' "$clean" "${digest:0:4}"
}

wg_for_exit() {
    local name="$1" clean digest
    clean="${name//[!A-Za-z0-9]/-}"
    clean="${clean:0:5}"
    [ -n "$clean" ] || clean="exit"
    digest="$(printf '%s' "$name" | sha256sum)"
    digest="${digest%% *}"
    printf 'cwg-%s-%s\n' "$clean" "${digest:0:4}"
}

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

normalize_display_name() {
    local s="${1:-}"
    s="${s//$'\t'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    s="$(trim_space "$s")"
    printf '%s\n' "${s:-unnamed}"
}

safe_exit_id() {
    local prefix="$1" display="$2" server="${3:-}" port="${4:-}"
    python3 - "$prefix" "$display" "$server" "$port" <<'PY'
import hashlib
import re
import sys

prefix, display, server, port = sys.argv[1:5]
display = display.strip() or prefix
candidate = re.sub(r"[^A-Za-z0-9_.-]+", "-", display).strip(".-_")
safe_display = re.fullmatch(r"[A-Za-z0-9_.-]+", display or "") is not None
if safe_display and display not in {"-", "host", "direct", "entry", "local", "main"}:
    print(display)
    raise SystemExit
base = candidate or prefix
if base != prefix and not base.startswith(prefix + "-"):
    base = "%s-%s" % (prefix, base)
digest = hashlib.sha1(("%s|%s|%s|%s" % (prefix, display, server, port)).encode()).hexdigest()[:6]
name = ("%s-%s" % (base, digest)).strip(".-_")
name = re.sub(r"-+", "-", name)
print(name[:48].strip(".-_") or ("%s-%s" % (prefix, digest)))
PY
}

parse_ss_link() {
    local link="$1"
    python3 - "$link" <<'PY'
import base64
import sys
from urllib.parse import unquote, urlsplit

link = sys.argv[1].strip()
if not link.startswith("ss://"):
    raise SystemExit("不是有效的 ss:// 链接")

fragment = ""
if "#" in link:
    link, fragment = link.split("#", 1)
    fragment = unquote(fragment)

body = link[5:]
method = password = host = port = ""

def b64decode_text(value):
    value = value.replace("-", "+").replace("_", "/")
    value += "=" * (-len(value) % 4)
    return base64.b64decode(value).decode()

if "@" in body:
    userinfo_b64, server = body.rsplit("@", 1)
    userinfo = b64decode_text(userinfo_b64)
    if ":" not in userinfo:
        raise SystemExit("SS 用户信息缺少 method:password")
    method, password = userinfo.split(":", 1)
    if server.startswith("["):
        host, rest = server[1:].split("]", 1)
        port = rest.lstrip(":")
    else:
        host, port = server.rsplit(":", 1)
else:
    decoded = b64decode_text(body)
    if "@" not in decoded:
        raise SystemExit("SS 链接缺少服务器信息")
    userinfo, server = decoded.rsplit("@", 1)
    method, password = userinfo.split(":", 1)
    host, port = server.rsplit(":", 1)

display = fragment or host.replace(".", "-")
print("\t".join([display, method, password, host, port]))
PY
}

parse_socks_link() {
    local link="$1"
    python3 - "$link" <<'PY'
import sys
from urllib.parse import unquote, urlsplit

link = sys.argv[1].strip()
parts = urlsplit(link)
if parts.scheme.lower() not in ("socks", "socks5", "sk5"):
    raise SystemExit("不是有效的 socks5:// 链接")
if not parts.hostname or not parts.port:
    raise SystemExit("SOCKS5 链接缺少地址或端口")

name = unquote(parts.fragment) if parts.fragment else parts.hostname.replace(".", "-")
username = unquote(parts.username or "")
password = unquote(parts.password or "")
print("\t".join([name, parts.hostname, str(parts.port), username, password]))
PY
}

parse_vless_tcp_link() {
    local link="$1"
    python3 - "$link" <<'PY'
import sys
import uuid
from urllib.parse import parse_qs, unquote, urlsplit

link = sys.argv[1].strip()
parts = urlsplit(link)
if parts.scheme.lower() != "vless":
    raise SystemExit("不是有效的 vless:// 链接")
if not parts.hostname or not parts.port:
    raise SystemExit("VLESS 链接缺少地址或端口")
user_id = unquote(parts.username or "")
try:
    user_id = str(uuid.UUID(user_id))
except (ValueError, AttributeError):
    raise SystemExit("VLESS 用户 ID 不是有效 UUID")
query = parse_qs(parts.query, keep_blank_values=True)
transport = (query.get("type") or ["tcp"])[0].lower()
encryption = (query.get("encryption") or ["none"])[0].lower()
security = (query.get("security") or ["none"])[0].lower()
if transport not in ("", "tcp"):
    raise SystemExit("目前只支持 VLESS+TCP，不支持 type=%s" % transport)
if encryption not in ("", "none"):
    raise SystemExit("VLESS+TCP 仅支持 encryption=none")
if security not in ("", "none"):
    raise SystemExit("目前只支持不带 TLS/Reality 的 VLESS+TCP")
name = unquote(parts.fragment) if parts.fragment else parts.hostname.replace(".", "-")
print("\t".join([name, parts.hostname, str(parts.port), user_id]))
PY
}

singbox_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        armv7l) printf 'armv7\n' ;;
        *) return 1 ;;
    esac
}

install_singbox_core() {
    need_root
    need_cmd curl
    need_cmd tar
    need_cmd python3
    local arch version tmp file url bin
    if [ -x "$SINGBOX_BIN" ]; then
        rm -f "$LEGACY_SINGBOX_BIN" 2>/dev/null || true
        return 0
    fi
    arch=$(singbox_arch) || die "暂不支持当前架构: $(uname -m)"
    version=$(curl -fsSL --connect-timeout 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1)
    [ -n "$version" ] || die "无法获取 sing-box 最新版本。"
    tmp=$(mktemp -d)
    file="sing-box-${version}-linux-${arch}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${file}"
    info "下载 sing-box v${version}..."
    curl -fL --connect-timeout 20 --retry 2 -o "$tmp/$file" "$url"
    tar -xzf "$tmp/$file" -C "$tmp"
    bin=$(find "$tmp" -type f -name sing-box | head -1)
    [ -n "$bin" ] || { rm -rf "$tmp"; die "压缩包内未找到 sing-box。"; }
    mkdir -p "$LIB_DIR"
    install -m 0755 "$bin" "$SINGBOX_BIN"
    rm -f "$LEGACY_SINGBOX_BIN" 2>/dev/null || true
    rm -rf "$tmp"
    info "脚本专用 sing-box 已安装: $SINGBOX_BIN"
}

write_resolved_guard() {
    local resolved_guard="$LIB_DIR/clear-resolved-link"
    mkdir -p "$LIB_DIR"
    cat > "$resolved_guard" <<'EOF'
#!/usr/bin/env sh
set -u

iface="${1:-}"
[ -n "$iface" ] || exit 0
command -v resolvectl >/dev/null 2>&1 || exit 0

# sing-box 的 TUN 可能会把自身 DNS 注册到 systemd-resolved。
# 这里重复清理几次，避免 Incus dnsmasq/容器 DNS 被出口 TUN 接管。
i=0
while [ "$i" -lt 5 ]; do
    resolvectl default-route "$iface" false >/dev/null 2>&1 || true
    resolvectl dns "$iface" "" >/dev/null 2>&1 || true
    resolvectl domain "$iface" "" >/dev/null 2>&1 || true
    resolvectl revert "$iface" >/dev/null 2>&1 || true
    resolvectl default-route "$iface" false >/dev/null 2>&1 || true
    resolvectl dns "$iface" "" >/dev/null 2>&1 || true
    resolvectl domain "$iface" "" >/dev/null 2>&1 || true
    i=$((i + 1))
    sleep 1
done
EOF
    chmod 755 "$resolved_guard"
}

proxy_split_rules() {
    [ "${ENABLE_SPLIT_RULES:-true}" = "true" ] || return 0
    cat <<'EOF'
      { "domain_suffix": ["github.com", "githubusercontent.com", "githubassets.com", "github.io"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["docker.io", "docker.com", "dockerhub.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["debian.org", "ubuntu.com", "canonical.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["centos.org", "fedoraproject.org", "redhat.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["alpinelinux.org", "archlinux.org"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["npmjs.org", "npmjs.com", "yarnpkg.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["pypi.org", "pythonhosted.org"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["golang.org", "go.dev", "proxy.golang.org"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["maven.org", "mvnrepository.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["rubygems.org", "crates.io", "packagist.org"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["cloudflare.com", "fastly.net", "akamai.net"], "action": "route", "outbound": "direct" },
EOF
}

proxy_outbound_json() {
    local protocol="$1" server="$2" port="$3" method="$4" password="$5" username="$6"
    local server_esc method_esc pass_esc user_esc auth_json
    server_esc=$(json_escape "$server")
    pass_esc=$(json_escape "$password")
    case "$protocol" in
        shadowsocks)
            method_esc=$(json_escape "$method")
            cat <<EOF
    {
      "type": "shadowsocks",
      "tag": "proxy",
      "server": "$server_esc",
      "server_port": $port,
      "method": "$method_esc",
      "password": "$pass_esc",
      "routing_mark": 666
    }
EOF
            ;;
        socks)
            auth_json=""
            if [ -n "$username" ] || [ -n "$password" ]; then
                user_esc=$(json_escape "$username")
                auth_json=$(cat <<EOF
,
      "username": "$user_esc",
      "password": "$pass_esc"
EOF
)
            fi
            cat <<EOF
    {
      "type": "socks",
      "tag": "proxy",
      "server": "$server_esc",
      "server_port": $port,
      "version": "5",
      "routing_mark": 666$auth_json
    }
EOF
            ;;
        vless)
            method_esc=$(json_escape "$method")
            cat <<EOF
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$server_esc",
      "server_port": $port,
      "uuid": "$method_esc",
      "routing_mark": 666
    }
EOF
            ;;
        *) die "不支持的 sing-box 出口协议: $protocol" ;;
    esac
}

write_proxy_exit_files() {
    local protocol="$1" name="$2" server="$3" port="$4" table="$5" tun="$6" method="${7:-}" password="${8:-}" username="${9:-}"
    local conf_dir conf service resolved_guard server_esc outbound_json split_rules domain_route proxy_direct_rule v4_octet v6_suffix
    conf_dir="$EXIT_DIR/$name"
    conf="$conf_dir/config.json"
    service="$SYSTEMD_DIR/${EXIT_SERVICE_PREFIX}-${name}.service"
    resolved_guard="$LIB_DIR/clear-resolved-link"
    server_esc=$(json_escape "$server")
    outbound_json=$(proxy_outbound_json "$protocol" "$server" "$port" "$method" "$password" "$username")
    split_rules=$(proxy_split_rules)
    domain_route=""
    proxy_direct_rule=""
    if is_ipv4 "$server"; then
        proxy_direct_rule="      { \"ip_cidr\": [\"$server/32\"], \"action\": \"route\", \"outbound\": \"direct\" },"
    elif is_ipv6 "$server"; then
        proxy_direct_rule="      { \"ip_cidr\": [\"$server/128\"], \"action\": \"route\", \"outbound\": \"direct\" },"
    else
        domain_route="      { \"domain\": [\"$server_esc\"], \"action\": \"route\", \"outbound\": \"direct\" },"
    fi
    v4_octet=$((table % 200 + 20))
    v6_suffix=$(printf '%x' "$table")
    mkdir -p "$conf_dir"
    write_resolved_guard
    cat > "$conf" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "type": "udp", "tag": "cf_v4", "server": "1.1.1.1", "server_port": 53, "detour": "direct" },
      { "type": "udp", "tag": "google_v4", "server": "8.8.8.8", "server_port": 53, "detour": "direct" },
      { "type": "udp", "tag": "cf_v6", "server": "2606:4700:4700::1111", "server_port": 53, "detour": "direct" },
      { "type": "udp", "tag": "google_v6", "server": "2001:4860:4860::8888", "server_port": 53, "detour": "direct" }
    ],
    "rules": [],
    "final": "cf_v4",
    "strategy": "prefer_ipv4",
    "cache_capacity": 4096
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "$tun",
      "address": ["172.31.${v4_octet}.1/30", "fd7a:636c:7368:${v6_suffix}::1/126"],
      "mtu": 1400,
      "stack": "mixed",
      "auto_route": false,
      "strict_route": false,
      "endpoint_independent_nat": true
    }
  ],
  "outbounds": [
$outbound_json,
    {
      "type": "direct",
      "tag": "direct",
      "routing_mark": 666
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": { "server": "cf_v4", "strategy": "prefer_ipv4" },
    "rules": [
      { "inbound": ["tun-in"], "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
$proxy_direct_rule
$domain_route
$split_rules
      {
        "ip_cidr": [
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "::1/128",
          "fc00::/7",
          "fe80::/10",
          "ff00::/8"
        ],
        "action": "route",
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
EOF
    chmod 600 "$conf"
    cat > "$service" <<EOF
[Unit]
Description=cloudshlii egress exit $name
After=network-online.target
Wants=network-online.target
Before=$APP_NAME.service $APP_NAME-autosync.service

[Service]
Type=simple
ExecStartPre=$SINGBOX_BIN check -c $conf
ExecStart=$SINGBOX_BIN run -c $conf
ExecStartPost=$resolved_guard $tun
ExecStartPost=/bin/sh -c 'for i in \$(seq 1 20); do ip link show "\$1" >/dev/null 2>&1 && break; sleep 1; done; "\$2" apply-exit-route "\$3" >/dev/null 2>&1 || true' sh $tun $INSTALL_BIN $name
SyslogIdentifier=cloudshlii-sing-box-$name
Restart=always
RestartSec=3
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

write_ss_exit_files() {
    local name="$1" method="$2" password="$3" server="$4" port="$5" table="$6" tun="$7"
    write_proxy_exit_files "shadowsocks" "$name" "$server" "$port" "$table" "$tun" "$method" "$password" ""
}

write_sk5_exit_files() {
    local name="$1" server="$2" port="$3" username="$4" password="$5" table="$6" tun="$7"
    write_proxy_exit_files "socks" "$name" "$server" "$port" "$table" "$tun" "" "$password" "$username"
}

write_vless_exit_files() {
    local name="$1" server="$2" port="$3" uuid="$4" table="$5" tun="$6"
    write_proxy_exit_files "vless" "$name" "$server" "$port" "$table" "$tun" "$uuid" "" ""
}

wait_for_iface() {
    local iface="$1" i
    for i in $(seq 1 20); do
        ip link show "$iface" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# 新出口启动前必须先释放配置锁。出口服务的 ExecStartPost 会重新调用本脚本
# 应用路由；如果父进程仍持锁，systemd 会一直等待并最终启动超时。
rollback_proxy_exit_add() {
    local name="$1" removed="false"
    state_lock_acquire
    if exit_exists "$name"; then
        remove_exit_row "$name"
        mark_nft_pending
        removed="true"
    fi
    state_lock_release

    stop_and_remove_exit_service "$name"
    rm -rf -- "${EXIT_DIR:?}/$name"
    if [ "$removed" = "true" ]; then
        (do_apply) >/dev/null 2>&1 || warn "出口 $name 的运行时规则回滚不完整，请执行: $INSTALL_BIN apply"
    fi
}

start_proxy_exit() {
    local kind="$1" name="$2" display="$3" mark="$4" table="$5" tun="$6" service
    service="${EXIT_SERVICE_PREFIX}-${name}"

    # 先登记出口，让服务重启钩子能读取到完整路由信息；随后立即释放外层锁。
    mark_nft_pending
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$mark" "$table" "dev:$tun" "dev:$tun" "$display" >> "$EXITS_FILE"
    chmod 600 "$EXITS_FILE"
    state_lock_release

    if ! systemctl daemon-reload || ! systemctl enable "$service" >/dev/null || ! systemctl start "$service"; then
        rollback_proxy_exit_add "$name"
        die "$kind 出口 '$display' 的服务启动失败，已回滚本次添加。请查看: journalctl -u $service.service -n 80 --no-pager"
    fi
    if ! wait_for_iface "$tun"; then
        rollback_proxy_exit_add "$name"
        die "$kind 出口 '$display' 的 TUN 设备 $tun 未启动，已回滚本次添加；请检查节点信息和服务日志。"
    fi
    if ! (do_apply); then
        rollback_proxy_exit_add "$name"
        die "$kind 出口 '$display' 已启动，但宿主机路由应用失败，已回滚本次添加。"
    fi
    info "$kind 出口 '$display' 已添加并启动。需要接管或刷新容器时，请在主菜单选择 7 或 8。"
}

add_ss_exit_values() {
    need_root
    load_config
    write_default_config
    need_cmd python3
    need_cmd systemctl
    need_cmd ip
    state_lock_acquire
    local display="$1" method="$2" password="$3" server="$4" port="$5" name="${6:-}" idx mark table tun
    display="$(normalize_display_name "$display")"
    server="$(normalize_proxy_host "$server")"
    valid_proxy_host "$server" || die "SS 地址无效，请填写纯 IP 或域名/DDNS，不要带协议、端口或路径: $server"
    [ -n "$method" ] || die "SS 加密方式不能为空。"
    [ -n "$password" ] || die "SS 密码不能为空。"
    validate_port "$port" || die "SS 端口无效: $port"
    name="${name:-$(safe_exit_id "ss" "$display" "$server" "$port")}"
    valid_name "$name" || die "出口内部名称无效: $name"
    exit_exists "$name" && die "出口已存在: $name"
    [ -z "$(exit_name_by_display "$display")" ] || die "出口显示名已存在: $display"
    idx=$(next_exit_index)
    mark=$(mark_for_index "$idx")
    table=$(table_for_index "$idx")
    tun=$(tun_for_exit "$name")
    install_singbox_core
    write_ss_exit_files "$name" "$method" "$password" "$server" "$port" "$table" "$tun"
    start_proxy_exit "SS" "$name" "$display" "$mark" "$table" "$tun"
}

add_ss_exit_link() {
    local link="$1" parsed display method password server port name
    [ -n "$link" ] || die "请提供 SS 节点链接。"
    parsed=$(parse_ss_link "$link") || die "SS 链接解析失败。"
    IFS=$'\t' read -r display method password server port <<< "$parsed"
    name="$(safe_exit_id "ss" "$display" "$server" "$port")"
    add_ss_exit_values "$display" "$method" "$password" "$server" "$port" "$name"
}

add_ss_exit() {
    local first="${1:-}" display server port password method
    [ -n "$first" ] || die "用法: $0 add-ss ss://...#名称 或 $0 add-ss 出口名 地址 端口 密码 [加密方式]"
    if [[ "$first" == ss://* ]]; then
        add_ss_exit_link "$first"
        return 0
    fi
    display="$first"
    server="${2:-}"
    port="${3:-}"
    password="${4:-}"
    method="${5:-chacha20-ietf-poly1305}"
    add_ss_exit_values "$display" "$method" "$password" "$server" "$port"
}

add_sk5_exit() {
    need_root
    load_config
    write_default_config
    need_cmd python3
    need_cmd systemctl
    need_cmd ip
    state_lock_acquire
    local first="${1:-}" display server port username password idx mark table tun parsed name
    [ -n "$first" ] || die "用法: $0 add-sk5 socks5://[用户:密码@]地址:端口#名称 或 $0 add-sk5 出口名 地址 端口 [用户名] [密码]"
    if [[ "$first" == *"://"* ]]; then
        parsed=$(parse_socks_link "$first") || die "SK5 链接解析失败。"
        IFS=$'\t' read -r display server port username password <<< "$parsed"
    else
        display="$first"
        server="${2:-}"
        port="${3:-}"
        username="${4:-}"
        password="${5:-}"
    fi
    display="$(normalize_display_name "$display")"
    server="$(normalize_proxy_host "$server")"
    valid_proxy_host "$server" || die "SK5 地址无效，请填写纯 IP 或域名/DDNS，不要带协议、端口或路径: $server"
    validate_port "$port" || die "SK5 端口无效: $port"
    name="$(safe_exit_id "sk5" "$display" "$server" "$port")"
    valid_name "$name" || die "出口内部名称无效: $name"
    exit_exists "$name" && die "出口已存在: $name"
    [ -z "$(exit_name_by_display "$display")" ] || die "出口显示名已存在: $display"
    idx=$(next_exit_index)
    mark=$(mark_for_index "$idx")
    table=$(table_for_index "$idx")
    tun=$(tun_for_exit "$name")
    install_singbox_core
    write_sk5_exit_files "$name" "$server" "$port" "$username" "$password" "$table" "$tun"
    start_proxy_exit "SK5" "$name" "$display" "$mark" "$table" "$tun"
}

add_vless_exit_values() {
    need_root
    load_config
    write_default_config
    need_cmd python3
    need_cmd systemctl
    need_cmd ip
    state_lock_acquire
    local display="$1" server="$2" port="$3" uuid="$4" name="${5:-}" idx mark table tun normalized_uuid
    display="$(normalize_display_name "$display")"
    server="$(normalize_proxy_host "$server")"
    valid_proxy_host "$server" || die "VLESS 地址无效，请填写纯 IP 或域名/DDNS，不要带协议、端口或路径: $server"
    validate_port "$port" || die "VLESS 端口无效: $port"
    normalized_uuid="$(python3 - "$uuid" <<'PY'
import sys, uuid
try:
    print(uuid.UUID(sys.argv[1]))
except (ValueError, AttributeError):
    raise SystemExit(1)
PY
)" || die "VLESS 用户 ID 不是有效 UUID。"
    name="${name:-$(safe_exit_id "vless" "$display" "$server" "$port")}"
    valid_name "$name" || die "出口内部名称无效: $name"
    exit_exists "$name" && die "出口已存在: $name"
    [ -z "$(exit_name_by_display "$display")" ] || die "出口显示名已存在: $display"
    idx=$(next_exit_index)
    mark=$(mark_for_index "$idx")
    table=$(table_for_index "$idx")
    tun=$(tun_for_exit "$name")
    install_singbox_core
    write_vless_exit_files "$name" "$server" "$port" "$normalized_uuid" "$table" "$tun"
    start_proxy_exit "VLESS+TCP" "$name" "$display" "$mark" "$table" "$tun"
}

add_vless_exit_link() {
    local link="$1" parsed display server port uuid name
    [ -n "$link" ] || die "请提供 VLESS+TCP 节点链接。"
    parsed=$(parse_vless_tcp_link "$link") || die "VLESS+TCP 链接解析失败。"
    IFS=$'\t' read -r display server port uuid <<< "$parsed"
    name="$(safe_exit_id "vless" "$display" "$server" "$port")"
    add_vless_exit_values "$display" "$server" "$port" "$uuid" "$name"
}

add_vless_exit() {
    local first="${1:-}" display server port uuid
    [ -n "$first" ] || die "用法: $0 add-vless vless://UUID@地址:端口?encryption=none&type=tcp#名称 或 $0 add-vless 出口名 地址 端口 UUID"
    if [[ "$first" == vless://* ]]; then
        add_vless_exit_link "$first"
        return 0
    fi
    display="$first"
    server="${2:-}"
    port="${3:-}"
    uuid="${4:-}"
    add_vless_exit_values "$display" "$server" "$port" "$uuid"
}

valid_wireguard_key() {
    local key="${1:-}"
    [ "$key" = "-" ] && return 0
    printf '%s' "$key" | grep -Eq '^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$'
}

valid_wireguard_address() {
    local family="$1" value="${2:-}"
    [ "$value" = "-" ] && return 0
    python3 - "$family" "$value" <<'PY'
import ipaddress
import sys

family, value = sys.argv[1:3]
try:
    interface = ipaddress.ip_interface(value)
except ValueError:
    raise SystemExit(1)
expected = 4 if family == "4" else 6
raise SystemExit(0 if interface.version == expected else 1)
PY
}

valid_wireguard_endpoint() {
    local endpoint="${1:-}"
    python3 - "$endpoint" <<'PY'
import sys
from urllib.parse import urlsplit

endpoint = sys.argv[1].strip()
parsed = None
try:
    parsed = urlsplit("wg://" + endpoint)
    valid = bool(parsed.hostname) and parsed.port is not None and 1 <= parsed.port <= 65535
except ValueError:
    valid = False
raise SystemExit(0 if valid and parsed is not None and not parsed.username and not parsed.password and not parsed.path else 1)
PY
}

install_wireguard_tools() {
    command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1 && return 0
    info "正在安装 WireGuard 工具；不会修改现有 sing-box 服务。"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wireguard-tools
    elif command -v yum >/dev/null 2>&1; then
        yum install -y wireguard-tools
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache wireguard-tools
    else
        die "无法自动安装 wireguard-tools，请先安装 wg 和 wg-quick。"
    fi
    command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1 \
        || die "WireGuard 工具安装后仍不可用。"
}

install_wg_server_dependencies() {
    local missing="" cmd
    for cmd in ip nft python3 flock sysctl ss; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        info "正在安装 WG 出口服务器依赖:$missing"
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache wireguard-tools iproute2 nftables python3 util-linux procps
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iproute2 nftables python3 util-linux procps
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y wireguard-tools iproute nftables python3 util-linux procps-ng
        elif command -v yum >/dev/null 2>&1; then
            yum install -y wireguard-tools iproute nftables python3 util-linux procps-ng
        else
            die "无法自动安装 WG 服务端依赖:$missing"
        fi
    fi
    install_wireguard_tools
    for cmd in ip nft python3 flock sysctl ss wg wg-quick; do need_cmd "$cmd"; done
    if ! command -v systemctl >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
        die "当前系统既没有 systemd，也没有 OpenRC，暂不支持自动管理 WG 服务。"
    fi
}

wg_random_free_udp_port() {
    local min="${1:-20000}" max="${2:-65535}" span attempts port
    [[ "$min" =~ ^[0-9]+$ ]] && [[ "$max" =~ ^[0-9]+$ ]] || return 1
    [ "$min" -ge 1024 ] && [ "$max" -le 65535 ] && [ "$min" -le "$max" ] || return 1
    span=$((max - min + 1))
    attempts=$((span * 2))
    [ "$attempts" -gt 200 ] && attempts=200
    while [ "$attempts" -gt 0 ]; do
        port=$((min + RANDOM % span))
        if ! ss -H -lun "sport = :$port" 2>/dev/null | grep -q .; then
            printf '%s\n' "$port"
            return 0
        fi
        attempts=$((attempts - 1))
    done
    return 1
}

WG_CHECK_PASS=0
WG_CHECK_WARN=0
WG_CHECK_FAIL=0

wg_check_pass() { WG_CHECK_PASS=$((WG_CHECK_PASS + 1)); printf '[PASS] %s\n' "$*"; }
wg_check_warn() { WG_CHECK_WARN=$((WG_CHECK_WARN + 1)); printf '[WARN] %s\n' "$*"; }
wg_check_fail() { WG_CHECK_FAIL=$((WG_CHECK_FAIL + 1)); printf '[FAIL] %s\n' "$*"; }

wg_server_preflight() {
    local port="${1:-}" wan probe_iface probe_table global4 init_name port_owner="" bind_result
    WG_CHECK_PASS=0
    WG_CHECK_WARN=0
    WG_CHECK_FAIL=0
    [ -n "$port" ] || die "用法: $0 wg-server-check UDP端口"
    validate_port "$port" || die "UDP 端口无效: $port"
    printf 'WireGuard 出口部署环境检测（UDP %s）\n\n' "$port"

    if [ "${EUID:-$(id -u)}" -eq 0 ]; then wg_check_pass "当前使用 root 权限。"; else wg_check_fail "必须使用 root 权限。"; fi

    if command -v systemctl >/dev/null 2>&1; then
        init_name="systemd"
        wg_check_pass "服务管理器: systemd。"
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        init_name="OpenRC"
        wg_check_pass "服务管理器: OpenRC。"
    else
        init_name="unknown"
        wg_check_fail "未找到受支持的 systemd/OpenRC 服务管理器。"
    fi

    wan="$(wg_server_detect_wan)"
    if [ -n "$wan" ] && ip link show "$wan" >/dev/null 2>&1; then
        wg_check_pass "默认出口网卡: $wan。"
    else
        wg_check_fail "没有检测到可用的 IPv4 默认出口网卡。"
    fi
    if ip route get 1.1.1.1 >/dev/null 2>&1; then wg_check_pass "IPv4 默认路由可用。"; else wg_check_fail "IPv4 默认路由不可用。"; fi

    global4="$(ip -4 -o addr show dev "$wan" scope global 2>/dev/null | awk 'NR == 1 {split($4,a,"/"); print a[1]}')"
    if [ -z "$global4" ]; then
        wg_check_fail "未发现 IPv4 地址。"
    elif python3 - "$global4" <<'PY' >/dev/null 2>&1
import ipaddress, sys
raise SystemExit(0 if ipaddress.ip_address(sys.argv[1]).is_global else 1)
PY
    then
        wg_check_pass "检测到公网 IPv4: $global4。"
    else
        wg_check_warn "本机地址 $global4 不是公网地址；若为 LXC/NAT，必须把公网 UDP $port 映射到本容器同端口。"
    fi

    for cmd in ip wg wg-quick nft python3 ss flock sysctl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            wg_check_pass "命令可用: $cmd。"
        elif command -v apk >/dev/null 2>&1 || command -v apt-get >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            wg_check_warn "缺少命令 $cmd，正式部署时会尝试自动安装。"
        else
            wg_check_fail "缺少命令 $cmd，且未找到可支持的包管理器。"
        fi
    done

    probe_iface="cwgp$((RANDOM % 9000 + 1000))"
    if ip link add "$probe_iface" type wireguard >/tmp/cloudshlii-wg-probe.log 2>&1; then
        ip link del "$probe_iface" 2>/dev/null || true
        wg_check_pass "内核允许创建 WireGuard 接口（CAP_NET_ADMIN 正常）。"
    else
        wg_check_fail "无法创建 WireGuard 接口: $(tr '\n' ' ' </tmp/cloudshlii-wg-probe.log 2>/dev/null)"
    fi
    rm -f /tmp/cloudshlii-wg-probe.log

    probe_table="csh_wgp_$((RANDOM % 9000 + 1000))"
    if ! command -v nft >/dev/null 2>&1; then
        wg_check_warn "nft 命令尚未安装，正式部署时会自动安装 nftables；安装后才能验证 nftables 内核和权限。"
    elif nft add table inet "$probe_table" >/tmp/cloudshlii-nft-probe.log 2>&1; then
        nft delete table inet "$probe_table" 2>/dev/null || true
        wg_check_pass "允许创建和删除独立 nftables 表。"
    else
        wg_check_fail "nftables 权限或内核支持不足: $(tr '\n' ' ' </tmp/cloudshlii-nft-probe.log 2>/dev/null)"
    fi
    rm -f /tmp/cloudshlii-nft-probe.log

    if [ -w /proc/sys/net/ipv4/ip_forward ]; then
        wg_check_pass "IPv4 转发参数可写（当前值: $(cat /proc/sys/net/ipv4/ip_forward)）。"
    else
        wg_check_fail "IPv4 转发参数不可写。"
    fi
    if [ -w /proc/sys/net/ipv6/conf/all/forwarding ]; then
        wg_check_pass "IPv6 转发参数可写（当前值: $(cat /proc/sys/net/ipv6/conf/all/forwarding)）。"
    else
        wg_check_warn "IPv6 转发参数不可写；仅部署 IPv4 时不影响。"
    fi

    if command -v ss >/dev/null 2>&1 && ss -H -lun "sport = :$port" 2>/dev/null | grep -q .; then
        if wg_server_load 2>/dev/null && [ "${WG_LISTEN_PORT:-}" = "$port" ] && ip link show "$WG_SERVER_IFACE" >/dev/null 2>&1; then
            port_owner="当前脚本管理的 $WG_SERVER_IFACE"
            wg_check_pass "UDP $port 已由$port_owner使用，可安全执行重新配置。"
        else
            wg_check_fail "UDP $port 已被其他服务占用。"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        bind_result="$(python3 - "$port" <<'PY' 2>&1
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError as exc:
    print(exc)
    raise SystemExit(1)
finally:
    s.close()
PY
)" && wg_check_pass "UDP $port 当前空闲且可绑定。" || wg_check_fail "UDP $port 无法绑定: $bind_result"
    else
        wg_check_warn "无法执行 UDP 绑定测试，因为缺少 Python。"
    fi

    printf '\n检测汇总: PASS=%s  WARN=%s  FAIL=%s\n' "$WG_CHECK_PASS" "$WG_CHECK_WARN" "$WG_CHECK_FAIL"
    if [ "$WG_CHECK_FAIL" -gt 0 ]; then
        printf '结论: 当前机器不满足 WG 出口部署条件，请先处理 FAIL 项。\n'
        return 1
    fi
    if [ "$WG_CHECK_WARN" -gt 0 ]; then
        printf '结论: 本机内核与权限满足部署；请确认 WARN 中的公网端口映射或可自动安装项。\n'
    else
        printf '结论: 当前机器完整满足 WG 出口部署条件。\n'
    fi
    [ "$init_name" != "unknown" ]
}

write_wireguard_exit_files() {
    local name="$1" iface="$2" endpoint="$3" peer_public_key="$4" address4="$5" address6="$6" private_key="$7" preshared_key="$8" mtu="$9"
    local conf_dir conf service addresses="" allowed_ips="" psk_line=""
    conf_dir="$EXIT_DIR/$name"
    # wg-quick 使用配置文件名作为接口名，因此必须保存为 <iface>.conf。
    conf="$conf_dir/$iface.conf"
    service="$SYSTEMD_DIR/${EXIT_SERVICE_PREFIX}-${name}.service"
    [ "$address4" = "-" ] || { addresses="$address4"; allowed_ips="0.0.0.0/0"; }
    if [ "$address6" != "-" ]; then
        [ -n "$addresses" ] && addresses="$addresses, "
        addresses="${addresses}${address6}"
        [ -n "$allowed_ips" ] && allowed_ips="$allowed_ips, "
        allowed_ips="${allowed_ips}::/0"
    fi
    [ "$preshared_key" = "-" ] || psk_line="PresharedKey = $preshared_key"
    mkdir -p "$conf_dir"
    cat > "$conf" <<EOF
[Interface]
PrivateKey = $private_key
Address = $addresses
MTU = $mtu
Table = off
FwMark = 666

[Peer]
PublicKey = $peer_public_key
$psk_line
Endpoint = $endpoint
AllowedIPs = $allowed_ips
PersistentKeepalive = 25
EOF
    chmod 600 "$conf"
    cat > "$service" <<EOF
[Unit]
Description=cloudshlii WireGuard egress exit $name
After=network-online.target
Wants=network-online.target
Before=$APP_NAME.service $APP_NAME-autosync.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up $conf
ExecStartPost=/bin/sh -c 'for i in \$(seq 1 20); do ip link show "\$1" >/dev/null 2>&1 && break; sleep 1; done; "\$2" apply-exit-route "\$3" >/dev/null 2>&1 || true' sh $iface $INSTALL_BIN $name
ExecStop=/usr/bin/wg-quick down $conf

[Install]
WantedBy=multi-user.target
EOF
}

add_wireguard_exit() {
    need_root
    load_config
    write_default_config
    need_cmd python3
    need_cmd systemctl
    need_cmd ip
    state_lock_acquire
    local display="${1:-}" endpoint="${2:-}" peer_public_key="${3:-}" address4="${4:--}" address6="${5:--}" preshared_key="${6:--}" mtu="${7:-1380}"
    local name idx mark table iface private_key public_key route4 route6 service
    [ -n "$display" ] && [ -n "$endpoint" ] && [ -n "$peer_public_key" ] \
        || die "用法: $0 add-wg 出口名 服务端地址:端口 服务端公钥 IPv4隧道地址 [IPv6隧道地址|-] [PSK|-] [MTU]"
    display="$(normalize_display_name "$display")"
    valid_wireguard_endpoint "$endpoint" || die "WireGuard Endpoint 无效，请使用 域名:端口、IPv4:端口 或 [IPv6]:端口。"
    valid_wireguard_key "$peer_public_key" || die "WireGuard 服务端公钥无效。"
    valid_wireguard_key "$preshared_key" || die "WireGuard PSK 无效；没有 PSK 请填 -。"
    valid_wireguard_address 4 "$address4" || die "WireGuard IPv4 隧道地址无效，请包含前缀，例如 10.66.0.2/32；不启用请填 -。"
    valid_wireguard_address 6 "$address6" || die "WireGuard IPv6 隧道地址无效，请包含前缀；不启用请填 -。"
    [ "$address4" != "-" ] || [ "$address6" != "-" ] || die "WireGuard 至少需要一个 IPv4 或 IPv6 隧道地址。"
    [[ "$mtu" =~ ^[0-9]+$ ]] && [ "$mtu" -ge 1280 ] && [ "$mtu" -le 9000 ] || die "WireGuard MTU 必须是 1280-9000 的整数。"
    name="$(safe_exit_id "wg" "$display" "$endpoint" "")"
    valid_name "$name" || die "出口内部名称无效: $name"
    exit_exists "$name" && die "出口已存在: $name"
    [ -z "$(exit_name_by_display "$display")" ] || die "出口显示名已存在: $display"
    install_wireguard_tools
    idx=$(next_exit_index)
    mark=$(mark_for_index "$idx")
    table=$(table_for_index "$idx")
    iface=$(wg_for_exit "$name")
    private_key="$(wg genkey)"
    public_key="$(printf '%s' "$private_key" | wg pubkey)"
    route4="none"; route6="none"
    [ "$address4" = "-" ] || route4="dev:$iface"
    [ "$address6" = "-" ] || route6="dev:$iface"
    write_wireguard_exit_files "$name" "$iface" "$endpoint" "$peer_public_key" "$address4" "$address6" "$private_key" "$preshared_key" "$mtu"
    service="${EXIT_SERVICE_PREFIX}-${name}"
    mark_nft_pending
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$mark" "$table" "$route4" "$route6" "$display" >> "$EXITS_FILE"
    chmod 600 "$EXITS_FILE"
    state_lock_release
    if ! systemctl daemon-reload || ! systemctl enable "$service" >/dev/null || ! systemctl start "$service"; then
        rollback_proxy_exit_add "$name"
        die "WireGuard 出口 '$display' 启动失败，已回滚本次添加。请查看: journalctl -u $service.service -n 80 --no-pager"
    fi
    if ! wait_for_iface "$iface"; then
        rollback_proxy_exit_add "$name"
        die "WireGuard 出口 '$display' 的接口 $iface 未启动，已回滚本次添加。"
    fi
    if ! (do_apply); then
        rollback_proxy_exit_add "$name"
        die "WireGuard 出口 '$display' 已启动，但宿主机路由应用失败，已回滚本次添加。"
    fi
    info "WireGuard 出口 '$display' 已添加并启动。"
    printf '入口机 WireGuard 公钥: %s\n' "$public_key"
    info "请把上面的入口机公钥配置到出口服务器 Peer；再通过主菜单 7 同步实例授权。"
}

wg_server_lock() {
    mkdir -p "$(dirname "$WG_SERVER_LOCK")"
    exec {WG_SERVER_LOCK_FD}>"$WG_SERVER_LOCK"
    flock -x "$WG_SERVER_LOCK_FD"
}

wg_server_unlock() {
    flock -u "$WG_SERVER_LOCK_FD" 2>/dev/null || true
    exec {WG_SERVER_LOCK_FD}>&-
}

wg_server_detect_wan() {
    ip -4 route show default 2>/dev/null | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

wg_server_network() {
    local value="$1"
    python3 - "$value" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
}

wg_server_load() {
    [ -s "$WG_SERVER_ENV" ] || return 1
    # shellcheck disable=SC1090
    . "$WG_SERVER_ENV"
    WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
    WG_ADDRESS4="${WG_ADDRESS4:--}"
    WG_ADDRESS6="${WG_ADDRESS6:--}"
    WG_MTU="${WG_MTU:-1380}"
    WG_WAN_IFACE="${WG_WAN_IFACE:-}"
}

wg_server_write_sysctl() {
    cat > "$WG_SERVER_SYSCTL" <<'EOF'
# Managed by cloudshlii WireGuard server mode.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    chmod 644 "$WG_SERVER_SYSCTL"
    sysctl -e -q -p "$WG_SERVER_SYSCTL"
}

wg_server_write_openrc_service() {
    local wg_quick_bin
    command -v rc-service >/dev/null 2>&1 || return 0
    wg_quick_bin="$(command -v wg-quick)"
    cat > "$WG_SERVER_OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run
description="cloudshlii WireGuard egress server"

depend() {
    need net
    after firewall
}

start() {
    ebegin "Starting cloudshlii WireGuard server"
    $wg_quick_bin up "$WG_SERVER_CONF"
    eend \$?
}

stop() {
    ebegin "Stopping cloudshlii WireGuard server"
    $wg_quick_bin down "$WG_SERVER_CONF"
    eend \$?
}
EOF
    chmod 755 "$WG_SERVER_OPENRC_SERVICE"
}

wg_server_service_enable_start() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl enable --now "wg-quick@$WG_SERVER_IFACE"
        systemctl restart "wg-quick@$WG_SERVER_IFACE"
    else
        wg_server_write_openrc_service
        rc-update add cloudshlii-wg-server default >/dev/null 2>&1 || true
        if rc-service cloudshlii-wg-server status >/dev/null 2>&1; then
            rc-service cloudshlii-wg-server restart
        else
            rc-service cloudshlii-wg-server start
        fi
    fi
}

wg_server_service_restart() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "wg-quick@$WG_SERVER_IFACE"
    else
        wg_server_write_openrc_service
        if rc-service cloudshlii-wg-server status >/dev/null 2>&1; then
            rc-service cloudshlii-wg-server restart
        else
            rc-service cloudshlii-wg-server start
        fi
    fi
}

wg_server_service_stop_disable() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "wg-quick@$WG_SERVER_IFACE" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    else
        rc-service cloudshlii-wg-server stop 2>/dev/null || true
        rc-update del cloudshlii-wg-server default >/dev/null 2>&1 || true
        rm -f "$WG_SERVER_OPENRC_SERVICE"
    fi
}

wg_server_service_status() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status "wg-quick@$WG_SERVER_IFACE" 2>/dev/null | sed -n '1,8p' || true
    else
        rc-service cloudshlii-wg-server status 2>&1 || true
        rc-update show default 2>/dev/null | grep -F cloudshlii-wg-server || true
    fi
}

wg_server_render() {
    wg_server_load || die "WireGuard 出口服务器尚未初始化。"
    local conf_stage conf_tmp nft_tmp nft_check private_key addresses="" network4="" network6="" nat4="" nat6="" peer_lines=""
    local name public_key allowed4 allowed6 psk rest psk_line allowed_ips
    conf_stage="$(mktemp -d)"
    conf_tmp="$conf_stage/${WG_SERVER_IFACE}.conf"
    nft_tmp="$(mktemp)"
    nft_check="$(mktemp)"
    private_key="$(cat "$WG_SERVER_PRIVATE_KEY")"
    if [ "$WG_ADDRESS4" != "-" ]; then
        addresses="$WG_ADDRESS4"
        network4="$(wg_server_network "$WG_ADDRESS4")"
        nat4="    ip saddr $network4 oifname \"$WG_WAN_IFACE\" masquerade"
    fi
    if [ "$WG_ADDRESS6" != "-" ]; then
        [ -n "$addresses" ] && addresses="$addresses, "
        addresses="${addresses}${WG_ADDRESS6}"
        network6="$(wg_server_network "$WG_ADDRESS6")"
        nat6="    ip6 saddr $network6 oifname \"$WG_WAN_IFACE\" masquerade"
    fi
    while IFS=$'\t' read -r name public_key allowed4 allowed6 psk rest; do
        [ -n "${name:-}" ] || continue
        case "$name" in \#*) continue ;; esac
        psk_line=""
        [ "${psk:--}" = "-" ] || psk_line="PresharedKey = $psk"
        allowed_ips=""
        [ "${allowed4:--}" = "-" ] || allowed_ips="$allowed4"
        if [ "${allowed6:--}" != "-" ]; then
            [ -n "$allowed_ips" ] && allowed_ips="$allowed_ips, "
            allowed_ips="${allowed_ips}${allowed6}"
        fi
        peer_lines="$peer_lines
# Peer: $name
[Peer]
PublicKey = $public_key
$psk_line
AllowedIPs = $allowed_ips
"
    done < "$WG_SERVER_PEERS"
    cat > "$conf_tmp" <<EOF
[Interface]
PrivateKey = $private_key
Address = $addresses
ListenPort = $WG_LISTEN_PORT
MTU = $WG_MTU
PostUp = nft delete table inet $WG_SERVER_NFT_TABLE 2>/dev/null || true; nft -f $WG_SERVER_NFT
PostDown = nft delete table inet $WG_SERVER_NFT_TABLE 2>/dev/null || true
$peer_lines
EOF
    cat > "$nft_tmp" <<EOF
table inet $WG_SERVER_NFT_TABLE {
  chain input {
    type filter hook input priority filter - 5; policy accept;
    udp dport $WG_LISTEN_PORT accept
  }
  chain forward {
    type filter hook forward priority filter - 5; policy accept;
    iifname "$WG_SERVER_IFACE" accept
    oifname "$WG_SERVER_IFACE" ct state established,related accept
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
$nat4
$nat6
  }
}
EOF
    wg-quick strip "$conf_tmp" >/dev/null || { rm -rf "$conf_stage"; rm -f "$nft_tmp" "$nft_check"; die "生成的 WireGuard 服务端配置校验失败。"; }
    if nft list table inet "$WG_SERVER_NFT_TABLE" >/dev/null 2>&1; then
        printf 'delete table inet %s\n' "$WG_SERVER_NFT_TABLE" > "$nft_check"
    fi
    cat "$nft_tmp" >> "$nft_check"
    nft -c -f "$nft_check" || { rm -rf "$conf_stage"; rm -f "$nft_tmp" "$nft_check"; die "生成的 WireGuard nftables 配置校验失败。"; }
    install -m 600 "$conf_tmp" "$WG_SERVER_CONF"
    install -m 600 "$nft_tmp" "$WG_SERVER_NFT"
    rm -rf "$conf_stage"
    rm -f "$nft_tmp" "$nft_check"
}

wg_server_restart() {
    local backup_conf="" backup_nft=""
    [ -f "$WG_SERVER_CONF" ] && { backup_conf="$(mktemp)"; cp -a "$WG_SERVER_CONF" "$backup_conf"; }
    [ -f "$WG_SERVER_NFT" ] && { backup_nft="$(mktemp)"; cp -a "$WG_SERVER_NFT" "$backup_nft"; }
    wg_server_render
    if wg_server_service_enable_start; then
        rm -f "$backup_conf" "$backup_nft"
        return 0
    fi
    warn "WireGuard 服务端启动失败，正在回滚配置。"
    [ -n "$backup_conf" ] && install -m 600 "$backup_conf" "$WG_SERVER_CONF"
    [ -n "$backup_nft" ] && install -m 600 "$backup_nft" "$WG_SERVER_NFT"
    rm -f "$backup_conf" "$backup_nft"
    wg_server_service_restart 2>/dev/null || true
    return 1
}

wg_server_install() {
    need_root
    umask 077
    install_wg_server_dependencies
    wg_server_lock
    local port="${1:-}" address4="${2:-10.66.0.1/24}" address6="${3:--}" mtu="${4:-1380}" wan="${5:-}" tmp
    if [ -z "$port" ] || [ "$port" = "random" ]; then
        port="$(wg_random_free_udp_port "${WG_RANDOM_PORT_MIN:-20000}" "${WG_RANDOM_PORT_MAX:-65535}")" \
            || die "指定随机范围内没有可用 UDP 端口。"
        info "已随机选择未占用 UDP 端口: $port"
    fi
    validate_port "$port" || die "WireGuard UDP 端口无效: $port"
    valid_wireguard_address 4 "$address4" || die "WireGuard 服务端 IPv4 地址无效: $address4"
    valid_wireguard_address 6 "$address6" || die "WireGuard 服务端 IPv6 地址无效: $address6"
    [ "$address4" != "-" ] || [ "$address6" != "-" ] || die "服务端至少需要一个隧道地址。"
    [[ "$mtu" =~ ^[0-9]+$ ]] && [ "$mtu" -ge 1280 ] && [ "$mtu" -le 9000 ] || die "MTU 必须是 1280-9000 的整数。"
    wan="${wan:-$(wg_server_detect_wan)}"
    [ -n "$wan" ] && valid_name "$wan" && ip link show "$wan" >/dev/null 2>&1 || die "无法确定公网出口网卡: $wan"
    mkdir -p "$WG_SERVER_DIR" /etc/wireguard
    chmod 700 "$WG_SERVER_DIR" /etc/wireguard
    [ -s "$WG_SERVER_PRIVATE_KEY" ] || wg genkey > "$WG_SERVER_PRIVATE_KEY"
    chmod 600 "$WG_SERVER_PRIVATE_KEY"
    wg pubkey < "$WG_SERVER_PRIVATE_KEY" > "$WG_SERVER_PUBLIC_KEY"
    chmod 644 "$WG_SERVER_PUBLIC_KEY"
    [ -f "$WG_SERVER_PEERS" ] || printf '# 名称\t公钥\tIPv4 AllowedIPs\tIPv6 AllowedIPs\tPSK\n' > "$WG_SERVER_PEERS"
    chmod 600 "$WG_SERVER_PEERS"
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
WG_LISTEN_PORT=$port
WG_ADDRESS4=$address4
WG_ADDRESS6=$address6
WG_MTU=$mtu
WG_WAN_IFACE=$wan
EOF
    install -m 600 "$tmp" "$WG_SERVER_ENV"
    rm -f "$tmp"
    wg_server_write_sysctl
    if ! wg_server_restart; then
        wg_server_unlock
        die "WireGuard 出口服务器部署失败，请查看 systemd journal 或 OpenRC 服务日志。"
    fi
    wg_server_unlock
    info "WireGuard 出口服务器已部署。"
    printf '接口: %s\nUDP端口: %s\n公网网卡: %s\n服务端公钥: %s\n' "$WG_SERVER_IFACE" "$port" "$wan" "$(cat "$WG_SERVER_PUBLIC_KEY")"
}

wg_server_add_peer() {
    need_root
    wg_server_load || die "请先部署 WireGuard 出口服务器。"
    wg_server_lock
    local name="${1:-}" public_key="${2:-}" allowed4="${3:--}" allowed6="${4:--}" psk="${5:--}" tmp peers_backup line_name line_public line4 line6 line_psk rest
    [ -n "$name" ] && [ -n "$public_key" ] || die "用法: $0 wg-server-add-peer 名称 入口机公钥 IPv4地址 [IPv6地址|-] [PSK|-]"
    valid_name "$name" || die "Peer 名称只能包含字母、数字、点、下划线和横线。"
    valid_wireguard_key "$public_key" || die "入口机 WireGuard 公钥无效。"
    valid_wireguard_key "$psk" || die "PSK 无效；不使用请填 -。"
    valid_wireguard_address 4 "$allowed4" || die "Peer IPv4 地址无效，应填写如 10.66.0.2/32。"
    valid_wireguard_address 6 "$allowed6" || die "Peer IPv6 地址无效。"
    [ "$allowed4" != "-" ] || [ "$allowed6" != "-" ] || die "Peer 至少需要一个隧道地址。"
    tmp="$(mktemp)"
    peers_backup="$(mktemp)"
    cp -a "$WG_SERVER_PEERS" "$peers_backup"
    printf '# 名称\t公钥\tIPv4 AllowedIPs\tIPv6 AllowedIPs\tPSK\n' > "$tmp"
    while IFS=$'\t' read -r line_name line_public line4 line6 line_psk rest; do
        case "${line_name:-}" in ""|\#*) continue ;; esac
        [ "$line_name" = "$name" ] && continue
        if [ "$line_public" = "$public_key" ]; then rm -f "$tmp" "$peers_backup"; wg_server_unlock; die "该公钥已被 Peer '$line_name' 使用。"; fi
        if { [ "$allowed4" != "-" ] && [ "$line4" = "$allowed4" ]; } || { [ "$allowed6" != "-" ] && [ "$line6" = "$allowed6" ]; }; then
            rm -f "$tmp" "$peers_backup"; wg_server_unlock; die "隧道地址已被 Peer '$line_name' 使用。"
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$line_name" "$line_public" "$line4" "$line6" "$line_psk" >> "$tmp"
    done < "$WG_SERVER_PEERS"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$public_key" "$allowed4" "$allowed6" "$psk" >> "$tmp"
    install -m 600 "$tmp" "$WG_SERVER_PEERS"
    rm -f "$tmp"
    if ! wg_server_restart; then
        install -m 600 "$peers_backup" "$WG_SERVER_PEERS"
        rm -f "$peers_backup"
        wg_server_unlock
        die "添加 Peer 后服务重启失败，Peer 清单已回滚。"
    fi
    rm -f "$peers_backup"
    wg_server_unlock
    info "WireGuard Peer '$name' 已添加或更新。"
}

wg_server_remove_peer() {
    need_root
    wg_server_load || die "WireGuard 出口服务器尚未部署。"
    wg_server_lock
    local name="${1:-}" tmp peers_backup found="false" line_name line_public line4 line6 line_psk rest
    [ -n "$name" ] || die "用法: $0 wg-server-remove-peer Peer名称"
    tmp="$(mktemp)"
    peers_backup="$(mktemp)"
    cp -a "$WG_SERVER_PEERS" "$peers_backup"
    printf '# 名称\t公钥\tIPv4 AllowedIPs\tIPv6 AllowedIPs\tPSK\n' > "$tmp"
    while IFS=$'\t' read -r line_name line_public line4 line6 line_psk rest; do
        case "${line_name:-}" in ""|\#*) continue ;; esac
        if [ "${line_name:-}" = "$name" ]; then found="true"; continue; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$line_name" "$line_public" "$line4" "$line6" "$line_psk" >> "$tmp"
    done < "$WG_SERVER_PEERS"
    [ "$found" = "true" ] || { rm -f "$tmp" "$peers_backup"; wg_server_unlock; die "未找到 Peer: $name"; }
    install -m 600 "$tmp" "$WG_SERVER_PEERS"
    rm -f "$tmp"
    if ! wg_server_restart; then
        install -m 600 "$peers_backup" "$WG_SERVER_PEERS"
        rm -f "$peers_backup"
        wg_server_unlock
        die "删除 Peer 后服务重启失败，Peer 清单已回滚。"
    fi
    rm -f "$peers_backup"
    wg_server_unlock
    info "WireGuard Peer '$name' 已删除。"
}

wg_server_status() {
    need_root
    if ! wg_server_load; then
        warn "WireGuard 出口服务器尚未部署。"
        return 1
    fi
    printf 'WireGuard 出口服务器\n接口: %s\nUDP端口: %s\n公网网卡: %s\nIPv4隧道: %s\nIPv6隧道: %s\nMTU: %s\n服务端公钥: %s\n\n' \
        "$WG_SERVER_IFACE" "$WG_LISTEN_PORT" "$WG_WAN_IFACE" "$WG_ADDRESS4" "$WG_ADDRESS6" "$WG_MTU" "$(cat "$WG_SERVER_PUBLIC_KEY")"
    printf 'Peer 配置:\n'
    awk -F '\t' '$1 !~ /^#/ && NF {printf "  %s  IPv4=%s  IPv6=%s  PSK=%s\n", $1,$3,$4,($5=="-"?"无":"已设置")}' "$WG_SERVER_PEERS"
    printf '\n运行状态:\n'
    wg_server_service_status
    printf '\n握手与流量:\n'
    wg show "$WG_SERVER_IFACE" 2>/dev/null || true
}

wg_server_uninstall() {
    need_root
    wg_server_lock
    wg_server_service_stop_disable
    nft delete table inet "$WG_SERVER_NFT_TABLE" 2>/dev/null || true
    rm -f "$WG_SERVER_CONF" "$WG_SERVER_SYSCTL"
    rm -rf "$WG_SERVER_DIR"
    wg_server_unlock
    info "WireGuard 出口服务器组件已卸载；其他 nftables 表、代理服务和运行时转发参数未改动。"
}

stop_and_remove_exit_service() {
    local name="$1" svc
    svc="${EXIT_SERVICE_PREFIX}-${name}.service"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        systemctl daemon-reload 2>/dev/null || true
    fi
}

remove_exit_row() {
    local target="$1" tmp found="false" name rest
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        read -r name rest <<< "$line"
        if [ "$name" = "$target" ]; then
            found="true"
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$EXITS_FILE"
    [ "$found" = "true" ] || { rm -f "$tmp"; die "未找到出口: $target"; }
    install -m 0600 "$tmp" "$EXITS_FILE"
    rm -f "$tmp"
}

reset_containers_for_removed_exit() {
    local removed="$1" tmp changed=0
    local name ip token allowed current project instance rest new_allowed new_current
    [ -f "$CONTAINERS_FILE" ] || return 0
    state_lock_acquire
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        read -r name ip token allowed current project instance rest <<< "$line"
        new_allowed="$(remove_allowed_item "${allowed:-*}" "$removed")"
        new_current="${current:--}"
        if [ "$new_current" = "$removed" ]; then
            new_current="-"
        fi
        if [ "$new_allowed" != "${allowed:-*}" ] || [ "$new_current" != "${current:--}" ]; then
            changed=$((changed + 1))
        fi
        append_container_row "$tmp" "$name" "$ip" "${token:--}" "$new_allowed" "$new_current" "${project:-}" "${instance:-}" "${rest:-}"
    done < "$CONTAINERS_FILE"
    install -m 0600 "$tmp" "$CONTAINERS_FILE"
    rm -f "$tmp"
    if [ "$changed" -gt 0 ]; then
        info "已更新 $changed 条容器授权记录；使用该出口的容器已切回入口机。"
    fi
    state_lock_release
}

reset_auto_allowed_for_removed_exit() {
    local removed="$1" new_allowed
    load_config
    [ "${AUTO_ALLOW_EXITS:-*}" != "*" ] || return 0
    new_allowed="$(remove_allowed_item "${AUTO_ALLOW_EXITS:-*}" "$removed")"
    if [ "$new_allowed" != "${AUTO_ALLOW_EXITS:-*}" ]; then
        set_config_value AUTO_ALLOW_EXITS "$new_allowed"
        info "已从自动授权出口列表中移除已删除出口: $removed"
    fi
}

reset_split_policies_for_removed_exit() {
    local removed="$1" tmp changed=0 app target new_target was_changed
    [ -f "$SPLIT_POLICIES_FILE" ] || return 0
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r app target <<< "$line"
        IFS=$'\t' read -r new_target was_changed <<< "$(split_target_list_remove "$target" "$removed")"
        if [ "$was_changed" = "true" ]; then
            printf '%s\t%s\n' "$app" "$new_target" >> "$tmp"
            changed=$((changed + 1))
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$SPLIT_POLICIES_FILE"
    install -m 0600 "$tmp" "$SPLIT_POLICIES_FILE"
    rm -f "$tmp"
    if [ "$changed" -gt 0 ]; then
        info "已把 $changed 条应用分流策略切回入口机。"
    fi
    [ -f "$SPLIT_CATEGORY_POLICIES_FILE" ] || return 0
    changed=0
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r app target <<< "$line"
        IFS=$'\t' read -r new_target was_changed <<< "$(split_target_list_remove "$target" "$removed")"
        if [ "$was_changed" = "true" ]; then
            printf '%s\t%s\n' "$app" "$new_target" >> "$tmp"
            changed=$((changed + 1))
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$SPLIT_CATEGORY_POLICIES_FILE"
    install -m 0600 "$tmp" "$SPLIT_CATEGORY_POLICIES_FILE"
    rm -f "$tmp"
    if [ "$changed" -gt 0 ]; then
        info "已把 $changed 条分类分流策略切回入口机。"
    fi
}

reset_container_split_policies_for_removed_exit() {
    local removed="$1" tmp changed=0 container app target
    [ -f "$SPLIT_CONTAINER_POLICIES_FILE" ] || return 0
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r container app target <<< "$line"
        if [ "$target" = "$removed" ]; then
            changed=$((changed + 1))
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$SPLIT_CONTAINER_POLICIES_FILE"
    install -m 0600 "$tmp" "$SPLIT_CONTAINER_POLICIES_FILE"
    rm -f "$tmp"
    if [ "$changed" -gt 0 ]; then
        info "已清理 $changed 条引用该出口的容器级应用分流覆盖。"
    fi
}

reset_force_on_exit_policies_for_removed_exit() {
    local removed="$1" file tmp line key source target new_target was_changed changed=0
    for file in "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE"; do
        [ -f "$file" ] || continue
        tmp="$(mktemp)"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
            esac
            IFS=$'\t' read -r key source target <<< "$line"
            if [ "$source" = "$removed" ]; then
                changed=$((changed + 1))
                continue
            fi
            IFS=$'\t' read -r new_target was_changed <<< "$(split_target_list_remove "$target" "$removed")"
            if [ "$was_changed" = "true" ]; then
                changed=$((changed + 1))
                printf '%s\t%s\t%s\n' "$key" "$source" "$new_target" >> "$tmp"
                continue
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$file"
        install -m 0600 "$tmp" "$file"
        rm -f "$tmp"
    done
    [ "$changed" -eq 0 ] || info "已清理 $changed 条引用该出口的按出口强制分流策略。"
}

upsert_exit_limit_row() {
    local name="$1" down="$2" up="$3" tmp line cur_name found=0
    tmp="$(mktemp)"
    if [ -f "$LIMITS_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
            esac
            read -r cur_name _down _up _rest <<< "$line"
            if [ "$cur_name" = "$name" ]; then
                printf '%s\t%s\t%s\n' "$name" "$down" "$up" >> "$tmp"
                found=1
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$LIMITS_FILE"
    fi
    if [ "$found" -eq 0 ]; then
        printf '%s\t%s\t%s\n' "$name" "$down" "$up" >> "$tmp"
    fi
    install -m 0600 "$tmp" "$LIMITS_FILE"
    rm -f "$tmp"
}

remove_exit_limit_row() {
    local removed="$1" tmp line cur_name changed=0
    [ -f "$LIMITS_FILE" ] || return 0
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        read -r cur_name _down _up _rest <<< "$line"
        if [ "$cur_name" = "$removed" ]; then
            changed=$((changed + 1))
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$LIMITS_FILE"
    install -m 0600 "$tmp" "$LIMITS_FILE"
    rm -f "$tmp"
    [ "$changed" -eq 0 ] || info "已清理出口 $removed 的限速配置。"
}

set_exit_limit() {
    need_root
    load_config
    write_default_config
    state_lock_acquire
    local input="${1:-}" down_raw="${2:-}" up_raw="${3:-}" name down up
    [ -n "$input" ] && [ -n "$down_raw" ] || die "用法: $0 limit-exit 出口名 下载限速 [上传限速]；只填一个限速时下载/上传相同"
    name="$(resolve_exit_target "$input")" || die "未找到出口: $input"
    [ "$name" != "-" ] || die "入口机直出不是可限速出口。"
    down="$(normalize_limit_rate "$down_raw")" || die "下载限速无效: $down_raw"
    up="$(normalize_limit_rate "${up_raw:-$down_raw}")" || die "上传限速无效: ${up_raw:-$down_raw}"
    if limit_is_unlimited "$down" && limit_is_unlimited "$up"; then
        remove_exit_limit_row "$name"
        info "已清除出口 $(display_exit_name "$name") 的限速。"
    else
        upsert_exit_limit_row "$name" "$down" "$up"
        info "已设置出口 $(display_exit_name "$name") 共享限速：下载 $(limit_rate_label "$down")，上传 $(limit_rate_label "$up")。"
    fi
    do_apply_limits
    state_lock_release
}

clear_exit_limit() {
    need_root
    load_config
    write_default_config
    state_lock_acquire
    local input="${1:-}" name
    [ -n "$input" ] || die "用法: $0 clear-limit 出口名"
    name="$(resolve_exit_target "$input")" || die "未找到出口: $input"
    [ "$name" != "-" ] || die "入口机直出没有出口限速配置。"
    remove_exit_limit_row "$name"
    do_apply_limits
    state_lock_release
    info "已清除出口 $(display_exit_name "$name") 的限速。"
}

clear_all_exit_limits() {
    need_root
    load_config
    write_default_config
    state_lock_acquire
    local name _mark _table route4 route6 _display dev
    while IFS=$'\t' read -r name _mark _table route4 route6 _display; do
        dev="$(exit_limit_device "$route4" "$route6" || true)"
        [ -n "$dev" ] && reset_tc_limit_on_dev "$dev"
    done < <(read_exit_rows)
    rm -f "$LIMITS_FILE"
    write_default_config
    do_apply_limits
    state_lock_release
    info "已清除所有出口共享限速。"
}

list_exit_limits() {
    load_config
    local name mark table route4 route6 display down up count=0
    printf '\n出口共享限速:\n'
    while IFS=$'\t' read -r name mark table route4 route6 display; do
        count=$((count + 1))
        down="$(exit_limit_down "$name")"
        up="$(exit_limit_up "$name")"
        printf '  %s. %s  id=%s  下载=%s  上传=%s\n' "$count" "${display:-$name}" "$name" "$(limit_rate_label "$down")" "$(limit_rate_label "$up")"
    done < <(read_exit_rows)
    [ "$count" -gt 0 ] || printf '  暂无出口，请先添加出口。\n'
}

cleanup_container_split_policies_for_app_targets() {
    local target_app="$1" allowed_targets="$2" tmp changed=0 container app target
    [ -f "$SPLIT_CONTAINER_POLICIES_FILE" ] || return 0
    state_lock_acquire
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r container app target <<< "$line"
        if [ "$app" = "$target_app" ] && ! split_target_list_contains "$allowed_targets" "$target"; then
            changed=$((changed + 1))
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$SPLIT_CONTAINER_POLICIES_FILE"
    install -m 0600 "$tmp" "$SPLIT_CONTAINER_POLICIES_FILE"
    rm -f "$tmp"
    if [ "$changed" -gt 0 ]; then
        info "已清理 $changed 条不在候选出口内的容器级覆盖。"
    fi
    state_lock_release
}

cleanup_container_split_policies_for_container_allowed() {
    local tmp changed=0 container app target
    [ -f "$SPLIT_CONTAINER_POLICIES_FILE" ] || return 0
    state_lock_acquire
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r container app target <<< "$line"
        if ! container_allows_exit "$container" "$target"; then
            changed=$((changed + 1))
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$SPLIT_CONTAINER_POLICIES_FILE"
    install -m 0600 "$tmp" "$SPLIT_CONTAINER_POLICIES_FILE"
    rm -f "$tmp"
    if [ "$changed" -gt 0 ]; then
        info "已清理 $changed 条超出容器授权出口的应用分流覆盖。"
    fi
    state_lock_release
}

remove_exit() {
    need_root
    load_config
    write_default_config
    state_lock_acquire
    local input="${1:-}" name row mark table route4 route6 display display_label
    [ -n "$input" ] || die "用法: $0 remove-exit 出口名"
    name="$(resolve_exit_target "$input")" || die "未找到出口: $input"
    [ "$name" != "-" ] || die "入口机不是可删除出口。"
    valid_name "$name" || die "出口内部名称无效: $name"
    row="$(exit_row "$name")"
    [ -n "$row" ] || die "未找到出口: $input"
    IFS=$'\t' read -r _name mark table route4 route6 display <<< "$row"
    display_label="${display:-$name}"

    mark_nft_pending
    state_lock_release
    stop_and_remove_exit_service "$name"
    state_lock_acquire
    row="$(exit_row "$name")"
    [ -n "$row" ] || { state_lock_release; die "出口 $display_label 在删除过程中已被其他操作修改，请刷新状态后重试。"; }
    ip route flush table "$table" 2>/dev/null || true
    ip -6 route flush table "$table" 2>/dev/null || true
    rm -rf -- "${EXIT_DIR:?}/$name" "${LEGACY_EXIT_DIR:?}/$name"
    reset_containers_for_removed_exit "$name"
    reset_auto_allowed_for_removed_exit "$name"
    reset_split_policies_for_removed_exit "$name"
    reset_container_split_policies_for_removed_exit "$name"
    reset_force_on_exit_policies_for_removed_exit "$name"
    remove_exit_limit_row "$name"
    remove_exit_row "$name"
    do_apply
    state_lock_release
    sync_now || true
    info "出口 '$display_label' 已删除；相关服务、配置目录、路由表和容器引用已清理。"
}

allowed_contains() {
    local allowed="$1" target="$2" item
    local items=()
    [ "$allowed" = "*" ] && return 0
    IFS=',' read -r -a items <<< "$allowed"
    for item in "${items[@]}"; do
        [ "$item" = "$target" ] && return 0
    done
    return 1
}

container_allows_exit() {
    local container="$1" target="$2" allowed
    [ "$target" = "-" ] && return 0
    allowed="$(container_allowed "$container")"
    [ -n "$allowed" ] || return 1
    allowed_contains "$allowed" "$target"
}

container_exists() {
    local container="$1"
    [ -f "$CONTAINERS_FILE" ] || return 1
    awk -F '\t' -v n="$container" 'NF && $1 !~ /^#/ && $1 == n {found=1} END {exit found ? 0 : 1}' "$CONTAINERS_FILE"
}

container_ip() {
    local container="$1"
    [ -f "$CONTAINERS_FILE" ] || return 0
    awk -F '\t' -v n="$container" 'NF && $1 !~ /^#/ && $1 == n {print $2; exit}' "$CONTAINERS_FILE"
}

container_allowed() {
    local container="$1"
    [ -f "$CONTAINERS_FILE" ] || return 0
    awk -F '\t' -v n="$container" 'NF && $1 !~ /^#/ && $1 == n {print ($4 ? $4 : "*"); exit}' "$CONTAINERS_FILE"
}

remove_allowed_item() {
    local allowed="$1" removed="$2" item out="" comma=""
    local items=()
    [ "$allowed" = "*" ] && { printf '*\n'; return 0; }
    IFS=',' read -r -a items <<< "$allowed"
    for item in "${items[@]}"; do
        [ -n "$item" ] || continue
        [ "$item" = "$removed" ] && continue
        out="${out}${comma}${item}"
        comma=","
    done
    printf '%s\n' "${out:--}"
}

resolve_allowed_exit_list() {
    local raw item resolved out="" comma="" seen=","
    local parts=()
    if [ "$#" -eq 0 ]; then
        printf '*\n'
        return 0
    fi
    for raw in "$@"; do
        IFS=',' read -r -a parts <<< "$raw"
        for item in "${parts[@]}"; do
            item="$(trim_space "$item")"
            [ -n "$item" ] || continue
            case "$item" in
                "*"|all|ALL|全部|全部出口)
                    printf '*\n'
                    return 0
                    ;;
            esac
            resolved="$(resolve_exit_target "$item")" || return 1
            [ "$resolved" != "-" ] || return 1
            case "$seen" in
                *,"$resolved",*) ;;
                *)
                    out="$out$comma$resolved"
                    comma=","
                    seen="$seen$resolved,"
                    ;;
            esac
        done
    done
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

add_container() {
    need_root
    load_config
    write_default_config
    state_lock_acquire
    local name="${1:-}" ip="${2:-}" allowed="${3:-*}" current="${4:-}" token="${5:-}" resolved_current
    [ -n "$name" ] && [ -n "$ip" ] || die "用法: $0 add-container 容器名 容器IP [允许出口] [当前出口] [TOKEN]"
    valid_name "$name" || die "容器名无效: $name"
    if ! is_ipv4 "$ip" && ! is_ipv6 "$ip"; then
        die "容器 IP 无效: $ip"
    fi
    if read_container_rows | awk -F '\t' -v n="$name" -v ip="$ip" '$1 == n || $2 == ip {found=1} END {exit found ? 0 : 1}'; then
        die "容器名或 IP 已存在。"
    fi
    resolved_current="$(resolve_exit_target "${current:-}")" || die "未知当前出口: $current"
    current="$resolved_current"
    if [ "$current" != "-" ]; then
        allowed_contains "$allowed" "$current" || die "当前出口 '$current' 不在允许出口 '$allowed' 内。"
    fi
    token="${token:-$(gen_token)}"
    mark_nft_pending
    append_container_row "$CONTAINERS_FILE" "$name" "$ip" "$token" "$allowed" "$current"
    chmod 600 "$CONTAINERS_FILE"
    do_apply_nftables
    state_lock_release
    info "已添加容器 '$name' ($ip)，当前出口: $(display_exit_name "$current")"
    printf 'TOKEN=%s\n' "$token"
    info "请把这个 token 写入容器内 /etc/incus-egress-token，并安装客户端为 /usr/local/bin/out。"
}

set_container_exit() {
    need_root
    load_config
    state_lock_acquire
    local ref="${1:-}" new_exit="${2:-}" tmp found="false" resolved_exit name ip token allowed current project instance rest
    [ -n "$ref" ] && [ -n "$new_exit" ] || die "用法: $0 set-container 容器名或IP 出口名"
    resolved_exit="$(resolve_exit_target "$new_exit")" || die "未知出口: $new_exit"
    new_exit="$resolved_exit"
    mark_nft_pending
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        read -r name ip token allowed current project instance rest <<< "$line"
        if [ "$name" = "$ref" ] || [ "$ip" = "$ref" ]; then
            if [ "$new_exit" != "-" ]; then
                allowed_contains "${allowed:-*}" "$new_exit" || die "容器 $name 不允许使用出口 '$new_exit'。"
            fi
            append_container_row "$tmp" "$name" "$ip" "${token:--}" "${allowed:-*}" "$new_exit" "${project:-}" "${instance:-}" "${rest:-}"
            found="true"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$CONTAINERS_FILE"
    [ "$found" = "true" ] || die "未找到容器: $ref"
    install -m 0600 "$tmp" "$CONTAINERS_FILE"
    rm -f "$tmp"
    do_apply_nftables
    state_lock_release
}

add_allowed_exit() {
    local allowed="${1:-*}" target="$2"
    if [ "$target" = "-" ] || [ "$allowed" = "*" ] || allowed_contains "$allowed" "$target"; then
        printf '%s\n' "$allowed"
    elif [ -z "$allowed" ] || [ "$allowed" = "-" ]; then
        printf '%s\n' "$target"
    else
        printf '%s,%s\n' "$allowed" "$target"
    fi
}

list_running_container_identities() {
    local project json
    for project in $AUTO_PROJECTS; do
        [ -n "$project" ] || continue
        json="$(mktemp)"
        if ! incus --project "$project" list --format json > "$json" 2>/dev/null; then
            rm -f "$json"
            warn "读取 Incus project=$project 的容器状态失败。"
            return 1
        fi
        if ! python3 - "$project" "$json" <<'PY'
import json
import sys

project, path = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as fh:
        items = json.load(fh)
except Exception as exc:
    print("无法解析 Incus 容器状态: %s" % exc, file=sys.stderr)
    raise SystemExit(1)

for item in items:
    name = item.get("name") or ""
    kind = item.get("type") or item.get("instance_type") or "container"
    status = (item.get("status") or "").lower()
    if name and kind == "container" and status == "running":
        print("%s\t%s" % (project, name))
PY
        then
            rm -f "$json"
            return 1
        fi
        rm -f "$json"
    done
}

switch_all_running_containers() {
    need_root
    load_config
    write_default_config
    need_cmd incus
    need_cmd python3
    local requested="${1:-}" target running_file tmp original changed_ips resolved name ip token allowed current project instance fingerprint rest
    local key new_allowed running_count=0 matched=0 changed=0 authorization_added=0 unchanged=0
    local -A running=()

    [ -n "$requested" ] || die "用法: $0 switch-all-containers 出口名"
    resolved="$(resolve_exit_target "$requested")" || die "未知出口: $requested"
    target="$resolved"

    info "正在同步并复核 Incus 运行中容器状态..."
    sync_now || die "容器同步失败，为避免部分切换，本次操作未执行。"

    running_file="$(mktemp)"
    if ! list_running_container_identities > "$running_file"; then
        rm -f "$running_file"
        die "读取运行中容器状态失败，为避免部分切换，本次操作未执行。"
    fi
    while IFS=$'\t' read -r project instance || [ -n "${project:-}${instance:-}" ]; do
        [ -n "${project:-}" ] && [ -n "${instance:-}" ] || continue
        key="$project"$'\034'"$instance"
        if [ -z "${running[$key]:-}" ]; then
            running["$key"]=1
            running_count=$((running_count + 1))
        fi
    done < "$running_file"
    rm -f "$running_file"

    if [ "$running_count" -eq 0 ]; then
        info "没有发现状态为 Running 的 Incus 容器，未修改任何配置。"
        return 0
    fi

    state_lock_acquire
    tmp="$(mktemp)"
    original="$(mktemp)"
    changed_ips="$(mktemp)"
    cp "$CONTAINERS_FILE" "$original"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r name ip token allowed current project instance fingerprint rest <<< "$line"
        project="${project:-default}"
        instance="${instance:-$name}"
        key="$project"$'\034'"$instance"
        if [ -n "${running[$key]:-}" ]; then
            matched=$((matched + 1))
            new_allowed="$(add_allowed_exit "${allowed:-*}" "$target")"
            if [ "$new_allowed" != "${allowed:-*}" ]; then
                authorization_added=$((authorization_added + 1))
            fi
            if [ "${current:--}" != "$target" ] || [ "$new_allowed" != "${allowed:-*}" ]; then
                append_container_row "$tmp" "$name" "$ip" "${token:--}" "$new_allowed" "$target" "$project" "$instance" "${fingerprint:-}"
                printf '%s\n' "$ip" >> "$changed_ips"
                changed=$((changed + 1))
            else
                printf '%s\n' "$line" >> "$tmp"
                unchanged=$((unchanged + 1))
            fi
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$CONTAINERS_FILE"

    if [ "$changed" -gt 0 ]; then
        mark_nft_pending
        install -m 0600 "$tmp" "$CONTAINERS_FILE"
        if ! (do_apply_nftables); then
            install -m 0600 "$original" "$CONTAINERS_FILE"
            mark_nft_pending
            if ! (do_apply_nftables); then
                warn "批量切换失败后旧 nftables 规则恢复不完整，已保留待应用标记；请执行: $INSTALL_BIN apply"
            fi
            rm -f "$tmp" "$original" "$changed_ips"
            state_lock_release
            die "批量切换的数据面应用失败，容器出口配置已恢复到操作前状态。"
        fi
    fi
    rm -f "$tmp" "$original"
    state_lock_release

    if [ "$changed" -gt 0 ] && [ "${SWITCH_CLEAR_CONNTRACK:-true}" = "true" ] && command -v conntrack >/dev/null 2>&1; then
        sort -u "$changed_ips" | while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            conntrack -D -s "$ip" >/dev/null 2>&1 || true
        done
    fi
    rm -f "$changed_ips"

    if [ "$matched" -eq 0 ]; then
        warn "发现 $running_count 台运行中容器，但没有可切换的已接管记录；请检查同步日志和容器 IP。"
        return 1
    fi
    info "批量切换完成：目标 $(display_exit_name "$target")，运行中 $running_count 台，已接管 $matched 台，更新 $changed 台，原本已是该出口 $unchanged 台。"
    if [ "$authorization_added" -gt 0 ]; then
        info "其中 $authorization_added 台容器原授权不含该出口，已自动补充授权。"
    fi
    if [ "$matched" -lt "$running_count" ]; then
        warn "$((running_count - matched)) 台运行中容器因未取得有效 IP 或未纳入接管而跳过。"
    fi
}

reset_all_containers_to_entry() {
    need_root
    load_config
    write_default_config
    state_lock_acquire
    local tmp changed=0 line name ip token allowed current project instance rest
    [ -f "$CONTAINERS_FILE" ] || return 0
    mark_nft_pending
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        read -r name ip token allowed current project instance rest <<< "$line"
        if [ "${current:--}" != "-" ]; then
            changed=$((changed + 1))
        fi
        append_container_row "$tmp" "$name" "$ip" "${token:--}" "${allowed:-*}" "-" "${project:-}" "${instance:-}" "${rest:-}"
    done < "$CONTAINERS_FILE"
    install -m 0600 "$tmp" "$CONTAINERS_FILE"
    rm -f "$tmp"
    do_apply_nftables
    state_lock_release
    info "已把 $changed 台容器的默认出口切回入口机。"
}

set_all_containers_access_mode() {
    need_root
    load_config
    write_default_config
    state_lock_acquire
    local new_allowed="$1" reset_current="${2:-false}" label="${3:-容器授权}" tmp changed=0 line name ip token allowed current project instance rest new_current
    [ -f "$CONTAINERS_FILE" ] || { info "暂无容器接管记录，已跳过 $label。"; return 0; }
    mark_nft_pending
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        read -r name ip token allowed current project instance rest <<< "$line"
        new_current="${current:--}"
        if [ "$reset_current" = "true" ]; then
            new_current="-"
        fi
        if [ "$new_current" != "-" ] && ! allowed_contains "$new_allowed" "$new_current"; then
            new_current="-"
        fi
        if [ "${allowed:-*}" != "$new_allowed" ] || [ "${current:--}" != "$new_current" ]; then
            changed=$((changed + 1))
        fi
        append_container_row "$tmp" "$name" "$ip" "${token:--}" "$new_allowed" "$new_current" "${project:-}" "${instance:-}" "${rest:-}"
    done < "$CONTAINERS_FILE"
    install -m 0600 "$tmp" "$CONTAINERS_FILE"
    rm -f "$tmp"
    cleanup_container_split_policies_for_container_allowed
    do_apply_nftables
    state_lock_release
    info "已更新 $changed 台容器的 $label。"
}

download_to_file() {
    local url="$1" out="$2" timeout max_time
    timeout="${SPLIT_FETCH_TIMEOUT:-10}"
    max_time=$((timeout + 5))
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$timeout" --max-time "$max_time" --retry 1 -A "$APP_NAME" "$url" -o "$out"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$timeout" --tries=1 -U "$APP_NAME" -O "$out" "$url"
        return $?
    fi
    return 127
}

split_catalog_ready() {
    [ -f "$SPLIT_CATALOG_FILE" ] || return 1
    [ -s "$SPLIT_APPS_FILE" ] || return 1
    [ "$(read_split_apps | awk 'END {print NR + 0}')" -gt 0 ]
}

split_require_catalog() {
    split_catalog_ready && return 0
    die "尚未同步应用目录。请先进入“分流管理”选择 1，或执行: $0 split-fetch"
}

split_parse_policy_apps() {
    local tmp app parsed=0 fail=0
    tmp="$(mktemp)"
    {
        read_split_policies | awk -F '\t' '{print $1}'
        while IFS= read -r app; do [ -n "$app" ] && printf '%s\n' "$app"; done < <(read_force_split_policies)
    } | awk 'NF && !seen[$0]++' > "$tmp"
    while IFS= read -r app || [ -n "$app" ]; do
        [ -n "$app" ] || continue
        if split_prepare_app_rules "$app" >&2; then
            parsed=$((parsed + 1))
        else
            fail=$((fail + 1))
        fi
    done < "$tmp"
    rm -f "$tmp"
    printf '%s\t%s\n' "$parsed" "$fail"
}

cleanup_split_policies_for_missing_apps() {
    local tmp line changed=0 app target container category
    state_lock_acquire
    mark_nft_pending
    if [ -f "$SPLIT_POLICIES_FILE" ]; then
        tmp="$(mktemp)"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
            esac
            IFS=$'\t' read -r app target <<< "$line"
            if split_app_exists "$app"; then
                printf '%s\n' "$line" >> "$tmp"
            else
                changed=$((changed + 1))
            fi
        done < "$SPLIT_POLICIES_FILE"
        install -m 0600 "$tmp" "$SPLIT_POLICIES_FILE"
        rm -f "$tmp"
    fi
    if [ -f "$SPLIT_FORCE_POLICIES_FILE" ]; then
        tmp="$(mktemp)"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
            esac
            app="$line"
            if split_app_exists "$app"; then
                printf '%s\n' "$line" >> "$tmp"
            else
                changed=$((changed + 1))
            fi
        done < "$SPLIT_FORCE_POLICIES_FILE"
        install -m 0600 "$tmp" "$SPLIT_FORCE_POLICIES_FILE"
        rm -f "$tmp"
    fi
    if [ -f "$SPLIT_CONTAINER_POLICIES_FILE" ]; then
        tmp="$(mktemp)"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
            esac
            IFS=$'\t' read -r container app target <<< "$line"
            if split_app_exists "$app"; then
                printf '%s\n' "$line" >> "$tmp"
            else
                changed=$((changed + 1))
            fi
        done < "$SPLIT_CONTAINER_POLICIES_FILE"
        install -m 0600 "$tmp" "$SPLIT_CONTAINER_POLICIES_FILE"
        rm -f "$tmp"
    fi
    if [ -f "$SPLIT_CATEGORY_POLICIES_FILE" ]; then
        tmp="$(mktemp)"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
            esac
            IFS=$'\t' read -r category target <<< "$line"
            if split_category_exists "$category"; then
                printf '%s\n' "$line" >> "$tmp"
            else
                changed=$((changed + 1))
            fi
        done < "$SPLIT_CATEGORY_POLICIES_FILE"
        install -m 0600 "$tmp" "$SPLIT_CATEGORY_POLICIES_FILE"
        rm -f "$tmp"
    fi
    if [ -f "$SPLIT_FORCE_CATEGORY_POLICIES_FILE" ]; then
        tmp="$(mktemp)"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
            esac
            category="$line"
            if split_category_exists "$category"; then
                printf '%s\n' "$line" >> "$tmp"
            else
                changed=$((changed + 1))
            fi
        done < "$SPLIT_FORCE_CATEGORY_POLICIES_FILE"
        install -m 0600 "$tmp" "$SPLIT_FORCE_CATEGORY_POLICIES_FILE"
        rm -f "$tmp"
    fi
    [ "$changed" -gt 0 ] && info "已清理 $changed 条失效的分流策略引用。"
    state_lock_release
    return 0
}

# 将单个规则合集拆分为 apps.tsv 和每应用本地缓存。只有完整解析成功后才替换现有目录。
split_import_bundle_file() {
    local bundle="$1" now="$2" source_url="$3"
    python3 - "$bundle" "$SPLIT_APPS_FILE" "$SPLIT_RAW_DIR" "$SPLIT_RESOLVED_DIR" "$SPLIT_BUNDLE_FILE" "$SPLIT_CATALOG_FILE" "$now" "$source_url" <<'PY'
import hashlib
import ipaddress
import os
import re
import shutil
import sys
import tempfile
import unicodedata

bundle, apps_file, raw_dir, resolved_dir, cached_bundle, catalog_file, now, source_url = sys.argv[1:9]
supported_types = {"DOMAIN", "DOMAIN-SUFFIX", "IP-CIDR", "IP-CIDR6"}
category_re = re.compile(r"^#\s*(?:风险场景|CATEGORY)\s*[：:]\s*(.+?)(?:（|\(|$)", re.I)
app_re = re.compile(r"^#\s*(?:应用|APP)\s*[：:]\s*(.+?)(?:（|\(|$)", re.I)
rules_declared_re = re.compile(r"\bRules\s*:\s*(\d+)", re.I)
scenarios_declared_re = re.compile(r"\bscenarios\s*:\s*(\d+)", re.I)


def clean_field(value):
    return (value or "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def normalize_domain(value):
    value = value.strip().strip("'\"").strip().lower()
    if value.startswith("*."):
        value = value[2:]
    value = value.strip(".")
    if not value or any(ch in value for ch in "/:* "):
        raise ValueError("invalid domain")
    encoded = value.encode("idna").decode("ascii")
    if "." not in encoded or len(encoded) > 253:
        raise ValueError("invalid domain")
    return encoded


def normalize_rule(line):
    parts = [item.strip() for item in line.split(",")]
    if len(parts) < 2:
        raise ValueError("missing value")
    kind = parts[0].upper()
    value = parts[1]
    if kind not in supported_types:
        return None, kind
    if kind in {"DOMAIN", "DOMAIN-SUFFIX"}:
        return "%s,%s" % (kind, normalize_domain(value)), kind
    network = ipaddress.ip_network(value, strict=False)
    expected = 4 if kind == "IP-CIDR" else 6
    if network.version != expected:
        raise ValueError("address family mismatch")
    return "%s,%s,no-resolve" % (kind, network), kind


def generated_id(display, used):
    normalized = unicodedata.normalize("NFKD", display).encode("ascii", "ignore").decode("ascii").lower()
    slug = re.sub(r"[^a-z0-9]+", "_", normalized).strip("_")
    digest = hashlib.sha256(display.casefold().encode("utf-8")).hexdigest()[:10]
    if not slug:
        slug = "app_%s" % digest
    slug = slug[:48].strip("_") or "app_%s" % digest
    candidate = slug
    if candidate in used:
        candidate = "%s_%s" % (slug[:37], digest)
    index = 2
    while candidate in used:
        candidate = "%s_%s" % (slug[:40], index)
        index += 1
    return candidate


old_rows = []
old_ids_by_display = {}
old_enabled = {}
old_source_ids = set()
if os.path.exists(apps_file):
    with open(apps_file, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if not parts or not parts[0] or parts[0].startswith("#"):
                continue
            parts += [""] * (5 - len(parts))
            app_id, display, category, remote, enabled = parts[:5]
            row = [clean_field(app_id), clean_field(display or app_id), clean_field(category or "未分类"), clean_field(remote or app_id), clean_field(enabled or "true")]
            if row[3].startswith("custom:"):
                old_rows.append(row)
            else:
                old_source_ids.add(row[0])
                old_ids_by_display.setdefault(row[1].casefold(), row[0])
                old_enabled[row[0]] = row[4]

categories = []
apps = []
apps_by_name = {}
current_category = ""
current_app = None
declared_rules = None
declared_scenarios = None
actual_rules = 0
invalid_rules = []
unsupported_counts = {}
duplicate_sections = 0
category_conflicts = 0

with open(bundle, "r", encoding="utf-8-sig", errors="strict") as fh:
    for lineno, raw in enumerate(fh, 1):
        line = raw.strip()
        match = rules_declared_re.search(line)
        if match:
            declared_rules = int(match.group(1))
        match = scenarios_declared_re.search(line)
        if match:
            declared_scenarios = int(match.group(1))
        match = category_re.match(line)
        if match:
            current_category = clean_field(match.group(1))
            if current_category and current_category not in categories:
                categories.append(current_category)
            current_app = None
            continue
        match = app_re.match(line)
        if match:
            display = clean_field(match.group(1))
            if not current_category or not display:
                raise SystemExit("第 %s 行应用缺少所属风险场景。" % lineno)
            key = display.casefold()
            if key in apps_by_name:
                current_app = apps_by_name[key]
                duplicate_sections += 1
                if current_app["category"] != current_category:
                    category_conflicts += 1
                continue
            current_app = {"display": display, "category": current_category, "rules": [], "seen": set()}
            apps_by_name[key] = current_app
            apps.append(current_app)
            continue
        if not line or line.startswith("#") or line == "payload:":
            continue
        if line.startswith("- "):
            line = line[2:].strip().strip("'\"")
        actual_rules += 1
        if current_app is None:
            invalid_rules.append("第 %s 行规则不在应用段内" % lineno)
            continue
        try:
            normalized, kind = normalize_rule(line)
        except Exception as exc:
            invalid_rules.append("第 %s 行 %s: %s" % (lineno, line, exc))
            continue
        if normalized is None:
            unsupported_counts[kind] = unsupported_counts.get(kind, 0) + 1
            continue
        if normalized not in current_app["seen"]:
            current_app["seen"].add(normalized)
            current_app["rules"].append(normalized)

if declared_rules and actual_rules < max(1, int(declared_rules * 0.8)):
    raise SystemExit("规则文件疑似不完整：声明 %s 条，实际只读取 %s 条，已保留旧目录。" % (declared_rules, actual_rules))
if declared_scenarios and len(categories) < declared_scenarios:
    raise SystemExit("规则文件疑似不完整：声明 %s 个分类，实际只读取 %s 个，已保留旧目录。" % (declared_scenarios, len(categories)))
if invalid_rules:
    raise SystemExit("规则文件包含 %s 条无效规则（%s），已保留旧目录。" % (len(invalid_rules), "；".join(invalid_rules[:3])))

usable_apps = [item for item in apps if item["rules"]]
dropped_apps = [item["display"] for item in apps if not item["rules"]]
if not categories or not usable_apps:
    raise SystemExit("规则文件没有可用的分类或应用，已保留旧目录。")

os.makedirs(os.path.dirname(apps_file), exist_ok=True)
os.makedirs(raw_dir, exist_ok=True)
stage = tempfile.mkdtemp(prefix=".bundle-import-", dir=os.path.dirname(raw_dir))
stage_raw = os.path.join(stage, "raw")
os.makedirs(stage_raw)
used_ids = {row[0] for row in old_rows}
rows = []
try:
    for item in usable_apps:
        app_id = old_ids_by_display.get(item["display"].casefold(), "")
        if not app_id or app_id in used_ids:
            app_id = generated_id(item["display"], used_ids)
        used_ids.add(app_id)
        item["id"] = app_id
        enabled = old_enabled.get(app_id, "true") or "true"
        rows.append([app_id, item["display"], item["category"], "bundle:%s" % app_id, enabled])
        raw_path = os.path.join(stage_raw, "%s.rules" % app_id)
        with open(raw_path, "w", encoding="utf-8", newline="\n") as out:
            out.write("# 分类：%s\n# 应用：%s\n" % (item["category"], item["display"]))
            for rule in item["rules"]:
                out.write(rule + "\n")
    rows.extend(old_rows)
    apps_tmp = os.path.join(stage, "apps.tsv")
    with open(apps_tmp, "w", encoding="utf-8", newline="\n") as out:
        for row in rows:
            out.write("\t".join(clean_field(value) for value in row) + "\n")
    bundle_tmp = os.path.join(stage, "Scam-Abuse-Risk.list")
    shutil.copyfile(bundle, bundle_tmp)

    new_source_ids = {item["id"] for item in usable_apps}
    for app_id in old_source_ids - new_source_ids:
        for suffix in (".rules", ".rules.url"):
            try:
                os.unlink(os.path.join(raw_dir, app_id + suffix))
            except FileNotFoundError:
                pass
        for suffix in (".ipv4", ".ipv6", ".domains", ".unsupported", ".stats"):
            try:
                os.unlink(os.path.join(resolved_dir, app_id + suffix))
            except FileNotFoundError:
                pass
    for item in usable_apps:
        app_id = item["id"]
        os.replace(os.path.join(stage_raw, "%s.rules" % app_id), os.path.join(raw_dir, "%s.rules" % app_id))
        with open(os.path.join(raw_dir, "%s.rules.url" % app_id), "w", encoding="utf-8") as out:
            out.write("%s#%s\n" % (source_url, item["display"]))
    os.replace(apps_tmp, apps_file)
    os.replace(bundle_tmp, cached_bundle)
    with open(catalog_file + ".tmp", "w", encoding="utf-8") as out:
        out.write("%s\n" % now)
    os.replace(catalog_file + ".tmp", catalog_file)
    for path in (apps_file, cached_bundle, catalog_file):
        os.chmod(path, 0o600)
    for item in usable_apps:
        app_id = item["id"]
        os.chmod(os.path.join(raw_dir, "%s.rules" % app_id), 0o600)
        os.chmod(os.path.join(raw_dir, "%s.rules.url" % app_id), 0o600)
finally:
    shutil.rmtree(stage, ignore_errors=True)

supported_count = sum(len(item["rules"]) for item in usable_apps)
unsupported_count = sum(unsupported_counts.values())
print("已导入单文件规则：分类 %s 个，应用 %s 个，可执行规则 %s 条。" % (len(categories), len(usable_apps), supported_count))
if duplicate_sections:
    print("已合并 %s 个同名应用段。" % duplicate_sections)
if unsupported_count:
    details = "、".join("%s %s" % (key, unsupported_counts[key]) for key in sorted(unsupported_counts))
    print("已跳过宿主机网络层无法识别的规则 %s 条：%s。" % (unsupported_count, details))
if dropped_apps:
    print("未显示无可执行网络规则的应用：%s。" % "、".join(dropped_apps))
if category_conflicts:
    print("警告：%s 个同名应用段跨分类，已采用首次出现的分类。" % category_conflicts)
if declared_rules and declared_rules != actual_rules:
    print("提示：文件声明规则 %s 条，实际读取 %s 条。" % (declared_rules, actual_rules))
PY
}

# 新目录源只下载一个合集文件，不访问 GitHub API，也不为每个应用发起请求。
split_fetch_all_rules() {
    need_root
    load_config
    write_default_config
    need_cmd python3
    local mode="${1:-catalog}" now tmp size
    case "$mode" in
        catalog|fetch|目录|all|full|fetch-all|update) ;;
        *) die "未知分流拉取模式: $mode" ;;
    esac
    mkdir -p "$SPLIT_DIR" "$SPLIT_RAW_DIR" "$SPLIT_RESOLVED_DIR" "$SPLIT_CACHE_DIR"
    split_cache_lock_acquire
    tmp="$(mktemp)"
    info "正在获取单文件分流规则: $SPLIT_RULE_BUNDLE_URL"
    if ! download_to_file "$SPLIT_RULE_BUNDLE_URL" "$tmp"; then
        rm -f "$tmp"
        split_cache_lock_release
        warn "单文件分流规则下载失败，现有目录和缓存未改动。"
        return 1
    fi
    size="$(wc -c < "$tmp" | tr -d ' ')"
    if [ "${size:-0}" -lt 100 ] || [ "${size:-0}" -gt 5242880 ]; then
        rm -f "$tmp"
        split_cache_lock_release
        warn "下载的分流规则文件大小异常（${size:-0} 字节），现有目录未改动。"
        return 1
    fi
    now="$(date +%s)"
    if ! split_import_bundle_file "$tmp" "$now" "$SPLIT_RULE_BUNDLE_URL"; then
        rm -f "$tmp"
        split_cache_lock_release
        return 1
    fi
    rm -f "$tmp"
    cleanup_split_policies_for_missing_apps
    split_cache_lock_release
    info "应用目录与规则缓存已通过一次下载完成同步。"
}

split_download_app() {
    local app="$1" remote="$2" raw
    remote="${remote:-$app}"
    raw="$(split_raw_file "$app")"
    case "$remote" in
        custom:*)
            [ -s "$raw" ] && return 0
            warn "自定义应用缺少本地规则文件: $app"
            return 1
            ;;
        bundle:*)
            if [ -s "$raw" ]; then
                return 0
            fi
            warn "应用规则缓存缺失，正在重新同步单文件规则源: $app"
            split_fetch_all_rules catalog || return 1
            [ -s "$raw" ]
            return $?
            ;;
        *)
            # 兼容升级前的旧目录行：同步新合集后复用同名应用保留下来的 ID。
            warn "检测到旧版应用目录，正在迁移到单文件规则源: $app"
            split_fetch_all_rules catalog || return 1
            [ -s "$raw" ]
            return $?
            ;;
    esac
}

split_parse_app_rules() {
    local app="$1" raw v4 v6 domains unsupported stats
    raw="$(split_raw_file "$app")"
    v4="$(split_resolved_v4_file "$app")"
    v6="$(split_resolved_v6_file "$app")"
    domains="$SPLIT_RESOLVED_DIR/$app.domains"
    unsupported="$SPLIT_RESOLVED_DIR/$app.unsupported"
    stats="$SPLIT_RESOLVED_DIR/$app.stats"
    mkdir -p "$SPLIT_RESOLVED_DIR"
    python3 - "$raw" "$v4" "$v6" "$domains" "$unsupported" "$stats" "${SPLIT_DOMAIN_RESOLVE_LIMIT:-300}" "${SPLIT_DNS_TIMEOUT:-2}" "${SPLIT_DNS_WORKERS:-4}" <<'PY'
import concurrent.futures
import datetime
import ipaddress
import os
import socket
import sys

raw_path, v4_path, v6_path, domains_path, unsupported_path, stats_path, limit_s, timeout_s, workers_s = sys.argv[1:10]
limit = max(int(limit_s or "300"), 0)
timeout = max(float(timeout_s or "2"), 0.2)
dns_workers = max(1, min(int(workers_s or "4"), 16))
socket.setdefaulttimeout(timeout)

rules = 0
domains_seen = 0
domains_tried = 0
resolved_domains = 0
v4 = set()
v6 = set()
domains = []
unsupported = []


def add_ip_or_cidr(value):
    value = value.strip()
    if not value:
        return
    try:
        if "/" in value:
            net = ipaddress.ip_network(value, strict=False)
            if net.version == 4:
                v4.add(str(net))
            else:
                v6.add(str(net))
        else:
            ip = ipaddress.ip_address(value)
            if ip.version == 4:
                v4.add(str(ip))
            else:
                v6.add(str(ip))
    except ValueError:
        unsupported.append("INVALID-IP,%s" % value)


def clean_domain(value):
    value = value.strip().strip("'\"").strip(".").lower()
    if not value or "/" in value or ":" in value or "*" in value:
        return ""
    try:
        return value.encode("idna").decode("ascii")
    except Exception:
        return ""


def resolve_domain(domain):
    addresses = set()
    try:
        for family in (socket.AF_INET, socket.AF_INET6):
            try:
                infos = socket.getaddrinfo(domain, None, family, socket.SOCK_STREAM)
            except socket.gaierror:
                continue
            for item in infos:
                ip = item[4][0]
                addresses.add(ip)
    except Exception:
        pass
    return domain, addresses


with open(raw_path, "r", encoding="utf-8", errors="ignore") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#") or line == "payload:":
            continue
        if line.startswith("- "):
            line = line[2:].strip()
        line = line.strip("'\"")
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2:
            unsupported.append("UNKNOWN,%s" % line)
            continue
        typ = parts[0].upper()
        value = parts[1]
        rules += 1
        if typ in ("IP-CIDR", "IP-CIDR6"):
            add_ip_or_cidr(value)
        elif typ in ("DOMAIN", "DOMAIN-SUFFIX"):
            domain = clean_domain(value)
            if not domain:
                unsupported.append("%s,%s" % (typ, value))
                continue
            domains_seen += 1
            if limit and domains_tried >= limit:
                unsupported.append("DOMAIN-OVER-LIMIT,%s" % domain)
                continue
            candidates = [domain]
            if typ == "DOMAIN-SUFFIX" and not domain.startswith("www."):
                candidates.append("www." + domain)
            for item in candidates:
                if limit and domains_tried >= limit:
                    unsupported.append("DOMAIN-OVER-LIMIT,%s" % item)
                    continue
                domains.append(item)
                domains_tried += 1
        else:
            unsupported.append("%s,%s" % (typ, value))


unique_domains = list(dict.fromkeys(domains))
if unique_domains:
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(dns_workers, len(unique_domains))) as executor:
        for domain, addresses in executor.map(resolve_domain, unique_domains):
            if addresses:
                resolved_domains += 1
                for address in addresses:
                    add_ip_or_cidr(address)
            else:
                unsupported.append("UNRESOLVED,%s" % domain)


def write_lines(path, values):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as out:
        for item in sorted(values):
            out.write("%s\n" % item)
    os.replace(tmp, path)


def collapse_ip_entries(values, version):
    nets = []
    for value in values:
        try:
            if "/" in value:
                net = ipaddress.ip_network(value, strict=False)
            else:
                suffix = 32 if version == 4 else 128
                net = ipaddress.ip_network("%s/%s" % (value, suffix), strict=False)
            if net.version == version:
                nets.append(net)
        except ValueError:
            unsupported.append("INVALID-IP,%s" % value)
    return [str(item) for item in ipaddress.collapse_addresses(nets)]


v4_out = collapse_ip_entries(v4, 4)
v6_out = collapse_ip_entries(v6, 6)
write_lines(v4_path, v4_out)
write_lines(v6_path, v6_out)
write_lines(domains_path, domains)
write_lines(unsupported_path, unsupported)
with open(stats_path + ".tmp", "w", encoding="utf-8") as out:
    out.write("updated_at=%s\n" % datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    out.write("rules=%s\n" % rules)
    out.write("domains_seen=%s\n" % domains_seen)
    out.write("domains_tried=%s\n" % domains_tried)
    out.write("domains_resolved=%s\n" % resolved_domains)
    out.write("ipv4=%s\n" % len(v4_out))
    out.write("ipv6=%s\n" % len(v6_out))
    out.write("unsupported=%s\n" % len(unsupported))
os.replace(stats_path + ".tmp", stats_path)
for path in (v4_path, v6_path, domains_path, unsupported_path, stats_path):
    os.chmod(path, 0o600)
PY
}

split_app_has_policy() {
    [ -n "$(split_policy_target "$1")" ]
}

split_sync_app_cache() {
    local app="$1" display="$2" remote="$3"
    if split_download_app "$app" "$remote"; then
        return 0
    fi
    if [ -s "$(split_raw_file "$app")" ]; then
        warn "下载失败，继续使用本地缓存: $display"
        return 0
    fi
    warn "下载失败且没有本地缓存: $display"
    return 1
}

split_prepare_app_rules() {
    local app="$1" display remote rc=0
    split_cache_lock_acquire
    display="$(split_app_display "$app")"
    remote="$(split_app_remote "$app")"
    info "准备应用分流规则: $display"
    if ! split_sync_app_cache "$app" "$display" "$remote"; then
        split_cache_lock_release
        return 1
    fi
    split_parse_app_rules "$app" || rc=$?
    split_cache_lock_release
    return "$rc"
}

split_sync() {
    need_root
    load_config
    write_default_config
    need_cmd python3
    local mode="${1:-}" now last age parsed fail
    if [ "${ENABLE_SPLIT_RULES:-true}" != "true" ]; then
        info "应用分流未启用，跳过规则更新。"
        return 0
    fi
    if ! split_catalog_ready; then
        if [ "$mode" = "--auto" ]; then
            return 0
        fi
        die "尚未同步应用目录。请先进入“分流管理”选择 1，或执行: $0 split-fetch"
    fi
    now="$(date +%s)"
    if [ "$mode" = "--auto" ] && [ -f "$SPLIT_LAST_SYNC_FILE" ]; then
        last="$(cat "$SPLIT_LAST_SYNC_FILE" 2>/dev/null || printf '0')"
        age=$((now - ${last:-0}))
        if [ "$age" -lt "${SPLIT_UPDATE_INTERVAL:-259200}" ]; then
            return 0
        fi
    fi
    split_fetch_all_rules catalog
    split_cache_lock_acquire
    state_lock_acquire
    mark_nft_pending
    state_lock_release
    split_reconcile_category_policies
    IFS=$'\t' read -r parsed fail <<< "$(split_parse_policy_apps)"
    do_apply_nftables
    printf '%s\n' "$now" > "$SPLIT_LAST_SYNC_FILE"
    chmod 600 "$SPLIT_LAST_SYNC_FILE"
    split_cache_lock_release
    info "已更新已启用的分流规则：解析下发 $parsed 个应用，失败 $fail 个。"
}

split_write_policy_value() {
    local app="$1" resolved="$2" tmp found="false" line row_app row_target
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_app row_target <<< "$line"
        if [ "$row_app" = "$app" ]; then
            printf '%s\t%s\n' "$app" "$resolved" >> "$tmp"
            found="true"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$SPLIT_POLICIES_FILE"
    if [ "$found" != "true" ]; then
        printf '%s\t%s\n' "$app" "$resolved" >> "$tmp"
    fi
    install -m 0600 "$tmp" "$SPLIT_POLICIES_FILE"
    rm -f "$tmp"
}

split_write_category_policy_value() {
    local category="$1" resolved="$2" tmp found="false" line row_category row_target
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_category row_target <<< "$line"
        if [ "$row_category" = "$category" ]; then
            printf '%s\t%s\n' "$category" "$resolved" >> "$tmp"
            found="true"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$SPLIT_CATEGORY_POLICIES_FILE"
    if [ "$found" != "true" ]; then
        printf '%s\t%s\n' "$category" "$resolved" >> "$tmp"
    fi
    install -m 0600 "$tmp" "$SPLIT_CATEGORY_POLICIES_FILE"
    rm -f "$tmp"
}

force_write_app_value() {
    local app="$1" tmp found="false" line row_app
    tmp="$(mktemp)"
    [ -f "$SPLIT_FORCE_POLICIES_FILE" ] || write_default_config
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_app <<< "$line"
        if [ "$row_app" = "$app" ]; then
            found="true"
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$SPLIT_FORCE_POLICIES_FILE"
    if [ "$found" != "true" ]; then
        printf '%s\n' "$app" >> "$tmp"
    fi
    install -m 0600 "$tmp" "$SPLIT_FORCE_POLICIES_FILE"
    rm -f "$tmp"
}

force_write_category_value() {
    local category="$1" tmp found="false" line row_category
    tmp="$(mktemp)"
    [ -f "$SPLIT_FORCE_CATEGORY_POLICIES_FILE" ] || write_default_config
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_category <<< "$line"
        if [ "$row_category" = "$category" ]; then
            found="true"
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$SPLIT_FORCE_CATEGORY_POLICIES_FILE"
    if [ "$found" != "true" ]; then
        printf '%s\n' "$category" >> "$tmp"
    fi
    install -m 0600 "$tmp" "$SPLIT_FORCE_CATEGORY_POLICIES_FILE"
    rm -f "$tmp"
}

force_clear_app_value() {
    local app="$1" tmp removed="false" line row_app
    [ -f "$SPLIT_FORCE_POLICIES_FILE" ] || return 0
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_app <<< "$line"
        if [ "$row_app" = "$app" ]; then
            removed="true"
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$SPLIT_FORCE_POLICIES_FILE"
    install -m 0600 "$tmp" "$SPLIT_FORCE_POLICIES_FILE"
    rm -f "$tmp"
    [ "$removed" = "true" ]
}

force_clear_category_value() {
    local category="$1" tmp removed="false" line row_category
    [ -f "$SPLIT_FORCE_CATEGORY_POLICIES_FILE" ] || return 0
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_category <<< "$line"
        if [ "$row_category" = "$category" ]; then
            removed="true"
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$SPLIT_FORCE_CATEGORY_POLICIES_FILE"
    install -m 0600 "$tmp" "$SPLIT_FORCE_CATEGORY_POLICIES_FILE"
    rm -f "$tmp"
    [ "$removed" = "true" ]
}

force_on_exit_write_value() {
    local file="$1" key="$2" source="$3" target="$4" tmp line row_key row_source row_target found="false"
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_key row_source row_target <<< "$line"
        if [ "$row_key" = "$key" ] && [ "$row_source" = "$source" ]; then
            printf '%s\t%s\t%s\n' "$key" "$source" "$target" >> "$tmp"
            found="true"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$file"
    [ "$found" = "true" ] || printf '%s\t%s\t%s\n' "$key" "$source" "$target" >> "$tmp"
    install -m 0600 "$tmp" "$file"
    rm -f "$tmp"
}

force_on_exit_clear_value() {
    local file="$1" key="$2" source="$3" tmp line row_key row_source row_target removed="false"
    [ -f "$file" ] || return 1
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_key row_source row_target <<< "$line"
        if [ "$row_key" = "$key" ] && [ "$row_source" = "$source" ]; then
            removed="true"
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    install -m 0600 "$tmp" "$file"
    rm -f "$tmp"
    [ "$removed" = "true" ]
}

split_reconcile_category_policies() {
    state_lock_acquire
    python3 - "$SPLIT_APPS_FILE" "$SPLIT_CATEGORY_POLICIES_FILE" "$SPLIT_POLICIES_FILE" <<'PY'
import os
import tempfile
import sys

apps_path, categories_path, policies_path = sys.argv[1:4]
categories = {}
with open(categories_path, "r", encoding="utf-8", errors="ignore") as fh:
    for raw in fh:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[0] and not parts[0].startswith("#"):
            categories[parts[0]] = parts[1]

rows = []
existing = set()
if os.path.exists(policies_path):
    with open(policies_path, "r", encoding="utf-8", errors="ignore") as fh:
        rows = list(fh)
    for raw in rows:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[0] and not parts[0].startswith("#"):
            existing.add(parts[0])

additions = []
with open(apps_path, "r", encoding="utf-8", errors="ignore") as fh:
    for raw in fh:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) >= 3 and parts[0] not in existing and parts[2] in categories:
            additions.append("%s\t%s\n" % (parts[0], categories[parts[2]]))

if additions:
    fd, tmp = tempfile.mkstemp(prefix="policies.", dir=os.path.dirname(policies_path))
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.writelines(rows)
        out.writelines(additions)
    os.chmod(tmp, 0o600)
    os.replace(tmp, policies_path)
PY
    state_lock_release
}

split_bulk_set_category_apps() {
    local category="$1" target="$2"
    state_lock_acquire
    python3 - "$SPLIT_APPS_FILE" "$SPLIT_POLICIES_FILE" "$category" "$target" <<'PY'
import os
import tempfile
import sys

apps_path, policies_path, category, target = sys.argv[1:5]
apps = []
with open(apps_path, "r", encoding="utf-8", errors="ignore") as fh:
    for raw in fh:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) >= 3 and parts[2] == category:
            apps.append(parts[0])
wanted = set(apps)
rows = []
seen = set()
if os.path.exists(policies_path):
    with open(policies_path, "r", encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            parts = raw.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0] in wanted:
                rows.append("%s\t%s\n" % (parts[0], target))
                seen.add(parts[0])
            else:
                rows.append(raw)
for app in apps:
    if app not in seen:
        rows.append("%s\t%s\n" % (app, target))
fd, tmp = tempfile.mkstemp(prefix="policies.", dir=os.path.dirname(policies_path))
with os.fdopen(fd, "w", encoding="utf-8") as out:
    out.writelines(rows)
os.chmod(tmp, 0o600)
os.replace(tmp, policies_path)
print(len(apps))
PY
    state_lock_release
}

cleanup_container_split_policies_for_category_targets() {
    local category="$1" allowed="$2" removed
    [ -f "$SPLIT_CONTAINER_POLICIES_FILE" ] || return 0
    state_lock_acquire
    removed="$(python3 - "$SPLIT_APPS_FILE" "$SPLIT_CONTAINER_POLICIES_FILE" "$category" "$allowed" <<'PY'
import os
import tempfile
import sys

apps_path, policies_path, category, allowed_raw = sys.argv[1:5]
allowed = {item for item in allowed_raw.split(",") if item}
apps = set()
with open(apps_path, "r", encoding="utf-8", errors="ignore") as fh:
    for raw in fh:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) >= 3 and parts[2] == category:
            apps.add(parts[0])
rows = []
removed = 0
with open(policies_path, "r", encoding="utf-8", errors="ignore") as fh:
    for raw in fh:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) >= 3 and parts[1] in apps and parts[2] not in allowed:
            removed += 1
            continue
        rows.append(raw)
fd, tmp = tempfile.mkstemp(prefix="container-policies.", dir=os.path.dirname(policies_path))
with os.fdopen(fd, "w", encoding="utf-8") as out:
    out.writelines(rows)
os.chmod(tmp, 0o600)
os.replace(tmp, policies_path)
print(removed)
PY
)"
    state_lock_release
    [ "${removed:-0}" -eq 0 ] || info "已清理 $removed 条不在候选出口内的容器级覆盖。"
}

split_set_policy() {
    need_root
    load_config
    write_default_config
    local app="${1:-}" resolved
    split_require_catalog
    [ -n "$app" ] || die "用法: $0 split-set 应用ID 目标出口[,候选出口...]"
    shift || true
    [ "$#" -gt 0 ] || die "用法: $0 split-set 应用ID 目标出口[,候选出口...]"
    split_app_exists "$app" || die "未知应用: $app"
    resolved="$(resolve_split_target_list "$@")" || die "存在未知出口: $*"
    split_prepare_app_rules "$app"
    state_lock_acquire
    mark_nft_pending
    split_write_policy_value "$app" "$resolved"
    cleanup_container_split_policies_for_app_targets "$app" "$resolved"
    cleanup_container_split_policies_for_container_allowed
    do_apply_nftables
    state_lock_release
    info "已设置应用分流：$(split_app_display "$app") -> $(split_target_list_label "$resolved")"
}

split_set_category_policy() {
    need_root
    load_config
    write_default_config
    local target_category="${1:-}" resolved app display app_category remote enabled count=0
    split_require_catalog
    [ -n "$target_category" ] || die "用法: $0 split-set-category 分类 目标出口[,候选出口...]"
    shift || true
    [ "$#" -gt 0 ] || die "用法: $0 split-set-category 分类 目标出口[,候选出口...]"
    resolved="$(resolve_split_target_list "$@")" || die "存在未知出口: $*"
    split_category_exists "$target_category" || die "未找到分类: $target_category"
    while IFS=$'\t' read -r app display app_category remote enabled; do
        [ "$app_category" = "$target_category" ] || continue
        split_prepare_app_rules "$app" || true
    done < <(read_split_apps)
    state_lock_acquire
    mark_nft_pending
    split_write_category_policy_value "$target_category" "$resolved"
    count="$(split_bulk_set_category_apps "$target_category" "$resolved")"
    cleanup_container_split_policies_for_category_targets "$target_category" "$resolved"
    cleanup_container_split_policies_for_container_allowed
    do_apply_nftables
    state_lock_release
    info "已设置分类分流：$target_category -> $(split_target_list_label "$resolved")，共 $count 个应用。"
}

split_force_on_exit_policy() {
    need_root
    load_config
    write_default_config
    local apps_input="${1:-}" sources_input="${2:-}" targets_input="${3:-}" app source target resolved_sources="" resolved_targets="" item comma
    local apps=() sources=() targets=()
    split_require_catalog
    [ -n "$apps_input" ] && [ -n "$sources_input" ] && [ -n "$targets_input" ] || die "用法: $0 split-force-on-exit 应用ID列表 来源出口列表 目标出口列表"
    IFS=',' read -r -a apps <<< "$apps_input"; IFS=',' read -r -a sources <<< "$sources_input"; IFS=',' read -r -a targets <<< "$targets_input"
    for app in "${apps[@]}"; do app="$(trim_space "$app")"; split_app_exists "$app" || die "未知应用: $app"; split_prepare_app_rules "$app"; done
    for item in "${sources[@]}"; do item="$(trim_space "$item")"; source="$(resolve_exit_target "$item")" || die "未知来源出口: $item"; comma=""; [ -n "$resolved_sources" ] && comma=","; case ",$resolved_sources," in *,"$source",*) ;; *) resolved_sources="$resolved_sources$comma$source" ;; esac; done
    for item in "${targets[@]}"; do item="$(trim_space "$item")"; target="$(resolve_exit_target "$item")" || die "未知目标出口: $item"; comma=""; [ -n "$resolved_targets" ] && comma=","; case ",$resolved_targets," in *,"$target",*) ;; *) resolved_targets="$resolved_targets$comma$target" ;; esac; done
    state_lock_acquire
    mark_nft_pending
    IFS=',' read -r -a sources <<< "$resolved_sources"
    for app in "${apps[@]}"; do app="$(trim_space "$app")"; for source in "${sources[@]}"; do force_on_exit_write_value "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" "$app" "$source" "$resolved_targets"; done; done
    do_apply_nftables
    state_lock_release
    info "已批量设置按出口强制应用分流：应用 ${#apps[@]} 个，来源 $(split_target_list_label "$resolved_sources") -> 目标候选 $(split_target_list_label "$resolved_targets")（第一个为实际目标）"
}

split_force_category_on_exit_policy() {
    need_root
    load_config
    write_default_config
    local categories_input="${1:-}" sources_input="${2:-}" targets_input="${3:-}" category source target app display app_category remote enabled count=0 item comma resolved_sources="" resolved_targets=""
    local categories=() sources=() targets=()
    split_require_catalog
    [ -n "$categories_input" ] && [ -n "$sources_input" ] && [ -n "$targets_input" ] || die "用法: $0 split-force-category-on-exit 分类列表 来源出口列表 目标出口列表"
    IFS=',' read -r -a categories <<< "$categories_input"; IFS=',' read -r -a sources <<< "$sources_input"; IFS=',' read -r -a targets <<< "$targets_input"
    for category in "${categories[@]}"; do category="$(trim_space "$category")"; split_category_exists "$category" || die "未找到分类: $category"; done
    for item in "${sources[@]}"; do item="$(trim_space "$item")"; source="$(resolve_exit_target "$item")" || die "未知来源出口: $item"; comma=""; [ -n "$resolved_sources" ] && comma=","; case ",$resolved_sources," in *,"$source",*) ;; *) resolved_sources="$resolved_sources$comma$source" ;; esac; done
    for item in "${targets[@]}"; do item="$(trim_space "$item")"; target="$(resolve_exit_target "$item")" || die "未知目标出口: $item"; comma=""; [ -n "$resolved_targets" ] && comma=","; case ",$resolved_targets," in *,"$target",*) ;; *) resolved_targets="$resolved_targets$comma$target" ;; esac; done
    while IFS=$'\t' read -r app display app_category remote enabled; do
        case ",$categories_input," in *,"$app_category",*) ;; *) continue ;; esac
        split_prepare_app_rules "$app" || true
        count=$((count + 1))
    done < <(read_split_apps)
    state_lock_acquire
    mark_nft_pending
    IFS=',' read -r -a sources <<< "$resolved_sources"
    for category in "${categories[@]}"; do category="$(trim_space "$category")"; for source in "${sources[@]}"; do force_on_exit_write_value "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE" "$category" "$source" "$resolved_targets"; done; done
    do_apply_nftables
    state_lock_release
    info "已批量设置按出口强制分类分流：分类 ${#categories[@]} 个，来源 $(split_target_list_label "$resolved_sources") -> 目标候选 $(split_target_list_label "$resolved_targets")（第一个为实际目标），共 $count 个应用。"
}

split_force_on_exit_clear_policy() {
    need_root
    load_config
    write_default_config
    local apps_input="${1:-}" sources_input="${2:-}" app source item removed="false"
    local apps=() sources=()
    split_require_catalog
    [ -n "$apps_input" ] && [ -n "$sources_input" ] || die "用法: $0 split-force-on-exit-clear 应用ID列表 来源出口列表"
    IFS=',' read -r -a apps <<< "$apps_input"; IFS=',' read -r -a sources <<< "$sources_input"
    for app in "${apps[@]}"; do app="$(trim_space "$app")"; split_app_exists "$app" || die "未知应用: $app"; done
    state_lock_acquire
    mark_nft_pending
    for app in "${apps[@]}"; do app="$(trim_space "$app")"; for item in "${sources[@]}"; do item="$(trim_space "$item")"; source="$(resolve_exit_target "$item")" || die "未知来源出口: $item"; force_on_exit_clear_value "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" "$app" "$source" && removed="true" || true; done; done
    do_apply_nftables
    state_lock_release
    [ "$removed" = "true" ] && info "已批量取消对应的按出口强制应用分流。" || info "未找到对应的按出口强制应用分流。"
}

split_force_category_on_exit_clear_policy() {
    need_root
    load_config
    write_default_config
    local categories_input="${1:-}" sources_input="${2:-}" category source item removed="false"
    local categories=() sources=()
    split_require_catalog
    [ -n "$categories_input" ] && [ -n "$sources_input" ] || die "用法: $0 split-force-category-on-exit-clear 分类列表 来源出口列表"
    IFS=',' read -r -a categories <<< "$categories_input"; IFS=',' read -r -a sources <<< "$sources_input"
    for category in "${categories[@]}"; do category="$(trim_space "$category")"; split_category_exists "$category" || die "未找到分类: $category"; done
    state_lock_acquire
    mark_nft_pending
    for category in "${categories[@]}"; do category="$(trim_space "$category")"; for item in "${sources[@]}"; do item="$(trim_space "$item")"; source="$(resolve_exit_target "$item")" || die "未知来源出口: $item"; force_on_exit_clear_value "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE" "$category" "$source" && removed="true" || true; done; done
    do_apply_nftables
    state_lock_release
    [ "$removed" = "true" ] && info "已批量取消对应的按出口强制分类分流。" || info "未找到对应的按出口强制分类分流。"
}

split_force_policy() {
    need_root
    load_config
    write_default_config
    local app="${1:-}" target="${2:-}" resolved
    split_require_catalog
    [ -n "$app" ] && [ -n "$target" ] || die "用法: $0 split-force 应用ID 目标出口"
    split_app_exists "$app" || die "未知应用: $app"
    resolved="$(resolve_exit_target "$target")" || die "未知出口: $target"
    split_prepare_app_rules "$app"
    state_lock_acquire
    mark_nft_pending
    split_write_policy_value "$app" "$resolved"
    force_write_app_value "$app"
    cleanup_container_split_policies_for_app_targets "$app" "$resolved"
    cleanup_container_split_policies_for_container_allowed
    do_apply_nftables
    state_lock_release
    info "已设置强制应用分流：$(split_app_display "$app") -> $(display_exit_name "$resolved")"
}

split_force_category_policy() {
    need_root
    load_config
    write_default_config
    local target_category="${1:-}" target="${2:-}" resolved app display app_category remote enabled count=0
    split_require_catalog
    [ -n "$target_category" ] && [ -n "$target" ] || die "用法: $0 split-force-category 分类 目标出口"
    split_category_exists "$target_category" || die "未找到分类: $target_category"
    resolved="$(resolve_exit_target "$target")" || die "未知出口: $target"
    while IFS=$'\t' read -r app display app_category remote enabled; do
        [ "$app_category" = "$target_category" ] || continue
        split_prepare_app_rules "$app" || true
    done < <(read_split_apps)
    state_lock_acquire
    mark_nft_pending
    split_write_category_policy_value "$target_category" "$resolved"
    force_write_category_value "$target_category"
    count="$(split_bulk_set_category_apps "$target_category" "$resolved")"
    cleanup_container_split_policies_for_category_targets "$target_category" "$resolved"
    cleanup_container_split_policies_for_container_allowed
    do_apply_nftables
    state_lock_release
    info "已设置强制分类分流：$target_category -> $(display_exit_name "$resolved")，共 $count 个应用。"
}

split_clear_category_policy() {
    need_root
    load_config
    write_default_config
    local target_category="${1:-}" tmp removed="false" line row_category row_target app display app_category remote enabled target
    split_require_catalog
    [ -n "$target_category" ] || die "用法: $0 split-clear-category 分类"
    split_category_exists "$target_category" || die "未找到分类: $target_category"
    state_lock_acquire
    mark_nft_pending
    target="$(split_category_policy_targets "$target_category")"
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_category row_target <<< "$line"
        if [ "$row_category" = "$target_category" ]; then
            removed="true"
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$SPLIT_CATEGORY_POLICIES_FILE"
    install -m 0600 "$tmp" "$SPLIT_CATEGORY_POLICIES_FILE"
    rm -f "$tmp"

    if [ -n "$target" ]; then
        tmp="$(mktemp)"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
            esac
            IFS=$'\t' read -r app row_target <<< "$line"
            app_category="$(split_app_category "$app")"
            if [ "$app_category" = "$target_category" ] && [ "$row_target" = "$target" ]; then
                continue
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$SPLIT_POLICIES_FILE"
        install -m 0600 "$tmp" "$SPLIT_POLICIES_FILE"
        rm -f "$tmp"
    fi
    force_clear_category_value "$target_category" >/dev/null 2>&1 || true
    while IFS=$'\t' read -r app display app_category remote enabled; do
        [ "$app_category" = "$target_category" ] || continue
        force_clear_app_value "$app" >/dev/null 2>&1 || true
    done < <(read_split_apps)
    do_apply_nftables
    if [ "$removed" = "true" ]; then
        info "已取消分类分流：$target_category"
    else
        info "该分类没有设置分流策略：$target_category"
    fi
    state_lock_release
}

split_clear_policy() {
    need_root
    load_config
    write_default_config
    local app="${1:-}" tmp removed="false"
    split_require_catalog
    [ -n "$app" ] || die "用法: $0 split-clear 应用ID"
    split_app_exists "$app" || die "未知应用: $app"
    state_lock_acquire
    mark_nft_pending
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_app row_target <<< "$line"
        if [ "$row_app" = "$app" ]; then
            removed="true"
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$SPLIT_POLICIES_FILE"
    install -m 0600 "$tmp" "$SPLIT_POLICIES_FILE"
    rm -f "$tmp"
    force_clear_app_value "$app" >/dev/null 2>&1 || true
    do_apply_nftables
    if [ "$removed" = "true" ]; then
        info "已取消应用分流：$(split_app_display "$app")"
    else
        info "该应用没有设置分流策略：$(split_app_display "$app")"
    fi
    state_lock_release
}

split_clear_all_rules() {
    need_root
    load_config
    write_default_config
    split_cache_lock_acquire
    state_lock_acquire
    mark_nft_pending
    local app_policies category_policies container_policies force_apps force_categories custom_apps tmp
    app_policies="$(read_split_policies | awk 'END {print NR + 0}')"
    category_policies="$(read_split_category_policies | awk 'END {print NR + 0}')"
    container_policies="$(read_container_split_policies | awk 'END {print NR + 0}')"
    force_apps="$(read_force_split_policies | awk 'END {print NR + 0}')"
    force_categories="$(read_force_split_category_policies | awk 'END {print NR + 0}')"
    custom_apps="$(read_split_apps | awk -F '\t' '$4 ~ /^custom:/ {n++} END {print n + 0}')"

    cat > "$SPLIT_POLICIES_FILE" <<'EOF'
# 应用分流策略，每行一条：
# app_id  目标出口候选列表
EOF
    cat > "$SPLIT_CATEGORY_POLICIES_FILE" <<'EOF'
# 分类分流策略，每行一条：
# 分类  目标出口候选列表
EOF
    cat > "$SPLIT_CONTAINER_POLICIES_FILE" <<'EOF'
# 容器级分流覆盖，每行一条：
# 容器名  app_id  目标出口
EOF
    cat > "$SPLIT_FORCE_POLICIES_FILE" <<'EOF'
# 强制应用分流，每行一个 app_id。
EOF
    cat > "$SPLIT_FORCE_CATEGORY_POLICIES_FILE" <<'EOF'
# 强制分类分流，每行一个分类名。
EOF
    cat > "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" <<'EOF'
# 按当前出口强制应用分流：app_id  来源出口  目标出口
EOF
    cat > "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE" <<'EOF'
# 按当前出口强制分类分流：分类  来源出口  目标出口
EOF
    chmod 600 "$SPLIT_POLICIES_FILE" "$SPLIT_CATEGORY_POLICIES_FILE" "$SPLIT_CONTAINER_POLICIES_FILE" "$SPLIT_FORCE_POLICIES_FILE" "$SPLIT_FORCE_CATEGORY_POLICIES_FILE" "$SPLIT_FORCE_ON_EXIT_POLICIES_FILE" "$SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE"

    if [ -f "$SPLIT_APPS_FILE" ]; then
        tmp="$(mktemp)"
        awk -F '\t' 'BEGIN {OFS=FS} /^#/ || !NF {print; next} $4 !~ /^custom:/ {print}' "$SPLIT_APPS_FILE" > "$tmp"
        install -m 0600 "$tmp" "$SPLIT_APPS_FILE"
        rm -f "$tmp"
    fi

    mkdir -p "$SPLIT_RAW_DIR" "$SPLIT_RESOLVED_DIR"
    find "$SPLIT_RAW_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    find "$SPLIT_RESOLVED_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    rm -f "$SPLIT_LAST_SYNC_FILE"
    do_apply_nftables
    state_lock_release
    split_cache_lock_release
    info "已清空全部分流规则：应用策略 $app_policies 条，分类策略 $category_policies 条，容器覆盖 $container_policies 条，强制应用 $force_apps 条，强制分类 $force_categories 条，自定义规则 $custom_apps 条。"
    info "应用目录仍保留，可继续按需重新添加应用/分类分流。"
}

split_prepare_one() {
    need_root
    load_config
    write_default_config
    local app="${1:-}"
    [ -n "$app" ] || die "用法: $0 split-prepare 应用ID"
    split_require_catalog
    split_app_exists "$app" || die "未知应用: $app"
    split_prepare_app_rules "$app"
    do_apply_nftables
    info "已准备应用分流规则：$(split_app_display "$app")"
}

# 容器切换应用分流时只在缓存缺失时下载；已有规则不重复访问 GitHub 或解析 DNS。
split_ensure_one() {
    need_root
    load_config
    write_default_config
    local app="${1:-}" stats
    [ -n "$app" ] || die "用法: $0 split-ensure 应用ID"
    split_require_catalog
    split_app_exists "$app" || die "未知应用: $app"
    stats="$SPLIT_RESOLVED_DIR/$app.stats"
    if [ -f "$stats" ] && { [ -f "$(split_resolved_v4_file "$app")" ] || [ -f "$(split_resolved_v6_file "$app")" ]; }; then
        return 0
    fi
    if [ -s "$(split_raw_file "$app")" ]; then
        split_cache_lock_acquire
        split_parse_app_rules "$app"
        split_cache_lock_release
    else
        split_prepare_app_rules "$app"
    fi
}

split_refresh_cached_dns() {
    need_root
    load_config
    write_default_config
    local app parsed=0 failed=0
    split_cache_lock_acquire
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        if [ -s "$(split_raw_file "$app")" ] && split_parse_app_rules "$app"; then
            parsed=$((parsed + 1))
        else
            failed=$((failed + 1))
        fi
    done < <(read_enabled_split_app_ids)
    split_cache_lock_release
    if [ "$parsed" -gt 0 ]; then
        do_apply_nftables
    fi
    info "已用本地缓存刷新分流域名：成功 $parsed 个，失败/无缓存 $failed 个；未访问 GitHub。"
}

split_make_custom_app_id() {
    local display="$1"
    python3 - "$display" "$SPLIT_APPS_FILE" <<'PY'
import hashlib
import os
import re
import sys

display, apps_file = sys.argv[1:3]
base = re.sub(r"[^A-Za-z0-9_.-]+", "-", display).strip("-._")
digest = hashlib.sha1(display.encode("utf-8")).hexdigest()[:8]
if not base:
    base = "custom"
if not re.match(r"^[A-Za-z]", base):
    base = "custom-" + base
base = base[:40].strip("-._") or "custom"
candidate = "custom_%s_%s" % (base, digest)
existing = set()
if os.path.exists(apps_file):
    with open(apps_file, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            if not line.strip() or line.startswith("#"):
                continue
            existing.add(line.split("\t", 1)[0])
if candidate not in existing:
    print(candidate)
    raise SystemExit(0)
i = 2
while "%s_%s" % (candidate, i) in existing:
    i += 1
print("%s_%s" % (candidate, i))
PY
}

split_write_app_catalog_row() {
    local app="$1" display="$2" category="$3" remote="$4" enabled="${5:-true}" tmp found="false" line row_app
    tmp="$(mktemp)"
    [ -f "$SPLIT_APPS_FILE" ] || write_default_config
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        IFS=$'\t' read -r row_app _rest <<< "$line"
        if [ "$row_app" = "$app" ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$app" "$display" "$category" "$remote" "$enabled" >> "$tmp"
            found="true"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$SPLIT_APPS_FILE"
    if [ "$found" != "true" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$app" "$display" "$category" "$remote" "$enabled" >> "$tmp"
    fi
    install -m 0600 "$tmp" "$SPLIT_APPS_FILE"
    rm -f "$tmp"
}

split_add_custom_rule() {
    need_root
    load_config
    write_default_config
    need_cmd python3
    split_require_catalog
    local display="${1:-}" category="${2:-自定义}" input_file="${3:-}" app raw tmp normalized_count
    [ -n "$display" ] || die "用法: $0 split-add-custom 应用名 [分类] < rules.txt"
    display="$(printf '%s' "$display" | tr '\t\r\n' '   ')"
    category="$(printf '%s' "${category:-自定义}" | tr '\t\r\n' '   ')"
    app="$(split_make_custom_app_id "$display")"
    raw="$(split_raw_file "$app")"
    tmp="$(mktemp)"
    if [ -n "$input_file" ]; then
        [ -f "$input_file" ] || die "找不到自定义规则文件: $input_file"
        cat "$input_file" > "$tmp"
    else
        cat > "$tmp"
    fi
    split_cache_lock_acquire
    mkdir -p "$SPLIT_RAW_DIR" "$SPLIT_RESOLVED_DIR"
    if ! normalized_count="$(python3 - "$tmp" "$raw" <<'PY'
import ipaddress
import os
import re
import sys

src, dst = sys.argv[1:3]
allowed_types = {"DOMAIN", "DOMAIN-SUFFIX", "IP-CIDR", "IP-CIDR6"}
domain_re = re.compile(r"^(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]{2,}$")
out = []
errors = []


def clean_domain(value):
    value = value.strip().strip("'\"").strip(".").lower()
    if value.startswith("*."):
        value = value[2:]
    try:
        value = value.encode("idna").decode("ascii")
    except Exception:
        return ""
    if not domain_re.match(value):
        return ""
    return value


def add_rule(kind, value, lineno):
    kind = kind.upper().strip()
    value = value.strip()
    if kind in ("IP-CIDR", "IP-CIDR6"):
        try:
            if "/" in value:
                net = ipaddress.ip_network(value, strict=False)
            else:
                ip = ipaddress.ip_address(value)
                net = ipaddress.ip_network("%s/%s" % (ip, 32 if ip.version == 4 else 128), strict=False)
        except ValueError:
            errors.append("第 %s 行 IP/IP段无效: %s" % (lineno, value))
            return
        expected = "IP-CIDR" if net.version == 4 else "IP-CIDR6"
        out.append("%s,%s" % (expected, net))
        return
    if kind in ("DOMAIN", "DOMAIN-SUFFIX"):
        domain = clean_domain(value)
        if not domain:
            errors.append("第 %s 行域名无效: %s" % (lineno, value))
            return
        out.append("%s,%s" % (kind, domain))
        return
    errors.append("第 %s 行类型不支持: %s" % (lineno, kind))


with open(src, "r", encoding="utf-8", errors="ignore") as fh:
    for lineno, raw in enumerate(fh, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "," in line:
            kind, value = line.split(",", 1)
            kind = kind.strip().upper()
            if kind in allowed_types:
                add_rule(kind, value, lineno)
                continue
        try:
            if "/" in line:
                net = ipaddress.ip_network(line, strict=False)
                out.append("%s,%s" % ("IP-CIDR" if net.version == 4 else "IP-CIDR6", net))
                continue
            ip = ipaddress.ip_address(line)
            out.append("%s,%s" % ("IP-CIDR" if ip.version == 4 else "IP-CIDR6", ip))
            continue
        except ValueError:
            pass
        domain = clean_domain(line)
        if domain:
            out.append("DOMAIN-SUFFIX,%s" % domain)
        else:
            errors.append("第 %s 行格式无法识别: %s" % (lineno, line))

if errors:
    for item in errors:
        print(item, file=sys.stderr)
    raise SystemExit(1)
if not out:
    print("没有有效规则。", file=sys.stderr)
    raise SystemExit(1)

deduped = []
seen = set()
for item in out:
    if item not in seen:
        deduped.append(item)
        seen.add(item)
tmp = dst + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("# custom rules\n")
    for item in deduped:
        fh.write(item + "\n")
os.replace(tmp, dst)
os.chmod(dst, 0o600)
print(len(deduped))
PY
)"; then
        rm -f "$tmp" "$raw.tmp"
        split_cache_lock_release
        die "自定义分流规则校验失败，未写入任何应用配置。"
    fi
    rm -f "$tmp"
    printf 'custom:%s\n' "$app" > "$raw.url"
    chmod 600 "$raw.url"
    state_lock_acquire
    mark_nft_pending
    split_write_app_catalog_row "$app" "$display" "$category" "custom:$app" true
    split_parse_app_rules "$app"
    do_apply_nftables
    state_lock_release
    split_cache_lock_release
    info "已添加自定义分流规则：$display（分类: $category，应用ID: $app，规则 $normalized_count 条）"
}

split_force_clear_policy() {
    need_root
    load_config
    write_default_config
    local app="${1:-}"
    split_require_catalog
    [ -n "$app" ] || die "用法: $0 split-force-clear 应用ID"
    split_app_exists "$app" || die "未知应用: $app"
    state_lock_acquire
    mark_nft_pending
    if force_clear_app_value "$app"; then
        info "已取消强制应用分流：$(split_app_display "$app")"
    else
        info "该应用没有强制分流：$(split_app_display "$app")"
    fi
    do_apply_nftables
    state_lock_release
}

split_force_clear_category_policy() {
    need_root
    load_config
    write_default_config
    local category="${1:-}"
    split_require_catalog
    [ -n "$category" ] || die "用法: $0 split-force-clear-category 分类"
    split_category_exists "$category" || die "未找到分类: $category"
    state_lock_acquire
    mark_nft_pending
    if force_clear_category_value "$category"; then
        info "已取消强制分类分流：$category"
    else
        info "该分类没有强制分流：$category"
    fi
    do_apply_nftables
    state_lock_release
}

split_list() {
    load_config
    write_default_config
    local app display category remote enabled target v4 v6 raw stats c_count force_apps force_categories force_on_exit force_category_on_exit source
    c_count="$(read_container_split_policies | awk 'END {print NR + 0}')"
    force_apps="$(read_force_split_policies | awk 'END {print NR + 0}')"
    force_categories="$(read_force_split_category_policies | awk 'END {print NR + 0}')"
    force_on_exit="$(read_force_on_exit_policies | awk 'END {print NR + 0}')"
    force_category_on_exit="$(read_force_category_on_exit_policies | awk 'END {print NR + 0}')"
    printf '应用分流状态: %s  单文件规则源: %s  更新间隔: %ss\n' "$ENABLE_SPLIT_RULES" "$SPLIT_RULE_BUNDLE_URL" "$SPLIT_UPDATE_INTERVAL"
    printf '域名动态命中: %s\n' "$(split_dnsmasq_status_label)"
    if split_catalog_ready; then
        printf '应用目录: 已同步\n'
    else
        printf '应用目录: 未同步，请先执行“分流管理 -> 1. 同步应用目录”。\n'
    fi
    if [ -f "$SPLIT_CATALOG_FILE" ]; then
        printf '目录同步: %s\n' "$(date -d "@$(cat "$SPLIT_CATALOG_FILE" 2>/dev/null || printf 0)" '+%F %T' 2>/dev/null || cat "$SPLIT_CATALOG_FILE")"
    else
        printf '目录同步: 从未\n'
    fi
    printf '容器级覆盖: %s 条\n' "$c_count"
    printf '强制分流: 应用 %s / 分类 %s\n' "$force_apps" "$force_categories"
    printf '按当前出口强制: 应用 %s / 分类 %s\n' "$force_on_exit" "$force_category_on_exit"
    if [ -f "$SPLIT_LAST_SYNC_FILE" ]; then
        printf '规则更新: %s\n' "$(date -d "@$(cat "$SPLIT_LAST_SYNC_FILE" 2>/dev/null || printf 0)" '+%F %T' 2>/dev/null || cat "$SPLIT_LAST_SYNC_FILE")"
    else
        printf '规则更新: 从未\n'
    fi
    printf '\n分类分流策略:\n'
    if [ -n "$(read_split_category_policies)" ]; then
        while IFS=$'\t' read -r category target; do
            printf '  %s -> %s\n' "$category" "$(split_target_list_label "$target")"
        done < <(read_split_category_policies)
    else
        printf '  暂无\n'
    fi
    printf '\n按当前出口强制:\n'
    if [ -n "$(read_force_on_exit_policies)$(read_force_category_on_exit_policies)" ]; then
        while IFS=$'\t' read -r category source target; do
            printf '  分类 %s：%s -> %s\n' "$category" "$(display_exit_name "$source")" "$(split_target_list_label "$target")"
        done < <(read_force_category_on_exit_policies)
        while IFS=$'\t' read -r app source target; do
            printf '  应用 %s：%s -> %s\n' "$(split_app_display "$app")" "$(display_exit_name "$source")" "$(split_target_list_label "$target")"
        done < <(read_force_on_exit_policies)
    else
        printf '  暂无\n'
    fi
    printf '\n强制分类:\n'
    if [ -n "$(read_force_split_category_policies)" ]; then
        while IFS= read -r category; do
            printf '  %s\n' "$category"
        done < <(read_force_split_category_policies)
    else
        printf '  暂无\n'
    fi
    printf '\n强制应用:\n'
    if [ -n "$(read_force_split_policies)" ]; then
        while IFS= read -r app; do
            printf '  %s -> %s\n' "$(split_app_display "$app")" "$(display_exit_name "$(split_policy_target "$app")")"
        done < <(read_force_split_policies)
    else
        printf '  暂无\n'
    fi
    if ! split_catalog_ready; then
        return 0
    fi
    printf '\n%-20s %-10s %-32s %-16s %-8s %-8s\n' "应用" "分类" "候选出口" "规则来源" "IPv4" "IPv6"
    while IFS=$'\t' read -r app display category remote enabled; do
        target="$(split_policy_target "$app")"
        v4="$(split_count_file "$(split_resolved_v4_file "$app")")"
        v6="$(split_count_file "$(split_resolved_v6_file "$app")")"
        printf '%-20s %-10s %-32s %-16s %-8s %-8s\n' "$display" "$category" "$(split_target_label "$(split_policy_targets "$app")")" "$remote" "$v4" "$v6"
    done < <(read_split_apps)
}

# 控制面服务。容器只能通过来源 IP + token 操作自己这一行配置，
# 不能提交其它容器 IP 来越权切换别人的出口。
write_controller() {
    mkdir -p "$LIB_DIR"
    local tmp
    tmp="$(mktemp "$LIB_DIR/controller.py.XXXXXX")"
    cat > "$tmp" <<'PY'
#!/usr/bin/env python3
import fcntl
import ipaddress
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_DIR = os.environ.get("EGRESS_CONFIG_DIR", "/etc/incus-egress-switch")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.env")
EXITS_FILE = os.path.join(CONFIG_DIR, "exits.tsv")
CONTAINERS_FILE = os.path.join(CONFIG_DIR, "containers.tsv")
SPLIT_DIR = os.path.join(CONFIG_DIR, "split")
SPLIT_APPS_FILE = os.path.join(SPLIT_DIR, "apps.tsv")
SPLIT_POLICIES_FILE = os.path.join(SPLIT_DIR, "policies.tsv")
SPLIT_CONTAINER_POLICIES_FILE = os.path.join(SPLIT_DIR, "container-policies.tsv")
SPLIT_FORCE_POLICIES_FILE = os.path.join(SPLIT_DIR, "force-policies.tsv")
SPLIT_FORCE_CATEGORY_POLICIES_FILE = os.path.join(SPLIT_DIR, "force-category-policies.tsv")
SPLIT_FORCE_ON_EXIT_POLICIES_FILE = os.path.join(SPLIT_DIR, "force-on-exit-policies.tsv")
SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE = os.path.join(SPLIT_DIR, "force-category-on-exit-policies.tsv")
MANAGER_BIN = os.environ.get("EGRESS_MANAGER_BIN", "/usr/local/sbin/incus-egress-switch")
STATE_LOCK_FILE = os.path.join(CONFIG_DIR, ".state.lock")
APPLY_LOCK_FILE = os.path.join("/run", "incus-egress-switch", "apply.lock")
PENDING_NFT_FILE = os.path.join(CONFIG_DIR, ".nft-apply-pending")


def read_env_file(path):
    data = {}
    if not os.path.exists(path):
        return data
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip().strip("'").strip('"')
            data[key.strip()] = value
    return data


CFG = read_env_file(CONFIG_FILE)
API_BIND = os.environ.get("API_BIND", CFG.get("API_BIND", "0.0.0.0"))
API_PORT = int(os.environ.get("API_PORT", CFG.get("API_PORT", "18988")))
NFT_TABLE = os.environ.get("NFT_TABLE", CFG.get("NFT_TABLE", "incus_egress_switch"))
STRICT_TOKEN = os.environ.get("STRICT_TOKEN", CFG.get("STRICT_TOKEN", "true")).lower() == "true"
SWITCH_CLEAR_CONNTRACK = os.environ.get("SWITCH_CLEAR_CONNTRACK", CFG.get("SWITCH_CLEAR_CONNTRACK", "true")).lower() == "true"
API_MAX_CONCURRENT = max(1, min(int(os.environ.get("API_MAX_CONCURRENT", CFG.get("API_MAX_CONCURRENT", "24"))), 32))
API_RATE_LIMIT = max(1, int(os.environ.get("API_RATE_LIMIT", CFG.get("API_RATE_LIMIT", "120"))))
API_MAX_BODY = max(256, int(os.environ.get("API_MAX_BODY", CFG.get("API_MAX_BODY", "4096"))))
API_SOCKET_TIMEOUT = max(2, int(os.environ.get("API_SOCKET_TIMEOUT", CFG.get("API_SOCKET_TIMEOUT", "15"))))
CONNTRACK_BIN = shutil.which("conntrack")
RATE_LOCK = threading.Lock()
RATE_BUCKETS = {}


@contextmanager
def file_lock(path, exclusive=True):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        yield


def rate_allowed(source):
    now = time.monotonic()
    with RATE_LOCK:
        start, count = RATE_BUCKETS.get(source, (now, 0))
        if now - start >= 60:
            start, count = now, 0
        count += 1
        RATE_BUCKETS[source] = (start, count)
        if len(RATE_BUCKETS) > 4096:
            cutoff = now - 120
            for key, value in list(RATE_BUCKETS.items()):
                if value[0] < cutoff:
                    RATE_BUCKETS.pop(key, None)
        return count <= API_RATE_LIMIT


def parse_rows(path, min_fields):
    rows = []
    if not os.path.exists(path):
        return rows
    with file_lock(STATE_LOCK_FILE, exclusive=False):
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                stripped = raw.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                parts = stripped.split()
                if len(parts) >= min_fields:
                    rows.append(parts)
    return rows


def parse_tsv_rows(path, min_fields):
    rows = []
    if not os.path.exists(path):
        return rows
    with file_lock(STATE_LOCK_FILE, exclusive=False):
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                stripped = raw.rstrip("\n")
                if not stripped.strip() or stripped.lstrip().startswith("#"):
                    continue
                parts = stripped.split("\t")
                if len(parts) >= min_fields:
                    rows.append(parts)
    return rows


def load_exits():
    exits = {}
    for name, mark, table, route4, route6, *rest in parse_rows(EXITS_FILE, 5):
        display = " ".join(rest).strip() or name
        exits[name] = {"name": name, "display": display, "mark": mark, "table": table, "route4": route4, "route6": route6}
    return exits


def load_containers():
    containers = []
    for name, ip, token, allowed, current, *rest in parse_rows(CONTAINERS_FILE, 5):
        containers.append({"name": name, "ip": ip, "token": token, "allowed": allowed, "current": current})
    return containers


def load_split_apps():
    apps = {}
    for app, display, category, remote, enabled, *rest in parse_tsv_rows(SPLIT_APPS_FILE, 5):
        if str(enabled).lower() in ("false", "0", "no"):
            continue
        apps[app] = {"app": app, "display": display, "category": category, "remote": remote}
    return apps


def load_split_policies():
    policies = {}
    for app, target, *rest in parse_tsv_rows(SPLIT_POLICIES_FILE, 2):
        policies[app] = target
    return policies


def load_container_split_policies():
    policies = {}
    for container, app, target, *rest in parse_tsv_rows(SPLIT_CONTAINER_POLICIES_FILE, 3):
        policies[(container, app)] = target
    return policies


def load_force_split_policies():
    return {parts[0] for parts in parse_tsv_rows(SPLIT_FORCE_POLICIES_FILE, 1) if parts and parts[0]}


def load_force_split_categories():
    return {parts[0] for parts in parse_tsv_rows(SPLIT_FORCE_CATEGORY_POLICIES_FILE, 1) if parts and parts[0]}


def load_force_on_exit_policies():
    return {(parts[0], parts[1]): parts[2] for parts in parse_tsv_rows(SPLIT_FORCE_ON_EXIT_POLICIES_FILE, 3)}


def load_force_category_on_exit_policies():
    return {(parts[0], parts[1]): parts[2] for parts in parse_tsv_rows(SPLIT_FORCE_CATEGORY_ON_EXIT_POLICIES_FILE, 3)}


DIRECT_EXIT = "-"
DIRECT_EXIT_NAME = "入口机"
DIRECT_ALIASES = {DIRECT_EXIT, DIRECT_EXIT_NAME, "host", "direct", "entry", "local", "main"}
DEFAULT_SPLIT_TARGET = "__default__"
DEFAULT_SPLIT_ALIASES = {DEFAULT_SPLIT_TARGET, "默认", "宿主机默认", "跟随宿主机", "default", "inherit"}


def current_label(current, exits=None):
    if current == DIRECT_EXIT:
        return DIRECT_EXIT_NAME
    if exits and current in exits:
        return exits[current].get("display") or current
    return current


def resolve_target(target, exits):
    if target in exits:
        return target
    for name, row in exits.items():
        if target == row.get("display"):
            return name
    if target in DIRECT_ALIASES:
        return DIRECT_EXIT
    return ""


def resolve_app(app_ref, apps):
    if app_ref in apps:
        return app_ref
    for app, row in apps.items():
        if app_ref == row.get("display"):
            return app
    return ""


def split_target_label(target, exits):
    if not target:
        return "未设置"
    if target == DEFAULT_SPLIT_TARGET:
        return "跟随宿主机默认"
    return current_label(target, exits)


def split_target_list(value):
    return [item.strip() for item in (value or "").split(",") if item.strip()]


def split_target_default(value):
    targets = split_target_list(value)
    return targets[0] if targets else ""


def split_target_list_label(value, exits):
    targets = split_target_list(value)
    if not targets:
        return "未设置"
    labels = [split_target_label(target, exits) for target in targets]
    if len(labels) > 1:
        return "%s（默认：%s）" % ("，".join(labels), labels[0])
    return labels[0]


def visible_split_target_list_label(policy_targets, visible_targets, exits):
    if not visible_targets:
        return "无可自选出口"
    labels = [split_target_label(target, exits) for target in visible_targets]
    default_target = split_target_default(policy_targets)
    default_label = split_target_label(default_target, exits)
    if default_target in visible_targets:
        if len(labels) > 1:
            return "%s（默认：%s）" % ("，".join(labels), default_label)
        return labels[0]
    return "%s（宿主默认：%s）" % ("，".join(labels), default_label)


def split_target_allowed(value, target):
    return target in split_target_list(value)


def app_is_forced(app, apps):
    if app in load_force_split_policies():
        return True
    category = (apps.get(app) or {}).get("category", "")
    return bool(category and category in load_force_split_categories())


def conditional_force_target(app, apps, container):
    source = container.get("current", "-")
    target = load_force_on_exit_policies().get((app, source), "")
    if target:
        return split_target_default(target)
    category = (apps.get(app) or {}).get("category", "")
    if not category:
        return ""
    return split_target_default(load_force_category_on_exit_policies().get((category, source), ""))


def normalize_ip(value):
    ip = ipaddress.ip_address(value.split("%", 1)[0])
    if getattr(ip, "ipv4_mapped", None):
        ip = ip.ipv4_mapped
    return str(ip)


def find_container_by_ip(remote_ip):
    remote = normalize_ip(remote_ip)
    for row in load_containers():
        if normalize_ip(row["ip"]) == remote:
            return row
    return None


def allowed_exits(container, exits):
    allowed = container["allowed"]
    if allowed == "*":
        return [DIRECT_EXIT_NAME] + [exits[name].get("display") or name for name in sorted(exits.keys())]
    names = [item for item in allowed.split(",") if item]
    return [DIRECT_EXIT_NAME] + [exits[name].get("display") or name for name in names if name in exits]


def is_allowed_target(container, target):
    allowed = container["allowed"]
    if target == DIRECT_EXIT or allowed == "*":
        return True
    names = [item for item in allowed.split(",") if item]
    return target in names


def visible_split_targets_for_container(container, targets, exits):
    visible = []
    seen = set()
    for target in targets:
        if target == DEFAULT_SPLIT_TARGET:
            continue
        if target == DIRECT_EXIT:
            candidate_ok = True
        else:
            candidate_ok = target in exits and is_allowed_target(container, target)
        if candidate_ok and target not in seen:
            visible.append(target)
            seen.add(target)
    return visible


def token_from_headers(headers):
    token = headers.get("X-Egress-Token", "")
    auth = headers.get("Authorization", "")
    if not token and auth.lower().startswith("bearer "):
        token = auth.split(None, 1)[1]
    return token


def authorize(handler, container):
    expected = container.get("token", "")
    provided = token_from_headers(handler.headers)
    if STRICT_TOKEN and (not expected or expected == "-"):
        return False, "容器 token 未配置"
    if expected and expected != "-" and provided != expected:
        return False, "token 无效"
    return True, ""


def response(handler, code, payload):
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    try:
        handler.send_response(code)
        handler.send_header("Content-Type", "application/json; charset=utf-8")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)
    except (BrokenPipeError, ConnectionResetError, TimeoutError):
        pass


def text_response(handler, code, body):
    payload = body.encode("utf-8")
    try:
        handler.send_response(code)
        handler.send_header("Content-Type", "text/plain; charset=utf-8")
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        handler.wfile.write(payload)
    except (BrokenPipeError, ConnectionResetError, TimeoutError):
        pass


def write_pending_generation():
    generation = "%s-%s" % (time.time_ns(), threading.get_ident())
    fd, tmp_path = tempfile.mkstemp(prefix="nft-pending.", dir=CONFIG_DIR)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write(generation + "\n")
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, PENDING_NFT_FILE)
    return generation


def clear_pending_generation(generation):
    with file_lock(STATE_LOCK_FILE):
        try:
            with open(PENDING_NFT_FILE, "r", encoding="utf-8") as fh:
                current = fh.read().strip()
        except OSError:
            return
        if current == generation:
            try:
                os.unlink(PENDING_NFT_FILE)
            except OSError:
                pass


def update_container_current(container_ip, new_exit):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with file_lock(STATE_LOCK_FILE):
        fd, tmp_path = tempfile.mkstemp(prefix="containers.", dir=CONFIG_DIR)
        found = False
        previous = None
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            with open(CONTAINERS_FILE, "r", encoding="utf-8") as src:
                for raw in src:
                    stripped = raw.strip()
                    if not stripped or stripped.startswith("#"):
                        out.write(raw)
                        continue
                    parts = stripped.split()
                    if len(parts) < 5:
                        out.write(raw)
                        continue
                    if normalize_ip(parts[1]) == normalize_ip(container_ip):
                        previous = parts[4]
                        parts[4] = new_exit
                        found = True
                    out.write("\t".join(parts) + "\n")
        if not found:
            os.unlink(tmp_path)
            raise RuntimeError("container row disappeared")
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, CONTAINERS_FILE)
        return previous, write_pending_generation()


def update_container_split(container_name, app, target):
    os.makedirs(SPLIT_DIR, exist_ok=True)
    with file_lock(STATE_LOCK_FILE):
        fd, tmp_path = tempfile.mkstemp(prefix="container-policies.", dir=SPLIT_DIR)
        found = False
        if not os.path.exists(SPLIT_CONTAINER_POLICIES_FILE):
            existing = []
        else:
            with open(SPLIT_CONTAINER_POLICIES_FILE, "r", encoding="utf-8") as src:
                existing = list(src)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            if not existing:
                out.write("# container app_id target_exit\n")
            for raw in existing:
                stripped = raw.strip()
                if not stripped or stripped.startswith("#"):
                    out.write(raw)
                    continue
                parts = stripped.split()
                if len(parts) < 3:
                    out.write(raw)
                    continue
                if parts[0] == container_name and parts[1] == app:
                    found = True
                    if target == DEFAULT_SPLIT_TARGET:
                        continue
                    parts[2] = target
                    out.write("\t".join(parts[:3]) + "\n")
                else:
                    out.write(raw)
            if not found and target != DEFAULT_SPLIT_TARGET:
                out.write("%s\t%s\t%s\n" % (container_name, app, target))
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, SPLIT_CONTAINER_POLICIES_FILE)
        return write_pending_generation()


def ensure_split_rules(app):
    result = subprocess.run([MANAGER_BIN, "split-ensure", app], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    if result.returncode != 0:
        raise RuntimeError((result.stdout or "split prepare failed").strip())


def run_nft_transition(lines):
    payload = "\n".join(lines) + "\n"
    with file_lock(APPLY_LOCK_FILE):
        result = subprocess.run(
            ["nft", "-f", "-"],
            input=payload,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
    return result.returncode == 0


def apply_nft_fallback():
    result = subprocess.run([MANAGER_BIN, "apply-nft"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError((result.stdout or "nft apply failed").strip())


def nft_update(container_ip, mark, previous):
    ip = ipaddress.ip_address(normalize_ip(container_ip))
    key_set = "egress4_keys" if ip.version == 4 else "egress6_keys"
    split_set = "split4_keys" if ip.version == 4 else "split6_keys"
    map_name = "egress4" if ip.version == 4 else "egress6"
    ip_s = str(ip)
    if previous == DIRECT_EXIT:
        lines = [
            "delete element inet %s %s { %s }" % (NFT_TABLE, split_set, ip_s),
            "add element inet %s %s { %s }" % (NFT_TABLE, key_set, ip_s),
            "add element inet %s %s { %s : %s }" % (NFT_TABLE, map_name, ip_s, mark),
        ]
    else:
        lines = [
            "delete element inet %s %s { %s }" % (NFT_TABLE, map_name, ip_s),
            "add element inet %s %s { %s : %s }" % (NFT_TABLE, map_name, ip_s, mark),
        ]
    if not run_nft_transition(lines):
        apply_nft_fallback()


def nft_clear(container_ip, previous):
    ip = ipaddress.ip_address(normalize_ip(container_ip))
    key_set = "egress4_keys" if ip.version == 4 else "egress6_keys"
    split_set = "split4_keys" if ip.version == 4 else "split6_keys"
    map_name = "egress4" if ip.version == 4 else "egress6"
    ip_s = str(ip)
    if previous == DIRECT_EXIT:
        return
    lines = [
        "delete element inet %s %s { %s }" % (NFT_TABLE, key_set, ip_s),
        "delete element inet %s %s { %s }" % (NFT_TABLE, map_name, ip_s),
        "add element inet %s %s { %s }" % (NFT_TABLE, split_set, ip_s),
    ]
    if not run_nft_transition(lines):
        apply_nft_fallback()


def clear_conntrack(container_ip):
    if not SWITCH_CLEAR_CONNTRACK or not CONNTRACK_BIN:
        return
    # 只清理容器主动建立的连接，避免切换出口时误杀转发到容器的 SSH/DNAT 会话。
    subprocess.run([CONNTRACK_BIN, "-D", "-s", container_ip], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


class Handler(BaseHTTPRequestHandler):
    server_version = "IncusEgressSwitch/1.0"

    def setup(self):
        super().setup()
        self.request.settimeout(API_SOCKET_TIMEOUT)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.client_address[0], fmt % args), flush=True)

    def container_or_error(self):
        if not rate_allowed(self.client_address[0]):
            response(self, 429, {"ok": False, "error": "请求过于频繁，请稍后重试"})
            return None
        container = find_container_by_ip(self.client_address[0])
        if not container:
            response(self, 403, {"ok": False, "error": "来源 IP 不是已登记容器", "source": self.client_address[0]})
            return None
        ok, why = authorize(self, container)
        if not ok:
            response(self, 403, {"ok": False, "error": why})
            return None
        return container

    def read_form(self):
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            response(self, 400, {"ok": False, "error": "Content-Length 无效"})
            return None
        if length < 0 or length > API_MAX_BODY:
            response(self, 413, {"ok": False, "error": "请求内容过大"})
            return None
        try:
            body = self.rfile.read(length).decode("utf-8", errors="replace")
        except (TimeoutError, ConnectionError, OSError):
            response(self, 408, {"ok": False, "error": "读取请求超时"})
            return None
        return urllib.parse.parse_qs(body)

    def split_list_text(self, container, exits):
        apps = load_split_apps()
        global_policies = load_split_policies()
        overrides = load_container_split_policies()
        lines = []
        for app in sorted(apps.keys(), key=lambda key: (apps[key].get("category", ""), apps[key].get("display", key))):
            conditional_target = conditional_force_target(app, apps, container)
            if app not in global_policies and not conditional_target:
                continue
            row = apps[app]
            policy_targets = global_policies.get(app, "")
            visible_targets = visible_split_targets_for_container(container, split_target_list(policy_targets), exits)
            default_target = split_target_default(policy_targets)
            override_target = overrides.get((container["name"], app), "")
            if override_target and not split_target_allowed(policy_targets, override_target):
                override_target = ""
            if override_target and not is_allowed_target(container, override_target):
                override_target = ""
            globally_forced = app_is_forced(app, apps)
            forced = globally_forced or bool(conditional_target)
            effective_target = conditional_target if conditional_target and not globally_forced else (default_target if globally_forced else (override_target if override_target else default_target))
            choice_label = "已锁定（不可自选）" if forced else visible_split_target_list_label(policy_targets, visible_targets, exits)
            lines.append("%s\t%s\t%s\t%s\t%s\t%s\t%s" % (
                app,
                row.get("display", app),
                row.get("category", "未分类"),
                split_target_label(effective_target, exits),
                choice_label,
                ("按当前出口强制" if conditional_target and not globally_forced else "宿主机强制") if forced else split_target_label(override_target, exits),
                choice_label,
            ))
        return "\n".join(lines) + ("\n" if lines else "")

    def split_targets_text(self, container, exits, app_ref=""):
        lines = []
        targets = []
        if app_ref:
            apps = load_split_apps()
            app = resolve_app(app_ref, apps)
            policies = load_split_policies()
            if app and (app_is_forced(app, apps) or conditional_force_target(app, apps, container)):
                return ""
            if app and app in policies:
                targets = split_target_list(policies[app])
        lines.append("%s\t%s" % (DEFAULT_SPLIT_TARGET, "跟随宿主机默认"))
        if not targets:
            targets = [DIRECT_EXIT] + sorted(exits.keys())
        targets = visible_split_targets_for_container(container, targets, exits)
        for name in targets:
            if name == DIRECT_EXIT:
                lines.append("%s\t%s" % (DIRECT_EXIT, DIRECT_EXIT_NAME))
            elif name in exits:
                lines.append("%s\t%s" % (name, exits[name].get("display") or name))
        return "\n".join(lines) + "\n"

    def do_GET(self):
        raw_path, _, query = self.path.partition("?")
        params = urllib.parse.parse_qs(query)
        if raw_path == "/health":
            response(self, 200, {"ok": True})
            return
        container = self.container_or_error()
        if not container:
            return
        exits = load_exits()
        path = raw_path
        if path == "/exits":
            response(self, 200, {"ok": True, "container": container["name"], "current": current_label(container["current"], exits), "exits": allowed_exits(container, exits)})
        elif path == "/current":
            response(self, 200, {"ok": True, "container": container["name"], "current": current_label(container["current"], exits)})
        elif path == "/split.txt":
            text_response(self, 200, self.split_list_text(container, exits))
        elif path == "/split-targets.txt":
            app_ref = (params.get("app") or [""])[0]
            text_response(self, 200, self.split_targets_text(container, exits, app_ref))
        else:
            response(self, 404, {"ok": False, "error": "接口不存在"})

    def do_POST(self):
        container = self.container_or_error()
        if not container:
            return
        path = self.path.split("?", 1)[0]
        if path in ("/split/use", "/split/switch"):
            self.do_split_post(container)
            return
        if path not in ("/use", "/switch"):
            response(self, 404, {"ok": False, "error": "接口不存在"})
            return
        params = self.read_form()
        if params is None:
            return
        requested = (params.get("exit") or params.get("name") or [""])[0]
        exits = load_exits()
        target = resolve_target(requested, exits)
        if not target:
            response(self, 400, {"ok": False, "error": "未知出口"})
            return
        if not is_allowed_target(container, target):
            response(self, 403, {"ok": False, "error": "该出口未授权给当前容器"})
            return
        try:
            previous, generation = update_container_current(container["ip"], target)
            if target == DIRECT_EXIT:
                nft_clear(container["ip"], previous)
            else:
                nft_update(container["ip"], exits[target]["mark"], previous)
            clear_pending_generation(generation)
            clear_conntrack(container["ip"])
        except Exception as exc:
            response(self, 500, {"ok": False, "error": str(exc)})
            return
        response(self, 200, {"ok": True, "container": container["name"], "current": current_label(target, exits)})

    def do_split_post(self, container):
        params = self.read_form()
        if params is None:
            return
        app_ref = (params.get("app") or params.get("name") or [""])[0]
        requested = (params.get("exit") or params.get("target") or [""])[0]
        apps = load_split_apps()
        exits = load_exits()
        app = resolve_app(app_ref, apps)
        if not app:
            response(self, 400, {"ok": False, "error": "未知应用分流"})
            return
        global_policies = load_split_policies()
        conditional_target = conditional_force_target(app, apps, container)
        if app not in global_policies and not conditional_target:
            response(self, 403, {"ok": False, "error": "宿主机未启用该应用分流"})
            return
        policy_targets = global_policies.get(app, "")
        if app_is_forced(app, apps) or conditional_target:
            response(self, 403, {"ok": False, "error": "该应用已由宿主机强制分流，容器不能自行切换"})
            return
        if requested in DEFAULT_SPLIT_ALIASES:
            target = DEFAULT_SPLIT_TARGET
        else:
            target = resolve_target(requested, exits)
            if not target:
                response(self, 400, {"ok": False, "error": "未知出口"})
                return
            if not is_allowed_target(container, target):
                response(self, 403, {"ok": False, "error": "该出口未授权给当前容器"})
                return
            if not split_target_allowed(policy_targets, target):
                response(self, 403, {"ok": False, "error": "该出口不在此应用允许的候选出口内"})
                return
        try:
            ensure_split_rules(app)
            generation = update_container_split(container["name"], app, target)
            apply_nft_fallback()
            clear_pending_generation(generation)
            clear_conntrack(container["ip"])
        except Exception as exc:
            response(self, 500, {"ok": False, "error": str(exc)})
            return
        overrides = load_container_split_policies()
        override_target = overrides.get((container["name"], app), "")
        if override_target and not split_target_allowed(policy_targets, override_target):
            override_target = ""
        if override_target and not is_allowed_target(container, override_target):
            override_target = ""
        effective_target = override_target if override_target else split_target_default(policy_targets)
        response(self, 200, {
            "ok": True,
            "container": container["name"],
            "app": apps[app].get("display", app),
            "target": split_target_label(effective_target, exits),
            "override": split_target_label(override_target, exits),
        })


class LimitedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = max(32, API_MAX_CONCURRENT * 2)

    def __init__(self, server_address, handler):
        self.worker_slots = threading.BoundedSemaphore(API_MAX_CONCURRENT)
        super().__init__(server_address, handler)

    def process_request(self, request, client_address):
        if not self.worker_slots.acquire(timeout=1):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.worker_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.worker_slots.release()


def main():
    httpd = LimitedThreadingHTTPServer((API_BIND, API_PORT), Handler)
    print("incus-egress-switch API listening on %s:%s" % (API_BIND, API_PORT), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
PY
    python3 -m py_compile "$tmp"
    rm -rf "$LIB_DIR/__pycache__"
    chmod 0755 "$tmp"
    mv -f "$tmp" "$CONTROLLER_FILE"
}

write_autosync() {
    mkdir -p "$LIB_DIR"
    local tmp
    tmp="$(mktemp "$LIB_DIR/autosync.py.XXXXXX")"
    cat > "$tmp" <<'PY'
#!/usr/bin/env python3
import argparse
import concurrent.futures
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from contextlib import contextmanager

CONFIG_DIR = os.environ.get("EGRESS_CONFIG_DIR", "/etc/incus-egress-switch")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.env")
EXITS_FILE = os.path.join(CONFIG_DIR, "exits.tsv")
CONTAINERS_FILE = os.path.join(CONFIG_DIR, "containers.tsv")
STATE_FILE = os.path.join(CONFIG_DIR, "autosync-state.json")
STATE_LOCK_FILE = os.path.join(CONFIG_DIR, ".state.lock")
RECONCILE_LOCK_FILE = os.path.join(CONFIG_DIR, ".reconcile.lock")
PENDING_NFT_FILE = os.path.join(CONFIG_DIR, ".nft-apply-pending")
MANAGER_BIN = os.environ.get("EGRESS_MANAGER_BIN", "/usr/local/sbin/incus-egress-switch")
OUT_CLIENT_FILE = os.environ.get("EGRESS_OUT_CLIENT", "/usr/local/lib/incus-egress-switch/out")


def log(message):
    print(time.strftime("%F %T"), message, flush=True)


def read_env_file(path):
    data = {}
    if not os.path.exists(path):
        return data
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip().strip("'").strip('"')
    return data


CFG = read_env_file(CONFIG_FILE)
AUTO_INTERVAL = int(os.environ.get("AUTO_INTERVAL", CFG.get("AUTO_INTERVAL", "15")))
AUTO_PROJECTS = os.environ.get("AUTO_PROJECTS", CFG.get("AUTO_PROJECTS", "default")).split()
AUTO_INCLUDE_REGEX = os.environ.get("AUTO_INCLUDE_REGEX", CFG.get("AUTO_INCLUDE_REGEX", ".*"))
AUTO_EXCLUDE_REGEX = os.environ.get("AUTO_EXCLUDE_REGEX", CFG.get("AUTO_EXCLUDE_REGEX", ""))
AUTO_ALLOW_EXITS = os.environ.get("AUTO_ALLOW_EXITS", CFG.get("AUTO_ALLOW_EXITS", "*"))
AUTO_DEFAULT_EXIT = os.environ.get("AUTO_DEFAULT_EXIT", CFG.get("AUTO_DEFAULT_EXIT", ""))
AUTO_INSTALL_CLIENT = os.environ.get("AUTO_INSTALL_CLIENT", CFG.get("AUTO_INSTALL_CLIENT", "true")).lower() == "true"
AUTO_CLIENT_VERIFY_INTERVAL = int(os.environ.get("AUTO_CLIENT_VERIFY_INTERVAL", CFG.get("AUTO_CLIENT_VERIFY_INTERVAL", "300")))
AUTO_STATE_REFRESH_INTERVAL = int(os.environ.get("AUTO_STATE_REFRESH_INTERVAL", CFG.get("AUTO_STATE_REFRESH_INTERVAL", "300")))
AUTO_CLIENT_PATH = os.environ.get("AUTO_CLIENT_PATH", CFG.get("AUTO_CLIENT_PATH", "/usr/local/bin/out"))
AUTO_TOKEN_PATH = os.environ.get("AUTO_TOKEN_PATH", CFG.get("AUTO_TOKEN_PATH", "/etc/incus-egress-token"))
AUTO_RUNNING_ONLY = os.environ.get("AUTO_RUNNING_ONLY", CFG.get("AUTO_RUNNING_ONLY", "true")).lower() == "true"
AUTO_SYNC_WORKERS = max(1, min(int(os.environ.get("AUTO_SYNC_WORKERS", CFG.get("AUTO_SYNC_WORKERS", "8"))), 32))
AUTO_INJECT_WORKERS = max(1, min(int(os.environ.get("AUTO_INJECT_WORKERS", CFG.get("AUTO_INJECT_WORKERS", "4"))), 16))
AUTO_COMMAND_TIMEOUT = max(5, int(os.environ.get("AUTO_COMMAND_TIMEOUT", CFG.get("AUTO_COMMAND_TIMEOUT", "30"))))
AUTO_DELETE_GRACE_SCANS = max(1, int(os.environ.get("AUTO_DELETE_GRACE_SCANS", CFG.get("AUTO_DELETE_GRACE_SCANS", "2"))))
AUTO_RECONCILE_MIN_INTERVAL = max(1, int(os.environ.get("AUTO_RECONCILE_MIN_INTERVAL", CFG.get("AUTO_RECONCILE_MIN_INTERVAL", "10"))))
AUTO_EVENT_DEBOUNCE = max(0.0, float(os.environ.get("AUTO_EVENT_DEBOUNCE", CFG.get("AUTO_EVENT_DEBOUNCE", "2"))))
ENABLE_SPLIT_RULES = os.environ.get("ENABLE_SPLIT_RULES", CFG.get("ENABLE_SPLIT_RULES", "true")).lower() == "true"
SPLIT_UPDATE_INTERVAL = int(os.environ.get("SPLIT_UPDATE_INTERVAL", CFG.get("SPLIT_UPDATE_INTERVAL", "259200")))
SPLIT_DNS_REFRESH_INTERVAL = int(os.environ.get("SPLIT_DNS_REFRESH_INTERVAL", CFG.get("SPLIT_DNS_REFRESH_INTERVAL", "21600")))
SPLIT_LAST_SYNC_FILE = os.path.join(CONFIG_DIR, "split", "last-sync")
SPLIT_LAST_DNS_REFRESH_FILE = os.path.join(CONFIG_DIR, "split", "last-dns-refresh")
SPLIT_CONTAINER_POLICIES_FILE = os.path.join(CONFIG_DIR, "split", "container-policies.tsv")
RECONCILE_EVENT = threading.Event()


@contextmanager
def file_lock(path, exclusive=True):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        yield


def run(cmd, check=True, capture=True, input_data=None, timeout=None):
    result = subprocess.run(
        cmd,
        input=input_data,
        stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        timeout=AUTO_COMMAND_TIMEOUT if timeout is None else timeout,
    )
    if check and result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise RuntimeError("%s failed%s" % (" ".join(cmd), ": " + stderr if stderr else ""))
    return result


def incus_cmd(project, *args):
    return ["incus", "--project", project, *args]


def load_exits():
    exits = []
    if not os.path.exists(EXITS_FILE):
        return exits
    with open(EXITS_FILE, "r", encoding="utf-8") as fh:
        for raw in fh:
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = stripped.split()
            if len(parts) >= 3:
                exits.append(parts[0])
    return exits


def first_exit():
    exits = load_exits()
    if AUTO_DEFAULT_EXIT:
        if AUTO_DEFAULT_EXIT in ("-", "入口机", "host", "direct", "entry", "local", "main"):
            return "-"
        if AUTO_DEFAULT_EXIT not in exits:
            raise RuntimeError("AUTO_DEFAULT_EXIT is not in exits.tsv: %s" % AUTO_DEFAULT_EXIT)
        return AUTO_DEFAULT_EXIT
    return "-"


def exit_label(name):
    return "入口机" if name == "-" else name


def normalize_ip(value):
    ip = ipaddress.ip_address(value.split("%", 1)[0])
    if getattr(ip, "ipv4_mapped", None):
        ip = ip.ipv4_mapped
    return str(ip)


def legacy_key(project, name):
    raw = name if project == "default" else "%s.%s" % (project, name)
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", raw)


def unique_key(project, name):
    if project == "default":
        return legacy_key(project, name)
    digest = hashlib.sha256((project + "\0" + name).encode("utf-8")).hexdigest()[:10]
    clean = re.sub(r"[^A-Za-z0-9_.-]+", "_", name).strip("._-")[:40] or "container"
    return "p_%s__%s" % (digest, clean)


def include_instance(project, name):
    key = legacy_key(project, name)
    try:
        if not re.search(AUTO_INCLUDE_REGEX, key) and not re.search(AUTO_INCLUDE_REGEX, name):
            return False
        if AUTO_EXCLUDE_REGEX and (re.search(AUTO_EXCLUDE_REGEX, key) or re.search(AUTO_EXCLUDE_REGEX, name)):
            return False
    except re.error as exc:
        raise RuntimeError("invalid include/exclude regex: %s" % exc)
    return True


def instance_state(project, name):
    quoted = urllib.parse.quote(name, safe="")
    project_q = urllib.parse.quote(project, safe="")
    try:
        result = run(["incus", "query", "/1.0/instances/%s/state?project=%s" % (quoted, project_q)], check=False)
    except Exception:
        return {}
    if result.returncode != 0:
        return {}
    try:
        return json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return {}


def pick_ip_from_state(state):
    network = state.get("network") or {}
    for iface, data in network.items():
        if iface == "lo":
            continue
        for addr in data.get("addresses") or []:
            family = addr.get("family")
            scope = addr.get("scope")
            address = addr.get("address")
            if family == "inet" and address and scope in ("global", ""):
                return normalize_ip(address)
    for iface, data in network.items():
        if iface == "lo":
            continue
        for addr in data.get("addresses") or []:
            family = addr.get("family")
            scope = addr.get("scope")
            address = addr.get("address")
            if family == "inet6" and address and scope == "global":
                return normalize_ip(address)
    return ""


def list_instances(project):
    result = run(incus_cmd(project, "list", "--format", "json"))
    try:
        items = json.loads(result.stdout or "[]")
    except json.JSONDecodeError as exc:
        raise RuntimeError("cannot parse incus list json for project %s: %s" % (project, exc))

    candidates = []
    for inst in items:
        name = inst.get("name") or ""
        if not name:
            continue
        inst_type = inst.get("type") or inst.get("instance_type") or "container"
        if inst_type != "container":
            continue
        if not include_instance(project, name):
            continue
        status = inst.get("status") or ""
        candidates.append({
            "project": project,
            "name": name,
            "status": status,
            "list_state": inst.get("state") or {},
            "fingerprint": (inst.get("config") or {}).get("volatile.uuid", "") or str(inst.get("created_at") or ""),
        })
    return candidates


def discover_instances(existing, refresh_ips=False):
    raw_instances = []
    failed_projects = []
    for project in AUTO_PROJECTS:
        if not project:
            continue
        try:
            raw_instances.extend(list_instances(project))
        except Exception as exc:
            failed_projects.append(project)
            log("扫描 project=%s 失败: %s" % (project, exc))

    identity_index = {}
    for row in existing.values():
        if row.get("project") and row.get("instance"):
            identity_index[(row["project"], row["instance"])] = row["name"]
    legacy_counts = {}
    for inst in raw_instances:
        old_key = legacy_key(inst["project"], inst["name"])
        legacy_counts[old_key] = legacy_counts.get(old_key, 0) + 1
    for old_key, count in legacy_counts.items():
        if count > 1 and old_key in existing and not existing[old_key].get("project"):
            raise RuntimeError("旧版容器标识 %s 同时匹配多个 project/实例；为防 token 串号已停止同步，请先人工确认该行归属" % old_key)

    used_keys = set()
    prepared = []
    for inst in raw_instances:
        identity = (inst["project"], inst["name"])
        old_key = legacy_key(*identity)
        if identity in identity_index:
            key = identity_index[identity]
        elif old_key in existing and not existing[old_key].get("project") and legacy_counts.get(old_key) == 1:
            # 兼容旧版非 default project 命名，保留 token、当前出口和容器分流引用。
            key = old_key
        else:
            key = unique_key(*identity)
        if key in used_keys:
            raise RuntimeError("容器标识冲突: project=%s name=%s key=%s" % (inst["project"], inst["name"], key))
        used_keys.add(key)
        item = dict(inst)
        item["key"] = key
        prepared.append(item)

    ready = []
    needs_query = []
    for inst in prepared:
        item = dict(inst)
        known = existing.get(inst["key"], {}).get("ip", "")
        state = inst.get("list_state") or {}
        ip = pick_ip_from_state(state)
        if inst.get("status", "").lower() == "running":
            if not ip and known and not refresh_ips:
                ip = known
            if not ip:
                needs_query.append(inst)
                continue
        elif known:
            ip = known
        item["ip"] = ip
        item.pop("list_state", None)
        ready.append(item)

    def query_state(inst):
        item = dict(inst)
        item["ip"] = pick_ip_from_state(instance_state(inst["project"], inst["name"]))
        item.pop("list_state", None)
        return item

    if len(needs_query) > 1 and AUTO_SYNC_WORKERS > 1:
        workers = min(AUTO_SYNC_WORKERS, len(needs_query))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
            queried = list(executor.map(query_state, needs_query))
    else:
        queried = [query_state(item) for item in needs_query]

    enriched = ready + queried
    found = {inst["key"]: inst for inst in enriched}
    return found, not failed_projects


def read_container_rows():
    rows = []
    comments = []
    if not os.path.exists(CONTAINERS_FILE):
        return comments, rows
    with open(CONTAINERS_FILE, "r", encoding="utf-8") as fh:
        for raw in fh:
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                comments.append(raw)
                continue
            parts = stripped.split()
            if len(parts) >= 5:
                rows.append({
                    "name": parts[0],
                    "ip": parts[1],
                    "token": parts[2],
                    "allowed": parts[3],
                    "current": parts[4],
                    "project": parts[5] if len(parts) > 5 else "",
                    "instance": parts[6] if len(parts) > 6 else "",
                    "fingerprint": parts[7] if len(parts) > 7 else "",
                })
    return comments, rows


def write_container_rows(comments, rows):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix="containers.", dir=CONFIG_DIR)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        if comments:
            out.writelines(comments)
        else:
            out.write("# name ip token allowed_exits current_exit project instance fingerprint\n")
        for row in rows:
            out.write("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (
                row["name"], row["ip"], row["token"], row["allowed"], row["current"],
                row.get("project", ""), row.get("instance", ""), row.get("fingerprint", ""),
            ))
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, CONTAINERS_FILE)


def remove_container_split_policies(container_names):
    if not container_names or not os.path.exists(SPLIT_CONTAINER_POLICIES_FILE):
        return 0
    names = set(container_names)
    os.makedirs(os.path.dirname(SPLIT_CONTAINER_POLICIES_FILE), exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix="container-policies.", dir=os.path.dirname(SPLIT_CONTAINER_POLICIES_FILE))
    removed = 0
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        with open(SPLIT_CONTAINER_POLICIES_FILE, "r", encoding="utf-8") as src:
            for raw in src:
                stripped = raw.strip()
                if not stripped or stripped.startswith("#"):
                    out.write(raw)
                    continue
                parts = stripped.split()
                if parts and parts[0] in names:
                    removed += 1
                    continue
                out.write(raw)
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, SPLIT_CONTAINER_POLICIES_FILE)
    return removed


def token():
    return secrets.token_hex(16)


def load_state():
    if not os.path.exists(STATE_FILE):
        return {"injected": {}}
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {"injected": {}}


def save_state(state):
    fd, tmp_path = tempfile.mkstemp(prefix="autosync-state.", dir=CONFIG_DIR)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(state, fh, separators=(",", ":"), ensure_ascii=False)
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, STATE_FILE)


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def push_file(project, name, local_path, remote_path, mode):
    run(incus_cmd(project, "file", "push", "-p", local_path, "%s%s" % (name, remote_path), "--mode=%s" % mode, "--uid=0", "--gid=0"))


def push_text(project, name, text, remote_path, mode):
    fd, tmp_path = tempfile.mkstemp(prefix="incus-egress-push.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        push_file(project, name, tmp_path, remote_path, mode)
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def remote_client_ok(inst, row):
    script = r'''
client_path="$1"
token_path="$2"
expected="$3"
[ -x "$client_path" ] || exit 1
[ -f "$token_path" ] || exit 1
actual="$(tr -d '\r\n' < "$token_path" 2>/dev/null || true)"
[ "$actual" = "$expected" ] || exit 1
'''
    result = run(
        incus_cmd(inst["project"], "exec", inst["name"], "--", "sh", "-c", script, "sh", AUTO_CLIENT_PATH, AUTO_TOKEN_PATH, row["token"]),
        check=False,
    )
    return result.returncode == 0


def inject_client(inst, row, state, client_digest, verify=False):
    if not AUTO_INSTALL_CLIENT:
        return
    if inst.get("status", "").lower() != "running":
        return
    injected = state.setdefault("injected", {})
    signature = "%s:%s:%s:%s" % (row["token"], AUTO_CLIENT_PATH, AUTO_TOKEN_PATH, client_digest)
    if injected.get(row["name"]) == signature:
        if not verify:
            return
        if remote_client_ok(inst, row):
            return
        log("检测到容器 out/token 缺失或不匹配，重新注入: %s" % row["name"])
    try:
        push_file(inst["project"], inst["name"], OUT_CLIENT_FILE, AUTO_CLIENT_PATH, "0755")
        push_text(inst["project"], inst["name"], row["token"] + "\n", AUTO_TOKEN_PATH, "0600")
        injected[row["name"]] = signature
        log("已注入 out/token: %s" % row["name"])
    except Exception as exc:
        log("注入失败 %s: %s" % (row["name"], exc))


def inject_clients(inst_rows, state, verify=False):
    if not AUTO_INSTALL_CLIENT or not inst_rows:
        return
    if not os.path.exists(OUT_CLIENT_FILE):
        run([MANAGER_BIN, "write-client"], check=True)
    client_digest = file_sha256(OUT_CLIENT_FILE)
    workers = min(AUTO_INJECT_WORKERS, len(inst_rows))
    if workers <= 1:
        for inst, row in inst_rows:
            inject_client(inst, row, state, client_digest, verify=verify)
        return
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(inject_client, inst, row, state, client_digest, verify) for inst, row in inst_rows]
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except Exception as exc:
                log("注入任务异常: %s" % exc)


def reconcile(force_client_check=False, force_ip_refresh=False):
    # 服务实例与手工 --once 共用该锁，避免同一宿主机同时启动两轮高开销扫描/注入。
    with file_lock(RECONCILE_LOCK_FILE):
        return reconcile_locked(force_client_check=force_client_check, force_ip_refresh=force_ip_refresh)


def reconcile_locked(force_client_check=False, force_ip_refresh=False):
    state = load_state()
    injected = state.setdefault("injected", {})
    missing_counts = state.setdefault("missing_counts", {})
    now = time.time()
    last_verify = float(state.get("last_client_verify", 0) or 0)
    last_ip_refresh = float(state.get("last_ip_refresh", 0) or 0)
    verify_clients = force_client_check or (now - last_verify >= max(AUTO_CLIENT_VERIFY_INTERVAL, 5))
    refresh_ips = force_ip_refresh or (now - last_ip_refresh >= max(AUTO_STATE_REFRESH_INTERVAL, 30))

    with file_lock(STATE_LOCK_FILE, exclusive=False):
        default_exit = first_exit()
        _, snapshot_rows = read_container_rows()
    snapshot = {row["name"]: row for row in snapshot_rows}
    found, scan_complete = discover_instances(snapshot, refresh_ips=refresh_ips)
    if refresh_ips and scan_complete:
        state["last_ip_refresh"] = now

    ip_owners = {}
    for key, inst in found.items():
        ip = inst.get("ip", "")
        if not ip:
            continue
        if ip in ip_owners and ip_owners[ip] != key:
            raise RuntimeError("检测到重复容器 IP %s: %s / %s；已拒绝同步以防出口和 token 串号" % (ip, ip_owners[ip], key))
        ip_owners[ip] = key

    inject_targets = []
    with file_lock(STATE_LOCK_FILE):
        # discovery 期间 API 可能刚切换出口；锁内重读并仅更新库存字段，保留最新 token/授权/当前出口。
        comments, rows = read_container_rows()
        existing = {row["name"]: row for row in rows}
        new_rows = []
        recreated = set()
        removed_containers = set()

        for key, inst in sorted(found.items()):
            running = inst.get("status", "").lower() == "running"
            if AUTO_RUNNING_ONLY and not running and key not in existing:
                continue
            ip = inst.get("ip", "") or existing.get(key, {}).get("ip", "")
            if not ip:
                log("等待容器获取 IP: %s" % key)
                if key in existing:
                    new_rows.append(existing[key])
                continue
            if key in existing:
                row = dict(existing[key])
                old_fingerprint = row.get("fingerprint", "")
                new_fingerprint = inst.get("fingerprint", "")
                if old_fingerprint and new_fingerprint and old_fingerprint != new_fingerprint:
                    row["token"] = token()
                    row["allowed"] = AUTO_ALLOW_EXITS
                    row["current"] = default_exit
                    recreated.add(key)
                    injected.pop(key, None)
                    log("检测到同名容器已重新创建，已轮换 token 并恢复默认出口: %s" % key)
                if row["ip"] != ip:
                    row["ip"] = ip
                    injected.pop(key, None)
                    log("容器 IP 已更新: %s -> %s" % (key, ip))
            else:
                row = {
                    "name": key,
                    "ip": ip,
                    "token": token(),
                    "allowed": AUTO_ALLOW_EXITS,
                    "current": default_exit,
                }
                log("自动授权新容器: %s ip=%s exit=%s" % (key, ip, exit_label(default_exit)))
            row["project"] = inst["project"]
            row["instance"] = inst["name"]
            row["fingerprint"] = inst.get("fingerprint", "")
            new_rows.append(row)
            missing_counts.pop(key, None)
            if running:
                inject_targets.append((inst, row))

        absent = sorted(set(existing) - set(found))
        for key in absent:
            row = existing[key]
            if not scan_complete:
                new_rows.append(row)
                continue
            # Incus may reuse an address immediately after an instance is removed.
            # Keeping the missing instance through the normal grace scans would
            # create two authorization rows for the same IP and make apply-nft
            # fail.  A currently discovered owner is stronger evidence than the
            # grace timer, so retire the stale authorization immediately.
            current_owner = ip_owners.get(row.get("ip", ""))
            if current_owner and current_owner != key:
                injected.pop(key, None)
                missing_counts.pop(key, None)
                removed_containers.add(key)
                log("容器 IP 已被当前实例接管，立即回收旧配置: %s ip=%s new=%s" % (
                    key, row.get("ip", ""), current_owner,
                ))
                continue
            misses = int(missing_counts.get(key, 0) or 0) + 1
            missing_counts[key] = misses
            if misses < AUTO_DELETE_GRACE_SCANS:
                new_rows.append(row)
                log("容器暂未发现，保留配置等待复核: %s (%s/%s)" % (key, misses, AUTO_DELETE_GRACE_SCANS))
                continue
            injected.pop(key, None)
            missing_counts.pop(key, None)
            removed_containers.add(key)
            log("连续 %s 轮确认容器已删除，回收配置: %s" % (AUTO_DELETE_GRACE_SCANS, key))

        cleanup_names = recreated | removed_containers
        if cleanup_names:
            removed_overrides = remove_container_split_policies(cleanup_names)
            if removed_overrides:
                log("已清理已删除/重新创建容器的旧应用分流覆盖: %s 条" % removed_overrides)

        changed = rows != new_rows
        if changed:
            write_container_rows(comments, new_rows)
            state["apply_pending"] = True
            fd, tmp_path = tempfile.mkstemp(prefix="nft-pending.", dir=CONFIG_DIR)
            with os.fdopen(fd, "w", encoding="utf-8") as out:
                out.write("autosync-%s-%s\n" % (os.getpid(), time.time_ns()))
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, PENDING_NFT_FILE)
            # 先持久化待应用标记；即使此刻进程退出，下一轮也会补做 nft 提交。
            save_state(state)

    apply_error = None
    if changed or state.get("apply_pending") or os.path.exists(PENDING_NFT_FILE):
        try:
            result = run([MANAGER_BIN, "apply-nft"], check=True, capture=True, timeout=max(AUTO_COMMAND_TIMEOUT, 60))
            output = (result.stdout or "").strip()
            if output:
                for line in output.splitlines()[-20:]:
                    log("apply-nft: %s" % line)
            state["apply_pending"] = False
        except Exception as exc:
            apply_error = exc
            log("容器配置已保存，但数据面应用失败，将在下一轮重试: %s" % exc)

    inject_clients(inject_targets, state, verify=verify_clients)
    if verify_clients:
        state["last_client_verify"] = now
    with file_lock(STATE_LOCK_FILE):
        save_state(state)
    if apply_error:
        raise apply_error
    return changed


def maybe_sync_split_rules(force=False):
    if not ENABLE_SPLIT_RULES:
        return
    now = time.time()
    last = 0.0
    try:
        with open(SPLIT_LAST_SYNC_FILE, "r", encoding="utf-8") as fh:
            last = float((fh.read() or "0").strip() or 0)
    except OSError:
        last = 0.0
    except ValueError:
        last = 0.0
    if not force and now - last < max(SPLIT_UPDATE_INTERVAL, 60):
        return
    log("开始检查应用分流规则更新")
    result = subprocess.run([MANAGER_BIN, "split-sync", "--auto"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = (result.stdout or "").strip()
    if output:
        for line in output.splitlines()[-20:]:
            log("split-sync: %s" % line)
    if result.returncode != 0:
        log("应用分流规则更新失败，退出码: %s" % result.returncode)


def maybe_refresh_split_dns(force=False):
    if not ENABLE_SPLIT_RULES or SPLIT_DNS_REFRESH_INTERVAL <= 0:
        return
    now = time.time()
    last = 0.0
    try:
        with open(SPLIT_LAST_DNS_REFRESH_FILE, "r", encoding="utf-8") as fh:
            last = float((fh.read() or "0").strip() or 0)
    except (OSError, ValueError):
        last = 0.0
    try:
        with open(SPLIT_LAST_SYNC_FILE, "r", encoding="utf-8") as fh:
            last = max(last, float((fh.read() or "0").strip() or 0))
    except (OSError, ValueError):
        pass
    if not force and now - last < max(SPLIT_DNS_REFRESH_INTERVAL, 300):
        return
    result = run([MANAGER_BIN, "split-refresh-dns"], check=False, capture=True, timeout=max(AUTO_COMMAND_TIMEOUT, 300))
    output = (result.stdout or "").strip()
    if output:
        for line in output.splitlines()[-10:]:
            log("split-dns: %s" % line)
    if result.returncode == 0:
        os.makedirs(os.path.dirname(SPLIT_LAST_DNS_REFRESH_FILE), exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(prefix="last-dns-refresh.", dir=os.path.dirname(SPLIT_LAST_DNS_REFRESH_FILE))
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(str(int(now)) + "\n")
        os.replace(tmp_path, SPLIT_LAST_DNS_REFRESH_FILE)
    else:
        log("本地域名分流刷新失败，退出码: %s" % result.returncode)


def watch_events():
    cmd = ["incus", "monitor", "--type=lifecycle"]
    last_sync = 0.0
    while True:
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            assert proc.stdout is not None
            for line in proc.stdout:
                if any(word in line.lower() for word in ("instance", "container", "created", "deleted", "started", "stopped", "renamed")):
                    now = time.time()
                    if now - last_sync < AUTO_EVENT_DEBOUNCE:
                        continue
                    last_sync = now
                    log("收到 Incus 事件，已合并到下一轮同步")
                    RECONCILE_EVENT.set()
            proc.wait(timeout=1)
        except Exception as exc:
            log("incus monitor 异常，稍后重连: %s" % exc)
        time.sleep(3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true", help="run one reconciliation and exit")
    args = parser.parse_args()
    os.makedirs(CONFIG_DIR, exist_ok=True)
    if args.once:
        maybe_sync_split_rules(force=False)
        maybe_refresh_split_dns(force=False)
        reconcile(force_client_check=True, force_ip_refresh=True)
        return
    threading.Thread(target=watch_events, daemon=True).start()
    next_run = 0.0
    last_run = 0.0
    while True:
        timeout = max(0.0, next_run - time.monotonic())
        triggered = RECONCILE_EVENT.wait(timeout=timeout)
        RECONCILE_EVENT.clear()
        if triggered and last_run:
            delay = AUTO_RECONCILE_MIN_INTERVAL - (time.monotonic() - last_run)
            if delay > 0:
                time.sleep(delay)
        try:
            maybe_sync_split_rules(force=False)
            maybe_refresh_split_dns(force=False)
            reconcile()
        except Exception as exc:
            log("定时同步失败: %s" % exc)
        last_run = time.monotonic()
        next_run = time.monotonic() + max(AUTO_INTERVAL, 5)


if __name__ == "__main__":
    main()
PY
    python3 -m py_compile "$tmp"
    rm -rf "$LIB_DIR/__pycache__"
    chmod 0755 "$tmp"
    mv -f "$tmp" "$AUTOSYNC_FILE"
}

write_service() {
    load_config
    local service_tmp autosync_tmp service_dir autosync_dir
    service_dir="$(dirname "$SERVICE_FILE")"
    autosync_dir="$(dirname "$AUTOSYNC_SERVICE")"
    mkdir -p "$service_dir" "$autosync_dir"
    service_tmp="$(mktemp "$service_dir/.${APP_NAME}.service.XXXXXX")"
    autosync_tmp="$(mktemp "$autosync_dir/.${APP_NAME}-autosync.service.XXXXXX")"
    cat > "$service_tmp" <<EOF
[Unit]
Description=Incus container self-service egress switch API
After=network-online.target systemd-sysctl.service
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
Environment=EGRESS_CONFIG_DIR=$CONFIG_DIR
Environment=EGRESS_MANAGER_BIN=$INSTALL_BIN
EnvironmentFile=-$CONFIG_FILE
ExecStartPre=/bin/sh -c 'if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then [ -e "$PENDING_NFT_FILE" ] && exec "$INSTALL_BIN" apply; exec "$INSTALL_BIN" apply-nft; else exec "$INSTALL_BIN" apply; fi'
ExecStart=/usr/bin/python3 $CONTROLLER_FILE
Restart=always
RestartSec=2
KillMode=mixed
TimeoutStopSec=30
NoNewPrivileges=true
TasksMax=96
LimitNOFILE=65536
CPUWeight=60
OOMScoreAdjust=-100

[Install]
WantedBy=multi-user.target
EOF

    cat > "$autosync_tmp" <<EOF
[Unit]
Description=Incus container egress autosync
After=network-online.target systemd-sysctl.service incus.service $APP_NAME.service
Wants=network-online.target $APP_NAME.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
Environment=EGRESS_CONFIG_DIR=$CONFIG_DIR
Environment=EGRESS_MANAGER_BIN=$INSTALL_BIN
Environment=EGRESS_OUT_CLIENT=$OUT_CLIENT_FILE
EnvironmentFile=-$CONFIG_FILE
ExecStart=/usr/bin/python3 $AUTOSYNC_FILE
Restart=always
RestartSec=3
KillMode=mixed
TimeoutStopSec=45
Nice=10
CPUWeight=20
IOWeight=20
TasksMax=256
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$service_tmp" "$autosync_tmp"
    mv -f "$service_tmp" "$SERVICE_FILE"
    mv -f "$autosync_tmp" "$AUTOSYNC_SERVICE"
}

refresh_existing_exit_service_hooks() {
    local name mark table route4 route6 display dev service
    while IFS=$'\t' read -r name mark table route4 route6 display; do
        service="$SYSTEMD_DIR/${EXIT_SERVICE_PREFIX}-${name}.service"
        [ -f "$service" ] || continue
        dev="$(exit_limit_device "$route4" "$route6" || true)"
        [ -n "$dev" ] || continue
        python3 - "$service" "$dev" "$INSTALL_BIN" "$name" <<'PY'
import os
import sys
import tempfile

path, dev, manager, name = sys.argv[1:5]
desired = "ExecStartPost=/bin/sh -c 'for i in $(seq 1 20); do ip link show \"$1\" >/dev/null 2>&1 && break; sleep 1; done; \"$2\" apply-exit-route \"$3\" >/dev/null 2>&1 || true' sh %s %s %s\n" % (dev, manager, name)
with open(path, "r", encoding="utf-8") as fh:
    lines = list(fh)
changed = False
for index, line in enumerate(lines):
    if line.startswith("ExecStartPost=/bin/sh -c") and (" apply " in line or "apply-exit-route" in line):
        if line != desired:
            lines[index] = desired
            changed = True
        break
if changed:
    fd, tmp = tempfile.mkstemp(prefix=".%s." % os.path.basename(path), dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.writelines(lines)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
PY
    done < <(read_exit_rows)
}

install_host() {
    need_root
    local autosync_was_active="false"
    install_host_dependencies
    need_cmd install
    need_cmd python3
    need_cmd systemctl
    need_cmd ip
    need_cmd nft
    need_cmd incus
    need_cmd curl
    need_cmd tar
    install_runtime_sysctls
    write_default_config
    ensure_runtime_config_defaults
    load_config
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$APP_NAME-autosync" && autosync_was_active="true"
        systemctl stop "$APP_NAME-autosync" "$APP_NAME" 2>/dev/null || true
    fi
    do_apply
    mkdir -p "$LIB_DIR" "$RUN_DIR"
    if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")" != "$INSTALL_BIN" ]; then
        install_self_atomically "$0"
    fi
    install_shortcut
    write_controller
    write_autosync
    write_client_file
    write_service
    refresh_existing_exit_service_hooks
    systemctl daemon-reload
    systemctl enable "$APP_NAME" >/dev/null
    systemctl restart "$APP_NAME"
    if [ "$autosync_was_active" = "true" ]; then
        systemctl restart "$APP_NAME-autosync" >/dev/null 2>&1 || true
    fi
    info "宿主机基础组件和控制器文件已安装。"
    info "安装步骤不会扫描或接管容器；需要接管时请在主菜单选择 7 或 8。"
    info "API 服务已启动并设置开机自启: $APP_NAME"
}

# 生成容器内使用的轻量客户端。容器只需要 curl/wget 和自己的 token。
client_script() {
    load_config
    cat <<EOF
#!/bin/sh
# cloudshlii out client v2
set -u
API_URL="\${EGRESS_API_URL:-$API_PUBLIC_URL}"
EOF
    cat <<'EOF'
TOKEN_FILE="${EGRESS_TOKEN_FILE:-/etc/incus-egress-token}"
TOKEN="${EGRESS_TOKEN:-}"

if [ -z "$TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
    TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
fi

if [ -t 1 ]; then
    C_RESET="$(printf '\033[0m')"
    C_BOLD="$(printf '\033[1m')"
    C_DIM="$(printf '\033[2m')"
    C_GREEN="$(printf '\033[32m')"
    C_CYAN="$(printf '\033[36m')"
    C_YELLOW="$(printf '\033[33m')"
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_GREEN=""
    C_CYAN=""
    C_YELLOW=""
fi

line() { printf '%s\n' '============================================================'; }
subline() { printf '%s\n' '------------------------------------------------------------'; }
title() { line; printf '%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; line; }
section() { printf '  %s【%s】%s\n' "$C_CYAN" "$1" "$C_RESET"; }

clear_screen() {
    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ] && command -v clear >/dev/null 2>&1; then
        clear
    fi
}

pause_back() {
    [ -t 0 ] || return 0
    printf '\n%s按回车返回上一层...%s' "$C_DIM" "$C_RESET"
    IFS= read -r _ || true
}

banner() {
    line
    printf '%s%s' "$C_CYAN" "$C_BOLD"
    cat <<'BANNER'
   ____ _                 _     _     _ _ _
  / ___| | ___  _   _  __| |___| |__ | (_) |
 | |   | |/ _ \| | | |/ _` / __| '_ \| | | |
 | |___| | (_) | |_| | (_| \__ \ | | | | | |
  \____|_|\___/ \__,_|\__,_|___/_| |_|_|_|_|
BANNER
    printf '%s' "$C_RESET"
    line
    printf '  %s+-------------- %scloudshlii容器出口工具%s%s --------------+%s\n' "$C_CYAN" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '\n'
}

need_http() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
        echo "缺少 curl 或 wget 命令" >&2
        exit 1
    }
}

have_curl() {
    command -v curl >/dev/null 2>&1
}

sec_to_ms() {
    awk -v s="${1:-0}" 'BEGIN { printf "%.0fms", s * 1000 }' 2>/dev/null || printf '%ss' "${1:-0}"
}

api_raw() {
    need_http
    if have_curl; then
        curl -fsS -H "X-Egress-Token: $TOKEN" "$1"
    else
        wget -qO- --header="X-Egress-Token: $TOKEN" "$1"
    fi
}

api_get() {
    api_raw "$1"
    echo
}

api_post_raw() {
    need_http
    if have_curl; then
        curl -sS -H "X-Egress-Token: $TOKEN" -X POST -d "$1" "$2"
    else
        wget -qO- --header="X-Egress-Token: $TOKEN" --post-data="$1" "$2"
    fi
}

api_post() {
    api_post_raw "$1" "$2"
    echo
}

api_post_exit() {
    need_http
    target="$1"
    if have_curl; then
        curl -sS -H "X-Egress-Token: $TOKEN" -X POST --data-urlencode "exit=$target" "$API_URL/use"
    else
        api_post_raw "exit=$target" "$API_URL/use"
    fi
}

api_post_split() {
    need_http
    app="$1"
    target="$2"
    if have_curl; then
        curl -sS -H "X-Egress-Token: $TOKEN" -X POST --data-urlencode "app=$app" --data-urlencode "exit=$target" "$API_URL/split/use"
    else
        api_post_raw "app=$app&exit=$target" "$API_URL/split/use"
    fi
}

json_value() {
    key="$1"
    sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p"
}

json_ok() {
    grep -q '"ok":true'
}

json_exits() {
    sed -n 's/.*"exits":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | sed 's/^"//;s/"$//;/^$/d'
}

is_entry_exit() {
    case "${1:-}" in
        -|入口机|host|direct|entry|local|main) return 0 ;;
        *) return 1 ;;
    esac
}

display_exit() {
    case "${1:-}" in
        ""|-) echo "入口机" ;;
        *) echo "$1" ;;
    esac
}

api_exit_target() {
    case "${1:-}" in
        -|入口机) echo "-" ;;
        *) echo "$1" ;;
    esac
}

same_exit() {
    [ "${1:-}" = "${2:-}" ] && return 0
    is_entry_exit "${1:-}" && is_entry_exit "${2:-}"
}

state_json() {
    api_raw "$API_URL/exits" 2>/dev/null || true
}

exit_list() {
    state_json | json_exits
}

print_current() {
    raw="$(state_json)"
    container="$(printf '%s' "$raw" | json_value container)"
    current="$(printf '%s' "$raw" | json_value current)"
    [ -n "$container" ] || { echo "无法读取容器状态，请检查 API/token。"; return 1; }
    printf '容器: %s\n' "$container"
    printf '当前出口: %s%s%s\n' "$C_GREEN" "$(display_exit "${current:-}")" "$C_RESET"
}

print_exits() {
    raw="$(state_json)"
    current="$(printf '%s' "$raw" | json_value current)"
    exits="$(printf '%s' "$raw" | json_exits)"
    title "可用出口"
    if [ -z "$exits" ]; then
        echo "  暂无可用出口"
        return 0
    fi
    printf '%s\n' "$exits" | while IFS= read -r item; do
        if same_exit "$item" "$current"; then
            printf '  %s*%s %s %s当前%s\n' "$C_GREEN" "$C_RESET" "$item" "$C_DIM" "$C_RESET"
        else
            echo "    $item"
        fi
    done
}

switch_exit() {
    target="${1:-}"
    [ -n "$target" ] || { echo "用法: out use 出口名" >&2; return 1; }
    resp="$(api_post_exit "$(api_exit_target "$target")" 2>/dev/null || true)"
    new_current="$(printf '%s' "$resp" | json_value current)"
    if printf '%s' "$resp" | json_ok; then
        echo "切换成功"
        echo "当前出口: $(display_exit "$new_current")"
        return 0
    fi
    err="$(printf '%s' "$resp" | json_value error)"
    echo "切换失败: ${err:-未知错误}" >&2
    return 1
}

split_lines() {
    api_raw "$API_URL/split.txt" 2>/dev/null || true
}

split_targets() {
    app="${1:-}"
    if [ -n "$app" ]; then
        api_raw "$API_URL/split-targets.txt?app=$app" 2>/dev/null || true
    else
        api_raw "$API_URL/split-targets.txt" 2>/dev/null || true
    fi
}

print_split_list() {
    lines="$(split_lines)"
    if [ -z "$lines" ]; then
        echo "暂无可用应用分流，或无法读取 API/token。"
        return 1
    fi
    title "应用分流"
    printf '%s\n' "$lines" | while IFS="$(printf '\t')" read -r app display category current default override choices; do
        [ -n "$app" ] || continue
        [ -n "$default" ] || default="未设置"
        [ -n "$override" ] || override="未设置"
        [ -n "$choices" ] || choices="$default"
        printf '  %s[%s]%s %s (%s)\n' "$C_CYAN" "$category" "$C_RESET" "$display" "$app"
        printf '    当前: %s  候选出口: %s  本容器覆盖: %s\n' "$current" "$choices" "$override"
    done
}

choose_split_app() {
    out_file="${1:-}"
    [ -n "$out_file" ] || return 1
    tmp="/tmp/out-split-apps.$$"
    split_lines > "$tmp"
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo "暂无可用应用分流" >&2
        return 1
    fi
    # 强制策略由宿主机控制，实例不能创建或恢复容器级覆盖。
    # 后端提交接口仍会再次校验；这里提前从可选应用中移除，避免误导用户。
    awk -F '\t' '$6 != "按当前出口强制" && $6 != "宿主机强制"' "$tmp" > "$tmp.selectable"
    mv -f "$tmp.selectable" "$tmp"
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo "当前应用均由宿主机强制分流，实例不可自行切换。" >&2
        return 1
    fi
    title "选择应用"
    printf '  %s[0]%s 返回上一层\n' "$C_GREEN" "$C_RESET"
    i=1
    while IFS="$(printf '\t')" read -r app display category current default override choices || [ -n "${app:-}" ]; do
        printf '  %s[%s]%s [%s] %s (%s)  当前: %s\n' "$C_GREEN" "$i" "$C_RESET" "$category" "$display" "$app" "$current"
        i=$((i + 1))
    done < "$tmp"
    subline
    printf "请输入序号、应用ID或显示名，0 返回: "
    read -r pick
    case "$pick" in
        ""|0) rm -f "$tmp"; return 2 ;;
        *[!0-9]*)
            target="$(awk -F '\t' -v p="$pick" '$1 == p || $2 == p {print $1; exit}' "$tmp")"
            ;;
        *) target="$(sed -n "${pick}p" "$tmp" | awk -F '\t' '{print $1}')" ;;
    esac
    rm -f "$tmp"
    [ -n "$target" ] || { echo "未找到这个应用。"; return 1; }
    printf '%s\n' "$target" > "$out_file"
}

choose_split_target() {
    out_file="${1:-}"
    app="${2:-}"
    [ -n "$out_file" ] || return 1
    tmp="/tmp/out-split-targets.$$"
    split_targets "$app" > "$tmp"
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo "暂无可用分流目标" >&2
        return 1
    fi
    title "选择分流目标"
    printf '  %s[0]%s 返回上一层\n' "$C_GREEN" "$C_RESET"
    i=1
    while IFS="$(printf '\t')" read -r target display || [ -n "${target:-}" ]; do
        printf '  %s[%s]%s %s\n' "$C_GREEN" "$i" "$C_RESET" "$display"
        i=$((i + 1))
    done < "$tmp"
    subline
    printf "请输入序号或出口名，0 返回: "
    read -r pick
    case "$pick" in
        ""|0) rm -f "$tmp"; return 2 ;;
        *[!0-9]*)
            target="$(awk -F '\t' -v p="$pick" '$1 == p || $2 == p {print $1; exit}' "$tmp")"
            ;;
        *) target="$(sed -n "${pick}p" "$tmp" | awk -F '\t' '{print $1}')" ;;
    esac
    rm -f "$tmp"
    [ -n "$target" ] || { echo "未找到这个分流目标。"; return 1; }
    printf '%s\n' "$target" > "$out_file"
}

switch_split() {
    app="${1:-}"
    target="${2:-}"
    [ -n "$app" ] && [ -n "$target" ] || { echo "用法: out split use 应用 出口" >&2; return 1; }
    resp="$(api_post_split "$app" "$target" 2>/dev/null || true)"
    ok="$(printf '%s' "$resp" | json_value ok)"
    new_target="$(printf '%s' "$resp" | json_value target)"
    app_name="$(printf '%s' "$resp" | json_value app)"
    if [ "$ok" = "true" ] || [ -n "$new_target" ]; then
        echo "应用分流已更新"
        echo "应用: ${app_name:-$app}"
        echo "当前分流: ${new_target:-未知}"
        return 0
    fi
    err="$(printf '%s' "$resp" | json_value error)"
    echo "应用分流切换失败: ${err:-未知错误}" >&2
    return 1
}

split_menu() {
    while :; do
        clear_screen
        title "cloudshlii 应用分流切换"
        section "分流操作"
        printf '    %s[1]%s 查看应用分流              %s[2]%s 切换应用分流\n' "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET"
        printf '    %s[3]%s 恢复应用为宿主机默认\n' "$C_GREEN" "$C_RESET"
        printf '\n'
        printf '  ------------------------------------------------------------\n'
        printf '    %s[0]%s 返回上一层\n' "$C_GREEN" "$C_RESET"
        line
        printf "请输入选项 [0-3]: "
        read -r choice
        case "$choice" in
            1)
                clear_screen
                print_split_list
                pause_back
                ;;
            2)
                app_file="/tmp/out-split-app.$$"
                target_file="/tmp/out-split-target.$$"
                if choose_split_app "$app_file"; then
                    app="$(cat "$app_file")"
                else
                    rc="$?"
                    rm -f "$app_file" "$target_file"
                    [ "$rc" = "2" ] || pause_back
                    continue
                fi
                if choose_split_target "$target_file" "$app"; then
                    target="$(cat "$target_file")"
                    clear_screen
                    switch_split "$app" "$target"
                    pause_back
                else
                    rc="$?"
                    [ "$rc" = "2" ] || pause_back
                fi
                rm -f "$app_file" "$target_file"
                ;;
            3)
                app_file="/tmp/out-split-app.$$"
                if choose_split_app "$app_file"; then
                    app="$(cat "$app_file")"
                    clear_screen
                    switch_split "$app" "__default__"
                    pause_back
                else
                    rc="$?"
                    [ "$rc" = "2" ] || pause_back
                fi
                rm -f "$app_file"
                ;;
            0) return 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

api_latency() {
    if have_curl; then
        t="$(curl -fsS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{time_total}' "$API_URL/health" 2>/dev/null || true)"
        [ -n "$t" ] && { sec_to_ms "$t"; return 0; }
    fi
    echo "不可用"
}

ip_probe() {
    family="$1"
    url="$2"
    flag="$3"
    if have_curl; then
        curl "$flag" -fsS --connect-timeout 8 --max-time 20 "$url" 2>/dev/null || true
    else
        wget -qO- "$url" 2>/dev/null || true
    fi
}

ping_probe() {
    ip="$1"
    [ -n "$ip" ] || { echo "出口 Ping: unavailable"; return 1; }
    command -v ping >/dev/null 2>&1 || { echo "出口 Ping: 未安装 ping"; return 1; }
    out="$(ping -c 3 -W 2 "$ip" 2>/dev/null || true)"
    if [ -z "$out" ]; then
        echo "出口 Ping: unavailable"
        return 1
    fi
    echo "出口 Ping:"
    printf '%s\n' "$out" | awk '
        /time=/ {
            v=$0
            sub(/^.*time=/, "", v)
            sub(/[[:space:]]*ms.*$/, "", v)
            n++
            sum += v
            printf "  #%d %sms\n", n, v
        }
        END {
            if (n > 0) printf "  平均 %.3fms\n", sum / n
        }'
}

exit_test() {
    target="${1:-}"
    raw="$(state_json)"
    current="$(printf '%s' "$raw" | json_value current)"
    container="$(printf '%s' "$raw" | json_value container)"
    [ -n "$container" ] || { echo "无法读取容器状态，请检查 API/token。"; return 1; }
    [ -n "$target" ] || target="$current"
    [ -n "$target" ] || { echo "当前没有可测试的出口。"; return 1; }
    if ! printf '%s' "$raw" | json_exits | grep -qx "$target"; then
        if is_entry_exit "$target" && printf '%s' "$raw" | json_exits | grep -qx "入口机"; then
            target="入口机"
        fi
    fi

    restore=""
    if ! same_exit "$target" "$current"; then
        echo "临时切换出口: $(display_exit "$current") -> $(display_exit "$target")"
        resp="$(api_post_exit "$(api_exit_target "$target")" 2>/dev/null || true)"
        new_current="$(printf '%s' "$resp" | json_value current)"
        if ! printf '%s' "$resp" | json_ok; then
            err="$(printf '%s' "$resp" | json_value error)"
            echo "临时切换失败: ${err:-未知错误}"
            return 1
        fi
        target="$new_current"
        restore="$current"
        sleep 1
    fi

    echo "出口测试"
    echo "容器: $container"
    echo "测试出口: $(display_exit "$target")"
    echo "API 延迟: $(api_latency)"
    v4="$(ip_probe "IPv4" "https://api.ipify.org" "-4")"
    if [ -n "$v4" ]; then
        echo "IPv4: $v4"
        ping_probe "$v4"
        echo "DNS: 正常"
    else
        echo "IPv4: unavailable"
        echo "DNS: 未确认"
    fi
    v6="$(ip_probe "IPv6" "https://api6.ipify.org" "-6")"
    if [ -n "$v6" ]; then
        echo "IPv6: $v6"
    else
        echo "IPv6: unavailable"
    fi

    if [ -n "$restore" ]; then
        echo "恢复原出口: $(display_exit "$restore")"
        api_post_exit "$(api_exit_target "$restore")" >/dev/null 2>&1 || echo "警告: 原出口恢复失败，请手动执行 out use $(display_exit "$restore")"
    fi
}

choose_exit() {
    out_file="${1:-}"
    [ -n "$out_file" ] || return 1
    tmp="/tmp/out-exits.$$"
    exit_list > "$tmp"
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo "暂无可用出口" >&2
        return 1
    fi
    title "选择出口"
    printf '  %s[0]%s 返回上一层\n' "$C_GREEN" "$C_RESET"
    i=1
    while IFS= read -r item || [ -n "$item" ]; do
        [ -n "$item" ] || continue
        printf '  %s[%s]%s %s\n' "$C_GREEN" "$i" "$C_RESET" "$item"
        i=$((i + 1))
    done < "$tmp"
    subline
    printf "请输入序号或出口名，0 返回: "
    read -r pick
    case "$pick" in
        ""|0) rm -f "$tmp"; return 2 ;;
        *[!0-9]*) target="$pick" ;;
        *) target="$(sed -n "${pick}p" "$tmp")" ;;
    esac
    rm -f "$tmp"
    [ -n "$target" ] || { echo "未找到这个出口。"; return 1; }
    printf '%s\n' "$target" > "$out_file"
}

menu() {
    while :; do
        clear_screen
        banner
        print_current 2>/dev/null || true
        subline
        section "出口操作"
        printf '    %s[1]%s 查看当前出口              %s[2]%s 查看可用出口\n' "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET"
        printf '    %s[3]%s 切换出口                  %s[4]%s 出口测试\n' "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET"
        printf '\n'
        section "分流操作"
        printf '    %s[5]%s 应用分流切换\n' "$C_GREEN" "$C_RESET"
        printf '\n'
        printf '  ------------------------------------------------------------\n'
        printf '    %s[0]%s 退出\n' "$C_GREEN" "$C_RESET"
        line
        printf "请输入选项 [0-5]: "
        read -r choice
        case "$choice" in
            1)
                clear_screen
                title "当前出口"
                print_current
                pause_back
                ;;
            2)
                clear_screen
                print_exits
                pause_back
                ;;
            3)
                choice_file="/tmp/out-choice.$$"
                if choose_exit "$choice_file"; then
                    target="$(cat "$choice_file")"
                    rm -f "$choice_file"
                    clear_screen
                    switch_exit "$target"
                    pause_back
                else
                    rc="$?"
                    rm -f "$choice_file"
                    [ "$rc" = "2" ] || pause_back
                fi
                ;;
            4)
                choice_file="/tmp/out-choice.$$"
                if choose_exit "$choice_file"; then
                    target="$(cat "$choice_file")"
                    rm -f "$choice_file"
                    clear_screen
                    exit_test "$target"
                    pause_back
                else
                    rc="$?"
                    rm -f "$choice_file"
                    [ "$rc" = "2" ] || pause_back
                fi
                ;;
            5) split_menu ;;
            0) exit 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

show_help() {
    cat <<'HELP'
用法:
  out                 进入交互菜单
  out list            查看可用出口
  out current         查看当前出口
  out use 出口名      切换出口
  out use 入口机      切回入口机直出
  out test [出口名]   出口测试；指定出口时会临时切换，测完恢复
  out split           进入应用分流切换菜单
  out split list      查看本容器应用分流
  out split use 应用 出口
  out split default 应用
  out help            查看帮助
HELP
}

case "${1:-menu}" in
    ""|menu)
        menu
        ;;
    list)
        print_exits
        ;;
    current)
        print_current
        ;;
    use|switch)
        switch_exit "${2:-}"
        ;;
    test)
        exit_test "${2:-}"
        ;;
    split)
        case "${2:-menu}" in
            ""|menu)
                split_menu
                ;;
            list)
                print_split_list
                ;;
            use)
                switch_split "${3:-}" "${4:-}"
                ;;
            default)
                switch_split "${3:-}" "__default__"
                ;;
            *)
                echo "用法: out split [list|use 应用 出口|default 应用]" >&2
                exit 1
                ;;
        esac
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        show_help >&2
        exit 1
        ;;
esac
EOF
}

write_client_file() {
    mkdir -p "$LIB_DIR"
    local tmp
    tmp="$(mktemp "$LIB_DIR/out.XXXXXX")"
    client_script > "$tmp"
    sh -n "$tmp"
    chmod 0755 "$tmp"
    mv -f "$tmp" "$OUT_CLIENT_FILE"
}

ensure_autosync_files() {
    mkdir -p "$LIB_DIR"
    write_autosync
    write_client_file
}

sync_now() {
    local manager_bin
    need_root
    load_config
    need_cmd incus
    need_cmd python3
    ensure_autosync_files
    manager_bin="$INSTALL_BIN"
    [ -x "$manager_bin" ] || manager_bin="$0"
    "$manager_bin" apply 2>/dev/null || do_apply
    EGRESS_CONFIG_DIR="$CONFIG_DIR" EGRESS_MANAGER_BIN="$manager_bin" EGRESS_OUT_CLIENT="$OUT_CLIENT_FILE" \
        python3 "$AUTOSYNC_FILE" --once
}

enable_autosync() {
    need_root
    need_cmd systemctl
    ensure_autosync_files
    write_service
    systemctl daemon-reload
    systemctl enable "$APP_NAME-autosync"
    # 大规模宿主机上旧进程可能正在扫描/注入数百台容器；异步重启避免菜单等待 TimeoutStopSec。
    systemctl restart --no-block "$APP_NAME-autosync"
    info "自动同步服务重启任务已提交: $APP_NAME-autosync（后台完成，不阻塞当前操作）"
}

disable_autosync() {
    need_root
    need_cmd systemctl
    systemctl disable --now "$APP_NAME-autosync" 2>/dev/null || true
    info "自动同步服务已停止。"
}

pause_screen() {
    local _
    read -r -p "按回车键继续..." _ || true
}

prompt_required() {
    local label="$1" value
    while true; do
        read -r -p "$label: " value
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
        warn "输入不能为空。"
    done
}

prompt_default() {
    local label="$1" default="$2" value
    read -r -p "$label [$default]: " value
    printf '%s\n' "${value:-$default}"
}

prompt_exit_name() {
    local label="$1" value
    while true; do
        value="$(prompt_required "$label")"
        value="$(normalize_display_name "$value")"
        printf '%s\n' "$value"
        return 0
    done
}

prompt_proxy_host() {
    local label="$1" value
    while true; do
        value="$(prompt_required "$label")"
        value="$(normalize_proxy_host "$value")"
        if valid_proxy_host "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
        warn "地址无效。请输入纯 IP 或域名/DDNS，不要带协议、端口、路径或空格。"
    done
}

prompt_proxy_port() {
    local label="$1" value
    while true; do
        value="$(prompt_required "$label")"
        if validate_port "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
        warn "端口无效，请输入 1-65535。"
    done
}

prompt_required_secret() {
    local label="$1" value
    while true; do
        read -r -s -p "$label: " value
        printf '\n' >&2
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
        warn "输入不能为空。"
    done
}

prompt_optional_secret() {
    local label="$1" value
    read -r -s -p "$label: " value
    printf '\n' >&2
    printf '%s\n' "$value"
}

prompt_ss_method() {
    local method
    printf '常用加密方式: aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305\n' >&2
    method="$(prompt_default "请输入加密方式名称" "chacha20-ietf-poly1305")"
    printf '%s\n' "$method"
}

confirm_yes() {
    local label="$1" answer
    read -r -p "$label [y/N]: " answer
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

print_exit_summary() {
    printf '\n当前出口:\n'
    if [ -f "$EXITS_FILE" ] && [ -n "$(read_exit_rows)" ]; then
        read_exit_rows | awk -F '\t' '{print "  - "$6"  id="$1"  mark="$2"  table="$3"  route4="$4"  route6="$5}'
    else
        printf '  暂无出口，请先添加。\n'
    fi
}

list_exits() {
    load_config
    local name mark table route4 route6 display status down up count=0
    printf '\n已添加出口信息:\n'
    while IFS=$'\t' read -r name mark table route4 route6 display; do
        [ -n "$name" ] || continue
        count=$((count + 1))
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${EXIT_SERVICE_PREFIX}-${name}.service" >/dev/null 2>&1; then
            status="$(service_state "${EXIT_SERVICE_PREFIX}-${name}")"
        else
            status="手动路由/未托管服务"
        fi
        printf '  %s. %s\n' "$count" "${display:-$name}"
        printf '     内部ID: %s  服务状态: %s\n' "$name" "$status"
        printf '     fwmark: %s  路由表: %s\n' "$mark" "$table"
        printf '     IPv4路由: %s\n' "$route4"
        printf '     IPv6路由: %s\n' "$route6"
        down="$(exit_limit_down "$name")"
        up="$(exit_limit_up "$name")"
        printf '     共享限速: 下载 %s / 上传 %s\n' "$(limit_rate_label "$down")" "$(limit_rate_label "$up")"
    done < <(read_exit_rows)
    if [ "$count" -eq 0 ]; then
        printf '  暂无出口，请先添加。\n'
    fi
}

interactive_list_exits() {
    list_exits
    pause_screen
}

print_container_summary() {
    printf '\n当前容器:\n'
    if [ -f "$CONTAINERS_FILE" ] && [ -n "$(read_container_rows)" ]; then
        read_container_rows | awk -F '\t' '{cur=$5; if (cur=="-") cur="入口机"; print "  - "$1"  ip="$2"  allowed="$4"  current="cur}'
    else
        printf '  暂无容器，请先添加。\n'
    fi
}

interactive_install_host() {
    install_host
    pause_screen
}

interactive_init_config() {
    need_root
    write_default_config
    info "配置文件已初始化: $CONFIG_DIR"
    pause_screen
}

interactive_add_exit() {
    local idx default_mark default_table name mark table route4 route6
    need_root
    load_config
    write_default_config
    idx="$(read_exit_rows | awk 'END {print NR + 1}')"
    printf -v default_mark '0x51%02x' "$idx"
    default_table="$((100 + idx))"

    printf '\n出口代表一条真实线路、VPN、sing-box 实例或已有路由表。\n'
    printf 'route 写法示例: dev:tun-jp / via:192.0.2.1,dev:eth1 / none\n\n'
    name="$(prompt_required "出口名称，例如 hk jp sg us")"
    mark="$(prompt_default "fwmark，建议保持唯一" "$default_mark")"
    table="$(prompt_default "路由表 ID，建议保持唯一" "$default_table")"
    route4="$(prompt_default "IPv4 默认路由" "dev:tun-$name")"
    route6="$(prompt_default "IPv6 默认路由，没 IPv6 可填 none" "none")"
    add_exit "$name" "$mark" "$table" "$route4" "$route6"
    pause_screen
}

interactive_add_container() {
    local name ip allowed current token
    need_root
    load_config
    write_default_config
    print_exit_summary

    printf '\n容器必须使用固定 IP。token 留空时会自动生成。\n\n'
    name="$(prompt_required "容器名称，例如 ct101")"
    ip="$(prompt_required "容器 IP，例如 10.88.0.21")"
    allowed="$(prompt_default "允许出口，逗号分隔，* 表示全部" "*")"
    current="$(prompt_default "默认当前出口，填 - 表示入口机直出" "-")"
    read -r -p "容器 token，留空自动生成: " token
    add_container "$name" "$ip" "$allowed" "$current" "$token"
    pause_screen
}

interactive_set_container() {
    local ref new_exit
    need_root
    load_config
    print_exit_summary
    print_container_summary
    printf '\n这个操作由宿主机管理员手动修改某台容器的当前出口；容器自助切换请使用容器内 out use。\n\n'
    ref="$(prompt_required "容器名称或容器 IP")"
    new_exit="$(prompt_required "目标出口名称")"
    set_container_exit "$ref" "$new_exit"
    pause_screen
}

interactive_apply() {
    need_root
    do_apply
    pause_screen
}

interactive_status() {
    show_status
    pause_screen
}

interactive_client_script() {
    local output
    load_config
    output="$(prompt_default "生成容器端 out 客户端到哪个路径" "/tmp/out")"
    client_script > "$output"
    chmod 0755 "$output"
    info "容器端客户端已生成: $output"
    info "放入容器后保存为 /usr/local/bin/out，并把该容器 token 写入 /etc/incus-egress-token。"
    pause_screen
}

interactive_add_proxy_exit() {
    local choice link parsed default_name name server port username password method uuid endpoint peer_key address4 address6 psk mtu
    need_root
    load_config
    write_default_config
    printf '\n请选择要添加的出口类型:\n'
    printf '  1. SS 链接导入\n'
    printf '  2. SS 手动输入\n'
    printf '  3. SK5 链接导入\n'
    printf '  4. SK5 手动输入\n'
    printf '  5. VLESS+TCP 链接导入\n'
    printf '  6. VLESS+TCP 手动输入\n'
    printf '  7. WireGuard 原生隧道\n'
    printf '  0. 返回主菜单\n'
    read -r -p "请输入序号 [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        0) return 0 ;;
        1)
            printf '\n请粘贴 SS 节点链接，格式类似 ss://...#名称。\n'
            link="$(prompt_required "SS 节点链接")"
            parsed=$(parse_ss_link "$link") || { warn "SS 链接解析失败。"; pause_screen; return 0; }
            # 链接导入时直接采用节点链接 # 后面的名称；没有 # 名称时解析器会用地址生成兜底名称。
            default_name=$(printf '%s' "$parsed" | awk -F '\t' '{print $1}')
            info "将使用节点链接解析出的出口名称: $default_name"
            add_ss_exit_link "$link"
            ;;
        2)
            printf '\n[Shadowsocks] 请输入节点信息:\n'
            name="$(prompt_exit_name "自定义出口显示名，容器里 out use 会用这个名字，例如 美国-SS")"
            server="$(prompt_proxy_host "地址 / DDNS 域名")"
            port="$(prompt_proxy_port "端口")"
            password="$(prompt_required_secret "密码")"
            method="$(prompt_ss_method)"
            add_ss_exit_values "$name" "$method" "$password" "$server" "$port"
            ;;
        3)
            printf '\n请粘贴 SK5/SOCKS5 节点链接，格式类似 socks5://用户:密码@地址:端口#名称。\n'
            link="$(prompt_required "SK5 链接")"
            parsed=$(parse_socks_link "$link") || { warn "SK5 链接解析失败。"; pause_screen; return 0; }
            # 链接导入时直接采用节点链接 # 后面的名称；没有 # 名称时解析器会用地址生成兜底名称。
            default_name=$(printf '%s' "$parsed" | awk -F '\t' '{print $1}')
            info "将使用节点链接解析出的出口名称: $default_name"
            add_sk5_exit "$link"
            ;;
        4)
            printf '\n[SOCKS5] 请输入节点信息:\n'
            name="$(prompt_exit_name "自定义出口显示名，容器里 out use 会用这个名字，例如 美国")"
            server="$(prompt_proxy_host "地址 / DDNS 域名")"
            port="$(prompt_proxy_port "端口")"
            read -r -p "用户名，可留空: " username
            password="$(prompt_optional_secret "密码，可留空")"
            add_sk5_exit "$name" "$server" "$port" "$username" "$password"
            ;;
        5)
            printf '\n请粘贴 VLESS+TCP 节点链接，格式类似 vless://UUID@地址:端口?encryption=none&type=tcp#名称。\n'
            link="$(prompt_required "VLESS+TCP 节点链接")"
            parsed=$(parse_vless_tcp_link "$link") || { warn "VLESS+TCP 链接解析失败。"; pause_screen; return 0; }
            default_name=$(printf '%s' "$parsed" | awk -F '\t' '{print $1}')
            info "将使用节点链接解析出的出口名称: $default_name"
            add_vless_exit_link "$link"
            ;;
        6)
            printf '\n[VLESS+TCP] 请输入节点信息（仅支持 encryption=none、无 TLS/Reality）:\n'
            name="$(prompt_exit_name "自定义出口显示名，容器里 out use 会用这个名字")"
            server="$(prompt_proxy_host "地址 / DDNS 域名")"
            port="$(prompt_proxy_port "端口")"
            uuid="$(prompt_required "用户 ID / UUID")"
            add_vless_exit_values "$name" "$server" "$port" "$uuid"
            ;;
        7)
            printf '\n[WireGuard] 入口机将自动生成私钥；现有 sing-box 出口不会被修改。\n'
            name="$(prompt_exit_name "自定义出口显示名，例如 日本-WG")"
            endpoint="$(prompt_required "出口服务器 Endpoint，例如 203.0.113.10:51820")"
            peer_key="$(prompt_required "出口服务器 WireGuard 公钥")"
            address4="$(prompt_default "入口机 IPv4 隧道地址（含前缀，不启用填 -）" "10.66.0.2/32")"
            address6="$(prompt_default "入口机 IPv6 隧道地址（含前缀，不启用填 -）" "-")"
            psk="$(prompt_optional_secret "预共享密钥 PSK（可留空）")"
            psk="${psk:--}"
            mtu="$(prompt_default "MTU" "1380")"
            add_wireguard_exit "$name" "$endpoint" "$peer_key" "$address4" "$address6" "$psk" "$mtu"
            ;;
        *) warn "无效选择。"; pause_screen; return 0 ;;
    esac
    pause_screen
}

interactive_add_ss_exit() {
    interactive_add_proxy_exit
}

interactive_wg_server_install() {
    local port address4 address6 mtu wan detected range min max
    detected="$(wg_server_detect_wan)"
    printf '\n这个功能用于部署“出口服务器”，不会安装 Incus，也不会修改现有 sing-box/realm 配置。\n'
    read -r -p "WireGuard UDP 监听端口（可自定义，直接回车随机）: " port
    if [ -z "$port" ]; then
        range="$(prompt_default "随机端口范围，格式 起始-结束" "20000-65535")"
        if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            min="${BASH_REMATCH[1]}"
            max="${BASH_REMATCH[2]}"
        else
            warn "随机端口范围格式无效: $range"
            return 0
        fi
        port="$(wg_random_free_udp_port "$min" "$max")" || { warn "范围 $range 内没有可用 UDP 端口。"; return 0; }
        info "已随机选择未占用 UDP 端口: $port"
    fi
    address4="$(prompt_default "服务端 IPv4 隧道地址（含前缀，不启用填 -）" "10.66.0.1/24")"
    address6="$(prompt_default "服务端 IPv6 隧道地址（含前缀，不启用填 -）" "-")"
    mtu="$(prompt_default "MTU" "1380")"
    wan="$(prompt_default "公网出口网卡" "${detected:-eth0}")"
    wg_server_install "$port" "$address4" "$address6" "$mtu" "$wan"
}

interactive_wg_server_add_peer() {
    local name public_key address4 address6 psk
    wg_server_load || { warn "请先部署 WireGuard 出口服务器。"; return 0; }
    printf '\n请填写入口母机创建 WG 出口后显示的公钥和隧道地址。\n'
    name="$(prompt_required "Peer 名称，例如 hk-mother-01")"
    public_key="$(prompt_required "入口母机 WireGuard 公钥")"
    address4="$(prompt_default "入口母机 IPv4 隧道地址（建议 /32，不启用填 -）" "10.66.0.2/32")"
    address6="$(prompt_default "入口母机 IPv6 隧道地址（建议 /128，不启用填 -）" "-")"
    psk="$(prompt_optional_secret "预共享密钥 PSK（可留空）")"
    psk="${psk:--}"
    wg_server_add_peer "$name" "$public_key" "$address4" "$address6" "$psk"
}

interactive_wg_server_remove_peer() {
    local name
    wg_server_load || { warn "WireGuard 出口服务器尚未部署。"; return 0; }
    printf '\n当前 Peer:\n'
    awk -F '\t' '$1 !~ /^#/ && NF {print "  - "$1"  IPv4="$3"  IPv6="$4}' "$WG_SERVER_PEERS"
    name="$(prompt_required "要删除的 Peer 名称")"
    confirm_yes "确认删除 Peer '$name' 吗" || { info "已取消。"; return 0; }
    wg_server_remove_peer "$name"
}

interactive_wg_server_check() {
    local port
    port="$(prompt_required "计划使用的 WireGuard UDP 端口")"
    if ! wg_server_preflight "$port"; then
        warn "检测存在失败项，暂不建议部署。"
    fi
}

interactive_wg_server_menu() {
    local choice
    while true; do
        printf '\n'
        ui_title "WireGuard 出口服务器管理"
        printf '  1. 检测当前机器是否满足 WG 出口部署\n'
        printf '  2. 一键部署 / 重新配置 WG 出口服务器\n'
        printf '  3. 添加或更新入口母机 Peer\n'
        printf '  4. 查看服务、Peer、握手和流量\n'
        printf '  5. 删除入口母机 Peer\n'
        printf '  6. 卸载 WG 出口服务器组件\n'
        printf '  0. 返回主菜单\n'
        read -r -p "请输入选项 [0-6]: " choice
        case "$choice" in
            1) interactive_wg_server_check; pause_screen ;;
            2) interactive_wg_server_install; pause_screen ;;
            3) interactive_wg_server_add_peer; pause_screen ;;
            4) wg_server_status || true; pause_screen ;;
            5) interactive_wg_server_remove_peer; pause_screen ;;
            6)
                if confirm_yes "确认卸载本脚本管理的 WG 出口服务和密钥吗"; then
                    wg_server_uninstall
                else
                    info "已取消。"
                fi
                pause_screen
                ;;
            0|"") return 0 ;;
            *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

choose_host_exit() {
    local out_file="$1" tmp pick target i item
    [ -n "$out_file" ] || return 1
    tmp="$(mktemp)"
    read_exit_rows | awk -F '\t' '{print $1 "\t" $6}' > "$tmp"
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        warn "暂无出口可删除。"
        return 1
    fi
    printf '\n请选择出口:\n'
    printf '  0. 返回上一步\n'
    i=1
    while IFS=$'\t' read -r item display; do
        printf '  %s. %s\n' "$i" "${display:-$item}"
        i=$((i + 1))
    done < "$tmp"
    read -r -p "请输入序号或出口名: " pick
    case "$pick" in
        ""|0) target="" ;;
        *[!0-9]*) target="$pick" ;;
        *) target="$(sed -n "${pick}p" "$tmp" | awk -F '\t' '{print $1}')" ;;
    esac
    rm -f "$tmp"
    [ -n "$target" ] || return 1
    printf '%s\n' "$target" > "$out_file"
}

interactive_set_exit_limit() {
    local choice_file target down up
    choice_file="/tmp/incus-egress-limit-choice.$$"
    if ! choose_host_exit "$choice_file"; then
        rm -f "$choice_file"
        return 0
    fi
    target="$(cat "$choice_file")"
    rm -f "$choice_file"
    printf '\n为出口 %s 设置共享限速。\n' "$(display_exit_name "$target")"
    printf '所有切到该出口的容器、普通分流和强制分流会共享这个总带宽。\n'
    printf '单位使用 Mbps；只输入数字默认按 Mbps；0 表示不限速。\n'
    printf '换算：1 Mbps = 0.125 MB/s，8 Mbps = 1 MB/s。\n'
    printf '示例：50Mbps、500Kbps、1Gbps。\n\n'
    down="$(prompt_default "下载限速（Mbps，容器下载方向）" "0")"
    up="$(prompt_default "上传限速（Mbps，容器上传方向，默认同下载）" "$down")"
    set_exit_limit "$target" "$down" "$up"
}

interactive_clear_exit_limit() {
    local choice_file target
    choice_file="/tmp/incus-egress-limit-choice.$$"
    if ! choose_host_exit "$choice_file"; then
        rm -f "$choice_file"
        return 0
    fi
    target="$(cat "$choice_file")"
    rm -f "$choice_file"
    clear_exit_limit "$target"
}

interactive_limit_menu() {
    local choice
    while true; do
        list_exit_limits
        printf '\n出口共享限速操作:\n'
        printf '  1. 设置出口限速\n'
        printf '  2. 清除单个出口限速\n'
        printf '  3. 清除全部出口限速\n'
        printf '  0. 返回主菜单\n'
        read -r -p "请输入序号: " choice
        case "$choice" in
            1) interactive_set_exit_limit; pause_screen ;;
            2) interactive_clear_exit_limit; pause_screen ;;
            3)
                if confirm_yes "确认清除所有出口限速吗"; then
                    clear_all_exit_limits
                else
                    info "已取消。"
                fi
                pause_screen
                ;;
            0|"") return 0 ;;
            *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

resolve_split_app_ref() {
    local ref="$1" matched=""
    split_app_exists "$ref" && { printf '%s\n' "$ref"; return 0; }
    matched="$(split_app_id_by_display "$ref")"
    [ -n "$matched" ] && { printf '%s\n' "$matched"; return 0; }
    return 1
}

choose_split_app() {
    local out_file="$1" tmp all_tmp cat_tmp filter_tmp pick target i app display category remote enabled selected_category
    [ -n "$out_file" ] || return 1
    if ! split_catalog_ready; then
        warn "尚未同步应用目录，请先在分流管理选择 1。"
        return 1
    fi
    all_tmp="$(mktemp)"
    cat_tmp="$(mktemp)"
    filter_tmp="$(mktemp)"
    read_split_apps > "$all_tmp"
    if [ ! -s "$all_tmp" ]; then
        rm -f "$all_tmp" "$cat_tmp" "$filter_tmp"
        warn "暂无应用目录。"
        return 1
    fi
    awk -F '\t' '{count[$3]++} END {for (c in count) print c "\t" count[c]}' "$all_tmp" | sort > "$cat_tmp"
    printf '\n请选择应用范围:\n'
    printf '  0. 返回上一步\n'
    printf '  直接输入应用ID/显示名/关键词可以搜索；直接回车显示全部应用。\n'
    i=1
    while IFS=$'\t' read -r category app_count || [ -n "${category:-}" ]; do
        [ -n "$category" ] || continue
        printf '  %s. [%s] %s 个应用\n' "$i" "$category" "$app_count"
        i=$((i + 1))
    done < "$cat_tmp"
    read -r -p "请输入分类序号或关键词: " pick
    case "$pick" in
        0) rm -f "$all_tmp" "$cat_tmp" "$filter_tmp"; return 1 ;;
        "")
            cp "$all_tmp" "$filter_tmp"
            ;;
        *[!0-9]*)
            target="$(resolve_split_app_ref "$pick" || true)"
            if [ -n "$target" ]; then
                rm -f "$all_tmp" "$cat_tmp" "$filter_tmp"
                printf '%s\n' "$target" > "$out_file"
                return 0
            fi
            awk -F '\t' -v q="$pick" 'BEGIN{IGNORECASE=1} index($1,q) || index($2,q) || index($3,q) {print}' "$all_tmp" > "$filter_tmp"
            ;;
        *)
            selected_category="$(sed -n "${pick}p" "$cat_tmp" | awk -F '\t' '{print $1}')"
            [ -n "$selected_category" ] || { rm -f "$all_tmp" "$cat_tmp" "$filter_tmp"; warn "未知分类序号。"; return 1; }
            awk -F '\t' -v c="$selected_category" '$3 == c {print}' "$all_tmp" > "$filter_tmp"
            ;;
    esac
    if [ ! -s "$filter_tmp" ]; then
        rm -f "$all_tmp" "$cat_tmp" "$filter_tmp"
        warn "没有匹配的应用。"
        return 1
    fi
    printf '\n请选择应用:\n'
    printf '  0. 返回上一步\n'
    i=1
    while IFS=$'\t' read -r app display category remote enabled || [ -n "${app:-}" ]; do
        printf '  %s. [%s] %s (%s)\n' "$i" "$category" "$display" "$app"
        i=$((i + 1))
    done < "$filter_tmp"
    read -r -p "请输入序号、应用ID或显示名: " pick
    case "$pick" in
        ""|0) target="" ;;
        *[!0-9]*) target="$(resolve_split_app_ref "$pick" || true)" ;;
        *) target="$(sed -n "${pick}p" "$filter_tmp" | awk -F '\t' '{print $1}')" ;;
    esac
    rm -f "$all_tmp" "$cat_tmp" "$filter_tmp"
    [ -n "$target" ] || return 1
    printf '%s\n' "$target" > "$out_file"
}

choose_split_category() {
    local out_file="$1" tmp pick target i
    [ -n "$out_file" ] || return 1
    if ! split_catalog_ready; then
        warn "尚未同步应用目录，请先在分流管理选择 1。"
        return 1
    fi
    tmp="$(mktemp)"
    read_split_apps | awk -F '\t' '{print $3}' | awk 'NF && !seen[$0]++' > "$tmp"
    printf '\n请选择分类:\n'
    printf '  0. 返回上一步\n'
    i=1
    while IFS= read -r target || [ -n "$target" ]; do
        printf '  %s. %s\n' "$i" "$target"
        i=$((i + 1))
    done < "$tmp"
    read -r -p "请输入序号或分类名: " pick
    case "$pick" in
        ""|0) target="" ;;
        *[!0-9]*) target="$pick" ;;
        *) target="$(sed -n "${pick}p" "$tmp")" ;;
    esac
    rm -f "$tmp"
    [ -n "$target" ] || return 1
    printf '%s\n' "$target" > "$out_file"
}

choose_split_category_or_custom() {
    local out_file="$1" tmp pick target i category app_count manual_idx
    [ -n "$out_file" ] || return 1
    if ! split_catalog_ready; then
        warn "尚未同步应用目录，请先在分流管理选择 1。"
        return 1
    fi
    tmp="$(mktemp)"
    read_split_apps | awk -F '\t' '{count[$3]++} END {for (c in count) print c "\t" count[c]}' | sort > "$tmp"
    printf '\n请选择自定义规则所属分类:\n'
    printf '  0. 返回上一步\n'
    i=1
    while IFS=$'\t' read -r category app_count || [ -n "${category:-}" ]; do
        [ -n "$category" ] || continue
        printf '  %s. %s（%s 个应用）\n' "$i" "$category" "$app_count"
        i=$((i + 1))
    done < "$tmp"
    manual_idx="$i"
    printf '  %s. 手动输入新分类\n' "$manual_idx"
    read -r -p "请输入序号或分类名: " pick
    case "$pick" in
        ""|0)
            target=""
            ;;
        *[!0-9]*)
            target="$(trim_space "$pick")"
            ;;
        *)
            if [ "$pick" -eq "$manual_idx" ] 2>/dev/null; then
                target="$(prompt_default "请输入新分类名" "自定义")"
                target="$(trim_space "$target")"
            else
                target="$(sed -n "${pick}p" "$tmp" | awk -F '\t' '{print $1}')"
            fi
            ;;
    esac
    rm -f "$tmp"
    [ -n "$target" ] || return 1
    printf '%s\n' "$target" > "$out_file"
}

choose_split_apps() {
    local out_file="$1" tmp pick part app apps="" comma="" i=1
    local parts=()
    [ -n "$out_file" ] || return 1
    split_catalog_ready || { warn "尚未同步应用目录。"; return 1; }
    tmp="$(mktemp)"; read_split_apps > "$tmp"
    printf '\n请选择一个或多个应用（英文逗号分隔）:\n  0. 返回上一步\n'
    while IFS=$'\t' read -r app display category _rest; do printf '  %s. [%s] %s (%s)\n' "$i" "$category" "$display" "$app"; i=$((i + 1)); done < "$tmp"
    read -r -p "请输入一个或多个序号/应用ID/显示名: " pick
    case "$pick" in ""|0) rm -f "$tmp"; return 1 ;; esac
    IFS=',' read -r -a parts <<< "$pick"
    for part in "${parts[@]}"; do
        part="$(trim_space "$part")"
        if [[ "$part" =~ ^[0-9]+$ ]]; then app="$(sed -n "${part}p" "$tmp" | awk -F '\t' '{print $1}')"; else app="$(resolve_split_app_ref "$part" || true)"; fi
        [ -n "$app" ] || { rm -f "$tmp"; warn "未知应用: $part"; return 1; }
        case ",$apps," in *,"$app",*) ;; *) [ -n "$apps" ] && comma="," || comma=""; apps="$apps$comma$app" ;; esac
    done
    rm -f "$tmp"; [ -n "$apps" ] || return 1; printf '%s\n' "$apps" > "$out_file"
}

choose_split_categories() {
    local out_file="$1" tmp pick part category categories="" comma="" i=1
    local parts=()
    [ -n "$out_file" ] || return 1
    split_catalog_ready || { warn "尚未同步应用目录。"; return 1; }
    tmp="$(mktemp)"; read_split_apps | awk -F '\t' '{print $3}' | awk 'NF && !seen[$0]++' > "$tmp"
    printf '\n请选择一个或多个分类（英文逗号分隔）:\n  0. 返回上一步\n'
    while IFS= read -r category; do printf '  %s. %s\n' "$i" "$category"; i=$((i + 1)); done < "$tmp"
    read -r -p "请输入一个或多个序号/分类名: " pick
    case "$pick" in ""|0) rm -f "$tmp"; return 1 ;; esac
    IFS=',' read -r -a parts <<< "$pick"
    for part in "${parts[@]}"; do
        part="$(trim_space "$part")"
        if [[ "$part" =~ ^[0-9]+$ ]]; then category="$(sed -n "${part}p" "$tmp")"; else category="$part"; fi
        grep -Fxq "$category" "$tmp" || { rm -f "$tmp"; warn "未知分类: $part"; return 1; }
        case ",$categories," in *,"$category",*) ;; *) [ -n "$categories" ] && comma="," || comma=""; categories="$categories$comma$category" ;; esac
    done
    rm -f "$tmp"; [ -n "$categories" ] || return 1; printf '%s\n' "$categories" > "$out_file"
}

choose_split_target() {
    local out_file="$1" prompt_label="${2:-分流目标}" tmp pick target i item display
    [ -n "$out_file" ] || return 1
    tmp="$(mktemp)"
    read_exit_rows | awk -F '\t' '{print $1 "\t" $6}' > "$tmp"
    printf '\n请选择%s:\n' "$prompt_label"
    printf '  0. 返回上一步\n'
    printf '  1. 入口机直出\n'
    i=2
    while IFS=$'\t' read -r item display || [ -n "${item:-}" ]; do
        printf '  %s. %s\n' "$i" "${display:-$item}"
        i=$((i + 1))
    done < "$tmp"
    read -r -p "请输入${prompt_label}的序号或出口名: " pick
    case "$pick" in
        "") target="" ;;
        0) target="" ;;
        1) target="-" ;;
        *[!0-9]*) target="$(resolve_exit_target "$pick" || true)" ;;
        *) target="$(sed -n "$((pick - 1))p" "$tmp" | awk -F '\t' '{print $1}')" ;;
    esac
    rm -f "$tmp"
    [ -n "$target" ] || return 1
    printf '%s\n' "$target" > "$out_file"
}

choose_split_targets() {
    local out_file="$1" prompt_label="${2:-分流候选出口（第一个为默认出口）}" tmp pick i item display part target targets="" seen=","
    local parts=()
    [ -n "$out_file" ] || return 1
    tmp="$(mktemp)"
    {
        printf -- '-\t入口机直出\n'
        read_exit_rows | awk -F '\t' '{print $1 "\t" $6}'
    } > "$tmp"
    printf '\n请选择%s:\n' "$prompt_label"
    printf '  0. 返回上一步\n'
    i=1
    while IFS=$'\t' read -r item display || [ -n "${item:-}" ]; do
        [ -n "$item" ] || continue
        printf '  %s. %s\n' "$i" "${display:-$item}"
        i=$((i + 1))
    done < "$tmp"
    read -r -p "请输入一个或多个序号/出口名，英文逗号分隔: " pick
    case "$pick" in
        ""|0) rm -f "$tmp"; return 1 ;;
    esac
    IFS=',' read -r -a parts <<< "$pick"
    for part in "${parts[@]}"; do
        part="$(trim_space "$part")"
        [ -n "$part" ] || continue
        if [[ "$part" =~ ^[0-9]+$ ]]; then
            target="$(sed -n "${part}p" "$tmp" | awk -F '\t' '{print $1}')"
        else
            target="$(resolve_exit_target "$part" || true)"
        fi
        if [ -z "$target" ]; then
            rm -f "$tmp"
            warn "未知分流候选出口: $part"
            return 1
        fi
        case "$seen" in
            *,"$target",*) ;;
            *)
                [ -n "$targets" ] && targets="$targets,"
                targets="$targets$target"
                seen="$seen$target,"
                ;;
        esac
    done
    rm -f "$tmp"
    [ -n "$targets" ] || return 1
    printf '%s\n' "$targets" > "$out_file"
}

choose_takeover_allowed_exits() {
    local out_file="$1" tmp pick i item display part target targets="" seen=","
    local parts=()
    [ -n "$out_file" ] || return 1
    tmp="$(mktemp)"
    read_exit_rows | awk -F '\t' '{print $1 "\t" $6}' > "$tmp.exits"
    if [ ! -s "$tmp.exits" ]; then
        rm -f "$tmp.exits"
        rm -f "$tmp"
        warn "暂无已添加出口，请先添加出口后再同步容器。"
        return 1
    fi
    {
        printf '*\t全部已添加出口\n'
        cat "$tmp.exits"
    } > "$tmp"
    rm -f "$tmp.exits"
    printf '\n请选择允许容器自助切换的出口:\n'
    printf '  0. 返回上一步\n'
    i=1
    while IFS=$'\t' read -r item display || [ -n "${item:-}" ]; do
        [ -n "$item" ] || continue
        printf '  %s. %s\n' "$i" "${display:-$item}"
        i=$((i + 1))
    done < "$tmp"
    printf '\n选择 1 可一次授权全部已添加出口；也可以输入一个或多个序号/出口名，英文逗号分隔。\n'
    printf '未选中的出口不会出现在容器 out 中，也不能通过 API 强制切换。\n'
    printf '入口机直出是内置回退，不属于已添加出口，容器始终可以切回入口机。\n'
    read -r -p "请输入授权出口: " pick
    case "$pick" in
        ""|0) rm -f "$tmp"; return 1 ;;
    esac
    IFS=',' read -r -a parts <<< "$pick"
    for part in "${parts[@]}"; do
        part="$(trim_space "$part")"
        [ -n "$part" ] || continue
        if [[ "$part" =~ ^[0-9]+$ ]]; then
            target="$(sed -n "${part}p" "$tmp" | awk -F '\t' '{print $1}')"
        else
            case "$part" in
                "*"|all|ALL|全部|全部出口) target="*" ;;
                *) target="$(resolve_exit_target "$part" || true)" ;;
            esac
        fi
        if [ "$target" = "*" ]; then
            rm -f "$tmp"
            printf '*\n' > "$out_file"
            return 0
        fi
        if [ -z "$target" ] || [ "$target" = "-" ]; then
            rm -f "$tmp"
            warn "未知或不可用于授权的出口: $part"
            return 1
        fi
        case "$seen" in
            *,"$target",*) ;;
            *)
                [ -n "$targets" ] && targets="$targets,"
                targets="$targets$target"
                seen="$seen$target,"
                ;;
        esac
    done
    rm -f "$tmp"
    [ -n "$targets" ] || return 1
    printf '%s\n' "$targets" > "$out_file"
}

interactive_split_set_app() {
    local app_file target_file app target
    app_file="/tmp/incus-egress-split-app.$$"
    target_file="/tmp/incus-egress-split-target.$$"
    choose_split_app "$app_file" || { rm -f "$app_file" "$target_file"; return 0; }
    choose_split_targets "$target_file" || { rm -f "$app_file" "$target_file"; return 0; }
    app="$(cat "$app_file")"
    target="$(cat "$target_file")"
    rm -f "$app_file" "$target_file"
    split_set_policy "$app" "$target"
}

interactive_split_set_category() {
    local category_file target_file category target
    category_file="/tmp/incus-egress-split-category.$$"
    target_file="/tmp/incus-egress-split-target.$$"
    choose_split_category "$category_file" || { rm -f "$category_file" "$target_file"; return 0; }
    choose_split_targets "$target_file" || { rm -f "$category_file" "$target_file"; return 0; }
    category="$(cat "$category_file")"
    target="$(cat "$target_file")"
    rm -f "$category_file" "$target_file"
    split_set_category_policy "$category" "$target"
}

interactive_split_clear_app() {
    local app_file app
    app_file="/tmp/incus-egress-split-clear.$$"
    choose_split_app "$app_file" || { rm -f "$app_file"; return 0; }
    app="$(cat "$app_file")"
    rm -f "$app_file"
    split_clear_policy "$app"
}

interactive_split_clear_category() {
    local category_file category
    category_file="/tmp/incus-egress-split-category-clear.$$"
    choose_split_category "$category_file" || { rm -f "$category_file"; return 0; }
    category="$(cat "$category_file")"
    rm -f "$category_file"
    split_clear_category_policy "$category"
}

interactive_split_force_app() {
    local app_file target_file app target
    app_file="/tmp/incus-egress-force-app.$$"
    target_file="/tmp/incus-egress-force-target.$$"
    choose_split_app "$app_file" || { rm -f "$app_file" "$target_file"; return 0; }
    choose_split_target "$target_file" || { rm -f "$app_file" "$target_file"; return 0; }
    app="$(cat "$app_file")"
    target="$(cat "$target_file")"
    rm -f "$app_file" "$target_file"
    split_force_policy "$app" "$target"
}

interactive_split_force_category() {
    local category_file target_file category target
    category_file="/tmp/incus-egress-force-category.$$"
    target_file="/tmp/incus-egress-force-target.$$"
    choose_split_category "$category_file" || { rm -f "$category_file" "$target_file"; return 0; }
    choose_split_target "$target_file" || { rm -f "$category_file" "$target_file"; return 0; }
    category="$(cat "$category_file")"
    target="$(cat "$target_file")"
    rm -f "$category_file" "$target_file"
    split_force_category_policy "$category" "$target"
}

interactive_split_force_clear_app() {
    local app_file app
    app_file="/tmp/incus-egress-force-clear.$$"
    choose_split_app "$app_file" || { rm -f "$app_file"; return 0; }
    app="$(cat "$app_file")"
    rm -f "$app_file"
    split_force_clear_policy "$app"
}

interactive_split_force_clear_category() {
    local category_file category
    category_file="/tmp/incus-egress-force-category-clear.$$"
    choose_split_category "$category_file" || { rm -f "$category_file"; return 0; }
    category="$(cat "$category_file")"
    rm -f "$category_file"
    split_force_clear_category_policy "$category"
}

interactive_split_force_on_exit_app() {
    local app_file source_file target_file app source target
    app_file="/tmp/incus-egress-force-source-app.$$"; source_file="/tmp/incus-egress-force-source.$$"; target_file="/tmp/incus-egress-force-target.$$"
    choose_split_apps "$app_file" || { rm -f "$app_file" "$source_file" "$target_file"; return 0; }
    choose_split_targets "$source_file" "来源出口（可多选）" || { rm -f "$app_file" "$source_file" "$target_file"; return 0; }
    choose_split_targets "$target_file" "强制分流目标候选（可多选，第一个为实际目标）" || { rm -f "$app_file" "$source_file" "$target_file"; return 0; }
    app="$(cat "$app_file")"; source="$(cat "$source_file")"; target="$(cat "$target_file")"
    rm -f "$app_file" "$source_file" "$target_file"
    split_force_on_exit_policy "$app" "$source" "$target"
}

interactive_split_force_on_exit_category() {
    local category_file source_file target_file category source target
    category_file="/tmp/incus-egress-force-source-category.$$"; source_file="/tmp/incus-egress-force-source.$$"; target_file="/tmp/incus-egress-force-target.$$"
    choose_split_categories "$category_file" || { rm -f "$category_file" "$source_file" "$target_file"; return 0; }
    choose_split_targets "$source_file" "来源出口（可多选）" || { rm -f "$category_file" "$source_file" "$target_file"; return 0; }
    choose_split_targets "$target_file" "强制分流目标候选（可多选，第一个为实际目标）" || { rm -f "$category_file" "$source_file" "$target_file"; return 0; }
    category="$(cat "$category_file")"; source="$(cat "$source_file")"; target="$(cat "$target_file")"
    rm -f "$category_file" "$source_file" "$target_file"
    split_force_category_on_exit_policy "$category" "$source" "$target"
}

interactive_split_force_on_exit_clear_app() {
    local app_file source_file app source
    app_file="/tmp/incus-egress-force-source-clear-app.$$"; source_file="/tmp/incus-egress-force-source.$$"
    choose_split_apps "$app_file" || { rm -f "$app_file" "$source_file"; return 0; }
    choose_split_targets "$source_file" "需要取消规则的来源出口（可多选）" || { rm -f "$app_file" "$source_file"; return 0; }
    app="$(cat "$app_file")"; source="$(cat "$source_file")"
    rm -f "$app_file" "$source_file"
    split_force_on_exit_clear_policy "$app" "$source"
}

interactive_split_force_on_exit_clear_category() {
    local category_file source_file category source
    category_file="/tmp/incus-egress-force-source-clear-category.$$"; source_file="/tmp/incus-egress-force-source.$$"
    choose_split_categories "$category_file" || { rm -f "$category_file" "$source_file"; return 0; }
    choose_split_targets "$source_file" "需要取消规则的来源出口（可多选）" || { rm -f "$category_file" "$source_file"; return 0; }
    category="$(cat "$category_file")"; source="$(cat "$source_file")"
    rm -f "$category_file" "$source_file"
    split_force_category_on_exit_clear_policy "$category" "$source"
}

interactive_split_add_custom() {
    local display category category_file tmp line
    if ! split_catalog_ready; then
        warn "尚未同步应用目录，请先选择 1 同步应用目录。"
        return 0
    fi
    display="$(prompt_required "请输入自定义应用名，例如: 公司后台")"
    category_file="/tmp/incus-egress-custom-category.$$"
    choose_split_category_or_custom "$category_file" || { rm -f "$category_file"; return 0; }
    category="$(cat "$category_file")"
    rm -f "$category_file"
    tmp="$(mktemp)"
    cat <<'EOF'

请输入自定义规则，每行一条，输入 END 结束。

支持示例:
  example.com
  *.example.com
  DOMAIN,api.example.com
  DOMAIN-SUFFIX,example.com
  203.0.113.10
  203.0.113.0/24
  2001:db8::/32

说明:
  - 直接填写 example.com 会按 DOMAIN-SUFFIX 处理，包含其子域名。
  - 只支持域名、IPv4/IPv6 地址和 CIDR 段，不支持 PROCESS-NAME、IP-ASN 等客户端本地规则。
EOF
    while true; do
        read -r -p "规则> " line || break
        [ "$line" = "END" ] && break
        printf '%s\n' "$line" >> "$tmp"
    done
    if ! awk 'NF && $1 !~ /^#/ {found=1} END {exit found ? 0 : 1}' "$tmp"; then
        rm -f "$tmp"
        warn "没有输入有效规则，已取消。"
        return 0
    fi
    split_add_custom_rule "$display" "$category" "$tmp"
    rm -f "$tmp"
}

print_split_header() {
    local total categories app_policies category_policies force_apps force_categories force_on_exit force_category_on_exit catalog_sync rule_sync catalog_state app target category category_target app_count source specific_count=0
    load_config
    write_default_config
    total="$(read_split_apps | awk 'END {print NR + 0}')"
    categories="$(read_split_apps | awk -F '\t' '{seen[$3]=1} END {n=0; for (c in seen) n++; print n+0}')"
    app_policies="$(read_split_policies | awk 'END {print NR + 0}')"
    category_policies="$(read_split_category_policies | awk 'END {print NR + 0}')"
    force_apps="$(read_force_split_policies | awk 'END {print NR + 0}')"
    force_categories="$(read_force_split_category_policies | awk 'END {print NR + 0}')"
    force_on_exit="$(read_force_on_exit_policies | awk 'END {print NR + 0}')"
    force_category_on_exit="$(read_force_category_on_exit_policies | awk 'END {print NR + 0}')"
    if [ -f "$SPLIT_CATALOG_FILE" ]; then
        catalog_sync="$(date -d "@$(cat "$SPLIT_CATALOG_FILE" 2>/dev/null || printf 0)" '+%F %T' 2>/dev/null || cat "$SPLIT_CATALOG_FILE")"
    else
        catalog_sync="从未"
    fi
    if [ -f "$SPLIT_LAST_SYNC_FILE" ]; then
        rule_sync="$(date -d "@$(cat "$SPLIT_LAST_SYNC_FILE" 2>/dev/null || printf 0)" '+%F %T' 2>/dev/null || cat "$SPLIT_LAST_SYNC_FILE")"
    else
        rule_sync="从未"
    fi
    if split_catalog_ready; then
        catalog_state="已获取"
    else
        catalog_state="未获取"
    fi
    cat <<EOF
============================================================
                    分流管理
============================================================
 应用目录 : $catalog_state
 应用总数 : $total
 分类数量 : $categories
 已设策略 : 分类 $category_policies / 应用 $app_policies
 强制分流 : 分类 $force_categories / 应用 $force_apps
 按出口强制: 分类 $force_category_on_exit / 应用 $force_on_exit
 目录同步 : $catalog_sync
 规则更新 : $rule_sync
------------------------------------------------------------
 按类型应用数量:
EOF
    if ! split_catalog_ready; then
        printf '  尚未同步应用目录，请先选择 1 同步应用目录。\n'
        printf '%s\n' '============================================================'
        return 0
    fi
    read_split_apps | awk -F '\t' '{count[$3]++} END {for (c in count) print c "\t" count[c]}' | sort | while IFS=$'\t' read -r category app_count; do
        [ -n "$category" ] || continue
        category_target="$(split_category_policy_target "$category")"
        if [ -n "$category_target" ]; then
            printf '  - %s: %s 个，分类分流 -> %s\n' "$category" "$app_count" "$(split_target_list_label "$(split_category_policy_targets "$category")")"
        else
            printf '  - %s: %s 个\n' "$category" "$app_count"
        fi
    done
    printf '%s\n' '------------------------------------------------------------'
    printf ' 分类分流策略:\n'
    if [ -n "$(read_split_category_policies)" ]; then
        while IFS=$'\t' read -r category target; do
            app_count="$(read_split_apps | awk -F '\t' -v c="$category" '$3 == c {n++} END {print n+0}')"
            printf '  - %s -> %s（%s 个应用）\n' "$category" "$(split_target_list_label "$target")" "$app_count"
        done < <(read_split_category_policies)
    else
        printf '  暂无分类分流。\n'
    fi
    printf ' 单应用分流/覆盖:\n'
    while IFS=$'\t' read -r app target; do
        if split_app_policy_is_category_default "$app" "$target"; then
            continue
        fi
        printf '  - %s -> %s\n' "$(split_app_display "$app")" "$(split_target_list_label "$target")"
        specific_count=$((specific_count + 1))
    done < <(read_split_policies)
    [ "$specific_count" -gt 0 ] || printf '  暂无单应用覆盖。\n'
    printf ' 强制分流:\n'
    if [ -n "$(read_force_split_category_policies)" ] || [ -n "$(read_force_split_policies)" ]; then
        while IFS= read -r category; do
            [ -n "$category" ] || continue
            printf '  - 分类 %s\n' "$category"
        done < <(read_force_split_category_policies)
        while IFS= read -r app; do
            [ -n "$app" ] || continue
            printf '  - 应用 %s -> %s\n' "$(split_app_display "$app")" "$(display_exit_name "$(split_policy_target "$app")")"
        done < <(read_force_split_policies)
    else
        printf '  暂无强制分流。\n'
    fi
    printf ' 按当前出口强制:\n'
    if [ -n "$(read_force_on_exit_policies)$(read_force_category_on_exit_policies)" ]; then
        while IFS=$'\t' read -r category source target; do
            printf '  - 分类 %s：%s -> %s\n' "$category" "$(display_exit_name "$source")" "$(split_target_list_label "$target")"
        done < <(read_force_category_on_exit_policies)
        while IFS=$'\t' read -r app source target; do
            printf '  - 应用 %s：%s -> %s\n' "$(split_app_display "$app")" "$(display_exit_name "$source")" "$(split_target_list_label "$target")"
        done < <(read_force_on_exit_policies)
    else
        printf '  暂无按当前出口强制分流。\n'
    fi
    printf '%s\n' '============================================================'
}

interactive_split_menu() {
    local choice
    need_root
    load_config
    write_default_config
    while true; do
        if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ] && command -v clear >/dev/null 2>&1; then
            clear
        fi
        print_split_header
        cat <<EOF
  1. 同步单文件应用目录与规则缓存
  2. 更新已启用分流规则
  3. 查看应用分流状态
  4. 设置单个应用候选出口
  5. 按分类批量设置候选出口
  6. 添加自定义分流规则
  7. 取消单个应用分流
  8. 取消分类分流
  9. 设置强制单应用分流
  10. 设置强制分类分流
  11. 取消强制单应用分流
  12. 取消强制分类分流
  13. 一键清空全部分流规则
  14. 设置按当前出口强制单应用分流
  15. 设置按当前出口强制分类分流
  16. 取消按当前出口强制单应用分流
  17. 取消按当前出口强制分类分流
  0. 返回主菜单
============================================================
EOF
        read -r -p "请输入序号: " choice
        case "$choice" in
            1) split_fetch_all_rules catalog; pause_screen ;;
            2) split_sync --force; pause_screen ;;
            3) split_list; pause_screen ;;
            4) interactive_split_set_app; pause_screen ;;
            5) interactive_split_set_category; pause_screen ;;
            6) interactive_split_add_custom; pause_screen ;;
            7) interactive_split_clear_app; pause_screen ;;
            8) interactive_split_clear_category; pause_screen ;;
            9) interactive_split_force_app; pause_screen ;;
            10) interactive_split_force_category; pause_screen ;;
            11) interactive_split_force_clear_app; pause_screen ;;
            12) interactive_split_force_clear_category; pause_screen ;;
            13)
                if confirm_yes "确认清空全部分流规则吗？这会删除应用/分类/强制分流、容器覆盖、规则缓存和自定义分流规则，但保留应用目录"; then
                    split_clear_all_rules
                else
                    info "已取消清空全部分流规则。"
                fi
                pause_screen
                ;;
            14) interactive_split_force_on_exit_app; pause_screen ;;
            15) interactive_split_force_on_exit_category; pause_screen ;;
            16) interactive_split_force_on_exit_clear_app; pause_screen ;;
            17) interactive_split_force_on_exit_clear_category; pause_screen ;;
            0) return 0 ;;
            *) warn "无效选项，请重新输入。"; sleep 1 ;;
        esac
    done
}

interactive_remove_exit() {
    local choice_file name
    need_root
    load_config
    print_exit_summary
    choice_file="/tmp/incus-egress-remove.$$"
    if ! choose_host_exit "$choice_file"; then
        rm -f "$choice_file"
        pause_screen
        return 0
    fi
    name="$(cat "$choice_file")"
    rm -f "$choice_file"
    if ! confirm_yes "确认删除出口 '$name' 吗？正在使用该出口的容器会切回入口机"; then
        info "已取消删除出口。"
        pause_screen
        return 0
    fi
    remove_exit "$name"
    pause_screen
}

sync_and_enable_takeover() {
    need_root
    local allowed
    if [ "$#" -gt 0 ]; then
        allowed="$(resolve_allowed_exit_list "$@")" || die "存在未知出口，或选择了入口机作为授权出口: $*"
    else
        allowed="*"
    fi
    install_host
    set_config_value AUTO_INSTALL_CLIENT true
    set_config_value AUTO_ALLOW_EXITS "$allowed"
    set_config_value AUTO_DEFAULT_EXIT '-'
    load_config
    sync_now
    set_all_containers_access_mode "$allowed" false "出口切换授权"
    enable_autosync
    systemctl enable --now "$APP_NAME" >/dev/null 2>&1 || true
    if [ "$allowed" = "*" ]; then
        info "已同步容器、注入 out/token，并启动全量接管和轮询检查；容器可自助切换全部出口。"
    else
        info "已同步容器、注入 out/token，并启动可选出口接管和轮询检查；容器仅可自助切换: $(split_target_list_label "$allowed")。"
    fi
}

interactive_sync_and_enable() {
    local allowed_file allowed
    allowed_file="/tmp/incus-egress-allowed-exits.$$"
    choose_takeover_allowed_exits "$allowed_file" || { rm -f "$allowed_file"; pause_screen; return 0; }
    allowed="$(cat "$allowed_file")"
    rm -f "$allowed_file"
    sync_and_enable_takeover "$allowed"
    pause_screen
}

sync_split_only_takeover() {
    need_root
    install_host
    set_config_value AUTO_INSTALL_CLIENT true
    set_config_value AUTO_ALLOW_EXITS '-'
    set_config_value AUTO_DEFAULT_EXIT '-'
    load_config
    sync_now
    set_all_containers_access_mode '-' true "仅分流授权"
    enable_autosync
    systemctl enable --now "$APP_NAME" >/dev/null 2>&1 || true
    info "已同步容器、注入 out/token，并启动仅分流接管和轮询检查；容器默认走入口机，不能自助切换真实出口。"
}

interactive_sync_split_only() {
    sync_split_only_takeover
    pause_screen
}

interactive_sync_now() {
    printf '\n将扫描 Incus 当前容器，自动新增/更新/回收授权，并尝试注入 out/token。\n'
    sync_now
    pause_screen
}

choose_bulk_switch_exit() {
    local out_file="$1" tmp pick target i item display
    [ -n "$out_file" ] || return 1
    tmp="$(mktemp)"
    printf '%s\t%s\n' '-' '入口机' > "$tmp"
    read_exit_rows | awk -F '\t' '{print $1 "\t" $6}' >> "$tmp"

    printf '\n请选择全部运行中容器的目标出口:\n'
    printf '  0. 返回主菜单\n'
    i=1
    while IFS=$'\t' read -r item display; do
        printf '  %s. %s\n' "$i" "${display:-$item}"
        i=$((i + 1))
    done < "$tmp"
    read -r -p "请输入序号或出口名称: " pick
    case "$pick" in
        ""|0) target="" ;;
        *[!0-9]*) target="$(resolve_exit_target "$pick" 2>/dev/null || true)" ;;
        *) target="$(sed -n "${pick}p" "$tmp" | awk -F '\t' '{print $1}')" ;;
    esac
    rm -f "$tmp"
    if [ -z "$target" ]; then
        [ -z "$pick" ] || [ "$pick" = "0" ] || warn "没有找到对应出口: $pick"
        return 1
    fi
    printf '%s\n' "$target" > "$out_file"
}

interactive_switch_all_running_containers() {
    local choice_file target label
    choice_file="/tmp/incus-egress-switch-all.$$"
    if ! choose_bulk_switch_exit "$choice_file"; then
        rm -f "$choice_file"
        return 0
    fi
    target="$(cat "$choice_file")"
    rm -f "$choice_file"
    label="$(display_exit_name "$target")"
    printf '\n将先同步 Incus 状态，再把所有正常运行且已接管的容器切换到：%s\n' "$label"
    printf '停止中的容器、虚拟机和未取得有效 IP 的容器不会修改。\n'
    printf '如果目标出口不在容器原授权中，会自动补充该出口授权。\n'
    printf '宿主机强制分流仍保持原目标，不会被本次批量切换覆盖。\n\n'
    if confirm_yes "确认执行全部运行中容器一键切换吗"; then
        switch_all_running_containers "$target"
    else
        info "已取消。"
    fi
    pause_screen
}

interactive_enable_autosync() {
    printf '\n自动同步服务会持续监听 Incus 容器变化，并定时全量扫描兜底。\n'
    enable_autosync
    pause_screen
}

interactive_disable_autosync() {
    disable_autosync
    pause_screen
}

interactive_container_out_autofill() {
    local choice state
    load_config
    if [ "${AUTO_INSTALL_CLIENT:-true}" = "true" ]; then
        state="已启用"
    else
        state="已关闭"
    fi
    printf '\n容器 out/token 自动补齐当前状态: %s\n' "$state"
    printf '开启后，后台轮询会把缺失的 /usr/local/bin/out 和 /etc/incus-egress-token 自动补回。\n'
    printf '关闭后，宿主机分流仍然生效，但容器不能再用 out use 自助切换出口。\n\n'
    printf '  1. 启用自动补齐\n'
    printf '  2. 关闭自动补齐\n'
    printf '  0. 取消\n'
    read -r -p "请输入序号: " choice
    case "$choice" in
        1) enable_container_out_access ;;
        2) disable_container_out_access ;;
        0|"") info "已取消。" ;;
        *) warn "无效选项。" ;;
    esac
    pause_screen
}

interactive_clear_container_out() {
    printf '\n这个操作会一键清除所有实例的出口接管信息：\n'
    printf '  - 删除容器内 out 命令和 token\n'
    printf '  - 清空宿主机容器授权、当前出口和容器级分流覆盖\n'
    printf '  - 关闭自动同步和 out/token 自动补齐，防止立即重新生成\n'
    printf '已添加的出口节点和宿主机全局分流规则会保留。\n\n'
    if ! confirm_yes "确认清空全部实例出口信息吗"; then
        info "已取消。"
        pause_screen
        return 0
    fi
    clear_container_out_access
    info "如需重新接管实例，请返回主菜单选择 7；可直接选择 1 一次授权全部已添加出口。"
    pause_screen
}

managed_exit_services() {
    command -v systemctl >/dev/null 2>&1 || return 0
    (
        systemctl list-units --all "${EXIT_SERVICE_PREFIX}-*.service" --no-legend --no-pager 2>/dev/null || true
        systemctl list-unit-files "${EXIT_SERVICE_PREFIX}-*.service" --no-legend --no-pager 2>/dev/null || true
    ) | awk '{print $1}' | grep -E "^${EXIT_SERVICE_PREFIX}-.*\\.service$" | sort -u || true
}

stop_and_remove_exit_services() {
    local svc
    if command -v systemctl >/dev/null 2>&1; then
        for svc in $(managed_exit_services); do
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            rm -f "$SYSTEMD_DIR/$svc"
        done
        systemctl daemon-reload 2>/dev/null || true
    fi
}

flush_exit_route_tables() {
    local _name _mark table _route4 _route6
    while IFS=$'\t' read -r _name _mark table _route4 _route6 _display; do
        ip route flush table "$table" 2>/dev/null || true
        ip -6 route flush table "$table" 2>/dev/null || true
    done < <(read_exit_rows)
}

safe_instance_key() {
    local project="$1" name="$2" raw
    if [ "$project" = "default" ]; then
        raw="$name"
    else
        raw="$project.$name"
    fi
    printf '%s\n' "$raw" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

include_cleanup_instance() {
    local project="$1" name="$2" key
    key="$(safe_instance_key "$project" "$name")"
    if ! [[ "$key" =~ $AUTO_INCLUDE_REGEX || "$name" =~ $AUTO_INCLUDE_REGEX ]]; then
        return 1
    fi
    if [ -n "${AUTO_EXCLUDE_REGEX:-}" ] && [[ "$key" =~ $AUTO_EXCLUDE_REGEX || "$name" =~ $AUTO_EXCLUDE_REGEX ]]; then
        return 1
    fi
    return 0
}

list_project_container_names() {
    local project="$1"
    incus --project "$project" list --format json 2>/dev/null | python3 -c '
import json
import sys

try:
    items = json.load(sys.stdin)
except Exception:
    items = []
for item in items:
    name = item.get("name") or ""
    inst_type = item.get("type") or item.get("instance_type") or "container"
    if name and inst_type == "container":
        print(name)
' 2>/dev/null || true
}

cleanup_container_clients() {
    need_root
    load_config
    local project name path count=0
    if ! command -v incus >/dev/null 2>&1; then
        warn "未找到 incus 命令，跳过容器 out/token 清理。"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        warn "未找到 python3，跳过容器 out/token 清理。"
        return 0
    fi
    for project in $AUTO_PROJECTS; do
        [ -n "$project" ] || continue
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            include_cleanup_instance "$project" "$name" || continue
            for path in "$AUTO_CLIENT_PATH" "$AUTO_TOKEN_PATH"; do
                [ -n "$path" ] || continue
                incus --project "$project" file delete "$name$path" >/dev/null 2>&1 || true
            done
            count=$((count + 1))
        done < <(list_project_container_names "$project")
    done
    rm -f "$CONFIG_DIR/autosync-state.json" 2>/dev/null || true
    info "已尝试清理 $count 台容器内的 out 命令和 token。"
}

disable_container_out_access() {
    need_root
    load_config
    write_default_config
    set_config_value AUTO_INSTALL_CLIENT false
    load_config
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$APP_NAME-autosync" 2>/dev/null || true
    fi
    info "已关闭容器 out/token 自动补齐。后台仍会同步容器记录和宿主机应用分流。"
}

clear_container_out_access() {
    need_root
    load_config
    write_default_config
    local tmp
    info "正在停止自动同步，并清理所有实例出口接管信息。"
    set_config_value AUTO_INSTALL_CLIENT false
    load_config
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$APP_NAME-autosync" 2>/dev/null || true
    fi
    cleanup_container_clients
    state_lock_acquire
    mark_nft_pending
    tmp="$(mktemp)"
    cat > "$tmp" <<'EOF'
# 容器授权配置，每行一台：
# 名称    容器IP       token               允许出口      当前出口
# 请通过主菜单 7 重新同步运行中容器并选择授权出口。
EOF
    install -m 0600 "$tmp" "$CONTAINERS_FILE"
    cat > "$tmp" <<'EOF'
# 容器级应用分流覆盖，每行一条：
# 容器名  app_id  目标出口
EOF
    install -m 0600 "$tmp" "$SPLIT_CONTAINER_POLICIES_FILE"
    rm -f "$tmp" "$CONFIG_DIR/autosync-state.json"
    do_apply_nftables
    state_lock_release
    info "已清空全部实例出口信息；自动同步和 out/token 自动补齐保持关闭。"
    info "下一步：执行主菜单 7 重新同步；选择 1 可授权全部已添加出口。"
}

enable_container_out_access() {
    need_root
    load_config
    write_default_config
    set_config_value AUTO_INSTALL_CLIENT true
    load_config
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$APP_NAME-autosync" 2>/dev/null || true
    fi
    sync_now
    info "已开启 AUTO_INSTALL_CLIENT，并已尝试重新注入容器 out/token。"
}

restore_initial_state() {
    need_root
    load_config
    write_default_config
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$APP_NAME-autosync" "$APP_NAME" 2>/dev/null || true
        systemctl disable "$APP_NAME-autosync" 2>/dev/null || true
    fi
    cleanup_container_clients
    stop_and_remove_exit_services
    remove_split_dnsmasq_integration || true
    reset_managed_ip_rules
    flush_exit_route_tables
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE" 2>/dev/null || true
        nft delete table inet "$(apply_guard_table)" 2>/dev/null || true
    fi
    rm -rf "$EXIT_DIR" "$LEGACY_EXIT_DIR"
    rm -f "$LEGACY_SINGBOX_BIN" 2>/dev/null || true
    rm -f "$EXITS_FILE" "$LIMITS_FILE" "$CONTAINERS_FILE" "$CONFIG_DIR/autosync-state.json" \
        "$CONFIG_DIR/.autosync.lock" "$CONFIG_DIR/.lock" "$CONFIG_DIR/.state.lock" "$CONFIG_DIR/.reconcile.lock"
    rm -rf "$SPLIT_DIR"
    rm -rf "$RUN_DIR"
    write_default_config
    set_config_value AUTO_INSTALL_CLIENT false
    load_config
    if command -v systemctl >/dev/null 2>&1 && [ -f "$SERVICE_FILE" ]; then
        systemctl enable --now "$APP_NAME" >/dev/null 2>&1 || true
    fi
    info "已还原到初始状态：出口、容器授权、分流、策略路由、nft 规则和容器 out/token 已清空；脚本和基础配置已保留。"
}

interactive_restore() {
    need_root
    if ! confirm_yes "确认还原初始状态吗？这会删除出口、分流、容器接管记录和容器内 out/token，但不会卸载脚本"; then
        info "已取消还原。"
        pause_screen
        return 0
    fi
    restore_initial_state
    pause_screen
}

interactive_uninstall() {
    local purge_arg=""
    need_root
    if ! confirm_yes "确认彻底卸载 cloudshlii 出口切换器吗？这会删除服务、规则、配置、出口实例、容器内 out/token 和脚本文件"; then
        info "已取消卸载。"
        pause_screen
        return 0
    fi
    purge_arg="--purge"
    uninstall_host "$purge_arg"
    exit 0
}

count_rows() {
    local file="$1"
    [ -f "$file" ] || { printf '0\n'; return 0; }
    awk 'NF && $1 !~ /^#/ {n++} END {print n+0}' "$file"
}

service_state() {
    local name="$1"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$name" </dev/null; then
        printf '运行中'
    else
        printf '未运行'
    fi
}

takeover_mode_label() {
    load_config
    if [ "${AUTO_ALLOW_EXITS:-*}" = "*" ]; then
        printf '全量接管/可切换出口'
    elif [ "${AUTO_ALLOW_EXITS:-*}" = "-" ] && [ "${AUTO_DEFAULT_EXIT:--}" = "-" ]; then
        printf '仅分流/禁止切换出口'
    else
        printf '可选出口(%s)' "$(split_target_list_label "${AUTO_ALLOW_EXITS:-*}")"
    fi
}

allowed_exits_label() {
    case "${1:-*}" in
        "*") printf '全部已添加出口' ;;
        "-") printf '仅入口机' ;;
        *) split_target_list_label "$1" ;;
    esac
}

print_main_header() {
    local exits containers api_state sync_state out_auto_state takeover_mode
    load_config
    exits=$(count_rows "$EXITS_FILE")
    containers=$(count_rows "$CONTAINERS_FILE")
    api_state=$(service_state "$APP_NAME")
    sync_state=$(service_state "$APP_NAME-autosync")
    if [ "${AUTO_INSTALL_CLIENT:-true}" = "true" ]; then
        out_auto_state="已启用/${AUTO_CLIENT_VERIFY_INTERVAL}s巡检"
    else
        out_auto_state="已关闭"
    fi
    takeover_mode="$(takeover_mode_label)"
    ui_line
    printf '%s%s' "$UI_CYAN" "$UI_BOLD"
    cat <<'EOF'
   ____ _                 _     _     _ _ _
  / ___| | ___  _   _  __| |___| |__ | (_) |
 | |   | |/ _ \| | | |/ _` / __| '_ \| | | |
 | |___| | (_) | |_| | (_| \__ \ | | | | | |
  \____|_|\___/ \__,_|\__,_|___/_| |_|_|_|_|
EOF
    printf '%s' "$UI_RESET"
    ui_line
    printf '  %s+---------------- %scloudshlii出口管理工具%s%s ----------------+%s\n' "$UI_CYAN" "$UI_BOLD" "$UI_RESET" "$UI_CYAN" "$UI_RESET"
    printf '\n'
    printf '  %sAPI 地址%s     : %s%-30s%s | %sAPI 服务%s : %s\n' "$UI_CYAN" "$UI_RESET" "$UI_YELLOW" "$API_PUBLIC_URL" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$api_state"
    printf '  %s出口数量%s     : %s%-30s%s | %s同步服务%s : %s\n' "$UI_CYAN" "$UI_RESET" "$UI_GREEN" "$exits" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$sync_state"
    printf '  %s接管容器%s     : %s%-30s%s | %s接管模式%s : %s\n' "$UI_CYAN" "$UI_RESET" "$UI_GREEN" "$containers" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$takeover_mode"
    printf '  %sout 自动补齐%s : %s%-30s%s | %s同步并发%s : 查询 %s / 注入 %s\n' "$UI_CYAN" "$UI_RESET" "$UI_GREEN" "$out_auto_state" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$AUTO_SYNC_WORKERS" "$AUTO_INJECT_WORKERS"
    ui_line
}

interactive_menu() {
    local choice
    while true; do
        if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ] && command -v clear >/dev/null 2>&1; then
            clear
        fi
        print_main_header
        printf '  %s【基础管理】%s\n' "$UI_CYAN" "$UI_RESET"
        printf '    %s[1]%s 安装/修复宿主机组件        %s[2]%s 查看详细状态\n' "$UI_GREEN" "$UI_RESET" "$UI_GREEN" "$UI_RESET"
        printf '\n'
        printf '  %s【出口管理】%s\n' "$UI_CYAN" "$UI_RESET"
        printf '    %s[3]%s 添加出口                  %s[4]%s 查看出口\n' "$UI_GREEN" "$UI_RESET" "$UI_GREEN" "$UI_RESET"
        printf '    %s[5]%s 删除出口                  %s[6]%s 出口共享限速\n' "$UI_GREEN" "$UI_RESET" "$UI_GREEN" "$UI_RESET"
        printf '    %s[17]%s WG 出口服务器部署与 Peer 管理\n' "$UI_GREEN" "$UI_RESET"
        printf '\n'
        printf '  %s【容器同步】%s\n' "$UI_CYAN" "$UI_RESET"
        printf '    %s[7]%s 同步运行中容器，并选择可切换出口\n' "$UI_GREEN" "$UI_RESET"
        printf '    %s[8]%s 同步运行中容器，但仅启用宿主机分流\n' "$UI_GREEN" "$UI_RESET"
        printf '    %s[9]%s 容器 out/token 自动补齐开关\n' "$UI_GREEN" "$UI_RESET"
        printf '    %s[10]%s 一键清空全部实例出口信息\n' "$UI_GREEN" "$UI_RESET"
        printf '    %s[11]%s 全部运行中容器一键切换出口\n' "$UI_GREEN" "$UI_RESET"
        printf '\n'
        printf '  %s【分流管理】%s\n' "$UI_CYAN" "$UI_RESET"
        printf '    %s[12]%s 分流管理\n' "$UI_GREEN" "$UI_RESET"
        printf '\n'
        printf '  %s【维护操作】%s\n' "$UI_CYAN" "$UI_RESET"
        printf '    %s[13]%s 从 GitHub 安全更新          %s[16]%s 使用当前脚本安全更新\n' "$UI_GREEN" "$UI_RESET" "$UI_GREEN" "$UI_RESET"
        printf '    %s[14]%s 还原初始状态并清空接管     %s[15]%s 彻底卸载\n' "$UI_GREEN" "$UI_RESET" "$UI_GREEN" "$UI_RESET"
        printf '\n'
        printf '  ------------------------------------------------------------\n'
        printf '    %s[0]%s 退出\n' "$UI_GREEN" "$UI_RESET"
        ui_line
        read -r -p "请输入选项 [0-17]: " choice
        case "$choice" in
            1) interactive_install_host ;;
            2) interactive_status ;;
            3) interactive_add_proxy_exit ;;
            4) interactive_list_exits ;;
            5) interactive_remove_exit ;;
            6) interactive_limit_menu ;;
            7) interactive_sync_and_enable ;;
            8) interactive_sync_split_only ;;
            9) interactive_container_out_autofill ;;
            10) interactive_clear_container_out ;;
            11) interactive_switch_all_running_containers ;;
            12) interactive_split_menu ;;
            13) update_from_github; exec "$INSTALL_BIN" menu ;;
            14) interactive_restore ;;
            15) interactive_uninstall ;;
            16) upgrade_config_and_components; exec "$INSTALL_BIN" menu ;;
            17) interactive_wg_server_menu ;;
            0) info "退出。"; exit 0 ;;
            *) warn "无效选项，请重新输入。"; sleep 1 ;;
        esac
    done
}

show_status() {
    load_config
    printf '配置文件: %s\n' "$CONFIG_FILE"
    printf 'API 监听: %s:%s  容器访问地址: %s\n' "$API_BIND" "$API_PORT" "$API_PUBLIC_URL"
    printf '容器网桥: %s\n' "$BRIDGE_IFACES"
    printf '自动同步: %s  间隔: %ss  Project: %s\n' "$AUTO_SYNC" "$AUTO_INTERVAL" "$AUTO_PROJECTS"
    printf '自动授权出口: %s  默认出口: %s  自动注入: %s  客户端巡检: %ss\n' "$(allowed_exits_label "$AUTO_ALLOW_EXITS")" "$(display_exit_name "${AUTO_DEFAULT_EXIT:--}")" "$AUTO_INSTALL_CLIENT" "$AUTO_CLIENT_VERIFY_INTERVAL"
    printf '运行中容器: %s  查询并发: %s  注入并发: %s  事件去抖: %ss\n' "$AUTO_RUNNING_ONLY" "$AUTO_SYNC_WORKERS" "$AUTO_INJECT_WORKERS" "$AUTO_EVENT_DEBOUNCE"
    printf 'IP 完整复核: %ss  删除保护: %s 轮  最小同步间隔: %ss  命令超时: %ss\n' "$AUTO_STATE_REFRESH_INTERVAL" "$AUTO_DELETE_GRACE_SCANS" "$AUTO_RECONCILE_MIN_INTERVAL" "$AUTO_COMMAND_TIMEOUT"
    if [ -e "$PENDING_NFT_FILE" ]; then
        printf '数据面状态: 待应用（服务重启或下一轮自动同步会重试）\n'
    else
        printf '数据面状态: 已提交\n'
    fi
    if command -v sysctl >/dev/null 2>&1; then
        printf '内核转发: IPv4=%s  IPv6=%s  src_valid_mark=%s  rp_filter(all)=%s\n' \
            "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf '?')" \
            "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || printf '?')" \
            "$(sysctl -n net.ipv4.conf.all.src_valid_mark 2>/dev/null || printf '?')" \
            "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || printf '?')"
    fi
    printf '\n出口列表:\n'
    read_exit_rows | awk -F '\t' '{print "  "$6"\tid="$1"\tmark="$2"\ttable="$3"\troute4="$4"\troute6="$5}' || true
    printf '\n容器列表:\n'
    read_container_rows | awk -F '\t' '{cur=$5; if (cur=="-") cur="入口机"; print "  "$1"\t"$2"\tallowed="$4"\tcurrent="cur}' || true
    printf '\n应用分流策略:\n'
    if [ "${ENABLE_SPLIT_RULES:-true}" = "true" ]; then
        if [ -n "$(read_split_policies)" ]; then
            while IFS=$'\t' read -r app target; do
                printf '  %s -> %s\n' "$(split_app_display "$app")" "$(split_target_list_label "$target")"
            done < <(read_split_policies)
        else
            printf '  暂无，访问按容器当前出口处理。\n'
        fi
    else
        printf '  已禁用。\n'
    fi
    printf '\n本脚本管理的策略路由:\n'
    if command -v ip >/dev/null 2>&1; then
        local _name mark table _route4 _route6 _display
        while IFS=$'\t' read -r _name mark table _route4 _route6 _display; do
            ip rule show | grep -F "fwmark $mark lookup $table" || true
            ip -6 rule show 2>/dev/null | grep -F "fwmark $mark lookup $table" || true
        done < <(read_exit_rows)
    fi
    printf '\n本脚本管理的 nftables 表:\n'
    if command -v nft >/dev/null 2>&1; then
        nft list table inet "${NFT_TABLE:-incus_egress_switch}" 2>/dev/null || true
    fi
    printf '\n服务状态:\n'
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active "$APP_NAME" 2>/dev/null | sed "s/^/  $APP_NAME: /" || true
        systemctl is-active "$APP_NAME-autosync" 2>/dev/null | sed "s/^/  $APP_NAME-autosync: /" || true
    fi
}

uninstall_host() {
    need_root
    load_config
    local svc self_path
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$APP_NAME-autosync" "$APP_NAME" 2>/dev/null || true
        systemctl disable "$APP_NAME-autosync" "$APP_NAME" 2>/dev/null || true
    fi
    cleanup_container_clients
    stop_and_remove_exit_services
    remove_split_dnsmasq_integration || true
    reset_managed_ip_rules
    flush_exit_route_tables
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE" 2>/dev/null || true
        nft delete table inet "$(apply_guard_table)" 2>/dev/null || true
    fi
    restore_runtime_sysctls
    rm -f "$SERVICE_FILE" "$AUTOSYNC_SERVICE"
    rm -f "$SYSTEMD_DIR/multi-user.target.wants/$APP_NAME.service" \
          "$SYSTEMD_DIR/multi-user.target.wants/$APP_NAME-autosync.service" \
          "$SYSTEMD_DIR"/multi-user.target.wants/${EXIT_SERVICE_PREFIX}-*.service \
          "$SYSTEMD_DIR"/${EXIT_SERVICE_PREFIX}-*.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$APP_NAME" "$APP_NAME-autosync" "${EXIT_SERVICE_PREFIX}-*" 2>/dev/null || true
    rm -rf "$LIB_DIR" "$RUN_DIR" "/run/$APP_NAME"
    rm -f "$SYSCTL_FILE"
    rm -rf "$CONFIG_DIR"
    if [ "$(basename "$UPDATE_BACKUP_ROOT")" = "$APP_NAME" ] && [ -f "$UPDATE_BACKUP_ROOT/.managed-by-$APP_NAME" ]; then
        rm -rf "$UPDATE_BACKUP_ROOT"
    elif [ -d "$UPDATE_BACKUP_ROOT" ]; then
        warn "更新备份目录使用了自定义路径，出于安全考虑未自动删除: $UPDATE_BACKUP_ROOT"
    fi
    rm -f /tmp/incus-egress-* /tmp/out-choice.* /tmp/out-split-* 2>/dev/null || true
    rm -f "$INSTALL_BIN" "$SHORTCUT_BIN"
    rm -f /root/incus-egress-switch.sh 2>/dev/null || true
    self_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    case "$(basename "$self_path")" in
        bash|sh|dash|busybox) ;;
        *) [ -f "$self_path" ] && rm -f "$self_path" 2>/dev/null || true ;;
    esac
    info "已彻底卸载 cloudshlii 出口切换器。"
}

usage() {
    cat <<EOF
$APP_NAME - cloudshlii Incus 容器自助出口切换器

直接运行进入简化菜单：
  $0

常用命令:
  $0 install-host
      安装宿主机基础依赖、控制器和 API 服务；不会扫描或接管容器。

  $0 add-ss 'ss://...#name'
      添加一个 Shadowsocks 节点出口；链接导入会使用 # 后面解析出的节点名称。
      手动添加可写: add-ss 自定义名称 地址/DDNS域名 端口 密码 [加密方式]
      添加出口只写入并启动出口信息，不会自动同步容器；需要同步请执行 sync-enable。

  $0 add-sk5 socks5://user:pass@host:port#name
      添加一个 SK5/SOCKS5 节点出口；链接导入会使用 # 后面解析出的节点名称。
      手动添加可写: add-sk5 自定义名称 地址/DDNS域名 端口 [用户名] [密码]
      添加出口只写入并启动出口信息，不会自动同步容器；需要同步请执行 sync-enable。

  $0 add-vless 'vless://UUID@host:port?encryption=none&type=tcp#name'
      添加一个不带 TLS/Reality 的 VLESS+TCP 节点出口。
      手动添加可写: add-vless 自定义名称 地址/DDNS域名 端口 UUID
      添加出口只写入并启动出口信息，不会自动同步容器；需要同步请执行 sync-enable。

  $0 add-wg 出口名 Endpoint 服务端公钥 IPv4隧道地址 [IPv6隧道地址|-] [PSK|-] [MTU]
      添加原生 WireGuard 出口；入口机私钥自动生成且只保存在该出口的专用配置中。
      示例: add-wg JP-WG 203.0.113.10:51820 服务端公钥 10.66.0.2/32 - - 1380
      添加成功后会显示入口机公钥，需把它配置到出口服务器 Peer。

  $0 wg-server-install [UDP端口|random] [服务端IPv4地址] [服务端IPv6地址|-] [MTU] [公网网卡]
      在出口服务器一键安装或重新配置原生 WireGuard、独立 nftables NAT 和转发参数。
      交互菜单可自定义端口；直接回车后可填写随机范围。命令行使用 random 时默认从 20000-65535 选择空闲端口，
      可通过 WG_RANDOM_PORT_MIN / WG_RANDOM_PORT_MAX 限定范围。

  $0 wg-server-check UDP端口
      检测 WireGuard 内核能力、nftables 权限、转发参数、服务管理器、默认路由和端口绑定条件。

  $0 wg-server-add-peer 名称 入口机公钥 IPv4地址 [IPv6地址|-] [PSK|-]
      添加或更新一台入口母机 Peer。

  $0 wg-server-status
      查看服务端公钥、Peer、最新握手和流量。

  $0 wg-server-remove-peer 名称
      删除一个入口母机 Peer。

  $0 wg-server-uninstall
      仅卸载 WG 出口服务器组件，不改动其他 nftables 表、sing-box 或 realm。

  $0 list-exits
      查看所有已添加的出口信息。

  $0 limit-exit 出口名 下载限速 [上传限速]
      设置出口级共享限速；所有使用该出口的容器共享总带宽。只填一个限速时下载/上传相同。
      单位使用 Mbps；1 Mbps = 0.125 MB/s，8 Mbps = 1 MB/s；0 或 - 表示不限速。
      示例：limit-exit USNTT 100Mbps 30Mbps。

  $0 list-limits
      查看当前出口共享限速。

  $0 clear-limit 出口名
      清除单个出口的共享限速。

  $0 remove-exit 出口名
      删除一个出口，并把正在使用该出口的容器切回入口机。

  $0 sync-now
      立即扫描 Incus 容器，自动注入 out/token。

  $0 sync-enable [出口1,出口2...]
      同步容器，开启 out/token 自动补齐，并启动可选出口接管和轮询检查。
      不带参数时兼容旧逻辑，容器可切换所有已添加出口；带出口参数时，容器只会看到和切换被授权的出口。

  $0 sync-split-only
      同步容器，开启 out/token 自动补齐，并启动仅分流接管和轮询检查。
      容器默认仍走入口机；out 命令可查看状态，但不能切换到真实出口。

  $0 enable-autosync
      启动后台自动接管。

  $0 status
      查看状态。

  $0 upgrade-config
      手动上传新脚本后执行安全更新：先验证脚本/组件/配置/nft，再创建 root 专属备份并原子刷新组件。
      更新后会检查 API、nft、自动同步和原先在线出口；失败时自动恢复旧版本与配置。
      默认保留最近 5 份备份到 /var/backups/$APP_NAME；不会改动已有出口、token、限速和分流策略。

  $0 update-online
      从 GitHub 下载最新版，然后复用 upgrade-config 的预检、备份、健康检查和自动回滚流程。
      默认地址: $DEFAULT_UPDATE_SCRIPT_URL

  sbout
      安装后可直接输入 sbout 进入主菜单。

  $0 split-list
      查看应用分流目录、当前策略和本地解析出的 IPv4/IPv6 数量。

  $0 split-fetch
      只下载一次 Scam-Abuse-Risk.list，并按文件中的风险场景和应用拆分本地目录/缓存。
      未执行前不能设置分流策略。

  $0 split-fetch-all
      兼容旧命令，行为与 split-fetch 相同，也只下载一个规则文件。

  $0 split-sync
      单次下载最新规则合集，并重新解析已经设置策略的应用/分类；后台默认 3 天更新一次。

  $0 split-prepare binance
      拉取/解析单个应用规则并重新应用 nft；主要供容器 out split 自动调用。

  $0 split-set YouTube 美国,JP-NTT
      给单个应用设置一个或多个候选出口；第一个候选为宿主机默认出口。
      目标也可以写 入口机 或 -。

  $0 split-set-category 视频 美国,JP-NTT
      按分类批量设置一个或多个候选出口；容器 out split 只能在候选出口中自选。

  $0 split-add-custom 公司后台 自定义 < rules.txt
      添加自定义分流规则。rules.txt 每行一条，可写 example.com、*.example.com、DOMAIN-SUFFIX,example.com、203.0.113.0/24。

  $0 split-force binance 美国
      设置强制单应用分流；无论容器当前出口是什么，该应用都走宿主机指定出口。

  $0 split-force-category '金融、支付与数字资产' 美国
      设置强制分类分流；该分类下应用无论容器当前出口是什么，都走宿主机指定出口。

  $0 split-clear YouTube
      取消单个应用的分流策略，恢复按容器当前出口处理。

  $0 split-clear-category 视频
      取消某个分类的分流策略，并清理该分类下继承分类默认的应用策略。

  $0 split-force-clear binance
      取消单应用强制分流，但保留原来的宿主机应用分流目标。

  $0 split-force-clear-category '金融、支付与数字资产'
      取消分类强制分流，但保留原来的宿主机分类/应用分流目标。

  $0 split-clear-all
      一键清空全部分流规则：应用/分类/强制分流、容器覆盖、规则缓存和自定义分流规则都会删除。
      应用目录保留，可继续按需重新添加分流。

  $0 clear-container-out
      一键清空容器内 out/token、宿主机容器授权、当前出口和容器级分流覆盖。
      自动同步会停止；出口节点与全局分流保留，请通过主菜单 7 重新同步。

  $0 enable-container-out
      重新开启容器 out/token 自动注入，并立即同步一次。

  $0 disable-container-out
      关闭容器 out/token 自动补齐，但不删除容器内已有 out/token。

  $0 switch-all-containers 出口名
      先同步 Incus 状态，再把全部正常运行且已接管的容器批量切换到指定出口。
      可填写出口内部 ID、显示名、入口机或 -；停止容器和虚拟机不会修改。

  $0 restore
      还原初始状态，停止并清空所有出口、分流、容器接管记录和容器内 out/token，但保留脚本与基础配置。

  $0 uninstall
      彻底卸载，包括服务、配置、出口实例、容器内 out/token 和脚本自身。

高级命令:
  $0 add-exit 出口名 fwmark 路由表ID [IPv4路由] [IPv6路由]
  $0 add-container 容器名 容器IP [允许出口] [当前出口] [TOKEN]
      当前出口留空或填 - 表示入口机直出。
  $0 set-container 容器名或IP 出口名
      出口名可填入口机或 -，用于切回入口机直出。
  $0 switch-all-containers 出口名
  $0 disable-autosync
  $0 apply
  $0 cleanup-clients
  $0 clear-container-out
  $0 enable-container-out
  $0 disable-container-out
  $0 client-script
  $0 write-client

示例:
  $0 install-host
  $0 add-ss 'ss://xxx#jp'
  $0 add-ss us-ss 1.2.3.4 8388 password aes-256-gcm
  $0 add-sk5 socks5://127.0.0.1:1080#local-sk5
  $0 add-vless 'vless://UUID@127.0.0.1:55555?encryption=none&type=tcp#local-vless'
  $0 list-exits
  $0 limit-exit jp 100Mbps 30Mbps
  $0 remove-exit jp
  $0 upgrade-config
  $0 split-fetch
  $0 split-set YouTube jp,us
  printf 'example.com\n203.0.113.0/24\n' | $0 split-add-custom 公司后台 自定义
  $0 split-set-category 聊天 入口机
  $0 split-force binance jp
  $0 split-clear-all
  $0 sync-enable jp,us
  $0 sync-split-only
  $0 switch-all-containers jp

容器内命令:
  out list
  out current
  out use 出口名
  out use 入口机
  out test
  out split
EOF
}

# 测试脚本可只加载函数，不执行菜单或任何宿主机变更。
if [ "${EGRESS_LIB_ONLY:-false}" = "true" ]; then
    return 0 2>/dev/null || exit 0
fi

command_name="${1:-menu}"
shift || true

case "$command_name" in
    menu)
        interactive_menu "$@"
        ;;
    install-host)
        install_host "$@"
        ;;
    init-config)
        need_root
        write_default_config
        info "配置文件已初始化: $CONFIG_DIR"
        ;;
    add-exit)
        add_exit "$@"
        ;;
    add-ss)
        add_ss_exit "$@"
        ;;
    add-sk5|add-socks)
        add_sk5_exit "$@"
        ;;
    add-vless|add-vless-tcp)
        add_vless_exit "$@"
        ;;
    add-wg|add-wireguard)
        add_wireguard_exit "$@"
        ;;
    wg-server-install|wireguard-server-install)
        wg_server_install "$@"
        ;;
    wg-server-check|wireguard-server-check|wg-server-preflight)
        wg_server_preflight "$@"
        ;;
    wg-server-add-peer|wireguard-server-add-peer)
        wg_server_add_peer "$@"
        ;;
    wg-server-status|wireguard-server-status)
        wg_server_status "$@"
        ;;
    wg-server-remove-peer|wireguard-server-remove-peer)
        wg_server_remove_peer "$@"
        ;;
    wg-server-uninstall|wireguard-server-uninstall)
        wg_server_uninstall "$@"
        ;;
    list-exits|list-exit|exits)
        list_exits "$@"
        ;;
    limit-exit|set-limit|set-exit-limit)
        set_exit_limit "$@"
        ;;
    list-limits|limit-list|limits)
        list_exit_limits "$@"
        ;;
    clear-limit|clear-exit-limit)
        clear_exit_limit "$@"
        ;;
    clear-all-limits|clear-limits)
        clear_all_exit_limits "$@"
        ;;
    remove-exit|delete-exit|del-exit)
        remove_exit "$@"
        ;;
    add-container)
        add_container "$@"
        ;;
    sync-now)
        sync_now "$@"
        ;;
    sync-enable|enable-takeover)
        sync_and_enable_takeover "$@"
        ;;
    sync-split-only|enable-split-only)
        sync_split_only_takeover "$@"
        ;;
    enable-autosync)
        enable_autosync "$@"
        ;;
    disable-autosync)
        disable_autosync "$@"
        ;;
    cleanup-clients)
        cleanup_container_clients "$@"
        ;;
    clear-container-out|clear-out)
        clear_container_out_access "$@"
        ;;
    disable-container-out)
        disable_container_out_access "$@"
        ;;
    enable-container-out)
        enable_container_out_access "$@"
        ;;
    set-container)
        set_container_exit "$@"
        ;;
    switch-all-containers|switch-running-containers|set-all-containers)
        switch_all_running_containers "$@"
        ;;
    apply)
        do_apply "$@"
        ;;
    apply-nft)
        do_apply_nftables "$@"
        ;;
    apply-exit-route)
        do_apply_exit_route "$@"
        ;;
    status)
        show_status "$@"
        ;;
    upgrade-config|upgrade|update-script)
        upgrade_config_and_components "$@"
        ;;
    update-online|update-github|github-update)
        update_from_github "$@"
        ;;
    split-list)
        split_list "$@"
        ;;
    split-fetch|split-catalog)
        split_fetch_all_rules catalog "$@"
        ;;
    split-fetch-all)
        split_fetch_all_rules full "$@"
        ;;
    split-sync)
        split_sync "$@"
        ;;
    split-prepare)
        split_prepare_one "$@"
        ;;
    split-ensure)
        split_ensure_one "$@"
        ;;
    split-refresh-dns)
        split_refresh_cached_dns "$@"
        ;;
    split-set)
        split_set_policy "$@"
        ;;
    split-set-category)
        split_set_category_policy "$@"
        ;;
    split-add-custom|split-custom-add)
        split_add_custom_rule "$@"
        ;;
    split-force)
        split_force_policy "$@"
        ;;
    split-force-category)
        split_force_category_policy "$@"
        ;;
    split-force-on-exit)
        split_force_on_exit_policy "$@"
        ;;
    split-force-category-on-exit)
        split_force_category_on_exit_policy "$@"
        ;;
    split-force-on-exit-clear)
        split_force_on_exit_clear_policy "$@"
        ;;
    split-force-category-on-exit-clear)
        split_force_category_on_exit_clear_policy "$@"
        ;;
    split-force-clear)
        split_force_clear_policy "$@"
        ;;
    split-force-clear-category)
        split_force_clear_category_policy "$@"
        ;;
    split-clear-category)
        split_clear_category_policy "$@"
        ;;
    split-clear)
        split_clear_policy "$@"
        ;;
    split-clear-all|split-reset|split-clear-rules)
        split_clear_all_rules "$@"
        ;;
    restore)
        restore_initial_state "$@"
        ;;
    client-script)
        client_script "$@"
        ;;
    write-client)
        write_client_file "$@"
        ;;
    uninstall)
        uninstall_host "$@"
        exit 0
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
