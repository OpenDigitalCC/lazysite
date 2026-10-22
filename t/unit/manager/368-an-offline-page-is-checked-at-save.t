#!/usr/bin/perl
# SM1197 (inbox 2026-10-19): app_offline_pages and app_update are on the Config page
# and in the config-set allow list. A page kept on a device for offline use must be
# the same for every visitor, so a path the engine would not keep is REFUSED AT
# SAVE, naming the path and the reason, and the parity subtest runs the same pages
# through config-set and through the engine's worker so the two cannot disagree.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol     qw(gensym);
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps site_tempdir setup_test_site run_processor);
use PageScript qw(page_source extract_function);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' ); close $w;
    my $out = do { local $/; <$r> }; close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }
sub conf  { open my $f, '<', "$_[0]/lazysite/lazysite.conf" or die $!; local $/; <$f> }
sub put {
    my ( $path, $text ) = @_;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $o, '>', $path or die "$path: $!";
    print {$o} $text;
    close $o;
}

my $d = site_tempdir();
setup_test_site($d);
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "control_api_enabled: true\n"; close $cf;
put( "$d/assets/$_", "/* $_ */\n" ) for qw(lazysite-chrome.css lazysite-chrome.js lazysite-app.js);

my %page = ( # path => [ source, why it is refused (undef: accepted), word the refusal must carry ]
    '/portal/' => [ "---\ntitle: P\n---\nP.\n", undef ],
    '/portal/new' => [ "---\ntitle: N\ntt_page_var:\n  cats: odoo:expense-categories\n---\nN.\n", undef ],
    '/portal/open'     => [ "---\ntitle: O\nauth: none\n---\nO.\n",           undef ],
    '/portal/private'  => [ "---\ntitle: P\nauth: required\n---\nP.\n",       'sign-in' ],
    '/portal/optional' => [ "---\ntitle: P\nauth: optional\n---\nP.\n",       'sign-in' ],
    '/portal/groups'   => [ "---\ntitle: G\nauth_groups: [staff]\n---\nG.\n", 'group' ],
    '/portal/paid'     => [ "---\ntitle: P\npayment: required\n---\nP.\n",    'paid' ],
    '/portal/office'   => [ "---\ntitle: O\naddresses: [office]\n---\nO.\n",  'address' ],
    '/portal/broken' => [ "---\ntitle: B\nauth_groups: staff\n---\nB.\n", 'cannot read' ],
    '/portal/me' => [ "---\ntitle: M\ntt_page_var:\n  me: odoo-identity:\n---\nM.\n", 'odoo-identity' ],
    '/portal/mine' => [ "---\ntitle: M\ntt_page_var:\n  r: db:notes(mine)\n---\nM.\n", 'mine' ],
    '/portal/live'      => [ "---\ntitle: L\nnocache: true\n---\nL.\n", 'nocache' ],
    '/portal/api'       => [ "---\ntitle: A\napi: true\n---\n{}\n",     'data page' ],
    '/portal/acl/page'  => [ "---\ntitle: A\n---\nA.\n",                'access rule' ],
    '/portal/addr/page' => [ "---\ntitle: A\n---\nA.\n",                'access rule' ],
    '/outside/'         => [ "---\ntitle: O\n---\nO.\n",                'scope' ],
);
for my $p ( keys %page ) {
    ( my $f = $p ) =~ s{\A/}{};
    $f .= 'index' if $f eq '' || $f =~ m{/\z};
    put( "$d/$f.md", $page{$p}[0] );
}
put( "$d/lazysite/auth/acls.json",
    encode_json( { 'portal/acl' => { read => ['@staff'] }, 'portal/addr' => { addresses => ['office'] } } ) );

uapi( $d, { action => 'add', username => 'p', password => 'x-long-enough' } );
grant_caps( $d, 'p', 'manage_config', 'api' );
my $tok = uapi( $d, { action => 'token', username => 'p' } )->{token};
ok( $tok && $tok =~ /^lzs_/, 'minted a manage_config token' );

sub set {
    my ( $k, $v ) = @_;
    return mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
        HTTP_AUTHORIZATION => basic( 'p', $tok ),
        body               => encode_json( { key => $k, value => $v } ) );
}
ok( set( app_name  => 'Pocket Portal' )->{ok}, 'an app' );
ok( set( app_scope => '/portal/' )->{ok},      'with a scope' );

subtest 'a page the engine would keep is accepted' => sub {
    ok( set( app_offline_pages => '/portal/' )->{ok}, 'the start page' );
    ok( set( app_offline_pages => '/portal/, /portal/new, /portal/open' )->{ok},
        'a list, with a page that has an odoo: binding in it' );
    like( conf($d), qr{^app_offline_pages: /portal/, /portal/new, /portal/open$}m, 'written to lazysite.conf' );
};

subtest 'a page that is not the same for every visitor is refused, naming the path' => sub {
    for my $p ( sort grep { defined $page{$_}[1] } keys %page ) {
        my $r = set( app_offline_pages => "/portal/, $p" );
        ok( !$r->{ok}, "refused: $p" );
        like( $r->{error} // '', qr/\Q$p\E/, '... the refusal names the path' );
        like( $r->{error} // '', qr/app_offline_pages/, '... and the setting' );
        like( $r->{error} // '', qr/\Q$page{$p}[1]\E/i, "... and says why ($page{$p}[1])" );
        is( $r->{field}, 'app_offline_pages', '... as a field error' );
    }
    unlike( conf($d), qr/private|groups|paid/, 'and none of them was written' );
    like( conf($d), qr{^app_offline_pages: /portal/, /portal/new, /portal/open$}m, 'the stored list is as it was' );
};

subtest 'paths the worker never handles, and paths that are not pages' => sub {
    my %bad = (
        '/cgi-bin/lazysite-odoo.pl' => 'endpoint',
        '/portal/lazysite-auth.pl'  => 'endpoint',
        '/lazysite/cache/x'         => 'engine tree',
        '/manager/'                 => 'manager',
        '/login'                    => 'sign-in',
        '/portal/missing'           => 'not a page',
        '/portal/../x'              => 'plain site path',
        '/portal/new?x=1'           => 'plain site path',
        'portal/new'                => 'plain site path',
        '/portal/a b'               => 'plain site path',
    );
    for my $p ( sort keys %bad ) {
        my $r = set( app_offline_pages => "/portal/, $p" );
        ok( !$r->{ok}, "refused: $p" );
        like( $r->{error} // '', qr/\Q$bad{$p}\E/i, "... saying: $bad{$p}" );
    }
};

subtest 'SM1243: a list separated by spaces is refused saying it takes commas' => sub {
    # #372c, the 0.15.15 test-plan results: "/zz75/a /zz75/m" was refused as not
    # a plain site path, which is true, and the answer did not say the list is
    # separated by commas - which is the whole of what the caller got wrong.
    my $r = set( app_offline_pages => '/portal/ /portal/new' );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/not a plain site path/, '... as not a plain site path' );
    like( $r->{error} // '', qr/separated by commas/, '... saying the list takes commas' );
    like( $r->{error} // '', qr{e\.g\. /portal/, /portal/new\z}, '... with the list written that way' );
    my $one = set( app_offline_pages => '/portal/, /portal/a b' );
    unlike( $one->{error} // '', qr/commas/, 'a single path with a space in it gets no such hint' );
    like( conf($d), qr{^app_offline_pages: /portal/, /portal/new, /portal/open$}m, 'the stored list is as it was' );
};

subtest 'a site where every page is gated by default keeps only what says auth: none' => sub {
    open my $a, '>>', "$d/lazysite/lazysite.conf" or die $!; print {$a} "auth_default: required\n"; close $a;
    my $r = set( app_offline_pages => '/portal/' );
    ok( !$r->{ok}, 'a page with no auth line is gated by auth_default' );
    like( $r->{error} // '', qr/sign-in/, '... and says so' );
    ok( set( app_offline_pages => '/portal/open' )->{ok}, 'a page that says auth: none is fine' );
    my $c = conf($d); $c =~ s/^auth_default: required\n//m;
    open my $o, '>', "$d/lazysite/lazysite.conf" or die $!; print {$o} $c; close $o;
    ok( set( app_offline_pages => '/portal/, /portal/new, /portal/open' )->{ok}, 'restored' );
};

subtest 'the scope may not strand a stored page, and a page must be inside the scope' => sub {
    my $r = set( app_scope => '/other/' );
    ok( !$r->{ok}, 'a scope that leaves a stored page outside it is refused' );
    like( $r->{error} // '', qr/app_offline_pages/, '... naming the setting to change first' );
    $r = set( app_offline_pages => '/outside/' );
    ok( !$r->{ok}, 'a page outside the scope is refused' );
    like( $r->{error} // '', qr/scope/, '... saying so' );
};

subtest 'app_update takes now or wait' => sub {
    ok( set( app_update => 'wait' )->{ok}, 'wait' );
    ok( set( app_update => 'now' )->{ok},  'now' );
    my $r = set( app_update => 'later' );
    ok( !$r->{ok}, 'anything else is refused' );
    like( $r->{error} // '', qr/app_update/, '... naming the key' );
    ok( set( app_update => '' )->{ok}, 'and it clears' );
};

subtest 'both keys clear, and config-read shows them' => sub {
    set( app_update => 'wait' );
    my $r = mapi( $d, QUERY_STRING => 'action=config-read', HTTP_AUTHORIZATION => basic( 'p', $tok ) );
    is( $r->{config}{app_update}, 'wait', 'app_update read back' );
    like( $r->{config}{app_offline_pages}, qr{/portal/new}, 'and the page list' );
    ok( set( app_offline_pages => '' )->{ok}, 'the list clears' );
    ok( set( app_update        => '' )->{ok}, 'and so does the update mode' );
};

subtest 'parity: config-set accepts exactly the pages the engine puts in the worker' => sub {
    set( app_offline_pages => '' );
    my $keep = conf($d);
    for my $mode ( 'plain', 'auth_default' ) {
        my $extra = $mode eq 'auth_default' ? "auth_default: required\n" : '';
        open my $o, '>', "$d/lazysite/lazysite.conf" or die $!;
        print {$o} $keep, $extra;
        close $o;
        my %accepted = map { $_ => ( set( app_offline_pages => $_ )->{ok} ? 1 : 0 ) }
            ( keys %page, '/portal/missing', '/cgi-bin/lazysite-odoo.pl', '/manager/' );
        set( app_offline_pages => '' );
        open $o, '>', "$d/lazysite/lazysite.conf" or die $!;
        print {$o} $keep, $extra, 'app_offline_pages: ', join( ', ', sort keys %accepted ), "\n";
        close $o;
        my $out = run_processor( $d, '/portal/lazysite-sw.js' );
        my ( undef, $js ) = split /\r?\n\r?\n/, $out, 2;
        my ($list) = ( $js // '' ) =~ /"pages":(\[[^\]]*\])/;
        my %listed = map { $_ => 1 } @{ decode_json( $list // '[]' ) };
        for my $p ( sort keys %accepted ) {
            is( $listed{$p} ? 1 : 0, $accepted{$p}, "($mode) $p: the engine lists it exactly when config-set accepts it" );
        }
        ok( scalar( grep { $accepted{$_} } keys %accepted ), "($mode) and the comparison covered a page that is accepted" );
        ok( scalar( grep { !$accepted{$_} } keys %accepted ), "($mode) and one that is refused" );
    }
    open my $o, '>', "$d/lazysite/lazysite.conf" or die $!; print {$o} $keep; close $o;
};

subtest 'the Config page offers both' => sub {
    my $src = page_source("$root/starter/manager/config.md");
    my $js  = join "\n",
        ( $src =~ /(var SITE_SCHEMA = \[.*?\n\];)/s )[0]     // die('no SITE_SCHEMA'),
        ( $src =~ /(var SERVICE_PRESETS = \{.*?\n\};)/s )[0] // die('no presets'),
        extract_function( $src, 'esc' ),
        extract_function( $src, 'renderSiteForm' );
    my $t = File::Temp->new( SUFFIX => '.js' );
    print {$t} "var availableLayouts = [];\nvar location = {protocol:'https:',host:'x'};\n$js\n"
        . "console.log(JSON.stringify({html: renderSiteForm({app_offline_pages:'/portal/'}), keys: SITE_SCHEMA.map(function(f){return f.key})}));\n";
    close $t;
    my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`; chomp $node;
    plan skip_all => 'node not installed' unless length $node;
    my $out = `\Q$node\E \Q$t\E 2>&1`;
    my $got = eval { decode_json($out) } or BAIL_OUT("page script did not run: $out");
    for my $k (qw(app_offline_pages app_update)) {
        ok( ( grep { $_ eq $k } @{ $got->{keys} } ), "$k is a field" );
        like( $got->{html}, qr/name="\Q$k\E"/, "$k is rendered" );
    }
    like( $got->{html}, qr{value="/portal/"}, 'with the stored value' );
};

done_testing();
