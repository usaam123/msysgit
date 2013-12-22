#!/bin/sh
#
# Rebase the thicket of branches -- including their merge structure -- on top
# of the specified upstream branch (defaults to 'junio/next'), optionally
# retaining "fast-forwardability" by fake-merging (using the "ours" strategy)
# the previous state on top of the current upstream state ("merging rebase").
#
# options:
#  --merging
#     start the rebased branch by a fake merge of the previous state
#
# The idea is to generate our very own rebase script, then call rebase -i with
# our fake editor to put the rebase script into place and then let the user edit
# the script.
#
# To make things prettier, we rewrite the rebase script after letting the user
# edit it, to replace "new" rebase commands with calls to a temporary alias ".r"
# that is added to help with starting the merging rebase, merging things, and
# cleaning up afterwards.

die () {
	echo "$*" >&2
	exit 1
}

git_dir="$(git rev-parse --git-dir)" ||
die "Not in a Git directory"

help () {
	cat >&2 << EOF
Usage: $0 [options] <upstream>

Options:
-m|--merging[=<msg>]	allow fast-forwarding the current to the rebased branch
--onto=<commit>		rebase onto the given commit
EOF
	exit 1
}

# Extra commands for use in the rebase script
extra_commands="edit mark rewind merge start_merging_rebase cleanup"

edit () {
	GIT_EDITOR="$1" &&
	GIT_SEQUENCE_EDITOR="$GIT_EDITOR" &&
	export GIT_EDITOR GIT_SEQUENCE_EDITOR &&
	shift &&
	case "$*" in
	*/git-rebase-todo)
		sed -e '/^noop/d' < "$1" >> "$git_dir"/REBASER-SCRIPT &&
		mv "$git_dir"/REBASER-SCRIPT "$1"
		"$GIT_EDITOR" "$@" &&
		mv "$1" "$git_dir"/REBASER-SCRIPT &&
		exprs="$(for command in $extra_commands
			do
				printf " -e 's/^$command\$/exec git .r &/'"
				printf " -e 's/^$command /exec git .r &/'"
			done)" &&
		eval sed $exprs < "$git_dir"/REBASER-SCRIPT > "$1"
		;;
	*)
		exec "$GIT_EDITOR" "$@"
	esac
}

mark () {
	git update-ref -m "Marking '$1' as rewritten" refs/rewritten/"$1" HEAD
}

rewind () {
	git reset --hard refs/rewritten/"$1"
}

merge () {
	# parse command-line arguments
	parents=
	while test "a$1" != a-C
	do
		parents="$parents $1" &&
		shift
	done &&
	shift &&
	orig="$1" &&
	shift &&
	# determine whether the merge needs to be redone
	p="$(git rev-parse HEAD)$parents" &&
	o="$(git rev-list -1 --parents $orig |
		sed "s/[^ ]*//")" &&
	while p=${p# }; o=${o# }; test -n "$p$o"
	do
		p1=${p%% *}; o1=${o%% *};
		test $o1 = "$(git rev-parse "$p1")" || break
		p=${p#$p1}; o=${o#$o1}
	done &&
	# either redo merge or fast-forward
	if test -z "$p$o"
	then
		git reset --hard $orig
	else
		msg="$(git cat-file commit $orig |
			sed "1,/^$/d")" &&
		git merge -n --no-ff -m "$msg" $p
	fi
}

start_merging_rebase () {
	git merge -s ours -m "$(cat "$git_dir"/REBASER-MERGING-MESSAGE)" "$1"
}

cleanup () {
	rm -f "$git_dir"/REBASER-SCRIPT &&
	for rewritten
	do
		git update-ref -d refs/rewritten/$rewritten
	done &&
	git config --unset alias..r
}

merging=
base_message=
onto=
while test $# -gt 0
do
	case "$1" in
	-m|--merging)
		merging=t
		base_message=
		;;
	--merging=*)
		merging=t
		base_message="${1#--merging=}"
		;;
	--onto)
		shift
		onto="$1"
		;;
	--onto=*)
		onto="${1#--onto=}"
		;;
	-h|--help)
		help
		;;
	-*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	*)
		break
		;;
	esac
	shift
done

case " $extra_commands " in
*" $1 "*)
	command="$1"
	shift
	"$command" "$@"
	exit
	;;
esac

string2regex () {
	echo "$*" |
	sed 's/[\\\/*?]/\\&/g'
}

merge2branch_name () {
	git show -s --format=%s "$1" |
		sed -n -e "s/^Merge [^']*'\([^']*\).*/\1/p" \
		-e "s/^Merge pull request #[0-9]* from //p" |
	tr ' 	' '-'
}

ensure_labeled () {
	for n in "$@"
	do
		case " $needslabel " in
		*" $n "*)
			;;
		*)
			needslabel="$needslabel $n"
			;;
		esac
	done
}

generate_script () {
	origtodo="$(git rev-list --no-merges --cherry-pick --pretty=oneline \
		--abbrev-commit --abbrev=7 --reverse --left-right --topo-order \
		$upstream..$head | \
		sed -n "s/^>/pick /p")"
	shorthead=$(git rev-parse --short $head)
	shortonto=$(git rev-parse --short $onto)

	# --topo-order has the bad habit of breaking first-parent chains over
	# merges, so we generate the topoligical order ourselves here

	list="$(git log --format='%h %p' --topo-order --reverse \
		$upstream..$head)"

	todo=
	if test -n "$merging"
	then
		from=$(git rev-parse --short "$upstream") &&
		to=$(git rev-parse --short "$onto") &&
		cat > "$git_dir"/REBASER-MERGING-MESSAGE << EOF &&
Start the merging-rebase to $onto

This commit starts the rebase of $from to $to
$base_message
EOF
		todo="start_merging_rebase \"$shorthead\""
	fi
	todo="$(printf '%s\n%s\n' "$todo" \
		"mark onto")"

	toberebased=" $(echo "$list" | cut -f 1 -d ' ' | tr '\n' ' ')"
	handled=
	needslabel=

	# each tip is an end point of a commit->first parent chain
	branch_tips="$(echo "$list" |
		cut -f 3- -d ' ' |
		tr ' ' '\n' |
		grep -v '^$')"

	ensure_labeled $branch_tips

	branch_tips="$(printf '%s\n%s' "$branch_tips" "$shorthead")"

	for tip in $branch_tips
	do
		# if this is not a commit to be rebased, skip
		case "$toberebased" in *" $tip "*) ;; *) continue;; esac

		# if it is handled already, skip
		case "$handled " in *" $tip "*) continue;; esac

		# start sub-todo for this tip
		subtodo=
		commit=$tip
		while true
		do
			# if already handled, this is our branch point
			case "$handled " in
			*" $commit "*)
				ensure_labeled $commit
				subtodo="$(printf '\nrewind %s # %s\n%s' \
					"$(name_commit $commit)" \
					"$(git show -s --format=%s $commit)" \
					"$subtodo")"
				break
				;;
			esac

			line="$(echo "$list" | grep "^$commit ")"
			# if there is no line, branch from the 'onto' commit
			if test -z "$line"
			then
				subtodo="$(printf '\nexec %s\n%s' \
					'git reset --hard refs/rewritten/onto' \
					"$subtodo")"
				break
			fi
			parents=${line#* }
			case "$parents" in
			*' '*)
				# merge
				parents2="`for parent in ${parents#* }
					do
						case "$toberebased" in
						*" $parent "*)
							printf refs/rewritten/
							;;
						esac
						echo "$parent "
					done`"
				subtodo="$(printf '%s # %s\n%s' \
					"merge $parents2-C $commit" \
					"$(git show -s --format=%s $commit)" \
					"$subtodo")"
				;;
			*)
				# non-merge commit
				line="$(echo "$origtodo" |
					grep "^pick $commit")"
				if test -z "$line"
				then
					line="# skip $commit"
				fi
				subtodo="$(printf '%s\n%s' "$line" "$subtodo")"
				;;
			esac
			handled="$handled $commit"
			commit=${parents%% *}
		done

		# try to figure out the branch name
		merged_by="$(echo "$list" |
			sed -n "s/^\([^ ]*\) [^ ]* $tip$/\1/p" |
			head -n 1)"
		if test -n "$merged_by"
		then
			branch_name="$(merge2branch_name "$merged_by")"
			test -z "$branch_name" ||
			subtodo="$(echo "$subtodo" |
				sed -e "1a\\
# Branch: $branch_name")"
		fi

		todo="$(printf '%s\n\n%s' "$todo" "$subtodo")"
	done

	for commit in $needslabel
	do
		linenumber="$(echo "$todo" |
			grep -n -e "^\(pick\|# skip\) $commit" \
				-e "^merge [0-9a-f/ ]* -C $commit")"
		linenumber=${linenumber%%:*}
		test -n "$linenumber" ||
		die "Internal error: could not find $commit in $todo"
		todo="$(echo "$todo" |
			sed "${linenumber}a\\
mark $commit\\
")"
	done

	lastline=9999
	while true
	do
		fixup="$(echo "$todo" |
			sed "$lastline,\$d" |
			grep -n -e '^pick [^ ]* \(fixup\|squash\)!' |
			tail -n 1)"
		test -n "$fixup" || break

		linenumber=${fixup%%:*}
		oneline="${fixup#* }"
		shortsha1="${oneline%% *}"
		oneline="${oneline#* }"
		command=${oneline%%!*}
		oneline="${oneline#*! }"
		oneline_regex="^pick [^ ]* $(string2regex "$oneline")\$"
		targetline="$(echo "$todo" |
			sed "$linenumber,\$d" |
			grep -n "$oneline_regex" |
			tail -n 1)"
		targetline=${targetline%%:*}
		if test -n "$targetline"
		then
			todo="$(echo "$todo" |
				sed -e "${linenumber}d" \
					-e "${targetline}a\\
$command $shortsha1 $oneline")"
		fi
		lastline=$(($linenumber+1))
	done

	todo="$(printf '%s\n\n%s' "$todo" "cleanup $needslabel")"
	echo "$todo" | uniq
}

this="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
setup () {
	alias="$(git config --get alias..r)"
	test -z "$alias" ||
	test "a$alias" = "a!sh \"$this\"" ||
	die "There is already an '.r' alias!"

	git config alias..r "!sh \"$this\"" &&
	generate_script > "$git_dir"/REBASER-SCRIPT &&
	GIT_EDITOR="$(cd "$git_dir" && pwd)/REBASER-EDITOR" &&
	cat > "$GIT_EDITOR" << EOF &&
#!/bin/sh

exec "$this" edit "$(git var GIT_EDITOR)" "\$@"
EOF
	chmod +x "$GIT_EDITOR" &&
	GIT_EDITOR="\"$GIT_EDITOR\"" &&
	GIT_SEQUENCE_EDITOR="$GIT_EDITOR" &&
	export GIT_EDITOR GIT_SEQUENCE_EDITOR
}

test ! -d "$git_dir"/rebase-merge &&
test ! -d "$git_dir"/rebase-apply ||
die "Rebase already in progress"

test $# = 1 ||
help

head="$(git rev-parse HEAD)" &&
upstream="$1" &&
onto=${onto:-$upstream}||
die "Could not determine rebase parameters"

setup

# Rebase!
git rebase -i --onto "$onto" HEAD

