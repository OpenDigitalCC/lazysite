#!/usr/bin/perl
# SM925 X2: an operator configured a valid XMPP account on a live site and could
# not connect. The port had defaulted to 5222 while the account's own domain
# answered `10 0 47594 xmpp.project.im.` - a different host AND a different port,
# neither unusual, since SRV exists so a client endpoint need not be the JID's
# domain. They ran that lookup by hand and transcribed two values the code could
# have resolved itself.
#
# A REGRESSION, NOT A MISSING FEATURE. notify-xmpp's header says delivery is "based
# on the xmpp-lite connector"; XMPP::Lite resolves SRV and tracks whether the port
# was explicit, and this flow was derived from it without those two clauses.
# Measured 2026-10-01 against the live record: XMPP::Lite::_resolve_srv returns
# `xmpp.project.im 47594`, and `dig +short SRV _xmpp-client._tcp.project.im` agrees.
#
# THE RULE IS THE OPERATOR'S and it is stricter than XMPP::Lite's: "either let SRV
# do its job or specify". SRV is consulted only when NEITHER host nor port is
# given; a conf naming either is obeyed and nothing is looked up.
#
# NO NETWORK AND NO DNS. The first version of this file had neither - it observed
# the choice by attempting a connection and reading the host out of the failure
# message, which reached the real server and failed at auth. That exposed the real
# problem: the endpoint decision had no name. It is `_xmpp_endpoint` now, and this
# calls it directly with $SRV_RESOLVER swapped, the way $XMPP_SENDER already is.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";

require Lazysite::Notify;

my @SRV = ( 'xmpp.project.im', 47594 );

sub endpoint {
    my (%conf) = @_;
    my $srv = delete $conf{_srv};
    my @asked;
    no warnings 'once';
    local $Lazysite::Notify::SRV_RESOLVER = sub {
        push @asked, $_[0];
        return $srv ? @$srv : ();
    };
    my ( $host, $port ) = Lazysite::Notify::_xmpp_endpoint( \%conf, 'project.im' );
    return { host => $host, port => $port, asked => \@asked };
}

subtest 'NEITHER host nor port given: the SRV record decides' => sub {
    my $r = endpoint( _srv => \@SRV );
    is( scalar @{ $r->{asked} }, 1,            'the resolver was consulted once' );
    is( $r->{asked}[0],          'project.im', 'for the JID domain' );
    is( $r->{host}, 'xmpp.project.im', 'the SRV target becomes the host' );
    is( $r->{port}, 47594, 'with the SRV port - not 5222, which is the whole defect' );
};

subtest 'a named PORT means exactly that, and nothing is looked up' => sub {
    my $r = endpoint( port => 5269, _srv => \@SRV );
    is( scalar @{ $r->{asked} }, 0, 'the resolver was NOT consulted' );
    is( $r->{port}, 5269,         'the operator has spoken' );
    is( $r->{host}, 'project.im', 'and the host stays the JID domain' );
};

subtest 'a named HOST means exactly that too - stricter than XMPP::Lite' => sub {
    # XMPP::Lite tracks only whether the PORT was explicit, so it would replace
    # this host from SRV. A host somebody typed is a specification.
    my $r = endpoint( host => 'chat.example', _srv => \@SRV );
    is( scalar @{ $r->{asked} }, 0, 'the resolver was NOT consulted' );
    is( $r->{host}, 'chat.example', 'the named host is obeyed, not overridden' );
    is( $r->{port}, 5222,           'and the port is the standard one' );
};

subtest 'both named: obeyed, and still no lookup' => sub {
    my $r = endpoint( host => 'chat.example', port => 5269, _srv => \@SRV );
    is( scalar @{ $r->{asked} }, 0,              'no lookup' );
    is( $r->{host},              'chat.example', 'host as given' );
    is( $r->{port},              5269,           'port as given' );
};

subtest 'no usable SRV record falls back to the domain and 5222' => sub {
    my $r = endpoint();    # the resolver returns ()
    is( scalar @{ $r->{asked} }, 1, 'the resolver WAS consulted' );
    is( $r->{host}, 'project.im', 'and the JID domain stands' );
    is( $r->{port}, 5222, 'with the standard port - which is what a fallback is for' );
};

subtest 'a blank or non-numeric port counts as NOT named' => sub {
    # The conf is a text file an operator edits; `port:` with nothing after it, or
    # a typo, must not read as "the operator specified something".
    for my $bad ( '', '  ', 'auto', '52a2' ) {
        my $r = endpoint( port => $bad, _srv => \@SRV );
        is( $r->{port}, 47594,
            "port '$bad' is not a specification, so SRV still decides" );
    }
};

# The real resolver, exercised only for the shapes that need no DNS.
subtest 'the real resolver reports a failure rather than swallowing it' => sub {
    my $err = '';
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        # A domain that cannot resolve: the lookup fails or returns nothing, and
        # either way the caller must get () and the operator must get a line.
        my @got = Lazysite::Notify::_resolve_xmpp_srv('invalid..example');
        is( scalar @got, 0, 'nothing usable is returned' );
    }
    # The WARN is conditional on the lookup dying rather than merely answering
    # NXDOMAIN, so this asserts the shape without requiring a resolver to be
    # reachable: either it is silent (clean no-answer) or it names the record.
    ok( $err eq '' || $err =~ /_xmpp-client\._tcp\.invalid\.\.example/,
        'a reported failure names the record it asked for' )
        or diag "stderr was: $err";
};

# The resolver needs Net::DNS, which is not core, so the plugin must declare it or
# X1 happens again inside X2's own repair: enable succeeds, and delivery fails at
# the first notice on a host that has not installed it.
#
# ASSERTED HERE AND NOT IN t/lint/201, deliberately. That lint requires a plugin
# naming a Debian package to declare SOMETHING - it cannot know which modules a
# plugin needs, because the requires live in Lazysite::Notify and the plugin is a
# descriptor, which was X1's whole finding. So removing Net::DNS passes the lint
# (Net::XMPP is still there) and a sabotage pass proved it. This is the gate that
# notices, and it sits beside the code that made the dependency load-bearing.
subtest 'notify-xmpp declares the resolver dependency' => sub {
    require JSON::PP;
    my $plugin = "$FindBin::Bin/../../../plugins/notify-xmpp.pl";
    my $desc   = JSON::PP::decode_json( scalar qx{$^X "$plugin" --describe} );
    my @deps   = @{ $desc->{owns}{deps} // [] };
    ok( ( grep { $_ eq 'Net::DNS' } @deps ),
        'Net::DNS is declared - the SRV lookup needs it and it is not core' )
        or diag "  declared: @deps";
    ok( ( grep { $_ eq 'Net::XMPP' } @deps ), 'and Net::XMPP still is' );

    my ($port_field) = grep { $_->{key} eq 'port' } @{ $desc->{config_schema} };
    ok( $port_field, 'the port field is declared' );
    ok( !exists $port_field->{default},
        'and carries NO default - a pre-filled 5222 overruled the SRV record on '
            . 'every site whose operator left the field alone' );
};

done_testing();
