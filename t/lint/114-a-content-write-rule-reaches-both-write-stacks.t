#!/usr/bin/perl
# SM749, generalising SM748's t/unit/manager/141: a content-write rule is
# enforced at the choke point (Manager::Files) AND on the separate WebDAV stack
# (lazysite-dav.pl), or it is not enforced.
#
# Three times a rule has lived on one surface and not the others - SM708's parse
# guard in one caller (SM748), the parse guard missing from WebDAV (SM729), and
# the active-theme rule on WebDAV alone (SM749). Each was found in the field,
# by an agent meeting a refusal on one surface and success on another. 141
# pins the parse guard's call sites; this file pins the FAMILY, so the next rule
# added to Manager::Common with a `_refusal` name is held to the same shape the
# day it is written, and a rule that reaches only one stack fails here rather
# than in somebody's session.
#
# The table is explicit rather than discovered, because a rule may legitimately
# have READ-side callers too (raw_html_page_refusal is used by validate_page and
# audit_site to report pages written before it existed). What is asserted is
# the MINIMUM: both write stacks call it. A rule in Common not listed here
# fails the last subtest, so it cannot be added without a decision.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

my $files  = slurp("$root/lib/Lazysite/Manager/Files.pm");
my $dav    = slurp("$root/lazysite-dav.pl");
my $common = slurp("$root/lib/Lazysite/Manager/Common.pm");

# rule => the filing that put it at the choke point
my %RULES = (
    raw_html_page_refusal   => 'SM189',
    page_parse_refusal      => 'SM748 / SM729',
    brief_write_refusal     => 'SM504',
    active_artifact_refusal => 'SM749',
);

for my $rule ( sort keys %RULES ) {
    subtest "$rule ($RULES{$rule}) reaches both write stacks" => sub {
        ok( $common =~ /^sub \Q$rule\E\b/m, 'defined in Manager::Common' );
        like( $common, qr/EXPORT_OK[^;]*\b\Q$rule\E\b/s, 'and exported' );
        like( $files, qr/\b\Q$rule\E\s*\(/, 'called from the choke point (Manager::Files)' );
        like( $dav, qr/\b\Q$rule\E\s*\(/, 'called from the WebDAV stack (lazysite-dav.pl)' );
    };
}

subtest 'every *_refusal rule in Common is in the table - a new rule is a decision' => sub {
    my @defined = sort( $common =~ /^sub ([a-z_]+_refusal)\b/mg );
    my @known   = sort keys %RULES;

    # Rules Common defines that are deliberately NOT write-stack rules go here,
    # with the reason, so absence from %RULES is a choice and not an oversight.
    my %EXEMPT = (
        carveout_refusal => 'a capability gate over governed paths, applied by the API and MCP dispatchers (SM268), not a content rule',
    );
    my @unaccounted = grep { !$RULES{$_} && !$EXEMPT{$_} } @defined;
    is_deeply( \@unaccounted, [],
        'no *_refusal in Manager::Common is missing from the table or the exemptions' )
        or diag( 'add to %RULES (and call it from both stacks) or to %EXEMPT with a reason: '
            . join( ', ', @unaccounted ) );
    for my $r (@known) {
        ok( ( grep { $_ eq $r } @defined ), "$r in the table exists in Common" );
    }
};

subtest 'the active-artifact rule runs BEFORE the write on both stacks' => sub {
    my ($save) = $files =~ /sub action_save \{(.*?)\n\}/s;
    my $guard  = index( $save, '_active_artifact_guard' );
    my $write  = index( $save, 'write_file_checked' );
    cmp_ok( $guard, '>', -1,     'action_save consults the guard' );
    cmp_ok( $guard, '<', $write, 'before it writes' );

    for my $verb (qw(action_save_binary action_delete action_mkdir action_move action_copy)) {
        my ($body) = $files =~ /sub \Q$verb\E \{(.*?)\n\}/s;
        like( $body, qr/_active_artifact_guard/, "$verb consults the guard - every write verb, not only save" );
    }

    my ($authz) = $dav =~ /(sub authorise_layouts_path.*?\n\})/s;
    $authz //= $dav;
    like( $dav, qr/active_artifact_refusal\(\s*\n?\s*\$rel, \$active_layout, \$active_theme/,
        'the DAV stack passes its own pointers to the shared rule' );
    unlike( $dav, qr/read-only over WebDAV/, 'and no longer carries a private copy of the rule\'s text' );
};

done_testing();
