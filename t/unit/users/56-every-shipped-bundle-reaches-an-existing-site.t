#!/usr/bin/perl
# SM1241 (#369): a bundle a release adds reaches a site seeded before it.
#
# The cap-* bundles and ch-* channels are seeded only when groups-settings.json
# is absent, so cap-tidy and cap-services reached new installs and never the
# fleet. SM1118 adopted cap-maintenance alone on an existing site. Every shipped
# bundle is adopted now, under the same rules:
#   - only when the bundle is ABSENT; a bundle that exists, edited, is not rewritten;
#   - only for the shipped roles present on the site, and no role's record changes;
#   - only on a site that has the bundle layer: a site whose shipped roles predate
#     the bundles (SM608 to SM631) is left as it is.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_cmd);

my $tool = "$FindBin::Bin/../../../tools/lazysite-users.pl";

sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; $t }
sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
sub cli   { my ( $d, @a ) = @_; return run_cmd( $^X, $tool, '--docroot', $d, @a ) }
sub gs_file { "$_[0]/lazysite/auth/groups-settings.json" }
sub gs_read { decode_json( slurp( gs_file( $_[0] ) ) ) }

sub groups_read {
    my ($d) = @_;
    my %g;
    for ( split /\n/, slurp("$d/lazysite/auth/groups") ) {
        next unless /^([^:]+):\s*(.*)$/;
        $g{$1} = [ sort grep { length } split /[,\s]+/, $2 ];
    }
    return \%g;
}

sub groups_write {
    my ( $d, $g ) = @_;
    spit( "$d/lazysite/auth/groups",
        join( '', map { "$_: " . join( ' ', @{ $g->{$_} } ) . "\n" } sort keys %$g ) );
}

# Take groups out of the store, as a release before them left it: the record and
# its line in the groups file, and its name from every other group's members.
sub remove_groups {
    my ( $d, @names ) = @_;
    my %gone = map { $_ => 1 } @names;
    my $gs = gs_read($d);
    delete @{$gs}{@names};
    spit( gs_file($d), encode_json($gs) );
    my $g = groups_read($d);
    delete @{$g}{@names};
    $_ = [ grep { !$gone{$_} } @$_ ] for values %$g;
    groups_write( $d, $g );
}

# What the manager's own reads do first: the ordinary use a site adopts a release on.
sub touch {
    my ($d) = @_;
    require IPC::Open2;
    my $pid = IPC::Open2::open2( my $o, my $i, $^X, $tool, '--api', '--docroot', $d );
    print {$i} encode_json( { action => 'users-page', me => 'boss' } );
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return $out;
}

sub seeded_site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/users",    "boss:x\n" );
    cli( $d, 'setup-sysop', '--user', 'boss' );
    return $d;
}

# --- the bundles #369 named, and a channel, reach an existing site ----------
{
    my $d     = seeded_site();
    my $fresh = gs_read($d);
    my $nest  = groups_read($d);
    ok( $fresh->{'cap-tidy'} && $fresh->{'cap-services'} && $fresh->{'ch-files'},
        'a fresh site is seeded with cap-tidy, cap-services and ch-files' );

    # an operator's edits, to a role and to a bundle that is there
    cli( $d, 'group-set', 'site-admins', 'housekeeping', 'off' );
    cli( $d, 'group-set', 'cap-site', 'manage_config', 'off' );
    my $edited_role   = gs_read($d)->{'site-admins'};
    my $edited_bundle = gs_read($d)->{'cap-site'};
    isnt( encode_json($edited_bundle), encode_json($fresh->{'cap-site'}), 'the operator\'s edit to cap-site took' );

    remove_groups( $d, qw(cap-tidy cap-services ch-files) );
    ok( !gs_read($d)->{'cap-tidy'}, 'the store has the shape an earlier release left' );

    touch($d);
    my $gs = gs_read($d);
    my $g  = groups_read($d);
    for my $b (qw(cap-tidy cap-services ch-files)) {
        ok( $gs->{$b}, "$b is added to the existing site" );
        my %want = %{ $fresh->{$b} };
        is_deeply( $gs->{$b}, \%want, "...as shipped" );
        is_deeply( $g->{$b}, $nest->{$b}, "...drawn on by the shipped roles: @{ $nest->{$b} }" );
    }
    is_deeply( $gs->{'site-admins'}, $edited_role,   'the role an operator edited is not rewritten' );
    is_deeply( $gs->{'cap-site'},    $edited_bundle, 'nor is a bundle an operator edited' );

    # an operator who takes a role out of an adopted bundle keeps it out
    my $later = groups_read($d);
    $later->{'cap-tidy'} = [];
    groups_write( $d, $later );
    touch($d);
    is_deeply( groups_read($d)->{'cap-tidy'}, [], 'a later use of the tool does not put the role back' );
}

# --- only the shipped roles that are there are nested ----------------------
{
    my $d = seeded_site();
    remove_groups( $d, qw(analysts cap-audit cap-analytics cap-audit-switch) );
    touch($d);
    my $gs = gs_read($d);
    ok( !$gs->{'cap-audit'}, 'cap-audit, drawn on by analysts alone, is not added without analysts' );
    ok( !$gs->{analysts},    'and the analysts role is not invented' );
    ok( $gs->{'cap-analytics'}, 'cap-analytics, which other roles draw on, is added' );
    is_deeply( groups_read($d)->{'cap-analytics'}, [qw(agent-ai mcp-ai)],
        '...drawn on by the roles present, not by the absent one' );
    ok( !$gs->{'cap-audit-switch'},
        'cap-audit-switch, which no role draws on, is never invented' );
}

# --- a site whose shipped roles predate the bundles is left as it is ---------
{
    my $d    = seeded_site();
    my $nest = do { my $gs = gs_read($d); [ grep { /^(?:cap|ch)-/ } keys %$gs ] };
    remove_groups( $d, @$nest );
    my $before_gs = gs_read($d);
    my $before_g  = groups_read($d);
    ok( $before_gs->{'site-admins'} && $before_gs->{'site-admins'}{seeded},
        'the site has shipped roles and no bundle' );
    touch($d);
    is_deeply( gs_read($d),     $before_gs, 'no bundle is added' );
    is_deeply( groups_read($d), $before_g,  'and no membership changes' );
}

done_testing;
