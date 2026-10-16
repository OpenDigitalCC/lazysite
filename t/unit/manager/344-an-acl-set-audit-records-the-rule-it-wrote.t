#!/usr/bin/perl
# SM1091: an acl-set audit row records the rule it WROTE.
#
# 0.15.5 edge test plan, row F7: "every acl-set audit row records the after-state
# as 'no restriction' though the rule restricts read - single and list form
# alike, e.g. 'read: @g; owner: claude-code -> no restriction'. Minor: the
# refused list attempt is audited with target ''; single form audits '/path',
# list form 'path'; the list form drops the read-without-write warning."
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . '/lazysite-manager-api.pl';

my @ALL = qw(ui manage_content manage_users);
my $s   = new_site( root => repo_root() );
my $d   = $s->docroot;
$s->add_user('owner1');
$s->grant( 'owner1', 'editors', [@ALL], \@ALL );
$s->users( 'group-add', 'owner1', 'team' );
for my $p (qw(one two three four)) {
    open my $fh, '>', "$d/$p.md" or die $!;
    print {$fh} "---\ntitle: $p\n---\nbody\n";
    close $fh;
}

sub rows {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    my @l = grep { /\| acl-set \|/ } <$fh>;
    close $fh;
    return @l;
}
sub fresh { my $n = () = rows(); return $n }

# --- single form, the lists as arrays and as a string ------------------------
for my $c ( [ 'array', [ '@team', 'owner1' ], 'one' ], [ 'string', '@team, owner1', 'four' ] ) {
    my ( $how, $read, $f ) = @$c;
    my $m = fresh();
    my $r = $s->call( 'owner1', 'acl-set', query => "action=acl-set&path=/$f.md",
        body => { read => $read } );
    ok( $r->{ok}, "single form ($how): the rule is written" ) or diag explain $r;
    my @new = ( rows() )[ $m .. $#{ [ rows() ] } ];
    is( scalar @new, 1, "...one audit row" );
    like( $new[0] // '', qr/\| \/$f\.md \|/, "...targeting /$f.md" );
    like( $new[0] // '', qr/-> read: \@team, owner1; owner: owner1\s*$/,
        '...whose after-state is the rule that was written' )
        or diag $new[0];
    unlike( $new[0] // '', qr/-> no restriction/, '...never "no restriction"' );
}

# --- list form -----------------------------------------------------------------
{
    my $m = fresh();
    my $r = $s->call( 'owner1', 'acl-set', query => 'action=acl-set',
        body => { paths => [ '/two.md', '/three.md' ], read => ['@team'] } );
    ok( $r->{ok}, 'list form: the rules are written' ) or diag explain $r;
    my @all = rows();
    my @new = @all[ $m .. $#all ];
    is( scalar @new, 2, '...one audit row per path' );
    like( $new[0] // '', qr/\| \/two\.md \|/,   '...the first targets /two.md, spelt as the single form spells it' );
    like( $new[1] // '', qr/\| \/three\.md \|/, '...the second targets /three.md' );
    like( $new[0] // '', qr/-> read: \@team; owner: owner1\s*$/, '...after-state is the written rule' )
        or diag $new[0];
    my @w = map { $_->{warnings} ? @{ $_->{warnings} } : () } ( $r, @{ $r->{results} || [] } );
    ok( ( grep { /READ IS RESTRICTED AND WRITE IS NOT/ } @w ),
        '...and the result carries the read-without-write warning' ) or diag explain $r;
}

# --- a refused list is audited with the paths it named -------------------------
{
    my $m = fresh();
    my $r = $s->call( 'owner1', 'acl-set', query => 'action=acl-set',
        body => { paths => [ '/two.md', '/nope-nothing.md/../../x' ], read => ['@team'] } );
    ok( !$r->{ok}, 'a list with a refused path is refused' ) or diag explain $r;
    my @all = rows();
    my @new = @all[ $m .. $#all ];
    is( scalar @new, 1, '...one audit row' ) or diag @new;
    unlike( $new[0] // '', qr/acl-set \|  \|/, '...whose target is not empty' );
    like( $new[0] // '', qr/\| acl-set \| \/two\.md,/, '...but the paths asked about' ) or diag $new[0];
}

done_testing();
