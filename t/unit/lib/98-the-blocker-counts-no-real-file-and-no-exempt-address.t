#!/usr/bin/perl
# SM1321 (ruling 48, T-03): THE BAD-URL BLOCKER COUNTS NO FILE THE SITE HAS, AND NO
# EXEMPT ADDRESS.
#
# `vendor/` is a probe pattern and also where a theme keeps its scripts. The guard
# counted a site's own /vendor/ assets, and behind a front proxy that did not hand on
# the visitor every request is 127.0.0.1, so one busy page blocked everyone for
# 1h44m. Now a path that resolves to a regular file under the docroot - plain
# segments, no symbolic link on the way, no dot name, not the engine tree - is never
# counted. Loopback is never counted nor refused, and neither is an address in an
# address list `bad_url_exempt` names (rulings 83, 84: the key names lists only and
# adds to loopback; only `none` takes loopback away).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";       # t/lib
use lib "$FindBin::Bin/../../../lib";    # repo lib
use Lazysite::BadUrl qw(guard site_has_file exempt is_blocked);    # and exempt_names, validate_exempt
use Lazysite::Auth::AddressRefs ();

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/cache", "$d/lazysite/logs", "$d/lazysite/auth" );
    spit( "$d/vendor/lib/app.js", "x\n" );
    spit( "$d/index.md",          "---\ntitle: Home\n---\n" );
    return $d;
}

# One request through the guard with threshold 1: a counted probe blocks at once.
sub hit {
    my ( $d, $path, $ip, @conf ) = @_;
    return guard( docroot => $d, path => $path, ip => $ip,
        conf_lines => [ "bad_url_threshold: 1\n", @conf ] );
}

sub hits_of {
    my ( $d, $ip ) = @_;
    open my $fh, '<', "$d/lazysite/cache/bad-url-hits.json" or return 0;
    my $h = eval { decode_json( do { local $/; <$fh> } ) } || {};
    return scalar @{ $h->{$ip} || [] };
}

subtest 'a path resolves to a file of the site only by plain segments' => sub {
    my $d = site();
    my $out = tempdir( CLEANUP => 1 );
    spit( "$out/secret.js", "s\n" );
    spit( "$d/.env",        "K=V\n" );
    spit( "$d/lazysite/vendor/x.js", "e\n" );
    symlink( "$out/secret.js", "$d/vendor/link.js" ) or die "symlink: $!";
    symlink( $out,             "$d/vendor/out" )     or die "symlink: $!";

    ok( site_has_file( $d, '/vendor/lib/app.js' ),        'a real vendor file is the site\'s' );
    ok( site_has_file( $d, '/vendor/lib/app.js?v=3' ),    '...with a query string' );
    ok( site_has_file( $d, '/vendor/lib/%61pp.js' ),      '...percent-encoded' );
    ok( !site_has_file( $d, '/vendor/lib/missing.js' ),   'a missing vendor path is not' );
    ok( !site_has_file( $d, '/vendor/lib' ),              'a folder is not a file' );
    ok( !site_has_file( $d, '/vendor/../vendor/lib/app.js' ), 'a .. segment is not, even onto a real file' );
    ok( !site_has_file( $d, '/vendor/%2e%2e/vendor/lib/app.js' ), '...percent-encoded either' );
    ok( !site_has_file( $d, '/vendor/lib/./app.js' ),     'a . segment is not' );
    ok( !site_has_file( $d, '/vendor/link.js' ),          'a symbolic link to a file is not' );
    ok( !site_has_file( $d, '/vendor/out/secret.js' ),    'a file through a linked folder is not' );
    ok( !site_has_file( $d, '/.env' ),                    'a dot name is not, though it exists' );
    ok( !site_has_file( $d, '/lazysite/vendor/x.js' ),    'the engine tree is not' );
    ok( !site_has_file( $d, '/vendor\\lib\\app.js' ),     'a backslash is not' );
    ok( !site_has_file( $d, '/' ),                        'the root is not' );
};

subtest 'a real vendor file is not counted; a missing one is' => sub {
    my $d = site();
    is( hit( $d, '/vendor/lib/app.js', '192.0.2.10' ), 0, 'a real asset under vendor/ is served' );
    is( hits_of( $d, '192.0.2.10' ), 0, '...and not counted' );
    ok( !is_blocked( $d, '192.0.2.10' ), '...so the address is not blocked' );

    is( hit( $d, '/vendor/phpunit/phpunit/src/Util/eval-stdin.php', '192.0.2.11' ), 1,
        'a vendor path the site does not have is counted and blocks at the threshold' );
    is( hit( $d, '/vendor/../vendor/lib/app.js', '192.0.2.12' ), 1,
        'a traversal onto a real file is still a probe' );
};

subtest 'loopback is always exempt; only none takes it away' => sub {
    my $d = site();
    spit( "$d/lazysite/auth/address-lists.json", encode_json( {
                office => { kind => 'allow', entries => [ { cidr => '198.51.100.7', note => '' } ] } } ) );
    for my $ip (qw(127.0.0.1 127.5.5.5 ::1)) {
        is( hit( $d, '/wp-login.php', $ip ), 0, "$ip: a probe is not counted" );
        is( hit( $d, '/wp-login.php', $ip ), 0, "$ip: nor the next" );
        is( hits_of( $d, $ip ), 0, "$ip: nothing recorded" );
    }
    # A block on file from before (the reported 127.0.0.1) is not enforced.
    spit( "$d/lazysite/cache/bad-url-blocked.json",
        encode_json( { '127.0.0.1' => { since => time, count => 10, path => '/vendor/x' } } ) );
    is( hit( $d, '/', '127.0.0.1' ), 0, 'loopback already in the block store is served' );
    is( hit( $d, '/', '127.0.0.1', "bad_url_exempt:   \n" ), 0, 'an empty key exempts loopback' );
    is( hit( $d, '/', '127.0.0.1', "bad_url_exempt: office\n" ), 0,
        'naming a list ADDS to loopback (ruling 83): loopback is still served' );
    is( hit( $d, '/wp-login.php', '::1', "bad_url_exempt: office\n" ), 0, '...and still not counted' );
    is( hit( $d, '/', '127.0.0.1', "bad_url_exempt: none\n" ), 1, 'with none, the block on file holds' );
    is( hit( $d, '/wp-login.php', '::1', "bad_url_exempt: NONE \n" ), 1, '...and loopback is counted' );
    is_deeply( [ Lazysite::BadUrl::exempt_names(undef) ],         [1],             'absent: loopback' );
    is_deeply( [ Lazysite::BadUrl::exempt_names('none') ],        [0],             'none: nothing' );
    is_deeply( [ Lazysite::BadUrl::exempt_names(' a , b ,') ],    [ 1, 'a', 'b' ], 'names: loopback and the lists' );
    is_deeply( [ Lazysite::BadUrl::exempt_names('none, office') ], [ 1, 'office' ],
        'none among names is no name, and does not take loopback away' );
};

subtest 'bad_url_exempt names address lists only' => sub {
    my $d = site();
    spit( "$d/lazysite/auth/address-lists.json", encode_json( {
                office  => { kind => 'allow', entries => [ { cidr => '198.51.100.7', note => '' } ] },
                scanner => { kind => 'deny',  entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } ) );
    my $conf = "bad_url_exempt: office, scanner\n";
    is( hit( $d, '/wp-login.php', '198.51.100.7', $conf ), 0, 'an address in a named allow list is not counted' );
    is( hit( $d, '/wp-login.php', '203.0.113.9', $conf ), 0, '...nor one in a named deny list (membership only)' );
    is( hits_of( $d, $_ ), 0, "$_: nothing recorded" ) for qw(203.0.113.9 198.51.100.7);
    is( hit( $d, '/wp-login.php', '192.0.2.20', $conf ), 1, 'an address in neither is counted' );
    is( hit( $d, '/wp-login.php', '192.0.2.30', "bad_url_exempt: 192.0.2.30\n" ), 1,
        'an address written in the key is not an exemption (ruling 84)' );
    is( hit( $d, '/wp-login.php', '198.51.100.8', "bad_url_exempt: nosuch\n" ), 1,
        'an unknown list name exempts nobody' );
    ok( exempt( $d, '198.51.100.7', 'office' ), 'exempt() asks the list' );
    ok( !exempt( $d, '', 'office' ), 'no address is never exempt' );

    # The save-time check refuses what would not work, by name.
    my $lz = "$d/lazysite";
    is( Lazysite::BadUrl::validate_exempt( $_, $lz ), '', "'$_' may be stored" )
        for ( 'office', 'office, scanner', '', 'none', ' None ' );
    like( Lazysite::BadUrl::validate_exempt( '203.0.113.0/24', $lz ), qr/'203\.0\.113\.0\/24' is not an address list name/,
        'an address or range is refused: the key names lists only' );
    like( Lazysite::BadUrl::validate_exempt( 'office, nosuch', $lz ), qr/'nosuch' is not an address list/,
        'a name the store does not hold is refused, naming it' );
    unlike( Lazysite::BadUrl::validate_exempt( 'office, nosuch', $lz ), qr/'office'/, '...and only it' );
    like( Lazysite::BadUrl::validate_exempt( 'none, office', $lz ), qr/'none' is the whole value/,
        'none beside names is refused' );
    my $plugin = do { open my $fh, '<', "$FindBin::Bin/../../../plugins/bad-url-blocker.pl" or die $!; local $/; <$fh> };
    like( $plugin, qr/key\s*=>\s*'bad_url_exempt',.*?validate\s*=>\s*'Lazysite::BadUrl::validate_exempt'/s,
        'the Config field names the check' );
    {
        # ...and the Config page's save runs it (Manager::Plugins calls a field's validate_*).
        require TestHelper;
        require Lazysite::Manager::Plugins;
        my $sd = TestHelper::site_tempdir( plugins => 1 );
        make_path("$sd/lazysite/auth");
        spit( "$sd/lazysite/lazysite.conf", "site_name: T\n" );
        spit( "$sd/lazysite/auth/address-lists.json", encode_json( {
                    office => { kind => 'allow', entries => [ { cidr => '198.51.100.7', note => '' } ] } } ) );
        no warnings 'once';
        local $ENV{PERL5LIB} = "$FindBin::Bin/../../../lib" . ( $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '' );
        local $Lazysite::Manager::Plugins::DOCROOT = $sd;
        my $res = Lazysite::Manager::Plugins::action_plugin_save( undef, 'plugins/bad-url-blocker.pl',
            { bad_url_exempt => '10.0.0.0/8' } );
        is( $res->{ok}, 0, 'saving an address in the field is refused' );
        is( $res->{field}, 'bad_url_exempt', '...naming the field' );
        $res = Lazysite::Manager::Plugins::action_plugin_save( undef, 'plugins/bad-url-blocker.pl',
            { bad_url_exempt => 'office' } );
        ok( $res->{ok}, 'saving a list that exists is accepted' ) or diag explain $res;
    }

    # The exemption counts as a use of the list, and lazysite check names a name the
    # store lacks (it reads AddressRefs): every item is a name.
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nbad_url_exempt: office, 192.0.2.30, none\n" );
    my @r = grep { $_->{ref} eq 'bad_url_exempt' } @{ Lazysite::Auth::AddressRefs::rules($d)->{rules} };
    is_deeply( [ map { [ $_->{where}, $_->{slot}, $_->{name} ] } @r ],
        [ [ 'conf', 'match', 'office' ], [ 'conf', 'match', '192.0.2.30' ] ],
        'AddressRefs names each item as a list, so the check reports one the store lacks' );
};

done_testing();
