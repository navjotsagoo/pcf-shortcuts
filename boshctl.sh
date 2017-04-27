#!/bin/bash

set -e

shopt -s expand_aliases

alias bosh='BUNDLE_GEMFILE=/home/tempest-web/tempest/web/vendor/bosh/Gemfile bundle exec bosh'
alias uaac='BUNDLE_GEMFILE=/home/tempest-web/tempest/web/vendor/uaac/Gemfile bundle exec uaac'

usage_and_exit() {
  cat <<EOF
BOSH Control starts or stops all your BOSH deployments.

Usage: boshctl <command>
Examples:
  boshctl login
  boshctl start
  boshctl stop
EOF
  exit 1
}

jq_exists() {
  command -v jq >/dev/null 2>&1
}

is_director_targeted() {
  ! $(bosh status | tr -d '\n' | grep -q 'Director  not set')
}

is_logged_in() {
  ! $(bosh status | grep -q 'not logged in')
}

is_opsman_locked() {
  $(curl "https://localhost/" -k -I -s | grep -q 'Location: .*/unlock')
}

unlock_opsman() {
  local PASSPHRASE=$1

  local STATUS_CODE=$(curl "https://localhost/api/v0/unlock" -k \
    -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -d "{\"passphrase\": \"$PASSPHRASE\"}")

    [ "200" = "$STATUS_CODE" ]
}

is_valid_access_token() {
  local UAA_ACCESS_TOKEN=$1
  [ -n "$UAA_ACCESS_TOKEN" ] || return 1

  local STATUS_CODE=$(curl "https://localhost/uaa/check_token" -k -L -G \
    -s -o /dev/null -w "%{http_code}" \
    -u "opsman:" \
    -d token_type=bearer \
    -d token="$UAA_ACCESS_TOKEN")

    [ "200" = "$STATUS_CODE" ]
}

login_to_uaac() {
  local OPSMAN_USER=
  read -r -p "Ops Manager User: " OPSMAN_USER

  local OPSMAN_PASS=
  read -r -s -p "Ops Manager Pass: " OPSMAN_PASS
  echo # extra linefeed

  uaac target https://localhost/uaa --skip-ssl-validation

  uaac token owner get opsman "$OPSMAN_USER" -p "$OPSMAN_PASS" -s ''

  echo "User $OPSMAN_USER logged in successfully."
}

get_director_password() {
  local output=$(curl "https://localhost/api/v0/deployed/director/credentials/director_credentials" -k -s \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN")

  local director_password=
  if jq_exists; then
    director_password=$(echo "$output" | jq -r .credential.value.password)
  else
    director_password=$(echo "$output" | grep -o -E '"password"\s{0,}:\s{0,}"[0-9a-zA-Z_-]+"' | cut -d : -f 2 | tr -d \" | tr -d ' ')
  fi
  echo $director_password
}

# Use Ops Manager admin credentials to go grab the director password for bosh login
login_via_opsmgr() {
  local UAA_ACCESS_TOKEN=$(uaac context | grep access_token | awk '{ print $2 }')
  if ! is_valid_access_token "$UAA_ACCESS_TOKEN"; then
    login_to_uaac
    UAA_ACCESS_TOKEN=$(uaac context | grep access_token | awk '{ print $2 }')
  fi
  local director_password=$(get_director_password)
  printf "director\n$director_password\n" | bosh login
}

login() {
  if ! is_director_targeted; then
    local director_url=
    read -r -p "Director URL: " director_url
    bosh -n --ca-cert /var/tempest/workspaces/default/root_ca_certificate target $director_url
  fi
  if is_opsman_locked; then
    local passphrase=
    read -r -s -p "Ops Manager Decryption Passphrase: " passphrase
    echo # extra linefeed
    if ! unlock_opsman "$passphrase"; then
      echo "Failed to unlock Ops Manager. Please try again."
      exit 1
    fi
  fi
  if ! is_logged_in; then
    login_via_opsmgr
  fi
}

get_deployments() {
  bosh deployments 2>/dev/null | grep -o '^| [[:alpha:]]\+-.*' | cut -d \| -f 2 | tr -d ' '
}

stop() {
  local deployment=$1
  local deployment_file="/var/tempest/workspaces/default/deployments/$deployment.yml"
  bosh deployment $deployment_file
  bosh -n -N stop --hard
}

start() {
  local deployment=$1
  local deployment_file="/var/tempest/workspaces/default/deployments/$deployment.yml"
  bosh deployment $deployment_file
  bosh -n -N start
}

# Stop all deployments in reverse order
stop_all() {
  for deployment in $(get_deployments | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }'); do
    stop $deployment
  done
}

# Start all deployments in order
start_all() {
  for deployment in $(get_deployments); do
    start $deployment
  done
}

CMD=$1 ARG=$2

if [ "start" = "$CMD" ]; then
  login
  start_all
  bosh tasks
elif [ "stop" = "$CMD" ]; then
  login
  stop_all
  bosh tasks
elif [ "login" = "$CMD" ]; then
  login
else
  usage_and_exit
fi
