#!/usr/bin/perl
# SM288: every channel resolves a user's groups the same way.
#
# The defect this pins was not a bug in a function - it was three channels
# answering "which groups is this account in" three different ways, each correct
# by its own lights:
#
#   lazysite-dav.pl          parsed the group file itself
#   lazysite-mcp.pl          hard-set the empty list, calling it a safe default
#   lazysite-manager-api.pl  read X-Remote-Groups, which a token cannot send
#
# So the same account, in the same group, reading the same file under the same
# ACL, was allowed over WebDAV and refused over MCP. Nothing failed, no test
# noticed, and it survived roughly a year - through the SM224 analysis, an
# adversarial security review, and a feature built on top of it. An operator
# found it by reading a summary and saying "partners do have groups".
#
# t/integration/44 drives the behaviour where behaviour exists. This file pins
# the shape, because the control API has no token action that makes a per-file
# read decision, and because a text match is what catches the FOURTH channel
# somebody adds.
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
    my $t = do { local $/; <$fh> };
    close $fh;
    return $t;
}

# Comments stripped before matching: a channel must not pass this by describing
# the resolver in a comment while assigning something else.
sub code_of {
    my ($text) = @_;
    return join "\n", grep { !/^\s*#/ } split /\n/, $text;
}

# --- the shared resolver exists and is the one the others already use -------
{
    my $acl = slurp("$root/lib/Lazysite/Auth/Acl.pm");
    like( $acl, qr/sub groups_for_user/,
        'Lazysite::Auth::Acl::groups_for_user is THE resolver' );
    like( code_of($acl), qr/Lazysite::Auth::Settings::effective_groups/,
        'and it delegates to effective_groups - the same answer the capability '
            . 'and domain-access resolvers already use, so "which groups is '
            . 'this user in" has one implementation for every question' );
}

# --- every channel assigns from it ------------------------------------------
my %CHANNEL = (
    'lazysite-dav.pl' => {
        must => qr/\@Lazysite::Auth::Acl::user_groups\s*\n?\s*=\s*Lazysite::Auth::Acl::groups_for_user/,
        why => 'WebDAV resolves the account\'s groups',
    },
    'lazysite-mcp.pl' => {
        must => qr/\@Lazysite::Auth::Acl::user_groups\s*=\s*Lazysite::Auth::Acl::groups_for_user/,
        why => 'MCP resolves them too - it used to hard-set the empty list',
    },
    'lazysite-manager-api.pl' => {
        must => qr/\$token_auth\s*\n?\s*\?\s*Lazysite::Auth::Acl::groups_for_user/,
        why  => 'the control API resolves them for a TOKEN client, and keeps '
            . 'X-Remote-Groups for a cookie client, whose session sets it',
    },
);

for my $file ( sort keys %CHANNEL ) {
    my $code = code_of( slurp("$root/$file") );
    like( $code, $CHANNEL{$file}{must}, "$file: $CHANNEL{$file}{why}" );

    # No channel may zero the list. This is the exact line that made an @group
    # entry silently inert for every MCP partner, and its comment called it "the
    # safe default" - which is how it survived review.
    unlike( $code, qr/\@Lazysite::Auth::Acl::user_groups\s*=\s*\(\s*\)/,
        "$file: does not hard-zero the group list" );
}

# --- and the second implementation stays deleted ----------------------------
# WebDAV used to parse lazysite/auth/groups itself. It returned the right answer
# in practice, which is why nobody looked at it for a year - a second answer to
# a question that must have exactly one is not a compatibility surface, it is a
# disagreement waiting to happen. SM279 deleted its dead resolvers for the same
# reason rather than fixing them twice.
{
    my $dav = code_of( slurp("$root/lazysite-dav.pl") );
    unlike( $dav, qr/sub user_groups_for/,
        'the local group-file reader in lazysite-dav.pl is gone, not kept '
            . 'alongside the shared one' );
    unlike( $dav, qr{open\s+my\s+\$\w+\s*,\s*'<'\s*,\s*\$gf},
        'and nothing else in it opens the group file directly' );
}

# --- the cookie path keeps the header, deliberately -------------------------
# Not an oversight and not a second resolver: for a cookie client the auth
# wrapper sets X-Remote-Groups from the validated session, and that is the
# trusted path the whole manager is built on. Asserted so a later tidy-up does
# not "make it consistent" by deleting the mechanism that carries the session.
{
    my $api = code_of( slurp("$root/lazysite-manager-api.pl") );
    like( $api, qr/HTTP_X_REMOTE_GROUPS/,
        'the cookie path still reads the session groups from the trusted header' );
}

done_testing();
