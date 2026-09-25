# managed by backrest shell integration
# Fish completions for backrest.
# Install: install.sh copies this to ~/.config/fish/completions/ and substitutes @REPO_DIR@.
# Profiles are derived live from the config — resolution order:
#   1. --config on the command line
#   2. $BACKREST_CONFIG
#   3. backup.json next to the script
#   4. the only backup*.json (e.g. backup-laptop.json; example/schema
#      excluded). Multiple candidates -> no profiles (ambiguous).

set -g __backrest_dir '@REPO_DIR@'

function __backrest_config
    set -l toks (commandline -opc)
    set -l n (count $toks)
    set -l i 2
    while test $i -le $n
        if test "$toks[$i]" = "--config"
            and test (math $i + 1) -le $n
            echo $toks[(math $i + 1)]
            return
        end
        set i (math $i + 1)
    end
    if set -q BACKREST_CONFIG
        echo $BACKREST_CONFIG
    else if test -f $__backrest_dir/backup.json
        echo $__backrest_dir/backup.json
    else
        set -l found
        for f in $__backrest_dir/backup-*.json $__backrest_dir/backup*.json
            test -f $f; or continue
            string match -q '*example*' $f; and continue
            string match -q '*schema*' $f; and continue
            contains -- $f $found; and continue
            set found $found $f
        end
        test (count $found) -eq 1; and echo $found
    end
end

function __backrest_profiles --argument-names type
    set -l cfg (__backrest_config)
    test -f $cfg; or return
    if test -n "$type"
        jq -r --arg type "$type" '.profiles | to_entries[] | select(.value.type == $type) | .key' $cfg 2>/dev/null
    else
        jq -r '.profiles | keys[]' $cfg 2>/dev/null
    end
end

# Non-flag words typed so far, excluding --config values.
# (commandline -opc excludes the token currently being completed.)
function __backrest_tokens
    set -l toks (commandline -opc)
    set -l n (count $toks)
    test $n -ge 2; or return
    set -l out
    set -l skip 0
    set -l i 2
    while test $i -le $n
        if test $skip -eq 1
            set skip 0
        else if test "$toks[$i]" = "--config"
            set skip 1
        else
            switch $toks[$i]
                case --dry-run --validate --no-validate --progress --follow -f -h --help
                case '*'
                    set out $out $toks[$i]
            end
        end
        set i (math $i + 1)
    end
    for t in $out; echo $t; end
end

# True while the user is typing the value right after --config.
function __backrest_after_config
    set -l toks (commandline -opc)
    test (count $toks) -ge 2; or return 1
    test "$toks[-1]" = "--config"
end

set -l flags --help --dry-run --validate --no-validate --config --progress --follow

for cmd in backrest ./backrest
    complete -c $cmd -f -n '__backrest_after_config' -a '(__fish_complete_path)'
    complete -c $cmd -f -n 'not __backrest_after_config; and test (count (__backrest_tokens)) -eq 0' -a 'run snapshots logs'
    complete -c $cmd -f -n 'not __backrest_after_config; and test (count (__backrest_tokens)) -eq 0' -a "$flags"
    complete -c $cmd -f -n 'not __backrest_after_config; and test (count (__backrest_tokens)) -eq 0' -a '(__backrest_profiles)'
    complete -c $cmd -f -n 'not __backrest_after_config; and test (count (__backrest_tokens)) -eq 1; and not contains snapshots (__backrest_tokens)' -a '(__backrest_profiles)'
    complete -c $cmd -f -n 'not __backrest_after_config; and test (count (__backrest_tokens)) -eq 1; and not contains snapshots (__backrest_tokens)' -a "$flags"
    complete -c $cmd -f -n 'not __backrest_after_config; and test (count (__backrest_tokens)) -eq 1; and contains snapshots (__backrest_tokens)' -a '(__backrest_profiles restic) (__backrest_profiles sqlite)'
    complete -c $cmd -f -n 'not __backrest_after_config; and test (count (__backrest_tokens)) -eq 1; and contains snapshots (__backrest_tokens)' -a "$flags"
end