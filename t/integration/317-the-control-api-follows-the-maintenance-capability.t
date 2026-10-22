#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): THE CONTROL API IS A MACHINE DOOR, AND A SITE IN
# MAINTENANCE REFUSES IT TO ANYONE WITHOUT `maintenance_access`.
#
#   "The machine doors (MCP, control API, WebDAV) follow the same capability: a
#    caller without it is refused 503 (JSON for the APIs)."
#
# Both ways in: a signed-in person (the manager UI's cookie session, the wrapper
# vouching) and a token client. For each: without the capability, 503 with
# Retry-After and a JSON body; with it, the call is answered as it always was;
# maintenance off, nobody is refused. Per domain: a Host in maintenance refuses,
# another Host does not. The operator can switch it off through this door, so a
# site in maintenance is never stuck.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui manage_content manage_config manage_users maintenance_access);
my $s = new_site( root => $root, conf => "control_api_enabled: true\nmaintenance: on\n" );
my $d = $s->docroot;

$s->add_user($_) for qw(boss ed agent agent2);
$s->grant( 'boss', 'ops', [qw(ui manage_content manage_config manage_users maintenance_access)], \@ALL );
$s->grant( 'ed',    'editors', [qw(ui manage_content)],                \@ALL );
$s->grant( 'agent', 'bots',    [qw(api manage_content manage_config)], \@ALL );
$s->grant( 'agent2', 'night-bots', [qw(api manage_content manage_config maintenance_access)], \@ALL );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my %auth;
for my $u (qw(agent agent2)) {
    my $t = uapi( { action => 'token', username => $u } )->{token} // '';
    ok( length $t, "a token for $u" );
    $auth{$u} = 'Basic ' . encode_base64( "$u:$t", '' );
}

# One API call, returning ( status code, headers, decoded body ). A token client
# when $o{token}; otherwise a signed-in person as the wrapper presents one.
sub api {
    my ( $action, %o ) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN HTTP_AUTHORIZATION)};
    my $body = defined $o{body} ? encode_json( $o{body} ) : undef;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{LAZYSITE_USERS_TOOL} = "$root/tools/lazysite-users.pl";
    $ENV{HTTP_HOST}           = $o{host} // 'site.test';
    $ENV{QUERY_STRING}        = "action=$action";
    $ENV{REQUEST_METHOD}      = defined $body ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}      = defined $body ? length $body : 0;
    if ( $o{token} ) { $ENV{HTTP_AUTHORIZATION} = $auth{ $o{token} } }
    else {
        $ENV{HTTP_X_REMOTE_USER}    = $o{user};
        $ENV{LAZYSITE_AUTH_TRUSTED} = '1';
        $ENV{HTTP_COOKIE}           = $s->cookie_for( $o{user} );
        $ENV{HTTP_X_CSRF_TOKEN}     = $s->csrf_for( $o{user} );
    }
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ],
        stdin => ( $body // '' ) )->{out};
    my ( $head, $jb ) = split /\r?\n\r?\n/, $out // '', 2;
    my ($code) = ( $head // '' ) =~ /^Status:\s*(\d+)/mi;
    my %h;
    $h{ lc $1 } = $2 while ( $head // '' ) =~ /^([A-Za-z-]+):\s*(.*?)\r?$/mg;
    return ( $code // 200, \%h, eval { decode_json( $jb // '' ) } // { _raw => $out } );
}

sub refused {
    my ( $name, @args ) = @_;
    my ( $code, $h, $j ) = api(@args);
    is( $code, 503, "$name: 503" );
    like( $h->{'retry-after'} // '', qr/\A\d+\z/, "$name: with Retry-After" );
    is( $j->{kind}, 'maintenance', "$name: kind maintenance" );
    ok( defined $j->{ok} && !$j->{ok}, "$name: ok false" );
    like( $j->{error} // '', qr/in maintenance/i, "$name: the maintenance message" );
    return;
}
sub served {
    my ( $name, @args ) = @_;
    my ( $code, $h, $j ) = api(@args);
    isnt( $code,            503,           "$name: not refused for maintenance" );
    isnt( $j->{kind} // '', 'maintenance', "$name: no maintenance answer" );
    return $j;
}

subtest 'a signed-in person without the capability is refused' => sub {
    refused( 'ed, whoami',         'whoami', user => 'ed' );
    refused( 'ed, a content read', 'pages',  user => 'ed' );
    refused( 'ed, a write', 'config-set', user => 'ed', body => { key => 'site_name', value => 'x' } );
};

subtest 'a token client without the capability is refused' => sub {
    refused( 'agent, whoami', 'whoami', token => 'agent' );
    refused( 'agent, pages',  'pages',  token => 'agent' );
    refused( 'agent, a write', 'config-set', token => 'agent', body => { key => 'site_name', value => 'x' } );
    unlike( do { open my $f, '<', "$d/lazysite/lazysite.conf"; local $/; <$f> }, qr/site_name: x/, '...and nothing was written' );
};

subtest 'the capability gets through, as it always did' => sub {
    my $j = served( 'boss, whoami', 'whoami', user => 'boss' );
    ok( $j->{ok}, '...answered' );
    $j = served( 'agent2, whoami', 'whoami', token => 'agent2' );
    ok( $j->{ok}, '...answered' );
    $j = served( 'agent2, pages', 'pages', token => 'agent2' );
    ok( $j->{ok}, '...answered' );
};

subtest 'it is the capability, not the role' => sub {
    $s->users( 'group-set', 'bots', 'maintenance_access', 'on' );
    served( 'agent, once granted', 'whoami', token => 'agent' );
    $s->users( 'group-set', 'bots', 'maintenance_access', 'off' );
    refused( 'agent, once taken away', 'whoami', token => 'agent' );
};

subtest 'maintenance off: nobody is refused' => sub {
    conf_set( 'maintenance', 'off' );
    served( 'ed',    'whoami', user  => 'ed' );
    served( 'agent', 'whoami', token => 'agent' );
    conf_set( 'maintenance', 'on' );
};

subtest 'per domain' => sub {
    conf_set( 'maintenance',                 undef );
    conf_set( 'alias_hosts',                 'a.example, b.example' );
    conf_set( 'alias.a.example.maintenance', 'on' );
    refused( 'ed on the domain in maintenance', 'whoami', user => 'ed', host => 'a.example' );
    served( 'ed on its sibling',      'whoami', user => 'ed', host => 'b.example' );
    served( 'ed on the default host', 'whoami', user => 'ed' );
    served( 'boss on the domain in maintenance', 'whoami', user => 'boss', host => 'a.example' );
    conf_set( 'maintenance', 'on' );
    refused( 'ed once the instance switch is on', 'whoami', user => 'ed', host => 'b.example' );
};

subtest 'the operator can switch it off through this door' => sub {
    my ( $code, undef, $j ) = api( 'config-set', user => 'boss', body => { key => 'maintenance', value => 'off' } );
    ok( $j->{ok}, 'config-set maintenance off answers ok' ) or diag( encode_json($j) );
    conf_set( 'alias.a.example.maintenance', undef );
    served( 'ed, once off', 'whoami', user => 'ed' );
};

sub conf_set {
    my ( $key, $val ) = @_;
    my $f = "$d/lazysite/lazysite.conf";
    open my $in, '<', $f or die $!;
    my $t = do { local $/; <$in> };
    close $in;
    $t =~ s/^\Q$key\E\s*:.*\n//mg;
    $t .= "$key: $val\n" if defined $val;
    open my $o, '>', $f or die $!;
    print {$o} $t;
    close $o;
    return;
}

done_testing;
