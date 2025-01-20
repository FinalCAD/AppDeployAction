#! /bin/bash

set -e
set -o pipefail

# Used for local tests (profile)
debug=${DEBUG:-false}
dry_run=${DRY_RUN:-false}
default=${DEFAULT_FILE:-default.yaml}
aws_cli_options="${aws_cli_options:-}"
aws_region="${AWS_REGION:-eu-central-1}"

echo "[INFO] Enable dry-run: ${dry_run}"
if [[ "${dry_run}" == 'false' ]]; then
  git_command=( git )
else
  git_command=( echo git )
fi

function override_continue() {
  local _environment="$1"; shift
  local _regions="$1"; shift
  local _application="$1"; shift
  local _override_path="$1"; shift
  local _default="$1"; shift
  local _registry="$1"; shift
  local _key="$1"; shift
  local _array_regions=${_regions//,/$'\n'}
  continue=0
  for r in ${_array_regions}; do
    local _region_dir="./${_environment}/${r}"
    [[ -d "${_region_dir}" ]] || continue
    echo "[INFO] Check region : ${r}"
    local _override_file="./${_environment}/${r}/${_application}.override.yaml"
    if [[ -f "${_override_file}" ]]; then
      echo "[INFO] Existing override file in eks-apps needs to be checked (${_override_file})"
      if [ -f "${_override_path}" ]; then
        echo "[INFO] Existing override file in apps repository needs to be checked (${_override_path})" &&
        override_value=$(yq ". *n load(\"${_default}\")" "${_override_path}") &&
        true || {
          echo '[ERROR] Unable to generate override values'
          return 1
        } >&2
        if ! diff <(yq -P 'sort_keys(..)' <<<"${override_value}") <(yq -P 'sort_keys(..)' "${_override_file}") > /dev/null; then
          echo "[INFO] Drift detected"
          continue=1
        fi
      else
        echo "[INFO] No existing override file in apps repository (${_override_path})"
      fi
    else
      echo "[INFO] Missing override file in region ${r}"
      create_file_deploy "${_environment}" "${r}" "${_application}" "${_registry}" "${_key}"
      continue=1
    fi
  done
}

function test_cue() {
  local _environment=$1
  local _override_path=$2
  local _value_file=./${_environment}/override.cue
  if ! cue vet "${_value_file}" "${_override_path}" --strict --simplify; then
    echo "[ERROR] Override file does not validate cue file"
    exit 1
  fi
}

function test_chart() {
  local _environment="$1"; shift
  local _regions="$1"; shift
  local _application="$1"; shift
  local _override_path="$1"; shift

  local _region=''
  for _region in ${_regions//,/$'\n'}; do
    echo "[INFO] Kubeconform & helm for ${_region}"

    ./scripts/check_templates.sh \
      --environment "${_environment}" \
      --region "${_region}" \
      --file-name "${_application}.yaml" \
      --override-file "${_override_path}" || {
        echo "[ERROR] Check template has failed after override"
        exit 1
    }
  done
}

function create_file_deploy() {
  echo "[INFO] Create deploy file"
  local _env="$1"; shift
  local _region="$1"; shift
  local _app_name="$1"; shift
  local _registry="$1"; shift
  local _key="$1"; shift
  local _values_dir="${_env}/${_region}"

  [[ -d "${_values_dir}" ]] || return 0
  local _values_file="${_values_dir}/${_app_name}.yaml"
  cat << EOF > "${_values_file}" &&
---
app:
  name: $_app_name
  finalcadContext: finalcad-one
EOF
  yq e -i ".image.repository=\"${_registry}\"" "${_values_file}" &&
  yq e -i "${_key}=\"sha256:init\"" "${_values_file}" &&
  cat "${_values_file}" &&
  echo "[INFO] File ${_values_file} created" &&
  "${git_command[@]}" add "${_values_file}" &&
  true
}

function check_ecr_compute_sha() {
  local _registry="$1"; shift
  local _reference="$1"; shift

  local _repo_cmd=( aws ${aws_cli_options} --region "${aws_region}" ecr describe-repositories --repository-names "${_registry}" )
  echo "AWS cmd: ${_repo_cmd[@]}"
  "${_repo_cmd[@]}" || {
    local status=$?
    echo "[ERROR] Registry ${_registry} not found on ${aws_region}"
    return ${status}
  } >&2

  local _cmd=( aws ${aws_cli_options} --output json --region "${aws_region}" ecr describe-images --repository-name "${_registry}" )
  echo "AWS cmd: ${_cmd[@]}"
  local _describe_images=''
  _describe_images="$("${_cmd[@]}")" || {
    local status=$?
    echo "[ERROR] Unable to list images from repository ${_registry} (${aws_region})"
    return ${status}
  } >&2

  local _computed_sha256=''
  _computed_sha256="$(jq -r --arg imageTagIndex "${_reference}" '.imageDetails[] | select(.imageTags | index($imageTagIndex)) | .imageDigest' <<<"${_describe_images}")" || {
    local status=$?
    echo "[ERROR] Error while looking up \"${_reference}\", exiting..."
    jq <<<"${_describe_images}" || true
    return ${status}
  } >&2

  [[ ! -z "${_computed_sha256}" ]] || {
    local status=$?
    echo "[ERROR] Unable to find a image with reference \"${_reference}\", exiting..."
    jq <<<"${_describe_images}" || true
    return 1
  }
  sha256="${_computed_sha256}"
  if [ "${debug}" = true ]; then
    echo "[DEBUG] sha256: ${sha256}"
  fi
}

function setup_git() {
  if [ -z "${ACTOR_EMAIL}" ]; then
    ACTOR_EMAIL="${GITHUB_ACTOR}@finalcad.com"
  fi
  if [ -z "${ACTOR_NAME}" ]; then
    ACTOR_NAME="${GITHUB_ACTOR}"
  fi

  "${git_command[@]}" config --global user.email "${ACTOR_EMAIL}"
  "${git_command[@]}" config --global user.name "${ACTOR_NAME}"
}

function git_push() {
  # Error after 5 attempts
  local i=0
  for i in {1..5}; do
    status=0
    "${git_command[@]}"  pull --rebase && "${git_command[@]}" push || status=$?
    if [[ "${status}" != 0 ]]; then
      echo "[WARNING] Error while pushing changes, retrying in 10 seconds" >&2
      sleep 10
    else
      echo "[INFO] Changes pushed"
      break
    fi
  done
  [[ "${status}" == 0 ]] || {
    echo "[ERROR] Error while pushing changes, exiting..."
    return "${status}"
  } >&2
}

function update_value_override() {
  local _environment=$1
  local _region=$2
  local _application=$3
  local _override_path=$4
  local _default=$5
  local _value_dir="./${_environment}/${_region}"
  [[ -d "${_value_dir}" ]] || return 0
  local _value_file="${_value_dir}/${_application}.override.yaml"
  echo "[INFO] Merge '${_default}' with '${_override_path}' into '${_value_file}'
  yq ". *n load(\"${_default}\")" "${_override_path}"> "${_value_file}"
  if [[ ! -z "$(git status --short "${_value_file}")" ]]; then
    echo "[INFO] File ${_value_file} updated"
    if [ ! "${debug}" = true ]; then
      "${git_command[@]}"  add --all &&
      "${git_command[@]}"  commit -am "${_application} ${_environment} ${_region} update override" || {
        local rc=$?
        echo "[ERROR] Unable to commit changes to '${_value_file}'"
        return $rc
      }
    fi
  else
    echo "[INFO] File ${_value_file} unchanged"
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
    "${git_command[@]}" commit -am "${_app_name} ${_env}.${_region}: update sha256 to ${_sha256}"
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

  res=$(yq '.sqitch | has("repository")' "$_values_file")
  if [ "$res" == "false" ]; then
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
    "${git_command[@]}"  commit -am "${_app_name} ${_env}.${_region}: update sha256 to ${_sha256}"
  fi
}

#########################
# Setup
#########################

if [ "${debug}" = true ]; then
  echo "[DEBUG] Debug Mode: ON"
  set +x
fi

[[ ! -z "${REGIONS}" ]] || REGIONS="eu,ap"

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
[[ ! -z "${APPNAME}" ]] || APPNAME=$(echo "${REGISTRY}" | cut -d '/' -f2)

#########################
# Override file
#########################

# Combine override files
[[ -z "${OVERRIDE_ADDITIONAL_PATHES}" ]] || {
  echo "[INFO] Merging override files ${OVERRIDE_PATH} ${OVERRIDE_ADDITIONAL_PATHES}"
  override_files=()
  for override_file in $(tr ',' ' ' <<<"${OVERRIDE_ADDITIONAL_PATHES}"); do
    override_files+=( "$(cd "${GITHUB_WORKSPACE}" && readlink -f "${override_file}")" )
  done
  override_temp="$(mktemp --suffix '.yaml')" &&
  echo "[INFO] Merge ${OVERRIDE_PATH} ${override_files[@]} into ${override_temp}" &&
  yq --prettyPrint eval-all '. as $item ireduce ({}; . * $item )' "${OVERRIDE_PATH}" "${override_files[@]}" > "${override_temp}" &&
  OVERRIDE_PATH="${override_temp}" || {
    echo '[ERROR] Unable to merge override files'
    exit 1
  } >&2
}

# Verify if override is needed
if [ "${sqitch}" = "true" ]; then
  # no override if we only update sqitch
  continue=0
else
  echo "[INFO] Test if override should be updated"
  override_continue "${ENVIRONMENT}" "${REGIONS}" "${APPNAME}" "${OVERRIDE_PATH}" "${default}" "${REGISTRY}" "${key}"
  echo "[INFO] continue: ${continue}"
fi

if [ "${continue}" -eq 0 ]; then
  echo "[INFO] Nothing to change"
else
  test_cue "${ENVIRONMENT}" "${OVERRIDE_PATH}"
  test_chart "${ENVIRONMENT}" "${REGIONS}" "${APPNAME}" "${OVERRIDE_PATH}"

  regions=${REGIONS//,/$'\n'}
  # For every defined regions, update values file with image sha
  for region in ${regions}; do
    update_value_override "${ENVIRONMENT}" "${region}" "${APPNAME}" "${OVERRIDE_PATH}" "${default}"
  done
fi

#########################
# Deploy file
#########################

if [ "${sqitch}" = "true" ]; then
  # Get sqitch image digest from reference
  check_ecr_compute_sha "${sqitch_registry}" "${ref}"
else
  # Get image digest from reference
  [[ -z "${REGISTRY}" ]] || check_ecr_compute_sha "${REGISTRY}" "${ref}"
fi

# For every defined regions, update values file with image sha
for region in ${regions}; do
  values_dir="${ENVIRONMENT}/${region}"
  if [ "${debug}" = true ]; then
    echo "[DEBUG] values_dir: ${values_dir}"
  fi
  [[ -d "${values_dir}" ]] || {
    echo "[INFO] Ignore environment/region ${values_dir}"
    continue
  }
  echo "############################################"
  if [ "${sqitch}" = "true" ]; then
    echo "# UPDATE SQITCH ${region}, ${REGISTRY}"
  else
    echo "# UPDATE APP ${region}, ${REGISTRY}"
  fi
  echo "############################################"
  values_file="${values_dir}/${APPNAME}.yaml"
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
    [[ -f "${values_file}" ]] || {
      echo "[ERROR] File ${values_file} not found, exiting..."
      exit 1
    } >&2
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

[[ "${dry_run}" == 'false' ]] || {
  for file in $(find "./${ENVIRONMENT}" -name "${APPNAME}*.yaml"); do
    echo
    echo "=============== ${file} ==============="
    cat "${file}"
  done
}
