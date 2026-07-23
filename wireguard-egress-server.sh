#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cloudshlii-wg-egress"
STATE_DIR="${WG_EGRESS_STATE_DIR:-/etc/cloudshlii-wg-server}"
ENV_FILE="$STATE_DIR/server.env"
PEERS_FILE="$STATE_DIR/peers.tsv"
PRIVATE_KEY_FILE="$STATE_DIR/server.key"
PUBLIC_KEY_FILE="$STATE_DIR/server.pub"
WG_IFACE="${WG_EGRESS_IFACE:-cwg-server}"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
NFT_FILE="$STATE_DIR/server.nft"
NFT_TABLE="csh_wg_server"
SYSCTL_FILE="/etc/sysctl.d/99-cloudshlii-wg-server.conf"
LOCK_FILE="/run/lock/cloudshlii-wg-server.lock"
OPENRC_SERVICE="/etc/init.d/cloudshlii-wg-server"
INSTALL_BIN="/usr/local/sbin/wg-egress"
SHORTCUT_BIN="/usr/local/sbin/wgout"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 运行。"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
valid_name() { [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+$ ]]; }
valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

valid_key() {
    [ "${1:-}" = "-" ] && return 0
    printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$'
}

valid_address() {
    local family="$1" value="${2:-}"
    [ "$value" = "-" ] && return 0
    python3 - "$family" "$value" <<'PY'
import ipaddress, sys
try:
    value = ipaddress.ip_interface(sys.argv[2])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if value.version == int(sys.argv[1]) else 1)
PY
}

prompt_default() {
    local text="$1" default="$2" value
    read -r -p "$text [$default]: " value
    printf '%s\n' "${value:-$default}"
}

prompt_required() {
    local text="$1" value=""
    while [ -z "$value" ]; do read -r -p "$text: " value; done
    printf '%s\n' "$value"
}

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

pause() {
    [ -t 0 ] || return 0
    read -r -p "按回车继续..." _
}

install_self() {
    local source
    source="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    mkdir -p /usr/local/sbin
    if [ "$source" != "$INSTALL_BIN" ]; then
        install -m 0755 "$source" "$INSTALL_BIN"
    fi
    ln -sfn "$INSTALL_BIN" "$SHORTCUT_BIN"
}

install_dependencies() {
    need_root
    local cmd missing=""
    for cmd in wg wg-quick ip nft python3 flock sysctl ss; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        info "缺少组件:$missing，正在安装必要依赖。"
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
            die "缺少组件:$missing，且不支持当前系统的包管理器。"
        fi
    fi
    for cmd in wg wg-quick ip nft python3 flock sysctl ss; do need_cmd "$cmd"; done
    if ! { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; } \
        && ! { command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; }; then
        die "需要 systemd 或 OpenRC。"
    fi
}

detect_wan() {
    ip -4 route show default 2>/dev/null |
        awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

network_of() {
    python3 - "$1" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
}

random_port() {
    local min="${1:-20000}" max="${2:-65535}" span attempts port
    [[ "$min" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] || return 1
    [ "$min" -ge 1024 ] && [ "$max" -le 65535 ] && [ "$min" -le "$max" ] || return 1
    span=$((max-min+1)); attempts=$((span*2)); [ "$attempts" -le 200 ] || attempts=200
    while [ "$attempts" -gt 0 ]; do
        port=$((min + RANDOM % span))
        if ! ss -H -lun "sport = :$port" 2>/dev/null | grep -q .; then
            printf '%s\n' "$port"; return 0
        fi
        attempts=$((attempts-1))
    done
    return 1
}

load_state() {
    [ -s "$ENV_FILE" ] || return 1
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
    WG_ADDRESS4="${WG_ADDRESS4:--}"
    WG_ADDRESS6="${WG_ADDRESS6:--}"
    WG_MTU="${WG_MTU:-1380}"
    WG_WAN_IFACE="${WG_WAN_IFACE:-}"
}

lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec {LOCK_FD}>"$LOCK_FILE"
    flock -x "$LOCK_FD"
}

unlock() {
    flock -u "$LOCK_FD" 2>/dev/null || true
    exec {LOCK_FD}>&-
}

CHECK_PASS=0 CHECK_WARN=0 CHECK_FAIL=0
pass() { CHECK_PASS=$((CHECK_PASS+1)); printf '[PASS] %s\n' "$*"; }
warning() { CHECK_WARN=$((CHECK_WARN+1)); printf '[WARN] %s\n' "$*"; }
fail() { CHECK_FAIL=$((CHECK_FAIL+1)); printf '[FAIL] %s\n' "$*"; }

preflight() {
    local port="${1:-}" wan probe_iface probe_table address bind_result
    CHECK_PASS=0 CHECK_WARN=0 CHECK_FAIL=0
    valid_port "$port" || die "请提供有效的 UDP 端口。"
    printf '\n检查 WG 出口环境（UDP %s）\n\n' "$port"
    [ "${EUID:-$(id -u)}" -eq 0 ] && pass "root 权限正常。" || fail "必须使用 root。"
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        pass "服务管理: systemd。"
    elif command -v rc-service >/dev/null 2>&1; then
        pass "服务管理: OpenRC。"
    else
        fail "没有 systemd/OpenRC。"
    fi
    wan="$(detect_wan)"
    [ -n "$wan" ] && pass "公网网卡: $wan。" || fail "未找到 IPv4 默认出口网卡。"
    address="$(ip -4 -o addr show dev "$wan" scope global 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}')"
    if [ -z "$address" ]; then
        fail "公网网卡没有 IPv4 地址。"
    elif python3 - "$address" <<'PY' >/dev/null 2>&1
import ipaddress, sys
raise SystemExit(0 if ipaddress.ip_address(sys.argv[1]).is_global else 1)
PY
    then
        pass "检测到公网 IPv4: $address。"
    else
        warning "本机是内网地址 $address；请把公网 UDP $port 映射到本机。"
    fi
    local cmd
    for cmd in ip wg wg-quick nft python3 ss flock sysctl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            pass "$cmd 可用。"
        elif command -v apk >/dev/null 2>&1 || command -v apt-get >/dev/null 2>&1 \
            || command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            warning "$cmd 未安装，部署时会自动安装。"
        else
            fail "$cmd 缺失且无法自动安装。"
        fi
    done
    probe_iface="cwgp$((RANDOM%9000+1000))"
    if ip link add "$probe_iface" type wireguard >/tmp/cwg-probe.log 2>&1; then
        ip link del "$probe_iface" 2>/dev/null || true
        pass "WireGuard 内核权限正常。"
    else
        fail "不能创建 WireGuard 接口: $(tr '\n' ' ' </tmp/cwg-probe.log 2>/dev/null)"
    fi
    rm -f /tmp/cwg-probe.log
    if ! command -v nft >/dev/null 2>&1; then
        warning "nftables 尚未安装，部署后再验证。"
    else
        probe_table="csh_wgp_$((RANDOM%9000+1000))"
        if nft add table inet "$probe_table" >/tmp/cwg-nft-probe.log 2>&1; then
            nft delete table inet "$probe_table" 2>/dev/null || true
            pass "nftables 权限正常。"
        else
            fail "nftables 不可用: $(tr '\n' ' ' </tmp/cwg-nft-probe.log 2>/dev/null)"
        fi
        rm -f /tmp/cwg-nft-probe.log
    fi
    [ -w /proc/sys/net/ipv4/ip_forward ] && pass "IPv4 转发可配置。" || fail "IPv4 转发不可配置。"
    if command -v ss >/dev/null 2>&1 && ss -H -lun "sport = :$port" 2>/dev/null | grep -q .; then
        if load_state 2>/dev/null && [ "$WG_LISTEN_PORT" = "$port" ] && ip link show "$WG_IFACE" >/dev/null 2>&1; then
            pass "UDP $port 正由本脚本使用，可重新配置。"
        else
            fail "UDP $port 已被其他程序占用。"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        bind_result="$(python3 - "$port" <<'PY' 2>&1
import socket, sys
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try: s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError as exc: print(exc); raise SystemExit(1)
finally: s.close()
PY
)" && pass "UDP $port 空闲。" || fail "UDP $port 无法绑定: $bind_result"
    fi
    printf '\n结果：PASS=%s  WARN=%s  FAIL=%s\n' "$CHECK_PASS" "$CHECK_WARN" "$CHECK_FAIL"
    [ "$CHECK_FAIL" -eq 0 ] || return 1
    printf '可以部署。WARN 项请按提示确认。\n'
}

write_sysctl() {
    cat > "$SYSCTL_FILE" <<'EOF'
# Managed by cloudshlii WG egress server.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    chmod 644 "$SYSCTL_FILE"
    sysctl -e -q -p "$SYSCTL_FILE"
}

write_openrc_service() {
    local wg_quick
    wg_quick="$(command -v wg-quick)"
    cat > "$OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run
description="cloudshlii WireGuard egress server"
depend() { need net; after firewall; }
start() { ebegin "Starting WG egress"; $wg_quick up "$WG_CONF"; eend \$?; }
stop() { ebegin "Stopping WG egress"; $wg_quick down "$WG_CONF"; eend \$?; }
EOF
    chmod 755 "$OPENRC_SERVICE"
}

service_start() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl enable "wg-quick@$WG_IFACE" >/dev/null
        systemctl restart "wg-quick@$WG_IFACE"
    else
        write_openrc_service
        rc-update add cloudshlii-wg-server default >/dev/null 2>&1 || true
        if rc-service cloudshlii-wg-server status >/dev/null 2>&1; then
            rc-service cloudshlii-wg-server restart
        else
            rc-service cloudshlii-wg-server start
        fi
    fi
}

service_stop() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "wg-quick@$WG_IFACE" 2>/dev/null || true
    else
        rc-service cloudshlii-wg-server stop 2>/dev/null || true
        rc-update del cloudshlii-wg-server default >/dev/null 2>&1 || true
        rm -f "$OPENRC_SERVICE"
    fi
}

render() {
    load_state || die "尚未部署 WG 出口。"
    local stage conf nft check private addresses="" network4="" network6="" nat4="" nat6=""
    local name public allowed4 allowed6 psk rest psk_line allowed peer_lines=""
    stage="$(mktemp -d)"; conf="$stage/$WG_IFACE.conf"; nft="$(mktemp)"; check="$(mktemp)"
    private="$(cat "$PRIVATE_KEY_FILE")"
    if [ "$WG_ADDRESS4" != "-" ]; then
        addresses="$WG_ADDRESS4"; network4="$(network_of "$WG_ADDRESS4")"
        nat4="    ip saddr $network4 oifname \"$WG_WAN_IFACE\" masquerade"
    fi
    if [ "$WG_ADDRESS6" != "-" ]; then
        [ -z "$addresses" ] || addresses="$addresses, "
        addresses="${addresses}${WG_ADDRESS6}"; network6="$(network_of "$WG_ADDRESS6")"
        nat6="    ip6 saddr $network6 oifname \"$WG_WAN_IFACE\" masquerade"
    fi
    while IFS=$'\t' read -r name public allowed4 allowed6 psk rest; do
        case "${name:-}" in ""|\#*) continue ;; esac
        psk_line=""; [ "${psk:--}" = "-" ] || psk_line="PresharedKey = $psk"
        allowed=""; [ "${allowed4:--}" = "-" ] || allowed="$allowed4"
        if [ "${allowed6:--}" != "-" ]; then [ -z "$allowed" ] || allowed="$allowed, "; allowed="${allowed}${allowed6}"; fi
        peer_lines="$peer_lines
# Peer: $name
[Peer]
PublicKey = $public
$psk_line
AllowedIPs = $allowed
"
    done < "$PEERS_FILE"
    cat > "$conf" <<EOF
[Interface]
PrivateKey = $private
Address = $addresses
ListenPort = $WG_LISTEN_PORT
MTU = $WG_MTU
PostUp = nft delete table inet $NFT_TABLE 2>/dev/null || true; nft -f $NFT_FILE
PostDown = nft delete table inet $NFT_TABLE 2>/dev/null || true
$peer_lines
EOF
    cat > "$nft" <<EOF
table inet $NFT_TABLE {
  chain input {
    type filter hook input priority filter - 5; policy accept;
    udp dport $WG_LISTEN_PORT accept
  }
  chain forward {
    type filter hook forward priority filter - 5; policy accept;
    iifname "$WG_IFACE" accept
    oifname "$WG_IFACE" ct state established,related accept
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
$nat4
$nat6
  }
}
EOF
    wg-quick strip "$conf" >/dev/null || die "WG 配置校验失败。"
    nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && printf 'delete table inet %s\n' "$NFT_TABLE" > "$check"
    cat "$nft" >> "$check"
    nft -c -f "$check" || die "nftables 配置校验失败。"
    install -m 600 "$conf" "$WG_CONF"
    install -m 600 "$nft" "$NFT_FILE"
    rm -rf "$stage"; rm -f "$nft" "$check"
}

restart_server() {
    local old_conf="" old_nft=""
    [ -f "$WG_CONF" ] && { old_conf="$(mktemp)"; cp -a "$WG_CONF" "$old_conf"; }
    [ -f "$NFT_FILE" ] && { old_nft="$(mktemp)"; cp -a "$NFT_FILE" "$old_nft"; }
    render
    if service_start; then rm -f "$old_conf" "$old_nft"; return 0; fi
    warn "启动失败，正在恢复旧配置。"
    [ -z "$old_conf" ] || install -m 600 "$old_conf" "$WG_CONF"
    [ -z "$old_nft" ] || install -m 600 "$old_nft" "$NFT_FILE"
    rm -f "$old_conf" "$old_nft"
    service_start 2>/dev/null || true
    return 1
}

install_server() {
    need_root; install_dependencies; lock
    local port="${1:-}" address4="${2:-10.66.0.1/24}" address6="${3:--}" mtu="${4:-1380}" wan="${5:-}" tmp
    [ "$port" != "random" ] || port="$(random_port "${WG_RANDOM_PORT_MIN:-20000}" "${WG_RANDOM_PORT_MAX:-65535}")"
    valid_port "$port" || { unlock; die "UDP 端口无效。"; }
    valid_address 4 "$address4" || { unlock; die "服务端 IPv4 隧道地址无效。"; }
    valid_address 6 "$address6" || { unlock; die "服务端 IPv6 隧道地址无效。"; }
    [ "$address4" != "-" ] || [ "$address6" != "-" ] || { unlock; die "至少启用一种隧道地址。"; }
    [[ "$mtu" =~ ^[0-9]+$ ]] && [ "$mtu" -ge 1280 ] && [ "$mtu" -le 9000 ] || { unlock; die "MTU 应为 1280-9000。"; }
    wan="${wan:-$(detect_wan)}"; valid_name "$wan" && ip link show "$wan" >/dev/null 2>&1 || { unlock; die "公网网卡无效。"; }
    mkdir -p "$STATE_DIR" /etc/wireguard; chmod 700 "$STATE_DIR" /etc/wireguard
    [ -s "$PRIVATE_KEY_FILE" ] || wg genkey > "$PRIVATE_KEY_FILE"
    chmod 600 "$PRIVATE_KEY_FILE"; wg pubkey < "$PRIVATE_KEY_FILE" > "$PUBLIC_KEY_FILE"; chmod 644 "$PUBLIC_KEY_FILE"
    [ -f "$PEERS_FILE" ] || printf '# 名称\t公钥\tIPv4\tIPv6\tPSK\n' > "$PEERS_FILE"
    chmod 600 "$PEERS_FILE"; tmp="$(mktemp)"
    cat > "$tmp" <<EOF
WG_LISTEN_PORT=$port
WG_ADDRESS4=$address4
WG_ADDRESS6=$address6
WG_MTU=$mtu
WG_WAN_IFACE=$wan
EOF
    install -m 600 "$tmp" "$ENV_FILE"; rm -f "$tmp"; write_sysctl
    restart_server || { unlock; die "部署失败，已恢复旧配置。"; }
    install_self; unlock
    printf '\n部署完成，请记住下面 3 项：\n'
    printf '  Endpoint端口 : %s/UDP\n' "$port"
    printf '  服务端公钥   : %s\n' "$(cat "$PUBLIC_KEY_FILE")"
    printf '  服务端隧道IP : %s\n' "$address4"
    printf '\n下一步：去入口母机添加 WG 出口。入口机完成后，再回来添加 Peer。\n'
}

add_peer() {
    need_root; load_state || die "请先部署 WG 出口。"; lock
    local name="${1:-}" public="${2:-}" address4="${3:--}" address6="${4:--}" psk="${5:--}"
    local tmp backup n p a4 a6 old_psk rest
    valid_name "$name" || { unlock; die "Peer 名称只能使用字母、数字、点、下划线和横线。"; }
    valid_key "$public" || { unlock; die "入口机公钥无效。"; }
    valid_key "$psk" || { unlock; die "PSK 无效。"; }
    valid_address 4 "$address4" || { unlock; die "入口机 IPv4 隧道地址无效。"; }
    valid_address 6 "$address6" || { unlock; die "入口机 IPv6 隧道地址无效。"; }
    [ "$address4" != "-" ] || [ "$address6" != "-" ] || { unlock; die "Peer 至少需要一个地址。"; }
    tmp="$(mktemp)"; backup="$(mktemp)"; cp -a "$PEERS_FILE" "$backup"
    printf '# 名称\t公钥\tIPv4\tIPv6\tPSK\n' > "$tmp"
    while IFS=$'\t' read -r n p a4 a6 old_psk rest; do
        case "${n:-}" in ""|\#*) continue ;; esac
        [ "$n" = "$name" ] && continue
        [ "$p" != "$public" ] || { rm -f "$tmp" "$backup"; unlock; die "该公钥已由 Peer $n 使用。"; }
        [ "$address4" = "-" ] || [ "$a4" != "$address4" ] || { rm -f "$tmp" "$backup"; unlock; die "地址已由 Peer $n 使用。"; }
        printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$p" "$a4" "$a6" "$old_psk" >> "$tmp"
    done < "$PEERS_FILE"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$public" "$address4" "$address6" "$psk" >> "$tmp"
    install -m 600 "$tmp" "$PEERS_FILE"; rm -f "$tmp"
    if ! restart_server; then install -m 600 "$backup" "$PEERS_FILE"; rm -f "$backup"; unlock; die "添加失败，已恢复旧 Peer。"; fi
    rm -f "$backup"; unlock
    info "Peer '$name' 已添加。等待约 30 秒后可查看握手状态。"
}

remove_peer() {
    need_root; load_state || die "尚未部署。"; lock
    local name="${1:-}" tmp backup n p a4 a6 psk rest found=false
    [ -n "$name" ] || { unlock; die "请提供 Peer 名称。"; }
    tmp="$(mktemp)"; backup="$(mktemp)"; cp -a "$PEERS_FILE" "$backup"; printf '# 名称\t公钥\tIPv4\tIPv6\tPSK\n' > "$tmp"
    while IFS=$'\t' read -r n p a4 a6 psk rest; do
        case "${n:-}" in ""|\#*) continue ;; esac
        if [ "$n" = "$name" ]; then found=true; else printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$p" "$a4" "$a6" "$psk" >> "$tmp"; fi
    done < "$PEERS_FILE"
    [ "$found" = true ] || { rm -f "$tmp" "$backup"; unlock; die "未找到 Peer: $name"; }
    install -m 600 "$tmp" "$PEERS_FILE"; rm -f "$tmp"
    if ! restart_server; then install -m 600 "$backup" "$PEERS_FILE"; rm -f "$backup"; unlock; die "删除失败，已恢复。"; fi
    rm -f "$backup"; unlock; info "Peer '$name' 已删除。"
}

status_server() {
    load_state || { warn "尚未部署 WG 出口。"; return 1; }
    printf '\nWG 出口状态\n'
    printf '  接口       : %s\n' "$WG_IFACE"
    printf '  UDP端口    : %s\n' "$WG_LISTEN_PORT"
    printf '  公网网卡   : %s\n' "$WG_WAN_IFACE"
    printf '  隧道地址   : %s\n' "$WG_ADDRESS4"
    printf '  服务端公钥 : %s\n' "$(cat "$PUBLIC_KEY_FILE")"
    printf '\n已添加 Peer：\n'
    if ! awk -F '\t' '$1!~/^#/ && NF {printf "  - %s  地址=%s\n",$1,$3; n++} END {exit(n?0:1)}' "$PEERS_FILE"; then
        printf '  暂无。请先在入口机添加 WG 出口，再回来添加 Peer。\n'
    fi
    printf '\n握手与流量：\n'
    wg show "$WG_IFACE" 2>/dev/null || printf '  接口未运行。\n'
}

uninstall_server() {
    need_root; lock; service_stop
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    rm -f "$WG_CONF" "$SYSCTL_FILE"; rm -rf "$STATE_DIR"; unlock
    info "WG 出口已卸载；没有改动其他代理或 nftables 表。"
}

interactive_deploy() {
    local port range min max address4 address6 mtu wan
    read -r -p "UDP端口（直接回车随机）: " port
    if [ -z "$port" ]; then
        range="$(prompt_default "随机范围" "20000-65535")"
        [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || { warn "范围格式错误。"; return 1; }
        min="${BASH_REMATCH[1]}"; max="${BASH_REMATCH[2]}"
        port="$(random_port "$min" "$max")" || { warn "范围内没有空闲端口。"; return 1; }
        info "已选择 UDP $port。"
    fi
    address4="$(prompt_default "服务端隧道地址" "10.66.0.1/24")"
    address6="-"
    mtu="$(prompt_default "MTU" "1380")"
    wan="$(prompt_default "公网网卡" "$(detect_wan)")"
    install_server "$port" "$address4" "$address6" "$mtu" "$wan"
}

interactive_add_peer() {
    local name public address4
    load_state || { warn "请先部署 WG 出口。"; return 1; }
    printf '\n请填写入口机添加 WG 出口后显示的两项信息。\n'
    name="$(prompt_required "入口机名称")"
    public="$(prompt_required "入口机公钥")"
    address4="$(prompt_default "入口机隧道地址" "10.66.0.2/32")"
    add_peer "$name" "$public" "$address4" - -
}

menu() {
    need_root; install_self
    local choice port name
    while true; do
        printf '\n============================================================\n'
        printf 'WG 出口服务器\n'
        printf '============================================================\n'
        printf '  1. 部署前检查\n'
        printf '  2. 部署或重新配置\n'
        printf '  3. 添加入口机\n'
        printf '  4. 查看状态\n'
        printf '  5. 删除入口机\n'
        printf '  6. 卸载 WG 出口\n'
        printf '  0. 退出\n'
        read -r -p "请选择 [0-6]: " choice
        case "$choice" in
            1) port="$(prompt_required "计划使用的 UDP 端口")"; preflight "$port" || true; pause ;;
            2) interactive_deploy; pause ;;
            3) interactive_add_peer; pause ;;
            4) status_server || true; pause ;;
            5) name="$(prompt_required "要删除的入口机名称")"; confirm "确认删除 $name 吗" && remove_peer "$name"; pause ;;
            6) confirm "确认卸载 WG 出口及密钥吗" && uninstall_server; pause ;;
            0|"") return 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

usage() {
    cat <<EOF
用法:
  $0 menu
  $0 check UDP端口
  $0 install UDP端口|random [服务端地址] [IPv6地址|-] [MTU] [公网网卡]
  $0 add-peer 名称 入口机公钥 入口机IPv4地址 [IPv6地址|-] [PSK|-]
  $0 status
  $0 remove-peer 名称
  $0 uninstall

安装后可直接输入: wgout
EOF
}

if [ "${WG_EGRESS_LIB_ONLY:-false}" = "true" ]; then
    return 0 2>/dev/null || exit 0
fi

command="${1:-menu}"; [ "$#" -eq 0 ] || shift
case "$command" in
    menu) menu ;;
    check|preflight) preflight "$@" ;;
    install|deploy) install_server "$@" ;;
    add-peer) add_peer "$@" ;;
    status) status_server ;;
    remove-peer) remove_peer "$@" ;;
    uninstall) uninstall_server ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
