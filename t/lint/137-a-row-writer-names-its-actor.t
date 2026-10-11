#!/usr/bin/perl
# SM860: a surface that writes rows sets the actor it writes them as.
#
# `Lazysite::Manager::Data` declares:
#
#     our $auth_user = ''; # SM468: the actor for schema-history rows; set by each surface
#
# "set by each surface" is a contract expressed as a comment, and one of the
# three surfaces did not honour it. lazysite-manager-api.pl and lazysite-mcp.pl
# set it; lazysite-data.pl - the endpoint an app's own users write through -
# did not, so every row it wrote recorded no author at all. The declaration was
# right and nothing checked it.
#
# This is the check. It is deliberately about the DECLARATION rather than about
# one file: the next surface to reach the row writers will be written by someone
# who has not read this filing, and a comment will not stop them.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    return <$fh>;
}

# The writers. Reaching either means writing a row, and a row carries an
# author - so a caller of either owes the actor.
my @WRITERS = qw(action_data_row_save action_data_row_delete);

# Every Perl entry point that could plausibly be a surface. Not lib/, because
# the modules there are called BY a surface and inherit whatever it set; the
# question this asks is about the outermost caller, which is where the verified
# identity actually lives.
my @CANDIDATES = grep { -f } glob("$root/*.pl");
ok( scalar @CANDIDATES, 'there are top-level scripts to check' );

my $checked = 0;
for my $path (@CANDIDATES) {
    my $src = slurp($path);
    next unless defined $src;

    my @calls = grep { $src =~ /\bLazysite::Manager::Data::\Q$_\E\s*\(/ } @WRITERS;
    next unless @calls;

    ( my $name = $path ) =~ s{^\Q$root\E/}{};
    $checked++;

    # The assignment, in any of the forms the tree actually uses: `local
    # $Lazysite::Manager::Data::auth_user = ...` (lazysite-data.pl) or a plain
    # assignment (lazysite-manager-api.pl, lazysite-mcp.pl).
    like( $src, qr/\$Lazysite::Manager::Data::auth_user\s*=/, "$name sets the actor it writes rows as" )
        or diag( "$name calls "
            . join( ', ', @calls )
            . " but never assigns \$Lazysite::Manager::Data::auth_user, so the "
            . "row writer receives the empty default and Tables::_stamp writes "
            . "undef. An empty created_by already means 'written anonymously', "
            . "so the rows this surface writes claim to have no author. Set it "
            . "from the identity this surface has verified, AFTER the require - "
            . "assigning before the module loads is silently undone by its own "
            . "`our`." );
}

# THE GUARD NEEDS A SUBJECT. If a refactor renames the writers or moves the
# surfaces, every `like` above simply stops running and the file still reports
# a pass - the vacuous-pass shape this suite keeps finding elsewhere. Three
# surfaces reach the row writers today; fewer means the check has lost its
# subject and wants rewriting, not deleting.
cmp_ok( $checked, '>=', 3,
    'the check found the surfaces it exists to check (3 today: data, manager-api, mcp)' )
    or diag( "Only $checked top-level script(s) matched a call to "
        . join( ' or ', @WRITERS )
        . ". Either the row writers were renamed or the surfaces moved - in "
        . "which case this lint is now testing nothing and needs its "
        . "@WRITERS list updated, not removing." );

# P21 (WORK-PLAN-0154): THE WRITERS MOVED INTO MODULES, SO THE CHECK FOLLOWS.
#
# The check above reads only the top-level scripts, by design: they are where a
# verified identity lives. But since SM944 split the scripts, rows are also
# written from lib/ - a connector's answer table, a form's table target, a site
# package's restored data - each calling the store's writers directly, where no
# surface's `$auth_user` reaches. Found when this was widened:
# Manager::SitePackage restored every row with no author (created_by empty,
# which means "written anonymously"); it now names the account restoring, as
# Manager::Data's import does.
#
# The rule here is the call's: every call to a stamping writer of
# Lazysite::Data::Tables - insert_row, update_row, import_rows - passes
# `actor =>`, even when the value may be empty (a form submitted by nobody
# signed in). delete_row stamps nothing and is not asked. The writers' own
# module is not read; every other .pl and .pm the engine ships is. Paths are
# judged BELOW the root, so a checkout under tmp/ reads the same files as the
# main one.
my @STAMPING = qw(insert_row update_row import_rows);
my $calls_re = join '|', @STAMPING;
my @FILES    = grep { -f } (
    glob("$root/*.pl"), glob("$root/tools/*.pl"), glob("$root/plugins/*.pl"),
);
{
    my @dirs = ("$root/lib");
    while ( my $dir = shift @dirs ) {
        opendir my $dh, $dir or next;
        for my $e ( sort grep { !/^\./ } readdir $dh ) {
            my $p = "$dir/$e";
            if    ( -d $p )          { push @dirs,  $p }
            elsif ( $p =~ /\.pm\z/ ) { push @FILES, $p }
        }
        closedir $dh;
    }
}

my ( $sites, @nameless ) = (0);
for my $path (@FILES) {
    ( my $rel = $path ) =~ s{^\Q$root\E/}{};
    next if $rel eq 'lib/Lazysite/Data/Tables.pm';    # the writers themselves
    my $src = slurp($path);
    next unless defined $src;
    $src = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src;    # not in a comment
    while ( $src =~ /(?<![\w:>\$])(?:Lazysite::Data::Tables::)?($calls_re)\s*(\((?:[^()]++|(?2))*\))/g ) {
        my ( $name, $args ) = ( $1, $2 );
        next if substr( $src, 0, $-[0] ) =~ /\bsub\s+\z/;            # a definition
        $sites++;
        my $line = 1 + ( () = substr( $src, 0, $-[0] ) =~ /\n/g );
        push @nameless, "$rel:$line $name" unless $args =~ /\bactor\s*=>/;
    }
}
is_deeply( \@nameless, [], 'every call to a stamping row writer names its actor' )
    or diag( "These calls write rows with no `actor =>`, so created_by/updated_by "
        . "are stamped empty - 'written anonymously' - whoever wrote them. Pass the "
        . "identity the caller verified (it may be empty for an anonymous visitor):\n  "
        . join( "\n  ", @nameless ) );
cmp_ok( $sites, '>=', 6, 'the widened check found the module writers it exists to check (6 today)' )
    or diag("Only $sites call(s) to @STAMPING were found - renamed, or the scan lost its files.");

done_testing();
