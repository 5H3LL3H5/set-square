#!/bin/bash dry-wit
# Copyright 2014-today Automated Computing Machinery S.L.
# Distributed under the terms of the GNU General Public License v3

function usage() {
cat <<EOF
$SCRIPT_NAME [-t|--tag tagName] [-f|--force] [-T|--tutum] [-s|--squash-image] [repo]
$SCRIPT_NAME [-h|--help]
(c) 2014-today Automated Computing Machinery S.L.
    Distributed under the terms of the GNU General Public License v3
 
Builds Docker images from templates, similar to wking's. If no repo is specified, all repositories will be built.

Where:
  * repo: the repository image to build.
  * tag: the tag to use once the image is built successfully.
  * force: whether to build the image even if it's already built.
  * tutum: whether to push the image to tutum.co.
  * squash-image: whether to squash the resulting image.
Common flags:
    * -h | --help: Display this message.
    * -X:e | --X:eval-defaults: whether to eval all default values, which potentially slows down the script unnecessarily.
    * -v: Increase the verbosity.
    * -vv: Increase the verbosity further.
    * -q | --quiet: Be silent.
EOF
}

DOCKER=$(which docker.io 2> /dev/null || which docker 2> /dev/null)

# Requirements
function checkRequirements() {
  checkReq ${DOCKER} DOCKER_NOT_INSTALLED;
  checkReq date DATE_NOT_INSTALLED;
  checkReq realpath REALPATH_NOT_INSTALLED;
  checkReq envsubst ENVSUBST_NOT_INSTALLED;
  checkReq head HEAD_NOT_INSTALLED;
  checkReq grep GREP_NOT_INSTALLED;
  checkReq awk AWK_NOT_INSTALLED;
}
 
# Error messages
function defineErrors() {
  export INVALID_OPTION="Unrecognized option";
  export DOCKER_NOT_INSTALLED="docker is not installed";
  export DATE_NOT_INSTALLED="date is not installed";
  export REALPATH_NOT_INSTALLED="realpath is not installed";
  export ENVSUBST_NOT_INSTALLED="envsubst is not installed";
  export HEAD_NOT_INSTALLED="head is not installed";
  export GREP_NOT_INSTALLED="grep is not installed";
  export AWK_NOT_INSTALLED="awk is not installed";
  export DOCKER_SQUASH_NOT_INSTALLED="docker-squash is not installed. Check out https://github.com/jwilder/docker-squash for details";
  export NO_REPOSITORIES_FOUND="no repositories found";
  export INVALID_URL="Invalid command";
  export ERROR_BUILDING_REPO="Error building image";
  export ERROR_TAGGING_REPO="Error tagging image";
  export ERROR_PUSHING_IMAGE_TO_TUTUM="Error pushing image to tutum.co";
  export ERROR_SQUASHING_IMAGE="Error squashing the image";

  ERROR_MESSAGES=(\
    INVALID_OPTION \
    DOCKER_NOT_INSTALLED \
    DATE_NOT_INSTALLED \
    REALPATH_NOT_INSTALLED \
    ENVSUBST_NOT_INSTALLED \
    HEAD_NOT_INSTALLED \
    GREP_NOT_INSTALLED \
    AWK_NOT_INSTALLED \
    DOCKER_SQUASH_NOT_INSTALLED \
    NO_REPOSITORIES_FOUND \
    INVALID_URL \
    ERROR_BUILDING_REPO \
    ERROR_TAGGING_REPO \
    ERROR_PUSHING_IMAGE_TO_TUTUM \
    ERROR_SQUASHING_IMAGE \
  );

  export ERROR_MESSAGES;
}

## Parses the input
## dry-wit hook
function parseInput() {

  local _flags=$(extractFlags $@);
  local _flagCount;
  local _currentCount;

  # Flags
  for _flag in ${_flags}; do
    _flagCount=$((_flagCount+1));
    case ${_flag} in
      -h | --help | -v | -vv | -q | -X:e | --X:eval-defaults)
         shift;
         ;;
      -t | --tag)
         shift;
	 export TAG="${1}";
         shift;
	 ;;
      -T | --tutum)
         shift;
	 export TUTUM=0;
         shift;
	 ;;
      -f | --force)
          shift;
          export FORCE_MODE=0;
          ;;
      -s | --squash-image)
          shift;
          export SQUASH_IMAGE=0;
    esac
  done
 
  if [[ ! -n ${TAG} ]]; then
    TAG="${DATE}";
  fi

  # Parameters
  if [[ -z ${REPOS} ]]; then
    REPOS="$@";
    shift;
  fi

  if [[ -z ${REPOS} ]]; then
    REPOS="$(find . -maxdepth 1 -type d | grep -v '^\.$' | sed 's \./  g' | grep -v '^\.')";
  fi

  if [[ -n ${REPOS} ]]; then
      loadRepoEnvironmentVariables "${REPOS}";
      evalEnvVars;
  fi
}

## Checking input
## dry-wit hook
function checkInput() {

  local _flags=$(extractFlags $@);
  local _flagCount;
  local _currentCount;
  logDebug -n "Checking input";

  # Flags
  for _flag in ${_flags}; do
    _flagCount=$((_flagCount+1));
    case ${_flag} in
      -h | --help | -v | -vv | -q | -X:e | --X:eval-defaults | -t | --tag | -T | --tutum | -f | --force | -s | --squash-image)
	 ;;
      *) logDebugResult FAILURE "fail";
         exitWithErrorCode INVALID_OPTION ${_flag};
         ;;
    esac
  done
 
  if [[ -z ${REPOS} ]]; then
    logDebugResult FAILURE "fail";
    exitWithErrorCode NO_REPOSITORIES_FOUND;
  else
    logDebugResult SUCCESS "valid";
  fi 
}

## Does "${NAMESPACE}/${REPO}:${TAG}" exist?
## -> 1: the repository.
## -> 2: the tag.
## -> 3: the stack (optional)
## <- 0 if it exists, 1 otherwise
## Example:
##   if repo_exists "myImage" "latest"; then [..]; fi
function repo_exists() {
  local _repo="${1}";
  local _tag="${2}";
  local _stack="${3}";
  local _stackSuffix;
  retrieve_stack_suffix "${_stack}";
  _stackSuffix="${RESULT}";

  local _images=$(${DOCKER} images "${NAMESPACE}/${_repo}${_stackSuffix}")
  local _matches=$(echo "${_images}" | grep "${_tag}")
  local _rescode;
  if [ -z "${_matches}" ]; then
    _rescode=1
  else
    _rescode=0
  fi

  return ${_rescode};
}

## Returns the suffix to use should the image is part of
## a stack, and leaving it empty if not.
## -> 1: stack (optional)
## <- RESULT: "_${stack}" if stack is not empty, the empty string otherwise.
## Example:
##   retrieve_stack_suffix "examplecom"
##   stackSuffix="${RESULT}"
function retrieve_stack_suffix() {
  local _stack="${1}";
  local _result;
  if [[ -n ${_stack} ]]; then
    _result="-${_stack}"
  else
    _result=""
  fi
  export RESULT="${_result}";
}

## Builds the image if it's defined locally.
## -> 1: the repository.
## -> 2: the tag.
## -> 3: the stack (optional).
## Example:
##   build_repo_if_defined_locally "myImage" "latest";
function build_repo_if_defined_locally() {
  local _repo="${1}";
  local _tag="${2}";
  local _stack="${3}";
  if [[ -n ${_repo} ]] && \
     [[ -d ${_repo} ]] && \
     ! repo_exists "${_repo#${NAMESPACE}/}" "${_tag}" "${_stack}" ; then
    build_repo "${_repo}" "${_tag}" "${_stack}"
  fi
}

## Squashes the image with docker-squash [1]
## [1] https://github.com/jwilder/docker-squash
## -> 1: the current tag
## -> 2: the new tag for the squashed image
## -> 3: the namespace
## -> 4: the repo name
## Example:
##   squash_image "namespace" "myimage" "201508-raw" "201508"
function squash_image() {
  local _namespace="${1}";
  local _repo="${2}";
  local _currentTag="${3}";
  local _tag="${4}";
  checkReq docker-squash DOCKER_SQUASH_NOT_INSTALLED;
  logInfo -n "Squashing ${_image} as ${_namespace}/${_repo}:${_tag}"
  ${DOCKER} save "${_namespace}/${_repo}:${_currentTag}" | sudo docker-squash -t "${_namespace}/${_repo}:${_tag}" | ${DOCKER} load
  if [ $? -eq 0 ]; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_SQUASHING_IMAGE "${_namespace}/${_repo}:${_currentTag}";
  fi
}

## Builds "${NAMESPACE}/${REPO}:${TAG}" image.
## -> 1: the repository.
## -> 2: the tag.
## -> 3: the stack (optional).
## Example:
##  build_repo "myImage" "latest" "";
function build_repo() {
  local _repo="${1}";
  local _canonicalTag="${2}";
  if squash_image_enabled; then
    _rawTag="${2}-raw";
    _tag="${_rawTag}";
  else
    _tag="${_canonicalTag}";
  fi
  local _stack="${3}";
  local _stackSuffix;
  local _cmdResult;
  local _rootImage=;
  if is_32bit; then
    _rootImage="${ROOT_IMAGE_32BIT}:${ROOT_IMAGE_VERSION}";
  else
    _rootImage="${ROOT_IMAGE_64BIT}:${ROOT_IMAGE_VERSION}";
  fi
  retrieve_stack_suffix "${STACK}";
  _stackSuffix="${RESULT}";
  local _env="$( \
      for ((i = 0; i < ${#ENV_VARIABLES[*]}; i++)); do
        echo ${ENV_VARIABLES[$i]} | awk -v dollar="$" -v quote="\"" '{printf("echo  %s=\\\"%s%s{%s}%s\\\"", $0, quote, dollar, $0, quote);}' | sh; \
      done;) TAG=\"${_canonicalTag}\" DATE=\"${DATE}\" MAINTAINER=\"${AUTHOR} <${AUTHOR_EMAIL}>\" STACK=\"${STACK}\" REPO=\"${_repo}\" ROOT_IMAGE=\"${_rootImage}\" BASE_IMAGE=\"${BASE_IMAGE}\" STACK_SUFFIX=\"${_stackSuffix}\" ";

  local _envsubstDecl=$(echo -n "'"; echo -n "$"; echo -n "{TAG} $"; echo -n "{DATE} $"; echo -n "{MAINTAINER} $"; echo -n "{STACK} $"; echo -n "{REPO} $"; echo -n "{ROOT_IMAGE} $"; echo -n "{BASE_IMAGE} $"; echo -n "{STACK_SUFFIX} "; echo ${ENV_VARIABLES[*]} | tr ' ' '\n' | awk '{printf("${%s} ", $0);}'; echo -n "'";);

  if [ $(ls ${_repo} | grep -e '\.template$' | wc -l) -gt 0 ]; then
    for f in ${_repo}/*.template; do
      echo "${_env} \
        envsubst \
          ${_envsubstDecl} \
      < ${f} > ${_repo}/$(basename ${f} .template)" | sh;
    done
  fi

  logInfo "Building ${NAMESPACE}/${_repo}${_stack}:${_tag}"
#  echo docker build ${BUILD_OPTS} -t "${NAMESPACE}/${_repo}${_stack}:${_tag}" --rm=true "${_repo}"
  docker build ${BUILD_OPTS} -t "${NAMESPACE}/${_repo}${_stack}:${_tag}" --rm=true "${_repo}"
  _cmdResult=$?
  logInfo -n "${NAMESPACE}/${_repo}${_stack}:${_tag}";
  if [ ${_cmdResult} -eq 0 ]; then
    logInfoResult SUCCESS "built"
  else
    logInfo -n "${NAMESPACE}/${_repo}${_stack}:${_tag}";
    logInfoResult FAILURE "not built"
    exitWithErrorCode ERROR_BUILDING_REPO "${_repo}";
  fi
  if squash_image_enabled; then
    squash_image "${NAMESPACE}" "${_repo}${_stack}" "${_tag}" "${_canonicalTag}";
  fi
  logInfo -n "Tagging ${NAMESPACE}/${_repo}${_stack}:${_canonicalTag}"
  docker tag -f "${NAMESPACE}/${_repo}${_stack}:${_canonicalTag}" "${NAMESPACE}/${_repo}${_stack}:latest"
  if [ $? -eq 0 ]; then
    logInfoResult SUCCESS "${NAMESPACE}/${_repo}${_stack}:latest";
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_TAGGING_REPO "${_repo}";
  fi
}

## Pushes the image to Tutum.io
## -> 1: the repository.
## -> 2: the tag.
## -> 3: the stack (optional).
## Example:
##   tutum_push "myImage" "latest"
function tutum_push() {
  local _repo="${1}";
  local _tag="${2}";
  local _stack="${3}";
  local _stackSuffix;
  local _pushResult;
  retrieve_stack_suffix "${_stack}";
  _stackSuffix="${RESULT}";
  logInfo -n "Tagging image for uploading to tutum.co";
  docker tag "${NAMESPACE}/${_repo}${_stackSuffix}:${_tag}" "tutum.co/${TUTUM_NAMESPACE}/${_repo}${_stackSuffix}:${_tag}";
  if [ $? -eq 0 ]; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_TAGGING_REPO "${_repo}";
  fi
  logInfo "Pushing image to tutum";
  docker push "tutum.co/${TUTUM_NAMESPACE}/${_repo}${_stackSuffix}:${_tag}"
  _pushResult=$?;
  logInfo -n "Pushing image to tutum";
  if [ ${_pushResult} -eq 0 ]; then
    logInfoResult SUCCESS "done"
  else
    logInfoResult FAILURE "failed"
    exitWithErrorCode ERROR_PUSHING_IMAGE "tutum.co/${TUTUM_NAMESPACE}/${_repo}${_stackSuffix}:${_tag}"
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
## <- RESULT: the parent, if any.
## Example:
##   find_parent_repo "myImage"
##   parent="${RESULT}"
function find_parent_repo() {
  local _repo="${1}"
  local _result=$(grep -e '^FROM ' ${_repo}/Dockerfile.template 2> /dev/null | head -n 1 | awk '{print $2;}' | awk -F':' '{print $1;}')
  if [[ -n ${_result} ]] && [[ "${_result#\$\{NAMESPACE\}/}" != "${_result}" ]]; then
    # parent under our namespace
    _result="${_result#\$\{NAMESPACE\}/}"
  fi
  if [[ -n ${_result} ]] && [[ ! -n ${_result#\$\{BASE_IMAGE\}} ]]; then
    _result=$(echo ${BASE_IMAGE} | awk -F'/' '{print $2;}')
  fi
  if [[ -n ${_result} ]] && [[ ! -n ${_result#\$\{ROOT_IMAGE\}} ]]; then
    _result=${ROOT_IMAGE}
  fi
   export RESULT="${_result}"
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
  find_parent_repo "${_repo}"
  local _parent="${RESULT}"
  while [[ -n ${_parent} ]] && [[ "${_parent#.*/}" == "${_parent}" ]]; do
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
    BASE_IMAGE=${BASE_IMAGE_32BIT}
  else
    BASE_IMAGE=${BASE_IMAGE_64BIT}
  fi
  export BASE_IMAGE
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

  for _repo in ${_repos}; do
    for f in "${DRY_WIT_SCRIPT_FOLDER}/${_repo}/build-settings.sh" "${_repo}/.build-settings.sh"; do
      if [ -e "${f}" ]; then
        source "${f}";
      fi
    done
  done
}

## Checks whether the -f flag is enabled
## Example:
##   if force_mode_enabled; then [..]; fi
function force_mode_enabled() {
  _flagEnabled FORCE_MODE;
}

## Checks whether the -t flag is enabled
## Example:
##   if tutum_push_enabled; then [..]; fi
function tutum_push_enabled() {
  _flagEnabled TUTUM;
}

## Checks whether the -s flag is enabled
## Example:
##   if squash_image_enabled; then [..]; fi
function squash_image_enabled() {
  _flagEnabled SQUASH_IMAGE;
}

## Cleans up the docker containers
## Example:
##   cleanup_containers
function cleanup_containers() {
  local _count="$(${DOCKER} ps -a -q | xargs -n 1 -I {} | wc -l)";
  #  _count=$((_count-1));
  if [ ${_count} -gt 0 ]; then
    logInfo -n "Cleaning up ${_count} stale container(s)";
    ${DOCKER} ps -a -q | xargs -n 1 -I {} sudo docker rm {} > /dev/null;
    if [ $? -eq 0 ]; then
      logInfoResult SUCCESS "done";
    else
      logInfoResult FAILED "failed";
    fi
  fi
}

## Cleans up unused docker images
## Example:
##   cleanup_images
function cleanup_images() {
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
}

# Main logic
function main() {
  local _repo;
  local _parents;
  local _stack="${STACK}";
  local _buildRepo=1;
  if [ "x${_stack}" != "x" ]; then
    _stack="_${_stack}";
  fi
  resolve_base_image
  for _repo in ${REPOS}; do
    _buildRepo=1;
    if force_mode_enabled; then
      _buildRepo=0;
    elif ! repo_exists "${_repo}" "${TAG}" "${_stack}"; then
      _buildRepo=0;
    else
      logInfo -n "Not building ${_repo} since it's already built";
      logInfoResult SUCCESS "skipped";
    fi
    if [ ${_buildRepo} -eq 0 ]; then
      find_parents "${_repo}"
      _parents="${RESULT}"
      for _parent in ${_parents}; do
        build_repo_if_defined_locally "${_parent}" "${TAG}" "" # stack is empty for parent images
      done

      build_repo "${_repo}" "${TAG}" "${_stack}"

      if tutum_push_enabled; then
        tutum_push "${_repo}" "${_stack}"
      fi
    fi
  done
  cleanup_containers;
  cleanup_images;
}
