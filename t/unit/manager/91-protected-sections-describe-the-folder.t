#!/usr/bin/perl
# SM462: the Protected sections panel describes the folder being browsed.
#
# It listed every rule on the site, so an operator standing in one folder read
# the whole estate's protection to find their own - and saw the names of
# protected sections elsewhere, which is not what this screen is for.
#
# THE CASE THAT MAKES IT MORE THAN A FILTER: a rule COVERING the folder must be
# kept, not just rules inside it. /intranet governs /intranet/team, and hiding
# that from the /intranet/team view would answer "is this protected?" with
# silence when the answer is yes - a confident wrong impression about whether
# visitors can see something, which is worse than the noise it removes.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/auth", "$d/intranet/team", "$d/clients/acme",
        "$d/intranet-archive", "$d/open" );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\n";
    close $c;
    open my $a, '>', "$d/lazysite/auth/acls.json" or die $!;
    print {$a} '{"intranet":{"read":["alice"],"owner":"alice"},'
        . '"intranet/team":{"read":["bob"],"owner":"bob"},'
        . '"clients/acme":{"read":["carol"],"owner":"carol"},'
        . '"intranet-archive":{"read":["dave"],"owner":"dave"}}';
    close $a;
    $Lazysite::Manager::Files::DOCROOT  = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
    $Lazysite::Auth::Acl::DOCROOT       = $d;
    $Lazysite::Auth::Acl::LAZYSITE_DIR  = "$d/lazysite";
    return $d;
}

sub prefixes {
    my ($path) = @_;
    my $r = Lazysite::Manager::Files::action_protected_sections( 'op', undef, $path );
    return [ sort map { $_->{prefix} } @{ $r->{sections} || [] } ];
}

subtest 'a folder shows its own rules and not the estate' => sub {
    fixture();
    is_deeply( prefixes('/clients/acme'), ['clients/acme'],
        'only the rule for this folder' )
        or diag( 'Listing every rule makes the operator read the whole site '
            . 'to find their own, and names sections elsewhere that this '
            . 'screen is not for.' );
};

subtest 'a rule COVERING the folder is kept' => sub {
    fixture();
    my $p = prefixes('/intranet/team');
    ok( ( grep { $_ eq 'intranet' } @{$p} ),
        'the parent section that governs this folder is shown' )
        or diag( 'Hiding it answers "is this protected?" with silence when '
            . 'the answer is yes - worse than the noise it removes.' );
    ok( ( grep { $_ eq 'intranet/team' } @{$p} ), 'and the folder\'s own rule' );
    ok( !( grep { $_ eq 'clients/acme' } @{$p} ), 'but not an unrelated one' );
};

subtest 'a parent shows the rules beneath it' => sub {
    fixture();
    my $p = prefixes('/intranet');
    is_deeply( $p, [ 'intranet', 'intranet/team' ],
        'standing at the section root shows it and what is inside' );

    # AND NOT ITS PREFIX SIBLING. intranet-archive starts with the same
    # string, so a bare index($k,$here)==0 claims it - and the operator is
    # shown another section's protection as if it governed theirs. Without
    # this case that sabotage passes cleanly, which it did.
    ok( !( grep { $_ eq 'intranet-archive' } @{$p} ),
        'a folder whose name merely STARTS with this one is not claimed' )
        or diag( 'Boundary-safe containment: /intranet must not swallow '
            . '/intranet-archive. Sixth time this masking has hidden a '
            . 'containment bug in this programme.' );
};

subtest 'an unprotected folder shows nothing, and says nothing wrong' => sub {
    fixture();
    is_deeply( prefixes('/open'), [], 'no rules here' );
};

subtest 'no path given still lists everything' => sub {
    # The standalone panel and any existing caller must not silently start
    # getting a subset.
    fixture();
    my $all = prefixes(undef);
    is( scalar @{$all}, 4, 'unscoped calls are unchanged' );
};

done_testing();
