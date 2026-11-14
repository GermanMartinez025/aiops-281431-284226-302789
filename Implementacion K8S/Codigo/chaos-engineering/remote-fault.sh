#!/bin/sh
set -eu

mode=$1
marker=$2
duration=$3
workers=$4
mib=$5
iface=$6
delay=$7
loss=$8
pids=
file=
qdisc=false
locked=false
lock="/tmp/aiops-net-$iface"

die() { echo "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "falta $1 en el contenedor"; }
clean() {
  status=$?
  trap - EXIT
  trap '' HUP INT TERM
  for pid in $pids; do kill "$pid" 2>/dev/null || :; done
  for pid in $pids; do wait "$pid" 2>/dev/null || :; done
  if [ -n "$file" ]; then rm -f -- "$file" || status=1; fi
  if "$qdisc"; then
    if tc qdisc show dev "$iface" | grep -q '^qdisc netem 7a10: root'; then
      tc qdisc del dev "$iface" root handle 7a10: || status=1
    else
      echo "La regla netem cambió durante el experimento" >&2
      status=1
    fi
  fi
  if "$locked"; then rmdir "$lock" || status=1; fi
  rm -f "$marker/stop" && rmdir "$marker" || status=1
  echo "cleanup_exit_code=$status"
  exit "$status"
}

umask 077
mkdir "$marker"
trap clean EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
deadline=$(($(date +%s) + duration))
case "$mode" in
  cpu-spike)
    need yes
    i=0
    while [ "$i" -lt "$workers" ]; do
      yes >/dev/null &
      pids="$pids $!"
      i=$((i+1))
    done
    ;;
  ram-spike)
    need dd
    need df
    need mktemp
    [ "$(stat -f -c %T /dev/shm)" = tmpfs ] || die "/dev/shm debe ser tmpfs"
    if [ -r /sys/fs/cgroup/memory.max ]; then
      read -r limit </sys/fs/cgroup/memory.max
      read -r used </sys/fs/cgroup/memory.current
    else
      read -r limit </sys/fs/cgroup/memory/memory.limit_in_bytes
      read -r used </sys/fs/cgroup/memory/memory.usage_in_bytes
    fi
    available=$(df -Pk /dev/shm | awk 'END {print $4}')
    awk -v limit="$limit" -v used="$used" -v available="$available" -v mib="$mib" '
      BEGIN {exit !(limit ~ /^[0-9]+$/ && limit < 2^50 &&
        used + mib * 1048576 <= limit * .8 && available >= mib * 1024)}' ||
      die "límite cgroup ausente o falta margen de memoria/tmpfs (máximo 80% del límite)"
    file=$(mktemp /dev/shm/aiops.XXXXXXXX)
    dd if=/dev/zero of="$file" bs=1048576 count="$mib"
    ;;
  network-latency|network-loss)
    need tc
    [ "$iface" != lo ] || die "use una interfaz del pod distinta de loopback"
    mkdir "$lock" || die "interfaz reservada por otro experimento"
    locked=true
    original=$(tc qdisc show dev "$iface")
    case "$original" in
      ''|'qdisc noqueue 0: root'*) ;;
      *) die "la interfaz tiene una disciplina existente; se conserva intacta" ;;
    esac
    if [ "$mode" = network-latency ]; then
      set -- delay "${delay}ms"
    else
      set -- loss "${loss}%"
    fi
    tc qdisc add dev "$iface" root handle 7a10: netem "$@" ||
      die "netem no disponible. Verifique NET_ADMIN y soporte del nodo, o use Chaos Mesh"
    qdisc=true
    tc qdisc show dev "$iface"
    ;;
esac
echo "fault_active_at=$(date -u +%FT%TZ)"
while [ "$(date +%s)" -lt "$deadline" ] && [ ! -f "$marker/stop" ]; do sleep 1; done

