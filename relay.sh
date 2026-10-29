#!/usr/bin/env bash
#
# relay.sh - Concurrent HTTP API relay written in bash.
#
# Requirements: bash 4+, socat, curl, awk, coreutils (mktemp, head, wc, timeout)
#
# Usage:
#   ./relay.sh [port]
#
# Environment configuration:
#   RELAY_PORT           Listen port                       (default 8080)
#   RELAY_BIND           Bind address                      (default 127.0.0.1)
#   RELAY_MAX_CLIENTS    Max simultaneous connections      (default 100)
#   RELAY_TIMEOUT        Max seconds per upstream call     (default 60)
#   RELAY_MAX_BODY       Max request body size in bytes    (default 10 MiB)
#   RELAY_ALLOWED_HOSTS  Regex of allowed target hosts     (default: empty = allow all)
#                        e.g. '^(api\.github\.com|api\.example\.com)$'
#   RELAY_LOG            Log file                          (default /dev/stderr)

set -o pipefail

export RELAY_PORT="${1:-${RELAY_PORT:-8080}}"
export RELAY_BIND="${RELAY_BIND:-127.0.0.1}"
export RELAY_MAX_CLIENTS="${RELAY_MAX_CLIENTS:-100}"
export RELAY_TIMEOUT="${RELAY_TIMEOUT:-60}"
export RELAY_MAX_BODY="${RELAY_MAX_BODY:-10485760}"
export RELAY_ALLOWED_HOSTS="${RELAY_ALLOWED_HOSTS:-}"
export RELAY_LOG="${RELAY_LOG:-/dev/stderr}"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

log() {
    printf '%s [pid %s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" \
        "${SOCAT_PEERADDR:-local}" "$*" >>"$RELAY_LOG"
}

urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '%s' "$s"
}

reason_phrase() {
    case "$1" in
        100) echo "Continue" ;;            101) echo "Switching Protocols" ;;
        200) echo "OK" ;;                  201) echo "Created" ;;
        202) echo "Accepted" ;;            204) echo "No Content" ;;
        206) echo "Partial Content" ;;     301) echo "Moved Permanently" ;;
        302) echo "Found" ;;               303) echo "See Other" ;;
        304) echo "Not Modified" ;;        307) echo "Temporary Redirect" ;;
        308) echo "Permanent Redirect" ;;  400) echo "Bad Request" ;;
        401) echo "Unauthorized" ;;        403) echo "Forbidden" ;;
        404) echo "Not Found" ;;           405) echo "Method Not Allowed" ;;
        408) echo "Request Timeout" ;;     409) echo "Conflict" ;;
        411) echo "Length Required" ;;     413) echo "Payload Too Large" ;;
        415) echo "Unsupported Media Type" ;;
        422) echo "Unprocessable Entity" ;;
        429) echo "Too Many Requests" ;;   431) echo "Request Header Fields Too Large" ;;
        500) echo "Internal Server Error" ;;
        501) echo "Not Implemented" ;;     502) echo "Bad Gateway" ;;
        503) echo "Service Unavailable" ;; 504) echo "Gateway Timeout" ;;
        *)   echo "Status" ;;
    esac
}

# Send a relay-generated error to the client and terminate this handler.
send_error() {
    local code="$1" msg="$2"
    local body
    body=$(printf '{"relay_error":{"status":%s,"message":"%s"}}' "$code" "$(json_escape "$msg")")
    printf 'HTTP/1.1 %s %s\r\n' "$code" "$(reason_phrase "$code")"
    printf 'Content-Type: application/json\r\n'
    printf 'Content-Length: %s\r\n' "${#body}"
    printf 'Connection: close\r\n\r\n'
    printf '%s' "$body"
    log "ERROR $code: $msg"
    exit 0
}

# --------------------------------------------------------------------------
# Per-connection handler (runs in its own process for every client)
# --------------------------------------------------------------------------

handle() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/relay.XXXXXX") || exit 1
    trap 'rm -rf "$tmp"' EXIT

    # ---- Request line ----------------------------------------------------
    local line method target version
    IFS= read -r -t 15 line || exit 0
    line="${line%$'\r'}"
    read -r method target version <<<"$line"

    [[ -n "$method" && -n "$target" && "$version" == HTTP/1.* ]] \
        || send_error 400 "Malformed request line"
    [[ "$method" =~ ^[A-Z]{1,16}$ ]] || send_error 400 "Invalid method"

    # ---- Headers ---------------------------------------------------------
    local -a fwd_headers=()
    local content_length="" transfer_encoding="" target_url=""
    local name value lname hcount=0 headers_done=0

    while IFS= read -r -t 15 line; do
        line="${line%$'\r'}"
        if [[ -z "$line" ]]; then headers_done=1; break; fi
        (( ++hcount > 100 )) && send_error 431 "Too many headers"
        [[ "$line" == *:* ]] || continue

        name="${line%%:*}"
        value="${line#*:}"
        value="${value#"${value%%[![:space:]]*}"}"   # trim leading whitespace
        lname="${name,,}"

        case "$lname" in
            content-length)    content_length="$value" ;;
            transfer-encoding) transfer_encoding="$value" ;;
            x-target-url)      target_url="$value" ;;
            # Hop-by-hop / relay-specific headers: do not forward
            host|connection|keep-alive|proxy-connection|proxy-authorization|\
            te|trailer|upgrade|expect) ;;
            *)
                if [[ -z "$value" ]]; then
                    fwd_headers+=(-H "$name;")         # curl syntax for empty header
                else
                    fwd_headers+=(-H "$name: $value")
                fi
                ;;
        esac
    done
    (( headers_done )) || send_error 408 "Timed out reading request headers"

    # ---- Resolve target URL ---------------------------------------------
    if [[ -z "$target_url" ]]; then
        case "$target" in
            /http://*|/https://*)
                target_url="${target#/}" ;;
            *\?url=*|*\&url=*)
                local q="${target#*url=}"
                target_url="$(urldecode "${q%%&*}")" ;;
        esac
    fi

    [[ -n "$target_url" ]] || send_error 400 \
        "No target URL. Use header 'X-Target-URL', path '/https://host/...', or '?url=<encoded>'"
    [[ "$target_url" =~ [[:space:][:cntrl:]] ]] && send_error 400 "Target URL contains invalid characters"
    [[ "$target_url" =~ ^https?://([^/?#]+) ]] || send_error 400 "Target URL must start with http:// or https://"

    local authority="${BASH_REMATCH[1]}" host
    [[ "$authority" == *@* ]] && send_error 400 "Credentials in target URL are not allowed"
    if [[ "$authority" == \[* ]]; then
        host="${authority%%]*}]"                     # IPv6 literal
    else
        host="${authority%%:*}"
    fi
    host="${host,,}"

    if [[ -n "$RELAY_ALLOWED_HOSTS" && ! "$host" =~ $RELAY_ALLOWED_HOSTS ]]; then
        send_error 403 "Target host '$host' is not allowed"
    fi

    # ---- Request body ----------------------------------------------------
    [[ -n "$transfer_encoding" ]] && send_error 411 \
        "Chunked request bodies are not supported; send Content-Length"

    local -a body_args=()
    if [[ -n "$content_length" ]]; then
        [[ "$content_length" =~ ^[0-9]+$ ]] || send_error 400 "Invalid Content-Length"
        (( content_length > RELAY_MAX_BODY )) && send_error 413 "Request body too large"
        if (( content_length > 0 )); then
            timeout 30 head -c "$content_length" >"$tmp/req_body"
            local got=$(( $(wc -c <"$tmp/req_body") ))
            (( got == content_length )) || send_error 400 "Incomplete request body ($got/$content_length bytes)"
            body_args=(--data-binary "@$tmp/req_body")
        fi
    fi

    # ---- Forward to the external API ------------------------------------
    local -a method_args
    if [[ "$method" == "HEAD" ]]; then
        method_args=(--head)
    else
        method_args=(-X "$method")
    fi

    log "-> $method $target_url"
    local start=$SECONDS code rc

    code=$(curl -sS \
        --proto '=http,https' \
        --connect-timeout 10 \
        --max-time "$RELAY_TIMEOUT" \
        "${method_args[@]}" \
        "${fwd_headers[@]}" \
        -H 'Expect:' \
        "${body_args[@]}" \
        -D "$tmp/resp_headers" \
        -o "$tmp/resp_body" \
        -w '%{http_code}' \
        -- "$target_url" 2>"$tmp/curl_err")
    rc=$?

    if (( rc != 0 )); then
        local err; err="$(head -c 500 "$tmp/curl_err")"
        if (( rc == 28 )); then
            send_error 504 "Upstream timeout: $err"
        else
            send_error 502 "Upstream request failed (curl $rc): $err"
        fi
    fi

    # ---- Relay the response back to the client --------------------------
    # Keep only the final header block (skips any 1xx interim responses).
    tr -d '\r' <"$tmp/resp_headers" | awk '
        /^HTTP\// { n = 0; next }
        length($0) { h[++n] = $0 }
        END { for (i = 1; i <= n; i++) print h[i] }
    ' >"$tmp/final_headers"

    local body_size=0
    [[ "$method" != "HEAD" ]] && body_size=$(( $(wc -c <"$tmp/resp_body") ))

    {
        printf 'HTTP/1.1 %s %s\r\n' "$code" "$(reason_phrase "$code")"
        while IFS= read -r line; do
            lname="${line%%:*}"; lname="${lname,,}"
            case "$lname" in
                connection|keep-alive|transfer-encoding|proxy-*|upgrade|trailer) continue ;;
                content-length) [[ "$method" == "HEAD" ]] || continue ;;
            esac
            printf '%s\r\n' "$line"
        done <"$tmp/final_headers"

        if [[ "$method" != "HEAD" && ! "$code" =~ ^(1..|204|304)$ ]]; then
            printf 'Content-Length: %s\r\n' "$body_size"
        fi
        printf 'Connection: close\r\n\r\n'

        if [[ "$method" != "HEAD" ]]; then
            cat "$tmp/resp_body"
        fi
    }

    log "<- $code ${body_size}B in $(( SECONDS - start ))s ($method $target_url)"
}

# --------------------------------------------------------------------------
# Listener
# --------------------------------------------------------------------------

main() {
    local dep
    for dep in socat curl awk timeout; do
        command -v "$dep" >/dev/null 2>&1 || { echo "Missing dependency: $dep" >&2; exit 1; }
    done
    [[ "$SELF" == *" "* ]] && { echo "Script path must not contain spaces: $SELF" >&2; exit 1; }

    log "Relay listening on $RELAY_BIND:$RELAY_PORT (max $RELAY_MAX_CLIENTS clients)"
    [[ -z "$RELAY_ALLOWED_HOSTS" ]] && log "WARNING: RELAY_ALLOWED_HOSTS is empty - all target hosts allowed"

    # 'fork' => each connection is handled by a separate process (concurrency).
    exec socat \
        "TCP-LISTEN:${RELAY_PORT},bind=${RELAY_BIND},reuseaddr,fork,max-children=${RELAY_MAX_CLIENTS},backlog=128" \
        "EXEC:${SELF} --handle"
}

if [[ "${1:-}" == "--handle" ]]; then
    handle
else
    main
fi

