#!/usr/bin/perl
# SM900: a template parse error is reported at the FILE line, on both surfaces.
#
# The 0.14.4 W11 walk: an unclosed [% IF %] on file line 11 was reported by
# `validate` as line 7, while the unclosed fence on the same page was reported
# at 8 - right. The fence check adds the front-matter offset back (SM488); the
# template check handed Template a body with the front matter gone AND every
# code-block line removed, and reported the parser's line as it stood. Two
# checks on one page, two origins for "line". The write path (a manager save,
# an MCP write_file) carried the same number in its refusal.
#
# THE FIXTURE SEPARATES THE ORIGINS: a five-line front matter, a fenced code
# block ABOVE the fault, and the fault below it. Without the offset the number
# is five short; without the kept-lines map it is four short again.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Validate;
use Lazysite::Manager::Common;

plan skip_all => 'Template is not installed' unless eval { require Template; 1 };

my @lines = (
    '---',                    # 1
    'title: Broken',          # 2
    'subtitle: for SM900',    # 3
    'draft: false',           # 4
    '---',                    # 5
    '',                       # 6
    '# Heading',              # 7
    '',                       # 8
    '```',                    # 9
    'code line one',          # 10
    'code line two',          # 11
    '```',                    # 12
    '',                       # 13
    '::: panel',              # 14  never closed
    'text',                   # 15
    '',                       # 16
    '[% IF foo %]',           # 17  never closed
    'body',                   # 18
);
my $page = join( "\n", @lines ) . "\n";

sub kinds {
    my ($r) = @_;
    my %at;
    for my $m ( @{ $r->{issues} }, @{ $r->{warnings} } ) {
        $at{ $m->{kind} } = $m->{line} if exists $m->{line};
    }
    return \%at;
}

subtest 'validate: both checks count from the top of the file' => sub {
    my $at = kinds( Lazysite::Validate::validate_content( content => $page, file => 'zz.md' ) );
    is( $at->{'component-fence-unmatched'}, 14, 'the fence is reported on its file line (SM488, unchanged)' );
    is( $at->{'template-parse'}, 17, 'and the template fault on ITS file line' )
        or diag( 'W11 measured 7 for a fault on line 11: the front matter and the '
            . 'code block above it were both subtracted.' );
};

subtest 'the write-path refusal carries the same file line' => sub {
    # List context: the message and the audit detail, the way the choke point
    # reads it. The "(line N)" lives in the detail's cause.
    my ( $err, $detail ) = Lazysite::Manager::Common::page_parse_refusal( 'zz.md', $page );
    ok( defined $err, 'the page is refused' )                         or return;
    like( $detail, qr/\(line 17\)/, 'the detail names file line 17' ) or diag($detail);
};

subtest 'no front matter, no code block: the parser line is the file line already' => sub {
    my $plain = "# Heading\n\n[% IF foo %]\nbody\n";
    my $at = kinds( Lazysite::Validate::validate_content( content => $plain, file => 'p.md' ) );
    is( $at->{'template-parse'}, 3, 'line 3, with nothing to add' );
};

subtest 'an indented code block above the fault is mapped too' => sub {
    # The other stripper: four-space indent after a blank line (SM744).
    my $ind = "---\ntitle: x\n---\n\ntext\n\n    indented code\n    more code\n\n[% IF foo %]\n";
  #          1        2         3   4    5      6   7                8              9   10
    my $at = kinds( Lazysite::Validate::validate_content( content => $ind, file => 'i.md' ) );
    is( $at->{'template-parse'}, 10, 'line 10' );
};

done_testing();
