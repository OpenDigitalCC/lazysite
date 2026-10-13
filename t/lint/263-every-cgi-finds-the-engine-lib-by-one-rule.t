#!/usr/bin/perl
# SM1078: EVERY SCRIPT A CGI-BIN RUNS FINDS THE ENGINE'S LIB BY ONE RULE.
#
# install.pl puts the Lazysite:: tree at {DOCROOT}/../lib, wherever --cgibin
# is. The CGIs looked only relative to themselves (bin/lib, bin/../lib,
# bin/../../lib; lazysite-data.pl and lazysite-odoo.pl only the first two), so
# on install.pl's own usage example - /var/www/html with /usr/lib/cgi-bin -
# every CGI but the symlinked plugins died "Can't locate Lazysite/...". The rule
# now ends with the docroot's ../lib, and it is one rule: this holds every copy
# to the same text, so t/unit/lib/97 can evaluate any one of them for all.
#
# Which scripts: every lazysite-*.pl at the repository root (install.pl puts
# them all in {CGIBIN}), the plugins install.pl links (or copies, where a
# symlink fails) into the cgi-bin, read from install.pl itself, and the
# processor's lazy lookup (_lazy_lib), which is the same rule inside a sub.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp { open my $fh, '<', $_[0] or die "open $_[0]: $!"; local $/; return scalar <$fh> }

# The rule, as two lines of code. Whitespace is normalised; nothing else is.
my $DOC_LINE = q{my $doc = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '';};
my $CAND_LINE = q[for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib", ( length $doc ? "$doc/../lib" : () ) ) {];

sub norm { my ($s) = @_; $s =~ s/\s+/ /g; $s =~ s/\A | \z//g; return $s }

opendir my $dh, $root or die $!;
my @scripts = sort grep { /\Alazysite-[a-z-]+\.pl\z/ && -f "$root/$_" } readdir $dh;
closedir $dh;
cmp_ok( scalar @scripts, '>=', 9, 'the root CGIs are found (' . scalar(@scripts) . ')' );

my ($linked) = slurp("$root/install.pl") =~ m{for my \$plugin \(qw\(([^)]+)\)\) \{\n\s+my \$src = "\$plugin_dir/\$plugin\.pl";\n\s+my \$dst = "\$cgibin/\$plugin\.pl";};
ok( defined $linked, 'install.pl names the plugins it puts in the cgi-bin' );
push @scripts, map { "plugins/$_.pl" } split ' ', $linked // '';

for my $s (@scripts) {
    my @lines = map  { norm($_) } split /\n/, slurp("$root/$s");
    my @cand  = grep { /\Afor my \$cand \( "\$bin\/lib"/ } @lines;
    is( scalar @cand, 1,            "$s: one lib candidate list" );
    is( $cand[0], norm($CAND_LINE), "$s: it is the rule's list, the docroot's ../lib last" );
    is( scalar( grep { $_ eq norm($DOC_LINE) } @lines ), 1, "$s: the docroot is read as the rule reads it" );
}

# The processor finds lib only when a lazy require needs it (ADR 0001: the render
# path loads no Lazysite:: module), so its copy is in _lazy_lib.
{
    my ($body) = slurp("$root/lazysite-processor.pl") =~ m{^sub _lazy_lib \{\n(.*?)^\}}ms;
    ok( defined $body, 'lazysite-processor.pl has _lazy_lib' );
    my @lines = map { norm($_) } split /\n/, $body // '';
    is( scalar( grep { $_ eq norm($CAND_LINE) } @lines ), 1, '_lazy_lib: the rule\'s list' );
    is( scalar( grep { $_ eq norm($DOC_LINE) } @lines ), 1, '_lazy_lib: the docroot read the same way' );
}

done_testing();
