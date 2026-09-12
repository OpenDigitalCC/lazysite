#!/usr/bin/perl
# A tool's --help is the only command reference an operator has at the terminal,
# and three of them had drifted from the dispatch that decides what actually
# runs. lazysite-users.pl dispatched eight commands its usage() never mentioned
# (rename, group-nest, brief, claim-create, claim-redeem, mfa-enroll,
# mfa-disable, group-reach's siblings) and advertised a `--scope` that has been
# refused since 0.7.26; lazysite-cli.pl dispatched `repair` and `probe` and
# listed neither; install.pl accepted --verify and --channel-check and named
# neither. Every one of those is invisible to a reader of the code, because
# nothing connects the ladder to the heredoc.
#
# So assert the connection: every literal the dispatch compares against, and
# every option the installer's GetOptions accepts, appears in the text that
# tool prints for --help. The reverse direction (usage naming something the
# dispatch does not have) is checked too - that is how `--scope` survived.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($rel) = @_;
    open my $fh, '<', "$root/$rel" or die "$rel: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    return $src;
}

# The body of the usage heredoc, which is what --help prints.
sub usage_text {
    my ( $src, $terminator ) = @_;
    my ($text) = $src =~ /<<'\Q$terminator\E';\n(.*?)^\Q$terminator\E\n/ms;
    return $text;
}

# --- lazysite-users.pl: the CLI ladder --------------------------------------
subtest 'lazysite-users.pl usage names every dispatched command' => sub {
    my $src   = slurp('tools/lazysite-users.pl');
    my $usage = usage_text( $src, 'USAGE' );
    ok( $usage, 'usage() heredoc found' ) or return;

    my @cmds = $src =~ /^(?:if|elsif)\s+\(\s*\$cmd eq '([a-z][\w-]*)'\s*\)/mg;
    cmp_ok( scalar @cmds, '>=', 25, 'the CLI ladder was parsed' );

    my @missing = grep { $usage !~ /^\s{2}\Q$_\E(?:\s|$)/m } @cmds;
    is_deeply( \@missing, [], 'every dispatched command is in --help' )
        or diag("dispatched but undocumented: @missing");
};

# --- lazysite-cli.pl: the verb ladder ---------------------------------------
subtest 'lazysite-cli.pl usage names every dispatched verb' => sub {
    my $src   = slurp('tools/lazysite-cli.pl');
    my $usage = usage_text( $src, 'USAGE' );
    ok( $usage, 'usage() heredoc found' ) or return;

    my @verbs = $src =~ /^(?:if|elsif)\s+\(\s*\$verb eq '([a-z][\w-]*)'\s*\)/mg;
    cmp_ok( scalar @verbs, '>=', 10, 'the verb ladder was parsed' );

    my @missing = grep { $usage !~ /^\s{2}\Q$_\E(?:\s|$)/m } @verbs;
    is_deeply( \@missing, [], 'every dispatched verb is in --help' )
        or diag("dispatched but undocumented: @missing");
};

# --- install.pl: the option list --------------------------------------------
# GetOptions is the dispatch here: an option it accepts and usage omits is a
# capability only a reader of the source can find.
subtest 'install.pl usage names every accepted option' => sub {
    my $src   = slurp('install.pl');
    my $usage = usage_text( $src, 'USAGE' );
    ok( $usage, 'usage() heredoc found' ) or return;

    my ($block) = $src =~ /Getopt::Long::GetOptions\(\n(.*?)^\)/ms;
    ok( $block, 'the GetOptions call was parsed' ) or return;
    my @opts = $block =~ /^\s*'([a-z][\w-]*)(?:=[si])?'\s*=>/mg;
    cmp_ok( scalar @opts, '>=', 12, 'the option list was parsed' );

    # --theme is accepted only so that an old invocation gets an explanation
    # instead of "Unknown option". It does nothing, so --help must NOT offer
    # it - the exemption is the assertion that it still only warns.
    my %retired = ( theme => 1 );
    like( $src, qr/--theme is no longer supported/,
        '--theme is accepted only to say it is retired' );
    unlike( $usage, qr/--theme\b/, 'and --help does not offer it' );

    my @missing = grep { !$retired{$_} && $usage !~ /--\Q$_\E\b/ } @opts;
    is_deeply( \@missing, [], 'every accepted option is in --help' )
        or diag("accepted but undocumented: @missing");
};

# --- and nothing advertises what the code refuses ---------------------------
# --scope was listed under partner-create long after SM279 made it die.
subtest 'no tool advertises a retired option' => sub {
    my $users = slurp('tools/lazysite-users.pl');
    my $usage = usage_text( $users, 'USAGE' );
    unlike( $usage, qr/--scope\b/,
        'lazysite-users.pl --help does not offer --scope (retired in 0.7.26)' );
    unlike( $usage, qr/dav_scope\/home_domain\s+\n?\s*are GROUP settings/,
        'nor does it call dav_scope/home_domain group settings' );
};

# SM858: AND THE OTHER DIRECTION, FOR COMMANDS - which this file's own header
# claimed was covered and was not. It checked one retired OPTION by name, so a
# command the usage described and the ladder never dispatched went unnoticed:
# `account-approve` was documented in six lines from SM673 and answered "unknown
# command 'account-approve'" for as long as it existed. A reader of --help had
# no way to know, and the filing that shipped it said the operator could call it
# from the CLI.
subtest 'every command --help describes is one the tool dispatches' => sub {
    # Any comparison against the command variable, not only a line that ends
    # there: `$verb eq 'help' || $verb =~ /^-h$/` dispatches help in a compound
    # condition, and an anchored pattern reads that as undispatched.
    my %tools = (
        'tools/lazysite-users.pl' => qr/\$cmd eq '([a-z][\w-]*)'/,
        'tools/lazysite-cli.pl'   => qr/\$verb eq '([a-z][\w-]*)'/,
    );
    for my $rel ( sort keys %tools ) {
        my $src   = slurp($rel);
        my $usage = usage_text( $src, 'USAGE' );
        ok( $usage, "$rel: usage() heredoc found" ) or next;

        my $re = $tools{$rel};
        my %dispatched = map { $_ => 1 } ( $src =~ /$re/mg );
        cmp_ok( scalar keys %dispatched, '>=', 10, "$rel: the ladder was parsed" );

        # A command line in the usage text: exactly two spaces, then the name.
        # Both files also carry worked EXAMPLES at that indent ("  sudo -u
        # siteuser lazysite provision \"), and the honest way to tell them apart
        # is the first word: a line that starts with a shell word or the tool's
        # own name is an invocation, not a command this tool dispatches. Trying
        # to separate them by what FOLLOWS the name does not work - a real
        # command line is followed by its flags, exactly as an example is.
        my %an_example = map { $_ => 1 } qw(sudo perl bash sh cd export lazysite);
        my @advertised = grep { !$an_example{$_} } ( $usage =~ /^ {2}([a-z][\w-]*)(?=\s|$)/mg );
        cmp_ok( scalar @advertised, '>=', 10, "$rel: the usage list was parsed" );

        my %seen;
        my @phantom = grep { !$dispatched{$_} && !$seen{$_}++ } @advertised;
        is_deeply( \@phantom, [], "$rel: --help describes nothing the ladder lacks" )
            or diag( "advertised but not dispatched: @phantom\n"
                . 'An operator reading --help types this and is told it does '
                . 'not exist.' );
    }
};

done_testing();
