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
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

my $mcp = slurp("$root/lazysite-mcp.pl");
my $api = slurp("$root/lazysite-manager-api.pl");

# --- SM944 S33a: a branch is read with its callees ---------------------------
# Ruled 2026-10-11. The request's parameters are Manager::Common's context now
# (%params, and the body memo behind _json_body), so a branch's body can move
# into a `dispatch_` handler in an area module unchanged - and a guard read
# from the branch text alone would be left behind. A branch is read together
# with the `dispatch_` handlers it calls, and every sub they call (in the script
# or a Manager module) that reads %params or calls _json_body, in turn.
sub code_of {
    my ($s) = @_;
    $s =~ s/^__(?:END|DATA)__\b.*//ms;
    $s =~ s/^=[a-zA-Z].*?^=cut\b[^\n]*//gms;
    $s =~ s/^\s*#.*$//gm;
    $s =~ s/(?<=[;{}),])\s*#.*$//gm;
    return $s;
}
my %SUB;
for my $file ( "$root/lazysite-manager-api.pl", sort glob "$root/lib/Lazysite/Manager/*.pm" ) {
    my $code = code_of( slurp($file) );
    while ( $code =~ /^sub\s+(\w+)\s*\{(?:([^\n]*)\}[ \t]*$|(.*?)^\})/msg ) {
        $SUB{$1} .= $2 // $3;
    }
}
my %READS_REQUEST = map { $_ => 1 }
    grep { $_ ne '_json_body' && $SUB{$_} =~ /\$params\{|\b_json_body\s*\(/ } keys %SUB;

sub with_callees {
    my ($text) = @_;
    my ( %seen, @todo );
    my $out = $text;
    @todo = grep { /\Adispatch_\w+\z/ } $text =~ /\b(\w+)\s*\(/g;
    while ( defined( my $n = shift @todo ) ) {
        next if $seen{$n}++             || !defined $SUB{$n};
        next unless $n =~ /\Adispatch_/ || $READS_REQUEST{$n};
        $out .= "\n$SUB{$n}";
        push @todo, $SUB{$n} =~ /\b(\w+)\s*\(/g;
    }
    return $out;
}

# One branch of the chain, to the next `elsif`/`else` in column 0 (lint 218's
# reading), with its callees.
sub branch_of {
    my ($action) = @_;
    my ($b) = $api =~ /^(?:if|elsif)\s*\(\s*\$action\s+eq\s+'\Q$action\E'\s*\)\s*\{(.*?)(?=^(?:elsif|else)\b|^\}\s*$)/ms;
    return defined $b ? with_callees($b) : undef;
}

# --- the dispatcher's silent defaults ----------------------------------------
# Whatever the control API supplies without the caller asking. If a second one is
# ever added, every pairing below has to be reconsidered - so this is derived,
# not hard-coded. SM944 S21: `$path` and `$action` are imported from
# Manager::Common now, so the default is an assignment, no longer a `my`.
my %api_default;
while ( $api =~ /^(?:my )?\$([a-z_]+)\s*=\s*\$params\{([a-z_]+)\}\s*\/\/\s*(.+?);/gm ) {
    $api_default{$2} = $3;
}
delete $api_default{action};    # the dispatch key itself, not an argument

cmp_ok( scalar keys %api_default, '>=', 1,
    'the control API has at least one dispatcher-level default' );
ok( exists $api_default{path},
    'and `path` is one of them - the argument SM306 was about' );

# --- the paired surfaces -----------------------------------------------------
# SM943 stage 2: the twins are declared on the actions (`mcp => 'tool'`), and
# t/lint/23 reads them from there too, so this no longer parses lint 23's source.
my %pair = Lazysite::ControlApi::Actions::mcp_twins();
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
    # SM431 paired acl-get with get_permissions, which brought it under this
    # check. The defaulted path reads the rule governing the site root - the
    # canonical way to ask for it since SM310 - and the operation only reads;
    # the hazardous sibling (acl-set) is guarded, not excepted, above.
    'acl-get' => 'a defaulted path reads the root rule, which SM310 made the '
        . 'canonical spelling of that question. Read-only either way.',
);

subtest 'every argument MCP requires is not silently supplied by the API' => sub {
    my @unrecorded;

    for my $action ( sort keys %pair ) {
        # SM431 paired acl-set with set_permissions in the shared pair table,
        # which would drag it back into this loop - the loop the file below
        # DELIBERATELY routes it around: its guard is asserted directly in its
        # own subtest, because the branch-extraction regex here is documented
        # there as having once reported a guard that was plainly present.
        next if $action eq 'acl-set';
        my $tool = $pair{$action};
        my $req  = $requires{$tool} or next;

        for my $arg (@$req) {
            next unless exists $api_default{$arg};

            # The API side either refuses when it is absent, or is recorded.
            # SM245's landing found this line had NEVER captured: without
            # parentheses, a list-context match yields (1), so $branch was the
            # string "1" and the guard check below could not succeed for any
            # action - the exemptions and acl-set's direct assertion masked it
            # until the first new paired action relied on a real guard. The
            # acl-set subtest's comment already distrusted this extraction; it
            # was righter than it knew.
            my ($branch) = $api =~ /(\$action eq '\Q$action\E'.*?)(?=\nelsif|\nelse\b)/s;
            $branch = with_callees($branch) if defined $branch;    # SM944 S33a
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
            "${action}'s exemption states an actual reason, not a shrug" );
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

    # SM944 S33a: the branch with its callees, read by lint 218's extraction -
    # acl-set's body moves to Manager::Files' dispatch_acl_set.
    my $acl = branch_of('acl-set');
    ok( defined $acl, 'the acl-set branch was found' );
    $acl //= '';
    like( $acl, qr/\Q$want_query\E/,
        'acl-set requires an explicit, non-empty path' );
    like( $acl, qr/\Q$want_body\E/,
        'and refuses a path in the BODY, which is how it was actually hit' );
};

done_testing();
