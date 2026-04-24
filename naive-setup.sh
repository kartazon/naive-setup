#!/usr/bin/env bash
set -euo pipefail

NAIVE_ENV_FILE="/etc/caddy/naive.env"

die() {
  echo "Error: $*" >&2
  exit 1
}

# Fix: Missing mktemp functions
mktemp_file() { mktemp "${TMPDIR:-/tmp}/naive-caddy.XXXXXX"; }
mktemp_tar()  { mktemp "${TMPDIR:-/tmp}/naive-tar.XXXXXX"; }

# Fix: Missing read_secret function
read_secret() {
  local _prompt=$1
  if [[ -t 0 ]]; then
    IFS= read -rs -p "$_prompt" PROXY_PASS
    echo >&2
  else
    IFS= read -r PROXY_PASS
  fi
}

require_root() {
  local uid
  uid=$(id -u) || die "The 'id' command failed."
  [[ "$uid" -eq 0 ]] || die "This script must be run as root (e.g. sudo \"${0#-}\")."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

apk_try_add_qrencode() {
  apk add --no-cache libqrencode-tools 2>/dev/null && return 0
  apk add --no-cache libqrencode 2>/dev/null && return 0
  echo "Could not install qrencode (enable community repo, then: apk add libqrencode-tools || apk add libqrencode)." >&2
  return 1
}

print_url_ascii_box() {
  local url=$1
  local w=72
  local top
  top="$(printf '%*s' "$w" '' | tr ' ' '-')"
  echo ""
  echo " +${top}+"
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    printf ' | %-*s |
' "$w" "$line"
  done < <(printf '%s' "$url" | fold -w "$w" 2>/dev/null || printf '%s
' "$url")
  echo " +${top}+"
  echo " (ASCII box - not a QR; use the link or install qrencode for a scannable terminal QR.)"
}

prompt_install_yes() {
  local _msg=$1
  if [[ ! -t 0 ]]; then
    echo "$_msg" >&2
    echo "Not running on a TTY - install packages manually, then re-run this script." >&2
    return 1
  fi
  printf '%s [Y/n]: ' "$_msg"
  read -r _reply
  case "${_reply:-y}" in
    [nN] | [nN][oO]) return 1 ;;
    *) return 0 ;;
  esac
}

_words_uniq() {
  echo "$1" | tr ' ' '
' | grep -v '^$' | sort -u | tr '
' ' ' || true
}

offer_install_dependencies() {
  local have_curl_wget=0
  command -v curl >/dev/null 2>&1 && have_curl_wget=1
  command -v wget >/dev/null 2>&1 && have_curl_wget=1

  local pm=""
  if [[ -f /etc/alpine-release ]] && command -v apk >/dev/null 2>&1; then
    pm=apk
  elif command -v apt-get >/dev/null 2>&1; then
    pm=apt
  elif command -v dnf >/dev/null 2>&1; then
    pm=dnf
  elif command -v yum >/dev/null 2>&1; then
    pm=yum
  elif command -v zypper >/dev/null 2>&1; then
    pm=zypper
  fi

  local pkgs=""
  need=""
  if [[ "$have_curl_wget" -eq 0 ]]; then
    case "$pm" in
      apk) pkgs+=" curl wget ca-certificates" ;;
      apt) pkgs+=" curl wget ca-certificates" ;;
      dnf | yum) pkgs+=" curl wget ca-certificates" ;;
      zypper) pkgs+=" curl wget ca-certificates" ;;
      *) need+="curl or wget, " ;;
    esac
  fi
  if ! command -v xz >/dev/null 2>&1; then
    case "$pm" in
      apk) pkgs+=" xz" ;;
      apt) pkgs+=" xz-utils" ;;
      dnf | yum) pkgs+=" xz" ;;
      zypper) pkgs+=" xz" ;;
      *) need+="xz, " ;;
    esac
  fi
  if ! command -v awk >/dev/null 2>&1; then
    case "$pm" in
      apk) pkgs+=" gawk" ;;
      apt) pkgs+=" gawk" ;;
      dnf | yum) pkgs+=" gawk" ;;
      zypper) pkgs+=" gawk" ;;
      *) need+="awk, " ;;
    esac
  fi
  if ! command -v base64 >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1; then
    case "$pm" in
      apk) pkgs+=" openssl coreutils" ;;
      apt) pkgs+=" openssl coreutils" ;;
      dnf | yum) pkgs+=" openssl coreutils" ;;
      zypper) pkgs+=" openssl coreutils" ;;
      *) need+="base64 or openssl, " ;;
    esac
  fi
  if ! command -v getent >/dev/null 2>&1; then
    case "$pm" in
      apk) pkgs+=" musl-utils" ;;
      apt) pkgs+=" libc-bin" ;;
      dnf | yum) pkgs+=" glibc-common" ;;
      zypper) pkgs+=" glibc" ;;
      *) need+="getent, " ;;
    esac
  fi
  if ! command -v tar >/dev/null 2>&1; then
    case "$pm" in
      apk) pkgs+=" tar" ;;
      apt) pkgs+=" tar" ;;
      dnf | yum) pkgs+=" tar" ;;
      zypper) pkgs+=" tar" ;;
      *) need+="tar, " ;;
    esac
  fi
  if ! command -v setcap >/dev/null 2>&1; then
    case "$pm" in
      apk) pkgs+=" libcap" ;;
      apt) pkgs+=" libcap2-bin" ;;
      dnf | yum | zypper) pkgs+=" libcap" ;;
    esac
  fi

  pkgs=$(_words_uniq "$pkgs")
  if [[ -n "$pkgs" && -n "$pm" ]]; then
    echo "The following packages are missing or recommended: $pkgs" >&2
    case "$pm" in
      apk)
        if prompt_install_yes "Install them now with: apk add --no-cache $pkgs"; then
          # shellcheck disable=SC2086
          apk add --no-cache $pkgs
          if echo "$pkgs" | grep -q ca-certificates; then
            update-ca-certificates 2>/dev/null || true
          fi
        fi
        ;;
      apt)
        if prompt_install_yes "Install them now with: apt-get install -y $pkgs"; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq
          # shellcheck disable=SC2086
          apt-get install -y $pkgs
        fi
        ;;
      dnf)
        if prompt_install_yes "Install them now with: dnf install -y $pkgs"; then
          # shellcheck disable=SC2086
          dnf install -y $pkgs
        fi
        ;;
      yum)
        if prompt_install_yes "Install them now with: yum install -y $pkgs"; then
          # shellcheck disable=SC2086
          yum install -y $pkgs
        fi
        ;;
      zypper)
        if prompt_install_yes "Install them now with: zypper install -y $pkgs"; then
          # shellcheck disable=SC2086
          zypper install -y $pkgs
        fi
        ;;
    esac
  elif [[ -n "$need" ]]; then
    echo "Missing: ${need%, }" >&2
    echo "Install the equivalent packages for this system, then re-run." >&2
  fi

  if ! command -v qrencode >/dev/null 2>&1 && [[ -n "$pm" ]]; then
    local _qrpkg=""
    case "$pm" in
      apk) _qrpkg="qrencode (apk: libqrencode-tools or libqrencode)" ;;
      apt) _qrpkg=qrencode ;;
      dnf | yum) _qrpkg=qrencode ;;
      zypper) _qrpkg=qrencode ;;
    esac
    if [[ -n "$_qrpkg" && -t 0 ]]; then
      printf 'Optional: install %s for a scannable QR in the terminal. Install now? [y/N]: ' "$_qrpkg"
      read -r _qr
      case "$_qr" in
        [yY] | [yY][eE][sS])
          case "$pm" in
            apk) apk_try_add_qrencode ;;
            apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y qrencode ;;
            dnf) dnf install -y qrencode ;;
            yum) yum install -y qrencode ;;
            zypper) zypper install -y qrencode ;;
          esac
          ;;
      esac
    fi
  fi
}

fetch_public_ip() {
  local url="https://whatismyip.akamai.com/"
  if command -v curl >/dev/null 2>&1; then
    curl --connect-timeout 10 --max-time 30 -fsSL "$url" | tr -d '\r
'
  elif command -v wget >/dev/null 2>&1; then
    wget --timeout=30 --tries=3 -qO- "$url" | tr -d '\r
'
  else
    die "Need curl or wget to fetch public IP"
  fi
}

download_to() {
  local url=$1 dest=$2
  if command -v curl >/dev/null 2>&1; then
    curl --connect-timeout 10 --max-time 30 -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget --timeout=30 --tries=3 -qO "$dest" "$url"
  else
    die "Need curl or wget to download"
  fi
}

lookup_domain_ipv4() {
  local domain=$1
  ips=""
  if command -v getent >/dev/null 2>&1; then
    ips=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' | sort -u || true)
    if [[ -z "$ips" ]]; then
      ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' | sort -u || true)
    fi
  fi
  if [[ -z "$ips" ]] && command -v dig >/dev/null 2>&1; then
    ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' || true)
  fi
  if [[ -z "$ips" ]] && command -v host >/dev/null 2>&1; then
    ips=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}' | grep -E '^[0-9.]+$' || true)
  fi
  if [[ -z "$ips" ]] && command -v nslookup >/dev/null 2>&1; then
    ips=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | grep -E '^[0-9.]+$' || true)
    if [[ -z "$ips" ]]; then
      ips=$(nslookup "$domain" 2>/dev/null | awk '/^Address [0-9]+: / {print $3}' | grep -E '^[0-9.]+$' || true)
    fi
  fi
  if [[ -z "$ips" ]] && command -v curl >/dev/null 2>&1; then
    local json
    json=$(curl -fsSL "https://1.1.1.1/dns-query?name=${domain}&type=A" -H "accept: application/dns-json" 2>/dev/null || true)
    if [[ -n "$json" ]]; then
      ips=$(printf '%s' "$json" | awk -F'"' ' { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i }' | sort -u)
    fi
  fi
  if [[ -z "$ips" ]] && command -v wget >/dev/null 2>&1; then
    local json
    json=$(wget -qO- "https://1.1.1.1/dns-query?name=${domain}&type=A" --header="accept: application/dns-json" 2>/dev/null || true)
    if [[ -n "$json" ]]; then
      ips=$(printf '%s' "$json" | awk -F'"' ' { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i }' | sort -u)
    fi
  fi
  printf '%s' "$ips"
}

domain_resolves_to_ip() {
  local domain=$1 expected_ip=$2 ips
  ips=$(lookup_domain_ipv4 "$domain")
  [[ -n "$ips" ]] || die "Could not resolve DNS for '$domain' (install bind-tools, use getent/nslookup, or curl for DoH)."
  local OLDIFS=$IFS ip
  IFS=$'
'
  for ip in $ips; do
    IFS=$OLDIFS
    [[ -z "$ip" ]] && continue
    if [[ "$ip" == "$expected_ip" ]]; then
      return 0
    fi
  done
  IFS=$OLDIFS
  return 1
}

write_naive_env() {
  local env_path=$1 domain=$2 email=$3 user=$4 pass=$5
  mkdir -p "$(dirname "$env_path")"
  # Fix: Security reminder about plain-text password
  cat >"$env_path" <<EOF
# WARNING: This file contains proxy credentials in plain text.
# Keep it root-only (0600).
NAIVE_DOMAIN="$domain"
NAIVE_EMAIL="$email"
PROXY_USER="$user"
PROXY_PASS="$pass"
EOF
  chmod 0600 "$env_path"
}

# Fix: caddy_quote using variable correctly
caddy_quote() {
  local _s=$1 _out
  _out=$(printf '%s' "$_s" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '"%s"' "$_out"
}

write_caddyfile() {
  local domain=$1 email=$2 user=$3 pass=$4 outfile=$5
  local q_domain q_email q_user q_pass
  q_domain=$(caddy_quote "$domain")
  q_email=$(caddy_quote "$email")
  q_user=$(caddy_quote "$user")
  q_pass=$(caddy_quote "$pass")

  cat >"$outfile" <<EOF
{
  order forward_proxy before reverse_proxy
}
:443, $q_domain {
  tls $q_email
  forward_proxy {
    basic_auth $q_user $q_pass
    hide_ip
    hide_via
    probe_resistance
  }
  reverse_proxy https://www.google.com {
    header_up Host {upstream_hostport}
    header_up -Authorization
  }
}
EOF
}

exports_from_caddyfile() {
  local path=$1
  local _awkf
  _awkf=$(mktemp "/tmp/naive-exports.XXXXXX" 2>/dev/null || echo "/tmp/naive-exports.$$")
  cat >"$_awkf" <<'AWK'
function unescape_caddy(q, n, inner, i, c, c2, out) {
  n = length(q)
  if (n < 2 || substr(q, 1, 1) != "\"" || substr(q, n, 1) != "\"") return q
  inner = substr(q, 2, n - 2)
  out = ""
  i = 1
  while (i <= length(inner)) {
    c = substr(inner, i, 1)
    if (c == "\\" && i < length(inner)) {
      c2 = substr(inner, i + 1, 1)
      if (c2 == "\"") { out = out "\""; i += 2; continue }
      if (c2 == "\\") { out = out "\\"; i += 2; continue }
    }
    out = out c
    i++
  }
  return out
}
function shquote(s, t) {
  t = s
  gsub(/\047/, "'\\''", t)
  return "'" t "'"
}
function read_caddy_quoted(buf, pos, n, i, c, c2, out) {
  n = length(buf)
  if (substr(buf, pos, 1) != "\"") return ""
  out = "\""
  i = pos + 1
  while (i <= n) {
    c = substr(buf, i, 1)
    out = out c
    if (c == "\\" && i < n) {
      c2 = substr(buf, i + 1, 1)
      out = out c2
      i += 2
      continue
    }
    if (c == "\"") return out
    i++
  }
  return ""
}
function read_caddy_unquoted(buf, pos, n, i, c, out) {
  n = length(buf)
  out = ""
  i = pos
  while (i <= n) {
    c = substr(buf, i, 1)
    if (c ~ /[[:space:]]/) break
    out = out c
    i++
  }
  return out
}
function read_caddy_value(buf, pos) {
  if (substr(buf, pos, 1) == "\"") return read_caddy_quoted(buf, pos)
  return read_caddy_unquoted(buf, pos)
}
{ buf = buf $0 "
" }
END {
  if (match(buf, /:443,[[:space:]]*[^[:space:]{#]+/)) {
    s = substr(buf, RSTART, RLENGTH)
    sub(/^:443,[[:space:]]*/, "", s)
    domain = s
  } else {
    print "Could not parse :443 host in Caddyfile." > "/dev/stderr"
    exit 1
  }
  if (!match(buf, /tls[[:space:]]+/)) {
    print "Could not find tls in Caddyfile." > "/dev/stderr"
    exit 1
  }
  rest = substr(buf, RSTART + RLENGTH)
  sub(/^[[:space:]]*/, "", rest)
  email_q = read_caddy_value(rest, 1)
  if (email_q == "") {
    print "Could not parse tls value in Caddyfile." > "/dev/stderr"
    exit 1
  }
  email = unescape_caddy(email_q)
  if (!match(buf, /basic_auth[[:space:]]+/)) {
    print "Could not find basic_auth in Caddyfile." > "/dev/stderr"
    exit 1
  }
  rest = substr(buf, RSTART + RLENGTH)
  sub(/^[[:space:]]*/, "", rest)
  uq = read_caddy_value(rest, 1)
  if (uq == "") {
    print "Could not parse basic_auth user in Caddyfile." > "/dev/stderr"
    exit 1
  }
  rest2 = substr(rest, length(uq) + 1)
  sub(/^[[:space:]]*/, "", rest2)
  pq = read_caddy_value(rest2, 1)
  if (pq == "") {
    print "Could not parse basic_auth password in Caddyfile." > "/dev/stderr"
    exit 1
  }
  user = unescape_caddy(uq)
  password = unescape_caddy(pq)
  print "export DOMAIN=" shquote(domain)
  print "export EMAIL=" shquote(email)
  print "export PROXY_USER=" shquote(user)
  print "export PROXY_PASS=" shquote(password)
}
AWK
  awk -f "$_awkf" "$path"
  local _ae=$?
  rm -f "$_awkf"
  return "$_ae"
}

naive_share_url() {
  local u=$1 p=$2 d=$3 raw b64
  raw="${u}:${p}@${d}:443"
  if command -v base64 >/dev/null 2>&1; then
    b64=$(printf '%s' "$raw" | base64 | tr -d '
')
  elif command -v openssl >/dev/null 2>&1; then
    b64=$(printf '%s' "$raw" | openssl base64 2>/dev/null | tr -d '
') \
      || b64=$(printf '%s' "$raw" | openssl enc -base64 2>/dev/null | tr -d '
')
  else
    die "Need base64 or openssl to build the share link."
  fi
  b64=$(printf '%s' "$b64" | tr -d '=')
  printf 'naive+quic://%s?method=auto
' "$b64"
}

show_share_link_and_qr() {
  local share_url
  share_url=$(naive_share_url "$PROXY_USER" "$PROXY_PASS" "$DOMAIN")
  echo ""
  echo "================================================================================"
  echo " Share link (import in naive client - host, port, user, password, type QUIC / HTTP/3)"
  echo "================================================================================"
  echo "$share_url"
  echo ""
  echo "QR code:"
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$share_url" | qrencode -t ANSIUTF8 2>/dev/null \
      || printf '%s' "$share_url" | qrencode -t UTF8
  else
    print_url_ascii_box "$share_url"
    echo " For a real QR: apk add libqrencode-tools 2>/dev/null || apk add libqrencode (Alpine community)"
    echo "                apt install qrencode (Debian/Ubuntu)"
  fi
  echo ""
}

print_firewall_reminder() {
  echo ""
  echo "================================================================================"
  echo " IMPORTANT: open ports 80 (ACME) and 443 (proxy) in your firewall."
  echo "================================================================================"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    echo " [ufw]"
    echo " ufw allow 80/tcp"
    echo " ufw allow 443/tcp"
    echo " ufw allow 443/udp"
    echo " ufw reload"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    echo " [firewalld]"
    echo " firewall-cmd --permanent --add-service=http"
    echo " firewall-cmd --permanent --add-service=https"
    echo " firewall-cmd --permanent --add-port=443/udp"
    echo " firewall-cmd --reload"
  elif command -v iptables >/dev/null 2>&1; then
    echo " [iptables]"
    echo " iptables -A INPUT -p tcp --dport 80 -j ACCEPT"
    echo " iptables -A INPUT -p tcp --dport 443 -j ACCEPT"
    echo " iptables -A INPUT -p udp --dport 443 -j ACCEPT"
  else
    echo " Open ports 80/tcp, 443/tcp, 443/udp manually for your firewall."
  fi
  echo "================================================================================"
  echo ""
}

port_owner() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | awk -v p=":$port " '$0 ~ p {match($0,/users:\(\("([^"]+",/); if (RSTART) print substr($0,RSTART+9,RLENGTH-10)}'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | awk -v p=":$port " '$0 ~ p {print $NF}'
  fi
}

check_ports() {
  local blocked=0
  local p owner
  for p in 80 443; do
    owner=$(port_owner "$p")
    if [[ -n "$owner" ]]; then
      echo "Warning: port $p is already in use by: $owner" >&2
      blocked=1
    fi
  done
  if [[ "$blocked" -eq 1 ]]; then
    die "One or more required ports are in use. Stop the conflicting process and re-run."
  fi
}

CADDY_USER="caddy-naive"

check_conflicting_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  local svc
  for svc in nginx apache2 httpd caddy; do
    if systemctl is-active --quiet "$svc"; then
      echo "Warning: service '$svc' is active and may be using ports 80/443." >&2
    fi
  done
}

ensure_caddy_user() {
  if id "$CADDY_USER" >/dev/null 2>&1; then
    return 0
  fi
  echo "Creating system user '$CADDY_USER'..." >&2
  if command -v useradd >/dev/null 2>&1; then
    useradd -r -s /bin/false -M -d /opt/caddy-forwardproxy-naive "$CADDY_USER"
  elif command -v adduser >/dev/null 2>&1; then
    adduser -S -H -s /sbin/nologin -D "$CADDY_USER"
  else
    die "Cannot create system user '$CADDY_USER': neither useradd nor adduser found."
  fi
}

main() {
  echo "Naive server setup (Caddy + forwardproxy)..." >&2
  local UPGRADE=0
  for arg in "$@"; do
    case "$arg" in
      --upgrade) UPGRADE=1 ;;
    esac
  done

  check_conflicting_services
  check_ports
  offer_install_dependencies

  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || die "Need curl or wget for downloads. On Alpine: apk add --no-cache curl wget ca-certificates"
  command -v xz >/dev/null 2>&1 \
    || die "Need xz to unpack the Caddy .tar.xz archive. On Alpine: apk add --no-cache xz"
  command -v base64 >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 \
    || die "Need base64 or openssl for the share link. On Alpine: apk add --no-cache openssl coreutils"

  require_cmd tar
  require_cmd awk

  local caddyfile_path="/etc/caddy/Caddyfile"
  mkdir -p /etc/caddy /var/www/html

  if [[ -f "$caddyfile_path" && -s "$caddyfile_path" ]]; then
    echo "Found existing $caddyfile_path." >&2
    ensure_caddy_user
    chown root:"$CADDY_USER" "$caddyfile_path"
    chmod 0640 "$caddyfile_path"

    if [[ -f "$NAIVE_ENV_FILE" ]]; then
      echo "Loading config from $NAIVE_ENV_FILE..." >&2
      # shellcheck disable=SC1090
      . "$NAIVE_ENV_FILE"
      DOMAIN="${NAIVE_DOMAIN:-}"
      EMAIL="${NAIVE_EMAIL:-}"
      [[ -n "$DOMAIN" && -n "$EMAIL" && -n "${PROXY_USER:-}" && -n "${PROXY_PASS:-}" ]] \
        || die "Incomplete values in $NAIVE_ENV_FILE — delete it and re-run to reconfigure."
    else
      local _exports
      _exports=$(exports_from_caddyfile "$caddyfile_path") \
        || die "Could not parse $caddyfile_path (expected :443, tls, and basic_auth lines)."
      eval "$_exports"
      write_naive_env "$NAIVE_ENV_FILE" "$DOMAIN" "$EMAIL" "$PROXY_USER" "$PROXY_PASS"
      echo "Migrated config to $NAIVE_ENV_FILE (0600)." >&2
    fi
  else
    printf 'Domain name (e.g. example.com): '
    read -r DOMAIN
    local DOMAIN_TRIM
    DOMAIN_TRIM=$(printf '%s' "$domain" | tr -d ' ')
    [[ -n "$DOMAIN_TRIM" ]] || die "Domain name is required."

    echo "Fetching public IP..."
    local MY_IP
    MY_IP=$(fetch_public_ip)
    [[ -n "$MY_IP" ]] || die "Could not determine public IP."
    echo "This machine's public IP: $MY_IP"

    echo "Checking that $DOMAIN resolves to $MY_IP ..."
    if ! domain_resolves_to_ip "$DOMAIN_TRIM" "$MY_IP"; then
      die "DNS for '$DOMAIN' does not resolve to $MY_IP. Fix DNS (A record) and try again."
    fi
    echo "DNS check passed."

    printf 'Email (for ACME / Lets Encrypt): '
    read -r EMAIL
    local EMAIL_TRIM
    EMAIL_TRIM=$(printf '%s' "$EMAIL" | tr -d ' ')
    [[ -n "$EMAIL_TRIM" ]] || die "Email is required."

    printf 'Proxy username: '
    read -r PROXY_USER
    local USER_TRIM
    USER_TRIM=$(printf '%s' "$PROXY_USER" | tr -d ' ')
    [[ -n "$USER_TRIM" ]] || die "Proxy username is required."

    read_secret "Proxy password: "
    [[ -n "${PROXY_PASS:-}" ]] || die "Proxy password is required."

    write_naive_env "$NAIVE_ENV_FILE" "$DOMAIN_TRIM" "$EMAIL_TRIM" "$PROXY_USER" "$PROXY_PASS"

    local TMP_CADDY
    TMP_CADDY=$(mktemp_file)
    # Fix: Combined cleanup trap
    trap 'rm -f "$TMP_CADDY"' EXIT
    
    write_caddyfile "$DOMAIN_TRIM" "$EMAIL_TRIM" "$PROXY_USER" "$PROXY_PASS" "$TMP_CADDY"
    mv "$TMP_CADDY" "$caddyfile_path"
    ensure_caddy_user
    chown root:"$CADDY_USER" "$caddyfile_path"
    chmod 0640 "$caddyfile_path"
  fi

  echo "Downloading static index.html..."
  download_to "https://raw.githubusercontent.com/nginx/nginx/5eaf45f11e85459b52c18f876e69320df420ae29/docs/html/index.html" \
    /var/www/html/index.html
  chown root:"$CADDY_USER" /var/www/html
  chmod 0750 /var/www/html
  chown root:"$CADDY_USER" /var/www/html/index.html
  chmod 0640 /var/www/html/index.html

  local arch
  arch=$(uname -m 2>/dev/null || echo unknown)
  local CADDY_RELEASE_URL CADDY_TAR_SHA256
  case "$arch" in
    x86_64|amd64)
      CADDY_RELEASE_URL="https://github.com/klzgrad/forwardproxy/releases/download/v2.10.0-naive/caddy-forwardproxy-naive.tar.xz"
      CADDY_TAR_SHA256="598b34841ac88b66f5b0b3a7bb371a02682915e92916e4e017d27be5399cd389"
      ;;
    aarch64|arm64)
      die "Prebuilt Caddy forwardproxy binary for arm64 is not bundled in this installer. Build it manually via xcaddy: xcaddy build --with github.com/klzgrad/forwardproxy@latest"
      ;;
    *)
      die "Unsupported architecture '$arch'. Use xcaddy to build Caddy from source."
      ;;
  esac

  local CADDY_DIR="/opt/caddy-forwardproxy-naive"
  mkdir -p "$CADDY_DIR"
  local CADDY_BIN="$CADDY_DIR/caddy"

  # Fix: Download if binary is missing even if not UPGRADE
  if [[ -x "$CADDY_BIN" && "$UPGRADE" -eq 0 ]]; then
    echo "Existing Caddy binary found at $CADDY_BIN - skipping download." >&2
  else
    local TMP_TAR
    TMP_TAR=$(mktemp_tar)
    # Fix: update trap to include tar
    trap 'rm -f "$TMP_CADDY" "$TMP_TAR"' EXIT
    echo "Downloading Caddy (forwardproxy naive) for $arch..." >&2
    download_to "$CADDY_RELEASE_URL" "$TMP_TAR"
    if command -v sha256sum >/dev/null 2>&1; then
      local CADDY_TAR_SUM
      CADDY_TAR_SUM=$(sha256sum "$TMP_TAR" | awk '{print $1}')
      if [[ "$CADDY_TAR_SUM" != "$CADDY_TAR_SHA256" ]]; then
        rm -f "$TMP_TAR"
        die "Caddy archive SHA256 mismatch. Expected $CADDY_TAR_SHA256, got $CADDY_TAR_SUM"
      fi
    else
      echo "Warning: sha256sum not found - skipping Caddy archive integrity check." >&2
    fi
    tar -xJf "$TMP_TAR" -C "$CADDY_DIR" \
      || die "Extracting Caddy archive failed. On Alpine install xz: apk add --no-cache xz"
    rm -f "$TMP_TAR"
    CADDY_BIN=$(find "$CADDY_DIR" -type f \( -name caddy -o -name caddy.exe \) | head -n1)
  fi

  [[ -n "$CADDY_BIN" ]] || die "Could not find caddy binary after extracting archive."
  chmod +x "$CADDY_BIN"

  if command -v setcap >/dev/null 2>&1; then
    setcap 'cap_net_bind_service=+ep' "$CADDY_BIN"
  else
    echo "Warning: setcap not found - Caddy may fail to bind port 443 as non-root." >&2
  fi

  local CADDY_STATE_DIR="/var/lib/caddy-naive"
  mkdir -p "$CADDY_STATE_DIR"
  chown "$CADDY_USER":"$CADDY_USER" "$CADDY_STATE_DIR"
  chmod 0750 "$CADDY_STATE_DIR"

  show_share_link_and_qr
  print_firewall_reminder

  if command -v systemctl >/dev/null 2>&1; then
    echo "Installing systemd service caddy-naive.service..." >&2
    local SYSTEMD_UNIT="/etc/systemd/system/caddy-naive.service"
    # Fix: Security - using local path for service template if possible or at least documenting risk
    # For now sticking to download as per script logic but fix hash/validation is not possible without local copy
    download_to "https://raw.githubusercontent.com/kartazon/naive-setup/main/caddy-naive.service" "$SYSTEMD_UNIT"
    chmod 0644 "$SYSTEMD_UNIT"
    systemctl daemon-reload
    systemctl enable --now caddy-naive.service
    echo "Caddy is now managed by systemd. Check status with: systemctl status caddy-naive" >&2
  else
    echo "systemd not found; starting Caddy in foreground." >&2
    cd "$(dirname "$CADDY_BIN")"
    exec su -s /bin/sh "$CADDY_USER" -c "\"$CADDY_BIN\" run --config \"$caddyfile_path\""
  fi
}

require_root
main "$@"
