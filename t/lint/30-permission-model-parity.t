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

    # SM293: the model addresses the engine tree as {LAZYSITE}, because the
    # installer must not write into a migrated site's docroot. The check tool
    # still names those paths docroot-relative ("lazysite/auth") and resolves
    # them at runtime, so normalise to that spelling here or the two key spaces
    # stop overlapping and this parity check silently compares nothing.
    $p =~ s{\A\{LAZYSITE\}}{lazysite};
    $p =~ s{\A\{DOCROOT\}/}{};
    $model{$p} = { mode => $rp->{mode}, by => $rp->{applied_by} || ['install'] };

    # Every row states WHY. The reason is the part that was missing, and the
    # reason a hand-maintained list drifts: without it, a later reader cannot
    # tell a deliberate mode from an accident.
    ok( defined $rp->{why} && length $rp->{why},
        "$p states why it has that mode" );

    # SM246 deliverable 3: the fresh-versus-upgrade policy is DECLARED, not
    # implied. Both categories are legitimate; what is not legitimate is being
    # unable to say which one a path is in.
    ok( defined $rp->{on_upgrade}
            && $rp->{on_upgrade} =~ /\A(?:repair|leave)\z/,
        "$p declares its upgrade policy (repair|leave)" );
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

    # SM321: the private store is outside the docroot too - it is a SIBLING, so
    # it does not normalise to a ../ prefix the way {DOCROOT}/../plugins does.
    #
    # It is exempt from the MODE-TABLE comparison and emphatically not from
    # checking: report_private_store_usable tests whether the CGI identity can
    # actually write into it (cgi_can), names its owner and mode when it cannot,
    # and repairs it under --fix. That is a stronger check than "does the mode
    # match", and it is the one this directory needs - SM323 was a store with a
    # plausible-looking mode that the engine still could not write to.
    next if $p eq '{PRIVATE_STORE}';

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

# --- the CGI-writable FILE list (SM246 deliverable 4) -----------------------
# It was hand-maintained in install.pl and tools/lazysite-check.pl, and the
# installer's own comment admitted it: "keep the two in step". A new file needing
# group write was only fixed if someone remembered both places. It is now
# declared once in the model, and this pins the check tool to it.
{
    my $rfs = $cls->{runtime_files} || [];
    cmp_ok( scalar @$rfs, '>=', 6, 'the model declares the CGI-writable files' );

    my %model_file;
    for my $rf (@$rfs) {
        # SM293: same normalisation as the directory model above - {LAZYSITE}
        # is the engine tree, spelled docroot-relative by the check tool.
        ( my $rel = $rf->{path} ) =~ s{\A\{LAZYSITE\}}{lazysite};
        $rel =~ s{\A\{DOCROOT\}/}{};
        $model_file{$rel} = 1;
        ok( defined $rf->{why} && length $rf->{why}, "$rel states why it needs group write" );
        is( $rf->{ensure}, 'group-write', "$rel declares what to ensure" );
    }

    # check 4b's list.
    my ($b4) = $chk =~ /4b\..*?for \s+ my \s+ \$rel \s* \( \s* qw\( (.*?) \)/xs;
    ok( defined $b4, "check 4b's file list was found" );
    my @check_file = grep { length } split /\s+/, ( $b4 // '' );
    cmp_ok( scalar @check_file, '>=', 6, 'and parsed' );

    my @file_disagree;
    for my $f (@check_file) {
        push @file_disagree, "$f: check 4b wants it group-writable, the model does not list it"
            unless $model_file{$f};
    }
    for my $f ( sort keys %model_file ) {
        push @file_disagree, "$f: the model declares it, check 4b never looks at it"
            unless grep { $_ eq $f } @check_file;
    }
    is_deeply( \@file_disagree, [],
        'the model and check 4b agree on which files need group write' )
        or diag( join "\n  ", '', @file_disagree );

    # install.pl must READ the model rather than carry a third copy.
    my $inst = do {
        open my $fh, '<:utf8', "$root/install.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $inst, qr/\$manifest->\{runtime_files\}/,
        'install.pl takes the file list from the model' );
}

# --- the manifest actually CARRIES the model ---------------------------------
# install.pl reads the model out of the manifest, not out of classification.json
# (the config is build-time and is not installed). So a section declared in the
# config and read by the installer is still INERT unless build-manifest.pl
# copies it across - and runtime_files was exactly that for its whole life:
# declared, read, never emitted, so install fell through to its hardcoded
# fallback on every single build while the filing recorded it as done.
#
# This asserts the round trip rather than any one section, because the failure
# mode is structural: whoever adds the next section will read the existing code,
# see a `$manifest->{...}` read, and reasonably assume the plumbing exists.
{
    my $inst = do {
        open my $fh, '<:utf8', "$root/install.pl" or die $!;
        local $/;
        <$fh>;
    };
    my $bm = do {
        open my $fh, '<:utf8', "$root/tools/build-manifest.pl" or die $!;
        local $/;
        <$fh>;
    };

    my %read;
    $read{$1} = 1 while $inst =~ /\$manifest->\{(\w+)\}/g;
    cmp_ok( scalar keys %read, '>=', 2,
        'install.pl reads model sections from the manifest' );

    # The keys build-manifest puts INTO the manifest hash it writes.
    my ($mblock) = $bm =~ /my \$manifest = \{(.*?)\n    \};/s;
    ok( defined $mblock, 'build-manifest.pl\'s manifest literal was found' );
    my %emitted;
    $emitted{$1} = 1 while $mblock =~ /^\s*(\w+)\s*=>/gm;
    # Fields added conditionally after the literal (e.g. security_critical).
    $emitted{$1} = 1 while $bm =~ /\$manifest->\{(\w+)\}\s*=/g;

    my @inert = grep { !$emitted{$_} } sort keys %read;
    is_deeply( \@inert, [],
        'every manifest section install.pl reads is one build-manifest emits' )
        or diag( join "\n  ", '',
        ( map { "$_: install.pl reads it, build-manifest.pl never writes it" } @inert ),
        'The installer will silently use its fallback - the declaration does nothing.',
        'Add the section to the manifest literal in tools/build-manifest.pl.' );
}

# --- install_dirs has three consumers too (SM268 03-F7) ----------------------
#
# SM246 states the design as "one table, three consumers - install applies,
# check verifies, check --fix repairs". This lint pinned runtime_paths and
# runtime_files and never install_dirs, and the gap was exactly where the design
# was not true: check carried its own hand-written list of eleven lazysite/*
# directories while the model declared twenty-eight, so a site with the reported
# fault was reported healthy.
#
# The chain has three links and each can break independently: declared in the
# config, emitted into the manifest, recorded into the install state, read by
# check. Pin all of them, because a section that is declared and never carried
# is precisely what runtime_files was for its whole life.
subtest 'install_dirs reaches the tool that verifies it' => sub {
    my $dirs = $cls->{install_dirs} || [];
    cmp_ok( scalar @$dirs, '>=', 20, 'the config declares install_dirs' );

    my $bm = do {
        open my $fh, '<:utf8', "$root/tools/build-manifest.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $bm, qr/install_dirs/,
        'build-manifest.pl carries install_dirs into the manifest' );

    my $inst = do {
        open my $fh, '<:utf8', "$root/install.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $inst, qr/\$manifest->\{install_dirs\}/,
        'install.pl reads it from the manifest' );
    like( $inst, qr/dirs\s*=>\s*\\%dirs/,
        'and records the RESOLVED modes into the install state - without this '
            . 'an installed site keeps no copy of the model and check has '
            . 'nothing to verify against' );

    my $chk = do {
        open my $fh, '<:utf8', "$root/tools/lazysite-check.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $chk, qr/\$j->\{dirs\}/,
        'lazysite-check.pl reads the recorded modes' );
};

done_testing();
