#!/bin/bash
#
# Copyright (c) 2017-2018 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

set -e

script_name=${0##*/}
typeset -A long_options

long_options=(
	[help]="Show usage"
	[package:]="Specify test package to run"
)

# Set default test run timeout value.
#
# KATA_GO_TEST_TIMEOUT can be set to any value accepted by
# "go test -timeout X"
timeout_value=${KATA_GO_TEST_TIMEOUT:-30s}

# -race flag is not supported on s390x
[ "$(go env GOARCH)" != "s390x" ] && race="-race"

# The "master" coverage file that contains the coverage results for
# all packages run under all scenarios.
test_coverage_file="coverage.txt"

# Temporary coverage file created for a "go test" run. The results in
# this file will be added to the master coverage file.
tmp_coverage_file="${test_coverage_file}.tmp"

warn()
{
	local msg="$*"
	echo >&2 "WARNING: $msg"
}

usage()
{
	cat <<EOF

Usage: $script_name help
       $script_name [options] [cmd]

Options:

EOF

	local option
	local description

	local long_option_names="${!long_options[@]}"

	# Sort space-separated list by converting to newline separated list
	# and back again.
	long_option_names=$(echo "$long_option_names"|tr ' ' '\n'|sort|tr '\n' ' ')

	# Display long options
	for option in ${long_option_names}
	do
		description=${long_options[$option]}

		# Remove any trailing colon which is for getopt(1) alone.
		option=$(echo "$option"|sed 's/:$//g')

		printf "    --%-10.10s # %s\n" "$option" "$description"
	done

	cat <<EOF

Commands:

    help           # Show usage.

EOF
}

# Run a command as either root or the current user (which might still be root).
#
# If the first argument is "root", run using sudo, else run as the current
# user. All arguments after the first will be treated as the command to run.
run_as_user()
{
	local user="$1"

	shift

	local cmd=$*

	if [ "$user" = root ]; then
		# use a shell to ensure PATH is correct.
		sudo -E PATH="$PATH" sh -c "$cmd"
	else
		eval "$cmd"
	fi
}

# Test a single golang package
test_go_package()
{
	local -r pkg="$1"
	local -r user="$2"

	printf "INFO: Running 'go test' as %s user on package '%s' with flags '%s'\n" \
		"$user" "$pkg" "$go_test_flags"

	run_as_user "$user" go test "$go_test_flags" -covermode=atomic -coverprofile=$tmp_coverage_file "$pkg"

	# Merge test results into the master coverage file.
	run_as_user "$user" tail -n +2 "$tmp_coverage_file" >> "$test_coverage_file"
	rm -f "$tmp_coverage_file"
}

# Run all tests and generate a test coverage file.
test_coverage()
{
	echo "mode: atomic" > "$test_coverage_file"

	users="current"

	if [ "$(id -u)" -eq 0 ]; then
		warn "Already running as root so will not re-run tests as non-root user."
		warn "As a result, only a subset of tests will be run"
		warn "(run this script as a non-privileged to ensure all tests are run)."
	else
		if [ "$CI" = true ] && [ -n "$KATA_DEV_MODE" ]; then
			warn "Dangerous to set CI and KATA_DEV_MODE together."
			warn "NOT running tests as root."
		else
			# Run the unit-tests *twice* (since some must run as root and
			# others must run as non-root), combining the resulting test
			# coverage files.
			users+=" root"
		fi
	fi

	echo "INFO: Currently running as user '$(id -un)'"
	for user in $users; do
	    test_go_package "$package" "$user"
	done
}

# Run the tests locally
test_local()
{
	eval go test "$go_test_flags" "$package"
}

main()
{
	local long_option_names="${!long_options[@]}"

	local args=$(getopt \
		-n "$script_name" \
		-a \
		--options="h" \
		--longoptions="$long_option_names" \
		-- "$@")

	package="./..."

	eval set -- "$args"
	[ $? -ne 0 ] && { usage >&2; exit 1; }

	while [ $# -gt 1 ]
	do
		case "$1" in
			-h|--help) usage; exit 0 ;;
			--package) package="$2"; shift 2;;
			--) shift; break ;;
		esac

		shift
	done

	# Consume getopt cruft
	[ "$1" = "--" ] && shift

	[ "$1" = "help" ] && usage && exit 0

	run_coverage=no
	if [ "$CI" = true ] || [ -n "$KATA_DEV_MODE" ]; then
		run_coverage=yes
	fi

	local go_ldflags
	[ "$(go env GOARCH)" = s390x ] && go_ldflags="-extldflags -Wl,--s390-pgste"

	# KATA_GO_TEST_FLAGS can be set to change the flags passed to "go test".
	go_test_flags=${KATA_GO_TEST_FLAGS:-"-v $race -timeout $timeout_value -ldflags '$go_ldflags'"}

	if [ "$run_coverage" = yes ]; then
		test_coverage
	else
		test_local
	fi
}

main "$@"
