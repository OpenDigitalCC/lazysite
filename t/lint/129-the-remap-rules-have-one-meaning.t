#!/usr/bin/perl
# SM802: the rules a save accepts are exactly the rules a request honours.
#
# Lazysite::Remap::parse_rules validates on save; the render path, module-free
# under ADR 0001, carries a marked copy in _remap_parse. Two parsers of one file
# disagreeing would mean a rule that saved cleanly and never fired, or a
# hand-edited line the save would refuse doing something anyway. Both are run
# over the same texts, including the shapes a hand-rolled parser gets wrong.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);
use Lazysite::Remap qw(parse_rules);

my $d = site_tempdir();
setup_minimal_site($d);
load_processor($d);

my @TEXTS = (
    "a.example /web https://x.example\n",
    "a.example /web https://x.example 301\n",
    "A.Example /web/ https://x.example/path?k=v\n",
    "# only a comment\n\n",
    "a.example /web //evil.example\n",
    "a.example web https://x.example\n",
    "a.example /web https://x.example 307\n",
    "a.example /web https://x.example\na.example /web/ https://y.example\n",
    "a.example / /home\n",
    "a.example /x https://x.example extra words\n",
    "a.example /x\"y https://x.example\n",
);

for my $t (@TEXTS) {
    my ($mod) = parse_rules($t);
    my $proc  = main::_remap_parse($t);
    my $show  = sub { join ' | ', map { "$_->{host} $_->{prefix} $_->{dest} $_->{code}" } @{ $_[0] } };
    ( my $label = $t ) =~ s/\n/\\n/g;
    is( $show->($proc), $show->($mod), "both parsers accept the same rules from: $label" );
}

done_testing();
