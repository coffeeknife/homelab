#!/command/with-contenv bash

OT_VENDOR_NAME="${OT_VENDOR_NAME:-OpenThread}"
OT_VENDOR_MODEL="${OT_VENDOR_MODEL:-BorderRouter}"
OT_LOG_LEVEL="${OT_LOG_LEVEL:-7}"
OT_RCP_DEVICE="${OT_RCP_DEVICE:-spinel+hdlc+uart:///dev/ttyACM0?uart-baudrate=1000000}"
OT_INFRA_IF="${OT_INFRA_IF:-wlan0}"
OT_THREAD_IF="${OT_THREAD_IF:-wpan0}"
OT_REST_LISTEN_ADDR="${OT_REST_LISTEN_ADDR:-127.0.0.1}"
OT_REST_LISTEN_PORT="${OT_REST_LISTEN_PORT:-8081}"
OT_FORWARD_INGRESS_CHAIN="OT_FORWARD_INGRESS"

die() {
    echo >&2 "ERROR: $*"
    exit 1
}

mkdir -p /data/thread && ln -sft /var/lib /data/thread || die "Could not create directory /var/lib/thread to store Thread data."

echo "Configuring OpenThread firewall..."

ipset create -exist otbr-ingress-deny-src hash:net family inet6
ipset create -exist otbr-ingress-deny-src-swap hash:net family inet6
ipset create -exist otbr-ingress-allow-dst hash:net family inet6
ipset create -exist otbr-ingress-allow-dst-swap hash:net family inet6

ip6tables -N "${OT_FORWARD_INGRESS_CHAIN}"
ip6tables -I FORWARD 1 -o "${OT_THREAD_IF}" -j "${OT_FORWARD_INGRESS_CHAIN}"

ip6tables -A "${OT_FORWARD_INGRESS_CHAIN}" -m pkttype --pkt-type unicast -i "${OT_THREAD_IF}" -j DROP
ip6tables -A "${OT_FORWARD_INGRESS_CHAIN}" -m set --match-set otbr-ingress-deny-src src -j DROP
ip6tables -A "${OT_FORWARD_INGRESS_CHAIN}" -m set --match-set otbr-ingress-allow-dst dst -j ACCEPT
ip6tables -A "${OT_FORWARD_INGRESS_CHAIN}" -m pkttype --pkt-type unicast -j DROP
ip6tables -A "${OT_FORWARD_INGRESS_CHAIN}" -j ACCEPT

echo "Configuring OpenThread NAT64..."

iptables -t mangle -A PREROUTING -i "${OT_THREAD_IF}" -j MARK --set-mark 0x1001
iptables -t nat -A POSTROUTING -m mark --mark 0x1001 -j MASQUERADE
iptables -t filter -A FORWARD -o "${OT_INFRA_IF}" -j ACCEPT
iptables -t filter -A FORWARD -i "${OT_INFRA_IF}" -j ACCEPT

echo "Starting otbr-agent (with CRTSCTS disabled via LD_PRELOAD)..."

export LD_PRELOAD=/data/no_crtscts.so

exec s6-notifyoncheck -d -s 300 -w 300 -n 0 stdbuf -oL \
     "/usr/sbin/otbr-agent" \
        -d"${OT_LOG_LEVEL}" -v -s \
        --vendor-name "${OT_VENDOR_NAME}" \
        --model-name "${OT_VENDOR_MODEL}" \
        -I "${OT_THREAD_IF}" \
        -B "${OT_INFRA_IF}" \
        "${OT_RCP_DEVICE}" \
        "trel://${OT_INFRA_IF}" \
        --rest-listen-address "${OT_REST_LISTEN_ADDR}" \
        --rest-listen-port "${OT_REST_LISTEN_PORT}"
