#!/usr/bin/perl
# SM695: three ways a history can be empty, and a caller must be able to tell
# them apart.
#
# WHAT THE FIELD MEASURED. `lazysite/forms/submissions/contact` answered
# `{versions:[], versioned:true, enabled:true}` - byte-identical to a normal
# content file awaiting its first commit. That path is in git's @EXCLUDE list,
# so it can NEVER have a commit; reporting `versioned:true` says the opposite.
#
# SM286 already said the right thing for the private STORE. The paths the
# REPOSITORY excludes - the auth store, the forms store, runtime state - were
# owed the same statement and did not get it, so the Files page was the only
# client that could tell "protected by design" from "recording may be failing",
# which is the confusion SM683 exists to remove.
#
# The three states:
#   has history          -> versioned:1, versions populated
#   in the private store -> versioned:0, notice: history ran up to protection
#   excluded from repo   -> versioned:0, notice: never recorded at all
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Lazysite::Git ();

subtest 'the predicate matches the list git is actually given' => sub {
    # Derived from @EXCLUDE rather than a second hand-written list - a copy
    # here would be the SM578 mistake, and would drift the first time the
    # exclude list changed.
    ok( Lazysite::Git::excluded_from_history('lazysite/forms/submissions/contact'),
        'the forms store is excluded' )
        or diag( 'This is the exact path the field measured answering '
            . 'versioned:true with an empty list.' );
    ok( Lazysite::Git::excluded_from_history('lazysite/auth/users'),
        'the auth store is excluded' );
    ok( Lazysite::Git::excluded_from_history('lazysite/cache/x'),
        'runtime state is excluded' );
    ok( Lazysite::Git::excluded_from_history('page.html'),
        'a generated .html is excluded (a suffix rule, not a prefix)' );
    ok( Lazysite::Git::excluded_from_history('.install-state'),
        'and a prefix glob matches' );

    ok( !Lazysite::Git::excluded_from_history('index.md'),
        'ordinary content is NOT excluded' )
        or diag( 'A predicate that excludes everything would report every file '
            . 'as unversionable, which is an outage dressed as a fix.' );
    ok( !Lazysite::Git::excluded_from_history('docs/guide.md'),
        'nor is content in a subfolder' );
};

subtest 'the answer distinguishes the two empty cases' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Files.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /(sub action_git_history \{.*?\n\})/s;
    ok( $fn, 'action_git_history was found' ) or return;

    like( $fn, qr/excluded_from_history/,
        'it asks whether the repository covers the path' );
    like( $fn, qr/versioned => _git_bool\( \$enabled && !\$in_store && !\$excluded \)/,
        'and an excluded path reports versioned:0' )
        or diag( 'versioned:true for a path that can never have a commit is a '
            . 'confident wrong answer, which is worse than an empty list.' );
    like( $fn, qr/never recorded, not because recording failed/,
        'the notice says WHY it is empty' );

    # The two reasons must not collapse into one sentence: a protected file's
    # history exists up to a point, an excluded path's never existed.
    like( $fn, qr/Its history runs up to the point it was/,
        'the protected case keeps its own wording' );
};

done_testing();
