#!/usr/bin/perl
# SM976 F1, F2, F4 (ruled 2026-10-09): what Q15c found a confined caller still
# reached, through every door, after the rulings.
#
# F1 "Yes, any served artifact": a confined caller writes a theme or layout only
#    if no site serves it, or only domains inside its scope do - on the file
#    choke point (cookie save, MCP write_file), the multipart upload and WebDAV.
#    The upload also asks SM749's active-theme rule now, which it never did.
# F2 "Confine both": form verbs reach only forms bound on pages inside the
#    caller's scope (a form no page binds is the primary's); brief verbs only the
#    briefs of pages inside it, or of rows of tables that pass the data rule.
#    Listings are filtered. WebDAV's form-conf branch asks the same rule.
# F4 "Activate on its domain": theme-activate / layout-activate take a host on
#    the control API, as MCP's twins do; a confined caller binds its own domain
#    that way with no manage_domains, and themes-list-all names those domains
#    (acts_on) for the Appearance page. The operator's page is unchanged.
#
# The probe was tmp/q15d-probe.pl (before and after in tmp/q15d-probe.*.out).
#
# Callers, none holding manage_domains or manage_users. op: the cookie operator
# (manage_users, so the operator). cks/cku: cookie managers scoped to
# sites/mine / bound to no domain. tks/tku, mcs/mcu, dvs/dvu: tokens, MCP grants
# and WebDAV accounts, scoped / unbound. A caller is scoped by naming its group
# in mine.example.org's allowed_groups.
#
# The instance: mine.example.org (sites/mine, theme mytheme), other.example.org
# (sites/other, theme spare), and the primary (layout base, theme one). Forms:
# mine_form on a page in sites/mine, other_form in sites/other, prim_form on a
# primary page, loose_form on no page.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_dav run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
plan skip_all => 'DBI / DBD::SQLite / YAML::PP not available'
    unless eval { require DBI; require DBD::SQLite; require YAML::PP; 1 };
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @WORK = qw(manage_content manage_themes manage_layouts manage_forms read_submissions
    delete_submissions manage_briefs manage_data purge);
my @ALL = ( qw(api ui mcp webdav manage_users manage_domains), @WORK );
my %CHAN = ( cks => 'ui', cku => 'ui', tks => 'api', tku => 'api', mcs => 'mcp', mcu => 'mcp',
    dvs => 'webdav', dvu => 'webdav' );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nwebdav_enabled: true\n"
        . "layout: base\ntheme: one\n"
        . "extensions:\n  - plugins/data.pl\n  - plugins/briefs.pl\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other", "$d/lazysite/db/tables", "$d/lazysite/forms/submissions" );
spit( "$d/sites/$_/index.md", "# $_\n" ) for qw(mine other);
spit( "$d/index.md",          "# primary\n" );
for my $l (qw(base gone)) {
    make_path("$d/lazysite/layouts/$l/themes");
    spit( "$d/lazysite/layouts/$l/layout.tt", "<html>[% content %]</html>\n" );
}
for my $t (qw(one two spare loose mytheme)) {
    make_path("$d/lazysite/layouts/base/themes/$t");
    spit( "$d/lazysite/layouts/base/themes/$t/theme.json",
        qq({"name":"$t","version":"1.0.0","layouts":["base"],"config":{}}) );
}
my %FORM = ( mine_form => 'sites/mine/contact.md', other_form => 'sites/other/contact.md',
    prim_form => 'contact.md', loose_form => '' );
for my $f ( sort keys %FORM ) {
    spit( "$d/$FORM{$f}", "---\ntitle: Contact\nform: $f\n---\n\n:::form\nname | Name\n:::\n" ) if length $FORM{$f};
    spit( "$d/lazysite/forms/$f.conf",              "targets:\n" );
    spit( "$d/lazysite/forms/submissions/$f.jsonl", encode_json( { name => 'V' } ) . "\n" );
}

$s->add_user('op');
$s->grant( 'op', 'g-op', [ 'ui', 'manage_users', 'manage_domains', @WORK ], \@ALL );
for my $u ( sort keys %CHAN ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", [ $CHAN{$u}, @WORK ], \@ALL );
}
sub op { my ( $a, $b, $q ) = @_; return $s->call( 'op', $a, ( defined $b ? ( body => $b ) : () ), ( defined $q ? ( query => $q ) : () ) ) }
for my $set (
    [ 'domain-add', { host => 'mine.example.org',  content_root => 'sites/mine' } ],
    [ 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } ],
    [ 'domain-set', { host => 'other.example.org', key => 'theme', value => 'spare' } ],
    [ 'domain-set', { host => 'mine.example.org',  key => 'theme', value => 'mytheme' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-cks, g-tks, g-mcs, g-dvs' } ],
    )
{
    ok( op(@$set)->{ok}, "set up: $set->[0] $set->[1]{host} " . ( $set->[1]{key} // q() ) ) or diag( op(@$set)->{error} );
}
for my $t ( [ t_mine => 'mine.example.org' ], [ t_other => 'other.example.org' ], [ t_free => '' ] ) {
    spit( "$d/lazysite/db/tables/$t->[0].yaml",
        "title: t\n" . ( length $t->[1] ? "domain: $t->[1]\n" : '' ) . "key: slug\nfields:\n  slug:\n    type: text\n" );
    op( 'data-migrate', {}, "action=data-migrate&table=$t->[0]" );
}
for my $p (qw(sites/mine/index.md sites/other/index.md index.md)) {
    ok( op( 'brief-append', { entry => 'seed' }, "action=brief-append&path=$p" )->{ok}, "set up: a brief of $p" );
}

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tks tku mcs mcu);

# The control API, raw: a token by Basic auth, a cookie caller as
# ManagerSession::call stands in for the auth wrapper. $o{raw}/$o{ctype} send a
# body other than JSON (the multipart upload).
sub api {
    my ( $who, $action, $body, $query, %o ) = @_;
    my $raw = $o{raw} // ( defined $body ? encode_json($body) : undef );
    if ( $who !~ /^tk/ && !defined $o{raw} ) {
        return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ), ( defined $query ? ( query => $query ) : () ) );
    }
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_AUTHORIZATION HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL CONTENT_TYPE)};
    if ( $who =~ /^tk/ ) { $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' ) }
    else {
        $ENV{HTTP_X_REMOTE_USER}    = $who;
        $ENV{LAZYSITE_AUTH_TRUSTED} = '1';
        $ENV{LAZYSITE_USERS_TOOL}   = $s->users;
        $ENV{HTTP_COOKIE}           = $s->cookie_for($who);
        $ENV{HTTP_X_CSRF_TOKEN}     = $s->csrf_for($who);
    }
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{QUERY_STRING}   = $query // "action=$action";
    $ENV{REQUEST_METHOD} = defined $raw ? 'POST'      : 'GET';
    $ENV{CONTENT_LENGTH} = defined $raw ? length $raw : 0;
    $ENV{CONTENT_TYPE}   = $o{ctype} if $o{ctype};
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ], stdin => ( $raw // '' ) )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub mcp {
    my ( $who, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

sub dav_put {
    my ( $who, $rel ) = @_;
    my $r = run_dav( $d, 'PUT', "/$rel",
        HTTP_AUTHORIZATION => 'Basic ' . encode_base64( "$who:pw-$who-0123456789", '' ),
        body               => ( $rel =~ /\.conf\z/ ? "targets:\n" : "/* probe */\n" ) );
    return { ok => ( ( $r->{code} // '' ) =~ /^20[014]$/ ? 1 : 0 ), error => 'HTTP ' . ( $r->{code} // '?' ) };
}

# A multipart upload of one file into a folder; the per-file refusal is the answer.
sub upload {
    my ( $who, $dir ) = @_;
    my $b   = 'XXq116XX';
    my $raw = "--$b\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\n1\r\n"
        . "--$b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"up.css\"\r\n"
        . "Content-Type: text/css\r\n\r\n/* up */\r\n--$b--\r\n";
    my $r = api( $who, 'file-upload', undef, "action=file-upload&path=$dir",
        raw => $raw, ctype => "multipart/form-data; boundary=$b" );
    my $e = ref $r->{errors} eq 'ARRAY' && @{ $r->{errors} } ? $r->{errors}[0] : undef;
    return $e ? { ok => 0, error => $e->{error}, kind => $e->{kind} } : $r;
}

# Y served, N refused; the letters follow the order given with each row.
sub run_cells {
    my ( $order, @cells ) = @_;
    my @who = split / /, $order;
    for my $c (@cells) {
        my ( $label, $want, $code ) = @$c;
        my @w = split //, $want;
        for my $i ( 0 .. $#who ) {
            my $r = $code->( $who[$i] );
            if ( $w[$i] eq 'Y' ) { ok( $r->{ok}, "$who[$i]: served: $label" ) or diag( $r->{error} // $r->{_raw} // '' ) }
            else {
                ok( !$r->{ok}, "$who[$i]: refused: $label" );
                unlike( $r->{kind} // '', qr/\A(?:invalid|not-found|validation)\z/,
                    '...and not for the shape of the call' ) or diag( $r->{error} // '' );
            }
        }
    }
    return;
}

my $T = 'lazysite/layouts/base/themes';

subtest 'F1: a theme or layout another site serves is that site\'s' => sub {
    run_cells( 'op cku cks',
        [ 'save into the theme other.example.org serves', 'YYN',
            sub { api( $_[0], 'save', { content => "/* $_[0] */\n" }, "action=save&path=$T/spare/p.css" ) } ],
        [ 'save into the theme mine.example.org serves', 'YYY',
            sub { api( $_[0], 'save', { content => "/* $_[0] */\n" }, "action=save&path=$T/mytheme/p.css" ) } ],
        [ 'save into a theme no site serves', 'YYY',
            sub { api( $_[0], 'save', { content => "/* $_[0] */\n" }, "action=save&path=$T/loose/p.css" ) } ],
        [ 'save into a layout no site serves', 'YYY',
            sub { api( $_[0], 'save', { content => "/* $_[0] */\n" }, "action=save&path=lazysite/layouts/gone/p.css" ) } ],
    );
    run_cells( 'op cku cks',
        [ 'upload into the theme other.example.org serves', 'YYN', sub { upload( $_[0], "$T/spare" ) } ],
        [ 'upload into the theme mine.example.org serves', 'YYY', sub { upload( $_[0], "$T/mytheme" ) } ],
        [ 'upload into the instance\'s active theme (SM749, never asked before)', 'NNN', sub { upload( $_[0], "$T/one" ) } ],
    );
    run_cells( 'mcu mcs',
        [ 'write_file into the theme other.example.org serves', 'NN',
            sub { mcp( $_[0], 'write_file', { path => "$T/spare/m.css", content => "/* m */\n" } ) } ],
        [ 'write_file into the theme mine.example.org serves', 'NY',
            sub { mcp( $_[0], 'write_file', { path => "$T/mytheme/m.css", content => "/* m */\n" } ) } ],
        [ 'write_file into a theme no site serves', 'YY',
            sub { mcp( $_[0], 'write_file', { path => "$T/loose/m.css", content => "/* m */\n" } ) } ],
        [ 'delete_file in the theme other.example.org serves', 'NN',
            sub { mcp( $_[0], 'delete_file', { path => "$T/spare/theme.json" } ) } ],
    );
    run_cells( 'dvu dvs',
        [ 'PUT into the theme other.example.org serves', 'NN', sub { dav_put( $_[0], "$T/spare/w.css" ) } ],
        [ 'PUT into the theme mine.example.org serves', 'NY', sub { dav_put( $_[0], "$T/mytheme/w.css" ) } ],
        [ 'PUT into a theme no site serves', 'YY', sub { dav_put( $_[0], "$T/loose/w.css" ) } ],
    );
    ok( -f "$d/$T/spare/theme.json", 'the theme other.example.org serves kept its theme.json' );
    unlike( slurp("$d/$T/spare/p.css"), qr/cks/, 'and cks wrote nothing into it' );
    my $r = api( 'cks', 'save', { content => "x\n" }, "action=save&path=$T/spare/p.css" );
    like( $r->{error} // '', qr/served by a site you do not reach.*copy it/s, 'the refusal names the rule and the way to work' );
    is( $s->last_status, 403, '...as 403 Forbidden' );
};

subtest 'F2: a form is reached through the pages that bind it' => sub {
    my @verbs = (
        [ 'form-targets-read', sub { api( $_[0], 'form-targets-read', undef, "action=form-targets-read&form=$_[1]" ) } ],
        [ 'form-targets-save', sub { api( $_[0], 'form-targets-save', { form => $_[1], handlers => [] } ) } ],
        [ 'form-uploads-save', sub { api( $_[0], 'form-uploads-save', { form => $_[1], uploads => JSON::PP::false } ) } ],
        [ 'form-notify-save', sub { api( $_[0], 'form-notify-save', { form => $_[1], notify => 'off' } ) } ],
        [ 'form-submissions', sub { api( $_[0], 'form-submissions', undef, "action=form-submissions&form=$_[1]" ) } ],
        [ 'form-submissions by store', sub {
                api( $_[0], 'form-submissions', undef, "action=form-submissions&file=lazysite/forms/submissions/$_[1].jsonl" ) } ],
    );
    my %want = ( mine_form => 'YYYYY', other_form => 'YYNYN', prim_form => 'YYNYN', loose_form => 'YYNYN' );
    for my $f ( sort keys %want ) {
        run_cells( 'op cku cks tku tks', map { my $v = $_; [ "$v->[0] $f", $want{$f}, sub { $v->[1]->( $_[0], $f ) } ] } @verbs );
    }
    # The row verbs refuse before they look: a row that does not exist is not
    # found for the reachable form and refused for the unreachable one.
    my $del = api( 'cks', 'form-submission-delete', { file => 'lazysite/forms/submissions/other_form.jsonl', id => 'ffffffffffffffff' } );
    like( $del->{error} // '', qr/cannot reach the form 'other_form'/, 'cks: a row of other_form, refused before the row is looked for' );
    my $own = api( 'cks', 'form-submission-delete', { file => 'lazysite/forms/submissions/mine_form.jsonl', id => 'ffffffffffffffff' } );
    unlike( $own->{error} // '', qr/cannot reach/, '...and of mine_form, looked for' );
    my $fd = api( 'cks', 'form-delete', { form => 'loose_form', confirm => 'loose_form' } );
    like( $fd->{error} // '', qr/cannot reach the form/, 'cks: form-delete of a form no page binds' );

    my %listed = map { $_ => join ',', sort map { $_->{name} } @{ api( $_, 'form-list' )->{forms} || [] } } qw(op cks tks tku);
    is( $listed{cks}, 'mine_form', 'form-list: cks sees its own form only' );
    is( $listed{tks}, 'mine_form', '...and so does tks' );
    is( $listed{op}, 'loose_form,mine_form,other_form,prim_form', '...the operator every form' );
    is( $listed{tku}, $listed{op}, '...and an unbound token every form (R3: its scope is the whole content)' );

    run_cells( 'mcu mcs',
        [ 'bind_form other_form', 'YN', sub { mcp( $_[0], 'bind_form', { form => 'other_form', handlers => [] } ) } ],
        [ 'set_form_notify mine_form', 'YY', sub { mcp( $_[0], 'set_form_notify', { form => 'mine_form', notify => 'off' } ) } ],
        [ 'set_form_uploads loose_form', 'YN', sub { mcp( $_[0], 'set_form_uploads', { form => 'loose_form', uploads => JSON::PP::false } ) } ],
        [ 'read_form_submissions prim_form', 'YN', sub { mcp( $_[0], 'read_form_submissions', { form => 'prim_form' } ) } ],
        [ 'create_form on its page, joining other_form', 'YN',
            sub { mcp( $_[0], 'create_form', { path => "sites/mine/join-$_[0].md", name => 'other_form' } ) } ],
        [ 'create_form on its page, a new name', 'YY',
            sub { mcp( $_[0], 'create_form', { path => "sites/mine/new-$_[0].md", name => "fresh_$_[0]" } ) } ],
    );
    is( join( ',', sort map { $_->{name} } @{ mcp( 'mcs', 'form_list', {} )->{forms} || [] } ), 'mine_form',
        'form_list: mcs sees the forms bound on its pages only (a new form is listed once it is bound)' );
    run_cells( 'dvu dvs',
        [ 'PUT lazysite/forms/mine_form.conf', 'YY', sub { dav_put( $_[0], 'lazysite/forms/mine_form.conf' ) } ],
        [ 'PUT lazysite/forms/other_form.conf', 'YN', sub { dav_put( $_[0], 'lazysite/forms/other_form.conf' ) } ],
        [ 'PUT lazysite/forms/loose_form.conf', 'YN', sub { dav_put( $_[0], 'lazysite/forms/loose_form.conf' ) } ],
    );
};

subtest 'F2: a brief is its page\'s, or its row\'s table\'s' => sub {
    run_cells( 'op cku cks tku tks',
        [ 'brief-read of a page in sites/mine', 'YYYYY', sub { api( $_[0], 'brief-read', undef, 'action=brief-read&path=sites/mine/index.md' ) } ],
        [ 'brief-append of a page in sites/other', 'YYNYN',
            sub { api( $_[0], 'brief-append', { entry => $_[0] }, 'action=brief-append&path=sites/other/index.md' ) } ],
        [ 'brief-read of the primary\'s page', 'YYNYN', sub { api( $_[0], 'brief-read', undef, 'action=brief-read&path=index.md' ) } ],
        [ 'brief-append of a row of other.example.org\'s table', 'YYNNN',
            sub { api( $_[0], 'brief-append', { entry => 'r', type => 'row', table => 't_other', key => 'k' }, 'action=brief-append&path=x' ) } ],
        [ 'brief-append of a row of mine.example.org\'s table', 'YYYNY',
            sub { api( $_[0], 'brief-append', { entry => 'r', type => 'row', table => 't_mine', key => 'k' }, 'action=brief-append&path=x' ) } ],
        [ 'brief-append of a row of a table naming no domain', 'YYYYY',
            sub { api( $_[0], 'brief-append', { entry => 'r', type => 'row', table => 't_free', key => 'k' }, 'action=brief-append&path=x' ) } ],
    );
    for my $w (qw(cks tks)) {
        my $r = api( $w, 'brief-read', undef, 'action=brief-read&path=sites/mine/../other/index.md' );
        like( $r->{error} // '', qr/cannot reach the brief/, "$w: a .. out of its scope is refused by the reach rule, before the path is resolved" );
    }
    my @cks = map { $_->{path} } @{ api( 'cks', 'briefs-list' )->{briefs} || [] };
    ok( ( grep { $_ eq '/sites/mine/index.md' } @cks ), 'briefs-list: cks sees its page\'s brief' );
    ok( !( grep { m{\A/(?:index\.md|sites/other/)} || m{/t_other/} } @cks ), '...and no other site\'s, nor other\'s rows' )
        or diag( join ', ', @cks );
    my @mcs = map { $_->{path} } @{ mcp( 'mcs', 'list_briefs', {} )->{briefs} || [] };
    ok( !( grep { m{\A/(?:index\.md|sites/other/)} } @mcs ), 'list_briefs: mcs sees no other site\'s brief' ) or diag( join ', ', @mcs );
    my $bd = api( 'cks', 'brief-delete', { type => 'row', table => 't_other', key => 'k' } );
    like( $bd->{error} // '', qr/cannot reach the brief of a row of 't_other'/, 'cks: brief-delete of other\'s row refused' );
    ok( api( 'op', 'brief-delete', { type => 'row', table => 't_other', key => 'k' } )->{ok}, '...the operator deletes it' );
};

subtest 'F4: a confined caller activates on its own domain, by host' => sub {
    my %acts = map { $_ => api( $_, 'themes-list-all' )->{acts_on} } qw(op cku cks tks tku);
    is_deeply( $acts{cks}, ['mine.example.org'], 'themes-list-all names cks\'s domain (acts_on)' );
    is_deeply( $acts{tks}, ['mine.example.org'], '...and tks\'s' );
    ok( !defined $acts{$_}, "...and is silent for $_, whose page is unchanged" ) for qw(op cku tku);

    run_cells( 'op cku cks tks tku',
        [ 'theme-activate with host=mine.example.org', 'YYYYN',
            sub { api( $_[0], 'theme-activate', {}, 'action=theme-activate&theme=two&host=mine.example.org' ) } ],
        [ 'theme-activate with host=other.example.org', 'YYNNN',
            sub { api( $_[0], 'theme-activate', {}, 'action=theme-activate&theme=spare&host=other.example.org' ) } ],
        [ 'layout-activate with host=mine.example.org', 'YYYYN',
            sub { api( $_[0], 'layout-activate', {}, 'action=layout-activate&layout=base&theme=mytheme&host=mine.example.org' ) } ],
    );
    my $iw = api( 'cks', 'theme-activate', {}, 'action=theme-activate&theme=two' );
    like( $iw->{error} // '', qr/instance-wide/, 'cks: the instance\'s theme is still refused (R1)' );
    my $conf = slurp("$d/lazysite/lazysite.conf");
    like( $conf, qr/^theme:\s*one\s*$/m, 'the instance\'s theme is untouched' );
    like( $conf, qr/^alias\.mine\.example\.org\.theme:\s*mytheme\s*$/m, 'mine.example.org is bound to the theme last activated on it' );
    like( $conf, qr/^alias\.other\.example\.org\.theme:\s*spare\s*$/m, 'other.example.org keeps its own' );
    my $tku = api( 'tku', 'theme-activate', {}, 'action=theme-activate&theme=two&host=mine.example.org' );
    like( $tku->{error} // '', qr/names no dav_scope/, 'an unbound token reaches no domain to bind (SM975)' );
};

done_testing();
