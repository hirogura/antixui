#!/bin/bash
# ============================================================
# antix-UI Setup Script for antiX (sysVinit)
# ------------------------------------------------------------
# Usage: sudo bash setup.sh [--branch <name>] [--no-restart]
#
# This script:
# 1. Installs system dependencies (apt)
# 2. Installs the antiX systemctl shim (sysVinit translation)
# 3. Creates a dedicated user for antix-UI
# 4. Sets up sudoers for management commands
# 5. Deploys antix-UI from GitHub (this repo)
# 6. Creates sysVinit service (/etc/init.d/antixui)
# 7. Configures Tailscale serve (HTTPS, optional)
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
APP_NAME="antix-UI"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/opt/antix-ui"
ANTIX_DIR="$BASE_DIR/antix"
APP_USER="antixui"
APP_PORT=3355
REPO_URL="https://github.com/hirogura/antixui.git"
BRANCH="main"
NO_RESTART=0

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) [[ $# -ge 2 ]] || err "--branch requires a value"; BRANCH="$2"; shift 2 ;;
    --no-restart) NO_RESTART=1; shift ;;
    *) err "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || err "root で実行してください (sudo bash setup.sh)"

# --- 依存パッケージ ---
log "依存パッケージをインストール中..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq python3 python3-pip python3-venv git curl lsb-base >/dev/null

# --- systemd が無い環境向け systemctl シム ---
if command -v systemctl >/dev/null 2>&1 && [ ! -e /usr/local/bin/systemctl ]; then
    info "systemd が検出されました。シムは不要のためスキップします。"
elif [ ! -e /usr/local/bin/systemctl ]; then
    log "systemctl シム (antiX / sysVinit 用) を /usr/local/bin/systemctl へ導入..."
    install -m 755 "$ANTIX_DIR/systemctl" /usr/local/bin/systemctl
else
    info "systemctl シムは既に導入済み。更新します。"
    install -m 755 "$ANTIX_DIR/systemctl" /usr/local/bin/systemctl
fi

# --- tailscaled (未導入なら sysVinit スクリプトを導入) ---
if ! pgrep -x tailscaled >/dev/null 2>&1; then
    if [ -x /etc/init.d/tailscaled ]; then
        log "tailscaled を起動..."
        /etc/init.d/tailscaled start || true
    else
        log "tailscaled を sysVinit スクリプトで導入..."
        install -m 755 "$ANTIX_DIR/tailscaled.init" /etc/init.d/tailscaled
        update-rc.d tailscaled defaults
        /etc/init.d/tailscaled start || true
    fi
fi

# --- Tailscale 未接続ならここではスキップ（setup.sh では接続済み前提） ---
if command -v tailscale >/dev/null 2>&1; then
    if ! tailscale status >/dev/null 2>&1; then
        warn "Tailscale が未接続です。'tailscale up' 後に再実行するか、手動で設定してください:"
        warn "  tailscale serve --bg --https 3355 http://127.0.0.1:3355"
    fi
fi

# --- アプリ用ユーザー ---
if ! id "$APP_USER" &>/dev/null; then
    log "ユーザー $APP_USER を作成..."
    useradd -r -m -s /bin/bash "$APP_USER"
else
    info "ユーザー $APP_USER は既に存在します"
fi

# --- sudoers ---
SUDOERS_FILE="/etc/sudoers.d/antixui-systemctl"
log "sudoers を設定..."
cat > "$SUDOERS_FILE" << 'EOF'
# antix-UI (antiX): 管理コマンドをパスワードなしで許可
Defaults:antixui env_keep += "DEBIAN_FRONTEND"
antixui ALL=(ALL) NOPASSWD: /usr/local/bin/systemctl, \
    /usr/bin/apt, \
    /usr/bin/apt-get, \
    /usr/bin/dpkg, \
    /usr/sbin/reboot, \
    /sbin/reboot, \
    /usr/bin/reboot, \
    /usr/sbin/poweroff, \
    /sbin/poweroff, \
    /usr/bin/poweroff, \
    /usr/sbin/rfkill, \
    /usr/sbin/ip, \
    /usr/bin/ip, \
    /usr/bin/env, \
    /usr/bin/su, \
    /usr/bin/sudo
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null || err "sudoers ファイルが不正です"

PRIMARY_USER=$(getent passwd 1000 | cut -d: -f1 || true)
if [[ -n "${PRIMARY_USER:-}" ]]; then
    USER_SUDOERS="/etc/sudoers.d/${PRIMARY_USER}-antix-nopasswd"
    log "sudoers を $PRIMARY_USER に設定 (ターミナル用)..."
    cat > "$USER_SUDOERS" << EOF
Defaults:$PRIMARY_USER env_keep += "DEBIAN_FRONTEND"
$PRIMARY_USER ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 "$USER_SUDOERS"
    visudo -cf "$USER_SUDOERS" >/dev/null || err "sudoers ファイルが不正です ($PRIMARY_USER)"
fi

# --- デプロイ (GitHub から最新を取得) ---
log "antix-UI を GitHub から取得中... (branch: $BRANCH)"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR:?}"' EXIT

if [[ -d "$APP_DIR/.git" ]]; then
    info "既存インストールを検出。更新します..."
    cd "$APP_DIR"
    if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$APP_DIR"; then
        git config --global --add safe.directory "$APP_DIR"
    fi
    git fetch origin "$BRANCH"
    git reset --hard FETCH_HEAD
else
    git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$TEMP_DIR"
    mkdir -p "$APP_DIR"
    cp -a "$TEMP_DIR/." "$APP_DIR/"
fi

# --- Python venv ---
log "Python 仮想環境をセットアップ..."
if [[ ! -d "$APP_DIR/venv" ]]; then
    python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

chown -R "$APP_USER:$APP_USER" "$APP_DIR"

# --- sysVinit サービス ---
log "/etc/init.d/antixui を作成..."
install -m 755 "$ANTIX_DIR/antixui.init" /etc/init.d/antixui
log "update-rc.d で自動起動を登録..."
update-rc.d antixui defaults

log "antix-UI を起動..."
/etc/init.d/antixui restart || err "antix-UI の起動に失敗しました"
sleep 2
if /etc/init.d/antixui status >/dev/null 2>&1; then
    log "antix-UI がポート $APP_PORT で稼働中"
else
    err "antix-UI が起動していません。ログを確認してください: /var/log/antixui.log"
fi

# --- Tailscale serve (HTTPS 公開) ---
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    TS_HOSTNAME=$(tailscale status --json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Self']['DNSName'].rstrip('.'))" 2>/dev/null || echo "")
    log "Tailscale serve を設定 (HTTPS 3355)..."
    tailscale serve --bg --https 3355 "http://127.0.0.1:$APP_PORT" \
        || warn "tailscale serve に失敗。手動で: tailscale serve --bg --https 3355 http://127.0.0.1:$APP_PORT"
    [ -n "$TS_HOSTNAME" ] && info "URL: https://$TS_HOSTNAME:3355"
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  ✅ antix-UI セットアップ完了!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  ${CYAN}ローカルURL:${NC}  http://127.0.0.1:$APP_PORT"
echo -e "  ${CYAN}サービス:${NC}    /etc/init.d/antixui {start|stop|restart|status}"
echo -e "  ${CYAN}ログ:${NC}        /var/log/antixui.log"
echo -e "  ${CYAN}導入先:${NC}      $APP_DIR"
echo -e "  ${CYAN}shim:${NC}        /usr/local/bin/systemctl (sysVinit 変換)"
echo -e "  ${CYAN}リポジトリ:${NC}  $REPO_URL"
echo ""
