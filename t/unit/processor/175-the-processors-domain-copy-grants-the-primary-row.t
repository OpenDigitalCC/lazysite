#!/usr/bin/perl
# SM1332 (ruling 78): THE PROCESSOR'S COPY OF THE DOMAIN RESOLVER AGREES WITH THE
# MODULE ON THE PRIMARY'S ROW.
#
# The manager's file browser is rooted from lazysite-processor/acl.pm's local copy
# of Auth::DomainAccess (_domain_scopes, _domain_home; ADR 0001: the render path
# loads no Lazysite:: module up front). If the copy did not read the primary's
# row, an account granted the primary would be shown only its other domain while
# every server-side check let it reach the primary. The copy's functions are lifted
# out of the source by name and asked what the module is asked, account by account.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
local @INC = ( "$root/lib", @INC );
require Lazysite::Auth::DomainAccess;

sub lift {
    my ( $src, $name ) = @_;
    my ($body) = $src =~ /^(sub \Q$name\E\b.*?^\})/ms or die "no sub $name";
    return $body;
}

open my $sf, '<', "$root/lazysite-processor/acl.pm" or die $!;
my $src = do { local $/; <$sf> };
close $sf;
my $code = join "\n", map { lift( $src, $_ ) } qw(_read_domain_access _domain_eff _domain_scopes _domain_home);
{
    package ProcCopy;
    our $LAZYSITE_DIR;
    sub _group_closure { return @_ }    # the walk is SM1140's test; here the groups are given
}
## no critic (ProhibitStringyEval)
eval "package ProcCopy; use strict; use warnings; our \$LAZYSITE_DIR; $code; 1" or die "lifting the copy: $@";

my $lz = site_tempdir() . '/lazysite';
make_path($lz);
my $BASE = "alias_hosts: a.test, b.test\nalias.a.test.content_root: sites/a\nalias.a.test.allowed_groups: ga\n"
    . "alias.b.test.content_root: sites/b\nalias.b.test.allowed_groups: gb\nalias.b.test.locked_users: pin\n";

my @WHO = ( [ 'free', [] ], [ 'ua', ['ga'] ], [ 'up', ['gp'] ], [ 'uap', [ 'ga', 'gp' ] ],
    [ 'pin', [ 'ga', 'gb', 'gp' ] ], [ 'gpin', [ 'ga', 'gb', 'lock-a' ] ], [ 'ppin', [ 'ga', 'lock-p' ] ] );

for my $case ( [ 'today\'s data', '' ], [ 'the primary row granted', "allowed_groups: gp\n" ],
    [ 'a group pin, on a domain and on the primary (SM1334)', "alias.a.test.locked_groups: lock-a\nlocked_groups: lock-p\n" ] )
{
    my ( $name, $extra ) = @$case;
    open my $fh, '>', "$lz/lazysite.conf" or die $!;
    print {$fh} $BASE, $extra;
    close $fh;
    $ProcCopy::LAZYSITE_DIR = $lz;
    my $dom = Lazysite::Auth::DomainAccess::read_domains("$lz/lazysite.conf");
    subtest $name => sub {
        for my $w (@WHO) {
            my ( $u, $g ) = @$w;
            is_deeply( [ sort( ProcCopy::_domain_scopes( $u, @$g ) ) ],
                [ sort( Lazysite::Auth::DomainAccess::effective_scopes( $dom, $u, $g ) ) ], "$u: the scopes" );
            is( ProcCopy::_domain_home( $u, @$g ),
                Lazysite::Auth::DomainAccess::effective_home_domain( $dom, $u, $g ), "$u: the home" );
        }
    };
}

# And the answers themselves, so two copies wrong the same way would not pass.
# The last case's conf is in place: the group pins.
is_deeply( [ ProcCopy::_domain_scopes( 'gpin', 'ga', 'gb', 'lock-a' ) ], ['sites/a'], 'a group pinned to a: a only' );
is_deeply( [ ProcCopy::_domain_scopes( 'ppin', 'ga', 'lock-p' ) ], ['/'], 'a group pinned to the primary: the primary' );
open my $fh, '>', "$lz/lazysite.conf" or die $!;
print {$fh} $BASE, "allowed_groups: gp\n";
close $fh;
is_deeply( [ sort( ProcCopy::_domain_scopes( 'uap', 'ga', 'gp' ) ) ], [ '/', 'sites/a' ],
    'granted a and the primary row: both, the primary as the docroot' );

done_testing();
