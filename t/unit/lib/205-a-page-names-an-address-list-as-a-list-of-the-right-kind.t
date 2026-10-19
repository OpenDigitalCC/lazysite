#!/usr/bin/perl
# SM1189 (0.15.10 walk, F-2 and F-3): the validator says what is wrong with a
# page's address rule.
#   F-2  `addresses: zz60-mine` (a bare value, not a list) refused the page and the
#        validator said only "could not be read as a list"; it now says how to
#        write it: "write it as a list: addresses: [name]". auth_groups shares the
#        fault and the sentence.
#   F-3  `addresses_deny: [zz60-mine]`, zz60-mine being an ALLOW list, was ignored
#        in silence; the validator now names the list and the kind it is.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';
use Lazysite::Validate ();

subtest 'a bare value says to write a list' => sub {
    for my $k (qw(addresses addresses_deny auth_groups)) {
        my $u = Lazysite::Validate::read_access_keys("$k: zz60-mine\n")->{unreadable}{$k};
        ok( $u, "$k: a bare value is unreadable" ) or next;
        like( $u, qr/write it as a list: \Q$k\E: \[\w+\]/, '  and the message says to write it as a list, with the form' );
        like( $u, qr/'zz60-mine'/, '  quoting the value it read' );
    }
};

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $fh, '>', "$d/lazysite/auth/address-lists.json" or die $!;
print {$fh} encode_json( {
    mine    => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
    blocked => { kind => 'deny',  entries => [ { cidr => '203.0.113.9',    note => '' } ] },
} );
close $fh;

sub issues_for {
    my ($fm) = @_;
    my $r = Lazysite::Validate::validate_content(
        content => "---\ntitle: T\n$fm---\nbody\n", path => "$d/p.md", docroot => $d, lazysite_dir => "$d/lazysite" );
    return [ grep { $_->{kind} eq 'address-list-wrong-kind' } @{ $r->{issues} } ];
}

subtest 'a list of the wrong kind is an issue that names it' => sub {
    my $i = issues_for("addresses_deny: [mine]\n");
    is( scalar @$i, 1, 'an allow list under addresses_deny is reported' ) or diag explain $i;
    like( $i->[0]{message} // '', qr/'mine', which is an allow list/, '  naming the list and its kind' );
    like( $i->[0]{message} // '', qr/addresses_deny/,          '  and the key' );
    $i = issues_for("addresses: [blocked]\n");
    is( scalar @$i, 1, 'a deny list under addresses is reported' );
    like( $i->[0]{message} // '', qr/'blocked', which is a deny list/, '  naming it' );
    is( scalar @{ issues_for("addresses: [mine]\naddresses_deny: [blocked]\n") }, 0, 'the right kinds: nothing said' );
    is( scalar @{ issues_for("addresses: [nosuch]\n") }, 0, 'a list the store does not hold is not "wrong kind"' );
};

done_testing();
