#! /bin/bash

set -e
# Used for local tests (profile)
debug=${DEBUG:-false}
default=${DEFAULT_FILE:-default.yaml}
aws_cli_options="${aws_cli_options:-}"
aws_region="${AWS_REGION:-eu-central-1}"

function override_continue() {
  local _envrionmment=$1
  local _regions=$2
  local _application=$3
  local _override_path=$4
  local _default=$5
  local _array_regions=${_regions//,/$'\n'}
  continue=0
  for r in ${_array_regions}; do
    if [ -f "./${_envrionmment}/${r}/${_application}.override.yaml" ]; then
      override_value=$(yq ". *n load(\"${_default}\")" "${_override_path}")
      diff <(yq -P 'sort_keys(..)' <(echo "${override_value}")) <(yq -P 'sort_keys(..)' "./${_envrionmment}/${r}/${_application}.override.yaml") > /dev/null
      exit_code="$?"
      if [ ! "${exit_code}" -eq 0 ]; then
        echo "[INFO] Drift detected"
        continue=1
        break
      fi
    else
      echo "[INFO] Missing override file in region ${r}"
      continue=1
      break
    fi
  done
}

function test_cue() {
  local _envrionmment=$1
  local _override_path=$2
  local _value_file=./${_envrionmment}/override.cue
  if ! cue vet "${_value_file}" "${_override_path}" --strict --simplify; then
    echo "[ERROR] Override file does not validate cue file"
    exit 1
  fi
}

function test_chart() {
  local _envrionmment=$1
  local _regions=$2
  local _application=$3
  local _override_path=$4
  local _kubeversions=$5
  local _repopath=./${_envrionmment}/chart
  local _array_regions=${_regions//,/$'\n'}
  local _array_kubeversions=${_kubeversions//,/$'\n'}
  for region in ${_array_regions}; do
    for kubeversion in ${_array_kubeversions}; do
      echo "[INFO] Kubeconform & helm for ${region} on ${kubeversion}"
      helm_args="-f ${_repopath}/values.yaml -f ${_repopath}/../${region}/values.yaml"
      if [  -f "${_repopath}/../${region}/${_application}.${_envrionmment}.${region}.values.yaml" ]; then
        helm_args+=" -f ${_repopath}/../${region}/${_application}.${_envrionmment}.${region}.values.yaml"
      fi
      if [  -f "${_repopath}/../${region}/${_application}.yaml" ]; then
        helm_args+=" -f ${_repopath}/../${region}/${_application}.yaml"
      fi
      result=$(helm template ${_repopath} ${helm_args} -f ${_override_path})
      if [ "$?" -ne 0 ]; then
        echo "[ERROR] Helm chart is not valid after override"
        exit 1
      fi
      echo "${result}" | kubeconform -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
        -kubernetes-version "${kubeversion}" -strict
      if [ "$?" -ne 0 ]; then
        echo "[ERROR] kubeconform failed after override"
        exit 1
      fi
    done
  done
}

function create_file_deploy() {
  echo "[INFO] Create deploy file"
  local _env=$1
  local _region=$2
  local _app_name=$3
  local _registry=$4
  local _key=$5
  local _values_file="${_env}/${_region}/${_app_name}.yaml"
  cat << EOF > "${_values_file}"
---
app:
  name: $_app_name
  finalcadContext: finalcad-one
EOF
  yq e -i ".image.repository=\"${_registry}\"" "${_values_file}"
  yq e -i "${_key}=\"sha256:init\""  "${_values_file}"
  cat "${_env}/${_region}/${_app_name}.yaml"
  echo "[INFO] File ${_env}/${_region}/${_app_name}.yaml created"
  git add "${_env}/${_region}/${_app_name}.yaml"
}

function check_ecr_compute_sha() {
  local _registry=$1
  local _reference=$2
  local _computed_sha256=""
  local _repo_cmd="aws ${aws_cli_options} --region ${aws_region} ecr describe-repositories --repository-names ${_registry}"
  echo "AWS cmd: ${_repo_cmd}"
  eval "${_repo_cmd}"
  status=$?
  if [ "${status}" -ne 0 ]; then
    echo "Registry ${_registry} not found on ${aws_region}"
    exit 1
  fi
  local _cmd="aws ${aws_cli_options} --region ${aws_region} ecr describe-images --repository-name ${_registry} | jq -r '.imageDetails[] | select(.imageTags | index(\"${_reference}\")) | .imageDigest'"
  echo "AWS cmd: ${_cmd}"
  _computed_sha256=$(eval "${_cmd}")
  if [ -z "${_computed_sha256}" ]; then
    echo "[ERROR] Unable to find a image with reference \"${_reference}\", exiting..."
    exit 1
  fi
  sha256=${_computed_sha256}
}

function setup_git() {
  if [ -z "${ACTOR_EMAIL}" ]; then
    ACTOR_EMAIL="${GITHUB_ACTOR}@finalcad.com"
  fi
  if [ -z "${ACTOR_NAME}" ]; then
    ACTOR_NAME="${GITHUB_ACTOR}"
  fi

  git config --global user.email "${ACTOR_EMAIL}"
  git config --global user.name "${ACTOR_NAME}"
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

function update_value_override() {
  local _envrionmment=$1
  local _region=$2
  local _application=$3
  local _override_path=$4
  local _default=$5
  local _value_file=./${_envrionmment}/${_region}/${_application}.override.yaml
  yq ". *n load(\"${_default}\")" "${_override_path}"> "${_value_file}"
  echo "[INFO] File ${_value_file} updated"
  if [ ! "${debug}" = true ]; then
    git add --all
    git commit -am "${_application} ${_envrionmment} ${_region} update override"
  fi
}

function update_value_deploy() {
  local _sha256=$1
  local _key=$2
  local _app_name=$3
  local _env=$4
  local _region=$5
  local _values_file=$6
  local _existing_value=""
  _existing_value=$(yq e "${_key}" "${_values_file}")
  echo "Existing value for ${_app_name} : ${_existing_value}"
  if [ "${_existing_value}" = "${_sha256}" ]; then
    echo "[WARNING] The image's SHA is already ${_sha256}, nothing to do..."
  else
    yq e -i "${_key}=\"${_sha256}\"" "${_values_file}"
    echo "File ${_values_file} updated with ${_key} => ${_sha256}"
    git commit -am "${_app_name} ${_env}.${_region}: update sha256 to ${_sha256}"
  fi
}

function update_value_sqitch() {
  local _sha256=$1
  local _key=$2
  local _app_name=$3
  local _env=$4
  local _region=$5
  local _values_file=$6
  local _sqitch_registry=$7
  local _existing_value=""

  if ! jq ".sqitch" "$_values_file" &>/dev/null; then
    # The "sqitch" section is missing, so we add it using jq and update the file in place
    yq e -i ".sqitch.repository = \"${_sqitch_registry}\"" "${_values_file}"
    yq e -i "${_key}=\"sha256:init\"" "${_values_file}"
  fi
  _existing_value=$(yq e "${_key}" "${_values_file}")
  echo "Existing value for ${_app_name} : ${_existing_value}"
  if [ "${_existing_value}" = "${_sha256}" ]; then
    echo "[WARNING] The image's SHA is already ${_sha256}, nothing to do..."
  else
    yq e -i "${_key}=\"${_sha256}\"" "${_values_file}"
    echo "File ${_values_file} updated with ${_key} => ${_sha256}"
    git commit -am "${_app_name} ${_env}.${_region}: update sha256 to ${_sha256}"
  fi
}

#########################
# Setup
#########################

if [ "${debug}" = true ]; then
  echo "[DEBUG] Debug Mode: ON"
  set +x
fi

# change comma to white space
regions=${REGIONS//,/$'\n'}

ref="${REF:-latest}"
key="${key:-.image.sha}"
sqitch="${SQITCH:-false}"
sqitch_key="${sqitch_key:-.sqitch.sha}"

if [[ ${REGISTRY} == *sqitch ]]
then
  sqitch_registry="${REGISTRY}"
else
  sqitch_registry="${REGISTRY}-sqitch"
fi

if [ "${debug}" = true ]; then
  echo "[DEBUG] Debug Mode: ON"
  echo "[INFO] Values environment: \"${ENVIRONMENT}\", region: \"${REGIONS}\", app: \"${APPNAME}\", path \"${OVERRIDE_PATH}\""
  set +x
else
  echo "[INFO] Setup git"
  setup_git
fi

# Use app_name variable if not empty, else set it with registry project part
if [ -z "${APPNAME}" ]; then
  APPNAME=$(echo "${REGISTRY}" | cut -d '/' -f2)
fi

#########################
# Override file
#########################

# Verify if override is needed
if [ "${sqitch}" = "true" ]; then
  # no override if we only update sqitch
  continue=0
else
  echo "[INFO] Test if override should be updated"
  override_continue "${ENVIRONMENT}" "${REGIONS}" "${APPNAME}" "${OVERRIDE_PATH}" "${default}"
  echo "[INFO] continue: ${continue}"
fi

# Create missing main file
for region in ${regions}; do
  if [ ! -f "${ENVIRONMENT}/${region}/${APPNAME}.yaml" ]; then
    create_file_deploy "${ENVIRONMENT}" "${region}" "${APPNAME}" "${REGISTRY}" "${key}"
  fi
done

if [ "${continue}" -eq 0 ]; then
  echo "[INFO] Nothing to change"
else
  test_cue "${ENVIRONMENT}" "${OVERRIDE_PATH}"
  test_chart "${ENVIRONMENT}" "${REGIONS}" "${APPNAME}" "${OVERRIDE_PATH}" "${KUBEVERSIONS}"

  regions=${REGIONS//,/$'\n'}
  # For every defined regions, update values file with image sha
  for region in ${regions}; do
    update_value_override "${ENVIRONMENT}" "${region}" "${APPNAME}" "${OVERRIDE_PATH}" "${default}"
  done
fi

#########################
# Deploy file
#########################

set +e
if [ "${sqitch}" = "true" ]; then
  # Get sqitch image digest from reference
  check_ecr_compute_sha "${sqitch_registry}" "${ref}"
else
  # Get image digest from reference
  check_ecr_compute_sha "${REGISTRY}" "${ref}"
fi
set -e

# For every defined regions, update values file with image sha
for region in ${regions}; do
  echo "############################################"
  if [ "${sqitch}" = "true" ]; then
    echo "# UPDATE SQITCH ${region}, ${REGISTRY}"
  else
    echo "# UPDATE APP ${region}, ${REGISTRY}"
  fi
  echo "############################################"
  values_file="${ENVIRONMENT}/${region}/${APPNAME}.yaml"
  echo "appname: ${APPNAME}"
  echo "registry: ${REGISTRY}"
  echo "registry-sqitch: ${REGISTRY}"
  echo "region: ${region}"
  echo "environment: ${ENVIRONMENT}"
  echo "value_file: ${values_file}"
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
    if [ "${sqitch}" = "true" ]; then
      update_value_sqitch "${sha256}" "${sqitch_key}" "${APPNAME}" "${ENVIRONMENT}" "${region}" "${values_file}" "${sqitch_registry}"
    else
      update_value_deploy "${sha256}" "${key}" "${APPNAME}" "${ENVIRONMENT}" "${region}" "${values_file}"
    fi
    echo "############################################"
  fi
done

#########################
# Push changes
#########################

if [ ! "${debug}" = true ]; then
  git_push
fi
