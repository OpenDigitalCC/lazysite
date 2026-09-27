#!/usr/bin/perl
# SM873: A KIND IS A NAME, NOT A STRING THE CODE BUILDS.
#
# `t/lint/139` requires every `kind => '...'` in the tree to have a decided HTTP
# status. It can only require that of kinds it can SEE, and for two years one
# line defeated it: Data::Tables emitted `kind => 'store_' . $why->{reason}`, so
# one statement produced a family of kinds whose members no static reader could
# enumerate. Every one of them missed %REFUSAL_STATUS and answered 400 Bad
# Request - telling a caller its request was malformed when the fault was this
# host failing to read its own data store. 139 had to exempt the stem `store_`
# rather than cover it, and the exemption was the only honest thing it could do.
#
# SM873 fixed that instance. THIS STOPS THE NEXT ONE, which is the part that
# outlives the fix: a kind assembled from a runtime value cannot be mapped to a
# status, cannot be documented, and cannot be checked - so the defect is not the
# wrong status, it is that the name was never a name.
#
# WHAT IT REFUSES, precisely. Four shapes, each an assembly:
#
#   kind => 'store_' . $why->{reason}     a literal extended at run time
#   kind => "store_$reason"               the same by interpolation
#   kind => $stem . $tail                 built from two values
#   kind => sprintf('store_%s', $r)       built by a function
#
# WHAT IT ALLOWS, and why each is sound rather than tolerated:
#
#   kind => 'not-found'                   a literal; 139 checks it
#   kind => $kind                         A PASS-THROUGH. Several modules carry
#                                         a local `_err($msg, kind => $k)`
#                                         helper. The literal exists at the CALL
#                                         site, where 139 reads it, so the
#                                         parameter is a hand-off and not an
#                                         assembly.
#   kind => ( $x ? 'a' : 'b' )            both arms are literals, so both are
#                                         enumerable and 139 sees each.
#   kind => $row->{kind} // ''            NOT A REFUSAL KIND AT ALL. `kind` is
#                                         also an ordinary field: a backup has a
#                                         kind, a layout has a kind, a snapshot
#                                         is 'dropped' or 'rebuild'. This test
#                                         cannot tell those from a refusal by
#                                         name and does not try - it refuses only
#                                         ASSEMBLY, which none of them do.
#
# WHAT IT CANNOT SEE, so a green run is not read as more than it is: a kind
# assembled inside a helper and then passed in as a variable. The assembly would
# be somewhere this test is not looking, on a line that does not say `kind`.
# Nothing in the tree does that today; if something starts, 139 is what notices,
# because the resulting kind reaches no status.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @files;
{
    open my $ls, '-|', 'git', '-C', $root, 'ls-files' or die "git ls-files: $!";
    while ( my $l = <$ls> ) {
        chomp $l;
        next if $l     =~ m{^(?:t/|tmp/)};
        next unless $l =~ /\.(?:pl|pm)$/;
        push @files, $l;
    }
    close $ls;
}
cmp_ok( scalar @files, '>=', 30, 'the source files were discovered' )
    or do { done_testing(); exit };

# The four assemblies, each with the name this test reports it by.
my @ASSEMBLED = (
    [ 'a literal extended by concatenation'   => qr/\Akind\s*=>\s*'[^']*'\s*\./ ],
    [ 'an interpolating double-quoted string' => qr/\Akind\s*=>\s*"[^"]*\$/ ],
    [ 'two values concatenated' => qr/\Akind\s*=>\s*\$[\w{}\->\[\]']+\s*\./ ],
    [ 'a string-building function' =>
            qr/\Akind\s*=>\s*(?:sprintf|join|lc|uc|ucfirst|reverse)\s*\(/ ],
);

my ( $checked, @found ) = (0);
for my $rel (@files) {
    open my $in, '<', "$root/$rel" or next;
    my $n = 0;
    while ( my $line = <$in> ) {
        $n++;

        # A comment quoting the shape it is describing is not an emit site.
        # Every real one is code, so the comment marker settles it.
        next if $line =~ /\A\s*#/;

        while ( $line =~ /(\bkind\s*=>\s*.{0,70})/g ) {
            my $expr = $1;
            $checked++;
            for my $rule (@ASSEMBLED) {
                my ( $why, $re ) = @$rule;
                next unless $expr =~ $re;
                push @found, "$rel:$n is $why\n    $expr";
                last;
            }
        }
    }
    close $in;
}

cmp_ok( $checked, '>=', 200, 'kind assignments were found to check' )
    or diag( 'If this drops sharply the scan stopped matching, which would '
        . 'make the assertion below vacuous rather than passing.' );

is( scalar @found, 0, 'no refusal kind is assembled at run time' )
    or diag( "A kind must be a NAME a reader can enumerate, because it is the\n"
        . "key %REFUSAL_STATUS is looked up by and the contract a client reads.\n"
        . "Give each case its own literal kind at its own emit site, and carry\n"
        . "the varying part in a field of its own - Data::Tables passes\n"
        . "`reason` beside `kind => 'store-uninspectable'` for exactly this.\n\n"
        . join( "\n", @found ) );

done_testing();
