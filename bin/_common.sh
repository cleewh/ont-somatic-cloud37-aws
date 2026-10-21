# Shared by the scripts in bin/. Not meant to be run on its own.
set -euo pipefail

# The pipeline runs only in Asia Pacific (Singapore).
REGION=ap-southeast-1
export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION
# Never open a pager: a waiting pager would leave Kiro's command hanging.
export AWS_PAGER=""

# Work from the repository folder, where setup.env and the logs are kept.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# On Windows the scripts run in Git Bash, with the Windows AWS CLI and Python.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=yes ;;
  *) ON_WINDOWS=no ;;
esac

# Python 3.8 or later, under whichever name it's installed (on Windows: python or py -3).
PYTHON=()
for _cand in python3 python "py -3"; do
  # shellcheck disable=SC2086
  if command -v "${_cand%% *}" >/dev/null 2>&1 \
     && $_cand -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
    read -r -a PYTHON <<<"$_cand"
    break
  fi
done

if [[ "$ON_WINDOWS" == yes ]]; then
  # The Windows AWS CLI and Python end their output lines with \r\n. Drop the \r so the
  # scripts compare values correctly. `aws s3 cp` can stream file contents, so it's left alone.
  aws() {
    if [[ "${1:-}" == s3 && "${2:-}" == cp ]]; then command aws "$@"; return; fi
    command aws "$@" | tr -d '\r'
    return "${PIPESTATUS[0]}"
  }
  python3() {
    "${PYTHON[@]}" "$@" | tr -d '\r'
    return "${PIPESTATUS[0]}"
  }
  # Pass CloudWatch log group names (/aws/...) to the AWS CLI unchanged.
  export MSYS2_ARG_CONV_EXCL="/aws/"
elif (( ${#PYTHON[@]} )) && [[ "${PYTHON[0]}" != python3 ]]; then
  python3() { "${PYTHON[@]}" "$@"; }
fi

# Stop with a message that tells the user what to do.
need() {
  echo
  echo "ACTION NEEDED: $*"
  exit 1
}

# Read the bucket and network that bin/deploy.sh saved in setup.env.
load_setup() {
  [[ -f setup.env ]] || need "the pipeline hasn't been set up from this folder. Run: bash bin/deploy.sh"
  unset BUCKET SUBNETS SECURITY_GROUP
  # shellcheck disable=SC1091
  source ./setup.env
  export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
  [[ -n "${BUCKET:-}" ]] || need "setup.env has no bucket. Run: bash bin/deploy.sh"
}

# One output value of a CloudFormation stack, or nothing.
stack_output() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null || true
}

# The account's EC2 On-Demand Standard vCPU limit in Singapore (whole number), or nothing.
vcpu_limit() {
  local v
  v="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
         --query 'Quota.Value' --output text 2>/dev/null || true)"
  if [[ ! "$v" =~ ^[0-9] ]]; then
    v="$(aws service-quotas get-aws-default-service-quota --service-code ec2 --quota-code L-1216C47A \
           --query 'Quota.Value' --output text 2>/dev/null || true)"
  fi
  if [[ "$v" =~ ^[0-9] ]]; then echo "${v%%.*}"; fi
}

# The command line of process $1, or nothing if it isn't running.
command_line() {
  if [[ -r "/proc/$1/cmdline" ]]; then
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true
  else
    ps -ww -o command= -p "$1" 2>/dev/null || true
  fi
}

# Is the background task recorded in pid file $1 still running? The process must also
# still be that task: after a restart, or in a copy of this folder on another computer,
# the same process number can belong to an unrelated program. Setup runs as
# production/cloud37/bootstrap.sh; uploads and downloads get their pid file as an argument.
alive() {
  local pid marker
  pid="$(cat "$1" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [[ "$1" == bootstrap.lock ]]; then marker="bootstrap.sh"; else marker=" $1 "; fi
  [[ " $(command_line "$pid") " == *"$marker"* ]]
}

# Run a bash script in the background, detached from this terminal, so it carries on if
# Kiro or the terminal is closed. Its output goes to file $1 (or nowhere, if $1 is empty).
# Usage: start_detached LOG SCRIPT [ARGS...]
start_detached() {
  local log="$1"; shift
  if [[ "$ON_WINDOWS" == yes ]]; then
    "${PYTHON[@]}" - "$log" "$(cygpath -w "$(command -v bash)")" "$@" <<'PY'
import os, subprocess, sys
log, bash, args = sys.argv[1], sys.argv[2], sys.argv[3:]
out = open(log, "wb") if log else open(os.devnull, "wb")
flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
for extra in (0x01000000, 0):  # CREATE_BREAKAWAY_FROM_JOB, if this terminal allows it
    try:
        subprocess.Popen([bash] + args, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                         creationflags=flags | extra, close_fds=True)
        break
    except OSError:
        if not extra:
            raise
PY
  else
    nohup "${PYTHON[@]}" -c '
import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp("bash", ["bash"] + sys.argv[1:])
' "$@" > "${log:-/dev/null}" 2>&1 < /dev/null &
  fi
}

# For --wait: give the background task in pid file $1 up to 90 seconds to finish.
wait_for() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9; do
    alive "$1" || return 0
    sleep 10
  done
}

# Hours since an ISO timestamp printed by the AWS CLI, with one decimal.
hours_since() {
  python3 - "$1" <<'PY'
import sys, datetime as d
try:
    t = d.datetime.fromisoformat(sys.argv[1])
    print(f"{(d.datetime.now(d.timezone.utc) - t).total_seconds() / 3600:.1f}")
except Exception:
    print("?")
PY
}
