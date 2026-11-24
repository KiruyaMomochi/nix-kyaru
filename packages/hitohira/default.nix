{ pkgs, lib, ... }:

let
  armPkgs =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
    then pkgs
    else import pkgs.path {
      system = "aarch64-linux";
      config = pkgs.config;
    };

  runtimePackages = with armPkgs; [
    bashInteractive
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    gnutar
    gzip
    xz
    zstd
    procps
    util-linuxMinimal
    iproute2
    file
    which
    less

    nushell
    helix
    starship
    openssh
    ripgrep
    fd
    bat
    delta
    sd
    jq
    sqlite
    curl
    cacert
    gitMinimal
    rsync
    tmux
    wstunnel
    nix
  ];

  pkgPaths = lib.concatStringsSep " " (map (p: "${p}") runtimePackages);
in
pkgs.runCommand "hitohira-0.1.0" {
  nativeBuildInputs = [ pkgs.lndir ];
  passthru = {
    inherit armPkgs runtimePackages;
  };
} ''
  mkdir -p $out/bin $out/etc/ssh $out/etc/ssl/certs $out/share/sukisu-module

  for pkg in ${pkgPaths}; do
    for sub in bin sbin libexec share; do
      if [ -d "$pkg/$sub" ]; then
        mkdir -p "$out/$sub"
        lndir -silent "$pkg/$sub" "$out/$sub"
      fi
    done
  done

  ln -sf ${armPkgs.cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-bundle.crt

  cat > $out/etc/ssh/sshd_config <<'EOF'
  Port 8023
  HostKey /data/hitohira/etc/ssh/ssh_host_ed25519_key
  PidFile /run/sshd.pid
  PermitRootLogin prohibit-password
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  AuthorizedKeysFile /home/kyaru/.ssh/authorized_keys
  StrictModes yes
  UsePAM no
  PrintMotd no
  Subsystem sftp internal-sftp
  SetEnv PATH=/home/kyaru/.nix-profile/bin:/nix/var/nix/profiles/per-user/kyaru/profile/bin:/nix/var/nix/profiles/hitohira/bin:/nix/var/nix/profiles/hitohira/sbin:/home/kyaru/.local/bin:/system/bin:/data/adb/ksu/bin SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt TZ=Asia/Shanghai LANG=C.UTF-8
  EOF
  sed -i 's/^  //' $out/etc/ssh/sshd_config

  cat > $out/bin/hitohira-ctl <<'EOF'
  #!/system/bin/sh
  set -eu

  NS_BASE="/data/local/tmp/.hitohira_ns"
  RUN_DIR="/data/hitohira/run"
  PIDFILE="$RUN_DIR/ns.pid"
  HOST_PROFILE="/data/nix/var/nix/profiles/hitohira"

  is_running() {
    [ -f "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    [ "$comm" = "sshd" ]
  }

  ensure_dirs() {
    mkdir -p \
      /data/nix/store \
      /data/nix/var/nix/profiles/per-user/kyaru \
      /data/hitohira/home/.local/state/nix/profiles \
      /data/hitohira/home/.ssh \
      /data/hitohira/home/.local/bin \
      /data/hitohira/home/.config/nushell \
      /data/hitohira/home/.config/nix \
      /data/hitohira/etc/ssh \
      "$RUN_DIR"
    chown 0:0 /data/hitohira/home /data/hitohira/home/.ssh
    chmod 0755 /data/hitohira/home
    chmod 0700 /data/hitohira/home/.ssh
    [ -f /data/hitohira/home/.ssh/authorized_keys ] && chmod 0600 /data/hitohira/home/.ssh/authorized_keys || true

    if [ ! -f /data/hitohira/home/.config/nix/nix.conf ]; then
      cat > /data/hitohira/home/.config/nix/nix.conf <<'NIXEOF'
  experimental-features = nix-command flakes
  sandbox = false
  filter-syscalls = false
  NIXEOF
    fi

    if [ ! -f /data/hitohira/home/.config/nushell/config.nu ]; then
      cat > /data/hitohira/home/.config/nushell/config.nu <<'NUEOF'
  $env.config.show_banner = false
  $env.PATH = ($env.PATH | split row (char esep) | prepend [
    "/nix/var/nix/profiles/hitohira/bin"
    "/nix/var/nix/profiles/hitohira/sbin"
    "/home/kyaru/.local/bin"
  ] | uniq)
  NUEOF
    fi
  }

  do_start() {
    if is_running; then
      return 0
    fi
    ensure_dirs
    rm -f "$PIDFILE"

    env -i PATH=/data/adb/ksu/bin:/system/bin unshare -m /system/bin/sh -c '
      set -eu
      NS_BASE="/data/local/tmp/.hitohira_ns"
      P="/nix/var/nix/profiles/hitohira"

      if command -v busybox >/dev/null 2>&1; then
        MNT="busybox mount"
      else
        MNT="mount"
      fi

      $MNT --make-rprivate / 2>/dev/null || true
      mkdir -p "$NS_BASE"
      $MNT -t tmpfs -o size=64M,mode=0755 tmpfs "$NS_BASE"

      mkdir -p \
        "$NS_BASE/up/nix" \
        "$NS_BASE/up/dev_host" \
        "$NS_BASE/up/home/kyaru" \
        "$NS_BASE/up/root" \
        "$NS_BASE/up/tmp" \
        "$NS_BASE/up/run" \
        "$NS_BASE/up/var/empty" \
        "$NS_BASE/up/var/run" \
        "$NS_BASE/up/etc/ssl/certs" \
        "$NS_BASE/up/etc/nix" \
        "$NS_BASE/up/usr/bin" \
        "$NS_BASE/up/bin" \
        "$NS_BASE/wk" \
        "$NS_BASE/merged"

      chmod 1777 "$NS_BASE/up/tmp"
      chown 0:0 "$NS_BASE/up/var/empty"
      chmod 0755 "$NS_BASE/up/var/empty"

      cat > "$NS_BASE/up/etc/passwd" <<PWEOF
  root:x:0:0:root:/home/kyaru:/bin/bash
  kyaru:x:0:0:Kiruya Momochi:/home/kyaru:$P/bin/nu
  sshd:x:74:74:Privilege-separated SSH:/var/empty:/bin/false
  nobody:x:65534:65534:nobody:/var/empty:/bin/false
  PWEOF

      cat > "$NS_BASE/up/etc/group" <<GRPEOF
  root:x:0:root,kyaru
  inet:x:3003:root,kyaru,sshd
  sshd:x:74:
  nobody:x:65534:
  GRPEOF

      cat > "$NS_BASE/up/etc/nsswitch.conf" <<NSSEOF
  passwd: files
  group: files
  hosts: files dns
  NSSEOF

      cat > "$NS_BASE/up/etc/resolv.conf" <<RESEOF
  nameserver 223.5.5.5
  nameserver 1.1.1.1
  nameserver 8.8.8.8
  RESEOF

      cat > "$NS_BASE/up/etc/nix/nix.conf" <<NIXCEOF
  experimental-features = nix-command flakes
  sandbox = false
  filter-syscalls = false
  build-users-group =
  trusted-users = root kyaru
  NIXCEOF

      cat > "$NS_BASE/up/etc/profile" <<PROFEOF
  export PATH="/home/kyaru/.nix-profile/bin:/nix/var/nix/profiles/per-user/kyaru/profile/bin:$P/bin:$P/sbin:/home/kyaru/.local/bin:/system/bin:/data/adb/ksu/bin"
  export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
  export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
  export LANG=C.UTF-8
  export TZ=Asia/Shanghai
  PROFEOF

      ln -sf "$P/bin/bash" "$NS_BASE/up/bin/sh"
      ln -sf "$P/bin/bash" "$NS_BASE/up/bin/bash"
      ln -sf "$P/bin/false" "$NS_BASE/up/bin/false"
      ln -sf "$P/bin/env" "$NS_BASE/up/usr/bin/env"
      ln -sf "$P/bin/nix" "$NS_BASE/up/usr/bin/nix"
      ln -sf "$P/bin/nix-store" "$NS_BASE/up/usr/bin/nix-store"
      ln -sf "$P/bin/nix-daemon" "$NS_BASE/up/usr/bin/nix-daemon"
      ln -sf "$P/etc/ssl/certs/ca-bundle.crt" "$NS_BASE/up/etc/ssl/certs/ca-bundle.crt"
      ln -sf "$P/etc/ssl/certs/ca-bundle.crt" "$NS_BASE/up/etc/ssl/certs/ca-certificates.crt"

      $MNT -t overlay overlay -o "lowerdir=/,upperdir=$NS_BASE/up,workdir=$NS_BASE/wk" "$NS_BASE/merged"

      for d in proc sys data apex system vendor product system_ext mnt storage linkerconfig; do
        if [ -d "/$d" ]; then
          mkdir -p "$NS_BASE/merged/$d" 2>/dev/null || true
          $MNT --rbind "/$d" "$NS_BASE/merged/$d" 2>/dev/null || true
        fi
      done

      $MNT --rbind /dev "$NS_BASE/merged/dev_host"
      $MNT -t tmpfs -o size=16M,mode=0755 tmpfs "$NS_BASE/merged/dev"
      for item in /dev/*; do
        name="''${item#/dev/}"
        [ "$name" = "pts" ] || [ "$name" = "ptmx" ] || [ "$name" = "shm" ] && continue
        ln -sf "/dev_host/$name" "$NS_BASE/merged/dev/$name"
      done
      mkdir -p "$NS_BASE/merged/dev/pts" "$NS_BASE/merged/dev/shm"
      $MNT -t devpts -o newinstance,ptmxmode=0666,mode=0620 devpts "$NS_BASE/merged/dev/pts"
      ln -sf pts/ptmx "$NS_BASE/merged/dev/ptmx"
      $MNT -t tmpfs -o size=256M,mode=1777 tmpfs "$NS_BASE/merged/dev/shm"
      ln -sf /proc/self/fd "$NS_BASE/merged/dev/fd"
      ln -sf /proc/self/fd/0 "$NS_BASE/merged/dev/stdin"
      ln -sf /proc/self/fd/1 "$NS_BASE/merged/dev/stdout"
      ln -sf /proc/self/fd/2 "$NS_BASE/merged/dev/stderr"

      $MNT -t tmpfs -o size=256M,mode=1777 tmpfs "$NS_BASE/merged/tmp"
      $MNT -t tmpfs -o size=16M,mode=0755 tmpfs "$NS_BASE/merged/run"
      $MNT --bind /data/nix "$NS_BASE/merged/nix"
      $MNT --bind /data/hitohira/home "$NS_BASE/merged/home/kyaru"
      $MNT --bind /data/hitohira/home "$NS_BASE/merged/root"

      if [ ! -f /data/hitohira/etc/ssh/ssh_host_ed25519_key ]; then
        chroot "$NS_BASE/merged" "$P/bin/ssh-keygen" -t ed25519 -f /data/hitohira/etc/ssh/ssh_host_ed25519_key -N "" >/dev/null
        chmod 0600 /data/hitohira/etc/ssh/ssh_host_ed25519_key
      fi

      if [ -f /data/hitohira/etc/beacon.conf ] && [ -x "$P/bin/hitohira-beacon" ]; then
        chroot "$NS_BASE/merged" "$P/bin/hitohira-beacon" </dev/null >> /data/hitohira/run/beacon.log 2>&1 &
      fi

      exec chroot "$NS_BASE/merged" "$P/bin/sshd" -D -e -f "$P/etc/ssh/sshd_config"
    ' >> "$RUN_DIR/sshd.log" 2>&1 &

    dpid=$!
    echo "$dpid" > "$PIDFILE"

    i=0
    while [ "$i" -lt 60 ]; do
      if is_running; then
        return 0
      fi
      sleep 0.2
      i=$((i + 1))
    done

    echo "hitohira: failed to start sshd; recent log:" >&2
    tail -n 20 "$RUN_DIR/sshd.log" >&2 || true
    return 1
  }

  do_stop() {
    if is_running; then
      pid="$(cat "$PIDFILE")"
      kill "$pid" 2>/dev/null || true
      sleep 0.3
      [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null || true
    fi
    for p in /proc/[0-9]*; do
      [ -r "$p/cmdline" ] || continue
      cmdline="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)"
      case "$cmdline" in
        *"/profiles/hitohira/etc/ssh/sshd_config"*|*"hitohira-beacon"*|*"wstunnel client"*)
          opid="''${p#/proc/}"
          kill "$opid" 2>/dev/null || true
          ;;
      esac
    done
    rm -f "$PIDFILE" "$RUN_DIR/beacon.pid" "$RUN_DIR/wstunnel.pid"
  }

  do_reload() {
    if is_running; then
      pid="$(cat "$PIDFILE")"
      kill -HUP "$pid"
      if [ -f /data/hitohira/etc/beacon.conf ] && [ -x /data/hitohira/current/bin/hitohira-beacon ]; then
        nsenter -t "$pid" -m -- chroot "$NS_BASE/merged" /nix/var/nix/profiles/hitohira/bin/hitohira-beacon </dev/null >> "$RUN_DIR/beacon.log" 2>&1 &
      fi
    else
      do_start
    fi
  }

  case "''${1:-status}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; do_start ;;
    reload)  do_reload ;;
    status)
      if is_running; then
        echo "running (pid $(cat "$PIDFILE"), profile $(readlink "$HOST_PROFILE" 2>/dev/null || echo none))"
      else
        echo "stopped"
        exit 1
      fi
      ;;
    *)
      echo "usage: hitohira-ctl {start|stop|restart|reload|status}" >&2
      exit 2
      ;;
  esac
  EOF
  sed -i 's/^  //' $out/bin/hitohira-ctl
  chmod 0755 $out/bin/hitohira-ctl

  cat > $out/bin/hitohira <<'EOF'
  #!/system/bin/sh
  set -eu

  CTL="/data/hitohira/current/bin/hitohira-ctl"
  PIDFILE="/data/hitohira/run/ns.pid"
  MERGED="/data/local/tmp/.hitohira_ns/merged"
  P="/nix/var/nix/profiles/hitohira"

  case "''${1:-}" in
    --start)   exec "$CTL" start ;;
    --stop)    exec "$CTL" stop ;;
    --restart) exec "$CTL" restart ;;
    --reload)  exec "$CTL" reload ;;
    --status)  exec "$CTL" status ;;
  esac

  if [ -d /nix/store ] && [ -x "$P/bin/nu" ]; then
    if [ "$#" -eq 0 ]; then
      exec "$P/bin/nu" -l
    else
      exec "$@"
    fi
  fi

  "$CTL" start
  nspid="$(cat "$PIDFILE")"

  term_val="''${TERM:-}"
  if [ -z "$term_val" ] || [ "$term_val" = "dumb" ]; then
    term_val="xterm-256color"
  fi

  if [ "$#" -eq 0 ]; then
    exec env -i \
      HOME=/home/kyaru \
      USER=kyaru \
      LOGNAME=kyaru \
      TERM="$term_val" \
      LANG=C.UTF-8 \
      TZ=Asia/Shanghai \
      SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt \
      NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt \
      PATH="/home/kyaru/.nix-profile/bin:/nix/var/nix/profiles/per-user/kyaru/profile/bin:$P/bin:$P/sbin:/home/kyaru/.local/bin:/system/bin:/data/adb/ksu/bin" \
      nsenter -t "$nspid" -m -- chroot "$MERGED" "$P/bin/bash" -c "cd /home/kyaru && exec '$P/bin/nu' -l"
  fi

  exec env -i \
    HOME=/home/kyaru \
    USER=kyaru \
    LOGNAME=kyaru \
    TERM="$term_val" \
    LANG=C.UTF-8 \
    TZ=Asia/Shanghai \
    SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt \
    NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt \
    PATH="/home/kyaru/.nix-profile/bin:/nix/var/nix/profiles/per-user/kyaru/profile/bin:$P/bin:$P/sbin:/home/kyaru/.local/bin:/system/bin:/data/adb/ksu/bin" \
    nsenter -t "$nspid" -m -- chroot "$MERGED" "$@"
  EOF
  sed -i 's/^  //' $out/bin/hitohira
  chmod 0755 $out/bin/hitohira

  cat > $out/bin/hitohira-beacon <<'EOF'
  #!/nix/var/nix/profiles/hitohira/bin/bash
  set -euo pipefail

  P="/nix/var/nix/profiles/hitohira"
  export PATH="$P/bin:$P/sbin:/system/bin"
  export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt

  CONF="/data/hitohira/etc/beacon.conf"
  RUN_DIR="/data/hitohira/run"
  PIDFILE="$RUN_DIR/beacon.pid"
  WST_PIDFILE="$RUN_DIR/wstunnel.pid"
  FIFO="$RUN_DIR/.beacon.fifo"

  [ -f "$CONF" ] || exit 0
  # shellcheck disable=SC1090
  . "$CONF"
  : "''${BEACON_DOMAIN:?}" "''${BEACON_SECRET:?}"
  BEACON_HOST_TAG="''${BEACON_HOST_TAG:-pixel10}"
  BEACON_REMOTE_PORT="''${BEACON_REMOTE_PORT:-18023}"
  PING_INTERVAL="''${PING_INTERVAL:-180}"
  ACTIVE_PING_INTERVAL="''${ACTIVE_PING_INTERVAL:-30}"

  mkdir -p "$RUN_DIR"
  if [ -f "$PIDFILE" ]; then
    old="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$old" ] && [ "$old" != "$$" ] &&
       grep -zFxq "$P/bin/hitohira-beacon" "/proc/$old/cmdline" 2>/dev/null; then
      kill "$old" 2>/dev/null || true
      # Bash may defer TERM while waiting for curl. Do not replace shared state
      # until its EXIT cleanup has finished (otherwise it can unlink our PID).
      for ((i=0; i<100; i++)); do
        kill -0 "$old" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$old" 2>/dev/null && kill -9 "$old" 2>/dev/null || true
    fi
  fi
  echo "$$" > "$PIDFILE"

  stop_tunnel() {
    if [ -f "$WST_PIDFILE" ]; then
      wp="$(cat "$WST_PIDFILE" 2>/dev/null || true)"
      if [ -n "$wp" ] && [ -d "/proc/$wp" ]; then
        kill "$wp" 2>/dev/null || true
      fi
      rm -f "$WST_PIDFILE"
    fi
  }
  cleanup() {
    if [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$$" ]; then
      stop_tunnel
      rm -f "$PIDFILE"
    fi
  }
  trap cleanup EXIT
  trap 'exit 0' INT TERM
  stop_tunnel

  rm -f "$FIFO"
  mkfifo -m 0600 "$FIFO"
  exec 9<>"$FIFO"

  boottime_sec() {
    local raw
    read -r raw _ < /proc/uptime
    echo "''${raw%%.*}"
  }

  tunnel_alive() {
    [ -f "$WST_PIDFILE" ] || return 1
    local wp
    wp="$(cat "$WST_PIDFILE" 2>/dev/null || true)"
    [ -n "$wp" ] && [ -d "/proc/$wp" ]
  }

  list_candidates() {
    # Prefer ordinary routing without a VPN; retain physical-interface escape paths.
    local rules vpn=0
    rules="$(ip rule show 2>/dev/null)"
    if printf '%s\n' "$rules" | grep -Eq 'fwmark (0x)?0/0x20000.*iif lo'; then
      vpn=1
    else
      echo "default 0x0"
    fi
    printf '%s\n' "$rules" | awk '
      /oif / && /uidrange 0-0/ {
        dev=""; tbl="";
        for (i=1; i<=NF; i++) {
          if ($i == "oif") dev=$(i+1);
          if ($i == "lookup") tbl=$(i+1);
        }
        if (dev ~ /^(wlan|rmnet|eth)/ && tbl != "") dev_for_tbl[tbl] = dev;
      }
      /fwmark / && /iif lo/ && !/oif / {
        mk=""; tbl="";
        for (i=1; i<=NF; i++) {
          if ($i == "fwmark") { split($(i+1), a, "/"); mk=a[1]; }
          if ($i == "lookup") tbl=$(i+1);
        }
        if (tbl in dev_for_tbl && mk != "") {
          d = dev_for_tbl[tbl];
          prio = (d ~ /^wlan/) ? 1 : 2;
          print prio, d, mk;
        }
      }
    ' | sort -n | awk '!seen[$2]++ {print $2, $3}'
    [ "$vpn" = 0 ] || echo "default 0x0"
  }

  cached_location() {
    # Read existing provider caches as AID_SHELL (2000) so ColorOS does not redact coordinates.
    timeout 4 /system/bin/su 2000 -c '/system/bin/dumpsys location' 2>/dev/null | awk -v now="$(boottime_sec)" '
      function seconds(t, a,n,i,total) {
        total=0;
        while (match(t, /[0-9]+(ms|d|h|m|s)/)) {
          n=substr(t,RSTART,RLENGTH); t=substr(t,RSTART+RLENGTH);
          if (n ~ /ms$/) total+=n/1000;
          else if (n ~ /d$/) total+=n*86400;
          else if (n ~ /h$/) total+=n*3600;
          else if (n ~ /m$/) total+=n*60;
          else total+=n;
        }
        return total;
      }
      /Location\[[a-zA-Z0-9_]+ -?[0-9.]+,-?[0-9.]+/ {
        line=$0;
        sub(/^.*Location\[/, "", line);
        n=split(line, f, " ");
        provider=f[1]; split(f[2], coord, ","); et=""; acc="";
        for(i=3;i<=n;i++) {
          if (f[i] ~ /^et=/) {et=f[i]; sub(/^et=/,"",et); sub(/\].*/,"",et)}
          if (f[i] ~ /^hAcc=/) {acc=f[i]; sub(/^hAcc=/,"",acc)}
        }
        stamp=seconds(et);
        if (et != "" && coord[1] !~ /\*/ && stamp > latest && stamp <= now+2) {
          latest=stamp; lat=coord[1]; lon=coord[2]; p=provider; a=acc; e=et;
        }
      }
      END {if(lat != "") printf "%s %s %s %s %s %.0f\n",lat,lon,p,a,e,(now>latest?now-latest:0)}
    ' || true
  }

  wst_deadline=0
  last_ping=-99999

  check_once() {
    local bat="" chg="" out body cf_ip want ttl now mark_dec ws_target
    local lat="" lon="" provider="" accuracy="" elapsed="" loc_age=""
    read -r lat lon provider accuracy elapsed loc_age < <(cached_location) || true
    bat="$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || true)"
    chg="$(cat /sys/class/power_supply/battery/status 2>/dev/null || true)"

    while read -r dev mark_hex; do
      [ -n "$dev" ] || continue
      local iface_args=()
      if [ "$dev" != "default" ]; then
        iface_args=(--interface "$dev")
      fi
      if out="$(curl "''${iface_args[@]}" -fsSm 6 -w '\n%{remote_ip}' --get \
        --data-urlencode "bat=$bat" --data-urlencode "chg=$chg" \
        --data-urlencode "dev=$dev" --data-urlencode "host=$BEACON_HOST_TAG" \
        --data-urlencode "lat=$lat" --data-urlencode "lon=$lon" \
        --data-urlencode "provider=$provider" --data-urlencode "accuracy=$accuracy" \
        --data-urlencode "elapsed=$elapsed" --data-urlencode "loc_age=$loc_age" \
        --data-urlencode "boot_id=$(cat /proc/sys/kernel/random/boot_id)" \
        "https://''${BEACON_DOMAIN}/''${BEACON_SECRET}/ping" 2>/dev/null)"; then
        cf_ip="''${out##*$'\n'}"
        body="''${out%$'\n'*}"
        want="$(printf '%s' "$body" | jq -r '.connect // 0' 2>/dev/null || echo 0)"
        ttl="$(printf '%s' "$body" | jq -r '.ttl // 600' 2>/dev/null || echo 600)"
        now="$(boottime_sec)"
        if [ "$want" = "1" ]; then
          wst_deadline=$(( now + ttl ))
          if ! tunnel_alive; then
            case "$cf_ip" in
              *:*) ws_target="[''${cf_ip}]:443" ;;
              *)   ws_target="''${cf_ip}:443" ;;
            esac
            local mark_args=()
            mark_dec=$(( (mark_hex) | 0x20000 ))
            if [ $(( mark_hex )) -gt 0 ]; then
              mark_args=(--socket-so-mark "$mark_dec")
            fi
            wstunnel client --no-color \
              --tls-verify-certificate \
              --tls-sni-override "$BEACON_DOMAIN" \
              -H "Host: $BEACON_DOMAIN" \
              "''${mark_args[@]}" \
              -P "$BEACON_SECRET" \
              -R "tcp://127.0.0.1:''${BEACON_REMOTE_PORT}:127.0.0.1:8023" \
              "wss://''${ws_target}" </dev/null >> "$RUN_DIR/wstunnel.log" 2>&1 &
            echo "$!" > "$WST_PIDFILE"
          fi
        else
          wst_deadline=0
          stop_tunnel
        fi
        return 0
      fi
    done < <(list_candidates)
    return 1
  }

  while true; do
    now="$(boottime_sec)"
    if tunnel_alive; then
      if [ "$now" -ge "$wst_deadline" ]; then
        stop_tunnel
        wst_deadline=0
      elif [ $(( now - last_ping )) -ge "$ACTIVE_PING_INTERVAL" ]; then
        last_ping="$now"
        check_once || true
      fi
    else
      if [ $(( now - last_ping )) -ge "$PING_INTERVAL" ]; then
        last_ping="$now"
        check_once || true
      fi
    fi
    read -r -t 5 -u 9 || true
  done
  EOF
  sed -i 's/^  //' $out/bin/hitohira-beacon
  chmod 0755 $out/bin/hitohira-beacon

  cat > $out/bin/hitohira-activate <<EOF
  #!/system/bin/sh
  set -eu

  SELF_STORE="$out"
  HOST_STORE="/data$out"
  PROFILES_DIR="/data/nix/var/nix/profiles"

  mkdir -p "\$PROFILES_DIR" /data/hitohira /data/adb/modules/hitohira /data/adb/ksu/bin

  if [ -L "\$PROFILES_DIR/hitohira" ]; then
    ln -sfn "\$(readlink "\$PROFILES_DIR/hitohira")" "\$PROFILES_DIR/hitohira-prev"
  fi
  ln -sfn "\$SELF_STORE" "\$PROFILES_DIR/hitohira"
  ln -sfn "\$HOST_STORE" /data/hitohira/current
  cp -f "\$HOST_STORE/share/sukisu-module/module.prop" /data/adb/modules/hitohira/module.prop
  cp -f "\$HOST_STORE/share/sukisu-module/service.sh" /data/adb/modules/hitohira/service.sh
  chmod 0755 /data/adb/modules/hitohira/service.sh
  : > /data/adb/modules/hitohira/skip_mount
  ln -sfn /data/hitohira/current/bin/hitohira /data/adb/ksu/bin/hitohira

  TERMUX_BIN="/data/data/com.termux/files/usr/bin"
  if [ -d "\$TERMUX_BIN" ]; then
    t_uid="\$(stat -c %u "\$TERMUX_BIN")"
    t_gid="\$(stat -c %g "\$TERMUX_BIN")"
    cp -f "\$HOST_STORE/share/sukisu-module/termux-hitohira" "\$TERMUX_BIN/hitohira"
    chown "\$t_uid:\$t_gid" "\$TERMUX_BIN/hitohira"
    chmod 0755 "\$TERMUX_BIN/hitohira"
  fi

  if [ ! -d /nix/store ]; then
    /data/hitohira/current/bin/hitohira-ctl reload
  elif [ -f /data/hitohira/run/ns.pid ]; then
    kill -HUP "\$(cat /data/hitohira/run/ns.pid)" 2>/dev/null || true
    if [ -f /data/hitohira/etc/beacon.conf ] && [ -x /nix/var/nix/profiles/hitohira/bin/hitohira-beacon ]; then
      /nix/var/nix/profiles/hitohira/bin/hitohira-beacon </dev/null >> /data/hitohira/run/beacon.log 2>&1 &
    fi
  fi
  echo "hitohira activated -> \$SELF_STORE"
  EOF
  sed -i 's/^  //' $out/bin/hitohira-activate
  chmod 0755 $out/bin/hitohira-activate

  cat > $out/share/sukisu-module/module.prop <<'EOF'
  id=hitohira
  name=Hitohira (Nix Runtime)
  version=v0.1.0
  versionCode=1
  author=Kiruya Momochi
  description=Isolated mount-namespace Nix runtime in /data/nix
  EOF
  sed -i 's/^  //' $out/share/sukisu-module/module.prop

  : > $out/share/sukisu-module/skip_mount

  cat > $out/share/sukisu-module/service.sh <<'EOF'
  #!/system/bin/sh
  while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
  done
  sleep 3
  mkdir -p /data/adb/ksu/bin
  ln -sfn /data/hitohira/current/bin/hitohira /data/adb/ksu/bin/hitohira
  exec /data/hitohira/current/bin/hitohira-ctl start
  EOF
  sed -i 's/^  //' $out/share/sukisu-module/service.sh
  chmod 0755 $out/share/sukisu-module/service.sh

  cat > $out/share/sukisu-module/termux-hitohira <<'EOF'
  #!/data/data/com.termux/files/usr/bin/bash
  if [ "$#" -eq 0 ]; then
    exec /system/bin/su -c /data/adb/ksu/bin/hitohira
  fi
  exec /system/bin/su -c "/data/adb/ksu/bin/hitohira ''${@@Q}"
  EOF
  sed -i 's/^  //' $out/share/sukisu-module/termux-hitohira
  chmod 0755 $out/share/sukisu-module/termux-hitohira
''
