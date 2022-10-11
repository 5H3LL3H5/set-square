#!/usr/bin/env dry-wit
# Copyright 2014-today Automated Computing Machinery S.L.
# Distributed under the terms of the GNU General Public License v3

# DW.import command;

# fun: main
# api: public
# txt: Main logic. Gets called by dry-wit.
# txt: Returns 0/TRUE always, but may exit due to errors.
# use: main
function main() {
  local _repo
  local _parents
  local _buildRepo
  local _oldIFS="${IFS}"

  resolve_base_image
  IFS="${DWIFS}"
  for _repo in ${REPOSITORIES}; do
    IFS="${_oldIFS}"
    loadRepoEnvironmentVariables "${_repo}"
    evalEnvVars
    retrieveNamespace
    local _namespace="${RESULT}"
    _buildRepo=${FALSE}
    if force_mode_enabled; then
      _buildRepo=${TRUE}
    elif ! repo_exists "${_repo}" "${TAG}"; then
      _buildRepo=${TRUE}
    else
      logInfo -n "Not building ${_namespace}/${_repo}:${TAG} since it's already built"
      logInfoResult SUCCESS "skipped"
    fi
    if isTrue ${_buildRepo}; then
      find_parents "${_repo}"
      _parents="${RESULT}"
      IFS="${DWIFS}"
      for _parent in ${_parents}; do
        IFS="${_oldIFS}"
        build_repo_if_defined_locally "${_parent}"
      done
      IFS="${_oldIFS}"

      build_repo "${_repo}"
    fi

    overwrite_latest_tag "${_namespace}" "${_repo}" "${TAG}"

    annotate_successful_build "${_repo}" "${TAG}"

    if registry_push_enabled || registry_tag_enabled; then
      registry_tag "${_repo}" "${TAG}"
      if overwrite_latest_enabled; then
        registry_tag "${_repo}" "latest"
      fi
    fi

    if registry_push_enabled; then
      registry_push "${_repo}" "${TAG}"
      if overwrite_latest_enabled; then
        registry_push "${_repo}" "latest"
      fi
    fi
  done
  IFS="${_oldIFS}"
  cleanup_containers
  cleanup_images
}

# fun: retrieveNamespace
# api: public
# txt: Retrieves the namespace.
# txt: Returns 0/TRUE always.
# use: if retrieveNamespace "bla"; then echo "Namespace for bla"; fi
function retrieveNamespace() {
  local _flavor=""

  if ! isEmpty "${SETSQUARE_FLAVOR}"; then
    _flavor="-${SETSQUARE_FLAVOR}"
  fi

  export RESULT="${NAMESPACE}${_flavor}"
  return ${TRUE}
}

# fun: repo_exists repo tag
# api: public
# txt: Does "${NAMESPACE}/${REPO}:${TAG}" exist?
# opt: repo: The repository.
# opt: tag: The tag.
# txt: Returns 0/TRUE if it exists; 1/FALSE otherwise.
# use: if repo_exists "myImage" "latest"; then echo "Repo exists"; fi
function repo_exists() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _tag="${2}"
  checkNotEmpty "tag" "${_tag}" 2
  local _aux
  local -i _rescode

  if evalEnvVar "${_tag}"; then
    _aux="${RESULT}"
    if isNotEmpty "${_aux}"; then
      _tag="${_aux}"
    fi
  fi

  retrieveNamespace
  local _namespace="${RESULT}"
  local _images=$(${DOCKER} images "${_namespace}/${_repo}")
  local _matches=$(echo "${_images}" | grep -- "${_tag}")

  if isEmpty "${_matches}"; then
    _rescode=${FALSE}
  else
    _rescode=${TRUE}
  fi

  return ${_rescode}
}

# fun: build_repo_if_defined_locally repo
# txt: Builds the image if it's defined locally.
# opt: repo: The repository.
# txt: Returns 0/TRUE always.
# use: build_repo_if_defined_locally "myImage:latest";
function build_repo_if_defined_locally() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _name="${_repo%:*}"
  local _tag="${_repo#*:}"
  retrieveNamespace
  local _namespace

  if ! isEmpty "${_name}" &&
    [[ -d ${_name} ]] &&
    ! repo_exists "${_name#${_namespace}/}" "${_tag}"; then
    build_repo "${_name}"
  fi
}

# fun: reduce_image_size namespace repo currentTag tag
# api: public
# txt: Squashes the image with docker-squash [1]
# txt: [1] https://github.com/jwilder/docker-squash
# opt: namespace: The namespace.
# opt: repo: The repo name.
# opt: currentTag: The current tag.
# opt: tag: The new tag for the squashed image.
# use: reduce_image_size "namespace" "myimage" "201508-raw" "201508"
function reduce_image_size() {
  local _namespace="${1}"
  checkNotEmpty namespace "${_namespace}" 1
  local _repo="${2}"
  checkNotEmpty repo "${_repo}" 2
  local _currentTag="${3}"
  checkNotEmpty currentTag "${_currentTag}" 3
  local _tag="${4}"
  checkNotEmpty tag "${_tag}" 4

  checkReq docker-squash DOCKER_SQUASH_NOT_INSTALLED

  logInfo -n "Squashing ${_image} as ${_namespace}/${_repo}:${_tag}"
  ${DOCKER} save "${_namespace}/${_repo}:${_currentTag}" | sudo docker-squash -t "${_namespace}/${_repo}:${_tag}" | ${DOCKER} load
  if isTrue $?; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_REDUCING_IMAGE "${_namespace}/${_repo}:${_currentTag}"
  fi
}

# fun: process_file
# api: public
# txt: Processes given file.
# opt: file: The input file.
# opt: output: The output file.
# opt: repoFolder: The repo folder.
# opt: templateFolder: The template folder.
# opt: repo: The image.
# opt: rootImage: The root image.
# opt: namespace: The namespace.
# txt: Returns 0/TRUE if the file is processed correctly; 1/FALSE otherwise.
# use: if process_file "my.template" "my" "my-image-folder" ".templates" "my" "base" "company"; then echo "File processed successfully"; fi
function process_file() {
  local _file="${1}"
  checkNotEmpty file "${_file}" 1
  local _output="${2}"
  local _repoFolder="${3}"
  local _templateFolder="${4}"
  local _repo="${5}"
  local _rootImage="${6}"
  local _namespace="${7}"
  local _backupHostSshPort="${10:-22}"
  local -i _rescode=${FALSE}

  local _temp1
  local _temp2

  if arrayContains "${_file}" "${__PROCESSED_FILES[@]}"; then
    _rescode=${TRUE}
  else
    __PROCESSED_FILES+="${_file}"
    checkNotEmpty output "${_output}" 2
    checkNotEmpty repoFolder "${_repoFolder}" 3
    checkNotEmpty templateFolder "${_templateFolder}" 4
    checkNotEmpty repo "${_repo}" 5
    checkNotEmpty rootImage "${_rootImage}" 6
    checkNotEmpty namespace "${_namespace}" 7

    local _settingsFile="$(dirname ${_file})/$(basename ${_file} .template).settings"
    logTrace -n "Settings file for ${_file}"
    if fileExists "${_settingsFile}"; then
      logTraceResult SUCCESS "${_settingsFile}"
      process_settings_file "${_settingsFile}"
    else
      logTraceResult FAILURE "${_settingsFile}"
    fi

    if createTempFile; then
      _temp1="${RESULT}"
    fi

    if createTempFile; then
      _temp2="${RESULT}"
    fi

    if isNotEmpty "${_temp1}" && isNotEmpty "${_temp2}" &&
      debugDuration resolve_includes "${_file}" "${_temp1}" "${_repoFolder}" "${_templateFolder}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
      logTrace -n "Resolving @include_env in ${_file}"
      if debugDuration resolve_include_env "${_temp1}" "${_temp2}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
        if debugDuration process_placeholders "${_temp2}" "${_output}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
          _rescode=${TRUE}
          logTraceResult SUCCESS "done"
        else
          _rescode=${FALSE}
          logTraceResult FAILURE "failed"
        fi
      else
        _rescode=${FALSE}
        logTraceResult FAILURE "failed"
      fi
    else
      _rescode=${FALSE}
    fi
  fi

  return ${_rescode}
  file repoFolder templateFolder
}

# fun: resolve_included_file
# api: public
# txt: Resolves given included file.
# opt: file: The file name.
# opt: repoFolder: The repository folder.
# opt: templateFolder: The template folder.
# txt: Returns 0/TRUE if the file is found; 1/FALSE otherwise.
# use: if ! resolve_included_file "footer" "my-image-folder" ".templates"; then echo "'footer' not found"; fi
function resolve_included_file() {
  local _file="${1}"
  checkNotEmpty file "${_file}" 1
  local _repoFolder="${2}"
  checkNotEmpty repoFolder "${_repoFolder}" 2
  local _templatesFolder="${3}"
  checkNotEmpty templatesFolder "${_templatesFolder}" 3
  local _result
  local _rescode=${FALSE}
  local d
  local _oldIFS="${IFS}"

  IFS=$' \t\n'
  for d in "${_templatesFolder}"; do
    IFS="${_oldIFS}"
    if [[ -f "${d}/${_file}" ]] ||
      [[ -f "${d}/$(basename ${_file} .template).template" ]]; then
      _result="${d}/${_file}"
      export RESULT="${_result}"
      _rescode=${TRUE}
      break
    fi
  done
  IFS="${_oldIFS}"

  if isFalse ${_rescode}; then
    if [[ $(eval "echo ${_file}") != "${_file}" ]]; then
      resolve_included_file "$(eval "echo ${_file}")" "${_repoFolder}" "${_templatesFolder}"
      _rescode=$?
    fi
  fi

  return ${_rescode}
}

# fun: resolve_includes input output repoFolder templateFolder repo rootImage namespace
# api: public
# txt: Resolves any @include in given file.
# opt: input: The input file.
# opt: output: The output file.
# opt: repoFolder: The repository folder.
# opt: templateFolder: The template folder.
# opt: repo: The image.
# opt: rootImage: The root image.
# opt: namespace: The namespace.
# opt: backupHostSshPort: The backup host's SSH port for this image (optional).
# txt: Returns 0/TRUE if the @include()s are resolved successfully; 1/FALSE otherwise.
# use: resolve_includes "my.template" "my" "my-image-folder" ".templates" "myImage" "myRoot" "example" "latest" "22"
function resolve_includes() {
  local _input="${1}"
  checkNotEmpty input "${_input}" 1
  local _output="${2}"
  checkNotEmpty output "${_output}" 2
  local _repoFolder="${3}"
  checkNotEmpty repoFolder "${_repoFolder}" 3
  local _templateFolder="${4}"
  checkNotEmpty templateFolder "${_templateFolder}" 4
  local _repo="${5}"
  checkNotEmpty repo "${_repo}" 5
  local _rootImage="${6}"
  checkNotEmpty rootImage "${_rootImage}" 6
  local _namespace="${7}"
  checkNotEmpty namespace "${_namespace}" 7
  local _backupHostSshPort="${8:-22}"
  local _rescode
  local _match
  local _includedFile
  local line
  local _folder
  local _files

  logTrace -n "Resolving @include()s in ${_input}"

  echo -n '' >"${_output}"

  while IFS='' read -r line; do
    _match=${FALSE}
    _includedFile=""
    if [[ "${line#@include(\"}" != "$line" ]] &&
      [[ "${line%\")}" != "$line" ]]; then
      _ref="$(echo "$line" | sed 's/@include(\"\(.*\)\")/\1/g')"
      if resolve_included_file "${_ref}" "${_repoFolder}" "${_templateFolder}"; then
        _includedFile="${RESULT}"
        if fileExists "${_includedFile}.template"; then
          if process_file "${_includedFile}.template" "${_includedFile}" "${_repoFolder}" "${_templateFolder}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
            _match=${TRUE}
          else
            _match=${FALSE}
            logTraceResult FAILURE "failed"
            exitWithErrorCode CANNOT_PROCESS_TEMPLATE "${_includedFile}"
          fi
        elif fileExists "${_includedFile}.settings"; then
          if process_settings_file "${_includedFile}.settings"; then
            _match=${TRUE}
          else
            _match=${FALSE}
            logTraceResult FAILURE "failed"
            exitWithErrorCode CANNOT_PROCESS_TEMPLATE "${_includedFile}.settings"
          fi
        else
          _match=${TRUE}
        fi
        if [ -d "${_templateFolder}/$(basename ${_includedFile})-files" ]; then
          mkdir "${_repoFolder}/$(basename ${_includedFile})-files" 2>/dev/null
          rsync -azI "${PWD}/${_templateFolder#\./}/$(basename ${_includedFile})-files/" "${_repoFolder}/$(basename ${_includedFile})-files/"
          _folder="${_repoFolder}/$(basename ${_includedFile})-files"
          if folderExists "${_folder}"; then
            #                  shopt -s nullglob dotglob;
            _files=($(find "${_folder}" -type f -name '*.template' 2>/dev/null))
            #                  shopt -u nullglob dotglob;
            if isGreaterThan ${#_files[@]} 0; then
              for p in ${_files[@]}; do
                IFS="${_oldIFS}"
                process_file "${p}" "$(dirname ${p})/$(basename ${p} .template)" "${_repoFolder}" "${_templateFolder}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"
              done
              IFS="${_oldIFS}"
            fi
          fi
        fi
      elif ! fileExists "${_ref}.template"; then
        logTraceResult FAILURE "failed"
        exitWithErrorCode TEMPLATE_DOES_NOT_EXIST "${_ref}"
      else
        _match=${FALSE}
        _errorRef="${_ref}"
        eval "echo ${_ref}" >/dev/null 2>&1
        if isTrue $?; then
          _errorRef="${_input} contains ${_ref} with evaluates to $(eval "echo ${_ref}" 2>/dev/null), and it's not found in any of the expected paths: ${_repoFolder}, ${_templateFolder}"
        fi
      fi
    fi
    if isTrue ${_match}; then
      cat "${_includedFile}" >>"${_output}"
    else
      echo "$line" >>"${_output}"
    fi
  done <"${_input}"
  _rescode=$?
  if isEmpty "${_errorRef}" && isTrue ${_rescode}; then
    logTraceResult SUCCESS "done"
  else
    logTraceResult FAILURE "failed"
  fi

  return ${_rescode}
}

# fun: process_settings_file file
# api: public
# txt: Processes a settings file for a template.
# opt: file: The settings file.
# txt: Returns 0/TRUE if the settings file was processed successfully; 1/FALSE otherwise.
# use: if process_settings_file "my.settings"; then echo "my.settings processed successfully"; fi
function process_settings_file() {
  local _file="${1}"
  checkNotEmpty file "${_file}" 1
  local -i _rescode=${FALSE}

  logInfo -n "Reading ${_file}"
  source "${_file}"
  _rescode=$?
  if isTrue ${_rescode}; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
  fi

  return ${_rescode}
}

# fun: retrieve_standard_environment_variables
# api: public
# txt: Retrieves the standard environment variables.
# txt: Returns 0/TRUE always.
# use: retrieve_standard_environment_variables; echo "vars: ${RESULT}"
function retrieve_standard_environment_variables() {
  export RESULT="TAG DATE TIME STACK BASE_IMAGE"
}

# fun: process_placeholders file output repo rootImage namespace backupHostSshPort
# api: public
# txt: Processes placeholders in given file.
# opt: file: The input file.
# opt: output: The output file.
# opt: repo: The image.
# opt: rootImage: The root image.
# opt: namespace: The namespace.
# opt: backupHostSshPort: The backup host's SSH port (optional).
# txt: Returns 0/TRUE if the file was processed successfully; 1/FALSE otherwise.
# use: if process_placeholders "my.template" "my" "myImage" "root" "example" "2222"; then echo "my.template -> my"; fi
function process_placeholders() {
  local _file="${1}"
  checkNotEmpty file "${_file}" 1
  local _output="${2}"
  checkNotEmpty output "${_output}" 2
  local _repo="${3}"
  checkNotEmpty repo "${_repo}" 3
  local _rootImage="${4}"
  checkNotEmpty rootImage "${_rootImage}" 4
  local _namespace="${5}"
  checkNotEmpty namespace "${_namespace}" 5
  local _backupHostSshPort="${6:-22}"
  local -i _rescode
  local -i i
  local _oldIFS="${IFS}"
  local _variables=''
  local _customEnvVars
  local _standardEnvVars
  local _var

  retrieve_standard_environment_variables
  _standardEnvVars="${RESULT}"

  retrieveCustomEnvironmentVariables
  _customEnvVars="${RESULT}"

  logTrace -n "Resolving placeholders in ${_file}"
  IFS="${DWIFS}"
  for _var in ${_standardEnvVars} ${_customEnvVars}; do
    IFS="${_oldIFS}"
    if isNotEmpty "${_var}"; then
      if isNotEmpty "${_variables}"; then
        _variables="${_variables} "
      fi
      _variables="${_variables}$(echo "${_var}" | awk -v dollar="$" -v quote="\"" '{printf("echo %s=\\\"%s%s{%s}%s\\\"", $0, quote, dollar, $0, quote);}' | sh)"
    fi
  done
  IFS="${_oldIFS}"

  _variables="${_variables} MAINTAINER=\"${AUTHOR} <${AUTHOR_EMAIL}>\" REPO=\"${_repo}\" IMAGE=\"${_repo}\" ROOT_IMAGE=\"${_rootImage}\" NAMESPACE=\"${_namespace}\" BACKUP_HOST_SSH_PORT=\"${_backupHostSshPort}\" DOLLAR=$ "

  replaceVariablesInFile "${_file}" "${_output}" ${_variables}
  logTraceResult SUCCESS "done"
}

# fun: resolve_include_env input output image rootImage namespace backupHostSshPort
# api: public
# txt: Resolves any @include_env in given file.
# opt: input: The input file.
# opt: output: The output file.
# opt: image: The image.
# opt: rootImage: The root image.
# opt: namespace: The namespace.
# opt: backupHostSshPort: The backup host SSH port (optional).
# txt: Returns 0/TRUE if the @include_env is resolved successfully; 1/FALSE otherwise.
# use: if resolve_include_env "my.template" "my" "image" "base" "example" 2222; then echo "@include_env resolved"; fi
function resolve_include_env() {
  local _input="${1}"
  checkNotEmpty input "${_input}" 1
  local _output="${2}"
  checkNotEmpty output "${_output}" 2
  local _image="${3}"
  checkNotEmpty image "${_image}" 3
  local _rootImage="${4}"
  checkNotEmpty rootImate "${_rootImage}" 4
  local _namespace="${5}"
  checkNotEmpty namespace "${_namespace}" 5
  local _backupHostSshPort="${6:-22}"

  local _includedFile
  local -i _rescode
  local _envVar
  local line
  local -a _envVars=()
  local -i i
  local _oldIFS="${IFS}"

  retrieveCustomEnvironmentVariables
  local _aux="${RESULT}"
  for _envVar in ${_aux}; do
    _envVars[${#_envVars[@]}]="${_envVar}"
  done
  _envVars[${#_envVars[@]}]="IMAGE"
  _envVars[${#_envVars[@]}]="DATE"
  _envVars[${#_envVars[@]}]="TIME"
  _envVars[${#_envVars[@]}]="MAINTAINER"
  _envVars[${#_envVars[@]}]="AUTHOR"
  _envVars[${#_envVars[@]}]="AUTHOR_EMAIL"
  _envVars[${#_envVars[@]}]="STACK"
  _envVars[${#_envVars[@]}]="ROOT_IMAGE"
  _envVars[${#_envVars[@]}]="BASE_IMAGE"
  _envVars[${#_envVars[@]}]="STACK_SUFFIX"
  _envVars[${#_envVars[@]}]="NAMESPACE"
  _envVars[${#_envVars[@]}]="BACKUP_HOST_SSH_PORT"

  logTrace -n "Resolving @include_env in ${_input}"

  echo -n '' >"${_output}"

  while IFS='' read -r line; do
    IFS="${_oldIFS}"
    _includedFile=""
    if [[ "${line#@include_env}" != "$line" ]]; then
      echo "ENV DW_DISABLE_ANSI_COLORS=TRUE \\" >>"${_output}"
      echo -n "    " >>"${_output}"
      for ((i = 0; i < ${#_envVars[@]}; i++)); do
        _envVar="${_envVars[$i]}"
        if [ "${_envVar#ENABLE_}" == "${_envVar}" ]; then
          if [ $i -ne 0 ]; then
            echo >>"${_output}"
            echo -n "    " >>"${_output}"
          fi
          echo "${_envVar}" | awk -v dollar="$" -v quote="\"" '{printf("echo -n \"SQ_%s=\\\"%s%s{%s}%s\\\"\"", $0, quote, dollar, $0, quote);}' | sh >>"${_output}"
          if isLessThan $i $((${#_envVars[@]} - 1)); then
            echo -n " \\" >>"${_output}"
          fi
        fi
      done
      echo >>"${_output}"
    elif [[ "${line# +}" == "${line}" ]]; then
      echo "$line" >>"${_output}"
    fi
  done <"${_input}"
  _rescode=$?
  if isTrue ${_rescode}; then
    logTraceResult SUCCESS "done"
  else
    logTraceResult FAILURE "failed"
  fi
  return ${_rescode}
}

# fun: update_log_category image
# api: public
# txt: Updates the log category to include the current image.
# opt: image: The image.
# txt: Returns 0/TRUE always.
# use: update_log_category "mysql"
function update_log_category() {
  local _image="${1}"
  checkNotEmpty image "${_image}" 1

  local _logCategory
  getLogCategory
  _logCategory="${RESULT%/*}/${_image}"
  setLogCategory "${_logCategory}"
}

# fun: copy_license_file repo folder
# api: public
# txt: Copies the license file from specified folder to the repository folder.
# opt: repo: The repository.
# opt: folder: The folder where the license file is included.
# txt: Returns 0/TRUE always.
# use: copy_license_file "myImage" ${PWD}
function copy_license_file() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _folder="${2}"
  checkNotEmpty folder "${_folder}" 2

  if isEmpty "${LICENSE_FILE}"; then
    exitWithErrorCode LICENSE_FILE_IS_MANDATORY
  fi

  if fileExists "${_folder}/${LICENSE_FILE}"; then
    logDebug -n "Using ${LICENSE_FILE} for ${_repo} image"
    cp "${_folder}/${LICENSE_FILE}" "${_repo}/${LICENSE_FILE}"
    if isTrue $?; then
      logDebugResult SUCCESS "done"
    else
      logDebugResult FAILURE "failed"
      exitWithErrorCode CANNOT_COPY_LICENSE_FILE
    fi
  else
    exitWithErrorCode LICENSE_FILE_DOES_NOT_EXIST "${_folder}/${LICENSE_FILE}"
  fi
}

# fun: copy_copyright_preamble_file repo folder
# api: public
# txt: Copies the copyright-preamble file from specified folder to the repository folder.
# opt: repo: The repository.
# opt: folder: The folder where the copyright preamble file is included.
# txt: Returns 0/TRUE always.
# use: copy_copyright_preamble_file "myImage" ${PWD}
function copy_copyright_preamble_file() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _folder="${2}"
  checkNotEmpty folder "${_folder}" 2

  if isEmpty "${COPYRIGHT_PREAMBLE_FILE}"; then
    exitWithErrorCode COPYRIGHT_PREAMBLE_FILE_IS_MANDATORY
  fi

  if fileExists "${_folder}/${COPYRIGHT_PREAMBLE_FILE}"; then
    logDebug -n "Using ${COPYRIGHT_PREAMBLE_FILE} for ${_repo} image"
    cp "${_folder}/${COPYRIGHT_PREAMBLE_FILE}" "${_repo}/${COPYRIGHT_PREAMBLE_FILE}"
    if isTrue $?; then
      logDebugResult SUCCESS "done"
    else
      logDebugResult FAILURE "failed"
      exitWithErrorCode CANNOT_COPY_COPYRIGHT_PREAMBLE_FILE
    fi
  else
    exitWithErrorCode COPYRIGHT_PREAMBLE_FILE_DOES_NOT_EXIST "${_folder}/${COPYRIGHT_PREAMBLE_FILE}"
  fi
}

# fun: retrieve_backup_host_ssh_port repo
# api: public
# txt: Resolves the BACKUP_HOST_SSH_PORT variable.
# opt: repo: The image.
# txt: Returns 0/TRUE always.
# txt: RESULT contains the value of BACKUP_HOST_SSH_PORT variable.
# use: retrieve_backup_host_ssh_port mariadb; export BACKUP_HOST_SSH_PORT="${RESULT}"; fi
function retrieve_backup_host_ssh_port() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _result

  if isNotEmpty "${SSHPORTS_FILE}" &&
    fileExists "${SSHPORTS_FILE}"; then
    logDebug -n "Retrieving the ssh port of the backup host for ${_repo}"
    _result="$(
      echo -n ''
      (grep -e ${_repo} ${SSHPORTS_FILE} || echo ${_repo} 22) | awk '{print $2;}' | head -n 1
    )"
    if isTrue $?; then
      logDebugResult SUCCESS "${_result}"
      export RESULT="${_result}"
    else
      logDebugResult FAILURE "not-found"
    fi
  else
    _result=""
  fi
}

# fun: retrieveDockerBuildOpts
# api: public
# txt: Retrieves the options for docker build.
# txt: Returns 0/TRUE always.
# txt: The variable RESULT contains the build options.
# use: retrieveDockerBuildOpts; docker build ${RESULT} .
function retrieveDockerBuildOpts() {
  local _result="" #--net=host ";

  if isTrue ${NO_CACHE}; then
    _result="--no-cache"
  fi

  export RESULT="${_result}"
}

# fun: build_repo repo
# api: public
# txt: Builds "${NAMESPACE}/${REPO}:${TAG}" image.
# opt: repo: The repository.
# txt: Returns 0/TRUE always.
# use: build_repo "myImage" "latest" "";
function build_repo() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _canonicalTag="${2}"
  local _tag
  local _cmdResult
  local _rootImage
  local _f
  retrieveNamespace
  local _namespace="${RESULT}"
  local _buildOpts
  local _oldIFS="${IFS}"

  retrieve_backup_host_ssh_port "${_repo}"
  local _backupHostSshPort="${RESULT:-22}"
  if is_32bit; then
    _rootImage="${ROOT_IMAGE_32BIT}:${ROOT_IMAGE_VERSION}"
  else
    _rootImage="${ROOT_IMAGE_64BIT}:${ROOT_IMAGE_VERSION}"
  fi
  update_log_category "${_repo}"

  defineEnvVar IMAGE MANDATORY "The image to build" "${_repo}"

  local _logFile="${PWD}"/"${_repo}"/build.log
  rm -f "${_logFile}"
  touch "${_logFile}"
  logToFile "${_logFile}"

  copy_license_file "${_repo}" "${PWD}"
  copy_copyright_preamble_file "${_repo}" "${PWD}"

  if isGreaterThan $(ls ${_repo}/*.template | grep -e '\.template$' | grep -v -e 'Dockerfile\.template$' | wc -l) 0; then
    IFS="${DWIFS}"
    for _f in $(ls ${_repo} | grep -e '\.template$' | grep -v -e 'Dockerfile\.template$'); do
      IFS="${_oldIFS}"
      logDebug -n "Processing ${_repo}/${_f}"
      if process_file "${_repo}/${_f}" "${_repo}/$(basename ${_f} .template)" "${_repo}" "${INCLUDES_FOLDER}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
        logDebugResult SUCCESS "done"
      else
        logDebugResult FAILURE "failed"
        exitWithErrorCode CANNOT_PROCESS_TEMPLATE "${_repo}/${_f}"
      fi
    done
    IFS="${_oldIFS}"
  fi

  _tag="${TAG}"
  if reduce_image_enabled; then
    _rawTag="${TAG}-raw"
  fi
  _f="${_repo}/Dockerfile.template"
  logDebug -n "Processing ${_f}"
  if process_file "${_f}" "${_repo}/$(basename ${_f} .template)" "${_repo}" "${INCLUDES_FOLDER}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
    logDebugResult SUCCESS "done"
  else
    logDebugResult FAILURE "failed"
    exitWithErrorCode CANNOT_PROCESS_TEMPLATE "${_f}"
  fi

  retrieveDockerBuildOpts
  _buildOpts="${RESULT}"
  logInfo "docker build ${_buildOpts} -t ${_namespace}/${_repo}:${_tag} --rm=true ${_repo}"

  DW.import command

  runCommandLongOutput "${DOCKER} build ${_buildOpts} -t ${_namespace}/${_repo}:${_tag}-b --rm=true ${_repo}"
  _cmdResult=$?
  logInfo -n "${_namespace}/${_repo}:${_tag}-b"
  if isTrue ${_cmdResult}; then
    logInfoResult SUCCESS "built"
  else
    logInfoResult FAILURE "not built"
    exitWithErrorCode ERROR_BUILDING_REPOSITORY "${_repo}"
  fi

  logInfo -n "Adding build log to the resulting image"
  if add_file_to_image "${_logFile}" "/${IMAGE}.log" "${_namespace}/${_repo}:${_tag}-b" "${_namespace}/${_repo}:${_tag}"; then
    logInfoResult SUCCESS "done"
    logInfo -n "Removing intermediate image"
    if docker rmi "${_namespace}/${_repo}:${_tag}-b"; then
      logInfoResult SUCCESS "done"
    else
      logInfoResult FAILURE "failed"
    fi
  else
    logInfoResult FAILURE "failed"
  fi

  if reduce_image_enabled; then
    reduce_image_size "${_namespace}" "${_repo}" "${_tag}" "${_canonicalTag}"
  fi
}

# fun: add_file_to_image file destPath oldImage newImage
# api: public
# txt: Adds a file to given image, creating a new one.
# opt: file: The file to add.
# opt: destPath: The destination path.
# opt: oldImage: The old image.
# opt: newImage: The new image.
# txt: Returns 0/TRUE if the image could be built; 1/FALSE otherwise.
# use: if add_file_to_image build.log /build.log myImage:old myImage:new; then echo "Image built"; fi
function add_file_to_image() {
  local _file="${1}"
  checkNotEmpty file "${_file}" 1

  local _destPath="${2}"
  checkNotEmpty destPath "${_destPath}" 2

  local _oldImage="${3}"
  checkNotEmpty oldImage "${_oldImage}" 3

  local _newImage="${4}"
  checkNotEmpty newImage "${_newImage}" 4

  createTempFolder
  local _tempFolder="${RESULT}"
  local _dockerfile="${_tempFolder}/Dockerfile"

  cp "${_file}" "${_tempFolder}"
  local _fileName="$(basename "${_file}")"

  logDebug -n "Creating Dockerfile"
  cat <<EOF >"${_dockerfile}"
FROM ${_oldImage}

COPY ${_fileName} ${_destPath}
EOF
  logDebugResult SUCCESS "done"

  logDebug "Creating image ${_newImage}"
  pushd "${_tempFolder}"
  docker build -t ${_newImage} .
  _rescode=$?
  popd

  logDebug -n "Creating image ${_newImage}"
  if isTrue ${_rescode}; then
    logDebugResult SUCCESS "done"
  else
    logDebugResult FAILURE "failed"
  fi

  return ${_rescode}
}

# fun: add_file_to_image_using_a_temporary_container file destPath oldImage newImage
# api: public
# txt: Adds a file to given image, creating a new one.
# opt: file: The file to add.
# opt: destPath: The destination path.
# opt: oldImage: The old image.
# opt: newImage: The new image.
# txt: Returns 0/TRUE always, but can exit with an error.
# use: add_file_to_image_using_a_temporary_container build.log /build.log myImage:old myImage:new
function add_file_to_image_using_a_temporary_container() {
  local _file="${1}"
  checkNotEmpty file "${_file}" 1

  local _destPath="${2}"
  checkNotEmpty destPath "${_destPath}" 2

  local _oldImage="${3}"
  checkNotEmpty oldImage "${_oldImage}" 3

  local _newImage="${4}"
  checkNotEmpty newImage "${_newImage}" 4

  logInfo -n "Creating a temporary container for ${_oldImage}"
  local _containerId="$(docker create ${_oldImage})"
  if isTrue $?; then
    logInfoResult SUCCESS "${_containerId}"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode CANNOT_CREATE_A_DEAD_CONTAINER "${_oldImage}"
  fi

  logInfo -n "Copying ${_file} to ${_containerId} (${_oldImage})"
  docker cp "${_file}" ${_containerId}:"${_destPath}"
  if isTrue $?; then
    logInfoResult SUCCESS "${_containerId}"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode CANNOT_COPY_FILE_TO_CONTAINER "${_oldImage}"
  fi

  logInfo -n "Committing ${_containerId}"
  docker commit ${_containerId} "${_newImage}"
  if isTrue $?; then
    logInfoResult SUCCESS "${_newImage}"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode CANNOT_COMMIT_CONTAINER
  fi

  logInfo -n "Deleting temporary container"
  docker rm ${_containerId}
  if isTrue $?; then
    logInfoResult SUCCESS "${_containerId}"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode CANNOT_DELETE_CONTAINER "${_containerId}"
  fi
}

# fun: overwrite_latest_tag namespace repo tag
# api: public
# txt: Overwrites the "latest" tag if requested.
# opt: namespace: The namespace.
# opt: repo: The repository.
# opt: tag: The tag.
# txt: Conditionally overwrites the "latest" tag.
# txt: Returns 0/TRUE always.
# use: overwrite_latest_tag "mycompany" "myimage" "0.11";
function overwrite_latest_tag() {
  local _namespace="${1}"
  checkNotEmpty namespace "${_namespace}" 1
  local _repo="${2}"
  checkNotEmpty repo "${_repo}" 2
  local _tag="${3}"
  checkNotEmpty tag "${_tag}" 3

  if overwrite_latest_enabled; then
    logInfo -n "Tagging ${_namespace}/${_repo}:${_tag} as ${_namespace}/${_repo}:latest"
    docker tag "${_namespace}/${_repo}:${_tag}" "${_namespace}/${_repo}:latest"
    if isTrue $?; then
      logInfoResult SUCCESS "${_namespace}/${_repo}:latest"
    else
      logInfoResult FAILURE "failed"
      exitWithErrorCode ERROR_TAGGING_IMAGE "${_repo}"
    fi
  fi
}

# fun: annotate_successful_build repo tag
# api: public
# txt: Annotates a successful build.
# opt: repo: The repository.
# opt: tag: The tag.
# txt: Returns 0/TRUE if the build could be annotated successfully; 1/FALSE otherwise.
# use: if annotate_successful_build "myimage" "0.11"; then echo "Build annotated"; fi
function annotate_successful_build() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1

  local _tag="${2}"
  checkNotEmpty tag "${_tag}" 2

  touch "${_repo}"/.builds
  local -i _rescode=$?

  if isTrue ${_rescode}; then
    echo "${_tag}: $(date)" >>"${_repo}"/.builds
  fi

  return ${_rescode}
}

# fun: retrieveRemoteTag namespace repo tag
# api: public
# txt: Retrieves the remote tag.
# opt: namespace: The namespace.
# opt: repo: The repository name.
# opt: tag: The tag.
# txt: Returns 0/TRUE always.
# txt: RESULT contains the remote tag.
# use: retrieveRemoteTag "mycompany" "myImage" "latest"; echo "Remote tag: ${RESULT}";
function retrieveRemoteTag() {
  local _namespace="${1}"
  checkNotEmpty namespace "${_namespace}" 1
  local _repo="${2}"
  checkNotEmpty repo "${_repo}" 2
  local _tag="${3}"
  checkNotEmpty tag "${_tag}" 3

  local _result
  if areEqual "${REGISTRY}" "cloud.docker.com"; then
    _result="${REGISTRY_NAMESPACE}/${_namespace}/${_repo}:${_tag}"
  else
    _result="${REGISTRY}/${_namespace}/${_repo}:${_tag}"
  fi

  export RESULT="${_result}"
}

# fun: registry_tag repo tag
# api: public
# txt: Tags the image anticipating it will be pushed to a Docker registry later.
# opt: repo: The repository.
# opt: tag: The tag.
# txt: Returns 0/TRUE always.
# use: registry_tag "myImage" "latest"
function registry_tag() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _tag="${2}"
  checkNotEmpty tag "${_tag}" 2

  retrieveNamespace
  local _namespace="${RESULT}"
  retrieveRemoteTag "${_namespace}" "${_repo}" "${_tag}"
  local _remoteTag="${RESULT}"

  update_log_category "${_repo}"
  logInfo -n "Tagging ${_namespace}/${_repo}:${_tag} as ${_remoteTag}"
  docker tag ${DOCKER_TAG_OPTIONS} "${_namespace}/${_repo}:${_tag}" "${_remoteTag}"
  if isTrue $?; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_TAGGING_IMAGE "${_repo}"
  fi
}

# fun: registry_push repo tag
# api: public
# txt: Pushes the image to a Docker registry.
# opt: repo: The repository.
# opt: tag: The tag.
# txt: Returns 0/TRUE always.
# use: registry_push "myImage" "latest"
function registry_push() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _tag="${2}"
  checkNotEmpty tag "${_tag}" 2

  retrieveRemoteTag "${_repo}" "${_tag}"
  local _remoteTag="${RESULT}"

  local -i _pushResult
  update_log_category "${_repo}"

  logInfo -n "Pushing ${_remoteTag}"
  docker push "${_remoteTag}"
  _pushResult=$?
  if isTrue ${_pushResult}; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_PUSHING_IMAGE "${_remoteTag}"
  fi
}

# fun: is_32bit
# api: public
# txt: Finds out if the architecture is 32 bits.
# txt: Returns 0/TRUE if it 32b, 1/FALSE otherwise.
# use: if is_32bit; then echo "32bit"; fi
function is_32bit() {
  [ "$(uname -m)" == "i686" ]
}

# fun: find_parent_repo repo
# api: public
# txt: Finds The parent image for a given repo.
# opt: repo: The repository.
# txt: Returns 0/TRUE always.
# txt: RESULT contains the parent, if any, with the format name:tag.
# use: find_parent_repo "myImage"; echo "parent: ${RESULT}";
function find_parent_repo() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _result="$(grep -e '^FROM ' ${_repo}/Dockerfile.template 2>/dev/null | head -n 1 | awk '{print $2;}')"

  retrieveNamespace
  local _namespace
  if isNotEmpty ${_result} && [[ "${_result#\$\{_namespace\}/}" != "${_result}" ]]; then
    # parent under our namespace
    _result="${_result#\$\{_namespace\}/}"
  fi
  if isNotEmpty "${_result}" && isEmpty "${_result#\$\{BASE_IMAGE\}}"; then
    _result=$(echo ${BASE_IMAGE} | awk -F'/' '{print $2;}')
  fi
  if isNotEmpty "${_result}" && isEmpty "${_result#\$\{ROOT_IMAGE\}}"; then
    _result="${ROOT_IMAGE}"
  fi
  export RESULT="${_result}"
}

# fun: find_parents repo
# api: public
# txt: Recursively finds all parents for a given repo.
# opt: repo: The repository.
# txt: Returns 0/TRUE always.
# txt: RESULT is a space-separated list with the parent images.
# use: find_parents "myImage"; parents="${RESULT}"; for p in ${parents}; do "Echo parent found: ${p}"; done
function find_parents() {
  local _repo="${1}"
  checkNotEmpty repo "${_repo}" 1
  local _result=()
  declare -a _result
  find_parent_repo "${_repo}"
  local _parent="${RESULT}"
  while ! isEmpty "${_parent}" && [[ "${_parent#.*/}" == "${_parent}" ]]; do
    _result[${#_result[@]}]="${_parent}"
    find_parent_repo "${_parent}"
    _parent="${RESULT}"
  done
  export RESULT="${_result[@]}"
}

# fun: resolve_base_image
# api: public
# txt: Resolves which base image should be used, depending on the architecture.
# txt: Returns 0/TRUE always.
# txt: BASE_IMAGE contains the correct base image.
# use: resolve_base_image; echo "the base image is ${BASE_IMAGE}";
function resolve_base_image() {
  if is_32bit; then
    export BASE_IMAGE="${BASE_IMAGE_32BIT}"
  else
    export BASE_IMAGE="${BASE_IMAGE_64BIT}"
  fi
}

# fun: loadRepoEnvironmentVariables repo+
# api: public
# txt: Loads image-specific environment variables, sourcing the build-settings.sh and .build-settings.sh files in the repo folder, if they exist.
# opt: repo: The repository.
# txt: Returns 0/TRUE always.
# use: echo 'defineEnvVar MY_VAR "My variable" "default value"' > myImage/build-settings.sh; loadRepoEnvironmentVariables "myImage"; echo "MY_VAR is ${MY_VAR}";
function loadRepoEnvironmentVariables() {
  local _repos="${1}"
  checkNotEmpty repo "${_repos}" 1
  local _repoSettings
  local _privateSettings
  local _oldIFS="${IFS}"
  local _f
  local _repo

  local _file

  checkNotEmpty "repositories" "${_repos}" 1

  DW.getScriptFolder
  local _scriptFolder="${RESULT}"

  IFS="${DWIFS}"
  local _repo
  for _repo in ${_repos}; do
    for _f in "${_scriptFolder}/${_repo}/build-settings.sh" \
      "./${_repo}/build-settings.sh"; do
      IFS="${_oldIFS}"
      if fileExists "${_f}"; then
        _repoSettings="${_f}"
      fi
    done

    IFS="${DWIFS}"
    for _f in "${_scriptFolder}/${_repo}/.build-settings.sh" \
      "./${_repo}/.build-settings.sh"; do
      IFS="${_oldIFS}"
      if fileExists "${_f}"; then
        _privateSettings="${_f}"
      fi
    done

    IFS="${DWIFS}"
    for _f in "${_repoSettings}" "${_privateSettings}"; do
      IFS="${_oldIFS}"
      if isNotEmpty "${_f}" && fileExists "${_f}"; then
        logTrace -n "Sourcing ${_f}"
        source "${_f}"
        if isTrue $?; then
          logTraceResult SUCCESS "done"
        else
          logTraceResult FAILURE "failed"
        fi
      fi
    done
    IFS="${_oldIFS}"
  done
  IFS="${_oldIFS}"
}

# fun: force_mode_enabled
# api: public
# txt: Checks whether the -f flag is enabled
# txt: Returns 0/TRUE if the flag is enabled; 1/FALSE otherwise.
# use: if force_mode_enabled; then "force-mode enabled"; fi
function force_mode_enabled() {
  flagEnabled FORCE_MODE
}

# fun: overwrite_latest_enabled
# api: public
# txt: Checks whether the -o flag is enabled
# txt: Returns 0/TRUE if the flag is enabled; 1/FALSE otherwise.
# use: if overwrite_latest_enabled; then echo "overwrite-latest enabled"; fi
function overwrite_latest_enabled() {
  flagEnabled OVERWRITE_LATEST
}

# fun: registry_push_enabled
# api: public
# txt: Checks whether the -p flag is enabled
# txt: Returns 0/TRUE if the flag is enabled; 1/FALSE otherwise.
# use: if registry_push_enabled; then echo "registry-push enabled"; fi
function registry_push_enabled() {
  flagEnabled REGISTRY_PUSH
}

# fun: registry_tag_enabled
# api: public
# txt: Checks whether the -rt flag is enabled
# txt: Returns 0/TRUE if the flag is enabled; 1/FALSE otherwise.
# use: if registry_tag_enabled; then echo "registry-tag enabled"; fi
function registry_tag_enabled() {
  flagEnabled REGISTRY_TAG
}

# fun: reduce_image_enabled
# api: public
# txt: Checks whether the -r flag is enabled
# txt: Returns 0/TRUE if the flag is enabled; 1/FALSE otherwise.
# use: if reduce_image_enabled; then echo "reduce-image enabled"; fi
function reduce_image_enabled() {
  flagEnabled REDUCE_IMAGE
}

# fun: cleanup_containers_enabled
# api: public
# txt: Checks whether the -cc flag is enabled.
# txt: Returns 0/TRUE if the flag is enabled; 1/FALSE otherwise.
# use: if cleanup_containers_enabled; then "cleanup-containers enabled"; fi
function cleanup_containers_enabled() {
  flagEnabled CLEANUP_CONTAINERS
}

# fun: cleanup_containers
# api: public
# txt: Cleans up the docker containers.
# txt: Returns 0/TRUE always.
# use: cleanup_containers
function cleanup_containers() {

  if cleanup_containers_enabled; then
    local _count="$(${DOCKER} ps -a -q | xargs -n 1 -I {} | wc -l)"
    #  _count=$((_count-1));
    if isGreaterThan ${_count} 0; then
      logInfo -n "Cleaning up ${_count} stale container(s)"
      ${DOCKER} ps -a -q | xargs -n 1 -I {} sudo docker rm -v {} >/dev/null
      if isTrue $?; then
        logInfoResult SUCCESS "done"
      else
        logInfoResult FAILED "failed"
      fi
    fi
  fi
}

# fun: cleanup_images_enabled
# api: public
# txt: Checks whether the -ci flag is enabled.
# txt: Returns 0/TRUE always.
# use: if cleanup_images_enabled; then echo "cleanup-images enabled"; fi
function cleanup_images_enabled() {
  flagEnabled CLEANUP_IMAGES
}

# fun: cleanup_images
# api: public
# txt: Cleans up unused docker images.
# txt: Returns 0/TRUE always.
# use: cleanup_images
function cleanup_images() {
  if cleanup_images_enabled; then
    local _count="$(${DOCKER} images | grep '<none>' | wc -l)"
    if isGreaterThan ${_count} 0; then
      logInfo -n "Trying to delete up to ${_count} unnamed image(s)"
      ${DOCKER} images | grep '<none>' | awk '{printf("docker rmi -f %s\n", $3);}' | sh >/dev/null
      if isTrue $?; then
        logInfoResult SUCCESS "done"
      else
        logInfoResult FAILED "failed"
      fi
    fi
  fi
}

## Script metadata and CLI settings.

setScriptDescription "Builds Docker images from templates, similar to wking's. If no repository (image folder) is specified, all repositories will be built"
setScriptLicenseSummary "Distributed under the terms of the GNU General Public License v3"
setScriptCopyright "Copyleft 2014-today Automated Computing Machinery S.L."

addCommandLineFlag "noCache" "nc" "Whether to use the cached images or not" OPTIONAL NO_ARGUMENT "false"
addCommandLineFlag "force" "f" "Whether to build the image even if it's already built" OPTIONAL NO_ARGUMENT "false"
addCommandLineFlag "overwriteLatest" "o" "Whether to overwrite the \"latest\" tag with the new one (default: false)" OPTIONAL NO_ARGUMENT "false"
addCommandLineFlag "registryTag" "rt" "Whether to tag also for pushing the image to the remote registry (implicit if -rp is enabled)" OPTIONAL NO_ARGUMENT "false"
addCommandLineFlag "registryPush" "rp" "Optionally, whether to push the image to a remote registry" OPTIONAL NO_ARGUMENT "false"
addCommandLineFlag "reduceImage" "ri" "Whether to reduce the size of the resulting image" OPTIONAL NO_ARGUMENT "false"
addCommandLineFlag "cleanupImages" "ci" "Whether to try to cleanup images" OPTIONAL NO_ARGUMENT "false"
addCommandLineFlag "cleanupContainers" "cc" "Whether to try to cleanup containers" OPTIONAL NO_ARGUMENT "false"
addCommandLineFlag "X:evalDefaults" "X:e" "Whether to eval all default values, which potentially slows down the script unnecessarily" OPTIONAL NO_ARGUMENT
addCommandLineParameter "repositories" "The repositories to build" MANDATORY MULTIPLE

DOCKER=$(which docker.io 2>/dev/null || which docker 2>/dev/null)

checkReq docker
checkReq head
checkReq grep
checkReq awk
addError DOCKER_SQUASH_NOT_INSTALLED "docker-squash is not installed. Check out https://github.com/jwilder/docker-squash for details"

addError NO_REPOSITORIES_FOUND "no repositories found"
addError INVALID_URL "Invalid url"
addError CANNOT_PROCESS_TEMPLATE "Cannot process template"
addError TEMPLATE_DOES_NOT_EXIST "Template does not exist: "
addError INCLUDED_FILE_NOT_FOUND "The included file is missing"
addError ERROR_BUILDING_REPOSITORY "Error building repository"
addError ERROR_TAGGING_IMAGE "Error tagging image"
addError ERROR_PUSHING_IMAGE "Error pushing image to ${REGISTRY}"
addError ERROR_REDUCING_IMAGE "Error reducing the image size"
addError LICENSE_FILE_IS_MANDATORY "LICENSE_FILE needs to be defined. Review build.inc.sh or .build.inc.sh"
addError CANNOT_COPY_LICENSE_FILE "Cannot copy the license file ${LICENSE_FILE}"
addError LICENSE_FILE_DOES_NOT_EXIST "The specified license ${LICENSE_FILE} does not exist"
addError COPYRIGHT_PREAMBLE_FILE_IS_MANDATORY "COPYRIGHT_PREAMBLE_FILE needs to be defined. Review build.inc.sh or .build.inc.sh"
addError CANNOT_COPY_COPYRIGHT_PREAMBLE_FILE "Cannot copy the license file ${COPYRIGHT_PREAMBLE_FILE}"
addError COPYRIGHT_PREAMBLE_FILE_DOES_NOT_EXIST "The specified copyright-preamble file ${COPYRIGHT_PREAMBLE_FILE} does not exist"
addError PARENT_REPO_NOT_AVAILABLE "The parent repository is not available"
addError CANNOT_CREATE_A_DEAD_CONTAINER "Cannot create a dead container"
addError CANNOT_COPY_FILE_TO_CONTAINER "Cannot copy file to the container"
addError CANNOT_COMMIT_CONTAINER "Cannot commit container as new image"
addError CANNOT_DELETE_CONTAINER "Cannot delete container"

function dw_parse_noCache_cli_flag() {
  if isTrue "${NO_CACHE}" || isEmpty "${1}" || isTrue "${1}"; then
    export NO_CACHE=${TRUE}
  else
    export NO_CACHE=${FALSE}
  fi
}

function dw_parse_registryPush_cli_flag() {
  local _flag="${1}"
  if isTrue "${REGISTRY_PUSH}" || isEmpty "${1}" || isTrue "${_flag}"; then
    export REGISTRY_PUSH=${TRUE}
  else
    export REGISTRY_PUSH=${FALSE}
  fi
}

function dw_parse_registryTag_cli_flag() {
  local _flag="${1}"
  if isTrue "${REGISTRY_TAG}" || isEmpty "${1}" || isTrue "${_flag}"; then
    export REGISTRY_TAG=${TRUE}
  else
    export REGISTRY_TAG=${FALSE}
  fi
}

function dw_parse_force_cli_flag() {
  if isTrue "${FORCE_MODE}" || isTrue "${1}" || isEmpty "${1}"; then
    export FORCE_MODE=${TRUE}
  else
    export FORCE_MODE=${FALSE}
  fi
}

function dw_parse_overwriteLatest_cli_flag() {
  if isTrue "${OVERWRITE_LATEST}" || isEmpty "${1}" || isTrue "${1}"; then
    export OVERWRITE_LATEST=${TRUE}
  else
    export OVERWRITE_LATEST=${FALSE}
  fi
}

function dw_parse_reduceImage_cli_flag() {
  if isTrue "${REDUCE_IMAGE}" || isEmpty "${1}" || isTrue "${1}"; then
    export REDUCE_IMAGE=${TRUE}
  else
    export REDUCE_IMAGE=${FALSE}
  fi
}

function dw_parse_cleanupImages_cli_flag() {
  if isTrue "${CLEANUP_IMAGES}" || isEmpty "${1}" || isTrue "${1}"; then
    export CLEANUP_IMAGES=${TRUE}
  else
    export CLEANUP_IMAGES=${FALSE}
  fi
}

function dw_parse_tag_cli_envvar() {
  if isEmpty "${TAG}"; then
    export TAG="${DATE}"
  fi
}

function dw_parse_repositories_cli_parameter() {
  if isEmpty "${REPOSITORIES}"; then
    export REPOSITORIES="$@"
  fi

  if isEmpty "${REPOSITORIES}"; then
    export REPOSITORIES="$(find . -maxdepth 1 -type d | grep -v '^\.$' | sed 's \./  g' | grep -v '^\.')"
  fi
}

setDebugEchoEnabled TRUE
setDebugLogFile "/tmp/build.log"
# env: processedTemplates: The list of processed templates.
declare -a __PROCESSED_TEMPLATES=()
# vim: syntax=sh ts=2 sw=2 sts=4 sr noet
