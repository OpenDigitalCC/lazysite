#!/usr/bin/perl
# SM1332 (ruling 78): over WebDAV, an account whose group is named on a
# secondary domain and on the PRIMARY's row reaches both - the scope the primary
# grant adds (the docroot) is read by the content check as the whole site, as an
# unbound account's is. Before, that check skipped a scope with no folder in it,
# and the primary grant would have reached nothing more.
#
# The resolver runs for real here (scope_for -> resolve_user_scopes), so this is
# also the upgrade: the same account with no primary grant keeps its one domain.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);

sub put {
    my ( $s, $path ) = @_;
    return run_dav( $s->{docroot}, 'PUT', $path, HTTP_AUTHORIZATION => $s->{auth}, body => "# hi\n" );
}

sub site {
    my ($grant_primary) = @_;
    my $s = setup_dav_site( scope => 'content/a' );
    make_path( "$s->{docroot}/content/a", "$s->{docroot}/content/b" );
    if ($grant_primary) {
        open my $ap, '>>', "$s->{docroot}/lazysite/lazysite.conf" or die "conf: $!";
        print {$ap} "allowed_groups: role-$s->{user}\n";
        close $ap;
    }
    return $s;
}

subtest 'scoped to a secondary only: its domain and nothing else, as before' => sub {
    my $s = site(0);
    isnt( put( $s, '/content/a/page.md' )->{code}, 403, 'its own domain' );
    my $r = put( $s, '/content/b/page.md' );
    is( $r->{code}, 403, 'the primary\'s content is refused' );
    like( $r->{body}, qr{outside your assigned WebDAV scope \(content/a/\)}, '...by its scope' );
};

subtest 'granted the primary row as well: both' => sub {
    my $s = site(1);
    isnt( put( $s, '/content/a/page.md' )->{code}, 403, 'its own domain' );
    my $r = put( $s, '/content/b/page.md' );
    isnt( $r->{code}, 403, 'the primary\'s content is reached' );
    is( $r->{headers}{'x-lazysite-deny-reason'}, undef, '...with no deny reason' );
};

done_testing();
