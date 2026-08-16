#!/usr/bin/perl
# SM326: an argument required on one surface is required on the other, or the
# difference is recorded with a reason.
#
# WHERE THIS COMES FROM. `set_permissions` declares `required => ['path']`, so
# the MCP surface has always refused a call with no target. The control API
# derived its target from a SHARED dispatcher default:
#
#     my $path = $params{path} // '/';
#
# so the same operation with no path applied a SITE-WIDE read restriction and
# returned ok:1. A partner agent took a live site off the air that way (SM306).
#
# NOTHING COULD HAVE CAUGHT IT. SM239 pins that both surfaces expose the same
# ACTIONS, and t/lint/23 records which are deliberately one-sided. Neither
# compares what the two surfaces REQUIRE, so one channel could demand an argument
# while the other invented a dangerous default for it, and both looked correct to
# every check in the repository.
#
# WHAT THIS ASSERTS, and why it is narrower than the title. The hazard is
# specific: an argument that one surface REQUIRES and the other SILENTLY SUPPLIES.
# The control API has exactly one dispatcher-level default - `path` - so that is
# the pairing to check, and the check is that every paired action whose MCP tool
# requires `path` either guards it or is recorded here as safe, with the reason.
#
# "Safe by accident" is the state this converts. git-restore, git-show and
# git-history all inherit the `/` default and are harmless only because something
# DOWNSTREAM rejects it - is_editable_text on a directory. That is precisely the
# state acl-set was in before SM287 made a root ACL take effect: a downstream
# change turned a harmless default into a destructive one, and nothing was
# watching the seam.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

my $mcp = slurp("$root/lazysite-mcp.pl");
my $api = slurp("$root/lazysite-manager-api.pl");
my $l23 = slurp( ( glob "$root/t/lint/23*.t" )[0] );

# --- the dispatcher's silent defaults ----------------------------------------
# Whatever the control API supplies without the caller asking. If a second one is
# ever added, every pairing below has to be reconsidered - so this is derived,
# not hard-coded.
my %api_default;
while ( $api =~ /^my \$([a-z_]+)\s*=\s*\$params\{([a-z_]+)\}\s*\/\/\s*(.+?);/gm ) {
    $api_default{$2} = $3;
}
delete $api_default{action};    # the dispatch key itself, not an argument

cmp_ok( scalar keys %api_default, '>=', 1,
    'the control API has at least one dispatcher-level default' );
ok( exists $api_default{path},
    'and `path` is one of them - the argument SM306 was about' );

# --- the paired surfaces -----------------------------------------------------
my %pair;
if ( $l23 =~ /%PAIR = \((.*?)\n\);/s ) {
    my $block = $1;
    %pair = $block =~ /'([a-z0-9-]+)'\s*=>\s*'([a-z0-9_]+)'/g;
}
cmp_ok( scalar keys %pair, '>=', 10, 'the action/tool pairing was parsed' );

# What each MCP tool requires.
my %requires;
while ( $mcp =~ /\n    ([a-z0-9_]+) => \{(.*?)\n    \},/gs ) {
    my ( $tool, $body ) = ( $1, $2 );
    next unless $body =~ /required\s*=>\s*\[([^\]]*)\]/;
    my @args = $1 =~ /'([^']+)'/g;
    $requires{$tool} = \@args if @args;
}
cmp_ok( scalar keys %requires, '>=', 10, 'MCP required-argument lists parsed' );

# --- recorded exceptions -----------------------------------------------------
# An action whose API side accepts the default, with the reason it is safe.
# Keyed by action so adding one is a decision someone has to write down.
my %SAFE_WITH_DEFAULT = (
    'git-history' => 'a defaulted path is the docroot, and action_git_history '
        . 'resolves it through validate_path then is_editable_text, which '
        . 'rejects a directory. Read-only either way.',
    'git-show' => 'as git-history - validate_path then is_editable_text reject '
        . 'the docroot, and the operation only reads.',
    'git-restore' => 'validate_path then is_editable_text reject the docroot '
        . 'before anything is written, so the default cannot restore over a '
        . 'directory. NOTE this is safety DOWNSTREAM, not a guard here - the '
        . 'same shape acl-set had before SM287 made a root rule effective.',
);

subtest 'every argument MCP requires is not silently supplied by the API' => sub {
    my @unrecorded;

    for my $action ( sort keys %pair ) {
        my $tool = $pair{$action};
        my $req  = $requires{$tool} or next;

        for my $arg (@$req) {
            next unless exists $api_default{$arg};

            # The API side either refuses when it is absent, or is recorded.
            my ($branch) = $api =~ /\$action eq '\Q$action\E'.*?(?=\nelsif|\nelse\b)/s;
            my $guards = defined $branch
                && $branch =~ /defined \$params\{\Q$arg\E\}|exists \$params\{\Q$arg\E\}/;

            next if $guards;
            next if $SAFE_WITH_DEFAULT{$action};

            push @unrecorded,
                "$action: $tool requires '$arg', the API defaults it to "
                . "$api_default{$arg} and neither guards nor records why";
        }
    }

    is_deeply( \@unrecorded, [],
        'no paired action silently supplies an argument its twin requires' )
        or diag( join "\n  ",
        '',
        @unrecorded,
        '',
        'One surface demanding an argument while the other invents a default',
        'for it is how acl-set took a live site off the air (SM306). Either',
        'guard it, or add it to %SAFE_WITH_DEFAULT with the reason it is safe.' );
};

subtest 'the recorded exceptions are still paired, and still exempt' => sub {
    # A stale exemption is worse than none: it silently covers an action that
    # may since have gained a destructive default. Same guard-on-the-guard as
    # t/lint/47's datalist exemptions.
    for my $action ( sort keys %SAFE_WITH_DEFAULT ) {
        ok( exists $pair{$action},
            "$action is still a paired action" );
        cmp_ok( length $SAFE_WITH_DEFAULT{$action}, '>', 60,
            "$action's exemption states an actual reason, not a shrug" );
    }
};

subtest 'acl-set, the case this came from, is guarded rather than exempted' => sub {
    # Not in %PAIR, so the loop above does not reach it - but it is the reason
    # this file exists, and a regression there is the one that matters most.
    # Asserted against the file rather than an extracted branch: both patterns
    # are unique to acl-set, and a regex that carves out a branch is asserting
    # the surrounding formatting as much as the guard. The first cut of this
    # did exactly that and reported a guard that was plainly present.
    # SINGLE-QUOTED, then \Q. Writing the pattern inline made Perl interpolate
    # $params{path} before \Q ever saw it, which is a compile error under strict
    # - the file would not run at all, and a lint that cannot run asserts nothing.
    my $want_query = 'unless ( defined $params{path} && length $params{path} )';
    my $want_body  = 'elsif ( exists $req->{path} )';

    like( $api, qr/\Q$want_query\E/,
        'acl-set requires an explicit, non-empty path' );
    like( $api, qr/\Q$want_body\E/,
        'and refuses a path in the BODY, which is how it was actually hit' );
};

done_testing();
