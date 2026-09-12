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

done_testing();
