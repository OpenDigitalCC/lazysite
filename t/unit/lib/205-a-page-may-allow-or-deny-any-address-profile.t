#!/usr/bin/perl
# SM1189 (0.15.10 walk, F-2 and F-3): the validator says what is wrong with a
# page's address rule.
#   F-2  `addresses: zz60-mine` (a bare value, not a list) refused the page and the
#        validator said only "could not be read as a list"; it now says how to
#        write it: "write it as a list: addresses: [name]". auth_groups shares the
#        fault and the sentence.
#   F-3  `addresses_deny: [zz60-mine]`, zz60-mine being an ALLOW list, was ignored
#        in silence, and the validator was made to name the list and its kind.
# SM1343 (0.16.5): a profile has no kind, so a page may allow or deny any profile
# and the validator says nothing about which slot names it. Every issue the page
# raises is collected, so a kind-shaped complaint under any name fails here.
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
open my $fh, '>', "$d/lazysite/auth/address-profiles.json" or die $!;
print {$fh} encode_json( {
    # A kind left by a hand edit (or an unconverted record) is ignored: a page names
    # the slot.
    mine    => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
    blocked => { kind => 'deny',  entries => [ { cidr => '203.0.113.9',    note => '' } ] },
} );
close $fh;

sub issues_for {
    my ($fm) = @_;
    my $r = Lazysite::Validate::validate_content(
        content => "---\ntitle: T\n$fm---\nbody\n", path => "$d/p.md", docroot => $d, lazysite_dir => "$d/lazysite" );
    return [ grep { ( $_->{key} // '' ) =~ /\Aaddresses/ || ( $_->{message} // '' ) =~ /address|profile/i }
            @{ $r->{issues} } ];
}

subtest 'a page may allow or deny any profile, and nothing is said' => sub {
    for my $fm ( "addresses_deny: [mine]\n", "addresses: [blocked]\n", "addresses: [mine]\naddresses_deny: [blocked]\n",
        "addresses: [blocked]\naddresses_deny: [mine]\n", "addresses: [nosuch]\n" )
    {
        ( my $say = $fm ) =~ s/\n/; /g;
        is_deeply( issues_for($fm), [], "$say no issue" );
    }
};

done_testing();
