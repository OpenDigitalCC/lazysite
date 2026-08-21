package Lazysite::ControlApi::Actions;

# SM350: the control API's action reference, as data.
#
# WHAT WAS MISSING. MCP has tools/list, with a JSON Schema per tool. The control
# API is an enforced, first-class channel - describe-capabilities declares it as
# one - and had no equivalent and no documentation page. Across 23 reference docs
# and 7 briefings, a search for its action names returned one incidental mention.
# So the only way to learn what an action takes was to read the CGI, which a
# token client cannot do, or to try it and read the error.
#
# WHY THIS IS A DECLARATION AND NOT A DISPATCH TABLE. The filing asked for the
# reference to be GENERATED from the dispatch table rather than hand-written,
# citing three defects already caused by hand-maintained lists. It is right, and
# there is no dispatch table to generate from: the control API dispatches through
# a 108-branch if/elsif chain. SM237 met the same wall, wrote %KNOWN_ACTION as a
# literal, said plainly that the chain "is the underlying issue and it deserves
# its own request", and pinned the literal to the chain with t/lint/22 so drift
# is impossible.
#
# This takes the same treatment one step further. The table below was EXTRACTED
# from the chain rather than typed, and t/lint/58 re-extracts it and fails on any
# difference - action set, capabilities and parameters alike. So it is a fourth
# list, and it is a fourth list that cannot drift, which is the property the
# filing actually wanted. Replacing the chain with a real table remains the right
# fix and remains its own piece of work.
#
# THE THREE CAPABILITY STATES, which are the useful part of this document:
#
#   caps => ['manage_themes','manage_layouts']   any ONE of these is enough
#   caps => []                                   any authenticated caller
#                                                (introspection: whoami,
#                                                describe-capabilities)
#   caps => undef                                NOT reachable with a token.
#                                                Cookie-only - the manager UI
#                                                calls it and an agent cannot.
#
# The third state is the one a caller cannot discover any other way, and it is
# the reason SM237 needed %KNOWN_ACTION at all: without it the token gate could
# not tell "exists, but cookie-only" from "no such action", and reported both as
# the former.
#
# WHERE A PARAMETER IS READ FROM is recorded because the two channels are not
# interchangeable in the chain. `query` is the query string, `body` is the JSON
# request body, and `query_or_body` means the branch accepts either - which is
# real, not a hedge: several actions read the query string and fall back to the
# body, and a caller sending only one of them needs to know which.

use strict;
use warnings;

# action => { caps, params => [ { name, in } ] }
#
# EXTRACTED FROM THE CHAIN. Regenerate rather than edit: any change belongs in
# lazysite-manager-api.pl, and t/lint/58 will fail until this matches it.
our %ACTION = (
    'acl-get' => { caps => ['webdav'], params => [ { name => 'path', in => 'query' } ] },
    'acl-remove' => { caps => ['webdav'], params => [ { name => 'path', in => 'query' } ] },
    'acl-set' => { caps => ['webdav'], params => [ { name => 'path', in => 'query_or_body' }, { name => 'read', in => 'body' }, { name => 'write', in => 'body' }, { name => 'owner', in => 'body' }, { name => 'draft', in => 'body' } ] },
    'actions-list' => { caps => [],                 params => [] },
    'aliases-list' => { caps => ['manage_content'], params => [] },
    'analyse_visitors' => { caps => ['analytics'], params => [ { name => 'window', in => 'query' }, { name => 'day', in => 'query' }, { name => 'month', in => 'query' }, { name => 'index', in => 'query' }, { name => 'trails', in => 'query' } ] },
    'artifact-backups-delete' => { caps => [ 'manage_layouts', 'manage_themes' ], params => [ { name => 'path', in => 'query' } ] },
    'artifact-manifest' => { caps => [ 'manage_themes', 'manage_layouts' ], params => [] },
    'artifact-validate' => { caps => [ 'manage_themes', 'manage_layouts' ], params => [] },
    'audit' => { caps => ['audit'], params => [ { name => 'user', in => 'query' }, { name => 'target', in => 'query' }, { name => 'start', in => 'query' }, { name => 'end', in => 'query' }, { name => 'page', in => 'query' }, { name => 'per_page', in => 'query' } ] },
    'backup-create' => { caps => undef, params => [ { name => 'scope', in => 'query' } ] },
    'backup-delete' => { caps => undef, params => [ { name => 'name', in => 'query_or_body' } ] },
    'backup-download' => { caps => undef, params => [ { name => 'name', in => 'query' } ] },
    'backup-list'     => { caps => undef, params => [] },
    'backup-restore' => { caps => undef, params => [ { name => 'name', in => 'query' } ] },
    'bad-url-blocks' => { caps => ['manage_config'], params => [] },
    'bad-url-unblock' => { caps => ['manage_config'], params => [ { name => 'ip', in => 'query' } ] },
    'cache-invalidate' => { caps => undef, params => [ { name => 'path', in => 'query' }, { name => 'host', in => 'query' } ] },
    'cache-list'       => { caps => undef,             params => [] },
    'channel-services' => { caps => undef,             params => [] },
    'config-read'      => { caps => ['manage_config'], params => [] },
    'config-set' => { caps => ['manage_config'], params => [ { name => 'key', in => 'query_or_body' }, { name => 'value', in => 'query_or_body' } ] },
    'copy' => { caps => undef, params => [ { name => 'path', in => 'query' }, { name => 'to', in => 'query' } ] },
    'csrf-token' => { caps => undef, params => [] },
    'delete'     => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'describe-capabilities' => { caps => [], params => [] },
    'domain-add' => { caps => ['manage_domains'], params => [ { name => 'host', in => 'body' }, { name => 'content_root', in => 'body' }, { name => 'site_url', in => 'body' }, { name => 'site_name', in => 'body' }, { name => 'theme', in => 'body' }, { name => 'layout', in => 'body' }, { name => 'nav_file', in => 'body' }, { name => 'search_default', in => 'body' }, { name => 'lang', in => 'body' }, { name => 'lang_group', in => 'body' }, { name => 'seed', in => 'body' } ] },
    'domain-check' => { caps => ['manage_domains'], params => [ { name => 'host', in => 'query' } ] },
    'domain-preview' => { caps => ['manage_domains'], params => [ { name => 'host', in => 'query' } ] },
    'domain-remove' => { caps => ['manage_domains'], params => [ { name => 'host', in => 'body' }, { name => 'purge', in => 'body' } ] },
    'domain-set' => { caps => ['manage_domains'], params => [ { name => 'host', in => 'body' }, { name => 'key', in => 'body' }, { name => 'value', in => 'body' } ] },
    'domains-list'  => { caps => ['manage_domains'], params => [] },
    'file-download' => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'file-upload'   => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'file-zip-download' => { caps => undef, params => [] },
    'form-list' => { caps => [ 'manage_forms', 'read_submissions' ], params => [] },
    'form-submission-confirm' => { caps => undef, params => [ { name => 'file', in => 'query_or_body' }, { name => 'id', in => 'body' } ] },
    'form-submission-delete' => { caps => undef, params => [ { name => 'file', in => 'query_or_body' }, { name => 'id', in => 'body' } ] },
    'form-submissions' => { caps => [ 'manage_forms', 'read_submissions' ], params => [ { name => 'file', in => 'query' } ] },
    'form-submissions-delete-bulk' => { caps => undef, params => [ { name => 'file', in => 'query_or_body' }, { name => 'ids', in => 'body' } ] },
    'form-targets-read' => { caps => undef, params => [ { name => 'form', in => 'query' } ] },
    'form-targets-save' => { caps => undef, params => [ { name => 'form', in => 'query' }, { name => 'targets', in => 'body' } ] },
    'git-history' => { caps => ['manage_content'], params => [ { name => 'path', in => 'query' }, { name => 'limit', in => 'query' } ] },
    'git-history-summary' => { caps => ['manage_content'], params => [] },
    'git-init'            => { caps => ['manage_config'],  params => [] },
    'git-restore' => { caps => ['manage_content'], params => [ { name => 'path', in => 'query' }, { name => 'sha', in => 'query' } ] },
    'git-show' => { caps => ['manage_content'], params => [ { name => 'path', in => 'query' }, { name => 'sha', in => 'query' } ] },
    'git-status'     => { caps => ['manage_content'], params => [] },
    'handler-delete' => { caps => undef, params => [ { name => 'id', in => 'body' } ] },
    'handler-list'   => { caps => undef, params => [] },
    'handler-save'   => { caps => undef, params => [] },
    'key-revoke'     => { caps => undef, params => [] },
    'keys-list'      => { caps => undef, params => [] },
    'lang-status' => { caps => ['manage_content'], params => [ { name => 'group', in => 'query' } ] },
    'layout-activate' => { caps => ['manage_layouts'], params => [ { name => 'path', in => 'query' }, { name => 'layout', in => 'query' } ] },
    'layout-delete' => { caps => ['manage_layouts'], params => [ { name => 'path', in => 'query' } ] },
    'layout-install'    => { caps => ['manage_layouts'], params => [] },
    'layouts-available' => { caps => [ 'manage_themes', 'manage_layouts' ], params => [] },
    'layouts-install'  => { caps => undef,                                 params => [] },
    'layouts-manifest' => { caps => [ 'manage_themes', 'manage_layouts' ], params => [] },
    'layouts-release-contents' => { caps => undef, params => [ { name => 'tag', in => 'query' } ] },
    'layouts-releases' => { caps => undef, params => [] },
    'layouts-repo-get' => { caps => undef, params => [] },
    'layouts-repo-set' => { caps => undef, params => [ { name => 'value', in => 'body' } ] },
    'list' => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'lock' => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'migrate-to-local' => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'mkdir' => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'move' => { caps => undef, params => [ { name => 'path', in => 'query' }, { name => 'to', in => 'query' } ] },
    'nav-read' => { caps => ['manage_nav'], params => [ { name => 'host', in => 'query' } ] },
    'nav-save' => { caps => ['manage_nav'], params => [ { name => 'items', in => 'body' }, { name => 'host', in => 'query_or_body' } ] },
    'notices'      => { caps => ['notifications'], params => [] },
    'notices-seen' => { caps => undef,             params => [] },
    'pages'        => { caps => ['manage_nav'],    params => [] },
    'plugin-action' => { caps => undef, params => [ { name => 'plugin', in => 'query' }, { name => 'script', in => 'body' }, { name => 'action_id', in => 'body' }, { name => 'params', in => 'body' } ] },
    'plugin-disable' => { caps => undef, params => [ { name => 'script', in => 'body' } ] },
    'plugin-enable' => { caps => undef, params => [ { name => 'script', in => 'body' } ] },
    'plugin-list'   => { caps => undef, params => [] },
    'plugin-read' => { caps => undef, params => [ { name => 'plugin', in => 'query' }, { name => 'script', in => 'body' } ] },
    'plugin-save' => { caps => undef, params => [ { name => 'plugin', in => 'query' }, { name => 'script', in => 'body' }, { name => 'values', in => 'body' } ] },
    'preview'       => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'preview-clear' => { caps => undef, params => [] },
    'preview-grant' => { caps => [ 'manage_themes', 'manage_layouts' ], params => [] },
    'preview-public' => { caps => ['manage_content'], params => [ { name => 'path', in => 'query' } ] },
    'principals'         => { caps => undef, params => [] },
    'protected-sections' => { caps => undef, params => [] },
    'read' => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'recent-changes' => { caps => undef, params => [ { name => 'window', in => 'query' } ] },
    'regenerate-registries' => { caps => ['manage_content'], params => [] },
    'renew-lock' => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'rotate-auth-secret' => { caps => undef, params => [] },
    'save' => { caps => undef, params => [ { name => 'path', in => 'query' }, { name => 'content', in => 'body' }, { name => 'mtime', in => 'body' } ] },
    'session-revoke'    => { caps => undef,              params => [] },
    'sessions-list'     => { caps => undef,              params => [] },
    'site-backup-apply' => { caps => ['manage_domains'], params => [] },
    'site-backup-create' => { caps => ['manage_domains'], params => [ { name => 'host', in => 'query_or_body' } ] },
    'site-backup-delete' => { caps => ['manage_domains'], params => [ { name => 'name', in => 'query_or_body' } ] },
    'site-backup-download' => { caps => ['manage_domains'], params => [ { name => 'name', in => 'query_or_body' } ] },
    'site-backup-inspect' => { caps => ['manage_domains'], params => [ { name => 'name', in => 'query' }, { name => 'host', in => 'query' } ] },
    'site-backup-upload'  => { caps => ['manage_domains'], params => [] },
    'site-export-primary' => { caps => ['manage_content'], params => [] },
    'theme-activate' => { caps => ['manage_themes'], params => [ { name => 'path', in => 'query' }, { name => 'theme', in => 'query' } ] },
    'theme-delete' => { caps => ['manage_themes'], params => [ { name => 'path', in => 'query' } ] },
    'theme-list' => { caps => [ 'manage_themes', 'manage_layouts' ], params => [] },
    'theme-rename' => { caps => undef, params => [ { name => 'path', in => 'query' }, { name => 'new_name', in => 'body' } ] },
    'theme-upload' => { caps => undef, params => [ { name => 'filename', in => 'query' } ] },
    'themes-for-layout' => { caps => [ 'manage_themes', 'manage_layouts' ], params => [ { name => 'layout', in => 'query' } ] },
    'themes-list-all' => { caps => [ 'manage_themes', 'manage_layouts' ], params => [] },
    'unlock'      => { caps => undef, params => [ { name => 'path', in => 'query' } ] },
    'user-revoke' => { caps => undef, params => [] },
    'users'       => { caps => undef, params => [] },
    'version'     => { caps => undef, params => [] },
    'whoami'      => { caps => [],    params => [] },
);

# The actions this caller may use, in the shape describe_capabilities uses for
# its own lists. Subsets by grant exactly as tools/list does (SM210), so an
# account is never shown an action it cannot call - a reference listing
# everything would be a list of things to try and be refused.
#
# A COOKIE-ONLY action is omitted for a token caller and included for a cookie
# session, because that is precisely what its availability depends on.
sub actions_for {
    my ( $caps, %opt ) = @_;
    $caps ||= {};
    my @out;
    for my $name ( sort keys %ACTION ) {
        my $spec        = $ACTION{$name};
        my $caps_needed = $spec->{caps};

        my $available;
        if    ( !defined $caps_needed ) { $available = $opt{cookie} ? 1 : 0 }
        elsif ( !@$caps_needed )        { $available = 1 }
        else { $available = ( grep { $caps->{$_} } @$caps_needed ) ? 1 : 0 }
        next unless $available;

        push @out, {
            action => $name,
            params => [ map { { %$_ } } @{ $spec->{params} } ],
            ( defined $caps_needed
                ? ( capabilities => [@$caps_needed] )
                : ( cookie_only => 1 ) ),
        };
    }
    return \@out;
}

1;
