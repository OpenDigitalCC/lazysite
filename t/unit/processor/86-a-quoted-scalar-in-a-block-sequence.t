#!/usr/bin/perl
# SM940: a quoted scalar in a block sequence under `sections:` was read as a
# mapping.
#
# REPORTED by the sites agent against 0.14.4 and REPRODUCED against 0.15.1, which
# is the part that mattered - a report against a released version gets checked
# before it is scheduled, because the answer is sometimes "already fixed".
#
#   sections:
#     - bio-hero:
#         sameAs:
#           - 'https://github.com/StuartJMackintosh'
#
# parsed to [ { "'https" => "//github.com/StuartJMackintosh'" } ]. The sequence
# branch strips the `- ` and recurses, and the recursion reached the mapping test
# `^(.+?)\s*:\s*(.*)$` - which splits on the first colon - before anything
# consulted the quotes. A quote is exactly what an author adds to protect a value
# CONTAINING a colon, and here it was not read.
#
# SILENT: no warning, no render error. The layout received single-key hashes where
# it expected strings, so a FOREACH over them emitted empty cells or stringified
# hashes and the page merely looked wrong. It was found by diffing against
# YAML::XS, not by anything the engine said.
#
# THE OBVIOUS FIX IS WRONG, AND THAT IS WHAT THE SECOND SUBTEST IS FOR. "Treat a
# wholly quoted line as a scalar" also describes `'a': 'b'`, a legitimate
# quoted-KEY mapping; reading that as a scalar trades one defect for another. The
# discriminator is whether the OPENING quote closes at the end of the line.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/lazysite-processor/front-matter.pm" or die $!;
    local $/;
    <$fh>;
};

# The subs are lifted out of the processor rather than re-implemented here: the
# render path is module-free (ADR 0001), so there is nothing to `use`. _yaml_block
# and its helpers have ONE definition - checked across lib/, plugins/, tools/ and
# t/ - so there is no pinned copy for this test to drift from.
my @want = qw(_parse_sections _yaml_block _yaml_value _yaml_scalar
    _yaml_split_flow _yaml_quoted_scalar_line);
my $code = "package SecProbe;\nuse strict;\nuse warnings;\n";
for my $name (@want) {
    $src =~ /^(sub \Q$name\E \{.*?^\})/ms
        or BAIL_OUT("could not lift $name out of lazysite-processor/front-matter.pm");
    $code .= "$1\n";
}
$code .= "1;\n";
eval $code or BAIL_OUT("lifted subs did not compile: $@");

# _parse_sections takes the block UNDER `sections:`, not the key line. Feeding it
# the key line makes it parse a mapping and return [] - which reads as "cannot
# reproduce", and is how the first probe written for this report nearly reported a
# grade-A finding as unreproducible.
sub parse { return SecProbe::_parse_sections( $_[0] ) }

subtest 'a block sequence of quoted URLs is a list of strings' => sub {
    my $got = parse( <<'YAML' );
  - bio-hero:
      sameAs:
        - 'https://github.com/StuartJMackintosh'
        - 'https://www.linkedin.com/in/stuartjmackintosh/'
YAML
    is_deeply(
        $got,
        [   {   'bio-hero' => {
                    sameAs => [
                        'https://github.com/StuartJMackintosh',
                        'https://www.linkedin.com/in/stuartjmackintosh/',
                    ],
                },
            },
        ],
        'the reporter\'s own case: two strings, not two single-key hashes'
    );
};

subtest 'a quoted-KEY mapping is still a mapping' => sub {
    # The case the obvious fix breaks. `'a': 'b'` starts and ends with a quote,
    # so a naive "wholly quoted" test calls it a scalar and loses the pair.
    my $got = parse( <<'YAML' );
  - card:
      'a': 'b'
YAML
    is_deeply( $got, [ { card => { a => 'b' } } ],
        'the quotes are stripped from both sides of the pair, and it stays a pair' );
};

subtest 'the two spellings agree, which is the whole complaint' => sub {
    # The flow form was ALWAYS correct, because _yaml_split_flow tracks quote
    # state. The defect was that the two paths disagreed; asserting they now
    # match is stronger than asserting either one in isolation.
    my $block = parse( <<'YAML' );
  - hero:
      links:
        - 'https://example.test/a?x=1'
        - "https://example.test/b"
YAML
    my $flow = parse( <<'YAML' );
  - hero:
      links: [ 'https://example.test/a?x=1', "https://example.test/b" ]
YAML
    is_deeply( $block, $flow, 'block and flow produce the same structure' );
    is_deeply(
        $block->[0]{hero}{links},
        [ 'https://example.test/a?x=1', 'https://example.test/b' ],
        'and both are the strings the author wrote - single and double quoted'
    );
};

subtest 'values with no colon, and bareword scalars, are untouched' => sub {
    # The guard must not change anything that already worked. A sequence of
    # barewords is the common case and has no quotes to consult.
    is_deeply( parse("  - hero:\n      tags:\n        - alpha\n        - beta\n"),
        [ { hero => { tags => [ 'alpha', 'beta' ] } } ], 'barewords' );
    is_deeply( parse("  - hero:\n      tags:\n        - 'alpha'\n"),
        [ { hero => { tags => ['alpha'] } } ],
        'a quoted bareword loses its quotes and stays a string' );
};

subtest 'the helper answers the question it claims to' => sub {
    # Asserted directly, because the whole fix rests on this one distinction and
    # a reader should be able to see it stated rather than inferred.
    my @yes = ( "'https://x/y'", '"https://x/y"', "'a'", "''" );
    my @no  = ( "'a': 'b'", 'a: b', "'unterminated", 'plain', '', "'a' 'b'" );
    ok( SecProbe::_yaml_quoted_scalar_line($_), "scalar: $_" ) for @yes;
    ok( !SecProbe::_yaml_quoted_scalar_line($_), "not a scalar: $_" ) for @no;
};

done_testing();
