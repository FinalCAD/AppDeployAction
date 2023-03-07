#! /bin/bash

set -e
# Used for local tests (profile)
debug=${DEBUG:-false}
aws_cli_options="${aws_cli_options:-}"
aws_region="${AWS_REGION:-eu-central-1}"

if [ "${debug}" = true ]; then
  echo "[DEBUG] Debug Mode: ON"
  set +x
fi

function check_ecr_compute_sha() {
  local _registry=$1
  local _reference=$2
  local _repo_cmd="aws ${aws_cli_options} --region ${aws_region} ecr describe-repositories --repository-names ${_registry}"
  echo "AWS cmd: ${_repo_cmd}"
  $($repo_cmd)
  status=$?
  if [ "${status}" -ne 0 ]; then
    echo "Registry ${_registry} not found on ${aws_region}"
    exit 1
  fi
  local _cmd="aws ${aws_cli_options} --region ${aws_region} ecr describe-images --repository-name ${_registry} | jq -r '.imageDetails[] | select(.imageTags | index(\"${_reference}\")) | .imageDigest'"
  echo "AWS cmd: ${_cmd}"
  local _computed_sha256=$(eval "${_cmd}")
  if [ -z "${_computed_sha256}" ]; then
    echo "[ERROR] Unable to find a image with reference \"${_reference}\", exiting..."
    exit 1
  fi
  sha256=${_computed_sha256}
}

function git_push() {
  set +eo pipefail # allow error
  # Error after 50 seconds / 5 attempts
  i=1
  while [ $i -lt 6 ]; do
    git pull --rebase && git push
    status=$?
    if [ ! "${status}" -eq 0 ]; then
      echo "[WARNING] Error while pushing changes, retrying in 10 seconds"
      sleep 10
    else
      echo "Changes pushed"
      break
    fi
    i=$((i + 1))
  done
  set -eo pipefail # disallow error
  if [ $i -gt 5 ]; then
    echo "[ERROR] Error while pushing changes, exiting..."
    exit 1
  fi
}

function update_value() {
  local _sha256=$1
  local _key=$2
  local _app_name=$3
  local _env=$4
  local _region=$5
  local _values_file=$6
  local _existing_value=$(yq e "${_key}" "${_values_file}")
  echo "Existing value for ${_app_name} : ${_existing_value}"
  if [ "${_existing_value}" = "${_sha256}" ]; then
    echo "[WARNING] The image's SHA is already ${_sha256}, nothing to do..."
  else
    yq e -i "${_key}=\"${_sha256}\"" "${_values_file}"
    echo "File ${_values_file} updated with ${_key} => ${_sha256}"
    git commit -am "${_app_name} ${_env}.${_region}: update sha256 to ${_sha256}"
  fi
}

# change comma to white space
regions=${REGIONS//,/$'\n'}

ref="${REF:-latest}"
key="${key:-.image.sha}"
sqitch="${SQITCH:-false}"
sqitch_key="${sqitch_key:-.sqitch.sha}"

if [ -z "${ACTOR_EMAIL}" ]; then
  ACTOR_EMAIL="${GITHUB_ACTOR}@finalcad.com"
fi
if [ -z "${ACTOR_NAME}" ]; then
  ACTOR_NAME="${GITHUB_ACTOR}"
fi

git config --global user.email "${ACTOR_EMAIL}"
git config --global user.name "${ACTOR_NAME}"

# Use app_name variable if not empty, else set it with registry project part
if [ -z "${APPNAME}" ]; then
  APPNAME=$(echo "${REGISTRY}" | cut -d '/' -f2)
fi

if [ "${sqitch}" = "false" ]; then
  # Get image digest from reference
  set +e
  check_ecr_compute_sha "${REGISTRY}" "${ref}"
  set -e

  # For every defined regions, update values file with image sha
  for region in ${regions}; do
    echo "############################################"
    echo "# UPDATE APP ${region}, ${REGISTRY}"
    echo "############################################"
    file="${filename:-${APPNAME}.${ENVIRONMENT}.${region}.values.yaml}"
    values_file="${ENVIRONMENT}/${region}/${file}"
    echo "appname: ${APPNAME}"
    echo "registry: ${REGISTRY}"
    echo "region: ${region}"
    echo "environment: ${ENVIRONMENT}"
    echo "value_file: ${values_file}"
    echo "tag: ${tag}"
    echo "reference: ${ref}"
    echo "sha computed: ${sha256}"
    echo "############################################"
    if [ ! "${debug}" = true ]; then
      if [ ! -f "${values_file}" ]; then
        echo "[ERROR] File ${values_file} not found, exiting..."
        exit 1
      fi
      # Update value in yaml file
      echo "Updating the new version of ${APPNAME} in ${values_file} on ${ENVIRONMENT} ${region}"
      update_value "${sha256}" "${key}" "${APPNAME}" "${ENVIRONMENT}" "${region}" "${values_file}"
      echo "############################################"
    fi
  done
fi

if [ "${sqitch}" = "true" ]; then

  if [[ ${REGISTRY} == *sqitch ]]
  then
    sqitch_registry="${REGISTRY}"
  else
    sqitch_registry="${REGISTRY}-sqitch"
  fi

  regions_sqitch=${regions_sqitch:-$regions}
  # Get sqitch image digest from reference
  set +e
  check_ecr_compute_sha "${sqitch_registry}"
  set -e
  # For every defined regions, update values file with image sha
  for region in ${regions_sqitch}; do
    echo "############################################"
    echo "# UPDATE SQITCH ${region}, ${REGISTRY}"
    echo "############################################"
    file="${filename:-${APPNAME}.${ENVIRONMENT}.${region}.values.yaml}"
    values_file="${ENVIRONMENT}/${region}/${file}"
    echo "appname: ${APPNAME}"
    echo "registry: ${sqitch_registry}"
    echo "region: ${region}"
    echo "environment: ${ENVIRONMENT}"
    echo "value_file: ${values_file}"
    echo "tag: ${tag}"
    echo "reference: ${ref}"
    echo "sha computed: ${sha256}"
    echo "############################################"
    if [ ! "${debug}" = true ]; then
      if [ ! -f "${values_file}" ]; then
        echo "[ERROR] File ${values_file} not found, exiting..."
        exit 1
      fi
      # Update value in yaml file
      echo "Updating the new version of ${APPNAME}-sqitch in ${values_file} on ${ENVIRONMENT} ${region}"
      update_value "${sha256}" "${sqitch_key}" "${APPNAME}-sqitch" "${ENVIRONMENT}" "${region}" "${values_file}"
      echo "############################################"
    fi
  done
fi

# Push changes
if [ ! "${debug}" = true ]; then
  git_push
fi
