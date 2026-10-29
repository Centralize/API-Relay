# relay.sh - Concurrent HTTP API relay written in bash.

#### Requirements: bash 4+, socat, curl, awk, coreutils (mktemp, head, wc, timeout)

#### Usage:
  ./relay.sh [port]

#### Environment configuration:
  RELAY_PORT           Listen port                       (default 8080) <br />
  RELAY_BIND           Bind address                      (default 127.0.0.1) <br />
  RELAY_MAX_CLIENTS    Max simultaneous connections      (default 100)
  RELAY_TIMEOUT        Max seconds per upstream call     (default 60)
  RELAY_MAX_BODY       Max request body size in bytes    (default 10 MiB)
  RELAY_ALLOWED_HOSTS  Regex of allowed target hosts     (default: empty = allow all)
                       e.g. '^(api\.github\.com|api\.example\.com)$'
  RELAY_LOG            Log file                          (default /dev/stderr)
