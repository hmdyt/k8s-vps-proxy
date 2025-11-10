# K8s VPS Proxy (frp)

VPSにfrp (Fast Reverse Proxy) サーバーを自動構築し、K8sクラスターをインターネットに公開するためのセットアップスクリプト。

## 🚀 Quick Start

VPSで以下のコマンドを実行するだけ：

```bash
curl -fsSL https://raw.githubusercontent.com/hmdyt/k8s-vps-proxy/main/setup.sh | sudo TOKEN=your_token DOMAIN=example.com bash
```

または、ダウンロードして実行（推奨）：

```bash
curl -fsSL https://raw.githubusercontent.com/hmdyt/k8s-vps-proxy/main/setup.sh -o setup.sh
sudo TOKEN=your_token DOMAIN=example.com bash setup.sh
```

### 必須環境変数
- `TOKEN`: frpの認証トークン（K8s側と共有する）
- `DOMAIN`: あなたのドメイン名

## 📋 What it does

1. **frpsバイナリのインストール** - v0.65.0をGitHubからダウンロード
2. **systemdサービス登録** - 自動起動設定とサービス化
3. **ファイアウォール設定** - 必要なポート(80, 443, 7000)を自動開放
4. **K8s用設定生成** - frpcクライアント設定を自動生成・出力

## 🔧 Prerequisites

- VPS (Ubuntu 20.04+ / Debian 11+ 推奨)
- Root権限またはsudo権限
- ドメイン名
- K8s側で使用するTOKEN

## 🏗️ Architecture

```
Internet
    ↓
VPS (frps)
    ↓ frp tunnel
K8s Cluster (frpc → Ingress)
    ↓
Services
```

## 📚 Setup Flow

### 1. VPS側のセットアップ

```bash
sudo TOKEN=your_secure_token DOMAIN=example.com bash setup.sh
```

実行内容：
- frpsバイナリダウンロード → `/usr/local/bin/frps`
- 設定ファイル生成 → `/etc/frp/frps.toml`
- systemdサービス作成・起動
- UFWファイアウォール設定
- K8s用frpc設定を `~/frpc.toml` に出力

### 2. DNS設定

ドメインのDNSレコードに追加：

```
A    *.example.com    →  <VPS_IP>
```

### 3. K8s側のセットアップ

VPSセットアップ後に出力された `frpc.toml` を使用してK8s側にfrpcをデプロイします。

#### ConfigMap作成

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: frpc-config
  namespace: default
data:
  frpc.toml: |
    serverAddr = "<VPS_IP>"
    serverPort = 7000

    auth.method = "token"
    auth.token = "your_secure_token"

    [[proxies]]
    name = "web"
    type = "http"
    localIP = "127.0.0.1"
    localPort = 80
    customDomains = ["*.example.com"]

    [[proxies]]
    name = "web-https"
    type = "https"
    localIP = "127.0.0.1"
    localPort = 443
    customDomains = ["*.example.com"]
```

#### Deployment作成

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frpc
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frpc
  template:
    metadata:
      labels:
        app: frpc
    spec:
      hostNetwork: true
      containers:
      - name: frpc
        image: snowdreamtech/frpc:0.65.0
        command:
        - /usr/bin/frpc
        - -c
        - /etc/frp/frpc.toml
        volumeMounts:
        - name: frpc-config
          mountPath: /etc/frp
      volumes:
      - name: frpc-config
        configMap:
          name: frpc-config
```

**重要**: `hostNetwork: true` を使用することで、frpcがK8sノードのIngressに直接アクセスできます。

## ⚙️ Configuration

### VPS側

- `/usr/local/bin/frps` - frpsバイナリ
- `/etc/frp/frps.toml` - frps設定ファイル
- `/etc/systemd/system/frps.service` - systemdサービス
- `/var/log/frp/frps.log` - ログファイル

### 設定内容

```toml
bindPort = 7000            # frp制御ポート
vhostHTTPPort = 80         # HTTPポート
vhostHTTPSPort = 443       # HTTPSポート
auth.method = "token"      # トークン認証
subdomainHost = "example.com"  # ドメイン
```

## 🎛️ frp Dashboard

frpsには管理用Webダッシュボードが含まれています：

- URL: `http://<VPS_IP>:7500`
- User: `admin`
- Pass: `<TOKEN>`

ダッシュボードでは以下が確認できます：
- 接続中のクライアント
- プロキシ一覧
- トラフィック統計

## 🛠️ Management Commands

```bash
# サービスステータス確認
sudo systemctl status frps

# サービス再起動
sudo systemctl restart frps

# ログ確認
sudo journalctl -u frps -f

# 設定ファイル確認
sudo cat /etc/frp/frps.toml

# ログファイル確認
sudo tail -f /var/log/frp/frps.log
```

## 🔧 Ports

VPSで開放されるポート：
- `7000/tcp` - frp制御ポート（frpc ↔ frps通信）
- `7500/tcp` - frp Webダッシュボード
- `80/tcp` - HTTP
- `443/tcp` - HTTPS

## 🐛 Troubleshooting

### frpsが起動しない

```bash
# ログ確認
sudo journalctl -u frps -n 50

# 設定ファイル確認
sudo cat /etc/frp/frps.toml

# 手動起動でテスト
sudo /usr/local/bin/frps -c /etc/frp/frps.toml
```

### frpc接続エラー

```bash
# K8s側でfrpcのログ確認
kubectl logs -l app=frpc -f

# VPS側でダッシュボード確認
# http://<VPS_IP>:7500 にアクセス

# ファイアウォール確認
sudo ufw status
```

### トンネル接続はできるがHTTPアクセスできない

```bash
# K8s Ingressが80/443でリッスンしているか確認
# hostNetwork: true が設定されているか確認
kubectl get deployment frpc -o yaml | grep hostNetwork

# Ingress確認
kubectl get ingress
```

## 🔄 Update frps

新バージョンへのアップデート：

```bash
# 新しいバージョンをダウンロード
cd /tmp
curl -sSL -o frp.tar.gz https://github.com/fatedier/frp/releases/download/v0.XX.0/frp_0.XX.0_linux_amd64.tar.gz
tar xzf frp.tar.gz
sudo install -m 755 frp_0.XX.0_linux_amd64/frps /usr/local/bin/frps

# サービス再起動
sudo systemctl restart frps
```

## 📄 License

MIT

## 🤝 Contributing

Issues and Pull Requests are welcome!

## 👤 Author

[@hmdyt](https://github.com/hmdyt)
