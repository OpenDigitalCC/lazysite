#!/usr/bin/perl
# SM976 Q15e (ruled 2026-10-09, "Refuse new binding"): through every door, a
# domain-confined caller writes no page that newly binds a form it does not
# reach; editing a page that already binds one, and removing a binding, are
# unchanged; the operator and the unbound callers are unaffected.
#
# The finding was tmp/q15d-hijack-probe.pl: a cookie manager scoped to sites/mine
# was refused the primary's form `leads`, saved sites/mine/hook.md naming it, and
# then read its submission. The first subtest is that probe, as assertions.
#
# Callers, none holding manage_users. op: the cookie operator. cks/cku: cookie
# managers scoped to sites/mine / bound to no domain. tks/tku, mcs/mcu, dvs/dvu:
# tokens, MCP grants and WebDAV accounts, scoped / unbound. A caller is scoped by
# naming its group in mine.example.org's allowed_groups.
#
# The instance: mine.example.org (sites/mine), other.example.org (sites/other),
# the primary. Forms: mine_form on sites/mine/contact.md, other_form on
# sites/other/contact.md, prim_form on contact.md (the primary) and on
# sites/mine/shared.md (a page in mine that already binds it), leads on no page.
# A scoped caller reaches mine_form only; an unbound one reaches every form.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_dav);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @WORK = qw(manage_content manage_forms read_submissions manage_domains);
my @ALL  = ( qw(api ui mcp webdav manage_users manage_config), @WORK );
my %CHAN = ( cks => 'ui', cku => 'ui', tks => 'api', tku => 'api', mcs => 'mcp', mcu => 'mcp',
    dvs => 'webdav', dvu => 'webdav' );

sub spit { my ( $p, $t ) = @_; ( my $dir = $p ) =~ s{/[^/]+\z}{}; make_path($dir); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> }
sub page { my ( $f, $extra ) = @_; return "---\ntitle: P\nform: $f\n---\n\n:::form\nname | Name\n:::\n" . ( $extra // '' ) }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nwebdav_enabled: true\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other", "$d/lazysite/forms/submissions" );
spit( "$d/sites/$_/index.md", "# $_\n" ) for qw(mine other);
spit( "$d/index.md",          "# primary\n" );
my %FORM = ( mine_form => ['sites/mine/contact.md'], other_form => ['sites/other/contact.md'],
    prim_form => [ 'contact.md', 'sites/mine/shared.md' ], leads => [] );
for my $f ( sort keys %FORM ) {
    spit( "$d/$_",                                  page($f) ) for @{ $FORM{$f} };
    spit( "$d/lazysite/forms/$f.conf",              "targets:\n" );
    spit( "$d/lazysite/forms/submissions/$f.jsonl", encode_json( { name => 'Visitor' } ) . "\n" );
}

$s->add_user('op');
$s->grant( 'op', 'g-op', [ qw(ui manage_users manage_config), @WORK ], \@ALL );
for my $u ( sort keys %CHAN ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", [ $CHAN{$u}, @WORK ], \@ALL );
}
sub op { my ( $a, $b, $q ) = @_; return $s->call( 'op', $a, ( defined $b ? ( body => $b ) : () ), ( defined $q ? ( query => $q ) : () ) ) }
for my $set (
    [ 'domain-add', { host => 'mine.example.org',  content_root => 'sites/mine' } ],
    [ 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-cks, g-tks, g-mcs, g-dvs' } ],
    )
{
    ok( op(@$set)->{ok}, "set up: $set->[0] $set->[1]{host}" );
}
my $CONF = slurp("$d/lazysite/lazysite.conf");

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tks tku mcs mcu);

# The control API: a token by Basic auth, a cookie caller as ManagerSession::call
# stands in for the auth wrapper; $o{raw}/$o{ctype} send a multipart body.
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
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $raw // '' );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
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
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

sub dav {
    my ( $who, $method, $rel, %o ) = @_;
    my $r = run_dav( $d, $method, "/$rel",
        HTTP_AUTHORIZATION => 'Basic ' . encode_base64( "$who:pw-$who-0123456789", '' ),
        ( defined $o{body} ? ( body => $o{body} ) : () ),
        ( defined $o{to} ? ( HTTP_DESTINATION => "http://localhost/dav/$o{to}", HTTP_OVERWRITE => 'F' ) : () ) );
    return { ok => ( ( $r->{code} // '' ) =~ /^20[014]$/ ? 1 : 0 ), code => $r->{code},
        error => 'HTTP ' . ( $r->{code} // '?' ) . ' ' . ( $r->{body} // '' ) };
}

# A multipart upload of one page into a folder; the per-file refusal is the answer.
sub upload {
    my ( $who, $dir, $name, $text ) = @_;
    my $b = 'XXq117XX';
    my $raw = "--$b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$name\"\r\n"
        . "Content-Type: text/markdown\r\n\r\n$text\r\n--$b--\r\n";
    my $r = api( $who, 'file-upload', undef, "action=file-upload&path=$dir",
        raw => $raw, ctype => "multipart/form-data; boundary=$b" );
    my $e = ref $r->{errors} eq 'ARRAY' && @{ $r->{errors} } ? $r->{errors}[0] : undef;
    return $e ? { ok => 0, error => $e->{error}, kind => $e->{kind} } : $r;
}

# Y served, N refused - and a refusal is this rule's; the letters follow the order.
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
                like( ( $r->{error} // '' ) . ' ' . ( $r->{kind} // '' ), qr/form-bind-refused|binds no form it does not reach/,
                    '...by the form-binding rule' ) or diag( $r->{error} // '' );
            }
        }
    }
    return;
}

subtest 'the Q15d hijack probe, refused now' => sub {
    my $sub = sub { api( 'cks', 'form-submissions', undef, 'action=form-submissions&form=leads' ) };
    ok( !$sub->()->{ok}, 'cks is refused the primary\'s form leads' );
    my $save = api( 'cks', 'save', { content => page('leads') }, 'action=save&path=sites/mine/hook.md' );
    ok( !$save->{ok}, 'saving sites/mine/hook.md naming it is refused' );
    like( $save->{error} // '', qr/would bind the form 'leads'.*binds no form it does not reach/s, '...naming the rule' );
    is( $s->last_status, 403, '...as 403 Forbidden' );
    ok( !-e "$d/sites/mine/hook.md", '...and nothing was written' );
    ok( !$sub->()->{ok},             'so cks still cannot read leads\' submissions' );
    ok( api( 'cks', 'save', { content => page( 'prim_form', "edited\n" ) }, 'action=save&path=sites/mine/shared.md' )->{ok},
        'editing a page that already binds a form cks does not reach still works' );
    ok( api( 'cks', 'save', { content => "---\ntitle: P\n---\nno form\n" }, 'action=save&path=sites/mine/shared.md' )->{ok},
        'and so does removing the binding' );
    spit( "$d/sites/mine/shared.md", page('prim_form') );
    ok( op( 'save', { content => page('leads') }, 'action=save&path=ophook.md' )->{ok}, 'the operator is unaffected' );
    unlink "$d/ophook.md";
};

subtest 'the control API: the cookie file save' => sub {
    run_cells( 'op cku cks',
        [ 'a new page in mine binding prim_form', 'YYN',
            sub { api( $_[0], 'save', { content => page('prim_form') }, "action=save&path=sites/mine/new-$_[0].md" ) } ],
        [ 'a new page in mine binding other_form', 'YYN',
            sub { api( $_[0], 'save', { content => page('other_form') }, "action=save&path=sites/mine/oth-$_[0].md" ) } ],
        [ 'a new page in mine binding mine_form', 'YYY',
            sub { api( $_[0], 'save', { content => page('mine_form') }, "action=save&path=sites/mine/own-$_[0].md" ) } ],
        [ 'a new page in mine binding a form that exists nowhere (it creates it)', 'YYY',
            sub { api( $_[0], 'save', { content => page("fresh_$_[0]") }, "action=save&path=sites/mine/fresh-$_[0].md" ) } ],
        [ 'the page already binding prim_form, edited', 'YYY',
            sub { api( $_[0], 'save', { content => page( 'prim_form', "$_[0]\n" ) }, 'action=save&path=sites/mine/shared.md' ) } ],
    );
};

subtest 'the control API: move, copy, upload' => sub {
    run_cells( 'cks',
        [ 'move of the page binding prim_form', 'N',
            sub { api( $_[0], 'move', {}, "action=move&path=sites/mine/shared.md&to=sites/mine/mv-$_[0].md" ) } ],
        [ 'copy of the page binding prim_form', 'N',
            sub { api( $_[0], 'copy', {}, "action=copy&path=sites/mine/shared.md&to=sites/mine/cp-$_[0].md" ) } ],
        [ 'upload of a page binding prim_form', 'N', sub { upload( $_[0], 'sites/mine', "up-$_[0].md", page('prim_form') ) } ],
        [ 'upload of a page binding mine_form', 'Y', sub { upload( $_[0], 'sites/mine', "upm-$_[0].md", page('mine_form') ) } ],
    );
    ok( -e "$d/sites/mine/shared.md", 'the page stayed where it was' );
    run_cells( 'op cku',
        [ 'copy of the page binding prim_form', 'YY',
            sub { api( $_[0], 'copy', {}, "action=copy&path=sites/mine/shared.md&to=sites/mine/cp-$_[0].md" ) } ],
        [ 'upload of a page binding prim_form', 'YY', sub { upload( $_[0], 'sites/mine', "up-$_[0].md", page('prim_form') ) } ],
    );
    ok( api( 'cks', 'move', {}, 'action=move&path=sites/mine/contact.md&to=sites/mine/contact-us.md' )->{ok},
        'cks still renames its own form\'s page' );
};

subtest 'content history: git-restore and restore_version' => sub {
    ok( op( 'git-init', {} )->{ok}, 'set up: content history on' );
    ok( op( 'save', { content => page('prim_form') }, 'action=save&path=sites/mine/hist.md' )->{ok}, 'set up: a version binding prim_form' );
    ok( op( 'save', { content => "---\ntitle: H\n---\nplain\n" }, 'action=save&path=sites/mine/hist.md' )->{ok}, 'set up: then none' );
    my $h   = op( 'git-history', undef, 'action=git-history&path=sites/mine/hist.md' );
    my @v   = @{ $h->{versions} || [] };
    my $old = $v[-1]{sha} // $v[-1]{id} // '';
    like( $old, qr/\A[0-9a-f]{7,40}\z/, 'set up: the old version\'s id' ) or diag( encode_json($h) );
    run_cells( 'cks',
        [ 'git-restore of the version binding prim_form', 'N',
            sub { api( $_[0], 'git-restore', {}, "action=git-restore&path=sites/mine/hist.md&sha=$old" ) } ] );
    run_cells( 'mcs', [ 'restore_version of it', 'N', sub { mcp( $_[0], 'restore_version', { path => 'sites/mine/hist.md', version => $old } ) } ] );
    unlike( slurp("$d/sites/mine/hist.md"), qr/form:/, 'the page still binds nothing' );
    run_cells( 'mcu', [ 'restore_version of it', 'Y', sub { mcp( $_[0], 'restore_version', { path => 'sites/mine/hist.md', version => $old } ) } ] );
};

subtest 'MCP' => sub {
    # replace_text's old and new pass MCP's scope check as content paths (SM661 lists
    # them for rename_page), so the text is shaped as a path inside the scope.
    spit( "$d/sites/mine/plain.md", "---\ntitle: Plain\nsee: sites/mine/a\n---\nhello\n" );
    run_cells( 'mcu mcs',
        [ 'write_file of a new page binding prim_form', 'YN',
            sub { mcp( $_[0], 'write_file', { path => "sites/mine/w-$_[0].md", content => page('prim_form') } ) } ],
        [ 'write_file of the page already binding it', 'YY',
            sub { mcp( $_[0], 'write_file', { path => 'sites/mine/shared.md', content => page( 'prim_form', "$_[0]\n" ) } ) } ],
        [ 'upload_file of a page binding prim_form', 'YN',
            sub { mcp( $_[0], 'upload_file', { path => "sites/mine/u-$_[0].md", content_base64 => encode_base64( page('prim_form'), '' ) } ) } ],
        [ 'copy_file of the page binding prim_form', 'YN',
            sub { mcp( $_[0], 'copy_file', { from => 'sites/mine/shared.md', to => "sites/mine/c-$_[0].md" } ) } ],
    );
    run_cells( 'mcs',
        [ 'replace_text adding a form line', 'N',
            sub { mcp( $_[0], 'replace_text', { path => 'sites/mine/plain.md', old => "sites/mine/a\n", new => "sites/mine/a\nform: prim_form\n" } ) } ],
        [ 'move_file of the page binding prim_form', 'N',
            sub { mcp( $_[0], 'move_file', { from => 'sites/mine/shared.md', to => 'sites/mine/m.md' } ) } ],
        [ 'rename_page of the page binding prim_form', 'N',
            sub { mcp( $_[0], 'rename_page', { old => 'sites/mine/shared', new => 'sites/mine/renamed' } ) } ],
    );
    run_cells( 'mcs',
        [ 'create_form with a new name on a page of its own', 'Y',
            sub { mcp( $_[0], 'create_form', { name => 'join_us', path => 'sites/mine/join' } ) } ] );
    like( slurp("$d/sites/mine/join.md"), qr/form: join_us/, '...and the page binds it' );
    unlike( slurp("$d/sites/mine/plain.md"), qr/form:/, 'plain.md binds nothing' );
    ok( -e "$d/sites/mine/shared.md", 'shared.md stayed where it was' );
};

subtest 'WebDAV' => sub {
    run_cells( 'dvu dvs',
        [ 'PUT of a new page binding prim_form', 'YN', sub { dav( $_[0], 'PUT', "sites/mine/d-$_[0].md", body => page('prim_form') ) } ],
        [ 'PUT of the page already binding it', 'YY', sub { dav( $_[0], 'PUT', 'sites/mine/shared.md', body => page( 'prim_form', "$_[0]\n" ) ) } ],
        [ 'COPY of the page binding prim_form', 'YN', sub { dav( $_[0], 'COPY', 'sites/mine/shared.md', to => "sites/mine/dc-$_[0].md" ) } ],
    );
    my $mv = dav( 'dvs', 'MOVE', 'sites/mine/shared.md', to => 'sites/mine/dm.md' );
    ok( !$mv->{ok}, 'dvs: refused: MOVE of the page binding prim_form' );
    is( $mv->{code}, 403, '...as 403' );
    like( $mv->{error}, qr/would bind the form 'prim_form'/, '...by the form-binding rule' );
    ok( !-e "$d/sites/mine/d-dvs.md" && -e "$d/sites/mine/shared.md", 'nothing landed, nothing moved' );
    ok( dav( 'dvs', 'MOVE', 'sites/mine/contact-us.md', to => 'sites/mine/contact.md' )->{ok}, 'dvs still moves its own form\'s page' );
};

subtest 'site packages: site-backup-apply and site_apply' => sub {
    spit( "$d/sites/mine/pkg.md", page('prim_form') );
    my $pkg = op( 'site-backup-create', { host => 'mine.example.org' } )->{name} // '';
    like( $pkg, qr/\Alazysite-site-/, 'set up: a package of mine carrying a page binding prim_form' );
    unlink "$d/sites/mine/pkg.md";
    run_cells( 'cks tks',
        [ 'site-backup-apply of it to mine', 'NN', sub {
                my $r = api( $_[0], 'site-backup-apply', { name => $pkg, host => 'mine.example.org' } );
                spit( "$d/lazysite/lazysite.conf", $CONF );
                $r } ] );
    run_cells( 'mcs', [ 'site_apply of it to mine', 'N', sub {
                my $r = mcp( $_[0], 'site_apply', { name => $pkg, host => 'mine.example.org' } );
                spit( "$d/lazysite/lazysite.conf", $CONF );
                $r } ] );
    ok( !-e "$d/sites/mine/pkg.md", 'no page of the package landed' );
    my $r = op( 'site-backup-apply', { name => $pkg, host => 'mine.example.org' } );
    ok( $r->{ok}, 'the operator applies it' ) or diag( $r->{error} );
    spit( "$d/lazysite/lazysite.conf", $CONF );
};

done_testing();
