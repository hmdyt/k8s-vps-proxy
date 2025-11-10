# K8s VPS Proxy

VPSにWireGuardトンネルとCaddyリバースプロキシを自動構築し、K8sクラスターをインターネットに安全に公開するためのセットアップスクリプト。

## 🚀 Quick Start

VPSで以下のコマンドを実行するだけ：

```bash
curl -sSL https://raw.githubusercontent.com/hmdyt/k8s-vps-proxy/main/setup.sh | sh
```

## 📋 What it does

1. **WireGuardトンネル構築** - VPSとK8sクラスター間の安全な通信路
2. **Caddyリバースプロキシ** - 自動SSL証明書取得とHTTPS化
3. **自動セットアップ** - Docker環境の構築から設定まで全自動

## 🔧 Prerequisites

- VPS (Ubuntu 20.04+ / Debian 11+ 推奨)
- Root権限またはsudo権限
- ドメイン名（ワイルドカードDNSレコード設定済み）

## 📚 Setup Flow

```
1. Dockerインストール確認・自動インストール
2. WireGuard鍵ペア自動生成
3. 対話的設定（ドメイン名入力）
4. Docker Composeで起動
5. VPS公開鍵とK8s設定情報の表示
```

## 🏗️ Architecture

```
Internet
    ↓
VPS (Caddy + WireGuard)
    ↓ WireGuard Tunnel
K8s Cluster (Ingress)
    ↓
Services
```

## ⚙️ Configuration

セットアップ後、設定は `/opt/k8s-vps-proxy/` に保存されます：

- `.env` - 環境設定
- `wireguard/` - WireGuard設定と鍵
- `caddy/` - Caddy設定

## 🔐 Network

- WireGuard Network: `10.0.0.0/24`
- VPS WireGuard IP: `10.0.0.1`
- K8s WireGuard IP: `10.0.0.2`
- WireGuard Port: `51820/UDP`

## 📝 K8s Side Setup

VPSセットアップ完了後、表示される情報を使ってK8s側でWireGuardクライアントを設定してください。

### Example WireGuard Client Config (K8s)

```ini
[Interface]
Address = 10.0.0.2/24
PrivateKey = <YOUR_K8S_PRIVATE_KEY>

[Peer]
PublicKey = <VPS_PUBLIC_KEY_FROM_SETUP>
Endpoint = <VPS_IP>:51820
AllowedIPs = 10.0.0.1/32
PersistentKeepalive = 25
```

## 🛠️ Management Commands

```bash
# ステータス確認
cd /opt/k8s-vps-proxy
docker-compose ps
docker exec wireguard wg show

# ログ確認
docker-compose logs -f

# 再起動
docker-compose restart

# 停止
docker-compose down
```

## 🐛 Troubleshooting

### WireGuard接続が確立しない

```bash
# VPS側で確認
docker exec wireguard wg show

# ピアが表示されない場合は、K8s側の公開鍵を追加
docker exec wireguard wg set wg0 peer <K8S_PUBLIC_KEY> allowed-ips 10.0.0.2/32
```

### Caddyが起動しない

```bash
# ログ確認
docker-compose logs caddy

# Caddyfile検証
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

## 📄 License

MIT

## 🤝 Contributing

Issues and Pull Requests are welcome!

## 👤 Author

[@hmdyt](https://github.com/hmdyt)