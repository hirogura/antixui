#!/bin/bash
set -euo pipefail

# --- yes/noプロンプト関数 ---
ask_yn() {
    local prompt="$1"
    local answer
    while true; do
        read -rp "$prompt [y/n]: " answer
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "y か n で答えてください。" ;;
        esac
    done
}

# --- tailscaled デーモン起動確認 ---
# antiX は sysvinit なので systemd のサービス起動が行われず、
# tailscaled が起動していない状態で tailscale up を実行すると失敗する
ensure_tailscaled() {
    if pgrep -x tailscaled >/dev/null 2>&1; then
        return 0
    fi
    if [ -x /etc/init.d/tailscaled ]; then
        sudo /etc/init.d/tailscaled start
    elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        sudo systemctl enable --now tailscaled
    elif command -v tailscaled >/dev/null 2>&1; then
        sudo mkdir -p /var/lib/tailscale /var/run/tailscale
        sudo sh -c 'nohup tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock >/var/log/tailscaled.log 2>&1 &'
    else
        echo "[error] tailscaled が見つかりません。Tailscale のインストールを確認してください。" >&2
        return 1
    fi
    local i
    for i in $(seq 1 30); do
        if [ -S /var/run/tailscale/tailscaled.sock ]; then
            return 0
        fi
        sleep 1
    done
    echo "[error] tailscaled の起動に失敗しました。/var/log/tailscaled.log を確認してください。" >&2
    return 1
}

if command -v timedatectl >/dev/null 2>&1; then
    sudo timedatectl set-timezone Asia/Tokyo
else
    # systemd 配下でない環境（antiX 等）では timedatectl が存在しないため直接設定する
    echo "Asia/Tokyo" | sudo tee /etc/timezone >/dev/null
    sudo ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
fi

sudo apt update

# console-setup / keyboard-configuration のdebconf質問を事前回答で回避
sudo debconf-set-selections <<'EOF'
console-setup console-setup/codeset47 select Guess optimal character set
console-setup console-setup/fontface47 select Fixed
console-setup console-setup/fontsize select 16
keyboard-configuration keyboard-configuration/layout select Japanese
keyboard-configuration keyboard-configuration/layoutcode string jp
keyboard-configuration keyboard-configuration/variant select Japanese
EOF

sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
sudo apt install -y curl
curl -fsSL https://tailscale.com/install.sh | sudo sh

echo ""
if ask_yn "Tailscale の authkey がありますか？"; then
    USE_TS_AUTHKEY=true
else
    USE_TS_AUTHKEY=false
fi
echo ""

ensure_tailscaled

if [ "$USE_TS_AUTHKEY" = true ]; then
    # authkey認証に失敗した場合は、別のキー再試行かブラウザ認証かを選択させる
    while true; do
        read -rsp "authkey を入力してください（tskeyから始まる文字列。入力は非表示）: " TS_AUTHKEY
        echo ""
        if [ -z "${TS_AUTHKEY:-}" ]; then
            echo "authkey が空です。もう一度入力してください。"
            continue
        fi
        if sudo tailscale up --authkey="$TS_AUTHKEY"; then
            unset TS_AUTHKEY
            break
        fi
        unset TS_AUTHKEY
        echo ""
        echo "[error] Tailscale の認証に失敗しました（authkey が無効・期限切れの可能性があります）。"
        echo "次の方法を選択してください:"
        echo "  1) 別の Tailscale Auth key を試す"
        echo "  2) 通常の Webブラウザ認証をする"
        choice=""
        while true; do
            read -rp "選択 [1/2]: " choice
            case "$choice" in
                1|2) break ;;
                *) echo "1 か 2 で答えてください。" ;;
            esac
        done
        if [ "$choice" = "2" ]; then
            echo "[info] Webブラウザ認証フローを開始します"
            sudo tailscale up
            break
        fi
        echo "[info] 別の authkey を入力してください"
    done
else
    echo "[info] authkey未入力のためブラウザ認証フローを開始します"
    sudo tailscale up
fi

sudo apt install -y git
if [[ ! -d antixui ]]; then
  sudo git clone https://github.com/hirogura/antixui.git
  cd antixui
else
  echo "[info] ./antixui already exists, updating to latest..."
  cd antixui
  sudo git fetch origin main
  sudo git reset --hard origin/main
fi
sudo bash setup.sh
