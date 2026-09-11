#!/usr/bin/perl
# SM844: lazysite check lists the pages a 0.12 author wrote correctly and 0.13
# silently breaks.
#
# 0.12 printed db: values raw, so `| html` was the right advice. 0.13 escapes at
# the sink, so the same filter escapes twice - and only for values containing
# & < > or quotes, which is how it sits unnoticed. The render log names the table
# and column once a visitor hits it; this names the FILE before anyone does.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $tool = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $tool" unless -f $tool;

sub put { my ( $p, $t ) = @_; ( my $dir = $p ) =~ s{/[^/]+\z}{}; make_path($dir); open my $fh, '>', $p or die $!; print {$fh} $t; close $fh }
sub run {
    my ($d) = @_;
    open my $fh, '-|', $^X, $tool, '--docroot', $d or return '';
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

my $d = site_tempdir();    # lint 118: not a bare tempdir
make_path("$d/lazysite");

# The shapes. Only the first is the defect.
put( "$d/people.md", "---\ntitle: People\ntt_page_var:\n  people: db:people\n---\n\n"
        . "[% FOREACH p IN people %]<li>[% p.name | html %]</li>[% END %]\n" );
put( "$d/clean.md", "---\ntitle: Clean\ntt_page_var:\n  people: db:people\n---\n\n"
        . "[% FOREACH p IN people %]<li>[% p.name %]</li>[% END %]\n" );
put( "$d/nodb.md", "---\ntitle: No table\n---\n\n[% page.title | html %]\n" );
put( "$d/lazysite/templates/x.md", "---\ntitle: T\ntt_page_var:\n  a: db:a\n---\n\n[% a | html %]\n" );

my $out = run($d);
# Scoped to THIS check's line: other sections of the report name files too, and
# an assertion over the whole output would fail on them and prove nothing here.
my ($line) = $out =~ /^(.*bind a data table with db: and also use.*)$/m;
$line //= q{};

# --- THE CANARY -------------------------------------------------------------
like( $out, qr/bind a data table with db: and also use \| html/,
    'the check reports the double-escaped template at all' );

# --- THE FINDING ------------------------------------------------------------
like( $line, qr/\bpeople\.md\b/, 'it names the page, so it can be found before a visitor does' );
like( $out, qr/escaped for you from 0\.13\.0/, '...and says why the filter is now wrong' );

# --- and nothing it should not ---------------------------------------------
unlike( $line, qr/\bclean\.md\b/, 'a db: page without | html is not listed' );
unlike( $line, qr/\bnodb\.md\b/,  '| html on a page with no db: binding is not listed - it is correct there' );
unlike( $line, qr{lazysite/templates/x\.md}, 'the engine tree is not content and is not scanned' );

# A clean site says so, rather than saying nothing.
my $d2 = site_tempdir();
make_path("$d2/lazysite");
put( "$d2/clean.md", "---\ntitle: Clean\ntt_page_var:\n  people: db:people\n---\n\n[% people.0.name %]\n" );
like( run($d2), qr/no page binds a data table and also applies \| html/, 'a clean site reports OK' );

done_testing();
