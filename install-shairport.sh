#!/bin/bash -e

if [[ $(id -u) -ne 0 ]] ; then echo "Please run as root" ; exit 1 ; fi

: "${SHAIRPORT_VERSION:=4.3.2}"

echo
echo -n "Do you want to install Shairport Sync AirPlay 2 Audio Receiver (shairport-sync v${SHAIRPORT_VERSION})? [y/N] "
read REPLY
if [[ ! "$REPLY" =~ ^(yes|y|Y)$ ]]; then exit 0; fi

apt install --no-install-recommends build-essential git autoconf automake libtool libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev libssl-dev libsoxr-dev libplist-dev libsodium-dev libavutil-dev libavcodec-dev libavformat-dev uuid-dev libgcrypt-dev xxd libpulse-dev

# ALAC
git clone --depth 1 https://github.com/mikebrady/alac.git
cd alac
autoreconf -fi
./configure
make -j $(nproc)
make install
ldconfig
cd ..
rm -rf alac

# NQPTP
git clone https://github.com/mikebrady/nqptp.git
cd nqptp
git checkout 1.2.4
autoreconf -fi
./configure --with-systemd-startup
make -j $(nproc)
make install
cd ..
rm -rf nqptp

# Shairport Sync
git clone https://github.com/mikebrady/shairport-sync.git
cd shairport-sync
git checkout 4.3.2
autoreconf -fi
./configure --sysconfdir=/etc --with-mqtt-client --with-metadata --with-alsa --with-pa --with-soxr --with-avahi --with-ssl=openssl --with-airplay-2 --with-apple-alac
make -j $(nproc)
make install
cd ..
rm -rf shairport-sync

usermod -a -G gpio shairport-sync

PRETTY_HOSTNAME=$(hostnamectl status --pretty)
PRETTY_HOSTNAME=${PRETTY_HOSTNAME:-$(hostname)}

cat <<EOF > "/etc/shairport-sync.conf"
general = {
  name = "${PRETTY_HOSTNAME}";
  output_backend = "pa";
}

sessioncontrol = {
  session_timeout = 20;
};

metadata =
{
        enabled = "yes"; // set this to yes to get Shairport Sync to solicit metadata from the source and to pass it on via a pipe
        include_cover_art = "yes"; // set to "yes" to get Shairport Sync to solicit cover art from the source and pass it via the pipe. You must also set "enabled" to "yes".
        cover_art_cache_directory = "/tmp/shairport-sync/.cache/coverart"; // artwork will be  stored in this directory if the dbus or MPRIS interfaces are enabled or if the MQTT client is>
        pipe_name = "/tmp/shairport-sync-metadata";
        pipe_timeout = 5000; // wait for this number of milliseconds for a blocked pipe to unblock before giving up
};

mqtt =
{
        enabled = "yes"; // set this to yes to enable the mqtt-metadata-service
        hostname = "192.168.3.41"; // Hostname of the MQTT Broker
        port = 1883; // Port on the MQTT Broker to connect to
        topic = "shairport"; //MQTT topic where this instance of shairport-sync should publish. If not set, the general.name value is used.
//      publish_raw = "no"; //whether to publish all available metadata under the codes given in the 'metadata' docs.
        publish_parsed = "yes"; //whether to publish a small (but useful) subset of metadata under human-understandable topics
        publish_cover = "yes"; //whether to publish the cover over mqtt in binary form. This may lead to a bit of load on the broker
        enable_remote = "yes"; //whether to remote control via MQTT. RC is available under `topic`/remote.
};
EOF

systemctl enable --now nqptp

pm2 start shairport-sync
pm2 save
