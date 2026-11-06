#!/usr/bin/perl
# SM1372 (ruling 126): THE PRIMARY'S CONTENT LEAVES OUT THE OTHER DOMAINS' ROOTS,
# over WebDAV, with the resolver running for real (scope_for ->
# resolve_user_scopes).
#
# An account given nothing (unbound) and one granted the primary's row each read
# the whole docroot as their content, and by path that held every other domain's
# folder (sites/...): SM1332's recorded residual risk. Now neither reaches a
# domain's root it is not granted; one granted that domain keeps it, and so does
# the operator (a member of the operator group, SM991).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);

my $DOMAINS = "webdav_enabled: true\nalias_hosts: alpha.test, beta.test\n"
    . "alias.alpha.test.content_root: sites/alpha\nalias.beta.test.content_root: sites/beta\n";

sub site {
    my (%o) = @_;
    my $s = setup_dav_site( conf => $DOMAINS, ( $o{caps} ? ( caps => $o{caps} ) : () ) );
    make_path( "$s->{docroot}/sites/alpha", "$s->{docroot}/sites/beta" );
    open my $ap, '>>', "$s->{docroot}/lazysite/lazysite.conf" or die "conf: $!";
    print {$ap} "allowed_groups: role-$s->{user}\n"                  if $o{primary};
    print {$ap} "alias.alpha.test.allowed_groups: role-$s->{user}\n" if $o{alpha};
    close $ap;
    open my $bp, '>', "$s->{docroot}/sites/beta/existing.md" or die $!;
    print {$bp} "# beta\n";
    close $bp;
    return $s;
}

sub req {
    my ( $s, $m, $path ) = @_;
    return run_dav( $s->{docroot}, $m, $path, HTTP_AUTHORIZATION => $s->{auth},
        ( $m eq 'PUT' ? ( body => "# hi\n" ) : () ) );
}

for my $case ( [ 'unbound (granted nothing)', {} ], [ 'granted the primary row', { primary => 1 } ] ) {
    my ( $label, $o ) = @$case;
    subtest "$label: the primary, not the other domains" => sub {
        my $s = site(%$o);
        isnt( req( $s, 'PUT', '/about.md' )->{code}, 403, 'a primary page is written' );
        for my $m (qw(PUT GET)) {
            my $path = $m eq 'PUT' ? '/sites/beta/new.md' : '/sites/beta/existing.md';
            my $r    = req( $s, $m, $path );
            is( $r->{code}, 403, "$m in another domain's folder is refused" );
            like( $r->{body}, qr{another domain's content \(sites/beta/\)}, '  naming the domain\'s folder' );
        }
        is( req( $s, 'PUT', '/sites/alpha/new.md' )->{code}, 403, 'and so is the other one' );
        ok( !-e "$s->{docroot}/sites/beta/new.md", 'nothing was written there' );
    };
}

subtest 'granted the primary and alpha: alpha too, still not beta' => sub {
    my $s = site( primary => 1, alpha => 1 );
    isnt( req( $s, 'PUT', '/about.md' )->{code},           403, 'the primary' );
    isnt( req( $s, 'PUT', '/sites/alpha/new.md' )->{code}, 403, 'its granted domain' );
    is( req( $s, 'PUT', '/sites/beta/new.md' )->{code}, 403, 'not beta' );
};

subtest 'the operator keeps the whole docroot' => sub {
    my $s = site( caps => [qw(webdav manage_content manager)] );    # the operator group (SM991)
    isnt( req( $s, 'PUT', '/sites/beta/new.md' )->{code}, 403, 'an operator-group member reaches another domain\'s folder' );
};

done_testing();
