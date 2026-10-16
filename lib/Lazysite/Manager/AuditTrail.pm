package Lazysite::Manager::AuditTrail;

# The audit trail's views and its switch: what the trail holds, read for the
# Audit page and the recent-changes column (action_audit,
# action_recent_changes), the trail's own state (SM907), the names an audit
# line gives a subject that is not a path, and the N13-04 switch that turns
# recording off and on, writing its own two edges. Lazysite::Audit stays the
# writer every surface shares. Moved out of lazysite-manager-api.pl unchanged by
# SM944 S31 (ruled 2026-10-10).
#
# Index
#   _audit_trail_set        audit-trail-set: switch recording off or on (N13-04)
#   _audit_implicit_target  an audit line's subject when the action has no path
#   _audit_plugin_target    an extension action's subject: the plugin, and what
#   _audit_parse_line       one trail line as a hash, whichever release wrote it
#   _audit_cached_entries   the newest entries, parsed once (an append-only cache)
#   _audit_trail_state      why the list is what it is (SM907)
#   action_recent_changes   recent-changes: who last changed each target
#   action_audit            audit: the trail, filtered and paged
#
# The request context ($auth_user, $token_auth, %token_caps) is read from
# Lazysite::Manager::Common, which lazysite-manager-api.pl sets and nothing here
# assigns (t/lint/217); so are the request address (_request_ip) and the
# display names. Loaded where no request set the context, the views refuse and
# the switch refuses (t/unit/manager/205, 221). $DOCROOT and $LAZYSITE_DIR are
# set by the dispatcher, as for every manager module.

use strict;
use warnings;
use Exporter 'import';
use JSON::PP                 qw(encode_json decode_json);
use POSIX                    ();
use Lazysite::Util           qw(log_event);
use Lazysite::Paths          ();
use Lazysite::Audit          qw(audit_log);
use Lazysite::Auth::Settings ();
# SM944 S33: the audit branch's handler reads the query and the scope.
use Lazysite::Manager::Common
    qw($auth_user $token_auth %token_caps _user_caps _request_ip _display_names
    %params users_api);

our @EXPORT_OK = qw(_audit_trail_set _audit_implicit_target _audit_plugin_target
    _audit_parse_line _audit_cached_entries _audit_trail_state
    action_recent_changes action_audit dispatch_audit);

our $DOCROOT;         # set by the script
our $LAZYSITE_DIR;    # set by the script

# --- N13-04: the audit trail's switch -----------------------------------------
#
# RULED 2026-09-10 and 2026-09-11. The trail stays switchable, and the switch is
# ANSWERABLE: the switch-off is written to the trail, naming who, BEFORE it stops;
# the switch-on is written as it resumes. So the gap has named edges rather than
# being a silence. And turning the trail off is not the same authority as
# configuring a site: it needs manage_config AND audit_switch, which lives in a
# group of its own that no role draws on by default.
#
# The capability maps are OR lists - any listed capability admits - so they name
# audit_switch, the narrower grant, and manage_config is required here, where
# the refusal can name which of the two is missing.
#
# This action writes its own two edges, so it is skip-listed for the generic
# audit line: that line would land after the trail stopped, or duplicate the
# resumption.
sub _audit_trail_set {
    my ($req) = @_;
    my $caps = $token_auth ? \%token_caps : _user_caps($auth_user);
    return { ok => 0, kind => 'forbidden',
        error => 'Switching the audit trail needs Site config as well as the audit '
            . 'trail switch permission. An administrator can grant both on the Groups page.' }
        unless $caps->{manage_config} && $caps->{audit_switch};

    my $state = lc( $req->{state} // '' );
    return { ok => 0, kind => 'invalid', field => 'state',
        error => "state must be 'on' or 'off'." }
        unless $state eq 'on' || $state eq 'off';
    ( my $reason = $req->{reason} // '' ) =~ s/[\r\n|]+/ /g;

    require Lazysite::Audit;
    my $lz  = Lazysite::Paths::lazysite_dir($DOCROOT);
    my $was = Lazysite::Audit::audit_trail_state($lz);
    return { ok => 1, state => $was, changed => JSON::PP::false } if $was eq $state;

    my $origin = $token_auth ? 'api' : 'ui';
    my $ip     = _request_ip();
    my $who    = $auth_user // '-';

    if ( $state eq 'off' ) {
        # The edge FIRST, while the trail is still recording.
        audit_log( $who, 'audit-trail-off', 'audit trail', $ip, 'ok', $origin, $reason );
        my ( $ok, $err ) = Lazysite::Manager::Common::write_conf_key(
            'audit_trail', 'off', "audit trail switched off by $who" );
        unless ($ok) {
            # Still on, so this is recorded: the trail must not claim a gap
            # that did not happen.
            audit_log( $who, 'audit-trail-off', 'audit trail', $ip, 'fail', $origin,
                "NOT switched off: " . ( $err // 'write failed' ) );
            return { ok => 0, error => "The audit trail was not switched off: " . ( $err // 'write failed' ) };
        }
    }
    else {
        my ( $ok, $err ) = Lazysite::Manager::Common::write_conf_key(
            'audit_trail', 'on', "audit trail switched on by $who" );
        return { ok => 0, error => "The audit trail was not switched on: " . ( $err // 'write failed' ) }
            unless $ok;
        # The edge AFTER, now the trail is recording again.
        audit_log( $who, 'audit-trail-on', 'audit trail', $ip, 'ok', $origin, $reason );
    }
    log_event( 'WARN', $who, "audit trail switched $state", reason => $reason );
    return { ok => 1, state => $state, changed => JSON::PP::true };
}

# Audit target for an action that carries no file PATH of its own - so the audit
# trail names WHAT was acted on (a domain, a config key, a backup) instead of a
# bare '/'. Derives from the query params / JSON body. '' = no implicit target.
sub _audit_implicit_target {
    my ( $action, $params, $body ) = @_;
    $action //= '';
    $params //= {};
    my $req = ( defined $body && length $body ) ? ( eval { decode_json($body) } // {} ) : {};

    # SM1091: a list-form acl-set carries no path of its own; its refusal was
    # audited with target '' while the single form names '/path'. Name the paths
    # it asked about, spelt as the single form spells one, the first few and the
    # count of the rest so a 2,000-path request stays a line.
    if ( $action eq 'acl-set' && ref $req eq 'HASH' && ref $req->{paths} eq 'ARRAY' ) {
        my @p = map { m{\A/} ? $_ : "/$_" } grep { defined && !ref && length } @{ $req->{paths} };
        if (@p) {
            my @show = splice( @p, 0, 5 );
            return join( ',', @show ) . ( @p ? ' (+' . scalar(@p) . ' more)' : '' );
        }
    }

    if ( $action eq 'nav-save' ) {    # nav-save edits the site navigation
        my $h = $params->{host} // $req->{host} // '';
        return length $h ? "nav ($h)" : 'nav';
    }

    # Domain + per-site actions act on a HOST (domain-add/set/remove/preview/
    # check, site-backup-create/apply/upload) - name the domain.
    return 'default' if $action eq 'site-export-primary';    # SM185
    if ( $action eq 'form-submission-delete'
        || $action eq 'form-submission-confirm'
        || $action eq 'form-submission-approve'              # SM858
        || $action eq 'form-submissions-delete-bulk' ) {     # SM187/SM216: name the store
        my $f = $params->{file} // $req->{file} // '';
        return $f if length $f;
    }
    if ( $action =~ /^(?:domain-|site-backup-)/ ) {
        my $h = $params->{host} // $req->{host} // '';
        return $h if length $h;
        # SM183: site-backup-delete acts on a package NAME, not a host.
        my $n = $params->{name} // $req->{name} // '';
        return $n if length $n && $action =~ /^site-backup-/;
    }
    # SM553: the SM261 alias spellings (theme=, layout=) resolve to a name
    # inside the dispatch branch only; the audit block still sees path='/'.
    # Name the theme or layout that went live whichever spelling was used.
    if ( $action eq 'theme-activate' || $action eq 'layout-activate' ) {
        my $k = $action eq 'theme-activate' ? 'theme' : 'layout';
        my $n = $params->{$k} // $req->{$k} // '';
        return $n if length $n;
    }
    # SM1050: group-set acts on a GROUP, named as a rule names one.
    if ( $action eq 'group-set' ) {
        my $g = $req->{group} // '';
        return "\@$g" if length $g && !ref $g;
    }
    # SM1053: an account import is named by the staged file it acts on.
    if ( $action =~ /\Aaccounts-import-(?:apply|stage|remove)\z/ ) {
        my $i = $req->{id} // '';
        return length $i && !ref $i ? "accounts import $i" : 'accounts import';
    }
    # config-set: name the KEY that changed (e.g. site_name), not a bare '/'.
    if ( $action eq 'config-set' ) {
        my $k = $params->{key} // $req->{key} // '';
        return $k if length $k;
    }
    # Backups: create names the KIND (full/content/manual); restore/download the
    # backup file.
    return ( $req->{kind} // $params->{kind} // 'manual' ) if $action eq 'backup-create';
    if ( $action =~ /^backup-(?:restore|download)\z/ ) {
        my $n = $params->{name} // $req->{name} // '';
        return $n if length $n;
    }

    # N141B-C: CONNECTORS - name the connector, not the request path.
    #
    # Every connector action recorded target='/'. A connector POST carries no
    # file path, so the generic default was the request path, and there was no
    # branch here to replace it: five audit entries that name WHAT was done and
    # never WHICH connector it was done to.
    #
    # connector-secret-set is the sharp case. It is the entry an auditor reads
    # to answer "whose credential changed, and when" - and it answered the
    # second half only. With two connectors it is a coin toss; the agent found
    # two calls to DIFFERENT connectors sharing a timestamp, so even ordering
    # does not separate them.
    #
    # Deliberately a rule for the whole family rather than a case per action.
    # The next connector verb should not have to remember this - the general
    # shape of the defect, named at filing, is that actions whose subject is
    # not a path pass no target at all.
    if ( $action =~ /^connector-/ ) {
        for my $k (qw(id connector)) {
            my $v = $params->{$k} // $req->{$k} // '';
            return $v if length $v;
        }
    }

    # SM888 F4: HANDLERS AND FORM TARGETS - name the handler, not the path.
    #
    # The fourth family to need this, after data (SM503) and connectors plus
    # group changes (N141B-C), and reported by the field AFTER those landed -
    # so it is the residue of the same cause rather than a repeat of it.
    #
    # It matters for the same reason the connector one did: a handler decides
    # which code a form's submissions are handed to, and form-targets-save
    # decides which handlers a form reaches. A row saying somebody changed a
    # handler, without saying which, cannot answer the question the trail
    # exists for.
    #
    # TWO KEYS, because the two actions spell their subject differently, and
    # this was measured rather than assumed: handler-save and handler-delete
    # carry `id`, while form-targets-save refuses with "form is required" when
    # sent an `id` - its subject is `form`.
    if ( $action =~ /^(?:handler-|form-targets-)/ ) {
        for my $k (qw(id form handler)) {
            my $v = $params->{$k} // $req->{$k} // '';
            return $v if length $v;
        }
    }
    return '';
}

# Derive a plugin's name for the audit target: the plugin param if present,
# else the body's script basename (form-handler.pl -> form-handler). Returns ''
# when neither is available.
sub _audit_plugin_target {
    my ( $params, $body, $action, $result ) = @_;
    my $plugin = $params->{plugin} // '';
    unless ( length $plugin ) {
        my $b      = eval { decode_json( $body // '' ) };
        my $script = ( ref $b eq 'HASH' ? $b->{script} : undef ) // '';
        $plugin = $script =~ m{([^/]+?)(?:\.pl)?$} ? $1 : '';
    }

    # plugin-save: name the setting(s) changed so the audit says WHICH config key
    # was edited (e.g. "lazysite (site_name)"), not just the plugin. Keys only -
    # values may be secrets; capped so a whole-form save isn't a giant target.
    # Prefer the save handler's actual diff: the UI posts the WHOLE form, so
    # the submitted keys read "8 settings" for a one-field edit (field report).
    if ( defined $action && $action eq 'plugin-save' && length $plugin ) {
        my @keys;
        if ( ref $result eq 'HASH' && ref $result->{changed} eq 'ARRAY' ) {
            @keys = @{ $result->{changed} };
            $plugin .= ' (no changes)' unless @keys;
        }
        else {
            my $b    = eval { decode_json( $body // '' ) };
            my $vals = ( ref $b eq 'HASH' ? $b->{values} : undef );
            @keys = sort keys %{$vals} if ref $vals eq 'HASH';
        }
        if (@keys) {
            my $list = @keys > 6 ? ( scalar(@keys) . ' settings' )
                :   join( ', ', @keys );
            $plugin .= " ($list)";
        }
    }

    # plugin-action: name WHICH action ran (and any choice it carried), so a
    # git-sync push and pull are distinguishable in the trail - "git-sync
    # (pull keep_mine)" rather than a bare plugin name (SM085).
    if ( defined $action && $action eq 'plugin-action' && length $plugin ) {
        my $b      = eval { decode_json( $body // '' ) };
        my $aid    = ( ref $b eq 'HASH' ? $b->{action_id} : undef ) // '';
        my $choice = ( ref $b eq 'HASH' && ref $b->{params} eq 'HASH' )
            ? ( $b->{params}{choice} // '' ) : '';
        s/[^a-zA-Z0-9_-]//g for ( $aid, $choice );
        $aid    .= " $choice" if length $aid && length $choice;
        $plugin .= " ($aid)"  if length $aid;
    }
    return $plugin;
}

# SM072 audit trail: append one line per state-changing request to a
# manager-readable log. Fields are pipe-delimited: ts | user | action | ip | status.
# audit_log now lives in Lazysite::Audit (shared with WebDAV + MCP); imported
# at the top. action_audit (the reader, below) is a manager action, so it is
# here, with the manager's modules (SM944 S31).

sub _audit_parse_line {
    my ($line) = @_;
    chomp $line;
    my @f = split / \| /, $line;
    # Column growth over releases: 5 = ts|user|action|ip|status (pre-SM078);
    # 6 adds target (SM078); 7 appends origin (SM077, ui/api); 8 adds detail.
    my ( $ts, $u, $act, $target, $ip, $status, $origin, $detail );
    if ( @f >= 8 ) { ( $ts, $u, $act, $target, $ip, $status, $origin, $detail ) = @f[ 0 .. 7 ] }
    elsif ( @f == 7 ) { ( $ts, $u, $act, $target, $ip, $status, $origin ) = @f[ 0 .. 6 ]; $detail = '' }
    elsif ( @f == 6 ) { ( $ts, $u, $act, $target, $ip, $status ) = @f[ 0 .. 5 ]; $origin = ''; $detail = '' }
    else { ( $ts, $u, $act, $ip, $status ) = @f[ 0 .. 4 ]; $target = ''; $origin = ''; $detail = '' }
    return { ts => $ts, user => $u, action => $act, target => $target,
        ip => $ip, status => $status, origin => $origin, detail => $detail };
}

# Append-only cache: parse only the audit lines appended since last call, keeping
# the most recent CAP entries (chronological order). Rotation/truncation-aware.
sub _audit_cached_entries {
    my $file       = "$LAZYSITE_DIR/logs/audit.log";
    my $CAP        = 5000;
    my $cache_dir  = "$LAZYSITE_DIR/cache";
    my $cache_file = "$cache_dir/audit-cache.json";
    # SM907: the stat serves the CACHE KEY - file identity, and how much is new
    # since last time - and never the absence decision. `return [] unless -f`
    # stood here, which is the guard lint 121 forbids on a store read now that
    # the trail is one: a stat this process may not make fails exactly like an
    # open it may not make, and the trail then reads as a site where nothing
    # happened. An empty stat leaves size 0, so the read below is skipped and
    # _audit_trail_state is what says why.
    my @st = stat($file);
    my ( $inode, $size ) = @st ? ( $st[1], $st[7] ) : ( -1, 0 );

    my $cache;
    # SM917: a DERIVED tail cursor, and the only thing it can do is save work.
    # The very next condition invalidates on a missing, stale or unparseable cache
    # and re-reads the trail from offset 0, so absent and unreadable produce the
    # same correct answer: recompute. There is no fourth state here to report, and
    # a WARN on every cold read would be noise. The marker sits on the open's own
    # line because that is where t/lint/121 reads it.
    if ( open my $cf, '<', $cache_file ) {    # not a store
        local $/; $cache = eval { decode_json(<$cf>) }; close $cf;
    }
    if ( !$cache || ref $cache ne 'HASH'
        || ( $cache->{inode}  // -1 ) != $inode
        || ( $cache->{offset} // 0 ) > $size ) {
        $cache = { inode => $inode, offset => 0, entries => [] };
    }
    $cache->{entries} ||= [];

    my $offset = $cache->{offset} // 0;
    if ( $size > $offset ) {
        open my $fh, '<', $file or do {
            # It stat'd and will not open: a permissions fault, never absence.
            Lazysite::Util::cannot_read( 'audit.log', $file );
            return $cache->{entries};
        };
        seek $fh, $offset, 0;
        my $pos = $offset;
        while ( my $line = <$fh> ) {
            last unless $line =~ /\n\z/;    # incomplete final line: next time
            $pos += length $line;
            push @{ $cache->{entries} }, _audit_parse_line($line);
        }
        close $fh;
        my $over = @{ $cache->{entries} } - $CAP;
        splice @{ $cache->{entries} }, 0, $over if $over > 0;
        $cache->{offset} = $pos;
        $cache->{inode}  = $inode;
        if ( -d $cache_dir || mkdir($cache_dir) ) {
            if ( open my $w, '>', "$cache_file.$$" ) {
                print {$w} encode_json($cache); close $w;
                rename "$cache_file.$$", $cache_file;
            }
        }
    }
    return $cache->{entries};
}

# THE TRAIL'S OWN STATE (SM907, AT2).
#
# A short audit page has six possible meanings and used to have one rendering.
# The field case: a trail the CGI could READ and could not APPEND to, so the page
# showed the six events a root shell had written, looked healthy, and said
# nothing about every web-server event since. The operator had to ask why an
# agent's deployment left no trace.
#
# ANSWERED BY THE IDENTITY THAT WRITES IT. This runs as the CGI, so `-w` is the
# real question ("can I append?") rather than arithmetic about somebody else's
# uid. `lazysite check` asks the same question for an operator running as root,
# where -w answers yes for everybody, and does the arithmetic there instead.
#
#   appendable    - recording
#   unwritable    - exists, readable, and every new event is LOST
#   unreadable    - exists and will not open: nothing here can be trusted
#   off           - audit_trail: off. Collection stopped, what was collected stays
#   cannot-start  - no trail, and the logs directory refuses one
#   never-written - no trail, and one could be written. A new site, and the only
#                   one of the six where an empty page is the truth
#
# `why` and `repair` are composed here rather than in the page, so the control
# API and the manager say the same sentence about the same state.
sub _audit_trail_state {
    my $dir  = "$LAZYSITE_DIR/logs";
    my $file = "$dir/audit.log";
    return { state => 'off', file => $file,
        why => 'Recording is switched off, so this is not the whole story - it is '
            . 'what was collected before the trail was switched off.' }
        if Lazysite::Audit::audit_trail_state() eq 'off';

    if ( open my $fh, '<:raw', $file ) {
        close $fh;
        return { state => 'appendable', file => $file } if -w $file;
        return { state => 'unwritable', file => $file,
            why => 'The audit trail cannot be written, so events are being lost as '
                . 'they happen. What is listed was written by a process that could.',
            repair => 'run `lazysite check --fix` on the host' };
    }
    unless ( $!{ENOENT} ) {
        Lazysite::Util::cannot_read( 'audit.log', $file );
        return { state => 'unreadable', file => $file };
    }
    return { state => 'never-written', file => $file } if -w $dir;
    return { state => 'cannot-start', file => $file,
        why => 'No audit trail has been written and none can be: the logs '
            . 'directory refuses it, so nothing this site does is being recorded.',
        repair => 'run `lazysite check --fix` on the host' };
}

sub action_recent_changes {
    my ($window) = @_;
    # SM944 S31, the established fail-closed pattern (ruled 2026-10-10): WHO LAST
    # CHANGED WHAT IS READ FOR AN ACCOUNT. Inside a request the dispatcher has
    # refused an empty $auth_user before this runs, so it is never empty here;
    # reached outside one (the request context's reset leaves nobody) it
    # answered with who last changed each target
    # (tmp/sm944-s31-s32-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'Recent changes are read by a signed-in account, and no account is asking.' }
        unless length $auth_user;
    $window = ( defined $window && $window =~ /\A\d+\z/ ) ? $window : 86_400;    # 24h
    my $entries = _audit_cached_entries();
    # Audit timestamps are ISO (…Z), so a lexical cutoff is a time cutoff.
    my $cutoff = POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime( time() - $window ) );
    my %recent;
    for my $e ( @{$entries} ) {
        next unless ( $e->{status} // '' ) eq 'ok';
        next unless defined $e->{target} && length $e->{target} && $e->{target} ne '/';
        next unless ( $e->{ts} // '' ) ge $cutoff;
        # Entries are chronological, so the last write per target wins.
        $recent{ $e->{target} } =
            { ts => $e->{ts}, user => $e->{user}, action => $e->{action} };
    }
    return { ok => 1, window => $window, changes => \%recent };
}

# SM944 S33 (ruled 2026-10-11, "Yes, S33a then groups"): the audit action's
# dispatch branch, moved here from lazysite-manager-api.pl with its statements
# unchanged: the cookie gate (the full trail needs 'audit'; create_sub_users
# alone gets the managed_by scope), then action_audit below with the request's
# filters from %params (Manager::Common's context, S33a). Outside a request the
# reset leaves a token client, so the cookie gate is skipped, and action_audit
# refuses an empty account (S31): it reads nothing.
sub dispatch_audit {
    my $result;
    # Strict gate: the FULL audit trail requires the 'audit' capability (separate
    # from visitor analytics). Token clients are already gated by %need above (a
    # token still needs 'audit' for the full log). SM173: a cookie (manager) user
    # who holds create_sub_users but NOT 'audit' gets a SCOPED view - their own
    # activity plus that of the accounts beneath them in the managed_by tree.
    my $scope;    # undef = full log; hashref of usernames = restrict to these
    my $denied = 0;
    if ( !$token_auth ) {
        my $caps = _user_caps($auth_user);
        if ( !$caps->{audit} ) {
            if ( $caps->{create_sub_users} ) {
                my $sc = users_api( { action => 'audit-scope', username => $auth_user } ) || {};
                $scope = { map { $_ => 1 } @{ $sc->{users} || [] }, $auth_user };
            }
            else {
                audit_log( $auth_user, 'audit', '', _request_ip(), 'fail', 'ui', 'denied: needs audit' );
                $result = { ok => 0, kind => 'forbidden',
                    error => "The audit trail requires the 'Audit trail' permission. An "
                        . "administrator can grant it on the Groups page: give a group the "
                        . "'Audit trail' action, and add the user to it." };
                $denied = 1;
            }
        }
    }
    $result = action_audit( user => $params{user}, target => $params{target},
        start    => $params{start},    end   => $params{end}, page => $params{page},
        per_page => $params{per_page}, scope => $scope )
        unless $denied;
    return $result;
}

sub action_audit {
    my (%opt) = @_;
    # SM944 S31, the established fail-closed pattern (ruled 2026-10-10): THE
    # TRAIL IS READ FOR AN ACCOUNT. Inside a request the dispatcher has refused
    # an empty $auth_user (and asked for `audit`, or narrowed a sub-user manager
    # to its team) before this runs, so it is never empty here; reached outside
    # one (the request context's reset leaves nobody) it answered with the whole
    # trail, every actor and target (tmp/sm944-s31-s32-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'The audit trail is read by a signed-in account, and no account is asking.' }
        unless length $auth_user;

    # SM907: a trail that exists and will not open is this host unable to read
    # its own record, which is SM873's kind and a 500 - never an empty list. The
    # entries behind an unopenable file are not "none", they are unknown, and
    # answering ok with nothing in it is the lie this filing is about.
    my $trail = _audit_trail_state();
    return { ok => 0, kind => 'store-uninspectable', reason => 'open',
        error => "The audit trail exists and cannot be read ($trail->{file}), so "
            . 'what this site recorded cannot be shown. Run `lazysite check --fix` '
            . 'on the host to repair it.' }
        if $trail->{state} eq 'unreadable';

    my $cached = _audit_cached_entries();
    my $want   = $opt{user};
    my $want_t = $opt{target};              # SM077: filter to one file's history
        # Date-range filter: timestamps are ISO (2026-06-27T14:47:24Z) so they sort
        # lexically. A bare date widens to the whole day (start -> 00:00, end -> 23:59).
    my ( $start, $end ) = ( $opt{start}, $opt{end} );
    for my $b ( [ \$start, 'T00:00:00Z' ], [ \$end, 'T23:59:59Z' ] ) {
        my ( $ref, $pad ) = @$b;
        if ( defined $$ref && length $$ref ) {
            $$ref =~ s/[^0-9T:Z+-].*\z//;    # keep ISO-ish chars only
            $$ref .= $pad if $$ref =~ /\A\d{4}-\d\d-\d\d\z/;
        }
        else { $$ref = undef }
    }
    my $scope = $opt{scope};    # SM173: hashref of visible actors, or undef
    my @entries;
    my ( %fusers, %ftargets );          # SM119: distinct values for the filter dropdowns
    for my $e ( reverse @$cached ) {    # newest first
        my ( $ts, $u, $target ) = ( $e->{ts}, $e->{user}, $e->{target} );
        # SM173: a scoped (sub-user-manager) view sees only its team's activity -
        # applied before the facets so the dropdowns list only that team.
        next if $scope && !$scope->{ $u // '' };
        $fusers{ defined $u        ? $u      : '' } = 1;    # facets from all entries
        $ftargets{ defined $target ? $target : '' } = 1;
        # SM119: a "__none" filter matches blank-valued entries; else exact match.
        if ( defined $want && length $want ) {
            next if $want eq '__none' ? length( $u // '' ) : ( $u // '' ) ne $want;
        }
        if ( defined $want_t && length $want_t ) {
            next if $want_t eq '__none' ? length( $target // '' ) : ( $target // '' ) ne $want_t;
        }
        next if defined $start && ( $ts // '' ) lt $start;
        next if defined $end   && ( $ts // '' ) gt $end;
        push @entries, $e;
    }

    # Paginate (newest first); default 50 rows per page.
    my $per = $opt{per_page} || 50;
    $per = 50  if $per < 1;
    $per = 200 if $per > 200;
    my $total = scalar @entries;
    my $pages = $total ? int( ( $total + $per - 1 ) / $per ) : 1;
    my $page  = $opt{page} || 1;
    $page = 1      if $page < 1;
    $page = $pages if $page > $pages;
    my $pg_start = ( $page - 1 ) * $per;
    my $pg_end   = $pg_start + $per - 1;
    $pg_end = $#entries if $pg_end > $#entries;
    my @slice = $total ? @entries[ $pg_start .. $pg_end ] : ();

    # SM641: WHICH OF THESE ACTORS IS ACTUALLY AN ACCOUNT.
    #
    # The Audit page links every actor to /manager/users?user=<name>, and until
    # SM641 a failed login wrote whatever name it was given, so the trail
    # offered links to accounts that never existed. The writer no longer does
    # that - but the entries already on disk still say it, and no writer-side
    # change can reach them.
    #
    # This is the INTERSECTION of the facet list with the real accounts, which
    # discloses nothing: every name in it is already in `users` above, and a
    # scoped (sub-user-manager) view has already been narrowed. 'system' is
    # absent by construction, which is correct - it is a pseudo-actor, not a
    # person, and it has been linked as one since SM128.
    my $accounts = Lazysite::Auth::Settings::account_names();
    my @real     = sort grep { length && $accounts->{$_} } keys %fusers;

    # SM778: the trail's actor column is a login, and so is the filter
    # dropdown. Only real accounts are resolved - `%fusers` also holds the
    # invented names SM641 describes, and a name for one of those would be a
    # claim the store cannot support.
    return { ok => 1, entries => \@slice,
        total    => $total, page => $page, per_page => $per, pages => $pages,
        trail    => $trail,                    # SM907: why this list is what it is
        scoped   => ( $scope ? JSON::PP::true() : JSON::PP::false() ),    # SM173
        users    => [ sort keys %fusers ],     # SM119: filter dropdown options
        accounts => \@real,                    # SM641: of those, the linkable ones
        targets  => [ sort keys %ftargets ],
        _display_names(@real) };
}

1;
