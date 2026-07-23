入口
```
(curl -LfsS https://raw.githubusercontent.com/jishengkele/xxooxxoo/main/incus-egress-switch-wg.sh -o /usr/local/sbin/incus-egress-switch || wget -q https://raw.githubusercontent.com/jishengkele/xxooxxoo/main/incus-egress-switch-wg.sh -O /usr/local/sbin/incus-egress-switch) && chmod +x /usr/local/sbin/incus-egress-switch && ln -sfn /usr/local/sbin/incus-egress-switch /usr/local/sbin/sbout && sbout
```

WG部署
```
(curl -LfsS https://raw.githubusercontent.com/jishengkele/xxooxxoo/main/wireguard-egress-server.sh -o /usr/local/sbin/wireguard-egress-server || wget -q https://raw.githubusercontent.com/jishengkele/xxooxxoo/main/incus-egress-switch-wg.sh -O /usr/local/sbin/wireguard-egress-server) && chmod +x /usr/local/sbin/wireguard-egress-server && ln -sfn /usr/local/sbin/incus-egress-switch /usr/local/sbin/sbout && sbout
```
