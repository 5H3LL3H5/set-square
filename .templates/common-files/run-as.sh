#!/usr/bin/env dry-wit
# Copyright 2015-today Automated Computing Machinery S.L.
# Distributed under the terms of the GNU General Public License v3
# mod: common
# api: public
# txt: Runs a command within given folder, under certain user/group.
# txt: If userId and groupId are omitted, those values are taken from the ownership information of the folder parameter.

DW.import user
DW.import command

# fun: main
# api: public
# txt: Main logic
# txt: Returns 0/TRUE always.
# use: main
function main() {
	local _uid="${USER_ID}"
	local _gid="${GROUP_ID}"
	local -i _restoreUid=${FALSE}
	local _uidUser
	local _temporaryUser
	local _temporaryUid
	local _command

	if isEmpty "${_uid}"; then
		if retrieveOwnerUid "${FOLDER}"; then
			_uid="${RESULT}"
		else
			exitWithErrorCode CANNOT_RETRIEVE_USER_UID_OF_FOLDER "${FOLDER}"
		fi
	fi

	if isEmpty "${_gid}"; then
		if retrieveOwnerGid "${FOLDER}"; then
			_gid="${RESULT}"
		else
			exitWithErrorCode CANNOT_RETRIEVE_GROUP_GID_OF_FOLDER "${FOLDER}"
		fi
	fi

	if retrieveUidFromUser "${RUN_AS_USER}"; then
		_serviceUserId="${RESULT}"
	fi

	if isEmpty "${_serviceUserId}"; then
		logDebug "Updating a temporary user to get a new uid"
		if uidAlreadyExists "${_uid}" &&
			areNotEqual "${_uid}" "${_serviceUserId}"; then
			_restoreUid=${TRUE}
			if retrieveUserFromUid "${_uid}"; then
				_uidUser="${RESULT}"
			else
				exitWithErrorCode CANNOT_RETRIEVE_USER_FROM_UID "${_uid}"
			fi
			_temporaryUser="temp$$"

			if ! createUser "${_temporaryUser}"; then
				exitWithErrorCode CANNOT_CREATE_USER "${_temporaryUser}"
			fi

			if retrieveUidFromUser "${_temporaryUser}"; then
				_temporaryUid="${RESULT}"
			else
				exitWithErrorCode CANNOT_RETRIEVE_UID_FROM_USER "${_temporaryUser}"
			fi
			if ! deleteUser "${_temporaryUser}"; then
				exitWithErrorCode CANNOT_DELETE_USER "${_temporaryUser}"
			fi
			if ! update_account "${_uidUser}" "${_temporaryUid}" "${_gid}"; then
				exitWithErrorCode CANNOT_UPDATE_ACCOUNT "${_uidUser}"
			fi
		fi
	fi

	if ! update_account "${RUN_AS_USER}" "${_uid}" "${_gid}"; then
		exitWithErrorCode CANNOT_UPDATE_ACCOUNT "${_uid}"
	fi

	if resolveCommandForUser "${RUN_AS_USER}" "${COMMAND}"; then
		_command="${RESULT}"
	fi

	if isEmpty "${_command}"; then
		_command="${COMMAND}"
	fi

	runCommandAsUidGid "${_uid}" "${_gid}" "${FOLDER}" "${_command}" "${COMMAND_ARGS}"
	local -i _rescode=$?

	if ! update_account "${RUN_AS_USER}" "${_serviceUserId}" "${_gid}"; then
		exitWithErrorCode CANNOT_UPDATE_ACCOUNT "${_uidUser}"
	fi

	if isTrue ${_restoreUid}; then
		if ! update_account "${_uidUser}" "${_uid}" "${_gid}"; then
			exitWithErrorCode CANNOT_UPDATE_ACCOUNT "${_uidUser}"
		fi
	fi

	return ${_rescode}
}

# fun: update_account
# api: public
# txt: Updates given account.
# opt: user: The user name.
# opt: userId: The new user id.
# opt: groupId: The new group id.
# txt: Returns 0/TRUE always, unless an error is detected.
# use: update_service_user_account guest 1000 1000
function update_account() {
	local _user="${1}"
	checkNotEmpty "user" "${_user}" 1
	local _userId="${2}"
	checkNotEmpty "userId" "${_userId}" 2
	local _groupId="${3}"
	checkNotEmpty "groupId" "${_groupId}" 3

	local _tempGroup
	local -i _deleteGroup=${FALSE}
	local _tempGroup

	if ! updateUserUid ${_user} ${_userId}; then
		exitWithErrorCode CANNOT_CHANGE_UID "${_user}"
	fi

	if ! gidAlreadyExists "${_groupId}"; then
		_tempGroup="temp$$"
		if createGroup "${_tempGroup}" "${_groupId}"; then
			_deleteGroup=${TRUE}
		else
			exitWithErrorCode CANNOT_CREATE_GROUP "${_tempGroup}"
		fi
	fi

	if ! updateUserGid "${_user}" ${_groupId}; then
		exitWithErrorCode CANNOT_CHANGE_GID "${_user} -> ${_groupId}"
	fi

	if isTrue ${_deleteGroup}; then
		if ! deleteGroup "${_tempGroup}"; then
			exitWithErrorCode CANNOT_DELETE_GROUP "${_tempGroup}"
		fi
	fi
}

## Script metadata and CLI settings.

setScriptDescription "Runs a command within given folder, under certain user/group.
If userId and groupId are omitted, those values are taken from the ownership information
of the folder parameter."

addCommandLineFlag "userId" "u" "The user id" OPTIONAL EXPECTS_ARGUMENT ""
addCommandLineFlag "userName" "U" "The user name" OPTIONAL EXPECTS_ARGUMENT ""
addCommandLineFlag "groupId" "g" "The group id" OPTIONAL EXPECTS_ARGUMENT ""
addCommandLineFlag "groupName" "G" "The group name" OPTIONAL EXPECTS_ARGUMENT ""
addCommandLineParameter "folder" "The folder where the command should run" MANDATORY SINGLE
addCommandLineParameter "command" "The command to run" MANDATORY SINGLE
addCommandLineParameter "args" "The command arguments" OPTIONAL MULTIPLE

defineEnvVar RUN_AS_USER OPTIONAL "The user we'll run on her behalf" "${SQ_SERVICE_USER:-${USER}}"

addError NO_FOLDER_SPECIFIED "No folder specified"
addError NO_COMMAND_SPECIFIED "No command specified"
addError NO_RUN_AS_USER_SPECIFIED "No RUN_AS_USER specified"
addError CANNOT_CHANGE_UID "Cannot change the uid of "
addError CANNOT_CHANGE_GID 'Cannot change the gid of '
addError CANNOT_RETRIEVE_USER_UID_OF_FOLDER "Cannot retrieve the user uid who owns folder "
addError CANNOT_RETRIEVE_GROUP_GID_OF_FOLDER "Cannot retrieve the group gid which owns folder "
addError USER_ID_IS_MANDATORY "The user id is mandatory if the -u flag is provided"
addError USER_DOES_NOT_EXIST "The user does not exist"
addError USER_NAME_IS_MANDATORY "The user name is mandatory if the -U flag is provided"
addError INVALID_USER_NAME "Invalid user name"
addError GROUP_ID_IS_MANDATORY "The group id is mandatory if the -g flag is provided"
addError GROUP_NAME_IS_MANDATORY "The group name is mandatory if the -G flag is provided"
addError GROUP_DOES_NOT_EXIST "The group does not exist"
addError INVALID_GROUP_NAME "Invalid group name"
addError CANNOT_RETRIEVE_USER_FROM_UID "Cannot retrieve the user associated to uid "
addError CANNOT_RETRIEVE_UID_FROM_USER "Cannot retrieve the uid associated to user "
addError CANNOT_CREATE_USER "Cannot create user "
addError CANNOT_DELETE_USER "Cannot delete user "
addError CANNOT_UPDATE_ACCOUNT "Cannot updated account "
addError CANNOT_CREATE_GROUP "Cannot create group "
addError CANNOT_DELETE_GROUP "Cannot delete group "

function dw_check_userid_cli_flag() {
	if isEmpty "${1}"; then
		exitWithErrorCode USER_ID_IS_MANDATORY "${1}"
	fi
	if ! uidAlreadyExists "${1}"; then
		exitWithErrorCode USER_DOES_NOT_EXIST "${1}"
	fi
}

function dw_check_username_cli_flag() {
	if isEmpty "${1}"; then
		exitWithErrorCode USER_NAME_IS_MANDATORY "${1}"
	fi
	if ! userAlreadyExists "${1}"; then
		exitWithErrorCode USER_DOES_NOT_EXIST "${1}"
	fi
	if retrieveUidFromUser "${1}"; then
		if isEmpty "${RESULT}"; then
			exitWithErrorCode INVALID_USER_NAME "${1}"
		fi
	else
		exitWithErrorCode INVALID_USER_NAME "${1}"
	fi
}

function dw_check_groupid_cli_flag() {
	if isEmpty "${1}"; then
		exitWithErrorCode GROUP_ID_IS_MANDATORY "${1}"
	fi
	if ! gidAlreadyExists "${1}"; then
		exitWithErrorCode GROUP_DOES_NOT_EXIST "${1}"
	fi
}

function dw_check_groupname_cli_flag() {
	if isEmpty "${1}"; then
		exitWithErrorCode GROUP_NAME_IS_MANDATORY "${1}"
	fi
	if ! groupAlreadyExists "${1}"; then
		exitWithErrorCode GROUP_DOES_NOT_EXIST "${1}"
	fi
	retrieveGidFromGroup "${1}"
	if isEmpty "${RESULT}"; then
		exitWithErrorCode INVALID_GROUP_NAME "${1}"
	fi
}

function dw_check_folder_cli_parameter() {
	if isEmpty "${1}"; then
		exitWithErrorCode NO_FOLDER_SPECIFIED
	fi
}

function dw_check_command_cli_parameter() {
	if isEmpty "${1}"; then
		exitWithErrorCode NO_COMMAND_SPECIFIED
	fi
}

function dw_parse_userid_cli_flag() {
	export USER_ID="${1}"
}

function dw_parse_username_cli_flag() {
	export USER_NAME="${1}"
	if retrieveUidFromUser "${1}"; then
		export USER_ID="${RESULT}"
	else
		exitWithErrorCode USER_DOES_NOT_EXIST
	fi
}

function dw_parse_groupid_cli_flag() {
	export GROUP_ID="${1}"
}

function dw_parse_groupname_cli_flag() {
	export GROUP_NAME="${1}"
	if retrieveGidFromGroup "${1}"; then
		export GROUP_ID="${RESULT}"
	else
		exitWithErrorCode GROUP_DOES_NOT_EXIST
	fi
}

function dw_parse_folder_cli_parameter() {
	export FOLDER="${1}"
}

function dw_parse_command_cli_parameter() {
	export COMMAND="${1}"
}

function dw_parse_args_cli_parameter() {
	export COMMAND_ARGS="${*}"
}
# vim: syntax=sh ts=2 sw=2 sts=4 sr noet
