#!/bin/bash

set -e

NQPTP_VERSION="1.2.4"
SHAIRPORT_SYNC_VERSION="4.3.5"
TMP_DIR=""

cleanup() {
    if [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
}

remove_previous_versions() {
    echo "Removing previous versions of Shairport Sync and NQPTP..."

    # Disable services if they exist
    if systemctl is-enabled --quiet shairport-sync; then
        echo "Disabling Shairport Sync..."
        sudo systemctl disable --now shairport-sync || true
    fi

    if systemctl is-enabled --quiet nqptp; then
        echo "Disabling NQPTP..."
        sudo systemctl disable --now nqptp || true
    fi

    # Find and remove binaries
    for app in shairport-sync nqptp; do
        BIN_PATH=$(which "$app" || true)
        if [[ -n "$BIN_PATH" ]]; then
            echo "Removing $app at $BIN_PATH..."
            sudo rm -f "$BIN_PATH"
        else
            echo "$app binary not found. Skipping removal."
        fi
    done

    echo "Previous versions removed."
}

verify_os() {
    MSG="Unsupported OS: Raspberry Pi OS 12 (bookworm) is required."

    if [ ! -f /etc/os-release ]; then
        echo $MSG
        exit 1
    fi

    . /etc/os-release

    if [ "$ID" != "debian" && "$ID" != "raspbian" ] || [ "$VERSION_ID" != "11" ]; then
        echo $MSG
        exit 1
    fi
}

set_hostname() {
    CURRENT_PRETTY_HOSTNAME=$(hostnamectl status --pretty)

    read -p "Hostname [$(hostname)]: " HOSTNAME
    sudo raspi-config nonint do_hostname ${HOSTNAME:-$(hostname)}

    read -p "Pretty hostname [${CURRENT_PRETTY_HOSTNAME:-Raspberry Pi}]: " PRETTY_HOSTNAME
    PRETTY_HOSTNAME="${PRETTY_HOSTNAME:-${CURRENT_PRETTY_HOSTNAME:-Raspberry Pi}}"
    sudo hostnamectl set-hostname --pretty "$PRETTY_HOSTNAME"
}

install_shairport() {
    read -p "Do you want to install Shairport Sync (AirPlay 2 audio player)? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^(yes|y|Y)$ ]]; then return; fi

    sudo apt update
    sudo apt install -y --no-install-recommends wget unzip autoconf automake build-essential libtool git autoconf automake libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev libssl-dev libsoxr-dev libplist-dev libsodium-dev libavutil-dev libavcodec-dev libavformat-dev uuid-dev libgcrypt20-dev xxd

    if [[ -z "$TMP_DIR" ]]; then
        TMP_DIR=$(mktemp -d)
    fi

    cd $TMP_DIR

    # Install ALAC
    wget -O alac-master.zip https://github.com/mikebrady/alac/archive/refs/heads/master.zip
    unzip alac-master.zip
    cd alac-master
    autoreconf -fi
    ./configure
    make -j $(nproc)
    sudo make install
    sudo ldconfig
    cd ..
    rm -rf alac-master

    # Install NQPTP
    wget -O nqptp-${NQPTP_VERSION}.zip https://github.com/mikebrady/nqptp/archive/refs/tags/${NQPTP_VERSION}.zip
    unzip nqptp-${NQPTP_VERSION}.zip
    cd nqptp-${NQPTP_VERSION}
    autoreconf -fi
    ./configure --with-systemd-startup
    make -j $(nproc)
    sudo make install
    cd ..
    rm -rf nqptp-${NQPTP_VERSION}

    # Install Shairport Sync
    wget -O shairport-sync-${SHAIRPORT_SYNC_VERSION}.zip https://github.com/mikebrady/shairport-sync/archive/refs/tags/${SHAIRPORT_SYNC_VERSION}.zip
    unzip shairport-sync-${SHAIRPORT_SYNC_VERSION}.zip
    cd shairport-sync-${SHAIRPORT_SYNC_VERSION}
    autoreconf -fi
    ./configure --sysconfdir=/etc --with-alsa --with-soxr --with-mqtt-client --with-metadata --with-avahi --with-ssl=openssl --with-systemd --with-airplay-2 --with-apple-alac
    make -j $(nproc)
    sudo make install
    cd ..
    rm -rf shairport-sync-${SHAIRPORT_SYNC_VERSION}

    # Configure Shairport Sync
    sudo tee /etc/shairport-sync.conf >/dev/null <<EOF
general = {
  name = "${PRETTY_HOSTNAME:-$(hostname)}";
  output_backend = "alsa";
}

sessioncontrol = {
  session_timeout = 20;
};

metadata =
{
        enabled = "yes";
        include_cover_art = "yes";
        cover_art_cache_directory = "/tmp/shairport-sync/.cache/coverart";
        pipe_name = "/tmp/shairport-sync-metadata";
        pipe_timeout = 5000;
};

mqtt =
{
        enabled = "yes";
        hostname = "192.168.3.41";
        port = 1883;
        topic = "shairport";
        publish_parsed = "yes";
        publish_cover = "yes";
        enable_remote = "yes";
};
EOF

    sudo usermod -a -G gpio shairport-sync
    sudo systemctl enable --now nqptp
    sudo systemctl enable --now shairport-sync

    echo "Shairport Sync installed and enabled."
}

install_raspotify() {
    read -p "Do you want to install Raspotify (Spotify Connect)? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^(yes|y|Y)$ ]]; then return; fi

    curl -sL https://dtcooper.github.io/raspotify/install.sh | sh

    # Configure Raspotify
    LIBRESPOT_NAME="${PRETTY_HOSTNAME// /-}"
    LIBRESPOT_NAME=${LIBRESPOT_NAME:-$(hostname)}

    sudo tee /etc/raspotify/conf >/dev/null <<EOF
LIBRESPOT_NAME="${LIBRESPOT_NAME}"
LIBRESPOT_DEVICE_TYPE="avr"
LIBRESPOT_BITRATE="320"
LIBRESPOT_INITIAL_VOLUME="30"
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now raspotify

    echo "Raspotify installed and enabled."
}

setup_timer() {
    echo "Setting up systemd timer to restart Shairport Sync every Sunday at 4 AM..."

    # Create systemd timer unit
    sudo tee /etc/systemd/system/shairport-sync-restart.timer >/dev/null <<EOF
[Unit]
Description=Restart Shairport Sync Weekly

[Timer]
OnCalendar=Sun 04:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Create corresponding service unit
    sudo tee /etc/systemd/system/shairport-sync-restart.service >/dev/null <<EOF
[Unit]
Description=Restart Shairport Sync Service

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart shairport-sync
EOF

    # Enable and start the timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now shairport-sync-restart.timer

    echo "Systemd timer enabled."
}

trap cleanup EXIT

echo "Raspberry Pi Audio Receiver"

verify_os
remove_previous_versions
set_hostname
install_shairport
install_raspotify
setup_timer
