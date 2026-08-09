#!/usr/bin/perl
# SM246: the permission model has ONE table, and every consumer agrees with it.
#
# The question "what mode should this path have?" was answered in four places by
# three policies, and the two that both hold a directory table had ALREADY
# diverged by four entries when this was written:
#
#   lazysite/forms              check wanted 2770; the model did not mention it
#   lazysite/git                check wanted 2770; the model did not mention it
#   lazysite/stats/form-events  check wanted 2775; the model did not mention it
#   ../plugins                  the model declared 0755; check never looked
#
# Nobody had noticed, because nothing compared them. That is the whole shape of
# the incident this request came from: a permission fact maintained by hand in
# more than one place drifts, and the drift is invisible until a deploy exposes
# it.
#
# WHAT THIS DOES NOT DO. The consumers still hold their own copies -
# dist/config/classification.json is a BUILD-time config and is not installed, so
# tools/lazysite-check.pl cannot read it on a deployed site. Making the model
# ship is a packaging change with its own risk and belongs with the rest of
# SM246, under report-before-repair. Until then this guard makes a divergence
# impossible to reintroduce unnoticed, which is the filing's own interim: "a
# drift guard pins the table against the consumers, the way t/lint/17-19 already
# pin duplicated data elsewhere."
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# --- the model --------------------------------------------------------------
my $json = do {
    open my $fh, '<:utf8', "$root/dist/config/classification.json" or die $!;
    local $/;
    <$fh>;
};
my $cls = JSON::PP->new->decode($json);
my $rps = $cls->{runtime_paths} || [];
ok( scalar @$rps, 'the model declares runtime paths' );

my %model;
for my $rp (@$rps) {
    my $p = $rp->{path};
    $p =~ s{\A\{DOCROOT\}/}{};
    $model{$p} = { mode => $rp->{mode}, by => $rp->{applied_by} || ['install'] };

    # Every row states WHY. The reason is the part that was missing, and the
    # reason a hand-maintained list drifts: without it, a later reader cannot
    # tell a deliberate mode from an accident.
    ok( defined $rp->{why} && length $rp->{why},
        "$p states why it has that mode" );
    like( $rp->{mode}, qr/\A[0-7]{3,4}\z/, "$p declares an octal mode" );
}

# --- the check tool's copy --------------------------------------------------
my $chk = do {
    open my $fh, '<:utf8', "$root/tools/lazysite-check.pl" or die $!;
    local $/;
    <$fh>;
};
my ($want_block) = $chk =~ /my \%want_dir = \((.*?)\);/s;
ok( defined $want_block, "the check tool's directory table was found" );

my %check;
while ( $want_block =~ /'([^']+)'\s*=>\s*0?([0-7]{4})/g ) {
    $check{$1} = $2;
}
cmp_ok( scalar keys %check, '>=', 8, 'and parsed' );

# --- they must agree --------------------------------------------------------
# Only the paths the check tool is responsible for: it verifies the docroot, so
# a model entry outside it ({DOCROOT}/../plugins) is legitimately absent.
my @disagree;
for my $p ( sort keys %check ) {
    my $m = $model{$p};
    unless ($m) {
        push @disagree, "$p: the check tool wants $check{$p}, the model does not mention it";
        next;
    }
    push @disagree, "$p: check wants $check{$p}, the model says $m->{mode}"
        unless $m->{mode} eq $check{$p};
}
for my $p ( sort keys %model ) {
    next if $p =~ m{\A\.\./};    # outside the docroot; not the check tool's job
    next if $check{$p};
    push @disagree, "$p: the model declares $model{$p}{mode}, the check tool never looks at it";
}

is_deeply( \@disagree, [],
    'the model and the check tool agree on every docroot path' )
    or diag( join "\n  ", '', @disagree,
    'Update dist/config/classification.json AND tools/lazysite-check.pl together,',
    'or the deploy applies one answer and the audit reports another.' );

# --- applied_by is honoured --------------------------------------------------
# A path the installer must NOT create (lazysite/git is made by the
# content-history plugin at adoption) has to be excluded there, or adding it to
# the model changes install behaviour - which report-before-repair forbids.
{
    my $inst = do {
        open my $fh, '<:utf8', "$root/install.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $inst, qr/applied_by/,
        'install.pl honours applied_by, so a check-only path is not created' );

    my @check_only = grep { !grep { $_ eq 'install' } @{ $model{$_}{by} } }
        sort keys %model;
    cmp_ok( scalar @check_only, '>=', 1,
        'the model carries at least one verified-but-not-installed path' );
    ok( ( grep { $_ eq 'lazysite/git' } @check_only ),
        'lazysite/git is check-only - the installer must never create it' );
}

done_testing();
