# managed by backrest shell integration
# Fish completions for backrest.
# Install: install.sh copies this to ~/.config/fish/completions/ and substitutes @REPO_DIR@.
# Profile names are derived live from backup.json (set $BACKREST_CONFIG to override).

set -g __backrest_dir '@REPO_DIR@'

function __backrest_config
    if set -q BACKREST_CONFIG
        echo $BACKREST_CONFIG
    else
        echo $__backrest_dir/backup.json
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

set -l actions run snapshots logs
set -l flags --help --dry-run --validate --no-validate --config --progress --follow

for cmd in backrest ./backrest
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $actions; and not __fish_seen_subcommand_from $flags" -a "$actions $flags"
    complete -c $cmd -f -n "__fish_seen_subcommand_from snapshots" -a '(__backrest_profiles restic) (__backrest_profiles sqlite)'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from snapshots; and test (count (commandline -opc)) -ge 2" -a '(__backrest_profiles)'
end