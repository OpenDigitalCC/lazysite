#!/usr/bin/perl
# SM1131 / SM1132 / SM1133 (SM1128 phase 1): the request's identity has ONE
# reader, Lazysite::Auth::Identity::request_identity.
#
# It answers which headers (the configured names under a trusted proxy, the fixed
# names behind the auth wrapper), how a groups header splits (the configured
# separator, each part trimmed, empties dropped), and what a directory group is
# called here (the explicit map, else normalised). The environment, a conf hash
# and the site's lazysite.conf in (the last for proxy_identity's answer, SM1129),
# a hash out.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Identity qw(request_identity normalise_group_name parse_group_map);

my @ENVS = qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_NAME HTTP_X_REMOTE_EMAIL HTTP_X_REMOTE_GROUPS
    HTTP_X_AUTHENTIK_USERNAME HTTP_X_AUTHENTIK_NAME HTTP_X_AUTHENTIK_EMAIL HTTP_X_AUTHENTIK_GROUPS
    LAZYSITE_AUTH_TRUSTED);

# SM1129: whether the proxy is trusted for the request is NOT read from the
# conf hash: the reader asks Lazysite::Util::proxy_identity, which reads the
# site's lazysite.conf and the peer. So the site written here carries the flag
# (as the hash says) and a trust list naming the loopback peer the request
# comes from; the header names come from the hash, as the processor's do.
sub site_conf {
    my ($text) = @_;
    my $d = site_tempdir();
    mkdir "$d/lazysite";
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} $text;
    close $fh;
    return "$d/lazysite";
}

sub ident {
    my ( $env, $conf, %o ) = @_;
    my $flag = lc( $conf->{auth_proxy_trusted} // '' ) eq 'true';
    my $lz   = site_conf( $flag ? "auth_proxy_trusted: true\nauth_proxy_trusted_from: 127.0.0.1\n" : '' );
    local %ENV = %ENV;
    delete @ENV{@ENVS};
    $ENV{REMOTE_ADDR} = '127.0.0.1';
    @ENV{ keys %$env } = values %$env;
    return request_identity( conf => $conf, lazysite_dir => $lz, %o );
}

my %authentik = (
    auth_proxy_trusted        => 'true',
    auth_header_user          => 'X-Authentik-Username',
    auth_header_name          => 'X-Authentik-Name',
    auth_header_email         => 'X-Authentik-Email',
    auth_header_groups        => 'X-Authentik-Groups',
    auth_header_groups_separator => '|',
);
my %hdr = (
    HTTP_X_AUTHENTIK_USERNAME => 'sam',
    HTTP_X_AUTHENTIK_NAME     => 'Sam Q',
    HTTP_X_AUTHENTIK_EMAIL    => 'sam@example.org',
    HTTP_X_AUTHENTIK_GROUPS   => 'Site Editors|Members',
);

subtest 'SM1131: a trusted proxy is read under the configured names' => sub {
    my $i = ident( \%hdr, \%authentik );
    is( $i->{user},  'sam',             'user' );
    is( $i->{name},  'Sam Q',           'name' );
    is( $i->{email}, 'sam@example.org', 'email' );
    is( $i->{source}, 'proxy',          'source' );
};

subtest 'SM1131: the configured names count only under auth_proxy_trusted' => sub {
    my $i = ident( \%hdr, { %authentik, auth_proxy_trusted => 'false' } );
    is( $i->{user}, '', 'a header a visitor sent under a custom name is nobody' );
    is_deeply( $i->{groups}, [], 'and has no groups' );
};

subtest 'SM1131: behind the wrapper the fixed names are the identity' => sub {
    my $i = ident(
        { HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'Admins,members',
            LAZYSITE_AUTH_TRUSTED => 1, %hdr },
        \%authentik );
    is( $i->{user}, 'alice', 'the cookie user, not the proxy header sent beside it' );
    is( $i->{source}, 'cookie', 'source' );
    is_deeply( $i->{groups}, [ 'Admins', 'members' ],
        'cookie groups come back as stored: no map, no normalising, no lowercasing' );
};

subtest 'SM1131: defaults are the X-Remote-* names' => sub {
    my $i = ident(
        { HTTP_X_REMOTE_USER => 'bob', HTTP_X_REMOTE_GROUPS => 'a,b' },
        { auth_proxy_trusted => 'true' } );
    is( $i->{user}, 'bob', 'default user header' );
    is_deeply( $i->{groups}, [ 'a', 'b' ], 'default groups header, comma' );
    my $d = ident( { HTTP_X_REMOTE_USER => 'cy' }, {} );
    is( $d->{user}, 'cy', 'no flag, no wrapper: the fixed names (stripped by the gates in service)' );
    is( $d->{source}, 'direct', 'source' );
};

subtest 'SM1132: the separator is configured; parts are trimmed; empties dropped' => sub {
    my $c = { %authentik, auth_header_groups_separator => '|' };
    is_deeply(
        ident( { HTTP_X_AUTHENTIK_USERNAME => 'u', HTTP_X_AUTHENTIK_GROUPS => ' a | |b||  c ' }, $c )->{groups},
        [ 'a', 'b', 'c' ], 'pipe, spaces around, empty parts' );
    my $comma = { %authentik };
    delete $comma->{auth_header_groups_separator};
    is_deeply(
        ident( { HTTP_X_AUTHENTIK_USERNAME => 'u', HTTP_X_AUTHENTIK_GROUPS => 'a, b ,,c' }, $comma )->{groups},
        [ 'a', 'b', 'c' ], 'default separator is the comma' );
    is_deeply(
        ident( { HTTP_X_AUTHENTIK_USERNAME => 'u', HTTP_X_AUTHENTIK_GROUPS => 'Site Editors, Members' }, $comma )->{groups},
        [ 'site-editors', 'members' ], 'a space inside a name is not a separator' );
    is_deeply(
        ident( { HTTP_X_AUTHENTIK_USERNAME => 'u', HTTP_X_AUTHENTIK_GROUPS => 'a|a|A' }, $c )->{groups},
        ['a'], 'a name listed twice (after normalising) is one group' );
};

subtest 'SM1133: normalising' => sub {
    is( normalise_group_name('Site Editors'),   'site-editors', 'space to hyphen, lowercased' );
    is( normalise_group_name('  Ops & Dev / EU '), 'ops-dev-eu', 'a run of other characters is one hyphen; ends trimmed' );
    is( normalise_group_name('keep_this-one'),  'keep_this-one', 'underscore and hyphen kept' );
    is( normalise_group_name('Caf' . "\x{e9}" . ' Staff'), 'caf-staff', 'non-ASCII is outside the class' );
    is( length( normalise_group_name( 'x' x 100 ) ), 64, 'cut to 64' );
    is( normalise_group_name( ( 'x' x 63 ) . ' yy' ), 'x' x 63, 'a hyphen left at the cut is trimmed' );
    is( normalise_group_name('---'), '', 'nothing left is empty' );
    is( normalise_group_name('!!!'), '', 'nothing left is empty (symbols)' );
};

subtest 'SM1133: the map wins; an empty name is dropped with a WARN' => sub {
    my $c = { %authentik,
        auth_group_map => 'Site Editors = Editors, Platform Admins=operators' };
    is_deeply(
        ident( { HTTP_X_AUTHENTIK_USERNAME => 'u',
                HTTP_X_AUTHENTIK_GROUPS => 'site  editors|platform admins|Members' }, $c )->{groups},
        [ 'Editors', 'operators', 'members' ],
        'the map (case- and space-insensitive on the directory name, target as written) wins; the rest normalise' );

    my $err = '';
    {
        local *STDERR;
        open STDERR, '>', \$err or die;
        my $i = ident( { HTTP_X_AUTHENTIK_USERNAME => 'u', HTTP_X_AUTHENTIK_GROUPS => '???|Members' }, \%authentik );
        is_deeply( $i->{groups}, ['members'], 'a name that normalises to nothing is dropped' );
    }
    like( $err, qr/\[WARN\].*directory group dropped/, 'and says so' );

    $err = '';
    {
        local *STDERR;
        open STDERR, '>', \$err or die;
        my $m = parse_group_map('Good = ok, Bad = not a name!, = x, nothing');
        is_deeply( $m, { good => 'ok' }, 'a malformed map entry is ignored' );
    }
    like( $err, qr/auth_group_map entry ignored/, 'and named in the log' );
};

subtest 'the conf can come from a file' => sub {
    my $d = site_tempdir();
    mkdir "$d/lazysite";
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "auth_proxy_trusted: true\nauth_proxy_trusted_from: 127.0.0.1\n"
        . "auth_header_groups: X-Authentik-Groups\n"
        . "auth_header_groups_separator: |\nauth_group_map: Site Editors = editors\n";
    close $fh;
    local %ENV = %ENV;
    delete @ENV{@ENVS};
    $ENV{REMOTE_ADDR}              = '127.0.0.1';
    $ENV{HTTP_X_REMOTE_USER}       = 'u';
    $ENV{HTTP_X_AUTHENTIK_GROUPS}  = 'Site Editors|Members';
    my $i = request_identity( lazysite_dir => "$d/lazysite" );
    is_deeply( $i->{groups}, [ 'editors', 'members' ], 'read from lazysite.conf' );
};

# SM1129 + SM1131: THE READER'S PROXY IS proxy_identity's PROXY. Which header
# names count is decided by "is the proxy trusted for THIS request", never by the
# flag alone - in service the trust gates have already stripped an unlisted
# peer's headers, so only a direct call can show the reader does not re-open
# what the hop check closed.
subtest 'SM1129: the configured names count only when proxy_identity trusts the peer' => sub {
    my $call = sub {
        my ( $conf_text, $addr, %o ) = @_;
        my $lz = site_conf($conf_text);
        local %ENV = %ENV;
        delete @ENV{@ENVS};
        $ENV{REMOTE_ADDR} = $addr;
        @ENV{ keys %hdr } = values %hdr;
        return request_identity( conf => \%authentik, lazysite_dir => $lz, %o );
    };
    my $on = "auth_proxy_trusted: true\n";

    my $i = $call->( "${on}auth_proxy_trusted_from: 10.0.0.0/8\n", '10.1.2.3' );
    is( $i->{user},   'sam',   'a listed peer: the proxy user' );
    is( $i->{source}, 'proxy', 'source proxy' );

    $i = $call->( "${on}auth_proxy_trusted_from: 10.0.0.0/8\n", '192.0.2.7' );
    is( $i->{user}, '', 'an unlisted peer: the configured names are not read' );
    is( $i->{source}, 'direct', 'and the source is not the proxy' );
    is_deeply( $i->{groups}, [], 'no groups either' );

    $i = $call->( $on, '10.1.2.3' );
    is( $i->{user}, '', 'the flag with no trust list: nobody (it fails closed)' );

    $i = $call->( '', '10.1.2.3' );
    is( $i->{user}, '', 'the flag set only in the conf HASH is not a trusted proxy' );

    {
        local %ENV = %ENV;
        delete @ENV{@ENVS};
        @ENV{ keys %hdr } = values %hdr;
        $i = request_identity( conf => \%authentik );
    }
    is( $i->{user}, '', 'nothing to ask (no lazysite_dir, no answer): untrusted' );

    $i = $call->( "${on}auth_proxy_trusted_from: 10.0.0.0/8\n", '10.1.2.3', proxy => { trusted => 0 } );
    is( $i->{user}, '', "the caller's answer for this request is the one used" );
};

done_testing();
