#!/usr/bin/perl
# SM683 step one: the history OVERVIEW may not list what the reader cannot read.
#
# THE SHAPE OF THE DEFECT. Every per-file history reader - git-history,
# git-show, git-restore - resolves its target through `_git_target`, which ends
# in `_acl_denied($rel, 'read', $username)`. A file's read rule already governs
# its history, its diffs and its restores.
#
# `action_git_history_summary` did not. It filtered by blocked paths and by
# SCOPE, and by no ACL at all - while carrying a WIDER gate than the readers it
# summarises (`manage_content|manage_config`, SM664). A wider gate with a
# narrower filter is the wrong way round.
#
# WHY IT MATTERED ONLY NOW. It was harmless while protected content stayed out
# of the repository, because there was nothing for it to list. The release
# manager has ruled that protected content MUST be versioned, so the reader has
# to be closed BEFORE anything is moved - otherwise the migration opens a hole
# and closes it afterwards, and in between the overview publishes the path and
# revision count of every protected file to any `manage_config` holder in
# scope. Not the bytes: the existence, and how often it changes.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Lazysite::Manager::Files ();
use Lazysite::Auth::Acl      ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/secret");
make_path("$docroot/open");

$Lazysite::Manager::Files::DOCROOT = $docroot;
$Lazysite::Auth::Acl::DOCROOT      = $docroot;

# Two files, one rule. `secret/plan.md` is readable by alice alone; `open/x.md`
# names nobody, which on the read path means unrestricted.
for my $rel ( 'secret/plan.md', 'open/x.md' ) {
    open my $fh, '>', "$docroot/$rel" or die "$rel: $!";
    print {$fh} "# $rel\n";
    close $fh;
}

my $acls = Lazysite::Auth::Acl::load_acls();
$acls->{'secret/plan.md'} = { owner => 'alice', read => ['alice'], write => ['alice'] };
Lazysite::Auth::Acl::save_acls($acls);

# Stand in for the repository: the summary's only job here is to FILTER what it
# is handed, so the filter is what this exercises.
{
    no warnings 'redefine', 'once';
    require Lazysite::Git;
    *Lazysite::Git::enabled       = sub { 1 };
    *Lazysite::Git::files_summary = sub {
        return {
            files => [
                { path => 'secret/plan.md', revisions => 7 },
                { path => 'open/x.md',      revisions => 2 },
            ],
            summary => { files => 2, revisions => 9 },
        };
    };
}

sub summary_for {
    my ($user) = @_;
    return Lazysite::Manager::Files::action_git_history_summary( [], $user );
}

subtest 'a reader the rule excludes does not see the file at all' => sub {
    my $r = summary_for('bob');
    ok( $r->{ok}, 'the summary answers' );
    my @paths = map { $_->{path} } @{ $r->{files} || [] };
    ok( !( grep { $_ eq 'secret/plan.md' } @paths ),
        'the protected path is absent for a reader the rule excludes' )
        or diag( 'The path and its revision count are the disclosure: they say '
            . 'a protected file exists and how often somebody edits it.' );
    ok( ( grep { $_ eq 'open/x.md' } @paths ),
        '...while an unrestricted file is still listed' )
        or diag( 'A filter that hides everything is not a fix, it is an outage.' );
};

subtest 'the totals describe the set the caller can see' => sub {
    my $r = summary_for('bob');
    is( $r->{summary}{files}, 1, 'one file counted' );
    is( $r->{summary}{revisions}, 2,
        'and only its revisions' )
        or diag( "The recount is the point - this function's own comment says "
            . 'a number that disagrees with its own list is its own disclosure. '
            . 'Counting 9 revisions over 1 listed file says a second file '
            . 'exists as loudly as naming it would.' );
};

subtest 'the owner still sees their own file' => sub {
    my $r = summary_for('alice');
    my @paths = sort map { $_->{path} } @{ $r->{files} || [] };
    is_deeply( \@paths, [ 'open/x.md', 'secret/plan.md' ],
        'alice sees both' )
        or diag( 'The rule names alice for read, so hiding it from her would '
            . 'be the filter misreading the ACL rather than applying it.' );
    is( $r->{summary}{revisions}, 9, 'and the full revision count' );
};

# The property, stated where a future reader will look: this filter must agree
# with the per-file readers. If they ever disagree, the overview is either
# leaking what the reader refuses or hiding what it allows.
subtest 'the overview agrees with the per-file reader' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Files.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /(sub action_git_history_summary \{.*?\n\})/s;
    ok( $fn, 'the summary was found' ) or return;
    like( $fn, qr/_acl_allows\(\s*\$_->\{path\}, 'read', \$username\s*\)/,
        'it consults the same read rule the per-file readers do' )
        or diag( '_git_target ends in _acl_denied($rel, "read", $username). '
            . 'This filter must ask the same question of the same store, or '
            . 'the two surfaces disagree about who may see a file.' );
};

done_testing();
