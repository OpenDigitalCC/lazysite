#!/usr/bin/perl
# SM711 half 2: the audit row for a refused plugin toggle names the dependency.
#
# SM472 refuses to enable a plugin whose declared modules or programs are not
# installed - correctly, because a plugin that enables and then fails on every
# request is the state that produced the 500s SM472 was filed for. The BANNER
# names what is missing and how to install it.
#
# The audit row did not. It recorded `plugin-enable / pandoc / fail` and, once
# a kind existed, `missing_deps` - which names the CLASS of failure and never
# the thing that is absent. The release manager's words: "the logged error
# doesn't say which dep is missing". The information existed the whole time,
# three feet away in the banner; only the record lacked it.
#
# WHY THE PROSE IS NOT REUSED. The operator's message is three sentences with
# install advice in the middle - right for a banner, wrong for a column an
# auditor scans. So the bare names travel beside it rather than being parsed
# back out of the sentence they were just formatted into, which is the mistake
# that would have made this cheap and wrong.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 qw(repo_root);
use Lazysite::Manager::Plugins ();

my $root = repo_root();

subtest 'the dependency check returns the names, not only the sentence' => sub {
    # A descriptor declaring a module that cannot exist, and a program that is
    # not on any PATH. Passed directly, so this needs no plugin on disk.
    my $desc = {
        owns => {
            deps => ['Lazysite::Definitely::Not::Installed'],
            bins => ['lazysite-no-such-program'],
        },
    };

    my ( $msg, $absent )
        = Lazysite::Manager::Plugins::_missing_deps( 'plugins/x.pl',
        '/nonexistent/x.pl', $desc );

    ok( defined $msg, 'a refusal message is produced' ) or return;

    # The banner keeps its shape: it must still tell an operator what to do.
    like( $msg, qr/not installed/, 'the sentence still explains' );
    like( $msg, qr/Debian:/,       'and still says where to get it' );

    ok( ref $absent eq 'ARRAY', 'the bare names come back beside it' ) or return;
    is_deeply(
        [ sort @$absent ],
        [ 'Lazysite::Definitely::Not::Installed', 'lazysite-no-such-program' ],
        'BOTH kinds - a Perl module and a program - are named'
    );

    # The names are bare. A name carrying "(Debian: ...)" would put install
    # advice in an audit column, which is the banner's job.
    unlike( join( ' ', @$absent ), qr/Debian|\(/,
        'and they are bare names, not the formatted entries' );
};

subtest 'an installed dependency is not reported missing' => sub {
    # The test is only worth anything if it can pass for the right reason.
    my $desc = { owns => { deps => ['Test::More'] } };
    my ($msg) = Lazysite::Manager::Plugins::_missing_deps( 'plugins/x.pl',
        '/nonexistent/x.pl', $desc );
    is( $msg, undef, 'a module that IS installed produces no refusal' );
};

subtest 'the refusal carries audit_detail, and the audit prefers it' => sub {
    # The enable path builds it, and the dispatcher reads it. Both halves are
    # needed and neither is visible from the other file, so both are asserted.
    my $plugins = do {
        open my $fh, '<', "$root/lib/Lazysite/Manager/Plugins.pm" or die $!;
        local $/;
        <$fh>;
    };
    like( $plugins, qr/audit_detail\s*=>\s*'missing_deps: '\s*\.\s*join/,
        'the refusal builds a short detail naming the modules' );

    my $api = do {
        open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
        local $/;
        <$fh>;
    };

    # Comments stripped: the block below explains audit_detail in prose, and a
    # search that cannot tell code from prose about code would pass on the
    # explanation alone.
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $api;
    like( $code,
        qr/\$result->\{audit_detail\}\s*\|\|\s*\$result->\{kind\}/,
        'and the audit detail prefers it over the bare kind' );
};

done_testing();
