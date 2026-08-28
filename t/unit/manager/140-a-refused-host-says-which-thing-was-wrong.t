#!/usr/bin/perl
# Site agent, 2026-08-28: "domain-add rejects new hosts with a bare 'Invalid
# domain host' and no rule ... A fresh agent/operator adding a domain cannot
# tell what a valid host is. BLOCKS SM647."
#
# It did block it. The message was returned for two different problems - no host
# supplied, and a malformed one - and named neither. domain-set and domain-add
# read `host` from the JSON BODY only, so an agent sending it in the query
# string got a message blaming a value it had checked carefully, and went
# looking at the host instead of at where it put it. Same class as SM237.
#
# THREE COPIES of the host rule existed: valid_host, a regex in domain_preview,
# and a third in the manager API's own domain-check. Three copies of one rule
# can answer differently for the same host on different actions, which is
# SM662's subject. They are one rule now.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

require Lazysite::Manager::Domains;

subtest 'absent and malformed are told apart' => sub {
    my $none = Lazysite::Manager::Domains::host_refusal('');
    like( $none->{error}, qr/No domain host was supplied/,
        'an absent host says so' );
    like( $none->{error}, qr/JSON body/,
        'and says where to put it - which is the part that was missing' )
        or diag( 'The agent sent it in the query string and was told the host '
            . 'was invalid.' );

    my $bad = Lazysite::Manager::Domains::host_refusal('not a host!');
    like( $bad->{error}, qr/Invalid domain host/, 'a malformed host says that' );
    like( $bad->{error}, qr/not a host!/, 'and quotes what it was given' );
    like( $bad->{error}, qr/dot-separated labels/,
        'and states the rule, so a caller can correct it without guessing' );
};

subtest 'one rule, not three' => sub {
    my $dom = do {
        open my $fh, '<', repo_root() . '/lib/Lazysite/Manager/Domains.pm' or die $!;
        local $/;
        <$fh>;
    };
    my $api = do {
        open my $fh, '<', repo_root() . '/lazysite-manager-api.pl' or die $!;
        local $/;
        <$fh>;
    };
    # The literal host regex must appear nowhere but inside valid_host.
    my $copies = () = ( $dom . $api ) =~ /\[a-z0-9-\]\*\[a-z0-9\]/g;
    cmp_ok( $copies, '<=', 1, 'the host pattern is written once' )
        or diag( "found $copies copies - two that disagree answer differently "
            . 'for the same host on different actions.' );
    unlike( $api, qr/'Invalid domain host'/,
        'and the manager API no longer carries its own refusal' );
};

subtest 'the rule itself still refuses what it should' => sub {
    ok( Lazysite::Manager::Domains::valid_host('edge3.explore.lazysite.io'), 'an FQDN' );
    ok( Lazysite::Manager::Domains::valid_host('edge3'),                     'a single label' );
    ok( !Lazysite::Manager::Domains::valid_host('(default)'),
        'the primary row is not addressable as a host' );
    ok( !Lazysite::Manager::Domains::valid_host('a..b'), 'an empty label' );
    ok( !Lazysite::Manager::Domains::valid_host('-lead'), 'a leading hyphen' );
    ok( !Lazysite::Manager::Domains::valid_host(''),      'nothing at all' );
};

done_testing();
