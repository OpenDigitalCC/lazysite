#!/usr/bin/perl
# tools/lazysite-validate.pl - check page source, from anywhere.
#
# SM887 F2, ruled 2026-09-15: validation is an ENGINE CAPABILITY, offered to
# anything that asks. This is the shell's way of asking. The checks are
# Lazysite::Validate's - the same ones the MCP surface runs, because there is
# one implementation.
#
# WHY A SHELL ENTRY POINT AT ALL. Until now the only way to validate a page was
# to be an authenticated MCP partner posting to a live site over HTTP. A person
# with a file could not ask; nor could CI, a pre-commit hook, or the claude.ai
# skill that raised this, which has a container, a file, and no site yet.
#
# EXIT STATUS IS THE POINT, not a detail. Everything in this tree answered
# "ok" and exited 0 no matter how broken the page was, which makes a validator
# useless in a pipeline: `lazysite validate page.md && publish` could not be
# written. Issues exit 1. Warnings do not, because a warning is a judgement the
# author may have made deliberately and a gate that fails on those teaches
# people to pass --no-verify; --strict is there for a caller who wants them to
# count.
#
# WITH OR WITHOUT A SITE. Two of the eight checks need one - `db:` bindings
# need the table descriptors, a named form needs its binding conf - so pass
# --docroot when there is a site. Without one they report that they could not
# check rather than passing silently, which is the honest third state.
use strict;
use warnings;

BEGIN {
    # SM366: locate the Lazysite module tree relative to this script
    # (run-in-place, tarball and Hestia installs), falling back to the system
    # @INC (package installs). Without it this tool cannot start anywhere the
    # modules are not already on @INC, which is every install that is not a
    # package - and a validator that dies on start reads as a broken page.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

use Lazysite::Validate ();

my %opt = ( docroot => '', json => 0, strict => 0, quiet => 0 );
my @files;
while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--docroot' )            { $opt{docroot} = shift @ARGV // '' }
    elsif ( $a eq '--json' )               { $opt{json}    = 1 }
    elsif ( $a eq '--strict' )             { $opt{strict}  = 1 }
    elsif ( $a eq '--quiet' )              { $opt{quiet}   = 1 }
    elsif ( $a eq '--help' || $a eq '-h' ) { usage(0) }
    elsif ( $a =~ /^-/ ) {
        print {*STDERR} "lazysite-validate: unknown option '$a'\n\n";
        usage(2);
    }
    else { push @files, $a }
}
usage(2) unless @files;

sub usage {
    my ($rc) = @_;
    print { $rc ? *STDERR : *STDOUT } <<'USAGE';
Usage: lazysite-validate.pl [--docroot DIR] [--json] [--strict] [--quiet] FILE...

Check page source against the engine's own rules: front matter, unclosed
component fences, template parse errors, form field rules and delivery, HTML
that belongs in a layout, and values that should probably not be public.

  --docroot DIR   the site, when there is one. Two checks need it - db: table
                  bindings and whether a named form is bound - and say so when
                  it is missing rather than passing silently.
  --json          one JSON object instead of lines, for a caller that parses.
  --strict        warnings count as failure too (exit 1).
  --quiet         print nothing; the exit status is the answer.

Exit: 0 nothing to report, 1 at least one issue (or with --strict, a warning),
2 bad usage.
USAGE
    exit $rc;
}

# Declared separately on purpose: `my (@results, $issues, $warnings)` gives the
# array everything and leaves the scalars undef.
my @results;
my $issues   = 0;
my $warnings = 0;
for my $f (@files) {
    my $r = Lazysite::Validate::validate_file( $f,
        docroot => ( length $opt{docroot} ? $opt{docroot} : undef ),
        path    => $f,
    );
    $issues   += scalar @{ $r->{issues} };
    $warnings += scalar @{ $r->{warnings} };
    push @results, { file => $f, %$r };
}

if ( $opt{json} ) {
    require JSON::PP;
    my $json = JSON::PP->new->canonical->pretty;
    print $json->encode( {
            ok       => JSON::PP::true,
            valid    => ( $issues ? JSON::PP::false : JSON::PP::true ),
            issues   => $issues,
            warnings => $warnings,
            files    => \@results,
    } ) unless $opt{quiet};
}
elsif ( !$opt{quiet} ) {

    # One message per line, file:line first, so an editor's jump-to-error and
    # a grep both work on it without a parser.
    for my $r (@results) {
        for my $m ( @{ $r->{issues} }, @{ $r->{warnings} } ) {
            my $where = $m->{file} // $r->{file};
            $where .= ':' . $m->{line} if defined $m->{line};
            printf "%s: %s: %s: %s\n", $where, uc( $m->{severity} ),
                $m->{kind}, $m->{message};
        }
    }
    printf "%d file(s), %d issue(s), %d warning(s)\n",
        scalar @results, $issues, $warnings;
}

exit 1 if $issues || ( $opt{strict} && $warnings );
exit 0;
