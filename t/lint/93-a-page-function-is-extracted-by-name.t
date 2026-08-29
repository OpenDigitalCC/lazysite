#!/usr/bin/perl
# SM684: no test may extract a page function by its exact signature.
#
# The hazard is not that such a regex is ugly. It is that when it stops
# matching, the assertions behind it are usually inside a SKIP block or guarded
# by `or return` - so the test goes QUIET rather than failing. SM683 added a
# third argument to `renderHistory`, and five assertions stopped running while
# the suite reported "16 tests, 5 skipped" and looked healthy.
#
# Adding a parameter to a function is a normal, correct change. A test that
# breaks on it is annoying; a test that silently stops watching is dangerous,
# and it is dangerous in exactly the releases where the code is being changed
# most.
#
# So: match the NAME, let the parameters move, and die when the function is
# absent. PageScript::extract_function does all three, which is why this lint
# points at it rather than describing the correct regex.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find;

my $troot = "$FindBin::Bin/..";

my @offenders;
find(
    {   wanted => sub {
            return unless /\.t\z/;
            my $path = $File::Find::name;
            open my $fh, '<', $path or return;
            local $/;
            my $src = <$fh>;
            close $fh;

            # A signature-pinned extraction: `function NAME(` followed by
            # anything other than an immediate `[^)]*` wildcard before the
            # closing paren. The literal-parameter form is what goes quiet.
            while ( $src =~ /=~ \s* \/ \( function \s+ (\w+) \\\( ([^)]*) \\\)/gx ) {
                my ( $fn, $params ) = ( $1, $2 );
                next if $params =~ /\A\[\^\)\]\*\z/;    # already parameter-agnostic
                next if $params eq '';                  # `function name()` - no parameters to drift
                push @offenders, "$path: $fn\\($params\\)";
            }
        },
        no_chdir => 1,
    },
    $troot
);

is( "@offenders", '',
    'no test extracts a page function by its exact parameter list' )
    or diag( "Signature-pinned extractions (use PageScript::extract_function):\n  "
        . join( "\n  ", @offenders )
        . "\n\nThese stop matching when somebody adds a parameter, and the\n"
        . "assertions behind them usually SKIP rather than fail - which is how\n"
        . "SM683 silently switched off five of t/unit/manager/127's checks." );

# The helper exists and does the two things the rule needs. Asserted here so
# the rule cannot be satisfied by a helper that quietly returns undef.
my $mod = "$troot/lib/PageScript.pm";
ok( -f $mod, 'the shared extractor exists' ) or done_testing(), exit;
my $src = do { open my $fh, '<', $mod or die $!; local $/; <$fh> };
like( $src, qr/function \\Q\$name\\E\\\(\[\^\)\]\*\\\)/,
    'it matches the name and lets the parameters move' );
like( $src, qr/\bdie\b/,
    'and a failed extraction dies rather than returning undef' )
    or diag( 'Returning undef is what let the caller skip. The helper must '
        . 'make absence fatal so the caller cannot accidentally tolerate it.' );

done_testing();
