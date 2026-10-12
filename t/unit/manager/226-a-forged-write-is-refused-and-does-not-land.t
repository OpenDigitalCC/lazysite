#!/usr/bin/perl
# SM944 S34 (ruled 2026-10-11, "Yes, as planned", (a) tests first): EVERY
# mutating action, and `users`, POSTed by a cookie session with no CSRF token is
# refused 403 AND DOES NOT LAND.
#
# The list is not written here: it is Lazysite::ControlApi::Actions'
# declaration (`mutates => 1`), so a mutating action added there is POSTed here
# without anyone remembering to. `users` is added by hand: it is dual-mode, not
# in %MUTATING, and its writes are POST-only inside action_users.
#
# WHY "DOES NOT LAND". Test 43 asserted the refusal's text for 19 actions. With
# the gate moved after the dispatch, a forged write landed while the answer was
# still 403 "Invalid or missing CSRF token", and test 43 passed on it; and 67
# mutating actions and `users` could be exempted with every test passing
# (SM944 § S34, tmp/sm944-s34-sab.out).
#
# HOW. Each action gets a fresh copy of one prepared site. The forged POST (no
# token) is sent first and must answer 403 `forbidden` with the CSRF error, set
# no cookie, leave every file of the site as it was (the whole site directory -
# the docroot and its siblings - by content, size and mode; the audit log is
# compared on its own) and add exactly one row to the audit trail: the refusal,
# denied by the CSRF gate (csrf-audit, ruled 2026-10-11; t/unit/manager/227
# holds its content). Then the SAME
# request carrying a valid token is sent - the control - and must do what the
# refusal is asserted to have prevented, or "did not land" would be measuring
# nothing:
#
#   landed   - the control changed the site's files, or (preview-grant and
#              preview-clear, whose whole effect is a cookie) set a cookie. The
#              forged POST is held to "nothing changed", the strong check.
#   ran      - the control changed no file but its handler ran and wrote an
#              audit row: its effect is not observable here (it calls out to the
#              network or a program, or needs state the test does not build).
#              The forged POST is held to "no audit row but the refusal's" -
#              the handler never ran - the weaker check. Those actions are %RAN_ONLY, each with
#              why, so the weaker check is a decision written down; an action
#              listed there that lands fails, so the list cannot go stale.
#
# A mutating action with no fixture below must land; the test says which did
# not, and the remedy is a fixture or a %RAN_ONLY entry with its reason.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use JSON::PP                      qw(encode_json decode_json);
use Digest::SHA                   qw(hmac_sha256_hex sha1_hex sha256_hex);
use IPC::Open3                    qw(open3);
use File::Path                    qw(make_path remove_tree);
use File::Find                    ();
use File::Temp                    ();
use File::Copy                    ();
use File::Basename                qw(dirname);
use IO::Compress::Zip             qw(zip $ZipError);
use TestHelper                    qw(repo_root site_tempdir grant_caps);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();
my $mapi = "$root/lazysite-manager-api.pl";
plan skip_all => 'manager api missing' unless -f $mapi;
my $secret = 'f' x 64;
my $ERRDIR = File::Temp::tempdir( CLEANUP => 1 );

# ---------------------------------------------------------------- helpers
sub spit {
    my ( $p, $t ) = @_;
    make_path( dirname($p) );
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return '';
    local $/;
    return scalar <$fh>;
}

# One request to the manager API as the cookie session `admin` (the auth wrapper
# stood in for, as in production: X-Remote-User vouched by
# LAZYSITE_AUTH_TRUSTED). token => 1 attaches a valid CSRF token.
sub api {
    my ( $doc, $action, %o ) = @_;
    my $body = !defined $o{body} ? '{}' : ref $o{body} ? encode_json( $o{body} ) : $o{body};
    local %ENV = %ENV;
    delete @ENV{
        qw(HTTP_AUTHORIZATION LAZYSITE_AUTH_TOKEN HTTP_X_CSRF_TOKEN HTTP_COOKIE LAZYSITE_LOG_LEVEL CONTENT_TYPE)};
    $ENV{DOCUMENT_ROOT}  = $doc;
    $ENV{REQUEST_METHOD} = 'POST';
    $ENV{QUERY_STRING}   = "action=$action" . ( defined $o{query} ? "&$o{query}" : '' );
    $ENV{CONTENT_LENGTH} = length $body;
    $ENV{CONTENT_TYPE}   = $o{ctype} if defined $o{ctype};
    $ENV{HTTP_X_REMOTE_USER}    = 'admin';
    $ENV{HTTP_X_REMOTE_GROUPS}  = 'managers';
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    $ENV{LAZYSITE_USERS_TOOL}   = "$root/tools/lazysite-users.pl";
    # The site's own copy of a plugin finds the module tree only beside an
    # install; prove -l passes it on as PERL5LIB and a plain `perl t/...` run
    # does not, so plugin-save's control found no tree and did not land there.
    $ENV{PERL5LIB} = join ':', "$root/lib", grep { defined && length } $ENV{PERL5LIB};
    $ENV{LAZYSITE_LOG_LEVEL}    = $o{log_level} if defined $o{log_level};
    $ENV{HTTP_X_CSRF_TOKEN} = hmac_sha256_hex( 'csrf:admin:' . int( time() / 3600 ), $secret ) if $o{token};
    open my $err, '>', "$ERRDIR/stderr" or die $!;
    my $pid = open3( my $w, my $r, '>&' . fileno($err), $^X, $mapi );
    binmode $w;
    print {$w} $body;
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    close $err;
    my ( $head, $jb ) = split /\r?\n\r?\n/, $out, 2;
    my ($status) = ( $head // '' ) =~ /^Status:\s*(\d+)/m;
    my $res = eval { decode_json( $jb // '' ) };
    return {
        status => $status // 200,
        res    => ( ref $res eq 'HASH'                  ? $res : { _raw => $out } ),
        cookie => ( ( $head // '' ) =~ /^Set-Cookie:/mi ? 1    : 0 ),
        stderr => slurp("$ERRDIR/stderr"),
    };
}

sub multipart {
    my ( $field, $filename, $type, $bytes ) = @_;
    my $b = 'lzsBoundary7x';
    return (
        ctype => "multipart/form-data; boundary=$b",
        body => "--$b\r\nContent-Disposition: form-data; name=\"$field\"; filename=\"$filename\"\r\n"
            . "Content-Type: $type\r\n\r\n$bytes\r\n--$b--\r\n",
    );
}

# ---------------------------------------------------------------- the site
# Prepared once, through the API itself where the API makes the thing, so each
# action's control has something to act on. Copied fresh for every action.
my $tpl_doc  = site_tempdir( plugins => 1 );
my $tpl_site = dirname($tpl_doc);              # <tmp>/site: the docroot and its siblings
my $lz       = "$tpl_doc/lazysite";
spit( "$lz/lazysite.conf",
    "site_name: T\nmanager: enabled\nmanager_groups: managers\nlayout: base\ntheme: one\n"
        . "plugins:\n  - plugins/data.pl\n  - plugins/briefs.pl\n  - plugins/remap.pl\n" );
spit( "$lz/auth/.secret", $secret );
chmod 0600, "$lz/auth/.secret";

# The account store is written through the tool that owns it.
sub users_tool {
    my (@args) = @_;
    my $pid = open3( my $w, my $r, undef, $^X, "$root/tools/lazysite-users.pl", '--docroot', $tpl_doc, @args );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    return $out;
}
sub users_api {
    my ($req) = @_;
    my $pid = open3( my $w, my $r, undef, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $tpl_doc );
    print {$w} encode_json($req);
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    return $out;
}
users_api( { action => 'add', username => 'admin', password => 'pw-admin-0123456789' } );
grant_caps( $tpl_doc, 'admin', 'manage_users', 'notifications', 'manage_config', 'audit_switch' );

spit( "$tpl_doc/page.md",   "---\ntitle: Page\n---\nx\n" );
spit( "$tpl_doc/page.html", "<p>x</p>\n" );                     # page.md's render cache
spit( "$tpl_doc/other.md",  "---\ntitle: Other\n---\ny\n" );
spit( "$tpl_doc/gone.md",   "---\ntitle: Gone\n---\nz\n" );
spit( "$tpl_doc/secret.md", "---\ntitle: Secret\n---\ns\n" );
spit( "$lz/layouts/base/layout.tt",  "<html>[% content %]</html>\n" );
spit( "$lz/layouts/extra/layout.tt", "<html>[% content %]</html>\n" );
spit( "$lz/layouts/base/themes/$_/theme.json", qq({"name":"$_","version":"1.0.0","layouts":["base"],"config":{}}) )
    for qw(one first);
make_path("$lz/layouts/old-backup-20260101T000000Z");
spit( "$tpl_doc/other.md.brief", "a sidecar brief\n" );    # what briefs-migrate imports
make_path("$tpl_doc/b");
spit( "$tpl_doc/b/index.md", "---\ntitle: B\n---\nb\n" );
spit( "$lz/forms/contact.conf", "account_email: email\ntargets:\n  - handler: local-storage\n" );
spit( "$lz/forms/empty.conf", "targets:\n  - handler: local-storage\n" );
spit( "$lz/forms/handlers.conf",
    "handlers:\n  - id: local-storage\n    enabled: true\n    name: Local file storage\n"
        . "    path: lazysite/forms/submissions\n    type: file\n"
        . "  - id: spare\n    enabled: true\n    name: Spare\n    path: lazysite/forms/submissions\n    type: file\n"
        . "  - id: unused\n    enabled: true\n    name: Unused\n    path: lazysite/forms/submissions\n    type: file\n" );
my @rows = (
    encode_json( { name => 'Ann', message => 'one' } ),
    encode_json( { name => 'Bob', message => 'two', _quarantined => JSON::PP::true, _spam_reason => 'x' } ),
    encode_json( { name => 'Cy', message => 'three', username => 'newbie', email => 'newbie@example.test' } ),
);
spit( "$lz/forms/submissions/contact.jsonl", join( '', map { "$_\n" } @rows ) );
my @row_id = map { substr( sha256_hex($_), 0, 16 ) } @rows;

my %S;    # what the setup made, by name
sub setup {
    my ( $action, %o ) = @_;
    my $r = api( $tpl_doc, $action, %o, token => 1 );
    diag "setup $action: $r->{status} " . encode_json( $r->{res} ) if $ENV{LZS_CSRF_PROBE};
    return $r->{res};
}
setup( 'acl-set', query => 'path=secret.md', body => { read => ['admin'] } );
$S{backup} = setup('backup-create')->{name} // '';
setup( 'data-table-save', body => { table => 'notes', descriptor => "title: Notes\nkey: slug\nfields:\n  slug:\n    type: text\n" } );
setup( 'data-migrate',       query => 'table=notes' );
setup( 'data-row-save',      body  => { table => 'notes', row  => { slug => 'a' } } );
setup( 'data-table-acl-set', body  => { table => 'notes', read => ['admin'] } );
setup( 'data-table-save', body => { table => 'old', descriptor => "title: Old\nkey: slug\nfields:\n  slug:\n    type: text\n" } );
setup( 'data-migrate',  query => 'table=old' );
setup( 'data-row-save', body  => { table => 'old', row => { slug => 'kept' } } );
my $drop = setup( 'data-table-drop', body => { table => 'old', confirm => 'old' } );
( $S{export} = $drop->{safety_export} // '' ) =~ s{.*/}{};
setup( 'domain-add', body => { host => 'b.test', content_root => 'b' } );
$S{package} = setup( 'site-backup-create', body => { host => 'b.test' } )->{name} // '';
setup( 'lock',         query => 'path=page.md' );
setup( 'brief-append', query => 'path=page.md', body => { entry => 'a brief' } );
setup( 'connector-save', body => { id => 'c1', connector => { name => 'C1', url => 'https://example.invalid/' } } );
setup( 'bad-url-block', query => 'ip=203.0.113.9' );
setup('git-init');
setup( 'save', query => 'path=other.md', body => { content => "---\ntitle: Other\n---\ny2\n" } );
$S{sha} = ( ( setup( 'git-history', query => 'path=other.md' )->{versions} || [] )->[-1] || {} )->{sha} // '';
setup( 'schedule-save', body => { id => 's1', handler => 'spare', every => 3600 } );
setup( 'data-table-save', body => { table => 'old', descriptor => "title: Old\nkey: slug\nfields:\n  slug:\n    type: text\n" } );
setup( 'data-migrate', query => 'table=old' ); # declared again, so its export can be restored
setup( 'data-table-save', body => { table => 'wide', descriptor => "title: Wide\nkey: slug\nfields:\n  slug:\n    type: text\n  extra:\n    type: text\n" } );
setup( 'data-migrate', query => 'table=wide' );
setup( 'data-row-save', body => { table => 'wide', row => { slug => 'w', extra => 'gone' } } );
setup( 'data-table-save', body => { table => 'wide', descriptor => "title: Wide\nkey: slug\nfields:\n  slug:\n    type: text\n" } );
setup( 'data-table-save', body => { table => 'pending', descriptor => "title: Pending\nkey: slug\nfields:\n  slug:\n    type: text\n" } );
# SM1053: an import staged for the operator to apply.
$S{import} = setup( 'accounts-import-stage', body => { accounts => [ { username => 'imp1' } ] } )->{id} // '';
users_api( { action => 'add', username => 'bot' } );    # an access-key account: no login
users_tool( 'set', 'bot', 'ui', 'off' );
users_api( { action => 'token', username => 'bot' } );
# After every setup write: a page save invalidates the registries.
spit( "$lz/templates/registries/sitemap.xml.tt", "<urlset/>\n" );
spit( "$lz/cache/registries/_root/sitemap.xml",  "<urlset/>\n" );
my $pkg_bytes = length $S{package} ? slurp("$lz/backups/$S{package}") : '';

my $theme_zip;
zip( \qq({"name":"up","version":"1.0.0","layouts":["base"],"config":{}}) => \$theme_zip, Name => 'theme.json' )
    or die "zip: $ZipError";

# ------------------------------------------------------------ the fixtures
# The request each action is sent with: what the control needs to land. An
# action not named here is sent with its name alone and an empty JSON object.
my %REQ = (
    'accounts-import-apply' => { body => { id => $S{import}, confirm => $S{import} } },    # SM1053
    'accounts-import-stage' => { body => { accounts => [ { username => 'imp2' } ] } },
    'acl-remove' => { query => 'path=secret.md' },
    'acl-set'    => { query => 'path=other.md', body => { read => ['admin'] } },
    'artifact-backups-delete' => { query => 'path=*' },
    'audit-trail-set'         => { body  => { state => 'off', reason => 'test' } },
    'backup-delete'           => { body  => { name  => $S{backup} } },
    'backup-restore'   => { query => "name=$S{backup}" },
    'bad-url-block'    => { query => 'ip=198.51.100.7' },
    'bad-url-unblock'  => { query => 'ip=203.0.113.9' },
    'brief-append'     => { query => 'path=other.md', body => { entry => 'another' } },
    'brief-delete'     => { query => 'path=page.md' },
    'cache-invalidate' => { query => 'path=/page.md' },
    'config-set'       => { body  => { key => 'site_name', value => 'U' } },
    'connector-call'   => { body  => { id  => 'c1' } },
    'connector-delete' => { body  => { id  => 'c1' } },
    'connector-save' => { body => { id => 'c2', connector => { name => 'C2', url => 'https://example.invalid/' } } },
    'connector-secret-set' => { body  => { id => 'c1', secret => 's3cret-value' } },
    'copy'                 => { query => 'path=page.md&to=copy.md' },
    'data-import' => { query => 'table=notes&apply=1', multipart( 'file', 'notes.csv', 'text/csv', "slug\nb\n" ) },
    'data-migrate'    => { query => 'table=pending' },
    'data-rebuild'    => { body  => { table => 'wide',  confirm_lost => ['extra'] } },
    'data-row-delete' => { body  => { table => 'notes', key          => 'a' } },
    'data-row-save'   => { body  => { table => 'notes', row => { slug => 'c' } } },
    'data-safety-export-delete'  => { body  => { file => $S{export} } },
    'data-safety-export-restore' => { body  => { file => $S{export}, apply => 1 } },
    'data-table-acl-remove'      => { query => 'table=notes' },
    'data-table-acl-set' => { body => { table => 'notes', read    => ['nobody'] } },
    'data-table-drop'    => { body => { table => 'notes', confirm => 'notes' } },
    'data-table-save' => { body => { table => 'more', descriptor => "title: More\nkey: slug\nfields:\n  slug:\n    type: text\n" } },
    'delete'           => { query => 'path=gone.md' },
    'domain-add'       => { body  => { host => 'c.test' } },
    'domain-alias-add' => { body  => { host => 'd.test', alias_of => 'b.test' } },
    'domain-remove'    => { body  => { host => 'b.test' } },
    'domain-set' => { body => { host => 'b.test', key => 'site_name', value => 'B' } },
    'file-upload' => { query => 'path=/', multipart( 'file', 'up.txt', 'text/plain', "hello\n" ) },
    'form-delete'      => { body => { form => 'empty',   confirm => 'empty' } },
    'form-notify-save' => { body => { form => 'contact', notify  => 'on' } },
    'form-submission-approve' => { body => { file => 'lazysite/forms/submissions/contact.jsonl', id => $row_id[2] } },
    'form-submission-confirm' => { body => { file => 'lazysite/forms/submissions/contact.jsonl', id => $row_id[1] } },
    'form-submission-delete' => { body => { file => 'lazysite/forms/submissions/contact.jsonl', id => $row_id[0] } },
    'form-submissions-delete-bulk' => { body => { file => 'lazysite/forms/submissions/contact.jsonl', ids => [ $row_id[0] ] } },
    'form-targets-save' => { body => { form => 'contact', handlers => ['spare'] } },
    'form-uploads-save' => { body => { form => 'contact', uploads => JSON::PP::true, max_kb => 100 } },
    'git-restore'    => { query => "path=other.md&sha=$S{sha}" },
    'handler-delete' => { body  => { id => 'unused' } },
    'handler-save' => { body => { id => 'h2', type => 'file', name => 'H2', path => 'lazysite/forms/submissions' } },
    'group-set'    => { body => { group => 'newgroup', caps => {} } },    # SM1050
    'key-revoke'       => { body  => { username => 'bot' } },
    'layout-activate'  => { query => 'layout=extra' },
    'layout-delete'    => { query => 'layout=extra' },
    'layouts-repo-set' => { body  => { value => 'owner/repo' } },
    'lock'             => { query => 'path=other.md' },
    'migrate-to-local' => { query => 'path=page.md' },
    'mkdir'            => { query => 'path=newdir' },
    'move'             => { query => 'path=gone.md&to=moved.md' },
    'nav-save'         => { body  => { items => [ { label => 'Home', url => '/' } ] } },
    'page-pdf'         => { query => 'path=nosuch.md' },
    'plugin-action'    => { query => 'plugin=nosuch' },
    'plugin-disable'   => { body  => { script => 'plugins/briefs.pl' } },
    'plugin-enable'    => { body  => { script => 'plugins/stats.pl' } },
    'plugin-save' => { query => 'plugin=stats', body => { script => 'plugins/stats.pl', values => {} } },
    'preview-grant' => { query => 'layout=extra' },
    'remap-save' => { body => { host => 'b.test', rules => [ { prefix => '/a', destination => '/b', code => 301 } ] } },
    'renew-lock' => { query => 'path=page.md' },
    'save' => { query => 'path=page.md', body => { content => "---\ntitle: Page\n---\nchanged\n" } },
    'schedule-delete' => { body => { id  => 's1' } },
    'schedule-save'   => { body => { id  => 's2', handler => 'spare', every => 3600 } },
    'session-revoke'  => { body => { sid => '0123456789abcdef' } },
    'site-backup-apply'  => { body => { name => $S{package}, host => 'b.test' } },
    'site-backup-create' => { body => { host => 'b.test' } },
    'site-backup-delete' => { body => { name => $S{package} } },
    'site-backup-upload' => { multipart( 'file', $S{package} || 'p.tar.gz', 'application/gzip', $pkg_bytes ) },
    'start-page-set' => { body  => { value => 'domain:b.test|/' } },
    'theme-activate' => { query => 'theme=first' },
    'theme-copy' => { query => 'path=one', body => { new_name => 'two', layout => 'base' } },
    'theme-delete' => { query => 'path=first' },
    'theme-upload' => { query => 'filename=up.zip', ctype => 'application/zip', body => $theme_zip },
    'unlock'      => { query => 'path=page.md' },
    'user-revoke' => { body  => { username => 'admin' } },
    'users' => { body => { action => 'add', username => 'eve', password => 'pw-eve-0123456789' } },
);

# The weaker check, each with its reason (see the header).
my %RAN_ONLY = (
    'layout-install' => 'installs from the layouts catalogue over the network; the request stops at its own check',
    'layouts-install' => 'installs a release from the layouts repository over the network; stops at its own check',
    'migrate-to-local' => 'fetches the .url page\'s remote source; the test makes no network call',
    'page-pdf' => 'its effect is the streamed document, made by an external converter the test does not need',
    'plugin-action' => 'runs an extension\'s own declared script; no extension here declares one that writes',
);

# SM944 S34 finding F-1 (found by this test): file-upload's rate check ran in
# the body read, BEFORE the CSRF gate, and reserved a slot in the account's
# hourly budget, so a forged POST wrote lazysite/manager/.upload-rate.db and
# spent one. This test pinned that one file as the only write a refused POST
# made. upload-budget moved the check to the dispatch branch; a forged
# file-upload now writes nothing, like every other action here
# (t/unit/manager/228 proves the budget).

# ---------------------------------------------------------- the comparison
sub fresh_site {
    my $doc  = site_tempdir();
    my $site = dirname($doc);
    remove_tree($site);
    system( 'cp', '-a', $tpl_site, dirname($site) ) == 0 or die "cp -a: $?";
    return $doc;
}

# Every file under the site directory: content, size and mode. The logs are
# compared on its own, by its rows.
sub snapshot {
    my ($doc) = @_;
    my $site = dirname($doc);
    my %s;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $rel = substr( $File::Find::name, length $site );
                return if $rel eq '/public_html/lazysite/logs/audit.log';
                my @st = lstat $File::Find::name;
                if ( -l _ ) { $s{$rel} = 'link:' . readlink $File::Find::name; return }
                if ( -d _ ) { $s{$rel} = sprintf 'dir:%o', $st[2] & 07777;     return }
                $s{$rel} = sprintf 'file:%o:%d:%s', $st[2] & 07777, $st[7], sha1_hex( slurp($File::Find::name) );
            },
        },
        $site
    );
    return \%s;
}

sub changed {
    my ( $x, $y ) = @_;
    my %k = map { $_ => 1 } keys %$x, keys %$y;
    return sort grep { ( $x->{$_} // '' ) ne ( $y->{$_} // '' ) } keys %k;
}

sub audit_rows {
    my ($doc) = @_;
    return grep { /\S/ } split /\n/, slurp("$doc/lazysite/logs/audit.log");
}

# ------------------------------------------------------------------- the run
my %mutating = Lazysite::ControlApi::Actions::mutating();
my @actions  = ( sort( keys %mutating ), 'users' );
cmp_ok( scalar keys %mutating, '>=', 87, 'the declaration names the mutating actions (87 when this was written)' );

my %class;
for my $action (@actions) {
    my $doc    = fresh_site();
    my $before = snapshot($doc);
    my @a0     = audit_rows($doc);
    my %req    = %{ $REQ{$action} || {} };

    my $f = api( $doc, $action, %req );
    is( $f->{status}, 403, "$action: a forged POST is answered 403" );
    is( ( $f->{res}{kind} // '' ), 'forbidden', "$action: ... kind forbidden" );
    like( ( $f->{res}{error} // '' ), qr/\AInvalid or missing CSRF token\z/, "$action: ... the CSRF refusal" );
    ok( !$f->{cookie}, "$action: ... and sets no cookie" );
    my @diff = changed( $before, snapshot($doc) );
    is_deeply( \@diff, [], "$action: ... and changes no file of the site" )
        or diag "changed: @diff";
    my @a1   = audit_rows($doc);
    my @rows = @a1[ scalar(@a0) .. $#a1 ];
    # (The plugin-* names are the deprecated spellings of extension-*, which
    # every audit row of theirs says.)
    is( scalar( grep { !/\| \Q$action\E \|.*\| fail \| ui \| denied: csrf(?:; spelling=deprecated)?$/ } @rows ), 0,
        "$action: ... and the handler never ran (no audit row but the refusal's)" )
        or diag join "\n", @rows;
    is( scalar(@rows), 1, "$action: ... and the refusal is audited once" ) or diag join "\n", @rows;

    # The control: the same request with a valid token.
    my $mid = snapshot($doc);
    my $c   = api( $doc, $action, %req, token => 1 );
    # SQLite's -shm and -wal change when the store is merely opened (a refusal
    # inside a data handler moves them), so they are no evidence that a control
    # landed; the forged POST above is held to them like any other file.
    my @cdiff = grep { !/-(?:shm|wal)\z/ } changed( $mid, snapshot($doc) );
    my @a2    = audit_rows($doc);
    $class{$action}
        = ( @cdiff || $c->{cookie} ) ? 'landed'
        : @a2 > @a1                  ? 'ran'
        :                              'nothing';
    my $want = $RAN_ONLY{$action} ? 'ran' : 'landed';
    is( $class{$action}, $want, "$action: the control (a valid token) " . ( $want eq 'ran' ? 'ran the handler' : 'landed' ) )
        or diag "control answered $c->{status}: " . encode_json( $c->{res} );
    diag sprintf '%-28s %-8s %s %s [%s]', $action, $class{$action}, $c->{status},
        substr( ( $c->{res}{error} // ( $c->{res}{ok} ? 'ok' : '' ) ), 0, 90 ), join ' ', @cdiff
        if $ENV{LZS_CSRF_PROBE};
}

diag 'weaker check (handler never ran): ' . join ', ', sort keys %RAN_ONLY;
done_testing();
