#!/bin/bash dry-wit
# Copyright 2014-today Automated Computing Machinery S.L.
# Distributed under the terms of the GNU General Public License v3

DW.import command;
DW.import envvar;

# Main logic. Gets called by dry-wit.
function main() {
  local _repo;
  local _parents;
  local _buildRepo;
  local _oldIFS="${IFS}";

  resolve_base_image
  IFS="${DWIFS}";
  for _repo in ${REPOSITORIES}; do
    IFS="${_oldIFS}";
    _buildRepo=${FALSE};
    if force_mode_enabled; then
      _buildRepo=${TRUE};
    elif ! repo_exists "${_repo}" "${TAG}"; then
      _buildRepo=${TRUE};
    else
      retrieveNamespace;
      local _namespace="${RESULT}";
       logInfo -n "Not building ${_namespace}/${_repo}:${TAG} since it's already built";
      logInfoResult SUCCESS "skipped";
    fi
    if isTrue ${_buildRepo}; then
      find_parents "${_repo}"
      _parents="${RESULT}"
      IFS="${DWIFS}";
      for _parent in ${_parents}; do
        IFS="${_oldIFS}";
        build_repo_if_defined_locally "${_parent}";
      done
      IFS="${_oldIFS}";

      build_repo "${_repo}";
    fi
    if registry_tag_enabled; then
        registry_tag "${_repo}" "${TAG}";
        if overwrite_latest_enabled; then
            registry_tag "${_repo}" "latest";
        fi
    fi
    if registry_push_enabled; then
      registry_push "${_repo}" "${TAG}";
      if overwrite_latest_enabled; then
        registry_push "${_repo}" "latest";
      fi
    fi
  done
  IFS="${_oldIFS}";
  cleanup_containers;
  cleanup_images;
}

## Retrieves the namespace.
## - 0/${TRUE} if the namespace gets built successfully; 1/${FALSE} otherwise.
## Example:
##   if retrieveNamespace "bla"; then
##     echo "Namespace for bla";
##   fi
function retrieveNamespace() {
  local _flavor="";

  if ! isEmpty "${SETSQUARE_FLAVOR}"; then
    _flavor="-${SETSQUARE_FLAVOR}";
  fi

  export RESULT="${NAMESPACE}${_flavor}";
  return ${TRUE};
}

## Does "${NAMESPACE}/${REPO}:${TAG}" exist?
## -> 1: the repository.
## -> 2: the tag.
## <- 0 if it exists, 1 otherwise
## Example:
##   if repo_exists "myImage" "latest"; then [..]; fi
function repo_exists() {
  local _repo="${1}";
  local _tag="${2}";
  local _aux;

  checkNotEmpty "repository" "${_repo}" 1;
  checkNotEmpty "tag" "${_tag}" 2;

  if _evalEnvVar "${_tag}"; then
    _aux="${RESULT}";
    if isNotEmpty "${_aux}"; then
      _tag="${_aux}";
    fi
  fi

  retrieveNamespace;
  local _namespace="${RESULT}";
  local _images=$(${DOCKER} images "${_namespace}/${_repo}")
  local _matches=$(echo "${_images}" | grep -- "${_tag}");
  local -i _rescode;

  if isEmpty "${_matches}"; then
      _rescode=${FALSE};
  else
    _rescode=${TRUE};
  fi

  return ${_rescode};
}

## Builds the image if it's defined locally.
## -> 1: the repository.
## Example:
##   build_repo_if_defined_locally "myImage:latest";
function build_repo_if_defined_locally() {
  local _repo="${1}";
  local _name="${_repo%:*}";
  local _tag="${_repo#*:}";
  retrieveNamespace;
  local _namespace;

  if ! isEmpty "${_name}" && \
     [[ -d ${_name} ]] && \
     ! repo_exists "${_name#${_namespace}/}" "${_tag}"; then
      build_repo "${_name}"
  fi
}

## Squashes the image with docker-squash [1]
## [1] https://github.com/jwilder/docker-squash
## -> 1: the namespace.
## -> 2: the repo name.
## -> 3: the current tag.
## -> 4: the new tag for the squashed image.
## Example:
##   reduce_image_size "namespace" "myimage" "201508-raw" "201508"
function reduce_image_size() {
  local _namespace="${1}";
  local _repo="${2}";
  local _currentTag="${3}";
  local _tag="${4}";
  checkReq docker-squash DOCKER_SQUASH_NOT_INSTALLED;

  checkNotEmpty "namespace" "${_namespace}" 1;
  checkNotEmpty "repository" "${_repo}" 2;
  checkNotEmpty "currentTag" "${_currentTag}" 3;
  checkNotEmpty "tag" "${_tag}" 4;

  logInfo -n "Squashing ${_image} as ${_namespace}/${_repo}:${_tag}"
  ${DOCKER} save "${_namespace}/${_repo}:${_currentTag}" | sudo docker-squash -t "${_namespace}/${_repo}:${_tag}" | ${DOCKER} load
  if isTrue $?; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_REDUCING_IMAGE "${_namespace}/${_repo}:${_currentTag}";
  fi
}

## Processes given file.
## -> 1: the input file.
## -> 2: the output file.
## -> 3: the repo folder.
## -> 4: the templates folder.
## -> 5: the image.
## -> 6: the root image.
## -> 7: the namespace.
## -> 8: the tag.
## -> 10: the backup host's SSH port (optional).
## <- 0: if the file is processed correctly; 1 otherwise.
## Example:
##  if process_file "my.template" "my" "my-image-folder" ".templates"; then
##    echo "File processed successfully";
##  fi
function process_file() {
  local _file="${1}";
  local _output="${2}";
  local _repoFolder="${3}";
  local _templateFolder="${4}";
  local _repo="${5}";
  local _rootImage="${6}";
  local _namespace="${7}";
  local _backupHostSshPort="${10:-22}";
  local -i _rescode=${FALSE};

  local _temp1;
  local _temp2;

  checkNotEmpty "file" "${_file}" 1;
  checkNotEmpty "output" "${_output}" 2;
  checkNotEmpty "repoFolder" "${_repoFolder}" 3;
  checkNotEmpty "templateFolder" "${_templateFolder}" 4;
  checkNotEmpty "repository" "${_repo}" 5;
  checkNotEmpty "rootImage" "${_rootImage}" 6;
  checkNotEmpty "namespace" "${_namespace}" 7;

  local _settingsFile="$(dirname ${_file})/$(basename ${_file} .template).settings";

  if createTempFile; then
      _temp1="${RESULT}";
  fi

  if createTempFile; then
      _temp2="${RESULT}";
  fi

  if isNotEmpty "${_temp1}" && isNotEmpty "${_temp2}" && \
     resolve_includes "${_file}" "${_temp1}" "${_repoFolder}" "${_templateFolder}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
      logTrace -n "Resolving @include_env in ${_file}";
      if resolve_include_env "${_temp1}" "${_temp2}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
          logTraceResult SUCCESS "done";
          if [ -e "${_settingsFile}" ]; then
              process_settings_file "${_settingsFile}";
          fi
          if process_placeholders "${_temp2}" "${_output}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
              _rescode=${TRUE};
              logTraceResult SUCCESS "done"
          else
            _rescode=${FALSE};
            logTraceResult FAILURE "failed";
          fi
      else
        _rescode=${FALSE};
        logTraceResult FAILURE "failed";
      fi
  else
    _rescode=${FALSE};
  fi

  return ${_rescode};
}

## Resolves given included file.
## -> 1: The file name.
## -> 2: The templates folder.
## -> 3: The repository's own folder.
## <- 0: if the file is found; 1 otherwise.
## Example:
##   if ! resolve_included_file "footer" "my-image-folder" ".templates"; then
##     echo "'footer' not found";
##   fi
function resolve_included_file() {
  local _file="${1}";
  local _repoFolder="${2}";
  local _templatesFolder="${3}";
  local _result;
  local _rescode=${FALSE};
  local d;
  local _oldIFS="${IFS}";

  checkNotEmpty "file" "${_file}" 1;
  checkNotEmpty "repoFolder" "${_repoFolder}" 2;
  checkNotEmpty "templatesFolder" "${_templatesFolder}" 3;

  IFS=$' \t\n';
  for d in "${_templatesFolder}"; do
    IFS="${_oldIFS}";
    if    [[ -f "${d}/${_file}" ]] \
       || [[ -f "${d}/$(basename ${_file} .template).template" ]]; then
      _result="${d}/${_file}";
      export RESULT="${_result}";
      _rescode=${TRUE};
      break;
    fi
  done
  IFS="${_oldIFS}";

  if isFalse ${_rescode}; then
    if [[ $(eval "echo ${_file}") != "${_file}" ]]; then
      resolve_included_file "$(eval "echo ${_file}")" "${_repoFolder}" "${_templatesFolder}";
      _rescode=$?;
    fi
  fi

  return ${_rescode};
}

## Resolves any @include in given file.
## -> 1: the input file.
## -> 2: the output file.
## -> 3: the templates folder.
## -> 4: the repository folder.
## -> 5: the image.
## -> 6: the root image.
## -> 7: the namespace.
## -> 8: the backup host's SSH port for this image (optional).
## <- 0: if the @include()s are resolved successfully; 1 otherwise.
## Example:
##  resolve_includes "my.template" "my" "my-image-folder" ".templates" "myImage" "myRoot" "example" "latest" "22"
function resolve_includes() {
  local _input="${1}";
  local _output="${2}";
  local _repoFolder="${3}";
  local _templateFolder="${4}";
  local _repo="${5}";
  local _rootImage="${6}";
  local _namespace="${7}";
  local _backupHostSshPort="${8:-22}";
  local _rescode;
  local _match;
  local _includedFile;
  local line;
  local _folder;
  local _files;

  checkNotEmpty "input" "${_input}" 1;
  checkNotEmpty "output" "${_output}" 2;
  checkNotEmpty "repoFolder" "${_repoFolder}" 3;
  checkNotEmpty "templateFolder" "${_templateFolder}" 4;
  checkNotEmpty "repository" "${_repo}" 5;
  checkNotEmpty "rootImage" "${_rootImage}" 6;
  checkNotEmpty "namespace" "${_namespace}" 7;

  logTrace -n "Resolving @include()s in ${_input}";

  echo -n '' > "${_output}";

  while IFS='' read -r line; do
    _match=${FALSE};
    _includedFile="";
    if    [[ "${line#@include(\"}" != "$line" ]] \
       && [[ "${line%\")}" != "$line" ]]; then
      _ref="$(echo "$line" | sed 's/@include(\"\(.*\)\")/\1/g')";
      if resolve_included_file "${_ref}" "${_repoFolder}" "${_templateFolder}"; then
          _includedFile="${RESULT}";
          if [ -d "${_templateFolder}/$(basename ${_includedFile})-files" ]; then
              mkdir "${_repoFolder}/$(basename ${_includedFile})-files" 2> /dev/null;
              rsync -azI "${PWD}/${_templateFolder#\./}/$(basename ${_includedFile})-files/" "${_repoFolder}/$(basename ${_includedFile})-files/"
              _folder="${_repoFolder}/$(basename ${_includedFile})-files";
              if folderExists "${_folder}"; then
#                  shopt -s nullglob dotglob;
                  _files=($(find "${_folder}" -type f -name '*.template' 2> /dev/null));
#                  shopt -u nullglob dotglob;
                  if [ ${#_files[@]} -gt 0 ]; then
                      for p in ${_files}; do
                          IFS="${_oldIFS}";
                          process_file "${p}" "$(dirname ${p})/$(basename ${p} .template)" "${_repoFolder}" "${_templateFolder}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}";
                      done
                      IFS="${_oldIFS}";
                  fi
              fi
          fi
          if [ -e "${_includedFile}.template" ]; then
              if process_file "${_includedFile}.template" "${_includedFile}" "${_repoFolder}" "${_templateFolder}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
                  _match=${TRUE};
              else
                _match=${FALSE};
                logTraceResult FAILURE "failed";
                exitWithErrorCode CANNOT_PROCESS_TEMPLATE "${_includedFile}";
              fi
          elif [ -e "${_includedFile}.settings" ]; then
              if process_settings_file "${_includedFile}.settings"; then
                  _match=${TRUE};
              else
                _match=${FALSE};
                logTraceResult FAILURE "failed";
                exitWithErrorCode CANNOT_PROCESS_TEMPLATE "${_includedFile}.settings";
              fi
          else
            _match=${TRUE};
          fi
      elif ! fileExists "${_ref}.template"; then
          logTraceResult FAILURE "failed";
          exitWithErrorCode CANNOT_PROCESS_TEMPLATE "${_ref}";
      else
        _match=${FALSE};
        _errorRef="${_ref}";
        eval "echo ${_ref}" > /dev/null 2>&1;
        if isTrue $?; then
          _errorRef="${_input} contains ${_ref} with evaluates to $(eval "echo ${_ref}" 2> /dev/null), and it's not found in any of the expected paths: ${_repoFolder}, ${_templateFolder}";
        fi
      fi
    fi
    if isTrue ${_match}; then
        cat "${_includedFile}" >> "${_output}";
    else
      echo "$line" >> "${_output}";
    fi
  done < "${_input}";
  _rescode=$?;
  if isEmpty "${_errorRef}" && isTrue ${_rescode}; then
      logTraceResult SUCCESS "done";
  else
    logTraceResult FAILURE "failed";
  fi

  return ${_rescode};
}

## Processes a settings file for a template.
## -> 1: The settings file.
## <- 0/${TRUE} if the settings file was processed successfully; 1/${FALSE} otherwise.
## Example:
##   if process_settings_file "my.settings"; then
##     echo "my.settings processed successfully";
##   fi
function process_settings_file() {
  local _file="${1}";
  local -i _rescode=${FALSE};

  checkNotEmpty "file" "${_file}" 1;

  logInfo -n "Reading ${_file}";
  source "${_file}";
  _rescode=$?;
  if isTrue ${_rescode}; then
      logInfoResult SUCCESS "done";
  else
    logInfoResult FAILURE "failed";
  fi

  return ${_rescode};
}

## Processes placeholders in given file.
## -> 1: the input file.
## -> 2: the output file.
## -> 3: the image.
## -> 4: the root image.
## -> 5: the namespace.
## -> 6: the tag.
## -> 8: the backup host's SSH port (optional).
## <- 0 if the file was processed successfully; 1 otherwise.
## Example:
##  if process_placeholders my.template" "my" "myImage" "root" "example" "latest" "" "2222"; then
##    echo "my.template -> my";
##  fi
function process_placeholders() {
  local _file="${1}";
  local _output="${2}";
  local _repo="${3}";
  local _rootImage="${4}";
  local _namespace="${5}";
  local _backupHostSshPort="${6:-22}";
  local _rescode;
  local i;

  checkNotEmpty "file" "${_file}" 1;
  checkNotEmpty "output" "${_output}" 2;
  checkNotEmpty "repository" "${_repo}" 3;
  checkNotEmpty "rootImage" "${_rootImage}" 4;
  checkNotEmpty "namespace" "${_namespace}" 5;

  local _env="$( \
    for ((i = 0; i < ${#__DW_ENVVAR_ENV_VARIABLES[*]}; i++)); do \
      if [ \"${__DW_ENVVAR_ENV_VARIABLES[$i]}\" != \"\" ]; then
        echo ${__DW_ENVVAR_ENV_VARIABLES[$i]} | awk -v dollar="$" -v quote="\"" '{printf("echo  %s=\\\"%s%s{%s}%s\\\"", $0, quote, dollar, $0, quote);}' | sh; \
      fi \
    done;) DATE=\"${DATE}\" TIME=\"${TIME}\" MAINTAINER=\"${AUTHOR} <${AUTHOR_EMAIL}>\" STACK=\"${STACK}\" REPO=\"${_repo}\" IMAGE=\"${_repo}\" ROOT_IMAGE=\"${_rootImage}\" BASE_IMAGE=\"${BASE_IMAGE}\" NAMESPACE=\"${_namespace}\" BACKUP_HOST_SSH_PORT=\"${_backupHostSshPort}\" DOLLAR='$' ";

  local _envsubstDecl=$(echo -n "'"; echo -n "$"; echo -n "{_tag} $"; echo -n "{DATE} $"; echo -n "{TIME} $"; echo -n "{MAINTAINER} $"; echo -n "{STACK} $"; echo -n "{REPO} $"; echo -n "{IMAGE} $"; echo -n "{ROOT_IMAGE} $"; echo -n "{BASE_IMAGE} $"; echo -n "{NAMESPACE} $"; echo -n "{BACKUP_HOST_SSH_PORT} $"; echo -n "{DOLLAR}"; echo ${__DW_ENVVAR_ENV_VARIABLES[*]} | tr ' ' '\n' | awk '{printf("${%s} ", $0);}'; echo -n "'";);

  echo "${_env} envsubst ${_envsubstDecl} < ${_file}" | sh > "${_output}";
  _rescode=$?;

  return ${_rescode};
}

## Resolves any @include_env in given file.
## -> 1: the input file.
## -> 2: the output file.
## -> 3: the image.
## -> 4: the root image.
## -> 5: the namespace.
## -> 6: the backup host SSH port (optional).
## <- 0/${TRUE}: if the @include_env is resolved successfully; 1/${FALSE} otherwise.
## Example:
##  resolve_include_env "my.template" "my"
function resolve_include_env() {
  local _input="${1}";
  local _output="${2}";
  local _image="${3}";
  local _rootImage="${4}";
  local _namespace="${5}";
  local _backupHostSshPort="${6:-22}";
  local _includedFile;
  local -i _rescode;
  local _envVar;
  local line;
  local -a _envVars=();
  local -i i;
  local _oldIFS="${IFS}";

  for ((i = 0; i < ${#__DW_ENVVAR_ENV_VARIABLES[*]}; i++)); do \
    _envVars[${i}]="${__DW_ENVVAR_ENV_VARIABLES[${i}]}";
  done
  _envVars[${#_envVars[*]}]="IMAGE";
  _envVars[${#_envVars[*]}]="DATE";
  _envVars[${#_envVars[*]}]="TIME";
  _envVars[${#_envVars[*]}]="MAINTAINER";
  _envVars[${#_envVars[*]}]="AUTHOR";
  _envVars[${#_envVars[*]}]="AUTHOR_EMAIL";
  _envVars[${#_envVars[*]}]="STACK";
  _envVars[${#_envVars[*]}]="ROOT_IMAGE";
  _envVars[${#_envVars[*]}]="BASE_IMAGE";
  _envVars[${#_envVars[*]}]="STACK_SUFFIX";
  _envVars[${#_envVars[*]}]="NAMESPACE";
  _envVars[${#_envVars[*]}]="BACKUP_HOST_SSH_PORT";

  logTrace -n "Resolving @include_env in ${_input}";

  echo -n '' > "${_output}";

  while IFS='' read -r line; do
    IFS="${_oldIFS}";
    _includedFile="";
    if [[ "${line#@include_env}" != "$line" ]]; then
      echo -n "ENV " >> "${_output}";
      for ((i = 0; i < ${#_envVars[*]}; i++)); do \
        _envVar="${_envVars[$i]}";
        if [ "${_envVar#ENABLE_}" == "${_envVar}" ]; then
          if [ $i -ne 0 ]; then
            echo >> "${_output}";
            echo -n "    " >> "${_output}";
          fi
          echo "${_envVar}" | awk -v dollar="$" -v quote="\"" '{printf("echo -n \"SQ_%s=\\\"%s%s{%s}%s\\\"\"", $0, quote, dollar, $0, quote);}' | sh >> "${_output}"
          if [ $i -lt $((${#_envVars[@]} - 1)) ]; then
            echo -n " \\" >> "${_output}";
          fi
        fi
      done
      echo >> "${_output}";
    elif [[ "${line# +}" == "${line}" ]]; then
      echo "$line" >> "${_output}";
    fi
  done < "${_input}";
  _rescode=$?;
  if isTrue ${_rescode}; then
    logTraceResult SUCCESS "done";
  else
    logTraceResult FAILURE "failed";
  fi
  return ${_rescode};
}

## Updates the log category to include the current image.
## -> 1: the image.
## Example:
##   update_log_category "mysql"
function update_log_category() {
  local _image="${1}";
  local _logCategory;
  getLogCategory;
  _logCategory="${RESULT%/*}/${_image}";
  setLogCategory "${_logCategory}";
}

## PUBLIC
## Copies the license file from specified folder to the repository folder.
## -> 1: the repository.
## -> 2: the folder where the license file is included.
## Example:
##   copy_license_file "myImage" ${PWD}
function copy_license_file() {
  local _repo="${1}";
  local _folder="${2}";

  checkNotEmpty "repo" "${_repo}" 1;
  checkNotEmpty "folder" "${_folder}" 2;

  if isEmpty "${LICENSE_FILE}"; then
      exitWithErrorCode LICENSE_FILE_IS_MANDATORY;
  fi

  if fileExists "${_folder}/${LICENSE_FILE}"; then
    logDebug -n "Using ${LICENSE_FILE} for ${_repo} image";
    cp "${_folder}/${LICENSE_FILE}" "${_repo}/LICENSE";
    if isTrue $?; then
      logDebugResult SUCCESS "done";
    else
      logDebugResult FAILURE "failed";
      exitWithErrorCode CANNOT_COPY_LICENSE_FILE;
    fi
  else
    exitWithErrorCode LICENSE_FILE_DOES_NOT_EXIST "${_folder}/${LICENSE_FILE}";
  fi
}

## PUBLIC
## Copies the copyright-preamble file from specified folder to the repository folder.
## -> 1: the repository.
## -> 2: the folder where the copyright preamble file is included.
## Example:
##   copy_copyright_preamble_file "myImage" ${PWD}
function copy_copyright_preamble_file() {
  local _repo="${1}";
  local _folder="${2}";

  checkNotEmpty "repo" "${_repo}" 1;
  checkNotEmpty "folder" "${_folder}" 2;

  if isEmpty "${COPYRIGHT_PREAMBLE_FILE}"; then
      exitWithErrorCode COPYRIGHT_PREAMBLE_FILE_IS_MANDATORY;
  fi

  if fileExists "${_folder}/${COPYRIGHT_PREAMBLE_FILE}"; then
      logDebug -n "Using ${COPYRIGHT_PREAMBLE_FILE} for ${_repo} image";
      cp "${_folder}/${COPYRIGHT_PREAMBLE_FILE}" "${_repo}/${COPYRIGHT_PREAMBLE_FILE}";
      if isTrue $?; then
          logDebugResult SUCCESS "done";
      else
        logDebugResult FAILURE "failed";
        exitWithErrorCode CANNOT_COPY_COPYRIGHT_PREAMBLE_FILE;
      fi
  else
    exitWithErrorCode COPYRIGHT_PREAMBLE_FILE_DOES_NOT_EXIST "${_folder}/${COPYRIGHT_PREAMBLE_FILE}";
  fi
}

## PUBLIC
## Resolves the BACKUP_HOST_SSH_PORT variable.
## -> 1: the image.
## <- RESULT: the value of such variable.
## Example:
##   retrieve_backup_host_ssh_port mariadb;
##   export BACKUP_HOST_SSH_PORT="${RESULT}";f
function retrieve_backup_host_ssh_port() {
  local _repo="${1}";
  local _result;

  checkNotEmpty "repo" "${_repo}" 1;

  if fileExists "${SSHPORTS_FILE}"; then
      logDebug -n "Retrieving the ssh port of the backup host for ${_repo}";
      _result="$(echo -n ''; (grep -e ${_repo} ${SSHPORTS_FILE} || echo ${_repo} 22) | awk '{print $2;}' | head -n 1)";
      if isTrue $?; then
          logDebugResult SUCCESS "${_result}";
          export RESULT="${_result}";
      else
        logDebugResult FAILURE "not-found";
      fi
  else
    _result="";
  fi
}

## PUBLIC
## Builds "${NAMESPACE}/${REPO}:${TAG}" image.
## -> 1: the repository.
## Example:
##  build_repo "myImage" "latest" "";
function build_repo() {
  local _repo="${1}";
  local _canonicalTag="${2}";
  local _tag;
  local _cmdResult;
  local _rootImage;
  local _f;
  retrieveNamespace;
  local _namespace="${RESULT}";
  local _oldIFS="${IFS}";

  checkNotEmpty "repo" "${_repo}" 1;

  retrieve_backup_host_ssh_port "${_repo}";
  local _backupHostSshPort="${RESULT:-22}";
  if is_32bit; then
    _rootImage="${ROOT_IMAGE_32BIT}:${ROOT_IMAGE_VERSION}";
  else
    _rootImage="${ROOT_IMAGE_64BIT}:${ROOT_IMAGE_VERSION}";
  fi
  update_log_category "${_repo}";

  defineEnvVar IMAGE MANDATORY "The image to build" "${_repo}";

  copy_license_file "${_repo}" "${PWD}";
  copy_copyright_preamble_file "${_repo}" "${PWD}";

  if [ $(ls ${_repo}/*.template | grep -e '\.template$' | grep -v -e 'Dockerfile\.template$' | wc -l) -gt 0 ]; then
    IFS="${DWIFS}";
    for _f in $(ls ${_repo} | grep -e '\.template$' | grep -v -e 'Dockerfile\.template$'); do
      IFS="${_oldIFS}";
      logDebug -n "Processing ${_repo}/${_f}";
      if process_file "${_repo}/${_f}" "${_repo}/$(basename ${_f} .template)" "${_repo}" "${INCLUDES_FOLDER}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
        logDebugResult SUCCESS "done";
      else
        logDebugResult FAILURE "failed";
        exitWithErrorCode CANNOT_PROCESS_TEMPLATE "${_repo}/${_f}";
      fi
    done
    IFS="${_oldIFS}";
  fi

  loadRepoEnvironmentVariables "${_repo}";
  evalEnvVars;
  if reduce_image_enabled; then
    _rawTag="${TAG}-raw";
  else
    _tag="${TAG}";
  fi
  _f="${_repo}/Dockerfile.template";
  logDebug -n "Processing ${_f}";
  if process_file "${_f}" "${_repo}/$(basename ${_f} .template)" "${_repo}" "${INCLUDES_FOLDER}" "${_repo}" "${_rootImage}" "${_namespace}" "${_backupHostSshPort}"; then
    logDebugResult SUCCESS "done";
  else
    logDebugResult FAILURE "failed";
    exitWithErrorCode CANNOT_PROCESS_TEMPLATE "${_f}";
  fi

  logInfo "Building ${_namespace}/${_repo}:${_tag}";
#  echo docker build ${BUILD_OPTS} -t "${_namespace}/${_repo}:${_tag}" --rm=true "${_repo}"
  runCommandLongOutput "${DOCKER} build ${BUILD_OPTS} -t ${_namespace}/${_repo}:${_tag} --rm=true ${_repo}";
  _cmdResult=$?
  logInfo -n "${_namespace}/${_repo}:${_tag}";
  if isTrue ${_cmdResult}; then
    logInfoResult SUCCESS "built"
  else
    logInfoResult FAILURE "not built"
    exitWithErrorCode ERROR_BUILDING_REPOSITORY "${_repo}";
  fi
  if reduce_image_enabled; then
    reduce_image_size "${_namespace}" "${_repo}" "${_tag}" "${_canonicalTag}";
  fi
  if overwrite_latest_enabled; then
    logInfo -n "Tagging ${_namespace}/${_repo}:${_tag} as ${_namespace}/${_repo}:latest"
    docker tag "${_namespace}/${_repo}:${_tag}" "${_namespace}/${_repo}:latest"
    if isTrue $?; then
      logInfoResult SUCCESS "${_namespace}/${_repo}:latest";
    else
      logInfoResult FAILURE "failed"
      exitWithErrorCode ERROR_TAGGING_IMAGE "${_repo}";
    fi
  fi
}

## Tags the image anticipating it will be pushed to a Docker registry later.
## -> 1: the repository.
## -> 2: the tag.
## Example:
##   registry_tag "myImage" "latest"
function registry_tag() {
  local _repo="${1}";
  local _tag="${2}";

  checkNotEmpty "repository" "${_repo}" 1;
  checkNotEmpty "tag" "${_tag}" 2;

  retrieveNamespace;
  local _namespace="${RESULT}";
  local _remoteTag="${REGISTRY}/${REGISTRY_NAMESPACE}/${_repo}:${_tag}";
  if isTrue ${PUSH_TO_DOCKERHUB}; then
    _remoteTag="${REGISTRY}/${_repo}:${_tag}";
  fi

  update_log_category "${_repo}";
  logInfo -n "Tagging ${_namespace}/${_repo}:${_tag} as ${_remoteTag}";
  docker tag ${DOCKER_TAG_OPTIONS} "${_namespace}/${_repo}:${_tag}" "${_remoteTag}";
  if isTrue $?; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_TAGGING_IMAGE "${_repo}";
  fi
}

## Pushes the image to a Docker registry.
## -> 1: the repository.
## -> 2: the tag.
## Example:
##   registry_push "myImage" "latest"
function registry_push() {
  local _repo="${1}";
  local _tag="${2}";

  checkNotEmpty "repository" "${_repo}" 1;
  checkNotEmpty "tag" "${_tag}" 2;

  local _remoteTag="${REGISTRY}/${REGISTRY_NAMESPACE}/${_repo}:${_tag}";
  if isTrue ${PUSH_TO_DOCKERHUB}; then
    _remoteTag="${REGISTRY}/${_repo}:${_tag}";
  fi

  local -i _pushResult;
  update_log_category "${_repo}";

  logInfo -n "Pushing ${_remoteTag}";
  docker push "${_remoteTag}"
  _pushResult=$?;
  if isTrue ${_pushResult}; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_PUSHING_IMAGE "${_remoteTag}"
  fi
}

## Finds out if the architecture is 32 bits.
## <- 0 if 32b, 1 otherwise.
## Example:
##   if is_32bit; then [..]; fi
function is_32bit() {
  [ "$(uname -m)" == "i686" ]
}

## Finds the parent image for a given repo.
## -> 1: the repository.
## <- RESULT: the parent, if any, with the format name:tag.
## Example:
##   find_parent_repo "myImage"
##   parent="${RESULT}"
function find_parent_repo() {
  local _repo="${1}"
  local _result="$(grep -e '^FROM ' ${_repo}/Dockerfile.template 2> /dev/null | head -n 1 | awk '{print $2;}')";

  retrieveNamespace;
  local _namespace;
  if isNotEmpty ${_result} && [[ "${_result#\$\{_namespace\}/}" != "${_result}" ]]; then
    # parent under our namespace
   _result="${_result#\$\{_namespace\}/}";
  fi
  if isNotEmpty "${_result}" && isEmpty "${_result#\$\{BASE_IMAGE\}}"; then
    _result=$(echo ${BASE_IMAGE} | awk -F'/' '{print $2;}')
  fi
  if isNotEmpty "${_result}" && isEmpty "${_result#\$\{ROOT_IMAGE\}}"; then
    _result="${ROOT_IMAGE}";
  fi
  export RESULT="${_result}";
}

## Recursively finds all parents for a given repo.
## -> 1: the repository.
## <- RESULT: a space-separated list with the parent images.
## Example:
##   find_parents "myImage"
##   parents="${RESULT}"
##   for p in ${parents}; do [..]; done
function find_parents() {
  local _repo="${1}"
  local _result=();
  declare -a _result;
  find_parent_repo "${_repo}";
  local _parent="${RESULT}"
  while ! isEmpty "${_parent}" && [[ "${_parent#.*/}" == "${_parent}" ]]; do
    _result[${#_result[@]}]="${_parent}"
    find_parent_repo "${_parent}"
    _parent="${RESULT}"
  done;
  export RESULT="${_result[@]}"
}

## Resolves which base image should be used,
## depending on the architecture.
## Example:
##   resolve_base_image;
##   echo "the base image is ${BASE_IMAGE}"
function resolve_base_image() {
  if is_32bit; then
    export BASE_IMAGE="${BASE_IMAGE_32BIT}";
  else
    export BASE_IMAGE="${BASE_IMAGE_64BIT}";
  fi
}

## Loads image-specific environment variables,
## sourcing the build-settings.sh and .build-settings.sh files
## in the repo folder, if they exist.
## -> 1: The repository.
## Example:
##   echo 'defineEnvVar MY_VAR "My variable" "default value"' > myImage/build-settings.sh
##   loadRepoEnvironmentVariables "myImage"
##   echo "MY_VAR is ${MY_VAR}"
function loadRepoEnvironmentVariables() {
  local _repos="${1}";
  local _repoSettings;
  local _privateSettings;
  local _oldIFS="${IFS}";

  checkNotEmpty "repositories" "${_repos}" 1;

  IFS="${DWIFS}";
  for _repo in ${_repos}; do
    for f in "${DRY_WIT_SCRIPT_FOLDER}/${_repo}/build-settings.sh" \
             "./${_repo}/build-settings.sh"; do
      IFS="${_oldIFS}";
      if [ -e "${f}" ]; then
          _repoSettings="${f}";
      fi
    done

    IFS="${DWIFS}";
    for f in "${DRY_WIT_SCRIPT_FOLDER}/${_repo}/.build-settings.sh" \
             "./${_repo}/.build-settings.sh"; do
      IFS="${_oldIFS}";
      if fileExists "${f}"; then
          _privateSettings="${f}";
      fi
    done

    IFS="${DWIFS}";
    for f in "${_repoSettings}" "${_privateSettings}"; do
      IFS="${_oldIFS}";
      if fileExists "${f}"; then
          logTrace -n "Sourcing ${f}";
          source "${f}";
          if isTrue $?; then
            logTraceResult SUCCESS "done";
          else
            logTraceResult FAILURE "failed";
          fi
      fi
    done
    IFS="${_oldIFS}";
  done
  IFS="${_oldIFS}";
}

## Checks whether the -f flag is enabled
## Example:
##   if force_mode_enabled; then [..]; fi
function force_mode_enabled() {
  flagEnabled FORCE_MODE;
}

## Checks whether the -o flag is enabled
## Example:
##   if overwrite_latest_enabled; then [..]; fi
function overwrite_latest_enabled() {
  flagEnabled OVERWRITE_LATEST;
}

## Checks whether the -p flag is enabled
## Example:
##   if registry_push_enabled; then [..]; fi
function registry_push_enabled() {
  flagEnabled REGISTRY_PUSH;
}

## Checks whether the -rt flag is enabled
## Example:
##   if registry_tag_enabled; then [..]; fi
function registry_tag_enabled() {
  flagEnabled REGISTRY_TAG;
}

## Checks whether the -r flag is enabled
## Example:
##   if reduce_image_enabled; then [..]; fi
function reduce_image_enabled() {
  flagEnabled REDUCE_IMAGE;
}

## Checks whether the -cc flag is enabled.
## Example:
##   if cleanup_containers_enabled; then [..]; fi
function cleanup_containers_enabled() {
  flagEnabled CLEANUP_CONTAINERS;
}

## Cleans up the docker containers
## Example:
##   cleanup_containers
function cleanup_containers() {

  if cleanup_containers_enabled; then
    local _count="$(${DOCKER} ps -a -q | xargs -n 1 -I {} | wc -l)";
    #  _count=$((_count-1));
    if [ ${_count} -gt 0 ]; then
      logInfo -n "Cleaning up ${_count} stale container(s)";
      ${DOCKER} ps -a -q | xargs -n 1 -I {} sudo docker rm -v {} > /dev/null;
      if isTrue $?; then
        logInfoResult SUCCESS "done";
      else
        logInfoResult FAILED "failed";
      fi
    fi
  fi
}

## Checks whether the -ci flag is enabled.
## Example:
##   if cleanup_images_enabled; then [..]; fi
function cleanup_images_enabled() {
  flagEnabled CLEANUP_IMAGES;
}

## Cleans up unused docker images.
## Example:
##   cleanup_images
function cleanup_images() {
  if cleanup_images_enabled; then
    local _count="$(${DOCKER} images | grep '<none>' | wc -l)";
    if [ ${_count} -gt 0 ]; then
      logInfo -n "Trying to delete up to ${_count} unnamed image(s)";
      ${DOCKER} images | grep '<none>' | awk '{printf("docker rmi -f %s\n", $3);}' | sh > /dev/null
      if [ $? -eq 0 ]; then
        logInfoResult SUCCESS "done";
      else
        logInfoResult FAILED "failed";
      fi
    fi
  fi
}

## Script metadata and CLI settings.

setScriptDescription "Builds Docker images from templates, similar to wking's. If no repository (image folder) is specified, all repositories will be built.";
addCommandLineFlag "tag" "t" "The tag to use once the image is built successfully" OPTIONAL EXPECTS_ARGUMENT "latest";
addCommandLineFlag "force" "f" "Whether to build the image even if it's already built" OPTIONAL NO_ARGUMENT "false";
addCommandLineFlag "overwrite-latest" "o" "Whether to overwrite the \"latest\" tag with the new one (default: false)" OPTIONAL NO_ARGUMENT "false";
addCommandLineFlag "registry" "p" "Optionally, the registry to push the image to." OPTIONAL EXPECTS_ARGUMENT;
addCommandLineFlag "reduce-image" "ri" "Whether to reduce the size of the resulting image" OPTIONAL NO_ARGUMENT "false";
addCommandLineFlag "cleanup-images" "ci" "Whether to try to cleanup images." OPTIONAL NO_ARGUMENT "false";
addCommandLineFlag "cleanup-containers" "cc" "Whether to try to cleanup containers" OPTIONAL NO_ARGUMENT "false";
addCommandLineFlag "registry-tag" "rt" "Whether to tag also for pushing to a registry later (implicit if -p is enabled)." OPTIONAL NO_ARGUMENT "false";
addCommandLineFlag "X:eval-defaults" "X:e" "Whether to eval all default values, which potentially slows down the script unnecessarily" OPTIONAL NO_ARGUMENT;
addCommandLineParameter "repositories" "The repositories to build" MANDATORY MULTIPLE;

DOCKER=$(which docker.io 2> /dev/null || which docker 2> /dev/null)

addError INVALID_OPTION "Unrecognized option";
addError DOCKER_NOT_INSTALLED "docker is not installed";
checkReq docker DOCKER_NOT_INSTALLED;
addError DATE_NOT_INSTALLED "date is not installed";
checkReq date DATE_NOT_INSTALLED;
addError REALPATH_NOT_INSTALLED "realpath is not installed";
checkReq realpath REALPATH_NOT_INSTALLED;
addError ENVSUBST_NOT_INSTALLED "envsubst is not installed";
checkReq envsubst ENVSUBST_NOT_INSTALLED;
addError HEAD_NOT_INSTALLED "head is not installed";
checkReq head HEAD_NOT_INSTALLED;
addError GREP_NOT_INSTALLED "grep is not installed";
checkReq grep GREP_NOT_INSTALLED;
addError AWK_NOT_INSTALLED "awk is not installed";
checkReq awk AWK_NOT_INSTALLED;
addError DOCKER_SQUASH_NOT_INSTALLED "docker-squash is not installed. Check out https://github.com/jwilder/docker-squash for details";

addError NO_REPOSITORIES_FOUND "no repositories found";
addError INVALID_URL "Invalid url";
addError TAG_IS_MANDATORY "Tag is mandatory";
addError CANNOT_PROCESS_TEMPLATE "Cannot process template";
addError INCLUDED_FILE_NOT_FOUND "The included file is missing";
addError ERROR_BUILDING_REPOSITORY "Error building repository";
addError ERROR_TAGGING_IMAGE "Error tagging image";
addError ERROR_PUSHING_IMAGE "Error pushing image to ${REGISTRY}";
addError ERROR_REDUCING_IMAGE "Error reducing the image size";
addError LICENSE_FILE_IS_MANDATORY "LICENSE_FILE needs to be defined. Review build.inc.sh or .build.inc.sh";
addError CANNOT_COPY_LICENSE_FILE "Cannot copy the license file ${LICENSE_FILE}";
addError LICENSE_FILE_DOES_NOT_EXIST "The specified license ${LICENSE_FILE} does not exist";
addError COPYRIGHT_PREAMBLE_FILE_IS_MANDATORY "COPYRIGHT_PREAMBLE_FILE needs to be defined. Review build.inc.sh or .build.inc.sh";
addError CANNOT_COPY_COPYRIGHT_PREAMBLE_FILE "Cannot copy the license file ${COPYRIGHT_PREAMBLE_FILE}";
addError COPYRIGHT_PREAMBLE_FILE_DOES_NOT_EXIST "The specified copyright-preamble file ${COPYRIGHT_PREAMBLE_FILE} does not exist";
addError PARENT_REPO_NOT_AVAILABLE "The parent repository is not available";

function dw_parse_tag_cli_flag() {
  export TAG="${1}";
}

function dw_parse_registry_cli_flag() {
  export REGISTRY_TAG=TRUE;
	export REGISTRY_PUSH=TRUE;
}

function dw_parse_force_cli_flag() {
  export FORCE_MODE=TRUE;
}

function dw_parse_overwrite_latest_cli_flag() {
  export OVERWRITE_LATEST=TRUE;
}

function dw_parse_reduce_image_cli_flag() {
  export REDUCE_IMAGE=TRUE;
}

function dw_parse_cleanup_images_cli_flag() {
  export CLEAUP_IMAGES=TRUE;
}

function dw_parse_registry_tag_cli_flag() {
  export REGISTRY_TAG=TRUE;
}

function dw_parse_tag_cli_envvar() {
  if isEmpty "${TAG}"; then
    export TAG="${DATE}";
  fi
}

function dw_parse_repositories_cli_parameter() {
  if isEmpty "${REPOSITORIES}"; then
    export REPOSITORIES="$@";
  fi

  if isEmpty "${REPOSITORIES}"; then
    export REPOSITORIES="$(find . -maxdepth 1 -type d | grep -v '^\.$' | sed 's \./  g' | grep -v '^\.')";
  fi
}
