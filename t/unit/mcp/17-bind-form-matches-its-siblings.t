#!/usr/bin/perl
# SM421: the same capability was weaker on one surface.
#
# manage_forms could already write an inline delivery target two ways: a raw
# lazysite/forms/<name>.conf over WebDAV, and the control API's
# form-targets-save, which explicitly accepts and preserves inline targets.
# Only MCP's bind_form was handler-only - so an agent delegated form-building
# through MCP had to ask an operator for something the same grant could do
# elsewhere, and the deny/allow story depended on which door was used.
#
# The ruling: permission decides whether this is available; where it is
# granted, the surface delivers it in full. So bind_form gains the ability
# rather than the others losing it.
#
# What is asserted here is the CONTRACT - handler still preferred and still
# validated, inline targets validated for shape, and no credential-bearing
# type offered - because that is what makes "in full" safe rather than merely
# permissive.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $mcp = repo_root() . '/lazysite-mcp.pl';
plan skip_all => "no $mcp" unless -f $mcp;
my $src = do { open my $fh, '<', $mcp or die $!; local $/; <$fh> };

my ($block) = $src =~ /(sub _inline_target_block \{.*?\n\})/s;
ok( $block, '_inline_target_block is present' ) or BAIL_OUT('cannot extract');

## no critic (BuiltinFunctions::ProhibitStringyEval)
eval "$block 1" or BAIL_OUT("cannot load: $@");
## use critic

subtest 'a webhook target is accepted, and rendered as the parser reads it' => sub {
    my $r = _inline_target_block(
        { type => 'webhook', url => 'https://example.test/collect' } );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    like( $r->{block}, qr/^\s+- type: webhook$/m, 'declares its type' );
    like( $r->{block}, qr{^\s+url: https://example\.test/collect$}m,
        'and its destination' );
};

subtest 'a file target is accepted and confined' => sub {
    my $ok = _inline_target_block( { type => 'file', path => 'content/leads' } );
    ok( $ok->{ok}, 'a relative path is accepted' );
    like( $ok->{block}, qr{^\s+path: content/leads$}m, 'rendered' );

    for my $bad ( '../escape', 'content/../../etc', '~root/x' ) {
        my $r = _inline_target_block( { type => 'file', path => $bad } );
        ok( !$r->{ok}, "refused: $bad" );
    }
};

subtest 'the shape is validated even though the destination is not' => sub {
    # Which URL a form may deliver to is the operator's decision, expressed by
    # whether they granted manage_forms. The SHAPE is still checked, because a
    # malformed target is a form that silently does not deliver.
    # SM590: db and table delivery is HANDLER-ONLY, and the docs now say so.
    # An inline target names a destination the operator has not vetted, and a
    # form writing rows into a declared table is exactly what they should vet -
    # so these two are refused here rather than merely undocumented.
    for my $t (qw(db table)) {
        my $r = _inline_target_block( { type => $t, path => 'anything' } );
        ok( !$r->{ok}, "an inline '$t' target is refused - delivery into a table is handler-only" );
        like( $r->{error}, qr/webhook, api or file/,
            "the refusal of '$t' names the types that ARE allowed" );
    }

    ok( !_inline_target_block( { type => 'ftp', url => 'ftp://x/' } )->{ok},
        'an unknown type is refused' );
    ok( !_inline_target_block( { type => 'webhook' } )->{ok},
        'a webhook with no url is refused' );
    ok( !_inline_target_block( { type => 'webhook', url => 'not-a-url' } )->{ok},
        'a non-http url is refused' );
    ok( !_inline_target_block(
            { type => 'webhook', url => "https://x/\nmalicious: y" } )->{ok},
        'a newline in the url is refused - it would inject a config line' );
    ok( !_inline_target_block( { type => 'file' } )->{ok},
        'a file target with no path is refused' );
};

subtest 'smtp is deliberately NOT offered inline' => sub {
    my $r = _inline_target_block(
        { type => 'smtp', url => 'smtp://mail.test' } );
    ok( !$r->{ok},
        'refused: an inline smtp target needs a credential, and the legacy '
            . 'parser reads only type/url/format/path - so it would be a '
            . 'target that silently cannot deliver' );
};

subtest 'the handler path is unchanged and still preferred' => sub {
    my ($bind) = $src =~ /(sub _bind_form \{.*?\n\})/s;
    ok( $bind, '_bind_form is present' ) or return;
    like( $bind, qr/no handler '\$handler'/,
        'an unknown handler id is still refused by name' );
    like( $bind, qr/give either handler or target, not both/,
        'and the two ways are mutually exclusive' );
    my ($desc) = $src =~ /bind_form => \{\s*description => '(.*?)',\n/s;
    like( $desc, qr/PREFER A HANDLER/,
        'the tool description still steers to the vetted handler first' );
};

done_testing();
